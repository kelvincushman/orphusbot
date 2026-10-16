/* Copyright (c) 2025-2026 Kelvin Lee. Licensed under MIT. Portions (c) 2024 Based Hardware Contributors, MIT (see LICENSE-UPSTREAM). */

#ifndef CODEC_H
#define CODEC_H
#include <zephyr/kernel.h>

// Callback
/** Receives one encoded Opus frame (<= CODEC_OUTPUT_MAX_BYTES). Runs on the codec thread. */
typedef void (*codec_callback)(uint8_t *data, size_t len);
void set_codec_callback(codec_callback callback);

// Integration

/** Queue @p len 16-bit PCM samples for encoding. Safe to call from an ISR. */
int codec_receive_pcm(int16_t *data, size_t len);

/**
 * @brief Initialize the Codec
 *
 * Initializes the Opus encoder and starts the encoder thread.
 *
 * @return 0 if successful, negative errno code if error
 */
int codec_start(void);

#endif
