<!-- Copyright (c) 2025-2026 Kelvin Lee. Licensed under MIT. -->
<!-- Source: https://wiki.seeedstudio.com/XIAO_BLE/ -->
<!-- Fetched: 2026-04-18. Full archival mirror. -->

# Seeed Studio XIAO nRF52840 Technical Reference

## 1. Board Specifications & Variants

| Feature | XIAO nRF52840 | XIAO nRF52840 Sense | XIAO nRF52840 Plus | XIAO nRF52840 Sense Plus |
|---------|---------------|-------------------|-------------------|----------------------|
| **Processor** | Nordic nRF52840, ARM Cortex-M4 32-bit with FPU, 64 MHz |  |  |  |
| **RAM/Flash** | 256 KB RAM, 2 MB onboard Flash |  |  |  |
| **Wireless** | Bluetooth Low Energy 5.4 / Bluetooth Mesh / NFC |  |  |  |
| **Sensors** | None | 6-DOF IMU (LSM6DS3TR-C), PDM Microphone | None | 6-DOF IMU (LSM6DS3TR-C), PDM Microphone |
| **Interfaces** | 1×I2C, 1×UART, 1×SPI | 1×I2C, 2×UART, 2×SPI, 1×I2S |  |  |
| **PWM/ADC Pins** | 11/6 | 20/6 |  |  |
| **Form Factor** | 21 × 17.8 mm, single-sided SMD |  |  |  |
| **Battery Charging** | BQ25101 IC (50 mA or 100 mA selectable) |  |  |  |

**Key Quote:** "Ultra Small Size: 21 x 17.8mm, Seeed Studio XIAO series classic form-factor for wearable devices"

---

## 2. Complete Pinout Tables

### XIAO nRF52840 / nRF52840 Sense Pin Mapping

| XIAO Pin | Function | Chip Pin | Arduino Name | Primary Function | Alternate Functions |
|----------|----------|----------|--------------|------------------|---------------------|
| D0 | Analog | P0.02 | 0 | GPIO, ADC | — |
| D1 | Analog | P0.03 | 1 | GPIO, ADC | — |
| D2 | Analog | P0.28 | 2 | GPIO, ADC | — |
| D3 | Analog | P0.29 | 3 | GPIO, ADC | — |
| D4 | Analog, SDA | P0.04 | 4 | GPIO, I2C Data, ADC | — |
| D5 | Analog, SCL | P0.05 | 5 | GPIO, I2C Clock, ADC | — |
| D6 | TX | P1.11 | 7/6 | GPIO, UART Transmit | — |
| D7 | RX | P1.12 | 8/7 | GPIO, UART Receive | — |
| D8 | SPI_SCK | P1.13 | 9/8 | GPIO, SPI Clock | — |
| D9 | SPI_MISO | P1.14 | 10/9 | GPIO, SPI Data | — |
| D10 | SPI_MOSI | P1.15 | 11/10 | GPIO, SPI Data | — |
| NFC1 | NFC | P0.09 | — | NFC | — |
| NFC2 | NFC | P0.10 | — | NFC | — |

**PDM Microphone (Sense variant only — INTERNAL, not on header pins):**
- **PDM_DATA:** P0.16 (audio data input pin)
- **PDM_CLK:** P1.00 (audio clock output pin)

**6-DOF IMU (Sense variant only — INTERNAL):**
- **IMU_PWR:** P1.08 (power control)
- **IMU_INT1:** P0.11 (interrupt signal pin)
- **Model:** LSM6DS3TR-C
- **Default I2C Address:** 0x6B
- **Interface:** I2C (via D4/D5 pins shared with user I2C)

**LED Control (INTERNAL):**
- **USER_LED_R (Red):** P0.26 (Arduino pin 11)
- **USER_LED_B (Blue):** P0.06 (Arduino pin 13/12)
- **USER_LED_G (Green):** P0.30 (Arduino pin 12/13)
- **CHARGE_LED:** P0.17 (charging indicator)
- **Behavior:** Active LOW — `digitalWrite(LED_BUILTIN, LOW)` turns the LED ON.

**Power & Battery (INTERNAL):**
- **ADC_BAT / READ_BAT_ENABLE:** P0.14 (output LOW to enable battery voltage reading)
- **AIN7_BAT:** P0.31 (battery voltage ADC read pin, Sense/Plus variants)

### XIAO nRF52840 Plus / Plus Sense Extended Pinout

