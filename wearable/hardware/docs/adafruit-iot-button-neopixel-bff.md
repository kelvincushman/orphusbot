<!-- Copyright (c) 2025-2026 Kelvin Lee. Licensed under MIT. -->
<!-- Source: https://learn.adafruit.com/adafruit-iot-button-with-neopixel-bff -->
<!-- Fetched: 2026-04-18. Partial mirror — Adafruit's guide is multi-page and nav-gated; see source for full walkthrough. -->

# Adafruit IoT Button with NeoPixel BFF for QT Py and Xiao

## Part number
- **5666** — Adafruit IoT Button with NeoPixel BFF for QT Py and Xiao

## Form factor
A BFF add-on that stacks on the back of a QT Py or Xiao board. Provides one 12 mm tactile button and one NeoPixel RGB LED on the front face.

## Pin mapping on Xiao

| Function | Xiao Pin (Silk) | nRF52840 GPIO | Notes |
|---|---|---|---|
| Button (tactile switch) | A2 | **P0.28** | Active-low; pulls to GND when pressed. Requires internal pull-up. |
| NeoPixel DATA | A3 | **P0.29** | Single WS2812-family LED on this line. |

> Adafruit quote: *"Tactile switch momentarily connects A2 to ground when pressed."*
> *"Single NeoPixel on GPIO A3."*
> *"Don't forget to enable an internal pull-up resistor on A2 or whatever pin you use."*

**Important on the Sense variant:** A2 (P0.28) and A3 (P0.29) are **header-exposed GPIOs and are not used by the onboard PDM microphone** (mic lives internally on P0.16 / P1.00). The BFF drops in cleanly — no conflict with audio capture.

## Jumper modifications (pin reassignment)

Two solder-jumpers on the front of the board allow re-routing:

- **NP jumper** (left of the NeoPixel LED, labelled `NP`) — cut to disconnect the NeoPixel data input from A3. The NeoPixel solder pad (top of the board, between `5V` silk and the LED) can then be wired to an alternate pin.
- **Sw jumper** (right of the NeoPixel LED, labelled `Sw`) — cut to disconnect the button output from A2. The button solder pad (top of the board, between `A0` silk and the LED) can be wired to an alternate pin.

For this build, **keep both jumpers at default (A2 / A3)** — the pins are free on the Xiao nRF52840 Sense and require no rerouting.

## Arduino setup

- Libraries: **`Adafruit_NeoPixel`** (for the LED) and **`Adafruit_IO_Arduino`** (for the connected-button example, optional)
- Baud: 115200 for Serial Monitor
- Basic example behaviour: press the button → NeoPixel lights red
- Connected example colour states:
  - **Red** = not connected to Adafruit IO
  - **Green** = connected
  - **Blue** = actively uploading data
- Full sketch: see the Adafruit Learning System Guides repo on GitHub

## What this doc does NOT cover

Adafruit's learn-guide is multi-page and partially rendered under JS navigation. The fetched content did not include:

- Exact NeoPixel IC part number (WS2812B vs SK6812 vs other — likely WS2812B based on part family conventions but not confirmed in the fetched pages)
- NeoPixel 3.3 V vs 5 V data-line tolerance (WS2812B nominally wants 5 V data but reliably works from nRF52840's 3.3 V output with a single LED at short trace length)
- Debounce timing requirements for the button (firmware-side debounce required — see `devkit/src/button.c` for the existing FSM pattern)

For those details consult the source URL in the header and the product page at https://www.adafruit.com/product/5666.

## Zephyr integration notes (for Wearable firmware)

NeoPixel driver: Zephyr ships `worldsemi,ws2812-spi` (uses a SPI peripheral to bit-bang WS2812 timing at ~3.2 MHz). On the Xiao nRF52840 Sense, SPI1 or SPI3 can be repurposed for the NeoPixel line — **do not** use SPI2 (already owned by the MicroSD BFF at D8/D9/D10).

Devicetree fragment (planned — to be finalised during Phase 2.2):
```dts
&spi1 {
    status = "okay";
    pinctrl-0 = <&spi1_neopixel>;
    pinctrl-names = "default";

    led_strip: ws2812@0 {
        compatible = "worldsemi,ws2812-spi";
        reg = <0>;
        spi-max-frequency = <4000000>;
        chain-length = <1>;
        spi-one-frame = <0x70>;
        spi-zero-frame = <0x40>;
        color-mapping = <LED_COLOR_ID_GREEN LED_COLOR_ID_RED LED_COLOR_ID_BLUE>;
    };
};

&pinctrl {
    spi1_neopixel: spi1_neopixel {
        group1 {
            psels = <NRF_PSEL(SPIM_MOSI, 0, 29)>;  // A3 / P0.29 → NeoPixel DATA
        };
    };
};
```

Button on A2:
```dts
/ {
    buttons {
        compatible = "gpio-keys";
        iot_button: button_iot {
            gpios = <&gpio0 28 (GPIO_PULL_UP | GPIO_ACTIVE_LOW)>;
            label = "IoT Button (A2)";
        };
    };
};
```
