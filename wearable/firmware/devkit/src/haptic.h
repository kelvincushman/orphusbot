/* Copyright (c) 2025-2026 Kelvin Lee. Licensed under MIT. Portions (c) 2024 Based Hardware Contributors, MIT (see LICENSE-UPSTREAM). */

#ifndef SPEAKER_H
#define SPEAKER_H

#include <zephyr/kernel.h>

/**
 * @brief Initialize the haptic (vibration motor) PWM.
 *
 * Non-fatal: returns 0 and logs a warning when the motor is absent, so boot
 * continues on a board with no vibration motor soldered.
 *
 * @return 0 if successful, negative errno code if error
 */
int init_haptic_pin();

/**
 * @brief Activate the haptic motor for a given duration
 *
 * On Call, starts the haptic motor, creating a vibration for the given
 * duration in milliseconds. Durations above 5000 ms are rejected.
 */
void play_haptic_milli(uint32_t duration);

/**
 * @brief Named haptic pattern IDs (Phase A).
 *
 * Each pattern runs a non-blocking timer-sequenced pulse sequence on A1/P0.03 (PWM).
 */
typedef enum {
    HAPTIC_SINGLE   = 0,  /* ● 120 ms */
    HAPTIC_LONG     = 1,  /* ▬ 500 ms */
    HAPTIC_DOUBLE   = 2,  /* ●● 120/100gap/120 */
    HAPTIC_TRIPLE   = 3,  /* ●●● triple */
    HAPTIC_RAMP     = 4,  /* ramp: 80/40gap/120 ms rising */
    HAPTIC_TICK     = 5,  /* short tick ≈ 30 ms (threshold cue) */
} haptic_pattern_t;

/**
 * @brief Play a named haptic pattern (non-blocking, work-queue driven).
 *
 * Multiple calls are queued: the sequencer finishes the current pulse
 * before starting the next segment. Safe to call from any context.
 */
void haptic_play(haptic_pattern_t pattern);

/*
 * Speaker link stubs — TEMPORARY, delete with their call sites.
 *
 * The I2S speaker was deleted in slice S4 (no audio hardware on this device,
 * none planned). These declarations remain only so main.c, transport.c and
 * button.c still link while CONFIG_KELVINLEE_ENABLE_SPEAKER=y. All five are
 * no-ops; see the matching block in speaker.c.
 */

#endif
