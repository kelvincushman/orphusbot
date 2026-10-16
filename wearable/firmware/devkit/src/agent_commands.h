/* Copyright (c) 2025-2026 Kelvin Lee. Licensed under MIT. */

#ifndef WEARABLE_AGENT_COMMANDS_H
#define WEARABLE_AGENT_COMMANDS_H

#include <zephyr/bluetooth/gatt.h>

/**
 * Register the Wearable agent commands GATT characteristic (UUID 0xCAB1AB97).
 *
 * Wire format matches src/harness/device/commands.ts::encodeCommand in the
 * Wearable TS backend:
 *
 *     byte 0 = op   (LED_COLOR=1, LED_PATTERN=2, HAPTIC=3, STATUS_QUERY=4)
 *     byte 1 = r  OR pattern
 *     byte 2 = g  OR duration_hi
 *     byte 3 = b  OR duration_lo   (big-endian u16 ms, 0..65535)
 *
 * The characteristic supports write-without-response — one 4-byte packet
 * per write. Larger writes are rejected with BT_GATT_ERR(BT_ATT_ERR_INVALID_ATTRIBUTE_LEN).
 */

/* 16-bit UUIDs need to be wrapped into the 128-bit base. CAB1AB97 is used
 * as the full UUID to avoid collision with Bluetooth SIG assignments. */
#define WEARABLE_AGENT_CMD_UUID_VAL BT_UUID_128_ENCODE(0xCAB1AB97, 0x0000, 0x1000, 0x8000, 0x00805F9B34FB)
#define WEARABLE_AGENT_CMD_UUID     BT_UUID_DECLARE_128(WEARABLE_AGENT_CMD_UUID_VAL)

/* Op codes — must mirror commands.ts OP enum. */
#define AGENT_OP_LED_COLOR    0x01
#define AGENT_OP_LED_PATTERN  0x02
#define AGENT_OP_HAPTIC       0x03
#define AGENT_OP_STATUS_QUERY 0x04
#define AGENT_OP_NOTIFY       0x05  /* byte 1 = notify_tier_t (0=low..3=alert) */
#define AGENT_OP_HABITAT      0x06  /* byte 1 = habitat_cue_t; firmware owns the composition */

/* Habitat cue ids — byte 1 of an AGENT_OP_HABITAT write. Must mirror the
 * HABITAT_CUE map in server-contract/src/device/commands.ts. Firmware owns the
 * colour/pattern/haptic composition for each, which is the whole point: the
 * phone names a cue, it cannot compose one that drifts from habitat.c. */
#define AGENT_CUE_CAPTURE_OPEN   0x01
#define AGENT_CUE_NOTE_FILED     0x02
#define AGENT_CUE_DISCARDED      0x03
#define AGENT_CUE_ACK            0x04
#define AGENT_CUE_NOP            0x05
#define AGENT_CUE_BLE_SEARCHING  0x06
#define AGENT_CUE_BLE_CONNECTED  0x07
#define AGENT_CUE_BLE_IDLE       0x08
#define AGENT_CUE_BUDGET_WARN    0x09
#define AGENT_CUE_ERROR          0x0A
#define AGENT_CUE_TASK_RUNNING   0x0B
#define AGENT_CUE_AWAITING_INPUT 0x0C

/* Pattern codes — must mirror commands.ts PATTERN enum. */
#define AGENT_PATTERN_OFF        0x00
#define AGENT_PATTERN_SOLID      0x01
#define AGENT_PATTERN_BREATHING  0x02
#define AGENT_PATTERN_PULSE      0x03
#define AGENT_PATTERN_BLINK      0x04
#define AGENT_PATTERN_FLASH      0x05
#define AGENT_PATTERN_FADE       0x06
#define AGENT_PATTERN_ALT_FLASH  0x07
#define AGENT_PATTERN_DOUBLE_BLINK 0x08
#define AGENT_PATTERN_HAPTIC_SINGLE  0x10
#define AGENT_PATTERN_HAPTIC_DOUBLE  0x11
#define AGENT_PATTERN_HAPTIC_TRIPLE  0x12
#define AGENT_PATTERN_HAPTIC_LONG    0x13

/** Apply a 4-byte agent-command packet. Exposed for unit testing; normal
 *  dispatch flows via the GATT write handler in the service definition. */
int agent_commands_apply(const uint8_t *pkt, uint16_t len);

/** Initialise internals (NeoPixel driver, any local state). Call once during
 *  boot, after the Bluetooth stack is up but before advertising. */
int agent_commands_init(void);

#endif /* WEARABLE_AGENT_COMMANDS_H */
