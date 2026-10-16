/* Copyright (c) 2025-2026 Kelvin Lee. Licensed under MIT. Portions (c) 2024 Based Hardware Contributors, MIT (see LICENSE-UPSTREAM). */

#include "transport.h"

#include <zephyr/bluetooth/bluetooth.h>
#include <zephyr/bluetooth/gatt.h>
#include <zephyr/bluetooth/hci.h>
#include <zephyr/bluetooth/l2cap.h>
#include <zephyr/bluetooth/services/bas.h>
#include <zephyr/bluetooth/uuid.h>
#include <zephyr/drivers/gpio.h>
#include <zephyr/drivers/sensor.h>
#include <zephyr/kernel.h>
#include <zephyr/logging/log.h>
#include <zephyr/sys/atomic.h>
#include <zephyr/sys/ring_buffer.h>

#include "button.h"
#include "config.h"
#include "habitat.h"
#include "haptic.h"
#include "lib/battery/battery.h"
#include "mic.h"
#include "sdcard.h"
#include "storage.h"
#include "utils.h"

LOG_MODULE_REGISTER(transport, CONFIG_LOG_DEFAULT_LEVEL);

/* Defined in main.c and storage.c respectively. */
extern bool is_connected;
extern bool storage_is_on;
extern struct bt_gatt_service storage_service;

/*
 * Connection lifetime.
 *
 * Invariant: current_connection is only ever read or written while holding
 * conn_lock, it owns exactly one reference for as long as it is non-NULL, and
 * every pointer handed out of this file carries its own additional reference
 * that the caller must release -- so a caller's pointer stays valid until that
 * caller unrefs it, whatever the BT RX thread does to current_connection in
 * the meantime.
 *
 * Static because nothing outside this file may reach the bare pointer;
 * get_current_connection() is the only way out, and it refs.
 */
static struct bt_conn *current_connection = NULL;
static struct k_spinlock conn_lock;

/* True while the app wants to be connectable. Set after each successful
 * bt_le_adv_start(), cleared at the top of bt_off() so the recycled callback
 * does not try to restart advertising against a stack that is being disabled.
 *
 * Why this exists: on the NCS baseline BT_LE_ADV_CONN made the host resume
 * advertising by itself after a disconnect. The Zephyr 4.4.2 port replaced
 * that (removed) macro with BT_LE_ADV_CONN_FAST_2, whose BT_LE_ADV_OPT_CONN
 * is one-shot -- the host no longer resumes, the application must. Nothing in
 * this file ever restarted advertising because it never had to, so every
 * post-port image stopped being connectable after its first disconnect. */
static volatile bool adv_wanted;
uint16_t current_mtu = 0;

/*
 * Install new_conn (already referenced, or NULL) and hand back the pointer it
 * displaced, still holding the reference the global owned. The caller unrefs
 * that outside the lock. This is the only writer of current_connection.
 */
static struct bt_conn *conn_swap(struct bt_conn *new_conn)
{
    k_spinlock_key_t key = k_spin_lock(&conn_lock);
    struct bt_conn *old = current_connection;

    current_connection = new_conn;
    k_spin_unlock(&conn_lock, key);

    return old;
}

/*
 * Serialises the SD write path against bt_off() cutting the card out from under
 * it. sdcard.c has its own mutex covering the filesystem itself; this one is
 * always taken first and sdcard.c never reaches back for it, so there is no
 * lock cycle.
 */
static struct k_mutex write_sdcard_mutex;

//
// Service and Characteristic
//
// Audio service with UUID 19B10000-E8F2-537E-4F6C-D104768A1214
// exposes following characteristics:
// - Audio data (UUID 19B10001-E8F2-537E-4F6C-D104768A1214) to send audio data (read/notify)
// - Audio codec (UUID 19B10002-E8F2-537E-4F6C-D104768A1214) to send audio codec type (read)
// TODO: The current audio service UUID seems to come from old Intel sample code,
// we should change it to UUID 814b9b7c-25fd-4acd-8604-d28877beee6d
static void audio_ccc_config_changed_handler(const struct bt_gatt_attr *attr, uint16_t value);
static ssize_t audio_data_read_characteristic(struct bt_conn *conn,
                                              const struct bt_gatt_attr *attr,
                                              void *buf,
                                              uint16_t len,
                                              uint16_t offset);
static ssize_t audio_codec_read_characteristic(struct bt_conn *conn,
                                               const struct bt_gatt_attr *attr,
                                               void *buf,
                                               uint16_t len,
                                               uint16_t offset);

static struct bt_uuid_128 audio_service_uuid =
    BT_UUID_INIT_128(BT_UUID_128_ENCODE(0x19B10000, 0xE8F2, 0x537E, 0x4F6C, 0xD104768A1214));
static struct bt_uuid_128 audio_characteristic_data_uuid =
    BT_UUID_INIT_128(BT_UUID_128_ENCODE(0x19B10001, 0xE8F2, 0x537E, 0x4F6C, 0xD104768A1214));
static struct bt_uuid_128 audio_characteristic_format_uuid =
    BT_UUID_INIT_128(BT_UUID_128_ENCODE(0x19B10002, 0xE8F2, 0x537E, 0x4F6C, 0xD104768A1214));

