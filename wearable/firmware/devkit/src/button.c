/* Copyright (c) 2025-2026 Kelvin Lee. Licensed under MIT. Portions (c) 2024 Based Hardware Contributors, MIT (see LICENSE-UPSTREAM). */

/*
 * button.c -- one finite state machine, two GPIO input sources.
 *
 * Source D5 (P0.05, hand-built gpio0 spec) carries the upstream gesture
 * grammar: press / release / single / double / long. Telemetry only -- it is
 * on the board the wearer is wearing and drives no product behaviour.
 *
 * Source A2 (P0.28, Adafruit IoT Button BFF, via the iot-button devicetree
 * alias) carries the whole wearable grammar, in three motor patterns:
 *
 *     tap = yes.  tap twice = no.  hold = power.
 *
 * One tap toggles capture, two cancel it, three recover a wedged link; the
 * hold bands power the device on and off. What a tap *means* is the phone's
 * to decide -- this file only reports the gesture and cues what it knows for
 * itself (the click under the finger, and every power transition).
 *
 * Both sources feed one payload (final_button_state), one GATT service and one
 * periodic tick. The tick runs on the system work queue at the D5 rate and
 * speeds up to the A2 rate while A2 is being held.
 */

#include "button.h"

#include <errno.h>

#include <zephyr/bluetooth/bluetooth.h>
#include <zephyr/bluetooth/gatt.h>
#include <zephyr/bluetooth/hci.h>
#include <zephyr/bluetooth/l2cap.h>
#include <zephyr/bluetooth/services/bas.h>
#include <zephyr/bluetooth/uuid.h>
#include <zephyr/drivers/gpio.h>
#include <zephyr/kernel.h>
#include <zephyr/logging/log.h>
#include <zephyr/sys/poweroff.h>

#include "habitat.h"
#include "led.h"
#include "mic.h"
#include "neopixel.h"
#include "sdcard.h"
#include "haptic.h"
#include "transport.h"

#include <hal/nrf_gpio.h>

LOG_MODULE_REGISTER(button, CONFIG_LOG_DEFAULT_LEVEL);

/* Read by main.c to decide whether to drive the status LEDs. */
bool is_off = false;

/* GATT
 *
 * Wire contract with the phone -- do not renumber, do not resize.
 *   service        23BA7924-0000-1000-7450-346EAC492E92
 *   characteristic 23BA7925-0000-1000-7450-346EAC492E92
 *   payload        int final_button_state[2], 8 bytes little-endian,
 *                  [0] = gesture code, [1] = sequence number.
 */

static void button_ccc_config_changed_handler(const struct bt_gatt_attr *attr, uint16_t value);
static ssize_t button_data_read_characteristic(struct bt_conn *conn,
                                               const struct bt_gatt_attr *attr,
                                               void *buf,
                                               uint16_t len,
                                               uint16_t offset);

static struct bt_uuid_128 button_uuid =
    BT_UUID_INIT_128(BT_UUID_128_ENCODE(0x23BA7924, 0x0000, 0x1000, 0x7450, 0x346EAC492E92));
static struct bt_uuid_128 button_characteristic_data_uuid =
    BT_UUID_INIT_128(BT_UUID_128_ENCODE(0x23BA7925, 0x0000, 0x1000, 0x7450, 0x346EAC492E92));

static struct bt_gatt_attr button_service_attr[] = {
    BT_GATT_PRIMARY_SERVICE(&button_uuid),
    BT_GATT_CHARACTERISTIC(&button_characteristic_data_uuid.uuid,
                           BT_GATT_CHRC_READ | BT_GATT_CHRC_NOTIFY,
                           BT_GATT_PERM_READ,
                           button_data_read_characteristic,
                           NULL,
                           NULL),
    BT_GATT_CCC(button_ccc_config_changed_handler, BT_GATT_PERM_READ | BT_GATT_PERM_WRITE),
};

static struct bt_gatt_service button_service = BT_GATT_SERVICE(button_service_attr);

/* The only notify payload in this file. int[2] rather than uint8_t[2] for
 * compatibility with older app builds: the app reads the sequence byte at
 * offset 4. */
static int final_button_state[2] = {0, 0};

static void button_ccc_config_changed_handler(const struct bt_gatt_attr *attr, uint16_t value)
{
    if (value == BT_GATT_CCC_NOTIFY) {
        LOG_INF("Client subscribed for notifications");
    } else if (value == 0) {
        LOG_INF("Client unsubscribed from notifications");
    } else {
        LOG_ERR("Invalid CCC value: %u", value);
    }
}

/* Gesture codes carried in final_button_state[0]. Wire contract.
 *
 * 6, 7 and 8 keep their values and changed their meaning: the phone infers
 * note / request / reply from the transcript now, so the button no longer
 * picks a bucket the wearer cannot see. Their *names* changed on all three
 * sides, so an app built against the old names silently mis-routes -- app,
 * server-contract and this file ship together or not at all. */
