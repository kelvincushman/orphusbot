/* Copyright (c) 2025-2026 Kelvin Lee. Licensed under MIT. Portions (c) 2024 Based Hardware Contributors, MIT (see LICENSE-UPSTREAM). */

#include <zephyr/kernel.h>
#include <zephyr/logging/log.h>

#include "agent_commands.h"
#include "button.h"
#include "codec.h"
#include "config.h"
#include "led.h"
#include "lib/battery/battery.h"
#include "mic.h"
#include "sdcard.h"
#include "haptic.h"
#include "storage.h"
#include "transport.h"
#include "usb.h"
#include "utils.h"
#define BOOT_BLINK_DURATION_MS 600
#define BOOT_PAUSE_DURATION_MS 200
#define VBUS_DETECT (1U << 20)
#define WAKEUP_DETECT (1U << 16)
LOG_MODULE_REGISTER(main, CONFIG_LOG_DEFAULT_LEVEL);

static void codec_handler(uint8_t *data, size_t len)
{
    int err = broadcast_audio_packets(data, len);
    if (err) {
        LOG_ERR("Failed to broadcast audio packets: %d", err);
    }
}

static void mic_handler(int16_t *buffer)
{
    int err = codec_receive_pcm(buffer, MIC_BUFFER_SAMPLES);
    if (err) {
        LOG_ERR("Failed to process PCM data: %d", err);
    }
}

void bt_ctlr_assert_handle(char *name, int type)
{
    LOG_INF("Bluetooth assert: %s (type %d)", name ? name : "NULL", type);
}

bool is_connected = false;
bool is_charging = false;
extern bool is_off;
extern bool usb_charge;
static void boot_led_sequence(void)
{
    // Red blink
    set_led_red(true);
    k_msleep(BOOT_BLINK_DURATION_MS);
    set_led_red(false);
    k_msleep(BOOT_PAUSE_DURATION_MS);
    // Green blink
    set_led_green(true);
    k_msleep(BOOT_BLINK_DURATION_MS);
    set_led_green(false);
    k_msleep(BOOT_PAUSE_DURATION_MS);
    // Blue blink
    set_led_blue(true);
    k_msleep(BOOT_BLINK_DURATION_MS);
    set_led_blue(false);
    k_msleep(BOOT_PAUSE_DURATION_MS);
    // All LEDs on
    set_led_red(true);
    set_led_green(true);
    set_led_blue(true);
    k_msleep(BOOT_BLINK_DURATION_MS);
    // All LEDs off
    set_led_red(false);
    set_led_green(false);
    set_led_blue(false);
}

void set_led_state()
{
    // Recording and connected state - BLUE

    if (usb_charge) {
        is_charging = !is_charging;
        if (is_charging) {
            set_led_green(true);
        } else {
            set_led_green(false);
        }
    } else {
        set_led_green(false);
    }
    if (is_off) {
        set_led_red(false);
        set_led_blue(false);
        return;
    }
    if (is_connected) {
        set_led_blue(true);
        set_led_red(false);
        return;
    }

    // Recording but lost connection - RED
    if (!is_connected) {
        set_led_red(true);
        set_led_blue(false);
        return;
    }
}

