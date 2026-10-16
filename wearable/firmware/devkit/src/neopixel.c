/* Copyright (c) 2025-2026 Kelvin Lee. Licensed under MIT. */

/*
 * WS2812 NeoPixel driver wrapper for Wearable habitat-alert patterns.
 *
 * Thin shim over Zephyr's led_strip API. All pattern evolution runs on a
 * single k_work_delayable so the audio thread is never blocked. The BFF
 * chains a single LED; the state machine is colour + pattern + duration.
 */

#include "neopixel.h"

#include <zephyr/device.h>
#include <zephyr/drivers/led_strip.h>
#include <zephyr/kernel.h>
#include <zephyr/logging/log.h>

LOG_MODULE_REGISTER(neopixel, CONFIG_LOG_DEFAULT_LEVEL);

#define STRIP_NODE  DT_ALIAS(led_strip)

#if DT_NODE_HAS_STATUS(STRIP_NODE, okay)
static const struct device *const strip_dev = DEVICE_DT_GET(STRIP_NODE);
#define HAS_STRIP 1
#else
static const struct device *const strip_dev = NULL;
#define HAS_STRIP 0
#endif

#define STRIP_LEN 1

/* Brightness cap — defensive against the Xiao's 3.3V LDO browning out under
 * simultaneous SD-write + BT TX + NeoPixel-full-white. 60 mA peak at 255
 * becomes ~42 mA peak at 180 — within margin on the 250 mA LDO even with
 * worst-case concurrent SD writes. Raise only after a battery burn-in test. */
#define NEOPIXEL_MAX_CHANNEL 180

static struct led_rgb current_color = { .r = 0, .g = 80, .b = 200 }; // Wearable blue default
static struct led_rgb alt_color = { .r = 220, .g = 140, .b = 0 }; // amber default for ALT_FLASH
static neopixel_pattern_t current_pattern = NEOPIXEL_OFF;
static uint16_t pattern_duration_ms = 0;
static int64_t pattern_started_at = 0;
static uint32_t tick_counter = 0;

/* State mutex — pattern_tick runs on the system work queue while public
 * setters run on the BLE RX thread (or anyone who writes to the GATT char).
 * Plain statics were racy: a set_pattern call mid-tick could leave state
 * half-mutated and the work item would render stale data. All reads and
 * writes of the five state fields above now hold this mutex. Critical
 * sections are tiny (a few assignments), so mutual exclusion is cheap. */
static K_MUTEX_DEFINE(state_mutex);

static void pattern_tick(struct k_work *work);
static K_WORK_DELAYABLE_DEFINE(pattern_work, pattern_tick);

/* Global brightness: every channel of every write is scaled by this / 255
 * before the safety cap. Set to 18 (~1/14 of full) because the bare NeoPixel at the
 * cap was uncomfortably bright worn on the body at arm's length. Colours are
 * authored at full 0-255 across the codebase; this is the single dimmer so no
 * cue has to know about it. Raise toward 255 for a brighter device. */
#define NEOPIXEL_BRIGHTNESS 18

static inline uint8_t cap(uint8_t v) {
    const uint8_t dimmed = (uint8_t)(((uint32_t)v * NEOPIXEL_BRIGHTNESS) / 255);
    return dimmed > NEOPIXEL_MAX_CHANNEL ? NEOPIXEL_MAX_CHANNEL : dimmed;
}

static int write_rgb(uint8_t r, uint8_t g, uint8_t b)
{
#if HAS_STRIP
    if (strip_dev == NULL || !device_is_ready(strip_dev)) {
        return -ENODEV;
    }
    /* Safety cap on every write — see NEOPIXEL_MAX_CHANNEL rationale. */
    struct led_rgb pixel = { .r = cap(r), .g = cap(g), .b = cap(b) };
    return led_strip_update_rgb(strip_dev, &pixel, STRIP_LEN);
#else
    (void)r; (void)g; (void)b;
    return -ENODEV;
#endif
}

int neopixel_init(void)
{
#if HAS_STRIP
    if (strip_dev == NULL) {
        LOG_WRN("NeoPixel devicetree node present but device handle is null");
        return -ENODEV;
    }
    if (!device_is_ready(strip_dev)) {
        LOG_WRN("NeoPixel device not ready");
        return -ENODEV;
    }
    write_rgb(0, 0, 0);
    LOG_INF("NeoPixel initialised");
    return 0;
#else
    LOG_WRN("NeoPixel driver compiled without a led-strip alias");
    return -ENOTSUP;
#endif
}

