/* Copyright (c) 2025-2026 Kelvin Lee. Licensed under MIT. Portions (c) 2024 Based Hardware Contributors, MIT (see LICENSE-UPSTREAM). */

/*
 * Haptic (vibration motor) driver.
 *
 * The I2S speaker half of this file was deleted in slice S4: this device has
 * no audio output hardware and never will.  What remains drives the vibration
 * motor on A1/P0.03 via PWM0 channel 0 (devicetree node `vibration_pwm`,
 * period PWM_MSEC(20)).
 */

#include "haptic.h"

#include <zephyr/devicetree.h>
#include <zephyr/drivers/pwm.h>
#include <zephyr/kernel.h>
#include <zephyr/logging/log.h>

LOG_MODULE_REGISTER(haptic, CONFIG_LOG_DEFAULT_LEVEL);

#define MAX_HAPTIC_DURATION 5000

/*
 * Raw PWM spec for the A1/P0.03 haptic motor.
 *
 * Uses the `vibration_pwm` devicetree node (a pwm-leds child) via its `pwms`
 * property — bypasses the led_pwm driver entirely, which avoids the boot fault
 * caused by DEVICE_DT_GET(DT_PATH(pwmleds)) when CONFIG_LED_PWM bound the
 * whole /pwmleds node.  Period comes from the DT (PWM_MSEC(20) = 20 ms).
 * Motor ON  = full duty (period == pulse_width).
 * Motor OFF = zero duty (pulse_width = 0).
 */
#if DT_NODE_HAS_STATUS(DT_NODELABEL(vibration_pwm), okay)
static const struct pwm_dt_spec haptic_pwm =
    PWM_DT_SPEC_GET(DT_NODELABEL(vibration_pwm));
#define HAPTIC_PWM_AVAILABLE 1
#else
#define HAPTIC_PWM_AVAILABLE 0
#endif

/* Haptic motor helpers — raw PWM, no led_pwm driver. */

/* haptic_motor_on/off: safe no-ops when PWM not available. */
static inline void haptic_motor_on(void)
{
#if HAPTIC_PWM_AVAILABLE
    if (!pwm_is_ready_dt(&haptic_pwm)) {
        LOG_WRN("Haptic PWM not ready — skipping motor on");
        return;
    }
    pwm_set_dt(&haptic_pwm, haptic_pwm.period, haptic_pwm.period);
#endif
}

static inline void haptic_motor_off(void)
{
#if HAPTIC_PWM_AVAILABLE
    if (!pwm_is_ready_dt(&haptic_pwm)) {
        return;
    }
    pwm_set_dt(&haptic_pwm, haptic_pwm.period, 0);
#endif
}

int init_haptic_pin()
{
#if HAPTIC_PWM_AVAILABLE
    if (!pwm_is_ready_dt(&haptic_pwm)) {
        LOG_WRN("Haptic PWM (A1/P0.03) not ready — haptic disabled, boot continues");
        return 0;  /* non-fatal: LED + USB must still boot */
    }
    /* Motor off at startup. */
    haptic_motor_off();
    LOG_INF("Haptic PWM (A1/P0.03) ready");
#else
    LOG_WRN("Haptic PWM node not present in DT — haptic disabled");
#endif
    return 0;
}

void haptic_timer_callback(struct k_timer *timer);

K_TIMER_DEFINE(my_status_timer, haptic_timer_callback, NULL);

void haptic_timer_callback(struct k_timer *timer)
{
    haptic_motor_off();
}

void play_haptic_milli(uint32_t duration)
{
    if (duration > MAX_HAPTIC_DURATION) {
        LOG_ERR("Duration is too long");
        return;
    }
    haptic_motor_on();
    k_timer_start(&my_status_timer, K_MSEC(duration), K_NO_WAIT);
}

/* --------------------------------------------------------------------------
 * Haptic sequencer — Phase A
 *
 * Each haptic_pattern_t is a small table of (on_ms, gap_ms) pulse pairs.
 * The work-queue item steps through the table: fires the motor, schedules
 * itself for (on_ms + gap_ms), then turns the motor off at the gap boundary
 * via a one-shot k_timer.  Non-blocking; safe to call from any context.
 * -------------------------------------------------------------------------- */

typedef struct {
    uint16_t on_ms;
    uint16_t gap_ms; /* silence after this pulse (0 for the last entry) */
} haptic_pulse_t;

static const haptic_pulse_t haptic_seq_single[]  = { {120, 0} };
static const haptic_pulse_t haptic_seq_long[]    = { {500, 0} };
static const haptic_pulse_t haptic_seq_double[]  = { {120, 100}, {120, 0} };
static const haptic_pulse_t haptic_seq_triple[]  = { {120, 80},  {120, 80}, {120, 0} };
static const haptic_pulse_t haptic_seq_ramp[]    = { {80,  40},  {120, 0} };
static const haptic_pulse_t haptic_seq_tick[]    = { {30,  0} };

