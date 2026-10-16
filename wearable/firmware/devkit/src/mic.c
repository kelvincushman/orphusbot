/* Copyright (c) 2025-2026 Kelvin Lee. Licensed under MIT. Portions (c) 2024 Based Hardware Contributors, MIT (see LICENSE-UPSTREAM). */

#include "mic.h"

#include <errno.h>
#include <hal/nrf_clock.h>
#include <haly/nrfy_gpio.h>
#include <nrfx_pdm.h>
#include <zephyr/kernel.h>
#include <zephyr/logging/log.h>

#include "config.h"

LOG_MODULE_REGISTER(mic, CONFIG_LOG_DEFAULT_LEVEL);

//
// Port of this code: https://github.com/Seeed-Studio/Seeed_Arduino_Mic/blob/master/src/hardware/nrf52840_adc.cpp
//

// Double buffered: the driver asks for the next buffer while it is still
// filling the current one, so the callback always gets a buffer the hardware
// has finished with. 1600 samples = 100 ms at 16 kHz.
static int16_t _buffers[2][MIC_BUFFER_SAMPLES];
static uint8_t _next_buffer; // ISR context only
static volatile mix_handler _callback = NULL;

// nrfx 4.x multi-instance PDM API. NRFX_PDM_INSTANCE() now takes the
// peripheral base address, and the driver keeps its control block inside the
// instance object, so it cannot be const. nRF52840 has only PDM0.
static nrfx_pdm_t pdm_instance = NRFX_PDM_INSTANCE(NRF_PDM);

// nrfx 4.x no longer ships per-instance ISRs; define nrfx_pdm_0_irq_handler.
NRFX_INSTANCE_IRQ_HANDLER_DEFINE(pdm, 0, &pdm_instance);

static void pdm_irq_handler(nrfx_pdm_evt_t const *event)
{
    // Overflow is the only error the driver reports and the frame is already
    // lost, so log it and keep sampling.
    if (event->error) {
        LOG_ERR("PDM error: %d", event->error);
        return;
    }

    if (event->buffer_requested) {
        LOG_DBG("Audio buffer requested");
        // nrfx 4.x returns a plain errno, 0 == success. Never compare against
        // NRFX_SUCCESS here: it is the deprecated 0x0BAD0000 sentinel and the
        // comparison would be unconditionally true.
        int err = nrfx_pdm_buffer_set(&pdm_instance, _buffers[_next_buffer], MIC_BUFFER_SAMPLES);
        if (err != 0) {
            // Keep _next_buffer where it is so the retry re-offers this buffer.
            LOG_ERR("Audio unable to queue PDM buffer: %d", err);
        } else {
            _next_buffer ^= 1;
        }
    }

    if (event->buffer_released) {
        LOG_DBG("Audio buffer released");
        if (_callback) {
            _callback(event->buffer_released);
        }
    }
}

int mic_start(void)
{

    // Start the high frequency clock
    nrf_clock_hfclk_t hfclk_src;
    if (!nrf_clock_is_running(NRF_CLOCK, NRF_CLOCK_DOMAIN_HFCLK, &hfclk_src) ||
        hfclk_src != NRF_CLOCK_HFCLK_HIGH_ACCURACY) {
        nrf_clock_task_trigger(NRF_CLOCK, NRF_CLOCK_TASK_HFCLKSTART);
    }

    // Power on the mic FIRST and let its rail / charge-pump settle before the
    // PDM clock starts. The MSM261 MEMS mic needs a wake-up window or its first
    // samples are invalid/zero. (mic-silence fix, 2026-07-01)
    nrfy_gpio_cfg_output(PDM_PWR_PIN);
    nrfy_gpio_pin_set(PDM_PWR_PIN);
    k_msleep(10);

    // Configure PDM: mono, 1.28 MHz / 80 = 16 kHz, sampled on the falling edge.
    nrfx_pdm_config_t pdm_config = NRFX_PDM_DEFAULT_CONFIG(PDM_CLK_PIN, PDM_DIN_PIN);
    pdm_config.mode = NRF_PDM_MODE_MONO;
    pdm_config.edge = NRF_PDM_EDGE_LEFTFALLING;
    pdm_config.gain_l = MIC_GAIN;
    pdm_config.gain_r = MIC_GAIN;
    pdm_config.prescalers.clock_freq = NRF_PDM_FREQ_1280K;
    pdm_config.prescalers.ratio = NRF_PDM_RATIO_80X;

    // ponytail: pdm_config.interrupt_priority is deliberately left at its
    // default. Zephyr's nrfx glue defines NRFX_IRQ_PRIORITY_SET as a no-op, so
    // the field never reaches the NVIC -- IRQ_DIRECT_CONNECT below is the only
    // thing that sets the PDM priority.
    IRQ_DIRECT_CONNECT(PDM_IRQn, MIC_IRQ_PRIORITY, nrfx_pdm_0_irq_handler, 0);

    int err = nrfx_pdm_init(&pdm_instance, &pdm_config, pdm_irq_handler);
    if (err != 0) {
        LOG_ERR("Audio unable to initialize PDM: %d", err);
        nrfy_gpio_pin_clear(PDM_PWR_PIN);
        return -EIO;
    }

    // Start PDM (mic already powered + settled above)
    err = nrfx_pdm_start(&pdm_instance);
    if (err != 0) {
        LOG_ERR("Audio unable to start PDM: %d", err);
        nrfx_pdm_uninit(&pdm_instance);
        nrfy_gpio_pin_clear(PDM_PWR_PIN);
        return -EIO;
    }

    LOG_INF("Audio microphone started");
    return 0;
}

void set_mic_callback(mix_handler callback)
{
    _callback = callback;
}

void mic_off(void)
{
    nrfy_gpio_pin_clear(PDM_PWR_PIN);
}

void mic_on(void)
{
    nrfy_gpio_pin_set(PDM_PWR_PIN);
}
