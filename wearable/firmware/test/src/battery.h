/* Copyright (c) 2025-2026 Kelvin Lee. Licensed under MIT. Portions (c) 2024 Based Hardware Contributors, MIT (see LICENSE-UPSTREAM). */

#ifndef BATTERY_H
#define BATTERY_H

#include <zephyr/input/input.h>
#include <zephyr/kernel.h>

extern bool is_charging;

int bat_init(void);

#endif // BATTERY_H