#ifdef CONFIG_KELVINLEE_ENABLE_SPEAKER
/*
 * 19B10003 is the phone -> device audio characteristic from the upstream design.
 * This device has no speaker, so the handler accepts the write and discards it:
 * the characteristic stays in the GATT table so a phone that still writes to it
 * gets a normal write response instead of an "attribute not found" error.
 *
 * Note it is only in the table when CONFIG_KELVINLEE_ENABLE_SPEAKER is set, and
 * that symbol is not defined in Kconfig, so the shipping build does not expose
 * it. See the slice report -- exposing it needs a Kconfig/.conf change, which
 * lives outside this slice.
 */
static struct bt_uuid_128 audio_characteristic_speaker_uuid =
    BT_UUID_INIT_128(BT_UUID_128_ENCODE(0x19B10003, 0xE8F2, 0x537E, 0x4F6C, 0xD104768A1214));

static ssize_t audio_data_write_handler(struct bt_conn *conn,
                                        const struct bt_gatt_attr *attr,
                                        const void *buf,
                                        uint16_t len,
                                        uint16_t offset,
                                        uint8_t flags)
{
    ARG_UNUSED(conn);
    ARG_UNUSED(attr);
    ARG_UNUSED(buf);
    ARG_UNUSED(offset);
    ARG_UNUSED(flags);

    LOG_DBG("discarding %d bytes written to the speaker characteristic", len);
    return len;
}
#endif

static struct bt_gatt_attr audio_service_attr[] = {
    BT_GATT_PRIMARY_SERVICE(&audio_service_uuid),
    BT_GATT_CHARACTERISTIC(&audio_characteristic_data_uuid.uuid,
                           BT_GATT_CHRC_READ | BT_GATT_CHRC_NOTIFY,
                           BT_GATT_PERM_READ,
                           audio_data_read_characteristic,
                           NULL,
                           NULL),
    BT_GATT_CCC(audio_ccc_config_changed_handler, BT_GATT_PERM_READ | BT_GATT_PERM_WRITE),
    BT_GATT_CHARACTERISTIC(&audio_characteristic_format_uuid.uuid,
                           BT_GATT_CHRC_READ,
                           BT_GATT_PERM_READ,
                           audio_codec_read_characteristic,
                           NULL,
                           NULL),
#ifdef CONFIG_KELVINLEE_ENABLE_SPEAKER
    BT_GATT_CHARACTERISTIC(&audio_characteristic_speaker_uuid.uuid,
                           BT_GATT_CHRC_WRITE | BT_GATT_CHRC_NOTIFY,
                           BT_GATT_PERM_WRITE,
                           NULL,
                           audio_data_write_handler,
                           NULL),
    BT_GATT_CCC(audio_ccc_config_changed_handler, BT_GATT_PERM_READ | BT_GATT_PERM_WRITE), //
#endif

};

static struct bt_gatt_service audio_service = BT_GATT_SERVICE(audio_service_attr);

// Nordic Legacy DFU service with UUID 00001530-1212-EFDE-1523-785FEABCD123
// exposes following characteristics:
// - Control point (UUID 00001531-1212-EFDE-1523-785FEABCD123) to start the OTA update process (write/notify)
static void dfu_ccc_config_changed_handler(const struct bt_gatt_attr *attr, uint16_t value);
static ssize_t dfu_control_point_write_handler(struct bt_conn *conn,
                                               const struct bt_gatt_attr *attr,
                                               const void *buf,
                                               uint16_t len,
                                               uint16_t offset,
                                               uint8_t flags);

static struct bt_uuid_128 dfu_service_uuid =
    BT_UUID_INIT_128(BT_UUID_128_ENCODE(0x00001530, 0x1212, 0xEFDE, 0x1523, 0x785FEABCD123));
static struct bt_uuid_128 dfu_control_point_uuid =
    BT_UUID_INIT_128(BT_UUID_128_ENCODE(0x00001531, 0x1212, 0xEFDE, 0x1523, 0x785FEABCD123));

static struct bt_gatt_attr dfu_service_attr[] = {
    BT_GATT_PRIMARY_SERVICE(&dfu_service_uuid),
    BT_GATT_CHARACTERISTIC(&dfu_control_point_uuid.uuid,
                           BT_GATT_CHRC_WRITE | BT_GATT_CHRC_NOTIFY,
                           BT_GATT_PERM_WRITE,
                           NULL,
                           dfu_control_point_write_handler,
                           NULL),
    BT_GATT_CCC(dfu_ccc_config_changed_handler, BT_GATT_PERM_READ | BT_GATT_PERM_WRITE),
};

static struct bt_gatt_service dfu_service = BT_GATT_SERVICE(dfu_service_attr);

// Acceleration data
// this code activates the onboard accelerometer. some cute ideas may include shaking the necklace to color strobe
//
static struct sensors mega_sensor;
static const struct device *lsm6dsl_dev;
// Arbritrary uuid, feel free to change
static struct bt_uuid_128 accel_uuid =
    BT_UUID_INIT_128(BT_UUID_128_ENCODE(0x32403790, 0x0000, 0x1000, 0x7450, 0xBF445E5829A2));
static struct bt_uuid_128 accel_uuid_x =
    BT_UUID_INIT_128(BT_UUID_128_ENCODE(0x32403791, 0x0000, 0x1000, 0x7450, 0xBF445E5829A2));

static void accel_ccc_config_changed_handler(const struct bt_gatt_attr *attr, uint16_t value);
static ssize_t accel_data_read_characteristic(struct bt_conn *conn,
                                              const struct bt_gatt_attr *attr,
                                              void *buf,
                                              uint16_t len,
                                              uint16_t offset);

