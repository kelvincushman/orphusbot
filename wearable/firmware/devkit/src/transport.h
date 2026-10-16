/* Copyright (c) 2025-2026 Kelvin Lee. Licensed under MIT. Portions (c) 2024 Based Hardware Contributors, MIT (see LICENSE-UPSTREAM). */

#ifndef TRANSPORT_H
#define TRANSPORT_H

#include <zephyr/drivers/sensor.h>

/* One accelerometer + gyro sample, notified verbatim on the accel
 * characteristic. Compiled in unconditionally; only main.c's accel_start()
 * call is behind CONFIG_KELVINLEE_ENABLE_ACCELEROMETER. */
struct sensors {
    struct sensor_value a_x;
    struct sensor_value a_y;
    struct sensor_value a_z;
    struct sensor_value g_x;
    struct sensor_value g_y;
    struct sensor_value g_z;
};

/**
 * @brief Initialize the BLE transport logic
 *
 * Initializes the BLE Logic
 *
 * @return 0 if successful, negative errno code if error
 */
int transport_start();
int broadcast_audio_packets(uint8_t *buffer, size_t size);
/**
 * @brief Borrow the current BLE connection.
 *
 * Returns a NEW reference, or NULL when nothing is attached. The caller owns
 * that reference and MUST bt_conn_unref() it on every path; until it does, the
 * connection object cannot be freed out from under it by a disconnect.
 */
struct bt_conn *get_current_connection();
int bt_on();
int bt_off();

int accel_start();
void accel_off();
#endif