#define BTN_CODE_SINGLE_TAP    1  /* D5 single tap        (telemetry only)  */
#define BTN_CODE_DOUBLE_TAP    2  /* D5 double tap        (telemetry only)  */
#define BTN_CODE_LONG_TAP      3  /* D5 long press        (telemetry only)  */
#define BTN_CODE_PRESS         4  /* reserved: no live gesture emits it     */
#define BTN_CODE_RELEASE       5  /* D5 release           (telemetry only)  */
#define BTN_CODE_CANCEL        6  /* A2 double tap  -> cancel / dismiss     */
#define BTN_CODE_CAPTURE       7  /* A2 single tap  -> start / stop capture */
#define BTN_CODE_LINK_RECOVER  8  /* A2 triple tap  -> link recovery        */
#define BTN_CODE_OFF_ARMED     9  /* off ramp reached; checkpoint the buffer */
#define BTN_CODE_OFF_ABORTED  10  /* hold let go before it committed        */
#define BTN_CODE_OFF_COMMITTED 11 /* off committed; sleeping on release     */

/* Timing contract. Every one of these is measured on hardware; changing any
 * of them changes what the phone sees.
 */

/* D5. The D5 grammar counts whole ticks and multiplies by D5_POLL_MS, so the
 * poll interval is part of its arithmetic, not just its sampling rate. */
#define D5_POLL_MS             40   /* 25 Hz gesture tick                    */
#define D5_TAP_MS             300   /* a press shorter than this is a tap    */
#define D5_DOUBLE_WINDOW_MS   600   /* second tap must land inside this      */
#define D5_LONG_PRESS_MS     1000   /* held this long is a long press        */

/* A2. */
#define A2_POLL_MS             20   /* 50 Hz while held, for the hold bands  */
#define A2_DEBOUNCE_MS         30   /* sample once the line has been quiet   */
#define A2_TAP_MS             700   /* a press shorter than this is a tap    */
#define A2_DOUBLE_WINDOW_MS   750   /* tap-count commit window               */
#define A2_HOLD_ON_MS        2000   /* hold from System OFF to confirm on    */
#define A2_HOLD_OFF_MS       4000   /* hold while on to power off            */

/* A2 hold-band cues on the way to A2_HOLD_ON_MS / A2_HOLD_OFF_MS. */
#define A2_ON_TICK1_MS        800   /* first tick on the power-on ramp       */
#define A2_ON_TICK2_MS       1600   /* second tick on the power-on ramp      */
#define A2_OFF_RAMP_MS       1500   /* amber ramp + OFF_ARMED on the way off */
#define A2_OFF_TICK_MS       3000   /* tick cue on the way to off            */
#define A2_OFF_GESTURE_MS A2_TAP_MS /* one threshold, not two: past a tap,
                                     * a release is a hold let go, never a
                                     * gesture                              */
#define A2_POWER_OFF_CUE_MS  1100   /* let the off cue play before poweroff  */
#define A2_WAKE_ABORT_MS       50   /* let the LED go dark before poweroff   */
#define A2_NOTIFY_RETRY_MS     40   /* single retry after a failed notify    */
#define A2_APP_ACK_MS        1500   /* app must confirm a gesture this fast  */
#define A2_LINK_STALE_MS    30000   /* no app write for this long = wedged   */
#define A2_STUCK_MS         30000   /* a press this long is not a person     */
#define A2_OFF_RELEASE_WAIT_MS 30000 /* longest wait for the line to go high */

/* --------------------------------------------------------------------------
 * GPIO sources.
 *
 * dt_flags is uint16_t and only carries devicetree-sourced flags (active
 * level, bias). Runtime flags live above bit 16 and would truncate to zero
 * here, so they must be passed to gpio_pin_configure_dt() /
 * gpio_pin_interrupt_configure_dt() instead -- see button_init().
 * -------------------------------------------------------------------------- */

/* P0.04. NOTE: docs/PIN_MAP.md maps P0.04 to the onboard IMU's I2C SDA, yet
 * this drives it as a push-pull output. Behaviour kept as-is because something
 * upstream depends on the rail; changing it is a hardware decision. */
struct gpio_dt_spec d4_pin = {.port = DEVICE_DT_GET(DT_NODELABEL(gpio0)),
                              .pin = 4,
                              .dt_flags = 0}; // 3.3
struct gpio_dt_spec d5_pin_input = {.port = DEVICE_DT_GET(DT_NODELABEL(gpio0)),
                                    .pin = 5,
                                    .dt_flags = 0};
static struct gpio_callback d5_cb_data;

#if DT_NODE_HAS_STATUS(DT_ALIAS(iot_button), okay)
/* GPIO_PULL_UP | GPIO_ACTIVE_LOW come from the devicetree node, so they belong
 * in dt_flags and GPIO_DT_SPEC_GET is the right way to pick them up. */
static const struct gpio_dt_spec iot_button_spec = GPIO_DT_SPEC_GET(DT_ALIAS(iot_button), gpios);
static struct gpio_callback iot_button_cb;
#define WEARABLE_HAS_IOT_BUTTON 1
#else
#define WEARABLE_HAS_IOT_BUTTON 0
#endif

/* FSM state.
 *
 * Once the tick is running, every field below is read and written from exactly
 * one context: the system work queue, inside button_tick(). The two GPIO ISRs
 * write nothing but d5_level_pressed (one bool) and call k_work_reschedule(),
 * both of which are ISR-safe. button_init() seeds a few fields before the tick
 * is scheduled, so that is not concurrent either. That is why there is no lock
 * here: the mutex this file used to carry only ever guarded work items that
 * were already serialised on that same queue.
 */

/* The one periodic tick, shared by both sources. */
static void button_tick(struct k_work *work);
static K_WORK_DELAYABLE_DEFINE(button_tick_work, button_tick);

