#!/bin/zsh
cd "$(dirname "$0")"
M1=(moonshine-tiny-en-v1-int8 whisper-tiny.en-int8 whisper-base.en-int8 zipformer-small-en-int8)
M2=(zipformer-gigaspeech-int8 parakeet-tdt-ctc-110m-int8 parakeet-tdt-0.6b-v3-int8 canary-180m-flash-int8)
M3=(sense-voice-int8 sense-voice-2024-int8 kroko-en-streaming zipformer-en-20M-streaming-int8)
for spec in "test-clean:clean" "test-clean:opus" "test-clean:wear10" "test-other:clean" "test-other:wear10"; do
  split=${spec%%:*}; chan=${spec##*:}
  echo "@@@ $split $chan"
  for g in 1 2 3; do
    eval "MS=(\$M$g)"
    LIMIT=120 NT=3 ./v/bin/python bench.py $split 200 chan/$split-$chan $MS 2>/dev/null &
  done
  wait
done
echo "@@@ ALLDONE"
