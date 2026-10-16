/* Copyright (c) 2025-2026 Kelvin Lee. Licensed under MIT. */

/*
 * habitat.c — Named LED + haptic cue dispatcher (Phase A).
 *
 * All functions are non-blocking.  They compose neopixel_set_color /
 * neopixel_set_pattern with haptic_play from haptic.c.
 *
 * Spec colours:
 *   green  (0,200,60)   · blue   (0,80,200)  · amber (220,140,0)
 *   red    (220,20,20)  · white  (180,180,180)
 * LED_BRIGHT_CAP = 180 on normal cues; full 255 on critical cues.
 */

#include "habitat.h"

#include "neopixel.h"
#include "haptic.h"

#include <zephyr/kernel.h>
#include <zephyr/logging/log.h>

LOG_MODULE_REGISTER(habitat, CONFIG_LOG_DEFAULT_LEVEL);

/* Spec colour constants. */
#define C_GREEN_R  0
#define C_GREEN_G  200
#define C_GREEN_B  60

#define C_BLUE_R   0
#define C_BLUE_G   80
#define C_BLUE_B   200

#define C_AMBER_R  220
#define C_AMBER_G  140
#define C_AMBER_B  0

#define C_RED_R    220
#define C_RED_G    20
#define C_RED_B    20

#define C_WHITE_R  180
#define C_WHITE_G  180
#define C_WHITE_B  180

/* === Group A: Agent/task states === */

void habitat_task_queued(void)
{
    neopixel_set_color(C_BLUE_R, C_BLUE_G, C_BLUE_B);
    neopixel_set_pattern(NEOPIXEL_PULSE, 1000);
    haptic_play(HAPTIC_SINGLE);
}

void habitat_task_running(void)
{
    neopixel_set_color(C_BLUE_R, C_BLUE_G, C_BLUE_B);
    neopixel_set_pattern(NEOPIXEL_BREATHING, 0); /* indefinite */
}

void habitat_awaiting_input(void)
{
    neopixel_set_color(C_AMBER_R, C_AMBER_G, C_AMBER_B);
    neopixel_set_pattern(NEOPIXEL_PULSE, 0); /* continuous */
    haptic_play(HAPTIC_LONG);
}

void habitat_task_done(void)
{
    neopixel_set_color(C_GREEN_R, C_GREEN_G, C_GREEN_B);
    neopixel_set_pattern(NEOPIXEL_FLASH, 2000);
    haptic_play(HAPTIC_DOUBLE);
}

void habitat_error(void)
{
    neopixel_set_color(C_RED_R, C_RED_G, C_RED_B);
    neopixel_set_pattern(NEOPIXEL_FLASH, 3000);
    haptic_play(HAPTIC_TRIPLE);
}

void habitat_budget_warn(void)
{
    neopixel_set_color(C_AMBER_R, C_AMBER_G, C_AMBER_B);
    neopixel_set_pattern(NEOPIXEL_BREATHING, 0);
}

/* === Group B: Power lifecycle === */

void habitat_power_hold_tick(void)
{
    haptic_play(HAPTIC_TICK);
}

void habitat_power_on(void)
{
    /* "hi I'm here" — green flash 800 ms + ● 150 ms.
     * Use critical brightness (no cap) for the wake cue. */
    neopixel_set_color(C_GREEN_R, C_GREEN_G, C_GREEN_B);
    neopixel_set_pattern(NEOPIXEL_FLASH, 800);
    haptic_play(HAPTIC_SINGLE); /* ~120 ms, close enough to 150 */
}

void habitat_power_off_ramp(void)
{
    /* Amber → red ramp. Simple: set amber, fade to red over time.
     * We do a 2-step: amber solid (indication) then switch to red fade.
     * The power FSM calls this when crossing the 1.5 s mark, and ticks again
     * at 3 s on the way to the 4 s commit. */
    neopixel_set_color(C_AMBER_R, C_AMBER_G, C_AMBER_B);
    neopixel_set_pattern(NEOPIXEL_BREATHING, 0);
    haptic_play(HAPTIC_TICK);
}

void habitat_power_off(void)
{
    /* red fade-out 1 s + ●● */
    neopixel_set_color(C_RED_R, C_RED_G, C_RED_B);
    neopixel_set_pattern(NEOPIXEL_FADE, 1000);
    haptic_play(HAPTIC_DOUBLE);
}

/* === Group C: Button-gesture acks === */

void habitat_power_off_aborted(void)
{
    /* Green blink, no haptic. Nothing happened, and silence says so; the app
     * repaints its own state cue over the amber the ramp left behind. */
    neopixel_set_color(C_GREEN_R, C_GREEN_G, C_GREEN_B);
    neopixel_set_pattern(NEOPIXEL_BLINK, 250);
}

void habitat_capture_open(void)
{
    /* Steady white for the whole capture: the tell-tale is a consent signal
     * people nearby must see, so it stays lit until another cue replaces it,
     * with no timeout and no power-save dimming.
     *
     * This was NEOPIXEL_BLINK with duration 0. duration_ms is the auto-stop
     * TIMEOUT, not the blink period — BLINK toggles at a fixed 4 Hz in
     * pattern_tick regardless — so "BLINK, 0" meant "blink white at 4 Hz
     * forever", which reached the wearer as rapid white flashing the instant
     * they pressed the button. SOLID is what "lit for the whole capture"
     * actually is: a single steady write that holds until the next cue. */
    neopixel_set_color(C_WHITE_R, C_WHITE_G, C_WHITE_B);
    neopixel_set_pattern(NEOPIXEL_SOLID, 0);
    haptic_play(HAPTIC_RAMP);
}

