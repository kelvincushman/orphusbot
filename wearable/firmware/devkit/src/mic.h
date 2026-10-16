/* Copyright (c) 2025-2026 Kelvin Lee. Licensed under MIT. Portions (c) 2024 Based Hardware Contributors, MIT (see LICENSE-UPSTREAM). */

#ifndef MIC_H
#define MIC_H

#include <stdbool.h>
#include <stdint.h>

/** Receives one full PDM buffer of MIC_BUFFER_SAMPLES 16-bit samples. Runs in ISR context. */
typedef void (*mix_handler)(int16_t *);

/**
 * @brief Initialize the Microphone
 *
 * Powers the mic rail, configures PDM for 16 kHz mono and starts sampling.
 *
 * @return 0 if successful, negative errno code if error
 */
int mic_start(void);
void set_mic_callback(mix_handler callback);

/** Cut / restore the mic supply rail. PDM keeps running either way. */
void mic_off(void);
void mic_on(void);
#endif