static struct bt_gatt_attr accel_service_attr[] = {
    BT_GATT_PRIMARY_SERVICE(&accel_uuid), // primary description
    BT_GATT_CHARACTERISTIC(&accel_uuid_x.uuid,
                           BT_GATT_CHRC_READ | BT_GATT_CHRC_NOTIFY,
                           BT_GATT_PERM_READ,
                           accel_data_read_characteristic,
                           NULL,
                           NULL),                                                          // data type
    BT_GATT_CCC(accel_ccc_config_changed_handler, BT_GATT_PERM_READ | BT_GATT_PERM_WRITE), // scheduler
};
static struct bt_gatt_service accel_service = BT_GATT_SERVICE(accel_service_attr);

static ssize_t accel_data_read_characteristic(struct bt_conn *conn,
                                              const struct bt_gatt_attr *attr,
                                              void *buf,
                                              uint16_t len,
                                              uint16_t offset)
{
    LOG_INF("Acceleration data read characteristic");
    int axis_mode = 6; // 3 for accel, 6 for (also) gyro
    return bt_gatt_attr_read(conn, attr, buf, len, offset, &axis_mode, sizeof(axis_mode));
}

#define ACCEL_REFRESH_INTERVAL 1000 // 1.0 seconds

void broadcast_accel(struct k_work *work_item);
K_WORK_DELAYABLE_DEFINE(accel_work, broadcast_accel);

void broadcast_accel(struct k_work *work_item)
{

    sensor_sample_fetch_chan(lsm6dsl_dev, SENSOR_CHAN_ACCEL_XYZ);
    sensor_channel_get(lsm6dsl_dev, SENSOR_CHAN_ACCEL_X, &mega_sensor.a_x);
    sensor_channel_get(lsm6dsl_dev, SENSOR_CHAN_ACCEL_Y, &mega_sensor.a_y);
    sensor_channel_get(lsm6dsl_dev, SENSOR_CHAN_ACCEL_Z, &mega_sensor.a_z);

    sensor_sample_fetch_chan(lsm6dsl_dev, SENSOR_CHAN_GYRO_XYZ);
    sensor_channel_get(lsm6dsl_dev, SENSOR_CHAN_GYRO_X, &mega_sensor.g_x);
    sensor_channel_get(lsm6dsl_dev, SENSOR_CHAN_GYRO_Y, &mega_sensor.g_y);
    sensor_channel_get(lsm6dsl_dev, SENSOR_CHAN_GYRO_Z, &mega_sensor.g_z);

    // only time mega sensor is changed is through here (hopefully),  so no chance of race condition
    // conn is NULL when nothing is attached, which bt_gatt_notify reads as
    // "all subscribers" -- same as the bare global used to give us here.
    struct bt_conn *conn = get_current_connection();
    int err = bt_gatt_notify(conn, &accel_service.attrs[1], &mega_sensor, sizeof(mega_sensor));
    if (conn) {
        bt_conn_unref(conn);
    }
    if (err) {
        LOG_ERR("Error updating Accelerometer data");
    }
    k_work_reschedule(&accel_work, K_MSEC(ACCEL_REFRESH_INTERVAL));
}

/* dt_flags is uint16_t and only carries devicetree-sourced flags (active
 * level, bias). Runtime flags live above bit 16 and must be passed to
 * gpio_pin_configure_dt() instead. */
static struct gpio_dt_spec accel_gpio_pin = {.port = DEVICE_DT_GET(DT_NODELABEL(gpio1)),
                                             .pin = 8,
                                             .dt_flags = 0};

// use d4,d5
static void accel_ccc_config_changed_handler(const struct bt_gatt_attr *attr, uint16_t value)
{
    if (value == BT_GATT_CCC_NOTIFY) {
        LOG_INF("Client subscribed for notifications");
    } else if (value == 0) {
        LOG_INF("Client unsubscribed from notifications");
    } else {
        LOG_ERR("Invalid CCC value: %u", value);
    }
}

int accel_start()
{
    struct sensor_value odr_attr;
    lsm6dsl_dev = DEVICE_DT_GET_ONE(st_lsm6dsl);
    k_msleep(50);
    if (lsm6dsl_dev == NULL) {
        LOG_ERR("Could not get LSM6DSL device");
        return 0;
    }
    if (!device_is_ready(lsm6dsl_dev)) {
        LOG_ERR("LSM6DSL: not ready");
        return 0;
    }
    odr_attr.val1 = 10;
    odr_attr.val2 = 0;

    if (gpio_is_ready_dt(&accel_gpio_pin)) {
        LOG_PRINTK("Accelerometer Pin ready\n");
    } else {
        LOG_PRINTK("Error setting up accelerometer Pin\n");
        return -1;
    }
    if (gpio_pin_configure_dt(&accel_gpio_pin, GPIO_OUTPUT_INACTIVE) < 0) {
        LOG_PRINTK("Error configuring accelerometer Pin\n");
        return -1;
    }
    gpio_pin_set_dt(&accel_gpio_pin, 1);
    if (sensor_attr_set(lsm6dsl_dev, SENSOR_CHAN_ACCEL_XYZ, SENSOR_ATTR_SAMPLING_FREQUENCY, &odr_attr) < 0) {
        LOG_ERR("Cannot set sampling frequency for Accelerometer.");
        return 0;
    }
    if (sensor_attr_set(lsm6dsl_dev, SENSOR_CHAN_GYRO_XYZ, SENSOR_ATTR_SAMPLING_FREQUENCY, &odr_attr) < 0) {
        LOG_ERR("Cannot set sampling frequency for gyro.");
        return 0;
    }
    if (sensor_sample_fetch(lsm6dsl_dev) < 0) {
        LOG_ERR("Sensor sample update error");
        return 0;
    }

    LOG_INF("Accelerometer is ready for use");

    return 1;
}