void neopixel_set_alt_color(uint8_t r, uint8_t g, uint8_t b)
{
    k_mutex_lock(&state_mutex, K_FOREVER);
    alt_color.r = r;
    alt_color.g = g;
    alt_color.b = b;
    k_mutex_unlock(&state_mutex);
}

int neopixel_set_color(uint8_t r, uint8_t g, uint8_t b)
{
    /* Cancel OUTSIDE the mutex to avoid pattern_tick deadlocking on us. */
    k_work_cancel_delayable(&pattern_work);
    k_mutex_lock(&state_mutex, K_FOREVER);
    current_color.r = r;
    current_color.g = g;
    current_color.b = b;
    current_pattern = NEOPIXEL_SOLID;
    pattern_duration_ms = 0;
    k_mutex_unlock(&state_mutex);
    return write_rgb(r, g, b);
}

int neopixel_set_pattern(neopixel_pattern_t pattern, uint16_t duration_ms)
{
    k_work_cancel_delayable(&pattern_work);
    k_mutex_lock(&state_mutex, K_FOREVER);
    current_pattern = pattern;
    pattern_duration_ms = duration_ms;
    pattern_started_at = k_uptime_get();
    tick_counter = 0;
    /* Snapshot color for a lock-free render outside the critical section. */
    uint8_t r = current_color.r;
    uint8_t g = current_color.g;
    uint8_t b = current_color.b;
    k_mutex_unlock(&state_mutex);

    switch (pattern) {
    case NEOPIXEL_OFF:
        return write_rgb(0, 0, 0);
    case NEOPIXEL_SOLID:
        return write_rgb(r, g, b);
    case NEOPIXEL_BREATHING:
    case NEOPIXEL_PULSE:
    case NEOPIXEL_BLINK:
    case NEOPIXEL_FLASH:
    case NEOPIXEL_FADE:
    case NEOPIXEL_ALT_FLASH:
    case NEOPIXEL_DOUBLE_BLINK: {
        /* k_work_schedule() returns 1 (scheduled) or 2 (was running, queued)
         * on success, not 0. Propagating that made every animated pattern
         * look like a failure to gatt_write_agent_cmd, which answers any
         * non-zero with ATT "unlikely error" — measured over a real
         * write-with-response. The app uses write-without-response, so the
         * animation ran and the error was never seen. 0 on success, as the
         * header promises. */
        int rc = k_work_schedule(&pattern_work, K_MSEC(0));
        return rc < 0 ? rc : 0;
    }
    default:
        return -EINVAL;
    }
}

int neopixel_off(void)
{
    k_work_cancel_delayable(&pattern_work);
    k_mutex_lock(&state_mutex, K_FOREVER);
    current_pattern = NEOPIXEL_OFF;
    pattern_duration_ms = 0;
    k_mutex_unlock(&state_mutex);
    return write_rgb(0, 0, 0);
}

/** Scale a 0-255 byte by a 0-255 brightness factor. */
static inline uint8_t scale(uint8_t v, uint8_t factor)
{
    return (uint8_t)(((uint32_t)v * factor) / 255);
}

