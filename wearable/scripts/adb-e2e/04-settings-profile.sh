#!/usr/bin/env bash

# Copyright (c) 2025-2026 Kelvin Lee. Licensed under MIT.

# Scenario: open the gear menu (WearableDrawer), navigate to Profile, confirm
# the profile page renders (was stubbed pre-M-7, now wired).

set -euo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=./_lib.sh
source "$HERE/_lib.sh"

require_one_device
relaunch

# Gear icon (replaces the burger per the dogfood feedback). Try several
# labels because Flutter widgets expose them in different ways depending
# on Material/Cupertino.
if ! tap_text "Settings" && ! tap_text "Menu" && ! tap_text "Profile"; then
  log "no menu label — tapping top-left corner where the gear sits"
  tap_xy 80 180
fi
sleep 1
shot "04-drawer-open"

# Drawer should now be visible. Tap "Profile" tile.
if ! tap_text "Profile"; then
  log "04-settings-profile: 'Profile' tile not found in drawer"
  shot "04-no-profile-tile"
  exit 1
fi
sleep 2

# Profile page success markers — either a known label, the user's email,
# or a signout button.
if wait_for_text "Sign out" 10 || wait_for_text "Profile" 10 || wait_for_text "Account" 10; then
  shot "04-profile-rendered"
  log "04-settings-profile ✓"
else
  shot "04-profile-failed"
  log "04-settings-profile: profile page didn't render"
  exit 1
fi
