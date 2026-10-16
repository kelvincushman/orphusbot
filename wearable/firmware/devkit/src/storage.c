/* Copyright (c) 2025-2026 Kelvin Lee. Licensed under MIT. Portions (c) 2024 Based Hardware Contributors, MIT (see LICENSE-UPSTREAM). */

#include "storage.h"

#include <stdio.h>
#include <string.h>
#include <zephyr/bluetooth/bluetooth.h>
#include <zephyr/bluetooth/gatt.h>
#include <zephyr/bluetooth/l2cap.h>
#include <zephyr/bluetooth/services/bas.h>
#include <zephyr/bluetooth/uuid.h>
#include <zephyr/kernel.h>
#include <zephyr/logging/log.h>
#include <zephyr/sys/atomic.h>

#include "sdcard.h"
#include "transport.h"
#include "utils.h"

LOG_MODULE_REGISTER(storage, CONFIG_LOG_DEFAULT_LEVEL);

/*
 * Offline-capture playback. The phone writes a command to the ...81
 * characteristic and the storage thread streams the requested audio file back
 * as a run of notifies on the same characteristic, one SD block per notify.
 * ...82 is read to discover how much there is to fetch.
 */

/* Command byte values written to ...81. Wire contract -- do not renumber. */
#define READ_COMMAND 0
#define DELETE_COMMAND 1
#define NUKE 2
#define STOP_COMMAND 3
/* The phone sends this periodically while downloading to say "still here";
 * it resets the frame counter below. It is a command value, not a frame count. */
#define HEARTBEAT_COMMAND 50

/* Result byte notified back after each command. Wire contract -- do not renumber. */
#define RESULT_OK 0
#define INVALID_FILE_SIZE 3
#define ZERO_FILE_SIZE 4
#define SIZE_TOO_LARGE 5
#define INVALID_COMMAND 6
#define RESULT_TRANSFER_DONE 100
#define RESULT_DELETED 200

/* Blocks we will stream without hearing a heartbeat before checkpointing the
 * read offset to the card. */
#define MAX_HEARTBEAT_FRAMES 100

/* Real links drop packets. Retry a block a few times before giving up on the
 * transfer rather than leaving the reader wedged on it forever. */
#define STORAGE_NOTIFY_RETRIES 3
#define STORAGE_NOTIFY_RETRY_DELAY_MS 1

static void storage_config_changed_handler(const struct bt_gatt_attr *attr, uint16_t value);
static ssize_t storage_write_handler(struct bt_conn *conn,
                                     const struct bt_gatt_attr *attr,
                                     const void *buf,
                                     uint16_t len,
                                     uint16_t offset,
                                     uint8_t flags);

static struct bt_uuid_128 storage_service_uuid =
    BT_UUID_INIT_128(BT_UUID_128_ENCODE(0x30295780, 0x4301, 0xEABD, 0x2904, 0x2849ADFEAE43));
static struct bt_uuid_128 storage_write_uuid =
    BT_UUID_INIT_128(BT_UUID_128_ENCODE(0x30295781, 0x4301, 0xEABD, 0x2904, 0x2849ADFEAE43));
static struct bt_uuid_128 storage_read_uuid =
    BT_UUID_INIT_128(BT_UUID_128_ENCODE(0x30295782, 0x4301, 0xEABD, 0x2904, 0x2849ADFEAE43));
static ssize_t storage_read_characteristic(struct bt_conn *conn,
                                           const struct bt_gatt_attr *attr,
                                           void *buf,
                                           uint16_t len,
                                           uint16_t offset);

K_THREAD_STACK_DEFINE(storage_stack, 4096);
static struct k_thread storage_thread;

