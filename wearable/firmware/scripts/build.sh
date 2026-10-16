# Copyright (c) 2025-2026 Kelvin Lee. Licensed under MIT. Portions (c) 2024 Based Hardware Contributors, MIT (see LICENSE-UPSTREAM).

set -e
west build
cp build/zephyr/zephyr.uf2 /Volumes/XIAO-SENSE/