| XIAO Pin | Function | Chip Pin | Arduino Name | Primary Function |
|----------|----------|----------|--------------|------------------|
| D0–D10 | (same as standard) | — | — | — |
| D11 | I2S_SD | P0.15 | — | GPIO, I2S, ADC |
| D12 | I2S_SCK | P0.19 | — | GPIO, I2S, ADC |
| D13 | I2S_WS | P1.01 | — | GPIO, I2S, ADC |
| D14 | RX1 / NFC1 | P0.09 | — | GPIO, UART Receive, ADC |
| D15 | TX1 / NFC2 | P0.10 | — | GPIO, UART Transmit, ADC |
| D16 | AIN7_BAT | P0.31 | — | Battery voltage ADC |
| D17 | SCK1 | P1.03 | — | GPIO, SPI Clock |
| D18 | MISO1 | P1.05 | — | GPIO, SPI Data |
| D19 | MOSI1 | P1.07 | — | GPIO, SPI Data |

---

## 3. Onboard Peripherals

### PDM Microphone (Sense/Sense Plus only)
- **Model:** MSM261D3526H1CPM
- **Data Pin:** P0.16 (internal — does NOT use A0/A1/A2/A3 header pins)
- **Clock Pin:** P1.00 (internal)
- **Function:** Real-time audio capture for audio recognition and embedded ML

### 6-Axis Inertial Measurement Unit (IMU)
- **Model:** LSM6DS3TR-C
- **Default I2C Address:** 0x6B
- **Power Control Pin:** P1.08
- **Interrupt Pin (INT1):** P0.11
- **Interface:** I2C (shares the user I2C bus on D4/D5)
- **Application:** Gesture recognition, TinyML projects

### RGB LED (3-in-one)
**Important Behavior:** "The LED turns ON when we give a LOW signal and it turns OFF when we give a HIGH signal."

Pin assignments:
- Red: `LED_BUILTIN` or `LED_RED` (P0.26)
- Blue: `LED_BLUE` (P0.06)
- Green: `LED_GREEN` (P0.30)

Example code (LED ON):
```cpp
void setup() {
  pinMode(LED_BUILTIN, OUTPUT);
}
void loop() {
  digitalWrite(LED_BUILTIN, LOW);  // LOW turns LED ON
}
```

### Charge LED
- **Pin:** P0.17 (CHG-LED_Red)
- **Behavior:** "Low level: when charging is in progress. High level: when the battery is either not charging or fully charged."

---

## 4. Power Management

### Battery Charging Circuit
- **Charger IC:** BQ25101
- **Charging Current:** Selectable via P0.13 (Pin 13)
  - **HIGH level = 50 mA** (low current charging)
  - **LOW level = 100 mA** (high current charging)

### Battery Voltage Reading
- **ADC pin:** P0.31 (`AIN7_BAT` on Plus variants)
- **Enable pin:** P0.14 (`READ_BAT_ENABLE`)
  - Set P0.14 **LOW** to enable reading
  - Set P0.14 **HIGH** to disable (isolates ADC from battery voltage)

**Critical Warning:** "When P0.14 is set HIGH, the battery voltage reading path is disabled and P0.31 may reach the input voltage limit of 3.6V, posing a risk of damaging the P0.31 pin."

### Sleep Mode Current
- **Standby Power Consumption:** Less than 5 μA

**Deep Sleep Example:**
```cpp
#include "SdFat.h"
#include "Adafruit_SPIFlash.h"
#include <bluefruit.h>

bool deepPowerDown(Adafruit_SPIFlash& flash, Adafruit_FlashTransport& transport) {
  uint32_t id_before = flash.getJEDECID();
  transport.begin();
  transport.runCommand(0xB9);  // SPI deep power-down command
  delay(10);
  uint32_t id_after = flash.getJEDECID();
  return (id_after == 0xFFFFFF || id_after == 0xFFFFFFFF);
}

void setup() {
  flash.begin();
  Bluefruit.begin();
  if (!deepPowerDown(flash, flashTransport)) {
    pinMode(LED_BUILTIN, OUTPUT);
    digitalWrite(LED_BUILTIN, LOW);
    while (1) { yield(); }
  }
  flash.end();
  sd_power_system_off();
}

void loop() { }
```

### Charging Current Control

**Low Charging Current (50 mA):**
```cpp
void setup(){ pinMode(P0_13, OUTPUT); }
void loop() { digitalWrite(P0_13, HIGH); }
```

**High Charging Current (100 mA):**
```cpp
void setup(){ pinMode(P0_13, OUTPUT); }
void loop() { digitalWrite(P0_13, LOW); }
```

---

## 5. Programming Methods

### UF2 Bootloader (Standard)
1. Connect via USB Type-C cable
2. Click the **Reset Button** once to reset, or **twice rapidly** to enter bootloader mode
3. Upload via Arduino IDE (automatic DFU)

### SWD/JTAG Debugging & Bootloader Reflashing