// Advertisement data
// The phone scans on the audio service UUID, so it has to stay in the
// advertisement; DFU goes in the scan response.
static const struct bt_data bt_ad[] = {
    BT_DATA_BYTES(BT_DATA_FLAGS, (BT_LE_AD_GENERAL | BT_LE_AD_NO_BREDR)),
    BT_DATA(BT_DATA_UUID128_ALL, audio_service_uuid.val, sizeof(audio_service_uuid.val)),
    BT_DATA(BT_DATA_NAME_COMPLETE, CONFIG_BT_DEVICE_NAME, sizeof(CONFIG_BT_DEVICE_NAME) - 1),
};

// Scan response data
static const struct bt_data bt_sd[] = {
    BT_DATA_BYTES(BT_DATA_UUID16_ALL, BT_UUID_16_ENCODE(BT_UUID_DIS_VAL)),
    BT_DATA(BT_DATA_UUID128_ALL, dfu_service_uuid.val, sizeof(dfu_service_uuid.val)),
};

//
// State and Characteristics
//

static void audio_ccc_config_changed_handler(const struct bt_gatt_attr *attr, uint16_t value)
{
    if (value == BT_GATT_CCC_NOTIFY) {
        LOG_INF("Client subscribed for notifications");
    } else if (value == 0) {
        LOG_INF("Client unsubscribed from notifications");
    } else {
        LOG_INF("Invalid CCC value: %u", value);
    }
}

static ssize_t audio_data_read_characteristic(struct bt_conn *conn,
                                              const struct bt_gatt_attr *attr,
                                              void *buf,
                                              uint16_t len,
                                              uint16_t offset)
{
    LOG_DBG("audio_data_read_characteristic");
    return bt_gatt_attr_read(conn, attr, buf, len, offset, NULL, 0);
}

static ssize_t audio_codec_read_characteristic(struct bt_conn *conn,
                                               const struct bt_gatt_attr *attr,
                                               void *buf,
                                               uint16_t len,
                                               uint16_t offset)
{
    uint8_t value[1] = {CODEC_ID};
    LOG_DBG("audio_codec_read_characteristic %d", CODEC_ID);
    return bt_gatt_attr_read(conn, attr, buf, len, offset, value, sizeof(value));
}

//
// DFU Service Handlers
//

static void dfu_ccc_config_changed_handler(const struct bt_gatt_attr *attr, uint16_t value)
{
    if (value == BT_GATT_CCC_NOTIFY) {
        LOG_INF("Client subscribed for notifications");
    } else if (value == 0) {
        LOG_INF("Client unsubscribed from notifications");
    } else {
        LOG_INF("Invalid CCC value: %u", value);
    }
}

/* GPREGRET value the MCUboot/nRF legacy bootloader looks for to stay in DFU
 * mode after the reset below. This is the only OTA path on this device. */
#define DFU_GPREGRET_BOOTLOADER 0xA8

static ssize_t dfu_control_point_write_handler(struct bt_conn *conn,
                                               const struct bt_gatt_attr *attr,
                                               const void *buf,
                                               uint16_t len,
                                               uint16_t offset,
                                               uint8_t flags)
{
    const uint8_t *bytes = buf;

    LOG_INF("dfu_control_point_write_handler");
    if (len == 1 && bytes[0] == 0x06) {
        NRF_POWER->GPREGRET = DFU_GPREGRET_BOOTLOADER;
        NVIC_SystemReset();
    } else if (len == 2 && bytes[0] == 0x01) {
        uint8_t notification_value = 0x10;
        bt_gatt_notify(conn, attr, &notification_value, sizeof(notification_value));

        NRF_POWER->GPREGRET = DFU_GPREGRET_BOOTLOADER;
        NVIC_SystemReset();
    }
    return len;
}

//
// Battery Service Handlers
//

#define BATTERY_REFRESH_INTERVAL 15000 // 15 seconds

void broadcast_battery_level(struct k_work *work_item);

K_WORK_DELAYABLE_DEFINE(battery_work, broadcast_battery_level);

void broadcast_battery_level(struct k_work *work_item)
{
    uint16_t battery_millivolt;
    uint8_t battery_percentage;
    if (battery_get_millivolt(&battery_millivolt) == 0 &&
        battery_get_percentage(&battery_percentage, battery_millivolt) == 0) {

        LOG_PRINTK("Battery at %d mV (capacity %d%%)\n", battery_millivolt, battery_percentage);

        // Use the Zephyr BAS function to set (and notify) the battery level
        int err = bt_bas_set_battery_level(battery_percentage);
        if (err) {
            LOG_ERR("Error updating battery level: %d", err);
        }
    } else {
        LOG_ERR("Failed to read battery level");
    }

    k_work_reschedule(&battery_work, K_MSEC(BATTERY_REFRESH_INTERVAL));
}

//
// Connection Callbacks
//

/* The link-lost cue is a double blink followed by the searching pattern. The
 * gap used to be a k_msleep() straight in the disconnected callback, which
 * stalled the whole BLE RX thread for 450 ms right when it needs to be getting
 * back to advertising. */
#define BLE_LOST_SEARCH_DELAY_MS 450

static void ble_searching_work_handler(struct k_work *work_item);
K_WORK_DELAYABLE_DEFINE(ble_searching_work, ble_searching_work_handler);