/* --- D5 --- */
typedef enum {
    BUTTON_EVENT_NONE,
    BUTTON_EVENT_SINGLE_TAP,
    BUTTON_EVENT_DOUBLE_TAP,
    BUTTON_EVENT_LONG_PRESS,
    BUTTON_EVENT_RELEASE
} ButtonEvent;

static volatile bool d5_level_pressed = false; /* mirrored by the D5 ISR */
static int64_t  d5_last_tick_ms    = 0;
static uint32_t d5_ticks           = 0;
static uint32_t d5_press_start_tick = 0;
static uint32_t d5_release_tick    = 0;
static uint32_t d5_last_tap_tick   = 0;
static bool     d5_is_pressed      = false;
static uint8_t  d5_last_event      = BUTTON_EVENT_NONE;
static FSM_STATE_T current_button_state = IDLE;

/* --- A2 --- */
#if WEARABLE_HAS_IOT_BUTTON
typedef enum {
    POWER_SYSTEM_OFF = 0,      /* device in System OFF / deep sleep         */
    POWER_BOOT_HOLD,           /* A2 held at boot; awaiting the on confirm  */
    POWER_ON_IDLE,             /* device fully on; normal operation         */
    POWER_OFF_PENDING_RELEASE, /* off committed; waiting for the line high  */
} a2_power_state_t;

static a2_power_state_t a2_power = POWER_ON_IDLE; /* boot = already on */
static bool     a2_pressed         = false; /* debounced level the FSM acts on */
static bool     a2_level_raw       = false; /* last level the tick actually read */
static int64_t  a2_level_since_ms  = 0;     /* when a2_level_raw last changed */
static bool     a2_hold_armed      = false; /* track hold until release or confirm */
static bool     a2_swallow_release = false; /* eat the release after power-on confirm */
static int64_t  a2_press_start_ms  = 0;
static uint8_t  a2_tap_count       = 0;
static int64_t  a2_tap_deadline_ms = 0;     /* 0 = no commit pending */
static bool     a2_off_cued        = false; /* amber ramp already played     */
static bool     a2_off_ticked      = false; /* off tick already played       */
static bool     a2_on_tick1        = false; /* first on-ramp tick played     */
static bool     a2_on_tick2        = false; /* second on-ramp tick played    */
static bool     a2_boot_cue_shown  = false; /* boot-hold LED actually took   */
static int64_t  a2_off_commit_ms   = 0;     /* when power-off committed      */
static int64_t  a2_ack_deadline_ms = 0;     /* 0 = no app confirmation due   */
static int64_t  a2_app_ack_ms      = 0;     /* 0 = the app has never written */
static uint8_t  a2_notify_seq      = 0;
static int      a2_retry_code      = 0;
static uint8_t  a2_retry_seq       = 0;
static int64_t  a2_retry_at_ms     = 0;     /* 0 = nothing to retry */

/* Written by the agent-commands GATT write handler, on the BLE RX thread.
 * One bool, exactly like d5_level_pressed: the tick consumes it and does all
 * the timestamping, so the int64_t clocks stay single-context. */
static volatile bool a2_app_ack_flag = false;
#endif

/* --- Notify --- */

/* The one place this file talks to the phone. get_current_connection() hands
 * back its own reference, so the connection cannot be freed underneath the
 * notify; we drop that reference before returning. */
static int button_notify(int code, uint8_t seq)
{
    final_button_state[0] = code;
    final_button_state[1] = (int) seq;

    struct bt_conn *conn = get_current_connection();
    if (conn == NULL) {
        LOG_WRN("button notify skipped: no BLE connection code=%d seq=%u", code, seq);
        return -ENOTCONN;
    }

    int err = bt_gatt_notify(conn, &button_service.attrs[1], final_button_state,
                             sizeof(final_button_state));
    bt_conn_unref(conn);

    if (err != 0) {
        LOG_WRN("button notify failed: code=%d seq=%u err=%d", code, seq, err);
    }
    return err;
}

/* D5 gestures carry sequence 0 and are not retried -- upstream behaviour. */
static inline void d5_notify(int code)
{
    (void) button_notify(code, 0);
}

/* --- D5 gesture grammar --- */

