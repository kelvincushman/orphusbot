/* Copyright (c) 2025-2026 Kelvin Lee. Licensed under MIT. Portions (c) 2024 Based Hardware Contributors, MIT (see LICENSE-UPSTREAM). */

#include "usb.h"

#include <hal/nrf_power.h>
#include <zephyr/kernel.h>
#include <zephyr/logging/log.h>

LOG_MODULE_REGISTER(usb, CONFIG_LOG_DEFAULT_LEVEL);

// True while VBUS is above the valid threshold, i.e. the device is powered over
// USB. main.c reads this to blink the green charging LED.
//
// Zephyr 4.4.2 deprecated the legacy USB device stack, so the old
// usb_enable()/usb_dc_set_status_callback() charge-detect callback is no longer
// available. The nRF52840 POWER peripheral reports VBUS in USBREGSTATUS, which
// is readable regardless of which USB device stack (if any) is enabled.
bool usb_charge = false;

#define USB_VBUS_POLL_INTERVAL K_MSEC(500)

static void usb_vbus_poll(struct k_timer *timer)
{
    ARG_UNUSED(timer);
    usb_charge = nrf_power_usbregstatus_vbusdet_get(NRF_POWER);
}

K_TIMER_DEFINE(usb_vbus_timer, usb_vbus_poll, NULL);

int init_usb()
{
    usb_charge = nrf_power_usbregstatus_vbusdet_get(NRF_POWER);
    k_timer_start(&usb_vbus_timer, USB_VBUS_POLL_INTERVAL, USB_VBUS_POLL_INTERVAL);
    LOG_INF("USB VBUS detect started (charging: %d)", usb_charge);
    return 0;
}
