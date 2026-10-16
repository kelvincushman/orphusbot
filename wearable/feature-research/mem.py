"""Peak RSS + single-utterance latency for one model, measured in a fresh process."""
import os, sys, time, resource, json
import numpy as np, soundfile as sf
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from bench import build, load_subset

name = sys.argv[1]
base = resource.getrusage(resource.RUSAGE_SELF).ru_maxrss
rec, online = build(name)
items = load_subset("test-clean", 200)[:12]
# warm-up
a,_ = sf.read(items[0][0], dtype="float32")
s = rec.create_stream(); s.accept_waveform(16000, a)
if online:
    s.accept_waveform(16000, np.zeros(8000, dtype="float32")); s.input_finished()
    while rec.is_ready(s): rec.decode_stream(s)
else:
    rec.decode_stream(s)
lat, dur = [], []
for path,_ in items:
    a,_ = sf.read(path, dtype="float32")
    t0 = time.perf_counter()
    s = rec.create_stream(); s.accept_waveform(16000, a)
    if online:
        s.accept_waveform(16000, np.zeros(8000, dtype="float32")); s.input_finished()
        while rec.is_ready(s): rec.decode_stream(s)
    else:
        rec.decode_stream(s)
    lat.append(time.perf_counter()-t0); dur.append(len(a)/16000)
peak = resource.getrusage(resource.RUSAGE_SELF).ru_maxrss
div = 1e6 if sys.platform == "darwin" else 1e3   # macOS ru_maxrss is bytes
print(json.dumps(dict(model=name, peak_rss_mb=round(peak/div,1), base_rss_mb=round(base/div,1),
      rtf=round(sum(lat)/sum(dur),4), med_lat_s=round(float(np.median(lat)),3),
      med_audio_s=round(float(np.median(dur)),2))))
