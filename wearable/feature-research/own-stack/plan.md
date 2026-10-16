# Plan: Own-stack wearable — Roadmap + Phase 0

**Goal:** Replace every upstream-derived file with our own implementation so
`kelvincushman/wearable` can be published as an original MIT project under
Kelvin Lee's name, with `LICENSE-UPSTREAM` legitimately removed because no
upstream code remains — not because the notice was stripped.

**Out of scope (explicit, permanently):**
- Rewriting `firmware/devkit/src/lib/opus-1.2.1/` — that is Xiph's Opus codec
  (BSD-3), not upstream's. Everyone vendors it. It keeps its own licence.
- Rewriting Zephyr, the Nordic HAL, or Flutter packages.
- Re-implementing upstream app features we do not use (conversations feed,
  plugin marketplace, payments, desktop shell). Those get deleted, not ported.

**Phase gate:** human approval required before any dispatch.

---

## Why this shape

Measured composition of the repo today:

| Area | Upstream-derived | Ours | Decision |
|---|---:|---:|---|
| `firmware/devkit/src/*.c,*.h` | ~22 files | `agent_commands`, `habitat`, `neopixel`, `config.h` | **rewrite** |
| `firmware/.../lib/opus-1.2.1` | 0 (Xiph BSD-3) | — | **keep, attribute** |
| `app/lib` (Dart) | 298 files | 75 (`lib/wearable`) | **delete + minimal new shell** |
| `server-contract/` | 0 | all | **keep** |
| docs | mixed | mixed | rewrite in Phase 3 |

The lazy read: the upstream firmware logic is only ~22 C files, which is
genuinely rewritable. The 298 Dart files are not worth porting — `lib/wearable`
already is the app we actually use; the rest is dead weight we delete.

---

## Roadmap

| Phase | Outcome | Gate |
|---|---|---|
| **0** | Toolchain on the external dev disk; existing firmware builds and flashes to the attached device | build + flash proven |
| **1** | Own Zephyr firmware: mic → Opus → BLE, button, LED, haptic | runs on hardware |
| **2** | Own Flutter app on `lib/wearable`; 298 upstream files deleted | app builds, pairs |
| **3** | Docs rewritten, `LICENSE` (MIT, Kelvin Lee), `LICENSE-UPSTREAM` removed | 0 upstream files |

Phases 1–3 are deliberately not detailed yet. Phase 0 decides whether the
hardware loop even closes on this machine; planning past an unproven
toolchain is speculative work.

---

## Phase 0 — Toolchain + proven flash loop

**Blocking fact:** this machine has no embedded toolchain. No `west`,
`arm-none-eabi-gcc`, `nrfutil`, `nrfjprog`, or `JLinkExe`. Nothing can be
built or flashed until that is fixed, and no firmware task can have a
machine-checkable acceptance criterion until a build runs.

**Hardware confirmed attached:** Zephyr CDC device, `idVendor 0x2FE3`,
`idProduct 0x0100`, on `/dev/cu.usbmodem114101`. Currently running the
existing firmware, not in bootloader mode. Recovery path if a flash fails:
double-tap reset → `XIAO-SENSE` UF2 drive → drag a known-good `.uf2`.

**All toolchain installs go to `~/dev/`** — nRF Connect SDK plus
the Zephyr SDK is ~10-15 GB. ExtHdd has 621 GB free.

### Task table

| Task-id | Title | Owner role | Risk | Depends on |
|---------|-------|------------|------|------------|
| T0.1 | Install Zephyr SDK + west on the external dev disk | glm-spinner | low | — |
| T0.2 | `west init`/`update` the nRF Connect SDK tree on the external dev disk | glm-spinner | low | T0.1 |
| T0.3 | Build existing devkit firmware unmodified | codex-coder | med | T0.2 |
| T0.4 | Flash attached device + confirm it re-enumerates | opus-coder | high | T0.3 |
| TV | Phase verification | qwen-verifier | — | T0.4 |