static void ble_searching_work_handler(struct k_work *work_item)
{
    habitat_ble_searching();
}

static const char *phy2str(uint8_t phy)
{
    switch (phy) {
    case 0:
        return "No packets";
    case BT_GAP_LE_PHY_1M:
        return "LE 1M";
    case BT_GAP_LE_PHY_2M:
        return "LE 2M";
    case BT_GAP_LE_PHY_CODED:
        return "LE Coded";
    default:
        return "Unknown";
    }
}

static void _transport_connected(struct bt_conn *conn, uint8_t err)
{
    struct bt_conn_info info = {0};

    if (err) {
        /* Connection establishment failed. Zephyr does not follow this with a
         * disconnected callback, so returning is the whole cleanup: we never
         * took a reference, and the stack resumes advertising on its own. The
         * old code overwrote this status with the bt_conn_get_info() result
         * below and so never looked at it, leaving is_connected latched true
         * on a failed connection. */
        LOG_ERR("Connection failed (err %u)", err);
        return;
    }

    int rc = bt_conn_get_info(conn, &info);
    if (rc) {
        /* No unref here: the callback does not own a reference to conn. */
        LOG_ERR("Failed to get connection info (err %d)", rc);
        return;
    }

    LOG_INF("bluetooth activated");

    /* Take our own reference first, then release whatever we displaced. */
    struct bt_conn *previous = conn_swap(bt_conn_ref(conn));
    if (previous != NULL) {
        bt_conn_unref(previous);
    }
    current_mtu = info.le.data_len->tx_max_len;
    LOG_INF("Transport connected");
    LOG_DBG("Interval: %d, latency: %d, timeout: %d", info.le.interval, info.le.latency, info.le.timeout);
    LOG_DBG("TX PHY %s, RX PHY %s", phy2str(info.le.phy->tx_phy), phy2str(info.le.phy->rx_phy));
    LOG_DBG("LE data len updated: TX (len: %d time: %d) RX (len: %d time: %d)",
            info.le.data_len->tx_max_len,
            info.le.data_len->tx_max_time,
            info.le.data_len->rx_max_len,
            info.le.data_len->rx_max_time);

    k_work_schedule(&battery_work, K_MSEC(100)); // run immediately

    is_connected = true;
    storage_is_on = true;

    /* Group D: BLE just-connected cue — green blink × 1 + tick haptic. A
     * reconnect inside the lost-link window must not have the searching
     * pattern fire on top of it. */
    k_work_cancel_delayable(&ble_searching_work);
    habitat_ble_connected();
}

static void _transport_disconnected(struct bt_conn *conn, uint8_t err)
{
    is_connected = false;
    storage_is_on = false;

    LOG_INF("Transport disconnected");

    /* Clear the global before unreffing, so a concurrent reader either gets a
     * reference of its own or gets NULL -- never a pointer we are about to
     * release. A no-op if bt_off() already took the connection out. */
    struct bt_conn *previous = conn_swap(NULL);
    if (previous != NULL) {
        bt_conn_unref(previous);
    }
    current_mtu = 0;

    /* Group D: link-lost cue — amber double-blink, then searching once the
     * double-blink has had time to play. */
    habitat_ble_lost();
    k_work_reschedule(&ble_searching_work, K_MSEC(BLE_LOST_SEARCH_DELAY_MS));
}

static bool _le_param_req(struct bt_conn *conn, struct bt_le_conn_param *param)
{
    LOG_INF("Transport connection parameters update request received.");
    LOG_DBG("Minimum interval: %d, Maximum interval: %d", param->interval_min, param->interval_max);
    LOG_DBG("Latency: %d, Timeout: %d", param->latency, param->timeout);

    return true;
}

static void _le_param_updated(struct bt_conn *conn, uint16_t interval, uint16_t latency, uint16_t timeout)
{
    LOG_INF("Connection parameters updated.");
    LOG_DBG("[ interval: %d, latency: %d, timeout: %d ]", interval, latency, timeout);
}

static void _le_phy_updated(struct bt_conn *conn, struct bt_conn_le_phy_info *param)
{
    LOG_DBG("LE PHY updated: TX PHY %s, RX PHY %s", phy2str(param->tx_phy), phy2str(param->rx_phy));
}

static void _le_data_length_updated(struct bt_conn *conn, struct bt_conn_le_data_len_info *info)
{
    LOG_DBG("LE data len updated: TX (len: %d time: %d)"
            " RX (len: %d time: %d)",
            info->tx_max_len,
            info->tx_max_time,
            info->rx_max_len,
            info->rx_max_time);
    current_mtu = info->tx_max_len;
}

/* Fires once the connection object is freed and the slot is reusable -- the
 * point Zephyr documents as "the event to listen for to start a new
 * connection or connectable advertiser". Restarting inside .disconnected can
 * fail with -ENOMEM on CONFIG_BT_MAX_CONN=1 because the single slot is still
 * being torn down there. */
static void _transport_recycled(void)
{
    if (!adv_wanted) {
        return;
    }
    int err = bt_le_adv_start(BT_LE_ADV_CONN_FAST_2, bt_ad, ARRAY_SIZE(bt_ad), bt_sd, ARRAY_SIZE(bt_sd));
    if (err == -EALREADY) {
        return; /* already advertising; nothing to do */
    }
    if (err) {
        LOG_ERR("Failed to resume advertising after disconnect (err %d)", err);
        return;
    }
    LOG_INF("Advertising resumed after disconnect");
}

