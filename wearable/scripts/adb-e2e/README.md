<!-- Copyright (c) 2025-2026 Kelvin Lee. Licensed under MIT. -->

# Mobile E2E (ADB) — Wearable

Scenario scripts that drive the Galaxy S24 (or any connected Android
device) through the Wearable Flutter app. Each scenario is a standalone
bash script — no test framework dependency, no device farm — so they
run anywhere `adb` is on `PATH`.

## Prerequisites

- `adb` on `PATH` (Android platform-tools)
- Device connected, USB debugging enabled, exactly one device authorised:
  ```
  adb devices
  # ... <adb serial>	device
  ```
- Wearable app installed (dev flavor: `com.wearable.app.dev`)
- Server reachable from the phone over the LAN — the chat scenario needs
  `wearable-core` to actually reply

## Run

Single scenario:

```bash
./scripts/adb-e2e/00-launch.sh
./scripts/adb-e2e/02-ask-wearable.sh
```

Full suite, sequential, fail-fast:

```bash
./scripts/adb-e2e/run-all.sh
```

Screenshots and uiautomator dumps land in `$WEARABLE_E2E_ARTIFACTS`
(default `/tmp/wearable-adb-e2e`), named by `HHMMSS-<step>.png`. The
filenames sort by time so a CI artifact upload preserves the
chronological story.

## Scenarios

| Script | What it covers |
|---|---|
| `00-launch.sh` | Cold start — relaunch + foreground assertion. Cheapest smoke test. |
| `01-boardroom-mic.sh` | Open Boardroom, tap mic, capture state. M-2 mic path. |
| `02-ask-wearable.sh` | Ask-Wearable bottom sheet → typing → reply lands. Phone twin of `dashboard/chat.test.ts`. |
| `03-threads.sh` | Open Threads side-sheet, confirm chat list. M-2 thread sidebar. |
| `04-settings-profile.sh` | Gear menu → Profile (M-7 wire-up — was stubbed pre-fix). |
| `05-tab-back-nav.sh` | PopScope tab-history back-nav. Verifies M-2 fix that back returns to last tab, not home. |

## Tap discipline

Scripts prefer `tap_text "<visible label>"` over pixel coordinates. When
labels aren't accessible to uiautomator (bare `Icon()` widgets without a
`Semantics` wrapper, custom-painted FABs), they fall back to coordinates
calibrated for a Galaxy S24 (1080×2340). If you're testing on a different
device, the fallbacks may need re-calibration — open
`adb shell uiautomator dump && adb pull /sdcard/ui.xml` and adjust.

## CI

Out of scope for this PR — the suite assumes a real device on a desk.
A future iteration could run these in a Firebase Test Lab job, gated by
a label so we don't burn quota on every push.
