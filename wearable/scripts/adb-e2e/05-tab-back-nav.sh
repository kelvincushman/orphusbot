#!/usr/bin/env bash

# Copyright (c) 2025-2026 Kelvin Lee. Licensed under MIT.

# Scenario: verify PopScope tab-history back-nav (M-2 work). Switch from
# Boardroom → another tab → press back, expect to return to Boardroom
# rather than exiting the app.

set -euo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=./_lib.sh
source "$HERE/_lib.sh"

require_one_device
relaunch

# Start on Boardroom (selectedIndex==0 in M-2 layout).
shot "05-start-boardroom"

# Move to Memories or Plugins tab — anything that's not the home.
if ! tap_text "Memories" && ! tap_text "Plugins" && ! tap_text "Apps"; then
  log "no second-tab label found — using bottom-nav coords"
  # On a Galaxy S24 the bottom nav is around y=2200; right of center hits
  # tab index 2-3 in a 5-tab layout.
  tap_xy 760 2200
fi
sleep 1
shot "05-second-tab"

# Press hardware back. PopScope should pop tab history back to home.
adb shell input keyevent KEYCODE_BACK
sleep 1
shot "05-after-back"

assert_foreground

# Looking for a Boardroom-only marker (mic, etc.) to confirm we're back.
if wait_for_text "Mic" 5 || wait_for_text "Board" 5; then
  log "05-tab-back-nav ✓ (returned to Boardroom)"
else
  shot "05-back-nav-failed"
  log "05-tab-back-nav: did not land on Boardroom after back press"
  exit 1
fi
