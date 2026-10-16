<!-- Copyright (c) 2025-2026 Kelvin Lee. Licensed under MIT. -->

# Scout: board target reconciliation (Zephyr v4.4.2 / XIAO nRF52840 Sense)

**Date:** 2026-09-06
**Trees inspected (read-only):**
- `~/dev/zephyr/ws/zephyr` — upstream Zephyr, git tag `v4.4.2`, commit `dccb0959963`, `VERSION` = 4.4.2
- `~/dev/zephyr/ws/modules/hal/nordic` — nrfx **4.2.0** (`CHANGELOG.md` `## [4.2.0] - 2026-03-12`)
- `~/dev/zephyr/zephyr-sdk-1.0.1` — has `gnu/arm-zephyr-eabi/bin/arm-zephyr-eabi-gcc`
- `~/dev/Developer-Caches/Nordic/ncs/v2.9.0` (via `/opt/nordic/ncs`) — **a complete nRF Connect SDK v2.9.0 tree already exists on this machine**, Zephyr 3.7.99 + nrfx 3.x. Used here purely as the "what the firmware was written against" reference.

---

## 0. Verdict in one line

The board target is **`xiao_ble/nrf52840/sense`**. Both names currently in the repo are wrong for v4.4.2, and *fixing the name is not sufficient* — the firmware is written against nRF Connect SDK 2.9 (Zephyr 3.7 / nrfx 3.x) and hits **2 fatal Kconfig errors and 4 source-level API breakages** on upstream Zephyr 4.4.2.

---

## 1. The exact board target

`~/dev/zephyr/ws/zephyr/boards/seeed/xiao_ble/board.yml`:

```yaml
board:
  name: xiao_ble
  full_name: XIAO BLE (Sense)
  vendor: seeed
  socs:
  - name: nrf52840
    variants:
    - name: 'sense'
```

Valid board targets in v4.4.2:

| Target | Files | Use |
|---|---|---|
| `xiao_ble` / `xiao_ble/nrf52840` | `xiao_ble.dts`, `xiao_ble_defconfig`, `xiao_ble.yaml` (`identifier: xiao_ble`) | non-Sense XIAO BLE. **No PDM mic, no IMU.** |
| **`xiao_ble/nrf52840/sense`** | `xiao_ble_nrf52840_sense.dts`, `xiao_ble_nrf52840_sense_defconfig`, `xiao_ble_nrf52840_sense.yaml` (`identifier: xiao_ble/nrf52840/sense`) | **This is ours.** |

No board revisions are defined, so no `@rev` suffix.

### Where the two wrong names came from

| String in repo | What it actually is | Status in v4.4.2 |
|---|---|---|
| `xiao_ble_sense` (`docs/BUILD_FIRMWARE.md`, `firmware/devkit/CMakePresets.json`, header comments in `prj_wearable.conf` and `overlay/wearable-peripherals.overlay`) | the **hardware-model-v1** board name (Zephyr ≤ 3.6 / NCS ≤ 2.6) | **Removed.** NCS 2.9's `boards/deprecated.cmake` still had `set(xiao_ble_sense_DEPRECATED xiao_ble/nrf52840/sense)`. In v4.4.2 `boards/deprecated.cmake` has **no `xiao_ble` entry at all** — the alias was dropped. `-b xiao_ble_sense` now fails with "board not found". |
| `seeed_xiao_nrf52840_sense` (`firmware/devkit/CMakeLists.txt:2`) | the **UF2 bootloader board-id**, not a Zephyr board. `boards/seeed/xiao_ble/board.cmake` line: `board_runner_args(uf2 "--board-id=Seeed_XIAO_nRF52840_Sense")` | Never was a Zephyr board name, in any Zephyr version. Present since the original subtree import (`a913293`). |

### Does `set(BOARD ...)` in CMakeLists.txt override `west build -b`?

**No** — but only because of scope ordering, and it *does* break a bare `west build`.

`cmake/modules/boards.cmake` calls `zephyr_check_cache(BOARD REQUIRED)`, which on a pristine build dir defers to `zephyr_get(BOARD)`. `cmake/modules/extensions.cmake:3367`:

```cmake
set(scopes "sysbuild_local;sysbuild_global;CACHE;snippets;ENV;current")
```

First non-empty scope wins (`return()` at line 3401). `-b <target>` lands in **CACHE**; the app's `set(BOARD ...)` lands in **current**. CACHE is checked first, so `-b` wins.

