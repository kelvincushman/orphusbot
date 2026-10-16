<!-- Copyright (c) 2025-2026 Kelvin Lee. Licensed under MIT. -->

# Firmware toolchain

Verified on macOS arm64, 2026-09-06. Produces `zephyr.uf2` from a clean tree
with **no source changes**.

## Two toolchains, on purpose

| | nRF Connect SDK 2.9.0 | Zephyr 4.4.2 (upstream) |
|---|---|---|
| Location | `~/dev/Developer-Caches/Nordic/ncs/v2.9.0` | `~/dev/zephyr/ws` |
| Builds today | **yes, unmodified** | no — needs source fixes |
| Binary blobs | ships `nrfxlib` (SoftDevice Controller) | none |
| Use for | building and flashing the current firmware | the own-stack rewrite target |

NCS is the baseline this firmware was written against, so it builds as-is.
Upstream Zephyr is where the rewrite lands, because it has no proprietary
blobs — which the open-source goal needs. Do not mix them.

## Board target

**`xiao_ble/nrf52840/sense`**

Both names previously in this repo were wrong:

- `xiao_ble_sense` — the hardware-model-v1 name. Zephyr 4.4.2 removed the
  deprecation alias, so it now fails with "board not found".
- `seeed_xiao_nrf52840_sense` — never a Zephyr board name. It is the UF2
  bootloader's `--board-id`, from `board.cmake`.

`firmware/devkit/CMakeLists.txt` still has `set(BOARD seeed_xiao_nrf52840_sense)`.
It does not override `-b` (CACHE scope wins), but it makes a bare `west build`
fail. Delete it when the file is next touched.

## Build (NCS 2.9.0)

Use the **real** paths. `/opt/nordic/ncs` is a symlink to the ExtHdd cache, and
mixing the two makes CMake emit a broken relative include for
`vector_table.ld`, failing at `linker_zephyr_pre0.cmd`.

```bash
B=~/dev/Developer-Caches/Nordic/ncs/toolchains/b8efef2ad5
export PATH="$B/bin:$PATH"
export ZEPHYR_BASE=~/dev/Developer-Caches/Nordic/ncs/v2.9.0/zephyr
export ZEPHYR_TOOLCHAIN_VARIANT=zephyr
export ZEPHYR_SDK_INSTALL_DIR="$B/opt/zephyr-sdk"

cd firmware/devkit
west build -b xiao_ble/nrf52840/sense -d build_kelvinlee --no-sysbuild -p always -- \
  -DCONF_FILE="prj_xiao_ble_sense_devkitv2-adafruit.conf;prj_wearable.conf" \
  -DDTC_OVERLAY_FILE="overlay/xiao_ble_sense_devkitv2-adafruit.overlay;overlay/wearable-peripherals.overlay"
```

For the soldered MicroSD stack, append `;prj_wearable_phase3_sd.conf` to `CONF_FILE`.

Use `-DCONF_FILE=`, **not** `-DEXTRA_CONF_FILE=` — `prj.conf` here is a stale
merged copy of the adafruit conf plus an obsolete SPI1-era delta, and
`EXTRA_CONF_FILE` would layer on top of it.

`--no-sysbuild` because `devkit/` has no `sysbuild.conf`.

### Expected output

```
FLASH:  296120 B / 788 KB   36.70%
RAM:    188064 B / 256 KB   71.74%
Wrote 592384 bytes to zephyr.uf2
```

**RAM is 71.7% used.** Opus, the BLE stack and the audio buffers dominate
256 KB. Any rewrite has little headroom; measure before adding buffers.

## Flash

The UF2 bootloader is entered by **double-tapping reset** — a physical action.
The 1200-baud touch does not work here: that is an Arduino/Adafruit bootloader
behaviour, and Zephyr's CDC stack does not implement it.

1. Double-tap the reset button. Volume `XIAO-SENSE` mounts.
2. `cp firmware/devkit/build_kelvinlee/zephyr/zephyr.uf2 /Volumes/XIAO-SENSE/`
3. The device reboots and re-enumerates. Confirm with:

```bash
ioreg -p IOUSB -w0 -l | grep '"USB Vendor Name" = "ZEPHYR"'
ls /dev/cu.usbmodem*
```

Recovery: the bootloader is untouched by a UF2 drag. If the image is bad,
double-tap reset again and drag a known-good `.uf2`.

Do not flash MCUboot or the bootloader as part of an app update.

## Upstream Zephyr 4.4.2 — known port work

Building against upstream needs these first (nrfx 3.x → 4.2.0, and BLE API):

| Where | Problem |
|---|---|
| `src/mic.c:29` | `NRFX_PDM_INSTANCE(0)` now takes a register address; compiles, then faults |
| `src/mic.c:80,83` | `.clock_freq` / `.ratio` moved into a nested `prescalers` struct |
| `src/mic.c` | nrfx returns plain `int` now, but `NRFX_SUCCESS` is `0x0BAD0000`, so `!= NRFX_SUCCESS` is always true and `mic_start()` fails **silently** |
| `src/mic.c:84` | `nrfx_pdm_0_irq_handler` removed |
| `src/mic.c:64` | `nrf_clock_hf_is_running` renamed |
| `src/transport.c:814,852` | `BT_LE_ADV_CONN` removed; use `BT_LE_ADV_CONN_FAST_2` |

Dead Kconfig symbols that abort the build (handwritten fragments are
`error_out = True`): `CONFIG_NRFX_PDM0` → `CONFIG_NRFX_PDM`;
`CONFIG_BT_CTLR_SDC_MAX_CONN_EVENT_LEN_DEFAULT` (NCS-only, delete);
`CONFIG_LOG_BACKEND_UART_OUTPUT_TEXT` (delete);
`CONFIG_KELVINLEE_OFFLINE_STORAGE` (typo for `..._ENABLE_OFFLINE_STORAGE`).
