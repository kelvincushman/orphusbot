#!/usr/bin/env bash

# Copyright (c) 2025-2026 Kelvin Lee. Licensed under MIT.

# Smoke test: relaunch the Wearable app and confirm the home screen renders.
# Cheapest possible E2E — if this fails, every other scenario will too.

set -euo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=./_lib.sh
source "$HERE/_lib.sh"

require_one_device
relaunch
assert_foreground
shot "00-launch-home"
log "00-launch ✓"
