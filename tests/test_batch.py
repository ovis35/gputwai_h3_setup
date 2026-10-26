"""End-to-end test of h3-batch.py against a fake ComfyUI HTTP server.
Run: python -I tests/test_batch.py h3-batch.py
The fake prompt mirrors the node ids/classes seen in the real 2026-10-25 OpenH3-IR workflow."""
import json, os, subprocess, sys, tempfile, threading, uuid
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path

SCRIPT = str(Path(sys.argv[1]).resolve())  # h3-batch runs from a temp dir
TRAY = [{"kind": "picture", "label": "picture1", "file": "openh3ir/a.png [input]", "role": "subject", "note": ""},
        {"kind": "picture", "label": "picture2", "file": "openh3ir/b.png [input]", "role": "subject", "note": ""},
        {"kind": "picture", "label": "picture3", "file": "openh3ir/c.png [input]", "role": "setting", "note": ""}]
PROMPT = {
    "10": {"class_type": "OpenH3IRSetup", "inputs": {"llm_model": "gpt-4.1-mini"}},
    "40": {"class_type": "PreviewAny", "inputs": {"source": ["166", 3]}},
    "41": {"class_type": "PreviewAny", "inputs": {"source": ["166", 4]}},
    "163": {"class_type": "OpenH3IRDirector", "inputs": {"profile": "{}"}},
    "164": {"class_type": "OpenH3IRMedia", "inputs": {"tray": json.dumps(TRAY)}},
    "166": {"class_type": "OpenH3IRCompile", "inputs": {"intent": "old", "seconds": 5.5, "aspect": "9:16", "creativity": "restrained",
            "silent": True, "shots": "1", "megapixels": 0.0, "spoken_language": "Chinese", "sizing": "max", "seed": 1, "effort": "max",
            "setup": ["10", 0], "media": ["164", 0]}},
    "161:110": {"class_type": "RandomNoise", "inputs": {"noise_seed": 1}},
    "161:90": {"class_type": "BasicScheduler", "inputs": {"scheduler": "beta", "steps": 20, "denoise": 1, "model": ["166", 0]}},
    "161:80": {"class_type": "KSamplerSelect", "inputs": {"sampler_name": "euler"}},
    "161:150": {"class_type": "CreateVideo", "inputs": {"fps": 24, "images": ["161:130", 0]}},
}
EXTRA = {"client_id": "ui", "create_time": 1, "extra_pnginfo": {"workflow": {"nodes": [{"id": 160, "type": "SaveVideo", "mode": 2}]}}}
history, posted = {}, []
history["seed-ui-run"] = {"prompt": [0, "seed-ui-run", PROMPT, EXTRA, []], "outputs": {}, "status": {"status_str": "success"}}


