"""On the pod: write one trial manifest per (shot, compile seed) so each can be compiled and checked.
Usage: seed_try.py MANIFEST SHOT SEED [SEED ...]   (writes try_<SHOT>_s<SEED>.json next to MANIFEST)"""
import json
import sys
from pathlib import Path

src, shot, seeds = sys.argv[1], sys.argv[2], sys.argv[3:]
for seed in seeds:
    m = json.load(open(src))
    m["shots"] = [s for s in m["shots"] if s["name"] == shot]
    m["shots"][0]["compile_seed"] = int(seed)
    out = Path(src).with_name(f"try_{shot}_s{seed}.json")
    json.dump(m, open(out, "w"), ensure_ascii=False)
    print(out)
