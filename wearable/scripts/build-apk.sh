#!/bin/bash
# Copyright (c) 2025-2026 Kelvin Lee. Licensed under MIT.
#
# Build the dev release APK, and VERIFY the artifact actually contains the
# current source before anyone installs it.
#
# Why this exists: `flutter build apk` twice produced a byte-identical APK
# after real Dart changes, reported success, and wrote a fresh timestamp.
# `flutter clean` does NOT remove android/app/build, which is where the stale
# artifact survives — Gradle then decides it is up to date and Flutter copies
# the old file forward. Every surface signal said it had worked.
#
# Usage:  scripts/build-apk.sh [marker-string]
# The marker is a string that MUST appear in the compiled Dart. Default is one
# that changes whenever the ASR model does.
set -euo pipefail
cd "$(dirname "$0")/../app"

TMP_SO="$(mktemp -t libapp)"
trap 'rm -f "$TMP_SO"' EXIT

MARKER="${1:-Zipformer-small from Hugging Face}"
APK=android/app/build/outputs/flutter-apk/app-dev-release.apk

echo "==> clearing Gradle outputs (flutter clean leaves these behind)"
rm -rf android/app/build android/.gradle build .dart_tool

fvm flutter pub get >/dev/null
fvm flutter build apk --release --flavor dev --target-platform android-arm64 2>&1 | tail -2 || true

[ -f "$APK" ] || { echo "FAIL: no APK produced"; exit 1; }
echo "==> built $(stat -f%Sm "$APK"), $(( $(stat -f%z "$APK") / 1048576 )) MB"

# Search the compiled Dart for the marker in BOTH encodings.
#
# Two false negatives have come out of this check, and both reported a correct
# build as stale — which is worse than no check, because it sends you hunting a
# build problem that does not exist:
#
#  1. `grep -q` exits on first match, `strings` takes SIGPIPE, and under
#     `set -o pipefail` the pipeline reports failure. Hence a match COUNT.
#  2. Dart stores a string as UTF-16 as soon as it contains one non-Latin-1
#     character — an em dash or an ellipsis is enough — and `strings` only
#     scans ASCII runs. A perfectly present marker scored zero.
#
# Searching the raw bytes for both encodings removes both traps and drops the
# dependency on `strings` (macOS's has no -el).
unzip -p "$APK" lib/arm64-v8a/libapp.so > "$TMP_SO"
HITS=$(MARKER="$MARKER" python3 - "$TMP_SO" <<'PY'
import os, sys
data = open(sys.argv[1], 'rb').read()
m = os.environ['MARKER']
print(data.count(m.encode('utf-8')) + data.count(m.encode('utf-16-le')))
PY
)
if [ "${HITS:-0}" -gt 0 ]; then
  echo "==> VERIFIED: artifact contains \"$MARKER\" ($HITS match(es))"
else
  echo "FAIL: \"$MARKER\" is NOT in the compiled Dart — this APK is stale."
  exit 1
fi