/* intervals = whole D5 poll periods since the last call, normally 1. */
static void d5_tick(uint32_t intervals)
{
    d5_ticks += intervals;

    bool pressed = d5_level_pressed;
    ButtonEvent event = BUTTON_EVENT_NONE;

    if (pressed && !d5_is_pressed) {
        d5_is_pressed = true;
        d5_press_start_tick = d5_ticks;
    } else if (!pressed && d5_is_pressed) {
        d5_is_pressed = false;
        d5_release_tick = d5_ticks;

        /* Second tap inside the double-tap window? */
        uint32_t press_ms = (d5_release_tick - d5_press_start_tick) * D5_POLL_MS;
        if (press_ms < D5_TAP_MS) {
            if (d5_last_tap_tick > 0 &&
                (d5_ticks - d5_last_tap_tick) * D5_POLL_MS < D5_DOUBLE_WINDOW_MS) {
                event = BUTTON_EVENT_DOUBLE_TAP;
                d5_last_tap_tick = 0;
            } else {
                d5_last_tap_tick = d5_ticks;
            }
        }
    }

    /* A tap only commits once the double-tap window has passed with nothing
     * following it. */
    if (!pressed && !d5_is_pressed) {
        uint32_t press_ms = (d5_release_tick - d5_press_start_tick) * D5_POLL_MS;
        if (press_ms < D5_TAP_MS && d5_last_tap_tick > 0 &&
            (d5_ticks - d5_press_start_tick) * D5_POLL_MS > D5_TAP_MS) {
            event = BUTTON_EVENT_SINGLE_TAP;
            d5_last_tap_tick = 0;
        } else if ((d5_ticks - d5_press_start_tick) * D5_POLL_MS > D5_TAP_MS) {
            event = BUTTON_EVENT_RELEASE;
        }
    }

    if (d5_is_pressed &&
        (d5_ticks - d5_press_start_tick) * D5_POLL_MS >= D5_LONG_PRESS_MS) {
        event = BUTTON_EVENT_LONG_PRESS;
    }

    switch (event) {
    case BUTTON_EVENT_SINGLE_TAP:
        LOG_PRINTK("single tap detected\n");
        d5_last_event = event;
        d5_notify(BTN_CODE_SINGLE_TAP);
        /* D5 is telemetry. The uncued, unconfirmed System OFF that used to
         * live here fired from a button on the board the wearer is wearing,
         * and defeated every protection A2 has. */
        break;

    case BUTTON_EVENT_DOUBLE_TAP:
        LOG_PRINTK("double tap detected\n");
        d5_last_event = event;
        d5_notify(BTN_CODE_DOUBLE_TAP);
        break;

    case BUTTON_EVENT_LONG_PRESS:
        /* One-time event. */
        if (d5_last_event != BUTTON_EVENT_LONG_PRESS) {
            LOG_PRINTK("long press detected\n");
            d5_last_event = event;
            d5_notify(BTN_CODE_LONG_TAP);
        }
        break;

    case BUTTON_EVENT_RELEASE:
        /* One-time event. */
        if (d5_last_event != BUTTON_EVENT_RELEASE) {
            LOG_PRINTK("release detected\n");
            d5_last_event = event;
            d5_notify(BTN_CODE_RELEASE);

            d5_ticks = 0;
            d5_press_start_tick = 0;
            d5_release_tick = 0;
            d5_last_tap_tick = 0;
        }
        current_button_state = GRACE;
        break;

    case BUTTON_EVENT_NONE:
    default:
        break;
    }
}

/* --- A2 gesture grammar + power state machine --- */

#if WEARABLE_HAS_IOT_BUTTON

/* Returns the notify result so callers can tell "the phone is not there" from
 * "the phone is there and did not take it". Row O of the grammar turns on
 * exactly that distinction. */
static int a2_notify(int code)
{
    uint8_t seq = ++a2_notify_seq;

    LOG_INF("A2 notify: %d seq=%u", code, seq);
    int err = button_notify(code, seq);
    if (err != 0 && err != -ENOTCONN) {
        a2_retry_code = code;
        a2_retry_seq = seq;
        a2_retry_at_ms = k_uptime_get() + A2_NOTIFY_RETRY_MS;
    }
    return err;
}

/* One retry, then give up -- the phone resyncs from the sequence number. */
static void a2_service_retry(int64_t now)
{
    if (a2_retry_at_ms == 0 || now < a2_retry_at_ms) {
        return;
    }
    a2_retry_at_ms = 0;
    (void) button_notify(a2_retry_code, a2_retry_seq);
}

/* --- Power off ---
 *
 * Committing is not sleeping. button_init() arms P0.28 as a SENSE_LOW System
 * OFF wake source, and the nRF52 latches that DETECT signal while the line is
 * still low -- so calling sys_poweroff() with the button still held powers
 * down and immediately wakes back up. Commit, cue, then wait for the line to
 * go high in the tick.
 */
static void a2_begin_power_off(int64_t now)
{
    a2_power = POWER_OFF_PENDING_RELEASE;
    a2_off_commit_ms = now;
    a2_hold_armed = false;
    a2_tap_count = 0;
    a2_tap_deadline_ms = 0;
    a2_ack_deadline_ms = 0;
    (void) a2_notify(BTN_CODE_OFF_COMMITTED);
    habitat_power_off();
}

static void a2_service_power_off(int64_t now)
{
    int since_ms = (int) (now - a2_off_commit_ms);

    if (since_ms < A2_POWER_OFF_CUE_MS) {
        return; /* let the red fade and the goodbye double-buzz play out */
    }

    bool held = (gpio_pin_get_raw(iot_button_spec.port, iot_button_spec.pin) == 0);
    if (held && since_ms < A2_OFF_RELEASE_WAIT_MS) {
        return; /* still held: sleeping now would just wake us again */
    }

    LOG_INF("A2: power OFF (held=%d, %d ms after commit)", (int) held, since_ms);
    is_off = true;
    bt_off();
    turnoff_all(); /* closes the SD card, then NRF_POWER->SYSTEMOFF = 1 */
    sys_poweroff(); /* only reached if that write did not stick */
}

/* --- Taps --- */

/* Triple tap. The reason anyone presses this is that the link looks wrong, so
 * when the app is not demonstrably alive the firmware acts by itself: drop
 * the connection and let transport.c's disconnected callback cue the loss and
 * restart advertising (it already does both). With a healthy app the firmware
 * touches nothing -- it just reports, and the app answers "I am right here".
 *
 * "Healthy" means the app wrote to 0xCAB1AB97 recently. a2_app_ack_ms stays 0
 * until button_note_app_ack() is wired into that write handler, and 0 reads as
 * never -- deliberately, so an unwired build is loudly wrong rather than
 * quietly wrong. */