class H(BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def send(self, obj):
        b = json.dumps(obj).encode(); self.send_response(200)
        self.send_header("Content-Type", "application/json"); self.end_headers(); self.wfile.write(b)
    def do_GET(self):
        if self.path.startswith("/history/"):
            pid = self.path.split("/")[2]; self.send({pid: history[pid]} if pid in history else {})
        elif self.path.startswith("/history"): self.send(history)
        elif self.path == "/queue": self.send({"queue_running": [], "queue_pending": []})
    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        pid = str(uuid.uuid4()); posted.append(body)
        is_render = any(n["class_type"] == "SaveVideo" for n in body["prompt"].values())
        history[pid] = {"prompt": [len(history), pid, body["prompt"], body["extra_data"], []], "status": {"status_str": "success"},
                        "outputs": {} if is_render else {"41": {"text": ["brief for " + body["prompt"]["166"]["inputs"]["intent"][:20]]}}}
        self.send({"prompt_id": pid, "number": len(history), "node_errors": {}})


srv = HTTPServer(("127.0.0.1", 0), H); threading.Thread(target=srv.serve_forever, daemon=True).start()
d = Path(tempfile.mkdtemp()); inp = d / "input" / "openh3ir"; inp.mkdir(parents=True)
for n in ("hh.png", "gm.png", "hall.png"): (inp / n).write_bytes(b"x")
env = dict(os.environ, COMFY_URL=f"http://127.0.0.1:{srv.server_port}", INPUT_DIR=str(d / "input"))
(d / "ep_intent_2.txt").write_text("@picture1 walks in.", encoding="utf-8")
manifest = {"template": "tpl.json", "output_prefix": "S3_EP5",
            "defaults": {"seconds": 15, "shots": 4, "takes": 2, "compile_seed": 7, "steps": 8, "scheduler": "simple", "sampler": "res_multistep"},
            "shots": [{"name": "EP5-1", "intent": "@picture1 talks to @picture2 in @picture3.",
                       "media": {"picture1": "openh3ir/hh.png", "picture2": "openh3ir/gm.png", "picture3": "openh3ir/hall.png"}},
                      {"name": "EP5-2", "intent_file": "ep_intent_2.txt", "takes": 3,
                       "media": {"picture1": "openh3ir/hh.png", "picture2": {"file": "openh3ir/hall.png", "role": "setting"}}}]}
(d / "ep.json").write_text(json.dumps(manifest, ensure_ascii=False), encoding="utf-8")


def run(*a, ok=True):
    r = subprocess.run([sys.executable, SCRIPT, *a], cwd=d, env=env, capture_output=True, text=True, encoding="utf-8")
    print(f"$ h3-batch {' '.join(a)}\n{r.stdout}{r.stderr}".rstrip())
    assert (r.returncode == 0) == ok, f"unexpected exit {r.returncode}"
    return r


def check(cond, msg):
    print(("PASS " if cond else "FAIL ") + msg); assert cond, msg


run("capture", "--out", "tpl.json")
tpl = json.loads((d / "tpl.json").read_text(encoding="utf-8"))
check("client_id" not in tpl["extra_data"] and tpl["source_prompt_id"] == "seed-ui-run", "capture strips client_id and records source")

run("submit", "ep.json", "--mode", "render", "--dry-run")
check(not posted, "dry-run posts nothing")

run("submit", "ep.json", "--mode", "compile")
check(len(posted) == 2, "compile queues one prompt per shot")
c1 = posted[0]["prompt"]
check(not any(n["class_type"] == "SaveVideo" for n in c1.values()), "compile has no SaveVideo")
check(c1["166"]["inputs"]["seconds"] == 15 and c1["166"]["inputs"]["shots"] == "4" and c1["166"]["inputs"]["seed"] == 7, "compile inputs patched")
tray = json.loads(c1["164"]["inputs"]["tray"])
check([s["file"] for s in tray] == ["openh3ir/hh.png [input]", "openh3ir/gm.png [input]", "openh3ir/hall.png [input]"]
      and tray[2]["role"] == "setting", "tray files swapped, template roles kept")
check(json.loads(posted[1]["prompt"]["164"]["inputs"]["tray"])[1]["role"] == "setting"
      and len(json.loads(posted[1]["prompt"]["164"]["inputs"]["tray"])) == 2, "slot override and slot count follow manifest")
check(posted[1]["prompt"]["166"]["inputs"]["intent"] == "@picture1 walks in.", "intent_file read")

run("previews", "ep.json")
pv = (d / "ep.previews.md").read_text(encoding="utf-8")
check("brief for @picture1 talks to" in pv and "## EP5-2" in pv, "previews written")

posted.clear()
run("submit", "ep.json", "--mode", "render", "--tag", "m1")
check(len(posted) == 5, "render queues takes per shot (2 + 3)")
r1, r2 = posted[0]["prompt"], posted[1]["prompt"]
sv = r1["h3batch_save"]["inputs"]
check(sv["video"] == ["161:150", 0] and sv["filename_prefix"] == "S3_EP5/EP5-1_t1_m1", "SaveVideo wired to CreateVideo with prefix")
check(r1["161:110"]["inputs"]["noise_seed"] != r2["161:110"]["inputs"]["noise_seed"], "takes get different noise seeds")
check(r1["166"]["inputs"]["seed"] == r2["166"]["inputs"]["seed"] == 7, "takes share compile seed")
check(r1["161:90"]["inputs"]["steps"] == 8 and r1["161:90"]["inputs"]["scheduler"] == "simple"
      and r1["161:80"]["inputs"]["sampler_name"] == "res_multistep", "steps/scheduler/sampler overrides")
check(posted[0]["extra_data"]["extra_pnginfo"]["workflow"]["nodes"][0]["mode"] == 0, "embedded workflow shows SaveVideo enabled")

posted.clear()
run("submit", "ep.json", "--mode", "render", "--only", "EP5-2", "--dry-run")
run("submit", "ep.json", "--mode", "render", "--only", "nope", ok=False)
(inp / "gm.png").unlink()
run("submit", "ep.json", "--mode", "compile", ok=False)
check(not posted, "missing media file aborts before posting")
run("status", "ep.json")
print("ALL PASS")