typedef struct {
    const haptic_pulse_t *pulses;
    uint8_t               count;
    uint8_t               index;
    bool                  active;
} haptic_seq_state_t;

static haptic_seq_state_t haptic_state = {0};
static K_MUTEX_DEFINE(haptic_seq_mutex);

static void haptic_seq_work_fn(struct k_work *work);
static K_WORK_DELAYABLE_DEFINE(haptic_seq_work, haptic_seq_work_fn);

/* Called by the one-shot timer to turn the motor off after on_ms. */
static void haptic_seq_off_cb(struct k_timer *timer)
{
    ARG_UNUSED(timer);
    haptic_motor_off();
}
static K_TIMER_DEFINE(haptic_seq_off_timer, haptic_seq_off_cb, NULL);

static void haptic_seq_work_fn(struct k_work *work)
{
    ARG_UNUSED(work);
    k_mutex_lock(&haptic_seq_mutex, K_FOREVER);
    if (!haptic_state.active || haptic_state.index >= haptic_state.count) {
        haptic_state.active = false;
        k_mutex_unlock(&haptic_seq_mutex);
        return;
    }
    const haptic_pulse_t *p = &haptic_state.pulses[haptic_state.index];
    haptic_state.index++;
    bool more = (haptic_state.index < haptic_state.count);
    uint16_t on_ms  = p->on_ms;
    uint16_t gap_ms = p->gap_ms;
    k_mutex_unlock(&haptic_seq_mutex);

    haptic_motor_on();
    k_timer_start(&haptic_seq_off_timer, K_MSEC(on_ms), K_NO_WAIT);

    if (more) {
        /* Schedule next pulse after on + gap. */
        k_work_schedule(&haptic_seq_work, K_MSEC(on_ms + gap_ms));
    } else {
        k_mutex_lock(&haptic_seq_mutex, K_FOREVER);
        haptic_state.active = false;
        k_mutex_unlock(&haptic_seq_mutex);
    }
}

void haptic_play(haptic_pattern_t pattern)
{
    const haptic_pulse_t *pulses;
    uint8_t count;

    switch (pattern) {
    case HAPTIC_SINGLE: pulses = haptic_seq_single; count = ARRAY_SIZE(haptic_seq_single); break;
    case HAPTIC_LONG:   pulses = haptic_seq_long;   count = ARRAY_SIZE(haptic_seq_long);   break;
    case HAPTIC_DOUBLE: pulses = haptic_seq_double;  count = ARRAY_SIZE(haptic_seq_double);  break;
    case HAPTIC_TRIPLE: pulses = haptic_seq_triple;  count = ARRAY_SIZE(haptic_seq_triple);  break;
    case HAPTIC_RAMP:   pulses = haptic_seq_ramp;    count = ARRAY_SIZE(haptic_seq_ramp);    break;
    case HAPTIC_TICK:   pulses = haptic_seq_tick;    count = ARRAY_SIZE(haptic_seq_tick);    break;
    default:            return;
    }

    k_mutex_lock(&haptic_seq_mutex, K_FOREVER);
    haptic_state.pulses = pulses;
    haptic_state.count  = count;
    haptic_state.index  = 0;
    haptic_state.active = true;
    k_mutex_unlock(&haptic_seq_mutex);

    /* Cancel any in-flight sequence and start fresh. */
    k_work_cancel_delayable(&haptic_seq_work);
    k_timer_stop(&haptic_seq_off_timer);
    haptic_motor_off();
    k_work_schedule(&haptic_seq_work, K_NO_WAIT);
}

/* --------------------------------------------------------------------------
 * Speaker link stubs — TEMPORARY, delete with their call sites.
 *
 * Slice S4 deleted the I2S speaker: driver, the two 10 KB mem-slabs, speak(),
 * the boot chime and the CAB1AB95/CAB1AB96 GATT service.  This hardware has no
 * audio output and none is planned, so nothing here is coming back.
 *
 * These five symbols survive only because files owned by other slices still
 * call them under CONFIG_KELVINLEE_ENABLE_SPEAKER, which the acceptance build
 * (prj_xiao_ble_sense_devkitv2-adafruit.conf) leaves at =y:
 *
 *   main.c       — speaker_init(), play_boot_sound()
 *   transport.c  — speak() (0x19B10003 write handler), register_speaker_service()
 *   button.c     — speaker_off() in turnoff_all()
 *
 * Removing them is the boot slice's job: drop the call sites (or set
 * CONFIG_KELVINLEE_ENABLE_SPEAKER=n, as every other prj_wearable_*.conf already
 * does), then delete these stubs and their declarations from speaker.h.
 * -------------------------------------------------------------------------- */