**Hardware Required:**
- J-Link debugger
- SWD pins on board (SWCLK, SWDIO, GND)

**Bootloader Flashing Procedure:**
1. Download Segger J-Link software
2. Launch J-Flash, search for "nRF52840"
3. Click **Target** → **Connect**
4. Load bootloader `.hex` file (e.g. `Seeed_XIAO_nRF52840_Sense_bootloader-0.6.1_s140_7.3.0.hex`)
5. Press **F4**, then **F5** to program

### Programming Language Support
- Arduino (recommended)
- MicroPython
- CircuitPython
- Zephyr RTOS (board support via Nordic overlays; see also PlatformIO with Zephyr framework)
- NuttX RTOS

---

## 6. Arduino Board Packages & Libraries

### Two Recommended Libraries

**1. Seeed nRF52 Boards** (for Bluetooth & low-power)
- Best for: Bluetooth, low-energy optimization, basic peripheral control
- Supports: LED, digital, analog, Serial, I2C, SPI basic functions
- **Note:** May require `#include <Adafruit_TinyUSB.h>` for Serial compilation

**2. Seeed nRF52 mbed-enabled Boards** (for TinyML & advanced IMU/PDM)
- Best for: embedded ML, IMU and PDM advanced features
- Supports: Serial compilation without modifications
- Better for: complex projects requiring advanced sensor integration

### Arduino IDE Setup

1. File → Preferences → Additional Boards Manager URLs:
   `https://files.seeedstudio.com/arduino/package_seeeduino_boards_index.json`
2. Tools → Board → Boards Manager → search "seeed nrf52" → install latest
3. Tools → Board → "Seeed XIAO nRF52840 Sense" (or standard variant)
4. Tools → Port → the Xiao's COM/tty
5. Test: File → Examples → 01.Basics → Blink → Upload

---

## 7. Troubleshooting FAQ

| Problem | Solution |
|---------|----------|
| Arduino IDE stuck during upload | Click Reset button once; if unresponsive, click twice rapidly to enter bootloader mode; or reconnect USB |
| Board not appearing as serial device | Click Reset button once; if unresponsive, click twice to enter bootloader mode |
| Battery voltage reading pin damaged | Never set P0.14 HIGH during battery charging; keep P0.14 LOW when reading P0.31 |
| Serial compilation fails (Seeed nRF52 Boards) | Add `#include <Adafruit_TinyUSB.h>` to code, or use Seeed nRF52 mbed-enabled library |

---

## 8. Key Resources

- Nordic nRF52840 datasheet: https://files.seeedstudio.com/wiki/XIAO-BLE/nRF52840_PS_v1.5.pdf
- XIAO nRF52840 schematic: https://files.seeedstudio.com/wiki/XIAO-BLE/Seeed_Studio_XIAO_nRF52840_PDF.pdf
- Pinout spreadsheet: https://files.seeedstudio.com/wiki/XIAO-BLE/XIAO-nRF52840-pinout_sheet.xlsx
- Sense-specific IMU datasheet: https://files.seeedstudio.com/wiki/XIAO-BLE/ST_LSM6DS3TR_Datasheet.pdf
- Sense-specific mic datasheet: https://files.seeedstudio.com/wiki/XIAO-BLE/mic-MSM261D3526H1CPM-ENG.pdf
- Charger IC datasheet: https://files.seeedstudio.com/wiki/XIAO-BLE/BQ25101.pdf
- Purchase — Sense variant: https://www.seeedstudio.com/Seeed-XIAO-BLE-Sense-nRF52840-p-5253.html

---

## 9. Key Takeaways for Wearable Firmware

- PDM mic is **internal** (P0.16 / P1.00) — **A2 (P0.28) and A3 (P0.29) are FREE** for the Adafruit IoT Button + NeoPixel BFF.
- Onboard RGB LED pins are P0.26 (R), P0.06 (B), P0.30 (G). **Avoid P0.06 and P0.30 for new peripherals** or disable LED drive explicitly.
- D4 / D5 (P0.04 / P0.05) are the I2C bus used by the onboard IMU. Existing kelvinlee devkit also uses D5 for the primary button.
- D6 / TX (P1.11) is the UART TX; the kelvinlee devkit firmware repurposes it for the haptic motor. **Conflict with Adafruit MicroSD BFF default CS (TX) — see that BFF's doc.**
- D8 / D9 / D10 (P1.13 / P1.14 / P1.15) are the primary SPI bus, used by the MicroSD BFF.
- Free candidate pins for a vibration motor (beyond the existing P1.11 haptic): none of D0–D10 are fully free on this configuration; candidate requires repurposing the UART RX (D7 / P1.12) or accepting the Plus-variant extra pins.