static struct bt_conn_cb _callback_references = {
    .connected = _transport_connected,
    .disconnected = _transport_disconnected,
    .recycled = _transport_recycled,
    .le_param_req = _le_param_req,
    .le_param_updated = _le_param_updated,
    .le_phy_updated = _le_phy_updated,
    .le_data_len_updated = _le_data_length_updated,
};

//
// Ring Buffer
//
// One codec frame per entry, stored as [len_lo][len_hi][payload], padded to a
// fixed stride so an entry always fits completely or not at all.
//

#define NET_BUFFER_HEADER_SIZE 3   // [id_lo][id_hi][index] in front of every audio notify
#define RING_BUFFER_HEADER_SIZE 2  // [len_lo][len_hi] in front of every ring entry
#define RING_BUFFER_ENTRY_SIZE (CODEC_OUTPUT_MAX_BYTES + RING_BUFFER_HEADER_SIZE)

static uint8_t tx_queue[NETWORK_RING_BUF_SIZE * RING_BUFFER_ENTRY_SIZE];
static uint8_t tx_buffer[RING_BUFFER_ENTRY_SIZE];
static uint8_t tx_buffer_2[RING_BUFFER_ENTRY_SIZE];
static uint32_t tx_buffer_size = 0;
static struct ring_buf ring_buf;

static bool write_to_tx_queue(uint8_t *data, size_t size)
{
    if (size > CODEC_OUTPUT_MAX_BYTES) {
        return false;
    }

    // Copy data (TODO: Avoid this copy)
    tx_buffer_2[0] = size & 0xFF;
    tx_buffer_2[1] = (size >> 8) & 0xFF;
    memcpy(tx_buffer_2 + RING_BUFFER_HEADER_SIZE, data, size);

    int written = ring_buf_put(&ring_buf, tx_buffer_2, RING_BUFFER_ENTRY_SIZE);
    return written == RING_BUFFER_ENTRY_SIZE;
}

/* Pulls one frame into tx_buffer / tx_buffer_size. */
static bool read_from_tx_queue(void)
{
    uint32_t read = ring_buf_get(&ring_buf, tx_buffer, RING_BUFFER_ENTRY_SIZE);
    if (read != RING_BUFFER_ENTRY_SIZE) {
        LOG_DBG("Failed to read from ring buffer. not enough data %u", read);
        return false;
    }

    tx_buffer_size = tx_buffer[0] + (tx_buffer[1] << 8);
    return true;
}

//
// Pusher
//
// One thread owns the frame between the ring buffer and its destination. Each
// pass moves exactly one frame, and the frame only leaves the ring buffer once
// we know where it is going: over BLE if a phone is subscribed, otherwise into
// the SD block being packed.
//

K_THREAD_STACK_DEFINE(pusher_stack, 4096);
static struct k_thread pusher_thread;
static uint16_t packet_next_index = 0;
static uint8_t pusher_temp_data[CODEC_OUTPUT_MAX_BYTES + NET_BUFFER_HEADER_SIZE];

/* Real links lose packets, so every fragment gets a few attempts before the
 * frame is given up on. */
#define MAX_NOTIFY_RETRIES 3
#define NOTIFY_RETRY_DELAY_MS 1

#define PUSHER_START_DELAY_MS 500
#define CONNECT_SETTLE_MS 100

/*
 * Send the frame in tx_buffer as MTU-sized fragments.
 *
 * *sent_any reports whether any fragment reached the phone, which lets the
 * caller tell "the link died before we sent anything" (the frame is safe to
 * archive to the card) from "the link died half way through" (archiving it
 * would duplicate what the phone already has).
 */
static bool push_frame_to_gatt(struct bt_conn *conn, bool *sent_any)
{
    const uint8_t *frame = tx_buffer + RING_BUFFER_HEADER_SIZE;
    uint32_t offset = 0;
    uint8_t index = 0;

    *sent_any = false;

    while (offset < tx_buffer_size) {
        uint32_t id = packet_next_index++;
        uint32_t fragment_size = MIN(current_mtu - NET_BUFFER_HEADER_SIZE, tx_buffer_size - offset);

        pusher_temp_data[0] = id & 0xFF;
        pusher_temp_data[1] = (id >> 8) & 0xFF;
        pusher_temp_data[2] = index;
        memcpy(pusher_temp_data + NET_BUFFER_HEADER_SIZE, frame + offset, fragment_size);

        bool sent = false;
        for (int attempt = 0; attempt < MAX_NOTIFY_RETRIES; attempt++) {
            int err = bt_gatt_notify(
                conn, &audio_service.attrs[1], pusher_temp_data, fragment_size + NET_BUFFER_HEADER_SIZE);
            if (err == 0) {
                sent = true;
                break;
            }
            LOG_DBG("bt_gatt_notify failed (err %d), MTU %d, packet %u",
                    err,
                    current_mtu,
                    fragment_size + NET_BUFFER_HEADER_SIZE);
            k_sleep(K_MSEC(NOTIFY_RETRY_DELAY_MS));
        }

        if (!sent) {
            LOG_ERR("Failed to send packet after %d retries", MAX_NOTIFY_RETRIES);
            return false;
        }

        *sent_any = true;
        offset += fragment_size;
        index++;
    }

    return true;
}

//
// Offline capture
//
// Frames are packed into fixed SD_BLOCK_SIZE blocks as [len][payload] runs and
// the block is flushed to the card whenever the next frame will not fit.
//