static struct bt_gatt_attr storage_service_attr[] = {
    BT_GATT_PRIMARY_SERVICE(&storage_service_uuid),
    BT_GATT_CHARACTERISTIC(&storage_write_uuid.uuid,
                           BT_GATT_CHRC_WRITE | BT_GATT_CHRC_NOTIFY,
                           BT_GATT_PERM_WRITE,
                           NULL,
                           storage_write_handler,
                           NULL),
    BT_GATT_CCC(storage_config_changed_handler, BT_GATT_PERM_READ | BT_GATT_PERM_WRITE),
    BT_GATT_CHARACTERISTIC(&storage_read_uuid.uuid,
                           BT_GATT_CHRC_READ | BT_GATT_CHRC_NOTIFY,
                           BT_GATT_PERM_READ,
                           storage_read_characteristic,
                           NULL,
                           NULL),
    BT_GATT_CCC(storage_config_changed_handler, BT_GATT_PERM_READ | BT_GATT_PERM_WRITE),

};

/* Registered by transport.c, which externs this. */
struct bt_gatt_service storage_service = BT_GATT_SERVICE(storage_service_attr);

/*
 * True while a phone is attached: set on connect and on any storage CCC
 * activity, cleared on disconnect and in bt_off(). transport.c's pusher reads
 * it to decide whether audio goes out over BLE or down to the SD card, so it
 * errs towards "phone present" -- a spurious true only means we do not record
 * offline, never that we write to a file the storage thread is reading.
 */
bool storage_is_on = false;

/* Owned by the storage thread; poked by the BLE RX thread through
 * parse_storage_command(). */
static uint8_t transport_started = 0;
static uint8_t stop_started = 0;
static uint8_t delete_started = 0;
static uint8_t nuke_started = 0;
static uint8_t delete_num = 0;
static uint8_t current_read_num = 1;
static uint8_t heartbeat_count = 0;
static uint32_t remaining_length = 0;
static uint32_t read_offset = 0;

static uint8_t storage_write_buffer[SD_BLOCK_SIZE];

static void storage_config_changed_handler(const struct bt_gatt_attr *attr, uint16_t value)
{
    storage_is_on = true;
    if (value == BT_GATT_CCC_NOTIFY) {
        LOG_INF("Client subscribed for notifications");
    } else if (value == 0) {
        LOG_INF("Client unsubscribed from notifications");
    } else {
        LOG_ERR("Invalid CCC value: %u", value);
    }
}

static ssize_t storage_read_characteristic(struct bt_conn *conn,
                                           const struct bt_gatt_attr *attr,
                                           void *buf,
                                           uint16_t len,
                                           uint16_t offset)
{
    k_msleep(10);
    uint32_t amount[2] = {0};
    sd_read_file_sizes(amount);
    return bt_gatt_attr_read(conn, attr, buf, len, offset, amount, sizeof(amount));
}

static int setup_storage_tx(void)
{
    transport_started = 0;
    LOG_INF("about to transmit storage");
    k_msleep(1000);

    int res = move_read_pointer(current_read_num);
    if (res) {
        LOG_INF("bad pointer");
        current_read_num = 1;
        remaining_length = 0;
        return -1;
    }

    LOG_INF("current read ptr %d", current_read_num);

    uint32_t sizes[2] = {0};
    sd_read_file_sizes(sizes);

    uint32_t file_size = sizes[current_read_num - 1];
    if (current_read_num == sd_file_count()) {
        file_size = get_file_size(current_read_num);
    }

    /* The phone picks up where it left off. A stale offset past the end of the
     * file used to wrap remaining_length to ~4 GB and stream forever. */
    if (read_offset >= file_size) {
        LOG_INF("offset %u past end of file (%u), nothing to send", read_offset, file_size);
        remaining_length = 0;
        return 0;
    }
    remaining_length = file_size - read_offset;

    LOG_INF("remaining length: %u", remaining_length);
    LOG_INF("offset: %u", read_offset);
    LOG_INF("file: %d", current_read_num);

    return 0;
}