static void a2_link_recover(int64_t now)
{
    struct bt_conn *conn = get_current_connection();
    bool healthy = (conn != NULL) && (a2_app_ack_ms != 0) &&
                   ((now - a2_app_ack_ms) < A2_LINK_STALE_MS);

    if (healthy) {
        if (a2_notify(BTN_CODE_LINK_RECOVER) != -ENOTCONN) {
            a2_ack_deadline_ms = now + A2_APP_ACK_MS;
        }
        bt_conn_unref(conn);
        return;
    }

    if (conn != NULL) {
        LOG_WRN("A2: link recovery -- dropping a stale connection");
        bt_conn_disconnect(conn, BT_HCI_ERR_REMOTE_USER_TERM_CONN);
        bt_conn_unref(conn);
        return; /* transport.c cues lost -> searching off the callback */
    }

    /* No link to drop and transport.c advertises indefinitely, so the only
     * honest thing left to say is "still looking". */
    LOG_INF("A2: link recovery -- no connection, already advertising");
    habitat_ble_lost();
}

static void a2_commit_taps(uint8_t taps, int64_t now)
{
    LOG_INF("A2 commit taps: %u", taps);

    if (taps >= 3) {
        a2_link_recover(now);
        return;
    }

    int code = (taps == 1) ? BTN_CODE_CAPTURE : BTN_CODE_CANCEL;
    if (a2_notify(code) == -ENOTCONN) {
        /* Row O: say what is actually wrong. Not habitat_error() -- nothing
         * went wrong, there is simply no phone to tell. */
        habitat_ble_lost();
        return;
    }

    /* The app must write to 0xCAB1AB97 on receipt, before it does anything
     * else. Silence past this deadline means the gesture went nowhere. */
    a2_ack_deadline_ms = now + A2_APP_ACK_MS;
}

/* A tap must not fire until the double-tap window has closed on it. */
static void a2_service_tap_window(int64_t now)
{
    if (a2_tap_deadline_ms == 0 || now < a2_tap_deadline_ms) {
        return;
    }
    a2_tap_deadline_ms = 0;

    uint8_t taps = a2_tap_count;
    a2_tap_count = 0;
    if (taps > 0) {
        a2_commit_taps(taps, now);
    }
}

static void a2_on_press(int64_t now)
{
    a2_pressed = true;
    a2_hold_armed = true;
    a2_press_start_ms = now;
    a2_off_cued = false;
    a2_off_ticked = false;
    a2_on_tick1 = false;
    a2_on_tick2 = false;

}

static void a2_on_release(int64_t now)
{
    int64_t held_ms = now - a2_press_start_ms;
    bool swallow = a2_swallow_release;

    a2_pressed = false;
    a2_hold_armed = false;
    a2_swallow_release = false;

    if (swallow) {
        /* Tail of the power-on confirm hold, not a gesture. */
        LOG_INF("A2: swallowing post-power-on release");
        return;
    }

    if (held_ms >= A2_STUCK_MS) {
        /* A line held this long was not a finger. Emit nothing, cue nothing.
         * Unreachable today -- every hold band commits inside 4 s and the
         * one long wait (POWER_OFF_PENDING_RELEASE) never returns here -- so
         * this is the floor under any band added later, not a live path. */
        LOG_WRN("A2: %d ms press ignored (stuck line)", (int) held_ms);
        return;
    }

    if (a2_power == POWER_BOOT_HOLD) {
        LOG_INF("A2: boot hold released early -- back to System OFF");
        a2_power = POWER_SYSTEM_OFF;
        neopixel_off();
        k_msleep(A2_WAKE_ABORT_MS);
        sys_poweroff();
        return;
    }

    if (held_ms >= A2_OFF_GESTURE_MS) {
        /* A hold, let go before it powered anything off. Explicitly not a
         * tap: one threshold in this file, not two. The app re-asserts
         * whatever state cue the amber ramp painted over. */
        LOG_INF("A2: power-off hold aborted at %d ms", (int) held_ms);
        a2_off_cued = false;
        a2_off_ticked = false;
        (void) a2_notify(BTN_CODE_OFF_ABORTED);
        habitat_power_off_aborted();
        return;
    }

    /* The click under the finger. It fires before the commit window closes
     * and carries no meaning beyond "I felt that" -- which is honest, since
     * at this instant the firmware does not know what the tap will mean. */
    haptic_play(HAPTIC_TICK);

    a2_tap_count++;
    LOG_INF("A2 tap_count now %u", a2_tap_count);

    if (a2_tap_count >= 3) {
        /* Nothing counts higher, so do not make the wearer wait out the
         * window for the one gesture they reach for when things are wrong. */
        a2_tap_count = 0;
        a2_tap_deadline_ms = 0;
        a2_commit_taps(3, now);
        return;
    }

    /* Reset / extend the commit window. */
    a2_tap_deadline_ms = now + A2_DOUBLE_WINDOW_MS;
}

