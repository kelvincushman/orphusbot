
## ASR benchmark corpus

`bench.py`, `mkchan.py`, `results.txt` and `extras.txt` are the harness and the
measurements. The inputs they need — 12 sherpa-onnx models, LibriSpeech, and
the channel-simulated audio — are 5.4 GB and live at **`~/dev/asr-bench/`**,
outside the repo and off the internal disk. They are re-downloadable, so they
are deliberately not committed.

Keep them: re-running this against real wearable recordings, rather than the
synthetic room simulation, is the outstanding piece of work and the models are
the slow part to fetch.
