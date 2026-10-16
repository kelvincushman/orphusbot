/* Copyright (c) 2025-2026 Kelvin Lee. Licensed under MIT. */

#ifndef WEARABLE_NEOPIXEL_H
#define WEARABLE_NEOPIXEL_H

#include <stdint.h>
#include <stdbool.h>

typedef enum {
    NEOPIXEL_OFF        = 0,
    NEOPIXEL_SOLID      = 1,
    NEOPIXEL_BREATHING  = 2,  /* slow sine-like fade at ~1 Hz */
    NEOPIXEL_PULSE      = 3,  /* single slow pulse; auto-off after duration */
    NEOPIXEL_BLINK      = 4,  /* fast on/off at ~4 Hz */
    NEOPIXEL_FLASH      = 5,  /* bright flash then off; duration = on-time */
    NEOPIXEL_FADE       = 6,  /* linear fade from current brightness to 0 */
    NEOPIXEL_ALT_FLASH  = 7,  /* two-colour alternating flash (amber+blue); uses
                                * a separate colour param — see habitat.c */
    NEOPIXEL_DOUBLE_BLINK = 8, /* two quick blinks then off */
} neopixel_pattern_t;

/**
 * For NEOPIXEL_ALT_FLASH: set the alternate colour (second colour in the flash).
 * The primary colour is set via neopixel_set_color as usual.
 */
void neopixel_set_alt_color(uint8_t r, uint8_t g, uint8_t b);

/**
 * Initialise the NeoPixel driver. Safe to call at boot; no-op if the
 * led-strip devicetree node isn't ready (enabled only when the BFF is
 * physically attached and the overlay wires it).
 *
 * Returns 0 on success, negative errno on failure.
 */
int neopixel_init(void);

/**
 * Set an RGB colour immediately (equivalent to OP=LED_COLOR in the GATT
 * command format). Any active pattern is cancelled. Values 0-255.
 */
int neopixel_set_color(uint8_t r, uint8_t g, uint8_t b);

/**
 * Start a pattern. Colour comes from the last neopixel_set_color() call or
 * defaults to (0, 80, 200) "Wearable blue" on first use.
 *
 * duration_ms = 0 means "until cleared". Otherwise the pattern auto-stops
 * after duration_ms and returns to NEOPIXEL_OFF.
 */
int neopixel_set_pattern(neopixel_pattern_t pattern, uint16_t duration_ms);

/**
 * Hard off — cancel any running pattern and set pixel to (0, 0, 0).
 */
int neopixel_off(void);

#endif /* WEARABLE_NEOPIXEL_H */