static void a2_track_hold(int64_t now)
{
    int64_t held_ms = now - a2_press_start_ms;

    if (a2_power == POWER_BOOT_HOLD) {
        if (!a2_boot_cue_shown) {
            /* neopixel_init() runs late in main(), long after button_init(),
             * so the first attempts here fail. Keep asking rather than
             * leaving the confirm hold unlit for its whole two seconds.
             *
             * neopixel_set_color() is the readiness probe: it calls the strip
             * driver and returns its -ENODEV. neopixel_set_pattern() only
             * queues work, so its return value says nothing about the LED —
             * and re-arming it every 20 ms tick would reset the breathing
             * step counter to 0, whose brightness is 0. */
            if (neopixel_set_color(0, 80, 200) == 0) {
                neopixel_set_pattern(NEOPIXEL_BREATHING, 0);
                a2_boot_cue_shown = true;
            }
        }
        if (!a2_on_tick1 && held_ms >= A2_ON_TICK1_MS) {
            habitat_power_hold_tick();
            a2_on_tick1 = true;
        }
        if (!a2_on_tick2 && held_ms >= A2_ON_TICK2_MS) {
            habitat_power_hold_tick();
            a2_on_tick2 = true;
        }
        if (held_ms >= A2_HOLD_ON_MS) {
            a2_power = POWER_ON_IDLE;
            a2_swallow_release = true;
            a2_hold_armed = false; /* stop tracking; the release is swallowed */
            a2_tap_count = 0;
            a2_tap_deadline_ms = 0;
            habitat_power_on();
            LOG_INF("A2: power ON confirmed");
        }
        return;
    }

    if (a2_power != POWER_ON_IDLE) {
        return;
    }

    if (!a2_off_cued && held_ms >= A2_OFF_RAMP_MS) {
        /* Amber, and tell the phone to checkpoint whatever it is holding.
         * The cheap part of an accidental power-off is the power. */
        habitat_power_off_ramp();
        (void) a2_notify(BTN_CODE_OFF_ARMED);
        a2_off_cued = true;
    }
    if (!a2_off_ticked && held_ms >= A2_OFF_TICK_MS) {
        habitat_power_hold_tick();
        a2_off_ticked = true;
    }
    if (held_ms >= A2_HOLD_OFF_MS) {
        LOG_INF("A2: power OFF committed (%d ms hold)", A2_HOLD_OFF_MS);
        a2_begin_power_off(now);
    }
}

/* Integrating debounce: a level is only handed to the FSM once the tick has
 * read that same level continuously for A2_DEBOUNCE_MS. Doing it here rather
 * than by trusting a single post-edge sample means the debounce does not
 * depend on when the work queue happens to run us. */
static void a2_sample(int64_t now)
{
    /* Active low via the devicetree alias: raw 0 means pressed. */
    bool level = (gpio_pin_get_raw(iot_button_spec.port, iot_button_spec.pin) == 0);

    if (level != a2_level_raw) {
        /* Line moved: restart the settle window. A bouncing contact keeps
         * landing here and never gets past the check below. */
        a2_level_raw = level;
        a2_level_since_ms = now;
        return;
    }

    if (level == a2_pressed || (now - a2_level_since_ms) < A2_DEBOUNCE_MS) {
        /* Nothing new, or not quiet for long enough yet. */
        return;
    }

    /* Timestamp the edge when the line first moved, not when we got round to
     * trusting it, so the debounce delay cancels out of every hold duration
     * instead of biasing press and release by different amounts. */
    if (level) {
        a2_on_press(a2_level_since_ms);
    } else {
        a2_on_release(a2_level_since_ms);
    }
}

/* The app writes to 0xCAB1AB97 the moment it takes a gesture notify. Silence
 * past A2_APP_ACK_MS means the gesture reached nobody, and a lost note is
 * worth more than a false warning is worth avoiding. */
static void a2_service_watchdog(int64_t now)
{
    if (a2_app_ack_flag) {
        a2_app_ack_flag = false;
        a2_app_ack_ms = now;
        a2_ack_deadline_ms = 0;
    }
    if (a2_ack_deadline_ms != 0 && now >= a2_ack_deadline_ms) {
        a2_ack_deadline_ms = 0;
        LOG_WRN("A2: no app confirmation within %d ms", A2_APP_ACK_MS);
        habitat_error();
    }
}

static void a2_tick(int64_t now)
{
    if (a2_power == POWER_OFF_PENDING_RELEASE) {
        /* Nothing else can matter now, and counting taps on the way down
         * would only file gestures at a phone we are about to leave. */
        a2_service_power_off(now);
        return;
    }
    a2_sample(now);
    if (a2_pressed && a2_hold_armed) {
        a2_track_hold(now);
    }
    /* Watchdog before the tap window: an app write that landed since the last
     * tick has to be consumed before this tick can arm a new deadline, or the
     * stale flag would disarm the gesture we are about to send. */
    a2_service_watchdog(now);
    a2_service_tap_window(now);
    a2_service_retry(now);
}

#endif /* WEARABLE_HAS_IOT_BUTTON */

/* --- The tick --- */

/* How long A2 would like to wait before looking at its line again. */
static inline int a2_period_ms(void)
{
#if WEARABLE_HAS_IOT_BUTTON
    if (a2_level_raw != a2_pressed) {
        /* An A2 edge is settling: come back when the debounce window closes,
         * rather than at whatever the idle rate happens to be. */
        return A2_DEBOUNCE_MS;
    }
    /* 50 Hz only while A2 is being held and its hold bands still matter. */
    return (a2_pressed && a2_hold_armed) ? A2_POLL_MS : D5_POLL_MS;
#else
    return D5_POLL_MS;
#endif
}

