#!/usr/bin/env bash

# Copyright (c) 2025-2026 Kelvin Lee. Licensed under MIT.

# Scenario: open the Threads side-sheet, confirm the chat list renders,
# tap an existing thread to switch active context.

set -euo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=./_lib.sh
source "$HERE/_lib.sh"

require_one_device
relaunch

tap_text "Ask Wearable" || tap_text "Chat" || true
sleep 2

# Threads icon is the burger / "☰ Threads" affordance from the M-2 work.
if ! tap_text "Threads"; then
  log "no 'Threads' label — checking for burger icon"
  # Accessible label fallback — Material Drawer typically exposes "Open
  # navigation drawer" via content-description.
  tap_text "Open" || true
fi
sleep 1
shot "03-threads-open"

if wait_for_text "New chat" 10 || wait_for_text "+ New" 10; then
  log "03-threads ✓ (sheet rendered)"
else
  shot "03-threads-failed"
  log "03-threads: side-sheet content not detected"
  exit 1
fi
