/* Copyright (c) 2025-2026 Kelvin Lee. Licensed under MIT. Portions (c) 2024 Based Hardware Contributors, MIT (see LICENSE-UPSTREAM). */

#include "codec.h"

#include <errno.h>
#include <zephyr/kernel.h>
#include <zephyr/logging/log.h>
#include <zephyr/sys/ring_buffer.h>

#include "config.h"
// config.h hard-errors unless CONFIG_KELVINLEE_CODEC_OPUS is set, so Opus is
// the only codec this file ever builds against -- no #if CODEC_OPUS ladders.
#include "lib/opus-1.2.1/opus.h"

LOG_MODULE_REGISTER(codec, CONFIG_LOG_DEFAULT_LEVEL);

// Size of the Opus encoder state for this build. config.h selects
// CONFIG_OPUS_MODE_CELT, which compiles SILK out of opus_encoder.c, so
// opus_encoder_get_size(1) == align(sizeof(OpusEncoder)) + celt_encoder_get_size(1)
//   = 2200 + (240 + (120 - 1) * 4 + 1024 * 4 + 4 * 21 * 2)
//   = 7180
// (240 = sizeof(struct OpusCustomEncoder), 120/21 = overlap/nbEBands of the
// static 48 kHz mode, celt_sig = 4 B and opus_val16 = 2 B under FIXED_POINT.)
// opus_encoder_get_size() is a run-time call, so this cannot be a BUILD_ASSERT;
// codec_start() checks the real size against this buffer instead. Flipping
// CONFIG_OPUS_MODE invalidates the number and that check will catch it.
#define OPUS_ENCODER_SIZE 7180

//
// Output
//

static volatile codec_callback _callback = NULL;

void set_codec_callback(codec_callback callback)
{
    _callback = callback;
}

//
// Input
//

static uint8_t codec_ring_buffer_data[AUDIO_BUFFER_SAMPLES * 2]; // 2 bytes per sample
static struct ring_buf codec_ring_buf;

int codec_receive_pcm(int16_t *data, size_t len) // this gets called after mic data is finished
{
    uint32_t bytes = len * 2;

    // Refuse the whole buffer rather than let ring_buf_put() take a partial
    // one: a short write would split a 16-bit sample and desynchronise every
    // frame after it. Single producer (PDM ISR) + single consumer (codec
    // thread) is the pattern ring_buf is lock-free for.
    if (ring_buf_space_get(&codec_ring_buf) < bytes) {
        LOG_WRN("Codec ring buffer full, dropping %u bytes", bytes);
        return -ENOSPC;
    }

    ring_buf_put(&codec_ring_buf, (uint8_t *) data, bytes);
    return 0;
}

//
// Thread
//

static int16_t codec_input_samples[CODEC_PACKAGE_SAMPLES];
static uint8_t codec_output_bytes[CODEC_OUTPUT_MAX_BYTES];

// Opus is built with USE_ALLOCA, so the encoder's working set lives on this
// stack. 32 KB is the upstream number and has not been measured on target.
K_THREAD_STACK_DEFINE(codec_stack, 32000);
static struct k_thread codec_thread;

static uint8_t m_opus_encoder[OPUS_ENCODER_SIZE] __aligned(4);
static OpusEncoder *const m_opus_state = (OpusEncoder *) m_opus_encoder;

static uint16_t execute_codec(void)
{
    opus_int32 size = opus_encode(
        m_opus_state, codec_input_samples, CODEC_PACKAGE_SAMPLES, codec_output_bytes, sizeof(codec_output_bytes));
    if (size < 0) {
        LOG_WRN("Opus encoding failed: %d", size);
        return 0;
    }
    LOG_DBG("Opus encoding success: %d", size);
    return (uint16_t) size;
}

static void codec_entry(void *p1, void *p2, void *p3)
{
    ARG_UNUSED(p1);
    ARG_UNUSED(p2);
    ARG_UNUSED(p3);

    while (1) {

        // Check if we have enough data
        if (ring_buf_size_get(&codec_ring_buf) < CODEC_PACKAGE_SAMPLES * 2) {
            k_sleep(K_MSEC(10));
            continue;
        }

        // Read package
        ring_buf_get(&codec_ring_buf, (uint8_t *) codec_input_samples, CODEC_PACKAGE_SAMPLES * 2);

        // Run Codec
        uint16_t output_size = execute_codec();

        // Notify. A zero-length frame means the encoder failed; there is
        // nothing worth putting on the air for it.
        if (output_size > 0 && _callback) {
            _callback(codec_output_bytes, output_size);
        }

        // Yield
        k_yield();
    }
}

int codec_start(void)
{
    // The real guard on m_opus_encoder. opus_encoder_get_size() is a run-time
    // call, so BUILD_ASSERT cannot be used; a buffer at least that large is
    // all opus_encoder_init() asks for.
    int encoder_size = opus_encoder_get_size(1);
    if (encoder_size <= 0 || (size_t) encoder_size > sizeof(m_opus_encoder)) {
        LOG_ERR("Opus encoder needs %d bytes, have %u", encoder_size, (unsigned int) sizeof(m_opus_encoder));
        return -ENOMEM;
    }

    int err = opus_encoder_init(m_opus_state, 16000, 1, CODEC_OPUS_APPLICATION);
    if (err != OPUS_OK) {
        LOG_ERR("Opus encoder init failed: %d", err);
        return -EIO;
    }

    // Every Opus error code is negative, so summing them can never cancel back
    // to OPUS_OK -- one check covers the whole block.
    err = opus_encoder_ctl(m_opus_state, OPUS_SET_BITRATE(CODEC_OPUS_BITRATE));
    err += opus_encoder_ctl(m_opus_state, OPUS_SET_VBR(CODEC_OPUS_VBR));
    err += opus_encoder_ctl(m_opus_state, OPUS_SET_VBR_CONSTRAINT(0));
    err += opus_encoder_ctl(m_opus_state, OPUS_SET_COMPLEXITY(CODEC_OPUS_COMPLEXITY));
    err += opus_encoder_ctl(m_opus_state, OPUS_SET_SIGNAL(OPUS_SIGNAL_VOICE));
    err += opus_encoder_ctl(m_opus_state, OPUS_SET_LSB_DEPTH(16));
    err += opus_encoder_ctl(m_opus_state, OPUS_SET_DTX(0));
    err += opus_encoder_ctl(m_opus_state, OPUS_SET_INBAND_FEC(0));
    err += opus_encoder_ctl(m_opus_state, OPUS_SET_PACKET_LOSS_PERC(0));
    if (err != OPUS_OK) {
        LOG_ERR("Opus encoder configuration failed: %d", err);
        return -EIO;
    }

    // Thread
    ring_buf_init(&codec_ring_buf, sizeof(codec_ring_buffer_data), codec_ring_buffer_data);
    k_thread_create(&codec_thread,
                    codec_stack,
                    K_THREAD_STACK_SIZEOF(codec_stack),
                    codec_entry,
                    NULL,
                    NULL,
                    NULL,
                    K_PRIO_PREEMPT(4),
                    0,
                    K_NO_WAIT);

    // Success
    return 0;
}
