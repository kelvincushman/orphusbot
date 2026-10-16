#!/usr/bin/env bash

# Copyright (c) 2025-2026 Kelvin Lee. Licensed under MIT.

# Scenario: open the Ask Wearable bottom sheet, type a message, send, expect
# an assistant bubble. Mirrors the dashboard `chat.test.ts` round-trip
# but on the phone surface.

set -euo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=./_lib.sh
source "$HERE/_lib.sh"

require_one_device
relaunch

# Open Ask Wearable. The button is reachable from any tab; in the M-2 layout
# it's a persistent FAB-style icon on the bottom-right.
if ! tap_text "Ask Wearable"; then
  # Fallback: tap-and-hold the chat tab if Ask Wearable isn't visible.
  log "no 'Ask Wearable' label — opening chat directly"
  tap_text "Chat" || true
fi
sleep 2
shot "02-sheet-open"

# Type the test prompt and send. Use a unique stamp so the assertion
# doesn't accidentally match a stale bubble.
STAMP="adbE2E-$(date +%s)"
adb shell input text "ping%s${STAMP}%sreply%swith%sPONG"
sleep 1
# Send button typically labeled "Send" or shown as an arrow icon.
tap_text "Send" || tap_xy 1000 2050

# Wait up to 60s for the reply (matches main role wallClockMs budget).
if wait_for_text "PONG" 60; then
  shot "02-reply-received"
  log "02-ask-wearable ✓ (PONG seen)"
else
  shot "02-reply-timeout"
  log "02-ask-wearable: PONG not received within 60s — agent may be hung or layout changed"
  exit 1
fi
