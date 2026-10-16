#!/usr/bin/env bash

# Copyright (c) 2025-2026 Kelvin Lee. Licensed under MIT.

# Run every scenario in numeric order. Stops on the first failure (set -e).
# Each scenario is independently runnable — this just batches them.

set -euo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

# shellcheck source=./_lib.sh
source "$HERE/_lib.sh"
require_one_device
log "Galaxy S24 detected. Running mobile E2E suite. Artifacts → $ARTIFACTS_DIR"

for spec in "$HERE"/[0-9][0-9]-*.sh; do
  name=$(basename "$spec" .sh)
  log "=========================================="
  log "▶ $name"
  log "=========================================="
  bash "$spec"
done

log "All mobile E2E scenarios passed."