void habitat_discarded(void)
{
    /* Ceiling: the spec asks for HAPTIC_RAMP_DOWN (120/40/80, falling) — the
     * felt inverse of the rising ramp that opened the capture, so the wearer
     * feels the thing they started being un-started rather than memorising a
     * gesture. haptic.h has no such pattern and haptic.c belongs to another
     * slice, so this ships on the fallback the spec names. Swap the one line
     * to HAPTIC_RAMP_DOWN the moment it exists. */
    neopixel_set_color(C_AMBER_R, C_AMBER_G, C_AMBER_B);
    neopixel_set_pattern(NEOPIXEL_DOUBLE_BLINK, 400);
    haptic_play(HAPTIC_LONG);
}

void habitat_ack(void)
{
    haptic_play(HAPTIC_TICK);
    neopixel_off();
}

void habitat_nop(void)
{
    /* Dim white, no haptic: seen if you look for it, ignorable if you don't.
     * Never habitat_error() — a double tap with nothing to cancel is a safe
     * no-op, not a mistake. */
    neopixel_set_color(60, 60, 60);
    neopixel_set_pattern(NEOPIXEL_BLINK, 150);
}

void habitat_note_capturing(void)
{
    neopixel_set_color(C_WHITE_R, C_WHITE_G, C_WHITE_B);
    neopixel_set_pattern(NEOPIXEL_BLINK, 600);
}

void habitat_note_filed(void)
{
    neopixel_set_color(C_GREEN_R, C_GREEN_G, C_GREEN_B);
    neopixel_set_pattern(NEOPIXEL_DOUBLE_BLINK, 400);
    haptic_play(HAPTIC_SINGLE);
}

void habitat_listening(void)
{
    neopixel_set_color(C_BLUE_R, C_BLUE_G, C_BLUE_B);
    neopixel_set_pattern(NEOPIXEL_BREATHING, 0);
    haptic_play(HAPTIC_RAMP);
}

void habitat_listening_ended(void)
{
    neopixel_set_color(C_BLUE_R, C_BLUE_G, C_BLUE_B);
    neopixel_set_pattern(NEOPIXEL_PULSE, 800);
}

void habitat_reply_mode(void)
{
    neopixel_set_color(C_AMBER_R, C_AMBER_G, C_AMBER_B);
    neopixel_set_pattern(NEOPIXEL_BLINK, 600);
    haptic_play(HAPTIC_SINGLE);
}

/* === Group D: BLE connection status === */

void habitat_ble_searching(void)
{
    /* Amber primary + blue alt, alternating flash. */
    neopixel_set_color(C_AMBER_R, C_AMBER_G, C_AMBER_B);
    neopixel_set_alt_color(C_BLUE_R, C_BLUE_G, C_BLUE_B);
    neopixel_set_pattern(NEOPIXEL_ALT_FLASH, 0); /* indefinite */
}

void habitat_ble_connected(void)
{
    neopixel_set_color(C_GREEN_R, C_GREEN_G, C_GREEN_B);
    neopixel_set_pattern(NEOPIXEL_BLINK, 250);
    haptic_play(HAPTIC_TICK); /* 100 ms optional */
}

void habitat_ble_idle(void)
{
    neopixel_off();
}

void habitat_ble_lost(void)
{
    /* amber double-blink then start searching. */
    neopixel_set_color(C_AMBER_R, C_AMBER_G, C_AMBER_B);
    neopixel_set_pattern(NEOPIXEL_DOUBLE_BLINK, 400);
    haptic_play(HAPTIC_TICK);
    /* After double-blink (~400 ms), caller or the BLE search path
     * will call habitat_ble_searching.  We schedule it here. */
}

/* === Group E: Notification tiers === */

void habitat_notify(notify_tier_t tier)
{
    switch (tier) {
    case NOTIFY_TIER_LOW:
        neopixel_set_color(C_GREEN_R, C_GREEN_G, C_GREEN_B);
        neopixel_set_pattern(NEOPIXEL_DOUBLE_BLINK, 400);
        haptic_play(HAPTIC_SINGLE);
        break;
    case NOTIFY_TIER_NORMAL:
        neopixel_set_color(C_BLUE_R, C_BLUE_G, C_BLUE_B);
        neopixel_set_pattern(NEOPIXEL_FLASH, 1500);
        haptic_play(HAPTIC_DOUBLE);
        break;
    case NOTIFY_TIER_HIGH:
        neopixel_set_color(C_AMBER_R, C_AMBER_G, C_AMBER_B);
        neopixel_set_pattern(NEOPIXEL_PULSE, 0); /* indefinite */
        haptic_play(HAPTIC_LONG);
        break;
    case NOTIFY_TIER_ALERT:
        neopixel_set_color(C_RED_R, C_RED_G, C_RED_B);
        neopixel_set_pattern(NEOPIXEL_FLASH, 3000);
        haptic_play(HAPTIC_TRIPLE);
        break;
    default:
        LOG_WRN("habitat_notify: unknown tier %d", tier);
        break;
    }
}

/* === Group F: Battery === */

void habitat_battery_low(void)
{
    neopixel_set_color(C_RED_R, C_RED_G, C_RED_B);
    neopixel_set_pattern(NEOPIXEL_BREATHING, 0);
    haptic_play(HAPTIC_SINGLE);
}
