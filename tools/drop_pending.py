"""On the pod: delete every still-pending prompt that a manifest's log submitted. Usage: drop_pending.py MANIFEST"""
import json
import os
import sys
import urllib.request

BASE = os.environ.get("COMFY_URL", f"http://127.0.0.1:{os.environ.get('PORT', '8188')}")

log = sys.argv[1].rsplit(".", 1)[0] + ".submitted.jsonl"
ids = {json.loads(l)["prompt_id"] for l in open(log)}
q = json.load(urllib.request.urlopen(BASE + "/queue"))
drop = sorted(ids & {i[1] for i in q["queue_pending"]})
if drop:
    urllib.request.urlopen(urllib.request.Request(BASE + "/queue", json.dumps({"delete": drop}).encode(),
                                                  {"Content-Type": "application/json"}))
print("dropped", len(drop), "pending prompts from", log)