static uint8_t parse_storage_command(const void *buf, uint16_t len)
{
    if (len != 6 && len != 2) {
        LOG_INF("invalid command");
        return INVALID_COMMAND;
    }

    const uint8_t *bytes = buf;
    const uint8_t command = bytes[0];
    const uint8_t file_num = bytes[1];
    uint32_t size = 0;
    if (len == 6) {
        size = ((uint32_t) bytes[2] << 24) | ((uint32_t) bytes[3] << 16) | ((uint32_t) bytes[4] << 8) | bytes[5];
    }
    LOG_PRINTK("command successful: command: %d file: %d size: %u \n", command, file_num, size);

    uint32_t sizes[2] = {0};
    sd_read_file_sizes(sizes);
    const uint8_t file_count = sd_file_count();

    if (file_num == 0) {
        LOG_INF("invalid file count 0");
        return INVALID_FILE_SIZE;
    }
    /* file_num indexes sizes[] as well as the on-card files, so it is bounded by
     * both. */
    if (file_num > file_count || file_num > (uint8_t) ARRAY_SIZE(sizes)) {
        LOG_INF("invalid file count");
        return INVALID_FILE_SIZE;
    }

    if (command == READ_COMMAND) {
        uint32_t known_size = sizes[file_num - 1];
        if (file_num != file_count) {
            if (known_size == 0) {
                LOG_INF("file size is 0");
                return ZERO_FILE_SIZE;
            }
            if (size > known_size) {
                LOG_INF("requested size is too large");
                return SIZE_TOO_LARGE;
            }
        }
        LOG_INF("valid command, setting up");
        read_offset = size - (size % SD_BLOCK_SIZE); // round down to a block boundary
        current_read_num = file_num;
        transport_started = 1;
    } else if (command == DELETE_COMMAND) {
        delete_num = file_num;
        delete_started = 1;
    } else if (command == NUKE) {
        nuke_started = 1;
    } else if (command == STOP_COMMAND) {
        remaining_length = 0;
        stop_started = 1;
    } else if (command == HEARTBEAT_COMMAND) {
        heartbeat_count = 0;
    } else {
        LOG_INF("invalid command");
        return INVALID_COMMAND;
    }

    return RESULT_OK;
}

static ssize_t storage_write_handler(struct bt_conn *conn,
                                     const struct bt_gatt_attr *attr,
                                     const void *buf,
                                     uint16_t len,
                                     uint16_t offset,
                                     uint8_t flags)
{
    uint8_t result = parse_storage_command(buf, len);
    LOG_INF("storage command len %d -> result %d", len, result);

    bt_gatt_notify(conn, &storage_service.attrs[1], &result, sizeof(result));

    /* ponytail: this sleeps the BLE RX thread. It paces the phone's command
     * sequence and the app is written against that timing, so it stays until
     * someone can retest the app against a version without it. */
    k_msleep(500);
    return len;
}

/* Ship one block. Returns false when the transfer cannot continue. */
static bool write_to_gatt(struct bt_conn *conn)
{
    uint32_t packet_size = MIN(remaining_length, SD_BLOCK_SIZE);

    int read = read_audio_data(storage_write_buffer, packet_size, read_offset);
    if (read < 0) {
        LOG_ERR("storage read failed at offset %u (err %d)", read_offset, read);
        return false;
    }
    if (read == 0) {
        LOG_WRN("storage read hit end of file at offset %u", read_offset);
        return false;
    }

    for (int attempt = 0; attempt < STORAGE_NOTIFY_RETRIES; attempt++) {
        int err = bt_gatt_notify(conn, &storage_service.attrs[1], storage_write_buffer, read);
        if (err == 0) {
            /* Advance only once the block is actually out. The old code moved
             * the offset before the notify and decremented by a fixed block
             * size, so a failed notify skipped a block and the final short
             * block wrapped remaining_length back up to ~4 GB. */
            read_offset += (uint32_t) read;
            remaining_length -= (uint32_t) read;
            return true;
        }
        LOG_DBG("error writing to gatt: %d", err);
        k_sleep(K_MSEC(STORAGE_NOTIFY_RETRY_DELAY_MS));
    }

    LOG_ERR("storage notify failed after %d retries", STORAGE_NOTIFY_RETRIES);
    return false;
}