int main(void)
{
    int err;

    // Store reset reason code
    uint32_t reset_reason = NRF_POWER->RESETREAS;

    NRF_POWER->DCDCEN = 1;
    NRF_POWER->DCDCEN0 = 1;
    NRF_POWER->RESETREAS = 1;

    LOG_INF("Booting...\n");

    LOG_INF("Model: %s", CONFIG_BT_DIS_MODEL);
    LOG_INF("Firmware revision: %s", CONFIG_BT_DIS_FW_REV_STR);
    LOG_INF("Hardware revision: %s", CONFIG_BT_DIS_HW_REV_STR);

    LOG_DBG("Reset reason: %d\n", reset_reason);

    LOG_PRINTK("\n");
    LOG_INF("Initializing LEDs...\n");

    err = led_start();
    if (err) {
        LOG_WRN("LEDs unavailable (err %d); continuing", err);
    }

    // Run the boot LED sequence
    boot_led_sequence();

    // Enable battery
#ifdef CONFIG_KELVINLEE_ENABLE_BATTERY
    err = battery_init();
    if (err) {
        LOG_WRN("Battery unavailable (err %d); continuing without battery reporting", err);
    }

    err = battery_charge_start();
    if (err) {
        LOG_WRN("Battery charge start failed (err %d); continuing", err);
    }
    LOG_INF("Battery initialized");
#endif

    // Enable button
#ifdef CONFIG_KELVINLEE_ENABLE_BUTTON
    err = button_init();
    if (err) {
        LOG_WRN("Button unavailable (err %d); continuing without button input", err);
    }
    LOG_INF("Button initialized");
    activate_button_work();
#endif

    // Enable accelerometer
#ifdef CONFIG_KELVINLEE_ENABLE_ACCELEROMETER
    /* accel_start() returns 1 on success and 0 or -1 on its various failure
      * paths, so a plain `if (err)` treated success as fatal. Non-fatal either
      * way now; the accelerometer is not required for capture. */
    err = accel_start();
    if (err != 1) {
        LOG_WRN("Accelerometer unavailable (err %d); continuing", err);
    }
    LOG_INF("Accelerometer initialized");
#endif

    // Enable sdcard
#ifdef CONFIG_KELVINLEE_ENABLE_OFFLINE_STORAGE
    LOG_PRINTK("\n");
    LOG_INF("Mount SD card...\n");

    err = mount_sd_card();
    if (err) {
        LOG_WRN("SD card unavailable (err %d); continuing without offline storage", err);
    } else {
        k_msleep(500);

        LOG_PRINTK("\n");
        LOG_INF("Initializing storage...\n");

        err = storage_init();
        if (err) {
            LOG_ERR("Failed to initialize storage (err %d)", err);
        }
    }
#endif

    // Enable haptic
#ifdef CONFIG_KELVINLEE_ENABLE_HAPTIC
    LOG_PRINTK("\n");
    LOG_INF("Initializing haptic...\n");

    err = init_haptic_pin();
    if (err) {
        LOG_WRN("Haptic init non-fatal (err %d) — continuing boot", err);
    } else {
        LOG_INF("Haptic pin initialized");
    }
#endif

    // Enable usb
#ifdef CONFIG_KELVINLEE_ENABLE_USB
    LOG_PRINTK("\n");
    LOG_INF("Initializing power supply check...\n");

    err = init_usb();
    if (err) {
        LOG_WRN("USB charge detect unavailable (err %d); continuing", err);
    }
#endif

    // Wearable: NeoPixel + agent-commands init is DEFERRED to after transport +
    // codec + mic (see below, just before the main loop). The blocking WS2812
    // SPI write wedged main() when run here (before transport_start), so we bring
    // it up last: BLE + button stay alive even if the SPI write stalls, and the
    // radio/HFCLK is fully up by then in case the transfer needed it.
    // (The agent-commands GATT service still self-registers at file scope via
    // BT_GATT_SERVICE_DEFINE, independent of agent_commands_init.)

    // Indicate transport initialization
    LOG_PRINTK("\n");
    LOG_INF("Initializing transport...\n");

    set_led_green(true);
    set_led_green(false);

    // Wearable diagnostic marker: visible blue pulse before transport_start
    // so we can tell whether main reaches this point (bench-testing only).
    set_led_blue(true);
    k_msleep(2000);
    set_led_blue(false);
    k_msleep(500);

    // Start transport
    int transportErr;
    transportErr = transport_start();

    // Wearable diagnostic marker: visible red pulse if transport_start
    // returned (regardless of err). Confirms we got past bt_enable etc.
    set_led_red(true);
    k_msleep(2000);
    set_led_red(false);
    k_msleep(500);
    if (transportErr) {
        LOG_ERR("Failed to start transport (err %d)", transportErr);
        // TODO: Detect the current core is app core or net core
        // Blink green LED to indicate error
        for (int i = 0; i < 5; i++) {
            set_led_green(!gpio_pin_get_dt(&led_green));
            k_msleep(200);
        }
        set_led_green(false);

        return transportErr;
    }

    LOG_PRINTK("\n");
    LOG_INF("Initializing codec...\n");

    set_led_blue(true);

    // Audio codec(opus) callback
    set_codec_callback(codec_handler);
    err = codec_start();
    if (err) {
        LOG_ERR("Failed to start codec: %d", err);
        // Blink blue LED to indicate error
        for (int i = 0; i < 5; i++) {
            set_led_blue(!gpio_pin_get_dt(&led_blue));
            k_msleep(200);
        }
        set_led_blue(false);
        return err;
    }

#ifdef CONFIG_KELVINLEE_ENABLE_HAPTIC
    play_haptic_milli(500);
#endif
    set_led_blue(false);

    // Indicate microphone initialization
    LOG_PRINTK("\n");
    LOG_INF("Initializing microphone...\n");

    set_led_red(true);
    set_led_green(true);

    set_mic_callback(mic_handler);
    err = mic_start();
    if (err) {
        LOG_ERR("Failed to start microphone: %d", err);
        // Blink red and green LEDs to indicate error
        for (int i = 0; i < 5; i++) {
            set_led_red(!gpio_pin_get_dt(&led_red));
            set_led_green(!gpio_pin_get_dt(&led_green));
            k_msleep(200);
        }
        set_led_red(false);
        set_led_green(false);
        return err;
    }

    set_led_red(false);
    set_led_green(false);

    // Wearable: NeoPixel + agent-commands init, deferred to here (after transport
    // + codec + mic) so a stalled WS2812 SPI write can't wedge boot before BLE.
#ifdef CONFIG_LED_STRIP
    LOG_PRINTK("\n");
    LOG_INF("Initializing Wearable agent commands + NeoPixel...\n");
    err = agent_commands_init();
    if (err) {
        LOG_WRN("agent_commands_init rc=%d (continuing without LED feedback)", err);
    }
#endif

    // Indicate successful initialization
    LOG_PRINTK("\n");
    LOG_INF("Device initialized successfully\n");

    set_led_blue(true);
    k_msleep(1000);
    set_led_blue(false);

    // Main loop
    LOG_PRINTK("\n");
    LOG_INF("Entering main loop...\n");

    while (1) {
        set_led_state();
        k_msleep(500);
    }

    // Unreachable
    return 0;
}
