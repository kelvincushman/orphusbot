<!-- Copyright (c) 2025-2026 Kelvin Lee. Licensed under MIT. -->

# Wearable wearable — hardware setup & soldering guide

Step-by-step guide to assembling the Wearable wearable from loose BFF boards into a working device. Read end-to-end before heating the iron — soldering is one-way.

**Authoritative pin map:** `devices/wearable-kelvinlee/docs/PIN_MAP.md`. This doc is the physical-assembly walkthrough; the PIN_MAP is the source of truth for what each pin does.

---

## 1. Bill of materials

| Qty | Part | Role |
|---:|---|---|
| 1 | Seeed **XIAO nRF52840 Sense** | MCU, onboard PDM mic, 6-axis IMU, RGB LED |
| 1 | Adafruit **MicroSD BFF** (P/N 5881) | SPI2 SD card storage for offline audio |
| 1 | Adafruit **IoT Button + NeoPixel BFF** (P/N 5695) | A2 pushbutton (AGENT_REQUEST) + A3 WS2812 LED |
| 1 | LiPo battery, 250–500 mAh, 2-pin JST PH 2.0, ≥3.7 V nominal | Primary power |
| 1 (optional) | Vibration motor, 3 V coin-type (e.g. 1027 ERM, Adafruit 1201) | Haptic feedback |
| 2 sets | 2×7 female header pins, 2.54 mm pitch | BFF-to-Xiao stacking |
| short lengths | 28-26 AWG stranded hookup wire, 2 colors | Motor wiring |

**What is NOT in this build** (intentionally omitted from the upstream KelvinLee spec):
- Adafruit 5769 Audio BFF / I2S speaker — dropped, no on-device TTS in v1
- Triangle v2 CAD enclosure — Kelvin's build is bench-wire + heat-shrink, not the injection-molded shell

---

## 2. Tools

- Temperature-controlled soldering iron (~330 °C for lead-free)
- 0.5–0.8 mm lead-free solder with no-clean flux core
- Flush cutters
- Helping-hands or PCB vise
- Digital multimeter (DMM) — required for continuity + short checks before first boot
- Small magnifier / jeweler's loupe — to inspect BFF solder jumpers
- Anti-static mat or wrist strap (recommended — nRF52840 is sensitive)

---

## 3. Pre-flight checks (5 min, do first)

**3.1 — Verify XIAO orientation marks.** Look at the **top face** of the XIAO. The USB-C port is at one end; pin D0 is at the opposite end, on the **left** side when the USB is toward you. All pin-to-pin instructions below assume this orientation.

**3.2 — MicroSD BFF solder-jumper — CRITICAL.** The Adafruit MicroSD BFF ships with a solder jumper that selects which pin is used for SPI chip-select (CS). The firmware expects **CS on A0 (P0.02)**. If your BFF is set to the default (CS on D6/P1.11), you must:

- Locate the tiny solder-jumper labeled `CS` on the back of the MicroSD BFF
- Under a loupe, verify which of the two pads is bridged
- If needed: reflow the jumper so the **A0 pad** is bridged, not the D6 pad
- Double-check with DMM continuity: probe CS test-point ↔ A0 pin → should beep

If this is wrong, `mount_sd_card()` in firmware fails silently and the wearable won't boot past the boot LED sequence. This is a known-silent failure mode.

**3.3 — Check each board for factory shorts.** DMM to continuity mode. On each board individually (before stacking):
- 3V3 ↔ GND → must **not** beep (open)
- 3V3 ↔ any signal pin → must **not** beep
- GND ↔ any signal pin → should **not** beep unless the pin is intentionally tied to GND (rare)

If any of these beeps, stop and inspect visually — rare, but factory QC slips happen.

---

## 4. Stack order (bottom → top)

The BFFs stack under the XIAO using female headers; the XIAO's castellated edges drop onto them. Orientation matters:

```
┌───────────────────────────┐
│   XIAO nRF52840 Sense     │   ← top (USB-C faces away)
├───────────────────────────┤
│   IoT Button + NeoPixel   │   ← button + LED face up, through XIAO's holes
├───────────────────────────┤
│   MicroSD BFF             │   ← SD slot faces out the side
└───────────────────────────┘
```

**Why this order:**

- IoT Button + NeoPixel BFF must be **directly under the XIAO** so its LED + button can poke through or remain accessible. If the MicroSD BFF were in the middle, the button would be buried.
- MicroSD BFF is at the bottom so you can insert/eject cards without unstacking.

**Pin alignment:** every pin on the XIAO's 2×7 footprint lines up with the same-named pin on each BFF. Orientation is fixed by the USB-C port — if you try to rotate a BFF 180°, the pin labels will no longer line up.

---

## 5. Soldering the stack

### 5.1 — Dry-fit first
Before any solder, push the headers through all three boards without solder. Confirm:
- The stack is square (no skew when viewed from the side)
- The XIAO's USB-C port clears both BFFs (nothing blocks a USB cable)
- The MicroSD slot points outward, not into the body of the stack

### 5.2 — Solder the XIAO first
1. Place XIAO pins-up on a flat surface
2. Push 2×7 male headers through from the top (long leg up)
3. Solder each of the 14 pins on the **bottom** side (the side that will mate with the BFFs)
4. Inspect: joints should be shiny conical meniscus, not dull balls. Reflow any dull joints.

### 5.3 — Solder the IoT Button + NeoPixel BFF
1. Slide the BFF onto the XIAO's header pins (button + LED face **up**, toward the XIAO's top face)
2. Confirm the button is aligned with the XIAO (roughly center-top)
3. Solder the 14 pins on the BFF's bottom side
4. Flush-cut excess pin length — it will interfere with the next BFF otherwise

### 5.4 — Solder the MicroSD BFF
1. Slide this BFF onto the IoT Button BFF's remaining header pin stubs (if any) or a second set of headers
2. Orient: SD slot faces outward (typically opposite the USB-C port)
3. Solder the 14 pins
4. Flush-cut.

### 5.5 — Verify stack integrity (DMM continuity, each pin)
For every Xiao pin, probe XIAO top → MicroSD BFF bottom → should beep. If any pin is open, reflow the joint on both BFFs.

---

## 6. Pin-to-pin assignments (Kelvin's build)

Full detail: `devices/wearable-kelvinlee/docs/PIN_MAP.md`. Quick reference for soldering verification:

| XIAO pin label | nRF52840 GPIO | Connects to | Do you need to solder? |
|---|---|---|---|
| D0 / A0 | P0.02 | MicroSD BFF — **SPI2 CS** (solder-jumper required, §3.2) | No, via stacked header |
| D1 / A1 | P0.03 | *(optional)* Vibration motor + | **Yes, hand-wire only if using second motor** |
| D2 / A2 | P0.28 | IoT Button BFF — button input | No, via stacked header |
| D3 / A3 | P0.29 | IoT Button BFF — NeoPixel DIN | No, via stacked header |
| D4 / SDA | P0.04 | Onboard IMU I2C (already internal) | No |
| D5 / SCL | P0.05 | Existing primary button (onboard Xiao fn button) | No |
| D6 / TX | P1.11 | **Primary haptic motor +** (existing KelvinLee haptic channel) | **Yes, hand-wire** (see §7) |
| D7 / RX | P1.12 | Unused in v1 | No |
| D8 / SCK | P1.13 | MicroSD BFF — SPI2 SCK | No, via stacked header |
| D9 / MISO | P1.14 | MicroSD BFF — SPI2 MISO | No, via stacked header |
| D10 / MOSI | P1.15 | MicroSD BFF — SPI2 MOSI | No, via stacked header |
| 3V3 | — | Stack power rail (MicroSD + IoT BFF logic) | No, via header |
| GND | — | Stack ground | No, via header |
| VBAT (BAT+) | — | LiPo + (via onboard JST) | **Plug JST connector only — no solder** |
| VBAT- (BAT-) | — | LiPo − | Same |