Consequence: `set(BOARD seeed_xiao_nrf52840_sense)` is dead weight *if* `-b` is always passed, and a hard failure the moment anyone runs plain `west build`. It should be deleted (recommended) or corrected to `xiao_ble/nrf52840/sense`.

---

## 2. Peripheral support — proof from the v4.4.2 DTS

All quotes from `boards/seeed/xiao_ble/` and `dts/arm/nordic/nrf52840.dtsi`.

### PDM microphone — present, **disabled by default**, pins fixed

`dts/arm/nordic/nrf52840.dtsi:416`:
```dts
pdm0: pdm@4001d000 {
    compatible = "nordic,nrf-pdm";
    reg = <0x4001d000 0x1000>;
    interrupts = <29 NRF_DEFAULT_IRQ_PRIORITY>;
    status = "disabled";
};
```

`xiao_ble_nrf52840_sense.dts` adds pinctrl + clock source but **does not set `status = "okay"`**:
```dts
&pdm0 {
    pinctrl-0 = <&pdm0_default>;
    pinctrl-1 = <&pdm0_sleep>;
    pinctrl-names = "default", "sleep";
    clock-source = "PCLK32M";
};
```

`xiao_ble-pinctrl.dtsi`:
```dts
pdm0_default: pdm0_default {
    group1 {
        psels = <NRF_PSEL(PDM_CLK, 1, 00)>,
                <NRF_PSEL(PDM_DIN, 0, 16)>;
    };
};
```
P1.00 = CLK, P0.16 = DIN — matches `src/config.h` / `docs/PIN_MAP.md`.

Mic power rail is on the board too (`xiao_ble_nrf52840_sense.dts`):
```dts
msm261d3526hicpm-c-en {
    compatible = "regulator-fixed";
    enable-gpios = <&gpio1 10 (NRF_GPIO_DRIVE_S0H1 | GPIO_ACTIVE_HIGH)>;
    regulator-name = "MSM261D3526HICPM-C-EN";
};
```
Note this is **P1.10**, and the firmware drives the mic rail itself via raw `nrfy_gpio` on `PDM_PWR_PIN` (`src/mic.c`). Two owners of the same rail is pre-existing, and `CONFIG_REGULATOR=y` *is* in `xiao_ble_nrf52840_sense_defconfig` — so the board's `regulator-fixed` will also be built. Worth watching if the mic-silence bug reappears.

**Correction to a stale comment:** `overlay/wearable-peripherals.overlay` claims "the Xiao Sense board DTS leaves `&pdm0` ENABLED". It does not — it is `status = "disabled"` in both NCS 2.9 and v4.4.2. The overlay's `&pdm0 { status = "disabled"; }` is therefore a harmless no-op, and the mic-silence root cause attributed to it in the comment was mis-diagnosed.

### SPI — three usable controllers

`nrf52840.dtsi:477` `spi2: spi@40023000`, `nrf52840.dtsi:551` `spi3: spi@4002f000 { compatible = "nordic,nrf-spim"; ... status = "disabled"; }`.

`xiao_ble_common.dtsi` enables spi2 for the XIAO header:
```dts
&spi2 {
    compatible = "nordic,nrf-spi";
    status = "okay";
    pinctrl-0 = <&spi2_default>;   /* SCK P1.13, MOSI P1.15, MISO P1.14 */
    ...
};
```
→ SD card path (D8/D9/D10) is native to the board. `spi3` is disabled by default and free for the NeoPixel — and the overlay's justification still holds in v4.4.2, because `xiao_ble_common.dtsi` still enables i2c1 with the comment `/* Cannot be used together with spi1. */`.

`zephyr,sdhc-spi-slot` and `zephyr,sdmmc-disk` bindings both still exist (`dts/bindings/sdhc/zephyr,sdhc-spi-slot.yaml`, `dts/bindings/sd/zephyr,sdmmc-disk.yaml`).

### PWM — enabled by default

`xiao_ble_common.dtsi`:
```dts
&pwm0 {
    status = "okay";
    pinctrl-0 = <&pwm0_default>;   /* PWM_OUT0 on P0.17 (charge LED), nordic,invert */
    pinctrl-1 = <&pwm0_sleep>;
    pinctrl-names = "default", "sleep";
};
```
The board also declares `pwm_led0` on `&pwm0 0`. `overlay/wearable-peripherals.overlay` re-points `pinctrl-0` to `pwm0_wearable_motor` (PWM_OUT0 → P0.03) and adds a **second** `pwm-leds` node. That means two `pwm-leds` nodes both claiming `&pwm0` channel 0, and the board's `pwm_led0` (P0.17) silently moves to P0.03. Not fatal, but it is why `CONFIG_LED_PWM` had to stay off (see the comment in `src/speaker.c:53`).

