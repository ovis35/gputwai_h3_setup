#!/usr/bin/env python3
"""Queue many OpenH3-IR shots on a running ComfyUI in one go.

  python3 h3-batch.py capture [--prompt-id ID] [--out openh3ir_template.json]
      Save the newest OpenH3-IR prompt that ComfyUI ran (from /history) as a template.
      Run your workflow once in the UI first; a compile-only run (SaveVideo muted) is enough.

  python3 h3-batch.py submit MANIFEST --mode compile|render [--only NAME,...] [--tag m1] [--dry-run]
      compile: queue each shot once without SaveVideo, so only the brief is written (~1 min each).
      render:  queue each shot `takes` times with SaveVideo enabled and a different noise seed per take.

  python3 h3-batch.py previews MANIFEST
      Write the briefs from finished compile runs to <manifest>.previews.md for review.

  python3 h3-batch.py status MANIFEST
      Show the queue and the state of every prompt this manifest submitted.

Standard library only. Talks to http://127.0.0.1:$PORT (default 8188).
"""
import argparse
import copy
import hashlib
import json
import os
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path

PORT = int(os.environ.get("PORT", "8188"))
BASE = os.environ.get("COMFY_URL", f"http://127.0.0.1:{PORT}")
INPUT_DIR = Path(os.environ.get("INPUT_DIR", os.path.join(os.environ.get("VAULT", "/vault"), "comfyui-input")))
SAVE_ID = "h3batch_save"

# Keys in a manifest shot (or its defaults) that map straight onto OpenH3IRCompile inputs.
COMPILE_KEYS = ("seconds", "aspect", "creativity", "silent", "shots", "megapixels",
                "spoken_language", "sizing", "effort")
DEFAULTS = {"takes": 1, "compile_seed": 7}


def die(msg):
    sys.exit(f"[h3-batch ERROR] {msg}")


