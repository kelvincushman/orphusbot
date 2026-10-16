<!-- Copyright (c) 2025-2026 Kelvin Lee. Licensed under MIT. -->

# firmware/scripts

Host-side tools for the wearable. They talk to the device over a plain Realtek
RTL8761B USB dongle driven by raw HCI, so nothing here needs a Nordic dongle,
nRF Connect, or CoreBluetooth permission.

## Flashing

**Use UF2.** Double-tap the reset button, wait for `XIAO-SENSE` to mount, and copy
the image:

```bash
cp firmware/devkit/build_btn/zephyr/zephyr.uf2 /Volumes/XIAO-SENSE/
```

The volume unmounts itself and the device reboots into the new firmware. This is
the only flash path currently known to produce a running application.

## `ble-gesture-test.py` — hardware test for the A2 button grammar

The only way to test the grammar. The firmware ships with `CONFIG_CONSOLE=n`
and no log output, so a button press is observable only as a GATT notify, an
LED, or a buzz.

```bash
./firmware/scripts/ble-gesture-test.py            # scripted session, five steps
./firmware/scripts/ble-gesture-test.py --listen 120   # just watch, no prompts
./firmware/scripts/ble-gesture-test.py --cues     # play all twelve habitat cues
```

It plays the **app's** half of the loop as well as watching. The firmware arms
a 1500 ms watchdog on every committed gesture and plays an error cue if no cue
write comes back, so a listener that only listens makes every correct gesture
look like a failure.

Exit code is 0 when every step passed. The last step powers the device off, so
the link dropping there is a pass, not a fault.

## `ble-dfu-flash.py` — over-the-air, **does not currently produce a bootable image**

Drives the legacy Nordic DFU protocol (SDK 11 / Adafruit bootloader) from the
RTL8761B. `--enter <app-addr>` first writes `0x06` to the running firmware's DFU
control point, which sets `GPREGRET = 0xA8` and resets into the bootloader, so a
flash needs no hands on the device at all.

The transport is proven. On 2026-09-07 it completed a full DFU — `START_DFU`,
init packet, 12 709 data packets (254 168 B in 183 s, 1.4 kB/s), `VALIDATE` and
`ACTIVATE_AND_RESET`, every one ACKed with success — and **the application never
came back**. The device sat in the bootloader with no BLE advertising until it was
recovered over UF2.

The leading explanation, not yet proven: legacy DFU carries a raw `.bin` with no
address in it, so the bootloader writes it at whatever it treats as the
application start, while this Zephyr image is linked at `0x27000` (the segment
record at the top of `zephyr.hex`). UF2 carries an absolute address per 256-byte
block, which is why the same image flashes fine that way.

To finish this: confirm the bootloader's application start (read its settings
page, or check the Adafruit bootloader version against its `nrf52840_s140_6.1.1`
memory map), then either relink the Zephyr image to match or offset the payload
before sending. Until then the script refuses to run without
`--i-know-it-does-not-boot`.

```bash
# build a package from the hex the west build produced
adafruit-nrfutil dfu genpkg --dev-type 0x0052 \
  --application firmware/devkit/build_btn/zephyr/zephyr.hex fw.zip

# re-test the OTA path (expect a successful transfer and a dark device)
./firmware/scripts/ble-dfu-flash.py --package fw.zip \
  --enter AA:BB:CC:DD:EE:FF --i-know-it-does-not-boot
```

## Flashing from an agent shell

macOS gates writes to removable volumes behind a per-application TCC grant, so
a copy to `/Volumes/XIAO-SENSE` from a sandboxed shell fails with `Permission
denied` even with the sandbox disabled — while the same copy from the user's own
terminal works. Python's `shutil.copyfile` does get through, and reports
`[Errno 5] Input/output error` on success: the bootloader reboots the moment it
has the whole image, before the copy can close the file. That error means it
worked. Verify with `ble-gesture-test.py` or a fingerprint write of cue op 0x06,
which only the current firmware accepts — never by trusting a "Flashed" line. A
stale image flashed cleanly once and the device came back looking perfectly fine.

## Gotcha that costs an evening

The dongle **forgets its firmware on every power cycle** and comes back as a bare
ROM that answers HCI commands normally but never reports a single advertiser. A
scan that returns zero devices — not even a neighbour's phone — means the patch
was not uploaded, not that your device is missing. `ble-dfu-flash.py` checks the
local version and uploads via `rtl-load.py` when needed; anything new should do
the same.
