#!/bin/zsh
cd "$(dirname "$0")"
until grep -q "@@@ ALLDONE" results.txt; do sleep 30; done
KEY=(moonshine-tiny-en-v1-int8 zipformer-small-en-int8 parakeet-tdt-ctc-110m-int8 parakeet-tdt-0.6b-v3-int8 canary-180m-flash-int8 whisper-base.en-int8)
echo "@@@ test-clean wear10dn (GTCRN-denoised)"
LIMIT=120 NT=4 ./v/bin/python bench.py test-clean 200 chan/test-clean-wear10dn $KEY 2>/dev/null
echo "@@@ test-other wear10dn (GTCRN-denoised)"
LIMIT=120 NT=4 ./v/bin/python bench.py test-other 200 chan/test-other-wear10dn $KEY 2>/dev/null
echo "@@@ SHORT<9s test-clean clean  (moonshine v2 44MB vs the rest)"
NT=4 ./v/bin/python short.py test-clean chan/test-clean-clean moonshine-tiny-en moonshine-base-en moonshine-tiny-en-v1-int8 zipformer-small-en-int8 parakeet-tdt-ctc-110m-int8 2>/dev/null
echo "@@@ SHORT<9s test-clean wear10"
NT=4 ./v/bin/python short.py test-clean chan/test-clean-wear10 moonshine-tiny-en moonshine-base-en moonshine-tiny-en-v1-int8 zipformer-small-en-int8 parakeet-tdt-ctc-110m-int8 2>/dev/null
echo "@@@ LATENCY (uncontended, NT=4, Apple M2, 12 utts)"
for m in moonshine-tiny-en-v1-int8 whisper-tiny.en-int8 whisper-base.en-int8 zipformer-small-en-int8 zipformer-gigaspeech-int8 parakeet-tdt-ctc-110m-int8 parakeet-tdt-0.6b-v3-int8 canary-180m-flash-int8 sense-voice-2024-int8 kroko-en-streaming; do
  NT=4 ./v/bin/python mem.py $m 2>/dev/null
done
echo "@@@ EXTRASDONE"