**Interpretation:** out of 14 XIAO pins, only 2 require hand-soldering of external wires — the primary haptic motor on D6/P1.11 (mandatory) and the optional second motor on D1/P0.03. Everything else routes through the stacked BFF headers.

---

## 7. Hand-wiring the vibration motor

The firmware calls `play_haptic_milli()` from `devkit/src/speaker.c`, which drives **P1.11 (D6/TX on the XIAO)** as a GPIO output. A simple coin-cell ERM motor takes ~50–80 mA at 3 V — within the XIAO's GPIO source capability for short pulses (<250 ms).

**Wiring:**

```
  ┌──────────────┐
  │ Vibration    │────[red wire]──── XIAO D6/TX (P1.11)
  │ motor        │
  │ (ERM coin)   │────[black wire]── XIAO GND
  └──────────────┘
```

**Steps:**
1. Trim the motor's factory leads to ~30 mm
2. Tin the trimmed ends (flux + solder, ~2 mm of tinning)
3. Solder the **red/positive** lead to the XIAO's **D6/TX** castellated pad (or the through-hole under the stack if accessible)
4. Solder the **black/negative** lead to the nearest **GND** pad
5. Apply ~5 mm of 3 mm heat-shrink tubing over each joint
6. Reinforce with hot-glue or epoxy if the motor will see flex during wear

**Polarity matters only for bidirectional motors (not coin ERMs).** Coin ERM will spin either way; voice-coil LRA motors require specific polarity — consult the motor datasheet.

**Optional second motor on A1:** If you want two independent haptic channels, repeat the above wiring on **D1/A1 (P0.03)**. The firmware's `agent_commands.c::HAPTIC` op currently only drives P1.11; the A1 PWM hook is wired in the overlay but not yet routed in code. Solder it in only if you plan to extend `agent_commands.c`.

---

## 8. Battery

The XIAO nRF52840 Sense has two small solder pads on its underside labeled **BAT+** and **BAT−** (or a JST PH 2.0 footprint depending on the board revision — check yours). 

- **If your XIAO has a JST PH 2.0 connector pre-soldered:** plug the battery in directly. Polarity is keyed.
- **If your XIAO has only solder pads:** solder a 2-pin JST PH 2.0 pigtail first, matching the battery's polarity. **Red → BAT+, Black → BAT−.** Reversing this destroys the XIAO's protection FET instantly.

**Battery charging** is handled onboard by the XIAO's BQ25101 — connect a USB-C cable to the XIAO and the onboard CHARGE LED (amber) lights during charge, off when full.

**Do not exceed 500 mAh** unless you know your exact charge settings. The default charge current is 50 mA — safe but slow for larger cells.

---

## 9. Post-solder verification (DMM, before first power)

Before plugging in USB for the first time:

**9.1 — No rails shorted.** Unpowered stack, DMM continuity:
- 3V3 ↔ GND → must **not** beep
- VBAT ↔ GND → must **not** beep  (unless the battery is plugged in — remove battery during this test)
- 3V3 ↔ VBAT → must **not** beep

If any of these beep, stop and inspect — you likely have a solder bridge between adjacent pins. Reflow the suspect area.

**9.2 — Each functional pin traces from XIAO to BFF end.** Pick 3–4 pins at random (say A0, A2, D8, D10) and confirm continuity from the XIAO's pin through the stack to the BFF's endpoint connector.

**9.3 — MicroSD CS on A0 (repeat of §3.2).** Probe the MicroSD BFF's CS test point ↔ XIAO A0 → must beep. If it doesn't beep but CS ↔ D6 does, you didn't reflow the solder jumper — go back to §3.2.