### USB CDC-ACM — **stack changed under us**

NCS 2.9 (`xiao_ble_defconfig`):
```
CONFIG_USB_DEVICE_STACK=y
CONFIG_USB_CDC_ACM_LOG_LEVEL_OFF=y
```
plus `zephyr,console = &usb_cdc_acm_uart` in `xiao_ble_common.dtsi`.

v4.4.2 — both lines are **gone from the defconfig**. Instead `xiao_ble_common.dtsi` ends with:
```dts
zephyr_udc0: &usbd {
    compatible = "nordic,nrf-usbd";
    status = "okay";
};

#include <../boards/common/usb/cdc_acm_serial.dtsi>
```
and `Kconfig.defconfig` is now just `source "boards/common/usb/Kconfig.cdc_acm_serial.defconfig"`, which sets:
```
config USB_DEVICE_STACK_NEXT
	default y if !MCUBOOT
config CDC_ACM_SERIAL_INITIALIZE_AT_BOOT
	default y if !MCUBOOT
```

So the board defaults to the **USB-D ("next") stack**. The legacy stack still exists (`subsys/usb/device/Kconfig:6 menuconfig USB_DEVICE_STACK`) but carries `select DEPRECATED`. Headers `include/zephyr/usb/usb_device.h` and `include/zephyr/drivers/usb/usb_dc.h` are both still present, so `src/usb.c` still *compiles*. It will not *link* unless `CONFIG_USB_DEVICE_STACK=y` is added — and today it survives only because `CONFIG_KELVINLEE_ENABLE_USB=n` in the phase confs makes `init_usb()` unreferenced and `--gc-sections` drops it.

The DT node label also changed: `usb_cdc_acm_uart` → `board_cdc_acm_uart`. Nothing in the firmware references it, so no breakage today.

### BLE — controller selection moved to devicetree

