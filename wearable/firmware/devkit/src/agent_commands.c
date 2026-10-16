/* Copyright (c) 2025-2026 Kelvin Lee. Licensed under MIT. */

/*
 * Agent-commands GATT service for Wearable.
 *
 * Receives 4-byte command packets from the phone app (which in turn got them
 * from Wearable's src/harness/inngest/device-delivery.ts queue). Dispatches to:
 *   - neopixel.c for LED ops (colour + pattern)
 *   - haptic.c::play_haptic_milli for haptic ops
 *
 * The service is registered via BT_GATT_SERVICE_DEFINE at file scope so it
 * joins the primary advertising set automatically. transport.c doesn't need
 * any changes — Zephyr discovers the extra service at bt_enable time.
 */

#include "agent_commands.h"
#include "button.h"
#include "habitat.h"
#include "neopixel.h"
#include "haptic.h"

#include <zephyr/bluetooth/bluetooth.h>
#include <zephyr/bluetooth/gatt.h>
#include <zephyr/bluetooth/uuid.h>
#include <zephyr/kernel.h>
#include <zephyr/logging/log.h>

LOG_MODULE_REGISTER(agent_commands, CONFIG_LOG_DEFAULT_LEVEL);

/* Service base UUID — separate from the existing 0x19B10000 BLE audio
 * service. Keeps this a distinct advertised GATT service so the phone can
 * subscribe without disturbing audio streaming. */
#define WEARABLE_CMD_SERVICE_UUID_VAL BT_UUID_128_ENCODE(0xCAB1AB90, 0x0000, 0x1000, 0x8000, 0x00805F9B34FB)
#define WEARABLE_CMD_SERVICE_UUID     BT_UUID_DECLARE_128(WEARABLE_CMD_SERVICE_UUID_VAL)

static uint16_t read_pattern_duration(const uint8_t *pkt)
{
    return ((uint16_t)pkt[2] << 8) | (uint16_t)pkt[3];
}

int agent_commands_apply(const uint8_t *pkt, uint16_t len)
{
    if (pkt == NULL || len != 4) {
        return -EINVAL;
    }
    uint8_t op = pkt[0];
    LOG_INF("agent cmd: op=0x%02x [%02x %02x %02x]", op, pkt[1], pkt[2], pkt[3]);

    switch (op) {
    case AGENT_OP_LED_COLOR:
        return neopixel_set_color(pkt[1], pkt[2], pkt[3]) < 0 ? -EIO : 0;

    case AGENT_OP_LED_PATTERN: {
        neopixel_pattern_t pattern;
        switch (pkt[1]) {
        case AGENT_PATTERN_OFF:       pattern = NEOPIXEL_OFF; break;
        case AGENT_PATTERN_SOLID:     pattern = NEOPIXEL_SOLID; break;
        case AGENT_PATTERN_BREATHING: pattern = NEOPIXEL_BREATHING; break;
        case AGENT_PATTERN_PULSE:     pattern = NEOPIXEL_PULSE; break;
        case AGENT_PATTERN_BLINK:     pattern = NEOPIXEL_BLINK; break;
        case AGENT_PATTERN_FLASH:     pattern = NEOPIXEL_FLASH; break;
        case AGENT_PATTERN_FADE:      pattern = NEOPIXEL_FADE; break;
        case AGENT_PATTERN_ALT_FLASH: pattern = NEOPIXEL_ALT_FLASH; break;
        case AGENT_PATTERN_DOUBLE_BLINK: pattern = NEOPIXEL_DOUBLE_BLINK; break;
        default:
            LOG_WRN("unknown LED pattern 0x%02x", pkt[1]);
            return -EINVAL;
        }
        /* neopixel_set_pattern returns k_work_schedule's value, which is 1 for
         * "queued" and 0 for "already queued" — both success. Returning it
         * straight made the GATT handler answer ATT_ERR_UNLIKELY to a pattern
         * write that had in fact worked. Same return-contract trap that left
         * the power-on hold unlit; normalise it here. */
        return neopixel_set_pattern(pattern, read_pattern_duration(pkt)) < 0 ? -EIO : 0;
    }

    case AGENT_OP_HAPTIC: {
        /* A named pattern runs haptic.c's sequencer, which is the only way
         * the phone can reach the felt vocabulary; the durationless
         * single-buzz form stays for callers that want an exact length. */
        switch (pkt[1]) {
        case AGENT_PATTERN_HAPTIC_SINGLE: haptic_play(HAPTIC_SINGLE); return 0;
        case AGENT_PATTERN_HAPTIC_DOUBLE: haptic_play(HAPTIC_DOUBLE); return 0;
        case AGENT_PATTERN_HAPTIC_TRIPLE: haptic_play(HAPTIC_TRIPLE); return 0;
        case AGENT_PATTERN_HAPTIC_LONG:   haptic_play(HAPTIC_LONG);   return 0;
        default:
            break;
        }
        uint16_t duration_ms = read_pattern_duration(pkt);
        if (duration_ms == 0) duration_ms = 120;  /* sensible default */
        if (duration_ms > 2000) duration_ms = 2000;  /* safety cap */
        play_haptic_milli(duration_ms);
        return 0;
    }

    case AGENT_OP_STATUS_QUERY:
        /* No immediate response; future commit can notify back on
         * 0x23BA7924 with battery + pattern state. */
        return 0;

    case AGENT_OP_NOTIFY: {
        /* op=0x05, byte 1 = tier (0=low, 1=normal, 2=high, 3=alert).
         * Map to group-E LED+haptic via habitat.c. */
        uint8_t tier_raw = pkt[1];
        notify_tier_t tier;
        switch (tier_raw) {
        case 0:  tier = NOTIFY_TIER_LOW;    break;
        case 1:  tier = NOTIFY_TIER_NORMAL; break;
        case 2:  tier = NOTIFY_TIER_HIGH;   break;
        case 3:  tier = NOTIFY_TIER_ALERT;  break;
        default:
            LOG_WRN("NOTIFY op: unknown tier 0x%02x", tier_raw);
            return -EINVAL;
        }
        habitat_notify(tier);
        return 0;
    }

    case AGENT_OP_HABITAT: {
        /* The phone names a cue; habitat.c owns what it looks and feels like.
         * Without this case every button cue in the A2 grammar is dropped on
         * the wire and the wearer gets no feedback at all. */
        switch (pkt[1]) {
        case AGENT_CUE_CAPTURE_OPEN:   habitat_capture_open();   return 0;
        case AGENT_CUE_NOTE_FILED:     habitat_note_filed();     return 0;
        case AGENT_CUE_DISCARDED:      habitat_discarded();      return 0;
        case AGENT_CUE_ACK:            habitat_ack();            return 0;
        case AGENT_CUE_NOP:            habitat_nop();            return 0;
        case AGENT_CUE_BLE_SEARCHING:  habitat_ble_searching();  return 0;
        case AGENT_CUE_BLE_CONNECTED:  habitat_ble_connected();  return 0;
        case AGENT_CUE_BLE_IDLE:       habitat_ble_idle();       return 0;
        case AGENT_CUE_BUDGET_WARN:    habitat_budget_warn();    return 0;
        case AGENT_CUE_ERROR:          habitat_error();          return 0;
        case AGENT_CUE_TASK_RUNNING:   habitat_task_running();   return 0;
        case AGENT_CUE_AWAITING_INPUT: habitat_awaiting_input(); return 0;
        default:
            LOG_WRN("unknown habitat cue 0x%02x", pkt[1]);
            return -EINVAL;
        }
    }

    default:
        LOG_WRN("unknown agent op 0x%02x", op);
        return -EINVAL;
    }
}