#define SD_FRAME_PREFIX_LENGTH 1
#define SD_MAX_FRAME_BYTES 255 // a frame length has to fit in its single prefix byte
#define SD_SIZE_REFRESH_FRAMES 255
#define MAX_STORAGE_BYTES 0xFFFF0000

static uint8_t storage_temp_data[SD_BLOCK_SIZE];
static uint16_t block_offset = 0;
static uint8_t frames_since_size_refresh = 0;

static void flush_sd_block(void)
{
    int written = write_to_file(storage_temp_data, SD_BLOCK_SIZE);
    if (written < 0) {
        LOG_ERR("SD block write failed (%d)", written);
    }
}

/* Add the frame in tx_buffer to the block being packed, flushing as needed.
 * Caller holds write_sdcard_mutex. */
static bool append_frame_to_sd_block(void)
{
    const uint8_t *payload = tx_buffer + RING_BUFFER_HEADER_SIZE;

    if (tx_buffer_size == 0 || tx_buffer_size > SD_MAX_FRAME_BYTES) {
        LOG_WRN("frame of %u bytes cannot be stored", tx_buffer_size);
        return false;
    }

    const uint8_t frame_len = (uint8_t) tx_buffer_size;
    const uint16_t entry_size = frame_len + SD_FRAME_PREFIX_LENGTH;

    if (block_offset + entry_size > SD_BLOCK_SIZE - 1) {
        /* Frame does not fit. Stamp the length byte where the reader stops,
         * flush the block, then start the next block with this frame. */
        storage_temp_data[block_offset] = frame_len;
        flush_sd_block();

        storage_temp_data[0] = frame_len;
        memcpy(storage_temp_data + SD_FRAME_PREFIX_LENGTH, payload, frame_len);
        block_offset = entry_size;
        return true;
    }

    storage_temp_data[block_offset] = frame_len;
    memcpy(storage_temp_data + block_offset + SD_FRAME_PREFIX_LENGTH, payload, frame_len);
    block_offset += entry_size;

    if (block_offset == SD_BLOCK_SIZE - 1) { // exact fit
        block_offset = 0;
        flush_sd_block();
    }

    return true;
}

static void update_file_size(void)
{
    uint32_t recorded_size = get_file_size(1);

    /* get_offset() returns -1 when info.txt cannot be read. Storing that raw
     * used to land 0xFFFFFFFF in the cached offset, which is above
     * MAX_STORAGE_BYTES and silently switched offline capture off. */
    int saved = get_offset();
    uint32_t saved_offset = (saved < 0) ? 0 : (uint32_t) saved;

    sd_set_file_sizes(recorded_size, saved_offset);
}

/* Cheap pre-check, used before a frame is taken out of the ring buffer: is
 * there any point pulling it for the card? The authoritative is_sd_on() check
 * still happens under write_sdcard_mutex in save_frame_to_sd(). */
static bool sd_can_accept_frame(void)
{
    if (!is_sd_on()) {
        return false;
    }

    uint32_t sizes[2];
    sd_read_file_sizes(sizes);
    return sizes[1] < MAX_STORAGE_BYTES; // card considered full
}

/* Put the frame in tx_buffer on the card. */
static void save_frame_to_sd(void)
{
    bool appended = false;

    if (sd_can_accept_frame()) {
        k_mutex_lock(&write_sdcard_mutex, K_FOREVER);
        if (is_sd_on()) {
            appended = append_frame_to_sd_block();
        }
        k_mutex_unlock(&write_sdcard_mutex);
    }

    if (!appended) {
        /* The frame is already out of the ring buffer by the time we get here,
         * so it is gone. Say so rather than dropping it silently. */
        LOG_WRN("dropped a frame: SD card unavailable or full");
        return;
    }

    /* Restating the file size costs two FAT stats, so it happens once every
     * few hundred frames rather than on every one. */
    frames_since_size_refresh++;
    if (frames_since_size_refresh >= SD_SIZE_REFRESH_FRAMES) {
        frames_since_size_refresh = 0;
        update_file_size();
    }
}

static void pusher(void)
{
    /* Refresh the cached file sizes once per fresh connection: the phone reads
     * them when it attaches, and two FAT stats are too slow for the hot loop. */
    bool sizes_refreshed = true;
    bool had_connection = false;

    k_msleep(PUSHER_START_DELAY_MS);

    while (1) {
        /* Owns a reference for the rest of the iteration, so the object cannot
         * be freed under us by a disconnect landing mid-loop. */
        struct bt_conn *conn = get_current_connection();

        if (conn && !had_connection) {
            k_msleep(CONNECT_SETTLE_MS);
            sizes_refreshed = false;
            had_connection = true;
        } else if (!conn) {
            had_connection = false;
        }

        if (!sizes_refreshed) {
            LOG_INF("updating file size");
            update_file_size();
            sizes_refreshed = true;
        }

        bool link_ready = conn != NULL && current_mtu >= MINIMAL_PACKET_SIZE &&
                          bt_gatt_is_subscribed(conn, &audio_service.attrs[1], BT_GATT_CCC_NOTIFY);

        if (link_ready) {
            if (read_from_tx_queue()) {
                bool sent_any = false;
                bool sent = push_frame_to_gatt(conn, &sent_any);

                if (!sent && !sent_any && !storage_is_on) {
                    /* The link went away before any of this frame got out. It
                     * is still sitting in tx_buffer, so it goes to the card
                     * rather than being dropped; this is the disconnect
                     * window. Two cases deliberately do NOT archive: a notify
                     * that fails while a phone is still attached is
                     * backpressure rather than a disconnect, and a frame we
                     * already half-sent would arrive twice. */
                    save_frame_to_sd();
                }
            }
        } else if (!storage_is_on) {
            /* No phone: record offline. Check there is somewhere to put the
             * frame before taking it out of the ring buffer -- otherwise it
             * would be consumed and then dropped, where leaving it queued lets
             * the ring buffer apply backpressure instead. */
            if (sd_can_accept_frame() && read_from_tx_queue()) {
                save_frame_to_sd();
            }
        }
        /* Phone attached but not subscribed yet: leave the frame queued and let
         * the ring buffer apply backpressure. */

        if (conn) {
            bt_conn_unref(conn);
        }

        k_yield();
    }
}