`nrf52840.dtsi:131`:
```dts
bt_hci_controller: bt_hci_controller {
    compatible = "zephyr,bt-hci-ll-sw-split";
    status = "okay";
};
```
and `subsys/bluetooth/controller/Kconfig:143`:
```
config BT_LL_SW_SPLIT
	bool "Software-based Bluetooth LE Link Layer"
	default y
	depends on DT_HAS_ZEPHYR_BT_HCI_LL_SW_SPLIT_ENABLED
	select HAS_BT_CTLR
```
There is **no `config BT_CTLR` symbol at all** in v4.4.2 (NCS 2.9's `xiao_ble/Kconfig.defconfig` had `config BT_CTLR default BT`; that block is gone). `CONFIG_BT=y` alone is now enough. None of our confs set `CONFIG_BT_CTLR`, so nothing to change — but see §4 for the TX-power fallout.

### Flash layout

`xiao_ble_common.dtsi` now pulls partitions from a shared file, `#include <nordic/nrf52840_partition_uf2_sdv7.dtsi>`. Same addresses as before (code @ 0x27000, 788 kB; storage @ 0xec000; UF2 boot @ 0xf4000) but partition **labels** changed: `code_partition` → label `"Application"` (was `"code_partition"`), `boot_partition` → `"UF2"` (was `"adafruit_boot"`). Also the `bootloader-led0` alias was dropped. Nothing in the firmware uses these.

### Summary table

| Need | v4.4.2 status | Action |
|---|---|---|
| PDM mic | node present, `status="disabled"`, pinctrl P1.00/P0.16 correct | none (firmware drives raw nrfx) |
| SPI (SD card) | `spi2` okay, P1.13/15/14 | none |
| SPI (NeoPixel) | `spi3` (SPIM) disabled → free | none, overlay enables it |
| PWM (haptic) | `pwm0` okay | none |
| USB CDC-ACM | switched to `USB_DEVICE_STACK_NEXT` | see §4/§5 — only bites if USB is re-enabled |
| BLE | `zephyr,bt-hci-ll-sw-split`, `BT_LL_SW_SPLIT=y` by default | none, but TX-power symbol no longer applies |
| IMU (LSM6DS3TR-C) | `&i2c0` okay with `st,lsm6dsl` @0x6a | none |

**Nothing our firmware needs is missing from the board.**

---

## 3. Overlay audit

`firmware/devkit/overlay/` — 6 files. All are written in **hwmv2-neutral** devicetree: they only use node labels (`&i2s0`, `&spi2`, `&spi3`, `&pwm0`, `&pinctrl`, `&i2c0`, `&i2c1`, `&temp`, `&uart0`, `&pdm0`) and no board-name-derived paths. **Nothing in the overlay bodies needs to change for hwmv2.** The only stale bits are naming in comments.

| File | Verdict |
|---|---|
| `wearable-peripherals.overlay` | **Bodies OK.** All node labels exist in v4.4.2. `INPUT_KEY_0`, `GPIO_PULL_UP`, `PWM_MSEC`, `NRF_PSEL` all resolve — `dts/vendor/nordic/nrf_common.dtsi` includes `input-event-codes.h`, `gpio.h`, `pwm.h`, `nrf-pinctrl.h`, so the overlay's lone `#include <zephyr/dt-bindings/led/led.h>` is sufficient. `worldsemi,ws2812-spi` binding unchanged (requires `spi-one-frame`/`spi-zero-frame`, both present). **Header comment is stale**: says `west build -b xiao_ble_sense`. **Body comment is wrong**: the `&pdm0` block claims the board leaves pdm0 enabled; it does not (§2). |
| `wearable-bare-xiao.overlay` | OK. Disables `&led_strip`, `&iot_button`, `&vibration_pwm` — all defined by `wearable-peripherals.overlay`, so it must be layered after it (as documented in the file). |
| `wearable-no-led-strip.overlay` | OK, same constraint. |
| `xiao_ble_sense_devkitv2-adafruit.overlay` | OK. Uses `label = "I2S_0"` / `"SDHC_0"` / `"b"` — `label` is still accepted (`dts/bindings/base/base.yaml:126`, marked deprecated). Re-declares `lsm6ds3tr_c@6a` under `&i2c0` on top of the board's own declaration; merges cleanly. |
| `xiao_ble_sense_devkitv1.overlay` | Comment-only, no-op. |
| `xiao_ble_sense_devkitv1-spisd.overlay` | OK (not in our build path). |

Two low-risk items worth knowing:
- `&spi3 { /delete-property/ cs-gpios; }` deletes a property that `nrf52840.dtsi` never defines. dtc treats delete-of-absent as a no-op — harmless, but it is noise.
- The filenames themselves (`xiao_ble_sense_devkitv*.overlay`) encode the dead hwmv1 board name. Renaming is cosmetic; I did **not** rename anything.

---

## 4. Kconfig audit — symbols that no longer exist in v4.4.2

### Why this is fatal, not cosmetic

`scripts/kconfig/kconfig.py` sets `kconf.warn_assign_undef = True` for handwritten fragments (line 57), then at line 110:

```python
warn_only = r"warning:.*set more than once."
if kconf.warnings:
    if args.forced_input_configs:
        error_out = False
    else:
        error_out = True      # <- unconditional for handwritten fragments
    ...
    if error_out:
        err("Aborting due to Kconfig warnings")
```

So **any assignment to an undefined `CONFIG_` symbol aborts the build**. (`check_assigned_sym_values` uses the script's own `warn()`, line 385, which only prints to stderr — those are *not* fatal.)

### Machine-checked result

Every `CONFIG_*` in every `firmware/devkit/prj*.conf` was cross-referenced against all 20 123 symbols defined by `Kconfig*` files in the v4.4.2 tree, plus the 8 `KELVINLEE_*` symbols in `firmware/devkit/Kconfig`:

| Conf file | Undefined symbol | Severity | Replacement |
|---|---|---|---|
| `prj.conf`, `prj_xiao_ble_sense_devkitv2-adafruit.conf` | `CONFIG_NRFX_PDM0` | **FATAL** | `CONFIG_NRFX_PDM=y` |
| `prj.conf`, `prj_xiao_ble_sense_devkitv2-adafruit.conf` | `CONFIG_BT_CTLR_SDC_MAX_CONN_EVENT_LEN_DEFAULT` | **FATAL** | **none** — delete the line (see below) |
| `prj_xiao_ble_sense_devkitv1.conf`, `prj_xiao_ble_sense_devkitv1-spisd.conf` | `CONFIG_LOG_BACKEND_UART_OUTPUT_TEXT` | FATAL (not in our build path) | delete — text is the default; only `LOG_BACKEND_UART_OUTPUT_DICTIONARY{,_BIN,_HEX}` remain |
| `prj_xiao_ble_sense_devkitv1-spisd.conf` | `CONFIG_KELVINLEE_OFFLINE_STORAGE` | FATAL (not in our build path) | typo for `CONFIG_KELVINLEE_ENABLE_OFFLINE_STORAGE` — already flagged in `plan.md` T0.3 |

`prj_wearable.conf`, `prj_wearable_phase2.conf`, `prj_wearable_phase3_sd.conf`, `prj_wearable_bare_xiao.conf` are **all clean**. No promptless-symbol assignments anywhere in the build path (those would also be fatal, via `check_no_promptless_assign`).

### `CONFIG_NRFX_PDM0` — why it vanished

NCS 2.9 (`zephyr/modules/hal_nordic/nrfx/Kconfig:254`):
```
config NRFX_PDM
	bool
config NRFX_PDM0
	bool "PDM0 driver instance"
	depends on $(dt_nodelabel_has_compat,pdm0,$(DT_COMPAT_NORDIC_NRF_PDM))
	select NRFX_PDM
```
v4.4.2 (`modules/hal_nordic/nrfx/Kconfig:176`):
```
config NRFX_PDM
	bool "PDM driver"
```
Upstream collapsed the per-instance layer wholesale: NCS 2.9 defines **193** `NRFX_<PERIPH><N>` symbols, v4.4.2 defines **10**. Instances are now derived from devicetree alone. `nrfx_kconfig.h:209` maps `CONFIG_NRFX_PDM` → `NRFX_PDM_ENABLED`; there is no `NRFX_PDM0_ENABLED` path any more.

### `CONFIG_BT_CTLR_SDC_MAX_CONN_EVENT_LEN_DEFAULT` — wrong SDK entirely

This is a **Nordic SoftDevice Controller** symbol from `nrfxlib`, which ships only in nRF Connect SDK. `grep -rn "BT_CTLR_SDC" ws/zephyr/subsys/` returns nothing. Upstream Zephyr on nRF52840 uses the open-source `BT_LL_SW_SPLIT` link layer, which has no equivalent knob. Delete the line.

### Non-fatal but silently ineffective

`CONFIG_BT_CTLR_TX_PWR_ANTENNA=8` — still defined (`subsys/bluetooth/controller/Kconfig:527`) but:
```
config BT_CTLR_TX_PWR_ANTENNA
	int "Set TX power (dBm)"
	depends on !BT_LL_SW_SPLIT
```
With upstream Zephyr, `BT_LL_SW_SPLIT=y`, so this dependency is unmet. It will print a `was assigned the value '8' but got the value '0'` warning (non-fatal) and **the +8 dBm TX power will not be applied**. Under the SW split controller the equivalent is the `BT_CTLR_TX_PWR_*` choice, e.g. `CONFIG_BT_CTLR_TX_PWR_PLUS_8=y`.

Expect a similar cosmetic warning for `CONFIG_I2C=n`, which the LSM6DSL driver force-`select`s back on.

---

## 5. Source-level breakage — nrfx 3.x → 4.2.0 and Zephyr host API

The confs were the easy part. These are compile/runtime failures the Kconfig audit will not catch.

### 5.1 `src/mic.c` — PDM instance address (silent hard fault)

nrfx 4.2 `drivers/include/nrfx_pdm.h:197`:
```c
#define NRFX_PDM_INSTANCE(reg)    \
{                                 \
    .p_reg = (NRF_PDM_Type *)reg, \
    .cb = {0}                     \
}
```
The argument is now a **register address**, not an instance index. Zephyr's own driver uses `NRFX_PDM_INSTANCE(DT_INST_REG_ADDR(inst))`. `mic.c:29` has `NRFX_PDM_INSTANCE(0)` → `p_reg = NULL` → compiles fine, hard-faults on first register write.
Fix: `NRFX_PDM_INSTANCE(NRF_PDM_BASE)` or `NRFX_PDM_INSTANCE(DT_REG_ADDR(DT_NODELABEL(pdm0)))`.

### 5.2 `src/mic.c` — config fields moved (compile error)

nrfx 4.2 `nrfx_pdm_config_t` (`nrfx_pdm.h:84`) no longer has top-level `clock_freq` or `ratio`; they moved into a nested `nrfx_pdm_prescalers_t prescalers`:
```c
typedef struct {
#if NRF_PDM_HAS_PDMCLKCTRL
    nrf_pdm_freq_t    clock_freq;
#elif NRF_PDM_HAS_PRESCALER
    uint32_t          prescaler;
#endif
#if NRF_PDM_HAS_RATIO_CONFIG
    nrf_pdm_ratio_t   ratio;
#endif
} nrfx_pdm_prescalers_t;
```
`mic.c` sets `pdm_config.clock_freq = NRF_PDM_FREQ_1280K;` and `pdm_config.ratio = NRF_PDM_RATIO_80X;` → **two compile errors**.
Fix: `pdm_config.prescalers.clock_freq = ...; pdm_config.prescalers.ratio = ...;`

### 5.3 `src/mic.c` — return convention flipped (silent, always-fails)

nrfx 4.2 signatures are plain `int` returning 0 on success:
```c
int nrfx_pdm_init(nrfx_pdm_t *, nrfx_pdm_config_t const *, nrfx_pdm_event_handler_t);
int nrfx_pdm_start(nrfx_pdm_t *);
int nrfx_pdm_buffer_set(nrfx_pdm_t *, int16_t *, uint16_t);
```
But `NRFX_SUCCESS == 0x0BAD0000` (`drivers/nrfx_errors.h:51,58`). `mic.c` tests `if (nrfx_pdm_init(...) != NRFX_SUCCESS)` and `if (nrfx_pdm_start(...) != NRFX_SUCCESS)` — both are now **always true**, so `mic_start()` always returns `-1`, `main()` blinks red+green and bails. Zero audio, no obvious error.
Fix: compare against `0`.

### 5.4 `src/mic.c` — IRQ handler renamed (link error)

nrfx 4.2 exports only `void nrfx_pdm_irq_handler(nrfx_pdm_t *p_instance);` (`nrfx_pdm.h:347`). There is **no `nrfx_pdm_0_irq_handler`**. `mic.c:84`:
```c
IRQ_DIRECT_CONNECT(PDM_IRQn, 5, nrfx_pdm_0_irq_handler, 0); // IMPORTANT!
```
`IRQ_DIRECT_CONNECT` also cannot pass the instance pointer the new handler needs.
Fix: `IRQ_CONNECT(DT_IRQN(DT_NODELABEL(pdm0)), 5, nrfx_pdm_irq_handler, &pdm_instance, 0); irq_enable(DT_IRQN(DT_NODELABEL(pdm0)));` — matching `drivers/audio/dmic_nrfx_pdm.c:510`.

### 5.5 `src/mic.c` — clock HAL renamed (compile error)

nrfx 3.x had `nrf_clock_hf_is_running(NRF_CLOCK_Type const *, nrf_clock_hfclk_t)`. nrfx 4.2 (`hal/nrf_clock.h:713`) has:
```c
NRF_STATIC_INLINE bool nrf_clock_is_running(NRF_CLOCK_Type const * p_reg,
                                            nrf_clock_domain_t     domain,
                                            void *                 p_clk_src);
```
`mic.c:64` calls `nrf_clock_hf_is_running(NRF_CLOCK, NRF_CLOCK_HFCLK_HIGH_ACCURACY)` → undefined.
Fix: `nrf_clock_hfclk_t src; if (!nrf_clock_is_running(NRF_CLOCK, NRF_CLOCK_DOMAIN_HFCLK, &src) || src != NRF_CLOCK_HFCLK_HIGH_ACCURACY) { ... }`

### 5.6 `src/transport.c` — `BT_LE_ADV_CONN` removed (compile error, ×2)

`include/zephyr/bluetooth/bluetooth.h` in v4.4.2 defines only `BT_LE_ADV_CONN_DIR`, `BT_LE_ADV_CONN_FAST_1`, `BT_LE_ADV_CONN_FAST_2`, `BT_LE_ADV_CONN_DIR_LOW_DUTY`. Plain `BT_LE_ADV_CONN` is gone. Used at `transport.c:814` and `transport.c:852`.
Fix: `BT_LE_ADV_CONN_FAST_2` — same 100–150 ms interval the old macro used.

### 5.7 `src/usb.c` — legacy stack, deferred risk

Compiles (headers survive) but will not link without `CONFIG_USB_DEVICE_STACK=y`, which now conflicts with the board's default `USB_DEVICE_STACK_NEXT=y` and pulls `select DEPRECATED`. Safe **only** while `CONFIG_KELVINLEE_ENABLE_USB=n`. Porting `usb.c` to the USB-D stack (`usbd_*`) is required before USB charge-detect can be re-enabled.

APIs that were checked and are **fine**: `nrfy_gpio_cfg_output` / `_pin_set` / `_pin_clear` (`haly/nrfy_gpio.h:94,156,163`), `nrf_clock_task_trigger`, `nrf_gpio_cfg_sense_set`, `NRF_GPIO_PIN_MAP`, `led_strip_update_rgb`, `device_get_binding`, all `bt_gatt_*` / `bt_conn_*` used.

---

## 6. Verdict — the build command

### Environment (once per shell)

```bash
source ~/dev/zephyr/venv/bin/activate
export ZEPHYR_BASE=~/dev/zephyr/ws/zephyr
export ZEPHYR_TOOLCHAIN_VARIANT=zephyr
export ZEPHYR_SDK_INSTALL_DIR=~/dev/zephyr/zephyr-sdk-1.0.1
```

`ZEPHYR_BASE` is load-bearing twice over: `firmware/devkit/CMakeLists.txt` does `find_package(Zephyr REQUIRED HINTS $ENV{ZEPHYR_BASE})`, and `west` needs it to locate the workspace from a cwd outside it (`west/app/main.py:253` — `west_topdir()` "falls back on searching from ZEPHYR_BASE"). With it set, running from the app directory works.

### The command

Run **from `firmware/devkit/`**:

```bash
west build -b xiao_ble/nrf52840/sense -d build_wearable --no-sysbuild -p always -- \
  -DCONF_FILE="prj_xiao_ble_sense_devkitv2-adafruit.conf;prj_wearable.conf" \
  -DDTC_OVERLAY_FILE="overlay/xiao_ble_sense_devkitv2-adafruit.overlay;overlay/wearable-peripherals.overlay"
```

For the actually-soldered stack (MicroSD BFF + IoT Button/NeoPixel BFF), add the phase-3 layer:

```bash
west build -b xiao_ble/nrf52840/sense -d build_phase3_sd --no-sysbuild -p always -- \
  -DCONF_FILE="prj_xiao_ble_sense_devkitv2-adafruit.conf;prj_wearable.conf;prj_wearable_phase3_sd.conf" \
  -DDTC_OVERLAY_FILE="overlay/xiao_ble_sense_devkitv2-adafruit.overlay;overlay/wearable-peripherals.overlay"
```

Deltas from `docs/BUILD_FIRMWARE.md`:
- `-b xiao_ble_sense` → **`-b xiao_ble/nrf52840/sense`**
- `--sysbuild` → **`--no-sysbuild`**. `firmware/devkit/` has no `sysbuild.conf` or `Kconfig.sysbuild` (unlike `firmware/kelvinlee/` and `firmware/test/`, which do). Upstream west already defaults to no sysbuild (`build.py:666`, `config_getboolean('sysbuild', False)`) — passing it explicitly documents the intent and guards against a stray `west config build.sysbuild true`.
- `-p always` added: `BOARD` is cached by `zephyr_check_cache`, so a non-pristine rebuild after a board-name change silently keeps the old value and prints only a warning.
- Use `-DCONF_FILE=` (not `-DEXTRA_CONF_FILE=`). `prj.conf` is auto-picked as the base when `CONF_FILE` is absent, and **`prj.conf` in this repo is a stale merged copy** of `prj_xiao_ble_sense_devkitv2-adafruit.conf` plus an obsolete SPI1-era Wearable delta (wrong device name, missing `CONFIG_SPI=y`). Explicit `CONF_FILE` bypasses it. This also means the `-DEXTRA_CONF_FILE=` recipe in `CLAUDE.md` and in the header of `overlay/wearable-peripherals.overlay` is the wrong one to follow.

### Prerequisites before that command can succeed

Ordered, each is required:

1. **`west update` must finish.** As of writing it is still fetching modules (`~/dev/zephyr/update.log`; sentinel `~/dev/zephyr/west.status` not yet written). `modules/hal/nordic` is present; `hal_nxp`, `mbedtls`, `tinycrypt` etc. are not. Then `west zephyr-export` + `pip install -r zephyr/scripts/requirements.txt` (already scripted in the same shell job).
2. **`firmware/devkit/CMakeLists.txt:2`** — delete `set(BOARD seeed_xiao_nrf52840_sense)` (or set it to `xiao_ble/nrf52840/sense`).
3. **`prj_xiao_ble_sense_devkitv2-adafruit.conf`** — `CONFIG_NRFX_PDM0=y` → `CONFIG_NRFX_PDM=y`; delete `CONFIG_BT_CTLR_SDC_MAX_CONN_EVENT_LEN_DEFAULT=400000`. (Same two edits in `prj.conf` if it is kept.)
4. **`src/mic.c`** — the five nrfx 4.2 fixes in §5.1–§5.5.
5. **`src/transport.c`** — `BT_LE_ADV_CONN` → `BT_LE_ADV_CONN_FAST_2` at lines 814 and 852.

Items 4 and 5 violate `plan.md` T0.3's "change no source" acceptance criterion. That criterion assumed an NCS 2.9 toolchain. On upstream Zephyr 4.4.2 it is unsatisfiable, and T0.3's own escalation trigger ("any source change appears necessary to compile") has fired.

### Risks I expect to hit, in order

| # | Risk | Likelihood | Detection |
|---|---|---|---|
| 1 | Kconfig aborts on the two undefined symbols | **certain** | `error: Aborting due to Kconfig warnings` at configure time |
| 2 | `mic.c` compile errors (`clock_freq`, `ratio`, `nrf_clock_hf_is_running`) | **certain** | compile |
| 3 | `transport.c` compile error on `BT_LE_ADV_CONN` ×2 | **certain** | compile |
| 4 | `nrfx_pdm_0_irq_handler` link error | **certain** | link |
| 5 | `NRFX_SUCCESS` comparison — mic dead at runtime with no build error | **high**, and silent | red+green blink loop at boot, no BLE audio |
| 6 | `NRFX_PDM_INSTANCE(0)` NULL `p_reg` → hard fault in `nrfx_pdm_init` | **high**, and silent | device hangs/resets right after "Initializing microphone" |
| 7 | Opus vendored tree (193 files) + `-DOPUS_ARM_INLINE_ASM` against SDK 1.0.1's newer GCC | medium | compile warnings/errors in `src/lib/opus-1.2.1/` |
| 8 | TX power silently drops from +8 dBm to 0 dBm (`depends on !BT_LL_SW_SPLIT`) | **certain**, non-fatal | shorter BLE range; Kconfig stderr warning |
| 9 | SW-split link layer vs SoftDevice Controller: different throughput/latency at `CONFIG_BT_L2CAP_TX_MTU=498`, `BT_CTLR_DATA_LENGTH_MAX=251` | medium | audio stutter / dropped Opus frames on-device |
| 10 | Board `regulator-fixed` for the mic rail (P1.10) now also active (`CONFIG_REGULATOR=y` in the sense defconfig) alongside the firmware's raw `nrfy_gpio` control | medium | mic-silence regression |
| 11 | Two `pwm-leds` nodes both on `&pwm0` ch0; board's `pwm_led0` moves P0.17 → P0.03 | low | charge-LED PWM misbehaviour |
| 12 | `usb.c` link failure if `CONFIG_KELVINLEE_ENABLE_USB` is ever set back to `y` | low today | link |

### Strategic note

`feature-research/own-stack/plan.md` T0.2 specifies **nRF Connect SDK v2.9.x**, which matches the firmware's actual baseline — and **that tree already exists on this machine** at `~/dev/Developer-Caches/Nordic/ncs/v2.9.0` (symlinked from `/opt/nordic/ncs`), complete with `boards/seeed/xiao_ble`, nrfx 3.x, and nrfxlib. Building against it would need only the board-name fix (`xiao_ble/nrf52840/sense` — NCS 2.9 also accepts the deprecated `xiao_ble_sense` alias) and **zero source changes**.

Choosing upstream Zephyr v4.4.2 instead is defensible for the own-stack goal (no Nordic-proprietary nrfxlib, pure Apache-2.0), but it is a **port, not a build**, and Phase 0's "prove the toolchain without touching source" gate cannot be met on it. Worth an explicit decision before spending the port effort:
- **Path A — NCS 2.9.0 (on disk now):** fastest route to a flashed device; keeps SoftDevice Controller; leaves a Nordic-licensed blob in the stack.
- **Path B — upstream Zephyr 4.4.2:** aligns with the own-stack licensing goal; costs the 5 fixes above plus BLE-throughput re-validation with the SW split link layer.