### T0.1: Install Zephyr SDK + west on the external dev disk
**Owner:** glm-spinner
**Files touched:**
- `docs/TOOLCHAIN.md` (new)

**Spec:** Install `west` (pipx or venv) and the Zephyr SDK 0.16.x for
`arm-zephyr-eabi`, rooted under `~/dev/zephyr/`. Nothing installs
to `~` or `/opt` except unavoidable pip shims. Record the exact commands and
env vars (`ZEPHYR_SDK_INSTALL_DIR`, `ZEPHYR_BASE`) in `docs/TOOLCHAIN.md`.

**Acceptance criteria:**
| # | Command | Expected |
|---|---------|----------|
| 1 | `west --version` | exit 0 |
| 2 | `test -d ~/dev/zephyr && echo yes` | `yes` |
| 3 | `ls ~/dev/zephyr/zephyr-sdk-*/arm-zephyr-eabi/bin/arm-zephyr-eabi-gcc` | exit 0 |

**Escalation triggers:** Zephyr SDK refuses a non-standard install root;
macOS Gatekeeper blocks the toolchain binaries.

### T0.2: west init + update the SDK tree
**Owner:** glm-spinner
**Files touched:**
- `docs/TOOLCHAIN.md`

**Spec:** `west init` an nRF Connect SDK workspace under
`~/dev/zephyr/ncs/` at the revision matching the firmware baseline
(DK2 v2.0.10 era; nRF Connect SDK v2.9.x), then `west update`. Do not modify
anything in the `wearable` repo except the doc.

**Acceptance criteria:**
| # | Command | Expected |
|---|---------|----------|
| 1 | `west list \| head -1` | exit 0 |
| 2 | `test -d ~/dev/zephyr/ncs/zephyr && echo yes` | `yes` |

**Escalation triggers:** west revision mismatch against the board files.

### T0.3: Build the existing firmware unmodified
**Owner:** codex-coder
**Files touched:**
- `docs/TOOLCHAIN.md`

**Spec:** From `firmware/devkit/`, build the Wearable variant exactly as
`docs/BUILD_FIRMWARE.md` documents, output dir `build_kelvinlee`, using the
ExtHdd toolchain. Change no source. The point is to prove the toolchain, not
to improve anything. If the build fails on a pre-existing defect, report it —
do not fix it (one known candidate: `prj_xiao_ble_sense_devkitv1-spisd.conf`
sets `CONFIG_KELVINLEE_OFFLINE_STORAGE`, undefined in Kconfig).

**Acceptance criteria:**
| # | Command | Expected |
|---|---------|----------|
| 1 | `test -f firmware/devkit/build_kelvinlee/zephyr/zephyr.uf2 && echo yes` | `yes` |
| 2 | `test -f firmware/devkit/build_kelvinlee/zephyr/zephyr.hex && echo yes` | `yes` |

**Escalation triggers:** any source change appears necessary to compile.

### T0.4: Flash the attached device
**Owner:** opus-coder
**Files touched:**
- `docs/TOOLCHAIN.md`

**Spec:** Flash `zephyr.uf2` to the attached XIAO via the UF2 bootloader
(double-tap reset → `XIAO-SENSE` volume → copy). Confirm the device
re-enumerates as a Zephyr CDC device afterwards. **Do not touch MCUboot or
the bootloader.** If the device does not re-enumerate within 30s, restore the
prebuilt image from `firmware/FLASH_3.0.8/MAC/` and escalate immediately.

**Acceptance criteria:**
| # | Command | Expected |
|---|---------|----------|
| 1 | `ls /dev/cu.usbmodem* \| wc -l` | `>= 1` |
| 2 | `ioreg -p IOUSB -w0 -l \| grep -c '"USB Vendor Name" = "ZEPHYR"'` | `>= 1` |

**Escalation triggers:** device does not enter bootloader; device fails to
re-enumerate; any prompt to erase MCUboot.

## Verification task (always last)

### TV: Phase verification
**Owner:** qwen-verifier
**Inputs:** this plan + all `audit-*.md`
**Output:** `feature-research/own-stack/phase-report.md`
