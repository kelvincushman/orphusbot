/* Copyright (c) 2025-2026 Kelvin Lee. Licensed under MIT. */

/*
 * battery.h — cell gauge and charger pin control for the Xiao nRF52840.
 *
 * The board taps the cell through a resistor divider into SAADC AIN7, gated
 * by an enable pin so the divider does not idle-drain. Charge current select
 * and the charge-status LED each sit on their own pin. Call battery_init()
 * once before anything else here.
 */

#ifndef WEARABLE_BATTERY_H
#define WEARABLE_BATTERY_H

#include <stdint.h>

/**
 * Configure the sense channel and the three charger pins.
 * Leaves the divider enabled and the charge current set to fast.
 *
 * @return 0, or a negative errno.
 */
int battery_init(void);

/** Select the 100 mA charge current. @return 0, or a negative errno. */
int battery_set_fast_charge(void);

/** Select the 50 mA charge current. @return 0, or a negative errno. */
int battery_set_slow_charge(void);

/**
 * Enable the sense divider and light the charge-status LED.
 *
 * @return 0, or a negative errno.
 */
int battery_charge_start(void);

/**
 * Extinguish the charge-status LED. Saves the LED current during runtime.
 *
 * @return 0, or a negative errno.
 */
int battery_charge_stop(void);

/**
 * Sample the cell voltage.
 *
 * @param[out] battery_millivolt Cell voltage in mV.
 *
 * @return 0, or a negative errno.
 */
int battery_get_millivolt(uint16_t *battery_millivolt);

/**
 * Map a cell voltage onto remaining charge for a 1S LiPo.
 *
 * @param[out] battery_percentage Remaining charge, 0-100.
 * @param[in]  battery_millivolt  Cell voltage in mV, from battery_get_millivolt().
 *
 * @return 0.
 */
int battery_get_percentage(uint8_t *battery_percentage, uint16_t battery_millivolt);

#endif /* WEARABLE_BATTERY_H */