static void storage_write(void)
{
    while (1) {
        /* Owns a reference for the whole iteration. That is what makes it safe
         * to keep using conn across the blocking FAT reads below: a disconnect
         * landing mid-transfer clears the global but cannot free the object
         * while we hold this. Every exit from the loop body unrefs. */
        struct bt_conn *conn = get_current_connection();

        if (transport_started) {
            setup_storage_tx();
        }

        // probably prefer to implement using work orders for delete,nuke,etc...
        if (delete_started) {
            LOG_INF("delete: %d", delete_num);
            int err = clear_audio_file(1);
            read_offset = 0;
            save_offset(read_offset);

            if (err) {
                LOG_ERR("error clearing");
            } else if (conn) {
                uint8_t result = RESULT_DELETED;
                bt_gatt_notify(conn, &storage_service.attrs[1], &result, sizeof(result));
            }
            delete_started = 0;
            k_msleep(10);
        }

        if (nuke_started) {
            clear_audio_directory();
            save_offset(0);
            nuke_started = 0;
        }

        if (stop_started) {
            remaining_length = 0;
            stop_started = 0;
            save_offset(read_offset);
        }

        if (heartbeat_count >= MAX_HEARTBEAT_FRAMES) {
            LOG_PRINTK("no heartbeat sent\n");
            save_offset(read_offset);
            /* Reset, or this re-fires on every pass. heartbeat_count only
             * advances while a transfer is running, so a transfer that ends on
             * exactly this count used to leave the condition latched true and
             * turn a k_yield()-only loop into one full FAT write per
             * iteration, holding the sdcard mutex against the pusher. */
            heartbeat_count = 0;
        }

        if (remaining_length > 0) {
            if (conn == NULL) {
                LOG_ERR("invalid connection");
                remaining_length = 0;
                save_offset(read_offset);
                continue; /* conn is NULL here, so nothing to release */
            }

            bool sent = write_to_gatt(conn);
            heartbeat_count = (heartbeat_count + 1) % (MAX_HEARTBEAT_FRAMES + 1);
            transport_started = 0;

            if (!sent) {
                /* Deliberately no "done" notify: telling the phone the file
                 * finished when it did not would let it drop a recording we
                 * never actually delivered. Checkpoint and stop. */
                LOG_ERR("storage transfer aborted at offset %u", read_offset);
                remaining_length = 0;
                save_offset(read_offset);
            } else if (remaining_length == 0) {
                if (stop_started) {
                    stop_started = 0;
                } else {
                    LOG_PRINTK("done. attempting to download more files\n");
                    uint8_t stop_result = RESULT_TRANSFER_DONE;
                    /* The connection we just streamed the file to, not a fresh
                     * lookup: a second get_current_connection() here would leak
                     * the reference it takes. */
                    int err =
                        bt_gatt_notify(conn, &storage_service.attrs[1], &stop_result, sizeof(stop_result));
                    if (err) {
                        LOG_ERR("failed to notify transfer done: %d", err);
                    }
                    k_sleep(K_MSEC(10));
                }
            }
        }

        if (conn != NULL) {
            bt_conn_unref(conn);
        }

        k_yield();
    }
}

int storage_init()
{
    k_thread_create(&storage_thread,
                    storage_stack,
                    K_THREAD_STACK_SIZEOF(storage_stack),
                    (k_thread_entry_t) storage_write,
                    NULL,
                    NULL,
                    NULL,
                    K_PRIO_PREEMPT(7),
                    0,
                    K_NO_WAIT);
    return 0;
}
