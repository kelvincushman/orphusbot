/* Copyright (c) 2025-2026 Kelvin Lee. Licensed under MIT. Portions (c) 2024 Based Hardware Contributors, MIT (see LICENSE-UPSTREAM). */

#include "led.h"

#include <zephyr/drivers/gpio.h>
#include <zephyr/logging/log.h>

#include "utils.h"

LOG_MODULE_REGISTER(led, CONFIG_LOG_DEFAULT_LEVEL);

int led_start()
{
    // All three sit on the same GPIO controller (P0.26 / P0.30 / P0.06), so a
    // single loop is enough: readiness is all-or-nothing.
    const struct gpio_dt_spec *const leds[] = {&led_red, &led_green, &led_blue};

    for (size_t i = 0; i < ARRAY_SIZE(leds); i++) {
        ASSERT_TRUE(gpio_is_ready_dt(leds[i]));
        ASSERT_OK(gpio_pin_configure_dt(leds[i], GPIO_OUTPUT_INACTIVE));
    }

    LOG_INF("LEDs started");
    return 0;
}

void set_led_red(bool on)
{
    gpio_pin_set_dt(&led_red, on);
}

void set_led_green(bool on)
{
    gpio_pin_set_dt(&led_green, on);
}

void set_led_blue(bool on)
{
    gpio_pin_set_dt(&led_blue, on);
}
