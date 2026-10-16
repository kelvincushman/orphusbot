# Copyright (c) 2025-2026 Kelvin Lee. Licensed under MIT. Portions (c) 2024 Based Hardware Contributors, MIT (see LICENSE-UPSTREAM).

# Suppress "unique_unit_address_if_enabled" to handle some overlaps
list(APPEND EXTRA_DTC_FLAGS "-Wno-unique_unit_address_if_enabled")
