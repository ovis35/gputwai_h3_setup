"""On the pod: for the newest compile of each shot in a manifest, wait for it, then report fallback, verbatim
dialogue, and which shot (with start time) each line landed in.
Usage: python3 check_shots.py MANIFEST [NAME ...]   (no names = every shot in the manifest)"""
import json
import os
import re
import sys
import time
import urllib.request

BASE = os.environ.get("COMFY_URL", f"http://127.0.0.1:{os.environ.get('PORT', '8188')}")

manifest = sys.argv[1]
m = json.load(open(manifest))
names = sys.argv[2:] or [s["name"] for s in m["shots"]]
latest = {}
for line in open(manifest.rsplit(".", 1)[0] + ".submitted.jsonl"):
    r = json.loads(line)
    if r["mode"] == "compile" and r["name"] in names:
        latest[r["name"]] = r["prompt_id"]
want = {s["name"]: re.findall(r'@speaks\("(.*?)"\)', s["intent"]) for s in m["shots"]}

for name in names:
    pid = latest[name]
    for _ in range(240):
        h = json.load(urllib.request.urlopen(BASE + "/history/" + pid)).get(pid)
        if h:
            break
        time.sleep(5)
    allt = "\n".join(t for o in h["outputs"].values() for t in o.get("text", []))
    desc = allt[allt.find("detailed_description"):]
    print(f"== {name} ({pid[:8]}) status={h['status']['status_str']} fallback={'fallback, not a written' in allt}")
    got = []
    for mm in re.finditer(r"\[Shot (\d+)\](.*?)(?=\[Shot \d+\]|overall_soundscape)", desc, re.S):
        body = mm.group(2)
        start = re.search(r"At (\d\d:\d\d\.\d+)", body)
        lines = re.findall(r"<d>\[Chinese\]\s*(.*?)</d>", body)
        got += lines
        print(f"  shot {mm.group(1)} @ {start.group(1) if start else '00:00.000'}: {lines}")
    print(f"  verbatim: {all(w in got for w in want[name])}")
