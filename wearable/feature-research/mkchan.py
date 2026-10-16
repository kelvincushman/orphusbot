"""Build channel variants of a LibriSpeech subset.

clean : 16 kHz wav, untouched
opus  : Opus round-trip with the EXACT firmware settings read from
        firmware/kelvinlee/src/lib/core/{codec.c,config.h}:
          16 kHz mono, OPUS_APPLICATION_RESTRICTED_LOWDELAY, 32 kbps,
          VBR unconstrained, complexity 3, 20 ms frames
wear  : synthetic chest-worn far-field channel, then the same Opus round-trip:
          reverb (T60 0.35 s, DRR +3 dB ~ interlocutor at ~1.2 m)
          + babble noise (sum of 12 other LibriSpeech speakers) at a target SNR
          + 120 Hz high-pass (MEMS/body occlusion)
The reverb + noise stage is a SIMULATION, not a recording from the device.
"""
import os, sys, glob, subprocess, random
import numpy as np, soundfile as sf
from scipy.signal import fftconvolve, butter, sosfilt

ROOT = os.path.dirname(os.path.abspath(__file__))
SR = 16000
OPUS = ["-c:a","libopus","-b:a","32k","-vbr","on","-application","lowdelay",
        "-compression_level","3","-frame_duration","20","-ar","16000","-ac","1"]

def rir(t60=0.35, drr_db=3.0, seed=0):
    rng = np.random.default_rng(seed)
    n = int(t60*SR)
    tail = rng.standard_normal(n) * np.exp(-6.9*np.arange(n)/(t60*SR))
    tail[:int(0.004*SR)] = 0                      # 4 ms pre-delay
    tail *= (10**(-drr_db/20)) / np.sqrt((tail**2).sum())
    h = np.zeros(n); h[0] = 1.0; h += tail
    return h.astype("float32")

def babble(n, pool, seed=0):
    rng = np.random.default_rng(seed); out = np.zeros(n, dtype="float32")
    for i in range(12):
        a, _ = sf.read(pool[rng.integers(len(pool))], dtype="float32")
        a = a / (np.sqrt((a**2).mean()) + 1e-9)
        reps = int(np.ceil(n/len(a))); a = np.tile(a, reps)[:n]
        out += a
    return out / np.sqrt((out**2).mean())

def opus_roundtrip(x, tmp):
    sf.write(tmp+".wav", x, SR, subtype="PCM_16")
    subprocess.run(["ffmpeg","-y","-loglevel","error","-i",tmp+".wav"]+OPUS+[tmp+".opus"], check=True)
    subprocess.run(["ffmpeg","-y","-loglevel","error","-i",tmp+".opus","-ar","16000","-ac","1",tmp+".out.wav"], check=True)
    y, _ = sf.read(tmp+".out.wav", dtype="float32")
    for e in (".wav",".opus",".out.wav"): os.remove(tmp+e)
    return y

def main(split, n, snr_db):
    sys.path.insert(0, ROOT); from bench import load_subset
    items = load_subset(split, n)
    pool = sorted(glob.glob(f"{ROOT}/LibriSpeech/{split}/*/*/*.flac"))
    h = rir(); sos = butter(2, 120, "highpass", fs=SR, output="sos")
    dirs = {c: f"{ROOT}/chan/{split}-{c}" for c in ("clean","opus",f"wear{snr_db}")}
    for d in dirs.values(): os.makedirs(d, exist_ok=True)
    for i,(path,_) in enumerate(items):
        base = os.path.basename(path).replace(".flac",".wav")
        x, sr = sf.read(path, dtype="float32"); assert sr == SR
        sf.write(os.path.join(dirs["clean"], base), x, SR, subtype="PCM_16")
        tmp = f"{ROOT}/chan/_t{i}"
        sf.write(os.path.join(dirs["opus"], base), opus_roundtrip(x, tmp), SR, subtype="PCM_16")
        r = fftconvolve(x, h)[:len(x)]
        b = babble(len(x), pool, seed=i)
        rs = np.sqrt((r**2).mean()); b *= rs / (10**(snr_db/20))
        w = sosfilt(sos, r + b).astype("float32")
        w *= 0.7/ (np.abs(w).max()+1e-9)
        sf.write(os.path.join(dirs[f"wear{snr_db}"], base), opus_roundtrip(w, tmp), SR, subtype="PCM_16")
        if i % 50 == 0: print(i, flush=True)
    print("done", {k: len(os.listdir(v)) for k,v in dirs.items()})

if __name__ == "__main__":
    main(sys.argv[1], int(sys.argv[2]), int(sys.argv[3]))