**9.4 — Motor polarity and resistance.** Probe the motor leads where they meet the XIAO pads:
- D6 (P1.11) ↔ motor+ → beep
- GND ↔ motor− → beep
- Motor+ ↔ motor− → read ~8–25 Ω (not zero, not infinite — a coin ERM has a tiny DC winding)

---

## 10. First power-on — what to expect

**Connect USB-C** to the XIAO. **Do NOT yet plug the battery** — first power-on should be USB-only so you can watch for smoke and pull the cable quickly if needed.

Expected sequence over the first ~5 seconds:

1. **Boot LED sequence** (built in, `devkit/src/main.c::boot_led_sequence`):
   - Red ~0.6 s
   - Green ~0.6 s  
   - Blue ~0.6 s
   - All three on ~0.6 s
   - All off
2. **Init log via USB-CDC serial** — connect `screen /dev/tty.usbmodem* 115200` in another terminal to see:
   - `Booting...`
   - `Model: Wearable KelvinLee DK2`
   - `Firmware revision: wearable-0.1.0+dk2-2.0.10`
   - `Initializing LEDs...` → `LEDs initialized`
   - `Battery initialized`
   - `Button initialized`
   - `Mount SD card...` → (if jumper correct) `SD card mounted`
   - `Initializing haptic...` → `Haptic pin initialized`
   - `Initializing transport...` → (BLE stack up, advertising starts)
   - `Initializing codec...` / `Initializing microphone...`
   - `Device initialized successfully`
3. **Brief blue LED pulse** (the "ready" indicator, ~1 s)
4. Then either off or colored per `set_led_state()` logic (RED if not connected to a phone, BLUE while connected + recording)

**If the boot sequence stops partway:**

| Stuck at | Meaning | Check |
|---|---|---|
| Red/Green/Blue cycle never starts | Firmware didn't reach `led_start()` | Is USB enumerating as `/dev/tty.usbmodem*`? If not, reflash the UF2. |
| Completes LED sequence, then dark (no further progress) | `mount_sd_card()` is hard-failing | Re-check §3.2 solder jumper; verify a formatted FAT32 SD card is inserted |
| Green LED blinks 5× | `transport_start()` failed | Missing Kconfig, BLE stack assert — capture serial log |
| Red+Green blinks 5× | `mic_start()` failed | PDM init issue — usually indicates the port to NRFX_PDM0 instance API failed at runtime. Capture serial log. |
| No power at all (no LED, no USB enum) | VBAT↔GND short or flipped battery polarity | Unplug immediately. DMM check §9.1. |

**If you see the full sequence**: the hardware is good. Now plug the battery, verify the CHARGE LED comes on (amber), and proceed to app pairing (see `docs/PDD.md`).

---

## 11. Ongoing references

- **Pin-by-pin detail:** `devices/wearable-kelvinlee/docs/PIN_MAP.md`
- **Firmware build + flash:** `devices/wearable-kelvinlee/docs/BUILD_FIRMWARE.md`
- **Habitat alert vocabulary:** `devices/wearable-kelvinlee/docs/HABITAT_ALERTS.md`
- **Test harness / BLE client scripts:** `devices/wearable-kelvinlee/docs/TEST_HARNESS.md`
- **Seeed XIAO nRF52840 Sense datasheet:** `devices/wearable-kelvinlee/hardware/docs/xiao-ble-nrf52840-sense.md`
- **Adafruit BFF datasheets:** same `hardware/docs/` folder

---

## 12. Warranty / liability

This build re-routes pins away from the upstream KelvinLee reference. If you're mixing Wearable firmware with stock-KelvinLee hardware (or vice versa), expect things to break silently. The firmware expects this specific stack — no auto-detection.

If you brick a XIAO, nRF52840 bare modules are available from Seeed for ~$10. The BFFs are similarly inexpensive. Don't let fear of bricks stop you from iterating.
