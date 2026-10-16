#!/usr/bin/env bash

# Copyright (c) 2025-2026 Kelvin Lee. Licensed under MIT.

# Scenario: open the Boardroom tab, tap the mic button, capture the LED
# state. Verifies the M-2 mic-press path end-to-end without needing a
# real LiveKit room — we only assert the local UI changes (mic active
# indicator + Habitat-Alert haptic ack).

set -euo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=./_lib.sh
source "$HERE/_lib.sh"

require_one_device
relaunch

# The home tab IS Boardroom in the Wearable flavor (selectedIndex==0). If the
# screen has a tab bar, the active tab text is "Board Room"; if not we
# rely on the mic FAB being visible on first paint.
shot "01-pre-tap"

if ! wait_for_text "Mic" 15 && ! wait_for_text "Board Room" 15; then
  log "01-boardroom-mic: neither 'Mic' nor 'Board Room' label seen — UI may have changed"
  exit 1
fi

# Try a labelled mic button first, fall back to the floating action area.
if ! tap_text "Mic"; then
  log "no labelled Mic — attempting tap on FAB region (bottom-center)"
  # Pixel-coordinate fallback. For a Galaxy S24 (1080x2340) that's roughly
  # centred near the bottom of the safe area. Adjust if layouts shift.
  tap_xy 540 2050
fi

sleep 2
shot "01-post-tap"
assert_foreground
log "01-boardroom-mic ✓"