/*
 * A tick must land on every D5 grid boundary, because D5 samples its level
 * when the tick runs and the old independent work item sampled on an exact
 * 40 ms grid. Waking early for an A2 deadline is free -- the D5 gate simply
 * skips that round -- but waking late shifts a D5 edge into the neighbouring
 * tick, and within one interval of the 300 ms tap boundary that turns a
 * release into a single tap, which powers the device off. So the next delay
 * is the earlier of the two deadlines and never past the D5 one.
 *
 * Idle, a2_period_ms() is D5_POLL_MS and the D5 boundary always wins, so this
 * costs no extra wake-ups; the extra wake only happens while A2 is active.
 */
static int button_tick_delay_ms(void)
{
    int64_t now = k_uptime_get();
    int64_t due = d5_last_tick_ms + D5_POLL_MS;
    int64_t a2_due = now + a2_period_ms();

    if (a2_due < due) {
        due = a2_due;
    }

    int64_t delay = due - now;

    /* Never 0 -- that would spin the work queue. */
    return (delay > 0) ? (int) delay : 1;
}

static void button_tick(struct k_work *work)
{
    ARG_UNUSED(work);

    int64_t now = k_uptime_get();

    /* D5 counts ticks and multiplies by D5_POLL_MS, so its timebase has to
     * track real elapsed time even though A2 activity perturbs the shared
     * tick (an edge pulls it to A2_DEBOUNCE_MS, a settling level holds it
     * there). Two things make that true: advance by however many whole
     * intervals actually elapsed, and carry the remainder in d5_last_tick_ms
     * instead of resetting it to now. Resetting would silently discard up to
     * one interval on every perturbed tick, and that error accumulates --
     * enough of it shortens a measured press across the 300 ms tap boundary,
     * where a misread turns a release into a single tap and powers the
     * device off. With the carry, counted time is always
     * floor(real elapsed / D5_POLL_MS) intervals: bounded to one tick, for
     * all time, exactly like the old independent 40 ms work item. */
    int64_t d5_elapsed_ms = now - d5_last_tick_ms;

    if (d5_elapsed_ms >= D5_POLL_MS) {
        uint32_t intervals = (uint32_t) (d5_elapsed_ms / D5_POLL_MS);

        d5_last_tick_ms += (int64_t) intervals * D5_POLL_MS;
        d5_tick(intervals);
    }

#if WEARABLE_HAS_IOT_BUTTON
    a2_tick(now);
#endif

    k_work_reschedule(&button_tick_work, K_MSEC(button_tick_delay_ms()));
}

/* --- GPIO interrupt sources --- */

/* D5 mirrors the pin level into the FSM. Active low: raw 0 means pressed. */
static void d5_isr(const struct device *dev, struct gpio_callback *cb, uint32_t pins)
{
    ARG_UNUSED(cb);
    ARG_UNUSED(pins);

    int raw = gpio_pin_get_raw(dev, d5_pin_input.pin);
    LOG_PRINTK("button_pressed_callback %d\n", raw);
    d5_level_pressed = (raw == 0);
}

#if WEARABLE_HAS_IOT_BUTTON
/* A2 touches no FSM state: it only pulls the shared tick forward so an edge is
 * noticed promptly instead of at the next idle tick. The debounce itself lives
 * in a2_sample(), which will not accept a level until it has held for
 * A2_DEBOUNCE_MS -- so a missed or racing reschedule costs latency, never a
 * false edge. */
static void a2_isr(const struct device *dev, struct gpio_callback *cb, uint32_t pins)
{
    ARG_UNUSED(dev);
    ARG_UNUSED(cb);
    ARG_UNUSED(pins);

    k_work_reschedule(&button_tick_work, K_MSEC(A2_DEBOUNCE_MS));
}
#endif

/* --- Public API --- */

static ssize_t button_data_read_characteristic(struct bt_conn *conn,
                                               const struct bt_gatt_attr *attr,
                                               void *buf,
                                               uint16_t len,
                                               uint16_t offset)
{
    LOG_INF("button_data_read_characteristic");
    LOG_PRINTK("was_pressed: %d\n", final_button_state[0]);
    return bt_gatt_attr_read(conn, attr, buf, len, offset, &final_button_state,
                             sizeof(final_button_state));
}