static void pattern_tick(struct k_work *work)
{
    ARG_UNUSED(work);

    /* Snapshot state under the mutex, then render without holding it so
     * write_rgb (which calls into the led-strip driver and may block on SPI)
     * doesn't starve setters. */
    k_mutex_lock(&state_mutex, K_FOREVER);
    neopixel_pattern_t pattern = current_pattern;
    uint16_t duration_ms = pattern_duration_ms;
    int64_t started_at = pattern_started_at;
    uint32_t step = tick_counter;
    uint8_t cr = current_color.r;
    uint8_t cg = current_color.g;
    uint8_t cb = current_color.b;
    uint8_t ar = alt_color.r;
    uint8_t ag = alt_color.g;
    uint8_t ab = alt_color.b;
    k_mutex_unlock(&state_mutex);

    // Auto-stop when duration elapses.
    if (duration_ms > 0) {
        int64_t elapsed = k_uptime_get() - started_at;
        if (elapsed >= duration_ms) {
            k_mutex_lock(&state_mutex, K_FOREVER);
            current_pattern = NEOPIXEL_OFF;
            k_mutex_unlock(&state_mutex);
            write_rgb(0, 0, 0);
            return;
        }
    }

    uint8_t brightness = 0;
    uint32_t next_delay_ms = 100;

    switch (pattern) {
    case NEOPIXEL_BREATHING: {
        // Triangle-wave breathing at 1 s full cycle (500 ms fade up, 500 ms
        // fade down). 20 ticks per half-cycle = ~25 ms per step.
        uint32_t phase = step % 40;
        brightness = (phase < 20) ? (uint8_t)((phase * 255) / 20)
                                  : (uint8_t)(((40 - phase) * 255) / 20);
        next_delay_ms = 25;
        break;
    }
    case NEOPIXEL_PULSE: {
        // One slow pulse over ~800 ms. After the pulse completes, we turn
        // off and STOP — no busy-rescheduling while waiting for the outer
        // duration to expire.
        if (step > 32) {
            k_mutex_lock(&state_mutex, K_FOREVER);
            current_pattern = NEOPIXEL_OFF;
            k_mutex_unlock(&state_mutex);
            write_rgb(0, 0, 0);
            return;
        }
        brightness = (step < 16) ? (uint8_t)((step * 255) / 16)
                                 : (uint8_t)(((32 - step) * 255) / 16);
        next_delay_ms = 25;
        break;
    }
    case NEOPIXEL_BLINK:
        brightness = (step % 2 == 0) ? 255 : 0;
        next_delay_ms = 125;
        break;
    case NEOPIXEL_FLASH:
        brightness = (step == 0) ? 255 : 0;
        next_delay_ms = 50;
        break;
    case NEOPIXEL_FADE: {
        /* Linear fade-out over 20 steps × 50 ms = 1 s. */
        if (step >= 20) {
            k_mutex_lock(&state_mutex, K_FOREVER);
            current_pattern = NEOPIXEL_OFF;
            k_mutex_unlock(&state_mutex);
            write_rgb(0, 0, 0);
            return;
        }
        brightness = (uint8_t)(((20 - step) * 255) / 20);
        next_delay_ms = 50;
        break;
    }
    case NEOPIXEL_ALT_FLASH: {
        /* Alternates primary (A) and alt (B) colours every 300 ms. */
        next_delay_ms = 300;
        if (step % 2 == 0) {
            write_rgb(scale(cr, 200), scale(cg, 200), scale(cb, 200));
        } else {
            write_rgb(scale(ar, 200), scale(ag, 200), scale(ab, 200));
        }
        k_mutex_lock(&state_mutex, K_FOREVER);
        if (current_pattern == pattern) {
            tick_counter = step + 1;
        }
        k_mutex_unlock(&state_mutex);
        k_work_schedule(&pattern_work, K_MSEC(next_delay_ms));
        return;  /* skip brightness-scaled write below */
    }
    case NEOPIXEL_DOUBLE_BLINK: {
        /* Two blinks (on 100ms, off 100ms) × 2, then off. */
        /* Steps 0-1: blink1, 2-3: blink2, 4+: off. */
        if (step >= 4) {
            k_mutex_lock(&state_mutex, K_FOREVER);
            current_pattern = NEOPIXEL_OFF;
            k_mutex_unlock(&state_mutex);
            write_rgb(0, 0, 0);
            return;
        }
        brightness = (step % 2 == 0) ? 255 : 0;
        next_delay_ms = 100;
        break;
    }
    default:
        return;
    }

    write_rgb(scale(cr, brightness),
              scale(cg, brightness),
              scale(cb, brightness));

    k_mutex_lock(&state_mutex, K_FOREVER);
    /* Only bump if a concurrent setter hasn't reset us — if current_pattern
     * has shifted to something other than what we rendered, leave tick_counter
     * alone so the new pattern starts fresh. */
    if (current_pattern == pattern) {
        tick_counter = step + 1;
    }
    k_mutex_unlock(&state_mutex);
    k_work_schedule(&pattern_work, K_MSEC(next_delay_ms));
}
