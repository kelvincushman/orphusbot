# Copyright (c) 2025-2026 Kelvin Lee. Licensed under MIT.
#
# ASR benchmark harness. Measures WER and RTF across sherpa-onnx models on a
# channel built to match this firmware (see mkchan.py).
#
# The corpus and model files live OUTSIDE the repo and off the internal disk,
# at ~/dev/asr-bench/ — models/, LibriSpeech/, chan/. They are 5.4 GB
# and re-downloadable, so they are deliberately not committed; keeping them
# means a re-run against real wearable audio costs minutes rather than an hour.
#
import os, sys, time, glob, json, re, unicodedata
import numpy as np, soundfile as sf, sherpa_onnx
from jiwer import wer

ROOT = os.path.dirname(os.path.abspath(__file__))
M    = os.path.join(ROOT, "models")

def norm(s):
    s = unicodedata.normalize("NFKC", s).upper()
    s = re.sub(r"[^A-Z' ]", " ", s)
    return " ".join(s.split())

def load_subset(split, n):
    """Deterministic every-Nth subset of a LibriSpeech split."""
    items = []
    for tr in sorted(glob.glob(f"{ROOT}/LibriSpeech/{split}/*/*/*.trans.txt")):
        d = os.path.dirname(tr)
        for line in open(tr):
            uid, txt = line.strip().split(" ", 1)
            items.append((os.path.join(d, uid + ".flac"), txt))
    items.sort()
    step = max(1, len(items)//n)
    return items[::step][:n]

def build(name):
    T = int(os.environ.get("NT", "4"))
    p = lambda *a: os.path.join(M, *a)
    if name == "moonshine-tiny-en":
        d = "sherpa-onnx-moonshine-tiny-en-quantized-2026-02-27"
        return sherpa_onnx.OfflineRecognizer.from_moonshine_v2(p(d,"encoder_model.ort"), p(d,"decoder_model_merged.ort"), p(d,"tokens.txt"), num_threads=T), False
    if name == "moonshine-base-en":
        d = "sherpa-onnx-moonshine-base-en-quantized-2026-02-27"
        return sherpa_onnx.OfflineRecognizer.from_moonshine_v2(p(d,"encoder_model.ort"), p(d,"decoder_model_merged.ort"), p(d,"tokens.txt"), num_threads=T), False
    if name == "zipformer-en-20M-streaming-fp32":
        d = "sherpa-onnx-streaming-zipformer-en-20M-2023-02-17-mobile"
        return sherpa_onnx.OnlineRecognizer.from_transducer(tokens=p(d,"tokens.txt"), encoder=p(d,"encoder-epoch-99-avg-1.onnx"), decoder=p(d,"decoder-epoch-99-avg-1.onnx"), joiner=p(d,"joiner-epoch-99-avg-1.int8.onnx"), num_threads=T, provider="cpu"), True
    if name == "moonshine-tiny-en-v1-int8":
        d = "sherpa-onnx-moonshine-tiny-en-int8"
        return sherpa_onnx.OfflineRecognizer.from_moonshine(p(d,"preprocess.onnx"), p(d,"encode.int8.onnx"), p(d,"uncached_decode.int8.onnx"), p(d,"cached_decode.int8.onnx"), p(d,"tokens.txt"), num_threads=T), False
    if name == "whisper-tiny.en-int8":
        d = "sherpa-onnx-whisper-tiny.en"
        return sherpa_onnx.OfflineRecognizer.from_whisper(p(d,"tiny.en-encoder.int8.onnx"), p(d,"tiny.en-decoder.int8.onnx"), p(d,"tiny.en-tokens.txt"), num_threads=T), False
    if name == "whisper-base.en-int8":
        d = "sherpa-onnx-whisper-base.en"
        return sherpa_onnx.OfflineRecognizer.from_whisper(p(d,"base.en-encoder.int8.onnx"), p(d,"base.en-decoder.int8.onnx"), p(d,"base.en-tokens.txt"), num_threads=T), False
    if name == "zipformer-small-en-int8":
        d = "sherpa-onnx-zipformer-small-en-2023-06-26"
        return sherpa_onnx.OfflineRecognizer.from_transducer(p(d,"encoder-epoch-99-avg-1.int8.onnx"), p(d,"decoder-epoch-99-avg-1.onnx"), p(d,"joiner-epoch-99-avg-1.int8.onnx"), p(d,"tokens.txt"), num_threads=T), False
    if name == "zipformer-gigaspeech-int8":
        d = "sherpa-onnx-zipformer-gigaspeech-2023-12-12"
        return sherpa_onnx.OfflineRecognizer.from_transducer(p(d,"encoder-epoch-30-avg-1.int8.onnx"), p(d,"decoder-epoch-30-avg-1.onnx"), p(d,"joiner-epoch-30-avg-1.int8.onnx"), p(d,"tokens.txt"), num_threads=T), False
    if name == "parakeet-tdt-ctc-110m-int8":
        d = "sherpa-onnx-nemo-parakeet_tdt_ctc_110m-en-36000-int8"
        return sherpa_onnx.OfflineRecognizer.from_nemo_ctc(p(d,"model.int8.onnx"), p(d,"tokens.txt"), num_threads=T), False
    if name == "parakeet-tdt-0.6b-v3-int8":
        d = "sherpa-onnx-nemo-parakeet-tdt-0.6b-v3-int8"
        return sherpa_onnx.OfflineRecognizer.from_transducer(p(d,"encoder.int8.onnx"), p(d,"decoder.int8.onnx"), p(d,"joiner.int8.onnx"), p(d,"tokens.txt"), num_threads=T, model_type="nemo_transducer", feature_dim=128), False
    if name == "canary-180m-flash-int8":
        d = "sherpa-onnx-nemo-canary-180m-flash-en-es-de-fr-int8"
        return sherpa_onnx.OfflineRecognizer.from_nemo_canary(p(d,"encoder.int8.onnx"), p(d,"decoder.int8.onnx"), p(d,"tokens.txt"), num_threads=T), False
    if name == "sense-voice-int8":
        d = "sherpa-onnx-sense-voice-zh-en-ja-ko-yue-int8-2025-09-09"
        return sherpa_onnx.OfflineRecognizer.from_sense_voice(p(d,"model.int8.onnx"), p(d,"tokens.txt"), num_threads=T, language="en", use_itn=False), False
    if name == "sense-voice-2024-int8":
        d = "sherpa-onnx-sense-voice-zh-en-ja-ko-yue-int8-2024-07-17"
        return sherpa_onnx.OfflineRecognizer.from_sense_voice(p(d,"model.int8.onnx"), p(d,"tokens.txt"), num_threads=T, language="en", use_itn=False), False
    if name == "kroko-en-streaming":
        d = "sherpa-onnx-streaming-zipformer-en-kroko-2025-08-06"
        return sherpa_onnx.OnlineRecognizer.from_transducer(tokens=p(d,"tokens.txt"), encoder=p(d,"encoder.onnx"), decoder=p(d,"decoder.onnx"), joiner=p(d,"joiner.onnx"), num_threads=T, provider="cpu"), True
    if name == "zipformer-en-streaming-int8":
        # Streaming sibling of our incumbent offline checkpoint (same date, same
        # family), so this is the closest like-for-like measure of what live
        # transcription costs in accuracy. chunk-16-left-128 is the wider
        # left-context variant; the left-64 build is the same size.
        d = "sherpa-onnx-streaming-zipformer-en-2023-06-26"
        return sherpa_onnx.OnlineRecognizer.from_transducer(tokens=p(d,"tokens.txt"), encoder=p(d,"encoder-epoch-99-avg-1-chunk-16-left-128.int8.onnx"), decoder=p(d,"decoder-epoch-99-avg-1-chunk-16-left-128.onnx"), joiner=p(d,"joiner-epoch-99-avg-1-chunk-16-left-128.int8.onnx"), num_threads=T, provider="cpu"), True
    if name == "zipformer-en-20M-streaming-int8":
        d = "sherpa-onnx-streaming-zipformer-en-20M-2023-02-17-mobile"
        return sherpa_onnx.OnlineRecognizer.from_transducer(tokens=p(d,"tokens.txt"), encoder=p(d,"encoder-epoch-99-avg-1.int8.onnx"), decoder=p(d,"decoder-epoch-99-avg-1.onnx"), joiner=p(d,"joiner-epoch-99-avg-1.int8.onnx"), num_threads=T, provider="cpu"), True
    raise SystemExit("unknown model " + name)

def run(name, items, audio_dir=None):
    rec, online = build(name)
    hyps, refs, dur, el = [], [], 0.0, 0.0
    for path, ref in items:
        if audio_dir:
            path = os.path.join(audio_dir, os.path.basename(path).replace(".flac", ".wav"))
        a, sr = sf.read(path, dtype="float32")
        assert sr == 16000, sr
        dur += len(a)/sr
        t0 = time.perf_counter()
        if online:
            s = rec.create_stream(); s.accept_waveform(sr, a)
            s.accept_waveform(sr, np.zeros(int(0.5*sr), dtype="float32")); s.input_finished()
            while rec.is_ready(s): rec.decode_stream(s)
            txt = rec.get_result(s)
        else:
            s = rec.create_stream(); s.accept_waveform(sr, a); rec.decode_stream(s); txt = s.result.text
        el += time.perf_counter()-t0
        hyps.append(norm(txt)); refs.append(norm(ref))
    return dict(model=name, wer=100*wer(refs, hyps), rtf=el/dur, audio_s=dur, decode_s=el, n=len(items))

if __name__ == "__main__":
    split, n = sys.argv[1], int(sys.argv[2])
    audio_dir = sys.argv[3] if len(sys.argv) > 3 and sys.argv[3] != "-" else None
    items = load_subset(split, n)
    lim = int(os.environ.get("LIMIT", "0"))
    if lim: items = items[:lim]
    for name in sys.argv[4:]:
        try:
            r = run(name, items, audio_dir)
            print(json.dumps(r), flush=True)
        except Exception as e:
            print(json.dumps(dict(model=name, error=str(e)[:300])), flush=True)
