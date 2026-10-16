# Fair comparison restricted to utterances < 9 s, where Moonshine v2's broken
# ORT export still decodes. Same subset for every model.
import os, sys, json, soundfile as sf
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from bench import load_subset, run
split, chan = sys.argv[1], sys.argv[2]
items = [(p,t) for p,t in load_subset(split,200)[:120]]
keep = []
for p,t in items:
    q = os.path.join(chan, os.path.basename(p).replace(".flac",".wav"))
    if os.path.exists(q) and sf.info(q).duration < 9.0: keep.append((p,t))
print(f"# {len(keep)} utterances < 9 s from {chan}", flush=True)
for m in sys.argv[3:]:
    try: print(json.dumps(run(m, keep, chan)), flush=True)
    except Exception as e: print(json.dumps(dict(model=m, error=str(e)[:200])), flush=True)
