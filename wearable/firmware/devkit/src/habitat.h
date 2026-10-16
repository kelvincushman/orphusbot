/* Copyright (c) 2025-2026 Kelvin Lee. Licensed under MIT. */

/*
 * habitat.h — Named LED + haptic cue dispatcher (Phase A).
 *
 * Maps spec feedback groups A-F to neopixel_set_color/neopixel_set_pattern +
 * haptic_play.  All functions are non-blocking (work-queue / timer driven).
 *
 * Spec colours:
 *   green  (0,200,60)  · blue  (0,80,200)   · amber (220,140,0)
 *   red    (220,20,20) · white (180,180,180)
 * Brightness cap 180; allow 255 on critical cues (HAPTIC_CRIT flag below).
 */

#ifndef WEARABLE_HABITAT_H
#define WEARABLE_HABITAT_H

#include <stdint.h>

/* --- Group A: Agent/task states --- */
void habitat_task_queued(void);     /* blue pulse + ● */
void habitat_task_running(void);    /* blue breathing */
void habitat_awaiting_input(void);  /* amber pulse (continuous) + ▬ once */
void habitat_task_done(void);       /* green flash 2s + ●● */
void habitat_error(void);           /* red flash 3s + ●●● */
void habitat_budget_warn(void);     /* amber breathing */

/* --- Group B: Power lifecycle --- */
void habitat_power_hold_tick(void);   /* tick haptic (1s/2s threshold cues on the way up) */
void habitat_power_on(void);          /* green flash 800ms + ● 150ms — "hi I'm here" */
void habitat_power_off_ramp(void);    /* amber→red ramp LED + tick at 1.5s/3s */
void habitat_power_off(void);         /* red fade 1s + ●● */
void habitat_power_off_aborted(void); /* green blink 250ms, no haptic — ramp let go */

/* --- Group C: Button-gesture acks --- */
void habitat_note_capturing(void);    /* white blink (short tap → note capturing) */
void habitat_note_filed(void);        /* green double-blink + ● */
void habitat_listening(void);         /* blue breathing while listening + ramp haptic */
void habitat_listening_ended(void);   /* blue single pulse */
void habitat_reply_mode(void);        /* amber blink + ● */

/* Group C, A2 button grammar v1.0. Only habitat_power_off_aborted() above is
 * played by the firmware; these four are the phone's, dispatched from an
 * AGENT_OP_HABITAT write. They live here because habitat.c is the one place
 * a cue may be composed, and because naming them identically on both sides is
 * the point of the op. */
void habitat_capture_open(void);      /* white blink, no timeout + rising ramp */
void habitat_discarded(void);         /* amber double-blink + falling ramp */
void habitat_ack(void);               /* tick, LED off — "yes, dealing with it" */
void habitat_nop(void);               /* dim white blink, no haptic */

/* --- Group D: BLE connection status --- */
void habitat_ble_searching(void);     /* amber+blue alternating flash (no link) */
void habitat_ble_connected(void);     /* green blink ×1 + ● 100ms (optional) */
void habitat_ble_idle(void);          /* dark (connected + idle) */
void habitat_ble_lost(void);          /* amber double-blink → then searching */

/* --- Group E: Notification tiers --- */
typedef enum {
    NOTIFY_TIER_LOW    = 0,  /* green double-blink + ● */
    NOTIFY_TIER_NORMAL = 1,  /* blue flash 1.5s + ●● */
    NOTIFY_TIER_HIGH   = 2,  /* amber pulse until answered + ▬ */
    NOTIFY_TIER_ALERT  = 3,  /* red flash 3s + ●●● */
} notify_tier_t;

void habitat_notify(notify_tier_t tier);

/* --- Group F: Battery --- */
void habitat_battery_low(void);  /* red slow breath + ● */

#endif /* WEARABLE_HABITAT_H */