int button_init()
{
    if (gpio_is_ready_dt(&d4_pin)) {
        LOG_INF("D4 Pin ready");
    } else {
        LOG_ERR("Error setting up D4 Pin");
        return -1;
    }
    if (gpio_pin_configure_dt(&d4_pin, GPIO_OUTPUT_ACTIVE) < 0) {
        LOG_ERR("Error setting up D4 Pin Voltage");
        return -1;
    } else {
        LOG_INF("D4 ready to transmit voltage");
    }
    if (gpio_is_ready_dt(&d5_pin_input)) {
        LOG_INF("D5 Pin ready");
    } else {
        LOG_ERR("D5 Pin not ready");
        return -1;
    }

    /* PULL_UP is not optional. D5 (P0.05) is a button to ground with no
     * external pull, and dt_flags is 0, so a bare GPIO_INPUT leaves the line
     * floating. With GPIO_INT_EDGE_BOTH armed below, a floating line emits
     * phantom presses: on the bench every A2 press produced a matching D5
     * SINGLE/LONG/RELEASE from a finger's capacitance near the board. */
    int err = gpio_pin_configure_dt(&d5_pin_input, GPIO_INPUT | GPIO_PULL_UP);

    if (err != 0) {
        LOG_ERR("Error setting up D5 Pin");
        return -1;
    } else {
        LOG_INF("D5 ready");
    }

    err = gpio_pin_interrupt_configure_dt(&d5_pin_input, GPIO_INT_EDGE_BOTH);

    if (err != 0) {
        LOG_ERR("D5 unable to detect button presses");
        return -1;
    } else {
        LOG_INF("D5 ready to detect button presses");
    }

    gpio_init_callback(&d5_cb_data, d5_isr, BIT(d5_pin_input.pin));
    gpio_add_callback(d5_pin_input.port, &d5_cb_data);

#if WEARABLE_HAS_IOT_BUTTON
    /* Wearable: second button on A2 via the iot-button devicetree alias. */
    if (!gpio_is_ready_dt(&iot_button_spec)) {
        LOG_WRN("IoT button (A2) not ready -- alias declared but device not available");
    } else if (gpio_pin_configure_dt(&iot_button_spec, GPIO_INPUT) < 0) {
        LOG_ERR("Failed to configure IoT button (A2) pin");
    } else if (gpio_pin_interrupt_configure_dt(&iot_button_spec, GPIO_INT_EDGE_BOTH) < 0) {
        LOG_ERR("Failed to configure IoT button (A2) interrupt (EDGE_BOTH)");
    } else {
        /* Both edges, so the FSM can measure hold duration for the power bands. */
        gpio_init_callback(&iot_button_cb, a2_isr, BIT(iot_button_spec.pin));
        gpio_add_callback(iot_button_spec.port, &iot_button_cb);

        /* A2 held at boot is exactly what the SENSE wake source below
         * produces, and that press *is* the power-on confirm hold -- so arm
         * the hold tracker on it. The old code adopted the level and
         * swallowed the release instead, which left POWER_WAKE_PENDING
         * unreachable: a2_tick() only tracks a hold when a2_hold_armed and
         * a2_press_start_ms are both set, and neither ever was. The device
         * simply came up ON, and the confirm hold was dead code.
         *
         * Ceiling: A2_HOLD_ON_MS is measured from here, not from the SoC
         * waking, so the felt hold is boot latency + 2000 ms. Measure that
         * latency on hardware and trim the constant to land at ~2.5 s felt. */
        a2_pressed = (gpio_pin_get_raw(iot_button_spec.port, iot_button_spec.pin) == 0);
        a2_level_raw = a2_pressed;
        if (a2_pressed) {
            a2_power = POWER_BOOT_HOLD;
            a2_hold_armed = true;
            a2_press_start_ms = k_uptime_get();
        }
        /* Configure A2 (P0.28) as a System OFF GPIO wake source.
         * nrf_gpio_cfg_sense_set programs the SENSE field on the pin so the
         * nRF52840 can wake from System OFF on a falling edge (active-low). */
        nrf_gpio_cfg_sense_set(NRF_GPIO_PIN_MAP(0, 28), NRF_GPIO_PIN_SENSE_LOW);
        LOG_INF("IoT button (A2) ready (tap/double/triple, hold 2s on / 4s off)");
    }
#endif

    return 0;
}

void activate_button_work()
{
    /* Seed the timebase so the first tick sees one interval, not however long
     * the rest of boot took. */
    d5_last_tick_ms = k_uptime_get();
    k_work_schedule(&button_tick_work, K_MSEC(D5_POLL_MS));
}

void register_button_service()
{
    bt_gatt_service_register(&button_service);
}

FSM_STATE_T get_current_button_state()
{
    return current_button_state;
}

/* Called from the agent-commands GATT write handler on every write the phone
 * makes to 0xCAB1AB97. Two jobs, both timing: it disarms the confirmation
 * watchdog for the gesture just sent, and it is the only evidence this file
 * has that the app is alive, which is what triple tap gates on. */
void button_note_app_ack(void)
{
#if WEARABLE_HAS_IOT_BUTTON
    a2_app_ack_flag = true;
#endif
}

void turnoff_all()
{

    mic_off();
    sd_off();
    accel_off();
    play_haptic_milli(50);
    k_msleep(100);
    set_led_blue(false);
    set_led_red(false);
    set_led_green(false);
    gpio_remove_callback(d5_pin_input.port, &d5_cb_data);
    /* D5 must NOT be a wake source. dt_flags is 0, so LEVEL_INACTIVE armed
     * SENSE on P0.05's physical LOW -- and that pin floats (see button_init).
     * A drifting line therefore asserted DETECT the instant SYSTEMOFF was
     * written, and the device powered off and woke straight back up. Observed
     * on hardware. Under the A2 grammar the only power control is A2, whose
     * SENSE_LOW is armed in button_init and is what wakes us. */
    gpio_pin_interrupt_configure_dt(&d5_pin_input, GPIO_INT_DISABLE);
    nrf_gpio_cfg_sense_set(NRF_GPIO_PIN_MAP(0, 5), NRF_GPIO_PIN_NOSENSE);
    NRF_USBD->INTENCLR = 0xFFFFFFFF;
    NRF_POWER->SYSTEMOFF = 1;
}

void force_button_state(FSM_STATE_T state)
{
    current_button_state = state;
}
