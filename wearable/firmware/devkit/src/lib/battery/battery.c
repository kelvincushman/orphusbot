/* Copyright (c) 2025-2026 Kelvin Lee. Licensed under MIT. */

#include "battery.h"

#include <zephyr/device.h>
#include <zephyr/devicetree.h>
#include <zephyr/drivers/adc.h>
#include <zephyr/drivers/gpio.h>
#include <zephyr/logging/log.h>

#ifdef CONFIG_ADC_NRFX_SAADC
#include <hal/nrf_saadc.h>
#endif

LOG_MODULE_REGISTER(battery, LOG_LEVEL_INF);

/*
 * Power pins, all on gpio0, all asserted by driving low, so they are declared
 * active-low and driven with logical values (see docs/PIN_MAP.md).
 */
#define PIN_CHARGE_CURRENT 13 /* asserted -> 100 mA, released -> 50 mA */
#define PIN_SENSE_ENABLE   14 /* asserted -> divider connected to AIN7 */
#define PIN_CHARGE_LED     17 /* asserted -> charge indicator lit */

/*
 * Cell sense sits on AIN7 (P0.31). 12 bits against the 0.6 V band gap at 1/6
 * gain gives a 3.6 V full scale, well clear of the ~1.42 V the divider
 * presents at a full 4.2 V cell. Averaging is left to the SAADC: 2^4 samples
 * per conversion costs nothing in code and nothing in thread time.
 */
#define SENSE_CHANNEL      7
#define SENSE_RESOLUTION   12
#define SENSE_GAIN         ADC_GAIN_1_6
#define SENSE_OVERSAMPLING 4

/*
 * Divider is 1 MOhm high side over 510 kOhm low side, so the cell is
 * 1510/510 = 2.961x whatever the ADC sees. Kept in permille because this is
 * the one number that has to be trimmed against real hardware -- resistor
 * tolerance and SAADC offset each move it by a percent or so. Raise it if the
 * reported voltage reads low against a bench meter.
 */
#define DIVIDER_PERMILLE 2961

static const struct device *const adc_dev = DEVICE_DT_GET(DT_NODELABEL(adc));
static const struct device *const gpio_dev = DEVICE_DT_GET(DT_NODELABEL(gpio0));

static const struct adc_channel_cfg sense_channel = {
    .gain = SENSE_GAIN,
    .reference = ADC_REF_INTERNAL,
    .acquisition_time = ADC_ACQ_TIME_DEFAULT,
    .channel_id = SENSE_CHANNEL,
#ifdef CONFIG_ADC_NRFX_SAADC
    .input_positive = NRF_SAADC_INPUT_AIN7,
#endif
};

static int configure_output(gpio_pin_t pin)
{
    return gpio_pin_configure(gpio_dev, pin, GPIO_OUTPUT_INACTIVE | GPIO_ACTIVE_LOW);
}

int battery_init(void)
{
    if (!device_is_ready(adc_dev) || !device_is_ready(gpio_dev)) {
        LOG_ERR("ADC or GPIO not ready");
        return -ENODEV;
    }

    int err = configure_output(PIN_CHARGE_CURRENT);
    if (!err) {
        err = configure_output(PIN_SENSE_ENABLE);
    }
    if (!err) {
        err = configure_output(PIN_CHARGE_LED);
    }
    if (err) {
        LOG_ERR("Charger pin configure failed (%d)", err);
        return err;
    }

    err = adc_channel_setup(adc_dev, &sense_channel);
    if (err) {
        LOG_ERR("Sense channel setup failed (%d)", err);
        return err;
    }

    err = gpio_pin_set(gpio_dev, PIN_SENSE_ENABLE, 1);
    if (err) {
        return err;
    }

    LOG_INF("Initialized");
    return battery_set_fast_charge();
}

int battery_set_fast_charge(void)
{
    return gpio_pin_set(gpio_dev, PIN_CHARGE_CURRENT, 1);
}

int battery_set_slow_charge(void)
{
    return gpio_pin_set(gpio_dev, PIN_CHARGE_CURRENT, 0);
}

int battery_charge_start(void)
{
    int err = gpio_pin_set(gpio_dev, PIN_SENSE_ENABLE, 1);

    return err ? err : gpio_pin_set(gpio_dev, PIN_CHARGE_LED, 1);
}

int battery_charge_stop(void)
{
    return gpio_pin_set(gpio_dev, PIN_CHARGE_LED, 0);
}

int battery_get_millivolt(uint16_t *battery_millivolt)
{
    int16_t raw = 0;
    const struct adc_sequence sequence = {
        .channels = BIT(SENSE_CHANNEL),
        .buffer = &raw,
        .buffer_size = sizeof(raw),
        .resolution = SENSE_RESOLUTION,
        .oversampling = SENSE_OVERSAMPLING,
    };

    int err = adc_read(adc_dev, &sequence);
    if (err) {
        LOG_ERR("Sense read failed (%d)", err);
        return err;
    }

    /* SAADC reads a little below zero at the bottom of its range. */
    int32_t adc_millivolt = raw > 0 ? raw : 0;

    err = adc_raw_to_millivolts(adc_ref_internal(adc_dev), SENSE_GAIN, SENSE_RESOLUTION,
                                &adc_millivolt);
    if (err) {
        return err;
    }

    *battery_millivolt = (uint16_t) (adc_millivolt * DIVIDER_PERMILLE / 1000);
    LOG_DBG("cell %u mV", *battery_millivolt);
    return 0;
}

/*
 * Piecewise-linear 1S LiPo discharge curve under light load: near-linear from
 * full down to the 3.9 V knee, a long flat plateau through the middle, then a
 * steep collapse below 3.5 V. Deliberately coarse -- a NeoPixel or motor pulse
 * sags the cell further than the error between these knees.
 */
int battery_get_percentage(uint8_t *battery_percentage, uint16_t battery_millivolt)
{
    const uint16_t mv = battery_millivolt;
    uint8_t percent;

    if (mv >= 4150) {
        percent = 100;
    } else if (mv >= 3900) {
        percent = 75 + (mv - 3900) * 25 / 250;
    } else if (mv >= 3700) {
        percent = 35 + (mv - 3700) * 40 / 200;
    } else if (mv >= 3500) {
        percent = 10 + (mv - 3500) * 25 / 200;
    } else if (mv >= 3300) {
        percent = (mv - 3300) * 10 / 200;
    } else {
        percent = 0;
    }

    *battery_percentage = percent;
    LOG_DBG("cell %u %%", percent);
    return 0;
}
