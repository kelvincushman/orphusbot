<!-- Copyright (c) 2025-2026 Kelvin Lee. Licensed under MIT. -->

# Third-party code

This project is MIT licensed (see [`LICENSE`](LICENSE)), Copyright (c) 2025-2026
Kelvin Lee. It vendors the third-party components below, which keep their own
licences. Their copyright notices are retained verbatim in each source file, as
those licences require.

| Component | Path | Licence | Copyright |
|---|---|---|---|
| Opus codec 1.2.1 | `firmware/devkit/src/lib/opus-1.2.1/` | BSD-3-Clause | Xiph.Org Foundation, Skype Limited, Jean-Marc Valin, Timothy B. Terriberry, CSIRO, Gregory Maxwell, Octasic Inc., Mark Borgerding, and others — see the notice at the top of each file |
| Battery driver | `firmware/devkit/src/lib/battery/` | Apache-2.0 | Copyright 2024 Marcus Alexander Tjomsaas |
| MCUboot sample keys | `firmware/bootloader/mcuboot/*.pem` | Apache-2.0 (MCUboot) | The MCUboot project |
| Bootloader images | `firmware/bootloader/`, `firmware/FLASH_3.0.8/` | Vendor redistributables | Seeed Studio / Adafruit |

Neither `firmware/devkit/src/lib/opus-1.2.1/` nor `firmware/devkit/src/lib/battery/`
carries a Kelvin Lee copyright header, and neither should. Both directories hold a
`.no-copyright` sentinel so `scripts/add-copyright-headers.sh` skips them.

## Upstream-derived code

Parts of the firmware and Flutter app derive from an MIT-licensed upstream project.
Those files carry a "Portions (c) 2024 Based Hardware Contributors" line and the
licence is reproduced in [`LICENSE-UPSTREAM`](LICENSE-UPSTREAM). MIT requires that
notice to ship alongside the code, so neither the line nor the file may be removed
while any of that code remains.

Replacing it is tracked in [`feature-research/own-stack/plan.md`](feature-research/own-stack/plan.md).
When no upstream-derived file remains, `LICENSE-UPSTREAM` can be removed — earned by
deleting the code, not by deleting the notice.

## Build-time dependencies (not vendored)

Zephyr RTOS (Apache-2.0), Nordic nRF HAL (BSD-3-Clause), and the Flutter/Dart
packages listed in `app/pubspec.yaml`, each under its own licence.