static ssize_t gatt_write_agent_cmd(struct bt_conn *conn,
                                    const struct bt_gatt_attr *attr,
                                    const void *buf, uint16_t len,
                                    uint16_t offset, uint8_t flags)
{
    ARG_UNUSED(conn);
    ARG_UNUSED(attr);
    ARG_UNUSED(flags);

    if (offset != 0) {
        return BT_GATT_ERR(BT_ATT_ERR_INVALID_OFFSET);
    }
    if (len != 4) {
        return BT_GATT_ERR(BT_ATT_ERR_INVALID_ATTRIBUTE_LEN);
    }
    /* Every write from the phone is the only evidence button.c has that the app
     * is alive. It disarms the 1500 ms confirmation watchdog for the gesture
     * just sent, and it is what triple-tap link recovery gates on. Without this
     * call the watchdog fired an error cue after EVERY committed gesture, and
     * triple tap always took the "app is dead" branch and dropped the link.
     * Note it before applying: a command that fails to apply still proves the
     * app is there and answering. */
    button_note_app_ack();

    int rc = agent_commands_apply((const uint8_t *)buf, len);
    if (rc != 0) {
        LOG_WRN("agent cmd rejected: rc=%d", rc);
        return BT_GATT_ERR(BT_ATT_ERR_UNLIKELY);
    }
    return len;
}

BT_GATT_SERVICE_DEFINE(wearable_cmd_svc,
    BT_GATT_PRIMARY_SERVICE(WEARABLE_CMD_SERVICE_UUID),
    BT_GATT_CHARACTERISTIC(WEARABLE_AGENT_CMD_UUID,
                           BT_GATT_CHRC_WRITE_WITHOUT_RESP | BT_GATT_CHRC_WRITE,
                           BT_GATT_PERM_WRITE,
                           NULL, gatt_write_agent_cmd, NULL),
);

int agent_commands_init(void)
{
    int rc = neopixel_init();
    if (rc != 0) {
        LOG_WRN("neopixel_init rc=%d (will run without LED feedback)", rc);
    }
    LOG_INF("Wearable agent commands service ready (UUID CAB1AB90...)");
    return 0;
}