def api(path, body=None):
    data = None if body is None else json.dumps(body).encode()
    req = urllib.request.Request(BASE + path, data, {"Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=60) as r:
            return json.loads(r.read() or b"null")
    except urllib.error.HTTPError as e:
        die(f"{path}: HTTP {e.code} {e.read().decode(errors='replace')[:1500]}")
    except urllib.error.URLError as e:
        die(f"{path}: cannot reach ComfyUI at {BASE} ({e.reason})")


def nodes_of(prompt, class_type):
    return [k for k, v in prompt.items() if v.get("class_type") == class_type]


def one_node(prompt, class_type):
    ids = nodes_of(prompt, class_type)
    if len(ids) != 1:
        die(f"template must contain exactly one {class_type} node, found {len(ids)}")
    return ids[0]


# ---------- capture ----------

def cmd_capture(args):
    hist = api("/history?max_items=50") or {}
    if args.prompt_id:
        if args.prompt_id not in hist:
            hist = api(f"/history/{args.prompt_id}") or {}
        items = [hist.get(args.prompt_id)] if args.prompt_id in hist else []
    else:
        # /history keeps insertion order; newest last.
        items = [h for h in reversed(list(hist.values()))
                 if nodes_of(h["prompt"][2], "OpenH3IRCompile")]
    if not items or items[0] is None:
        die("no OpenH3-IR prompt found in /history; run the workflow once in the UI first")
    item = items[0]
    prompt, extra = item["prompt"][2], dict(item["prompt"][3] or {})
    for k in ("client_id", "create_time"):
        extra.pop(k, None)
    for ct in ("OpenH3IRCompile", "OpenH3IRMedia", "RandomNoise", "CreateVideo"):
        one_node(prompt, ct)
    out = Path(args.out)
    out.write_text(json.dumps({"source_prompt_id": item["prompt"][1], "prompt": prompt, "extra_data": extra},
                              ensure_ascii=False, indent=1), encoding="utf-8")
    print(f"saved template from prompt {item['prompt'][1]} to {out} ({len(prompt)} nodes)")


# ---------- manifest ----------

def load_manifest(path):
    path = Path(path)
    m = json.loads(path.read_text(encoding="utf-8"))
    tpl_path = (path.parent / m.get("template", "openh3ir_template.json")).resolve()
    if not tpl_path.exists():
        die(f"template {tpl_path} not found; run `h3-batch.py capture --out {tpl_path}` on the pod")
    tpl = json.loads(tpl_path.read_text(encoding="utf-8"))
    names = [s.get("name") for s in m.get("shots", [])]
    if not names or None in names or len(set(names)) != len(names):
        die("every shot needs a unique `name`")
    return path, m, tpl


def shot_settings(m, shot, base_dir):
    s = dict(DEFAULTS)
    s.update(m.get("defaults", {}))
    s.update(shot)
    if "intent_file" in s:
        s["intent"] = (base_dir / s["intent_file"]).read_text(encoding="utf-8").strip()
    if not s.get("intent"):
        die(f"{shot['name']}: needs `intent` or `intent_file`")
    if not s.get("media"):
        die(f"{shot['name']}: needs `media` (slot label -> file in the ComfyUI input folder)")
    return s


def build_tray(template_tray, media, shot_name, check_files):
    """Keep each template slot's kind/role/note, swap its file; add slots the template lacks."""
    by_label = {slot["label"]: slot for slot in template_tray}
    known_roles = {slot.get("role") for slot in template_tray}
    tray = []
    for label, spec in media.items():
        spec = {"file": spec} if isinstance(spec, str) else dict(spec)
        slot = copy.deepcopy(by_label.get(label, {"kind": "picture", "label": label, "role": "subject", "note": ""}))
        name = spec["file"]
        if check_files and not (INPUT_DIR / name).is_file():
            die(f"{shot_name}: {label} file not found: {INPUT_DIR / name}")
        slot["file"] = name if name.endswith("]") else f"{name} [input]"
        for k in ("kind", "role", "note"):
            if k in spec:
                slot[k] = spec[k]
        # Role values are OpenH3-IR internals; the template only proves the ones it already uses.
        if slot.get("role") not in known_roles:
            print(f"[h3-batch WARNING] {shot_name}: {label} role {slot.get('role')!r} is not used in the template "
                  f"(template roles: {sorted(r for r in known_roles if r)}); check it in the UI", file=sys.stderr)
        tray.append(slot)
    return tray


def noise_seed(name, take):
    return int(hashlib.sha256(f"{name}#{take}".encode()).hexdigest()[:12], 16)


def build_prompt(tpl, s, mode, take, prefix, check_files):
    p = copy.deepcopy(tpl["prompt"])
    extra = copy.deepcopy(tpl.get("extra_data", {}))

    comp = p[one_node(p, "OpenH3IRCompile")]["inputs"]
    comp["intent"] = s["intent"]
    comp["seed"] = int(s["compile_seed"])
    for k in COMPILE_KEYS:
        if k in s and s[k] is not None:
            comp[k] = str(s[k]) if k == "shots" else s[k]

    media = p[one_node(p, "OpenH3IRMedia")]["inputs"]
    media["tray"] = json.dumps(build_tray(json.loads(media["tray"]), s["media"], s["name"], check_files),
                               ensure_ascii=False, separators=(",", ":"))

    seed = noise_seed(s["name"], take)
    p[one_node(p, "RandomNoise")]["inputs"]["noise_seed"] = seed
    if s.get("steps") is not None:
        p[one_node(p, "BasicScheduler")]["inputs"]["steps"] = int(s["steps"])
    if s.get("scheduler"):
        p[one_node(p, "BasicScheduler")]["inputs"]["scheduler"] = s["scheduler"]
    if s.get("sampler"):
        p[one_node(p, "KSamplerSelect")]["inputs"]["sampler_name"] = s["sampler"]

    # Muted nodes never reach the API prompt, so SaveVideo is added (render) or dropped (compile) here.
    for nid in nodes_of(p, "SaveVideo"):
        del p[nid]
    if mode == "render":
        p[SAVE_ID] = {"class_type": "SaveVideo", "_meta": {"title": "SaveVideo (h3-batch)"},
                      "inputs": {"video": [one_node(p, "CreateVideo"), 0], "filename_prefix": prefix,
                                 "format": "auto", "format.codec": "auto"}}
        for n in extra.get("extra_pnginfo", {}).get("workflow", {}).get("nodes", []):
            if n.get("type") == "SaveVideo":
                n["mode"] = 0
    return p, extra, seed


def log_path(manifest_path):
    return manifest_path.with_suffix(".submitted.jsonl")


def read_log(manifest_path):
    lp = log_path(manifest_path)
    if not lp.exists():
        return []
    return [json.loads(line) for line in lp.read_text(encoding="utf-8").splitlines() if line.strip()]


# ---------- submit ----------

def cmd_submit(args):
    mpath, m, tpl = load_manifest(args.manifest)
    only = set(args.only.split(",")) if args.only else None
    root = m.get("output_prefix", mpath.stem)
    planned = []
    for shot in m["shots"]:
        if only and shot["name"] not in only:
            continue
        s = shot_settings(m, shot, mpath.parent)
        takes = 1 if args.mode == "compile" else int(s["takes"])
        for take in range(1, takes + 1):
            tag = f"_{args.tag}" if args.tag else ""
            prefix = f"{root}/{s['name']}_t{take}{tag}"
            p, extra, seed = build_prompt(tpl, s, args.mode, take, prefix, check_files=not args.no_file_check)
            planned.append((s, take, prefix, seed, p, extra))
    if only and len({x[0]["name"] for x in planned}) != len(only):
        die(f"unknown shot name in --only: {sorted(only - {x[0]['name'] for x in planned})}")

    for s, take, prefix, seed, p, extra in planned:
        label = f"{s['name']} take {take}" if args.mode == "render" else s["name"]
        if args.dry_run:
            print(f"[dry-run] {args.mode} {label}: prefix={prefix} noise_seed={seed} nodes={len(p)}")
            continue
        r = api("/prompt", {"prompt": p, "extra_data": extra, "client_id": "h3-batch"})
        if r.get("node_errors"):
            die(f"{label}: node errors {json.dumps(r['node_errors'], ensure_ascii=False)[:1500]}")
        rec = {"time": time.strftime("%Y-%m-%d %H:%M:%S"), "mode": args.mode, "name": s["name"], "take": take,
               "prompt_id": r["prompt_id"], "prefix": prefix if args.mode == "render" else None,
               "noise_seed": seed, "compile_seed": s["compile_seed"]}
        with log_path(mpath).open("a", encoding="utf-8") as f:
            f.write(json.dumps(rec, ensure_ascii=False) + "\n")
        print(f"queued {args.mode} {label}: {r['prompt_id']}")
    if not args.dry_run:
        print(f"{len(planned)} prompt(s) queued; log: {log_path(mpath)}")


# ---------- previews / status ----------

def history_of(pid):
    return (api(f"/history/{pid}") or {}).get(pid)


def cmd_previews(args):
    mpath, _, _ = load_manifest(args.manifest)
    latest = {}
    for rec in read_log(mpath):
        if rec["mode"] == "compile":
            latest[rec["name"]] = rec
    if not latest:
        die("no compile runs in the log; run `submit --mode compile` first")
    out = [f"# Briefs for {mpath.name}\n"]
    for name, rec in latest.items():
        h = history_of(rec["prompt_id"])
        out.append(f"## {name}\n\nprompt `{rec['prompt_id']}`, compile seed {rec['compile_seed']}\n")
        if not h:
            out.append("_not finished yet_\n")
            continue
        texts = [t for o in h.get("outputs", {}).values() for t in o.get("text", [])]
        out.append("\n\n".join(f"```\n{t}\n```" for t in texts) if texts else "_no text output_")
        out.append("")
    dest = mpath.with_suffix(".previews.md")
    dest.write_text("\n".join(out), encoding="utf-8")
    print(f"wrote {dest}")


def cmd_status(args):
    mpath, _, _ = load_manifest(args.manifest)
    q = api("/queue") or {}
    running = {i[1] for i in q.get("queue_running", [])}
    pending = {i[1] for i in q.get("queue_pending", [])}
    print(f"queue: {len(running)} running, {len(pending)} pending")
    for rec in read_log(mpath):
        pid = rec["prompt_id"]
        if pid in running:
            state = "running"
        elif pid in pending:
            state = "pending"
        else:
            h = history_of(pid)
            state = h["status"]["status_str"] if h else "unknown"
        what = f"{rec['name']} t{rec['take']}" if rec["mode"] == "render" else rec["name"]
        print(f"  {rec['time']}  {rec['mode']:7}  {what:24} {state:8} {pid}  {rec['prefix'] or ''}")


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    c = sub.add_parser("capture")
    c.add_argument("--prompt-id")
    c.add_argument("--out", default="openh3ir_template.json")
    s = sub.add_parser("submit")
    s.add_argument("manifest")
    s.add_argument("--mode", choices=("compile", "render"), required=True)
    s.add_argument("--only", help="comma-separated shot names")
    s.add_argument("--tag", help="added to output names, e.g. a machine id when several pods share /vault")
    s.add_argument("--dry-run", action="store_true")
    s.add_argument("--no-file-check", action="store_true", help="skip checking media files under INPUT_DIR")
    for name in ("previews", "status"):
        sub.add_parser(name).add_argument("manifest")
    args = ap.parse_args()
    {"capture": cmd_capture, "submit": cmd_submit, "previews": cmd_previews, "status": cmd_status}[args.cmd](args)


if __name__ == "__main__":
    main()