//
// Public functions
//

int bt_off()
{
    adv_wanted = false;
    // First disconnect any active connections. Taking the connection out of the
    // global before disconnecting is what stops the double-unref: the
    // disconnected callback this triggers finds NULL and leaves the reference
    // alone, and we still hold it here for the duration of the disconnect.
    struct bt_conn *conn = conn_swap(NULL);
    if (conn != NULL) {
        bt_conn_disconnect(conn, BT_HCI_ERR_REMOTE_USER_TERM_CONN);
        bt_conn_unref(conn);
    }

    // Stop advertising
    int err = bt_le_adv_stop();
    if (err) {
        LOG_ERR("Failed to stop Bluetooth advertising %d", err);
    }

    // Disable Bluetooth
    err = bt_disable();
    if (err) {
        LOG_ERR("Failed to disable Bluetooth %d", err);
    }

    // Turn off other peripherals. The mutex keeps the card from being cut out
    // from under a block write in progress.
    k_mutex_lock(&write_sdcard_mutex, K_FOREVER);
    sd_off();
    k_mutex_unlock(&write_sdcard_mutex);
    mic_off();

    // Ensure all Bluetooth resources are cleaned up
    is_connected = false;
    storage_is_on = false;
    current_mtu = 0;

    return 0;
}

int bt_on()
{
    int err = bt_enable(NULL);
    if (err) {
        LOG_ERR("Failed to enable Bluetooth %d", err);
        return err;
    }

    err = bt_le_adv_start(BT_LE_ADV_CONN_FAST_2, bt_ad, ARRAY_SIZE(bt_ad), bt_sd, ARRAY_SIZE(bt_sd));
    if (err) {
        LOG_ERR("Failed to restart advertising %d", err);
        return err;
    }
    adv_wanted = true;

    bt_gatt_service_register(&storage_service);
    sd_on();
    mic_on();

    return 0;
}

// periodic advertising
int transport_start()
{
    k_mutex_init(&write_sdcard_mutex);

    // Configure callbacks
    bt_conn_cb_register(&_callback_references);

    // Enable Bluetooth
    int err = bt_enable(NULL);
    if (err) {
        LOG_ERR("Transport bluetooth init failed (err %d)", err);
        return err;
    }
    LOG_INF("Transport bluetooth initialized");

    //  Enable button
#ifdef CONFIG_KELVINLEE_ENABLE_BUTTON
    register_button_service();
#endif

    // Start advertising
    bt_gatt_service_register(&storage_service);
    bt_gatt_service_register(&audio_service);
    bt_gatt_service_register(&dfu_service);
    err = bt_le_adv_start(BT_LE_ADV_CONN_FAST_2, bt_ad, ARRAY_SIZE(bt_ad), bt_sd, ARRAY_SIZE(bt_sd));
    if (err) {
        LOG_ERR("Transport advertising failed to start (err %d)", err);
        return err;
    }
    adv_wanted = true;
    LOG_INF("Advertising successfully started");
    /* Group D: no link yet — start amber+blue alternating search cue. */
    habitat_ble_searching();

    int battErr = 0;
    battErr |= battery_init();
    battErr |= battery_charge_start();
    if (battErr) {
        LOG_ERR("Battery init failed (err %d)", battErr);
    } else {
        LOG_INF("Battery initialized");
    }

    // Start pusher
    ring_buf_init(&ring_buf, sizeof(tx_queue), tx_queue);
    k_thread_create(&pusher_thread,
                    pusher_stack,
                    K_THREAD_STACK_SIZEOF(pusher_stack),
                    (k_thread_entry_t) pusher,
                    NULL,
                    NULL,
                    NULL,
                    K_PRIO_PREEMPT(7),
                    0,
                    K_NO_WAIT);

    return 0;
}

struct bt_conn *get_current_connection()
{
    k_spinlock_key_t key = k_spin_lock(&conn_lock);
    /* bt_conn_ref() asserts on NULL, and returns NULL if the object is already
     * being torn down -- both mean "no usable connection" to the caller. */
    struct bt_conn *conn = current_connection ? bt_conn_ref(current_connection) : NULL;

    k_spin_unlock(&conn_lock, key);

    return conn;
}

int broadcast_audio_packets(uint8_t *buffer, size_t size)
{
    int retry_count = 0;

    while (retry_count < MAX_NOTIFY_RETRIES && !write_to_tx_queue(buffer, size)) {
        k_sleep(K_MSEC(NOTIFY_RETRY_DELAY_MS));
        retry_count++;
    }

    if (retry_count >= MAX_NOTIFY_RETRIES) {
        LOG_ERR("Failed to write to tx queue after %d retries", MAX_NOTIFY_RETRIES);
        return -1;
    }

    return 0;
}

void accel_off()
{
    gpio_pin_set_dt(&accel_gpio_pin, 0);
}
