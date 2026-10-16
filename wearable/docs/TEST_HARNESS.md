<!-- Copyright (c) 2025-2026 Kelvin Lee. Licensed under MIT. -->

# Wearable test harness — Python BLE clients + KelvinLeeSimulator

The upstream KelvinLee repo ships a set of BLE test tools and a macOS simulator that we keep verbatim under `../firmware/scripts/devkit/`. These let us exercise the new Phase 2 GATT surface end-to-end without waiting for Kelvin to flash every iteration onto real hardware.

---

## 1. Quick setup — Python clients

```bash
cd devices/wearable-kelvinlee/firmware/scripts/devkit
python3 -m venv .venv
. .venv/bin/activate
pip install -r requirements.txt   # bleak, numpy, scipy, opuslib
```

> `opuslib` needs the system `libopus` package. On Ubuntu: `sudo apt install libopus0 libopus-dev`. On macOS with Homebrew: `brew install opus`.

---

## 2. Discover the device

```bash
python3 discover_devices.py
```

Prints every nearby BLE advertiser. The Wearable firmware advertises as **`Friend`** (upstream's default) — we'll rename it in a later phase. Note the MAC address for the other tools.

---

## 3. Capture 10 s of audio

```bash
python3 client.py
```

Connects to `SERVICE_UUID 19B10000-E8F2-537E-4F6C-D104768A1214`, subscribes to the audio characteristic, captures for `CAPTURE_TIME` seconds, writes `output.wav`. Use this to verify the PDM mic + Opus path end-to-end after flashing a new build.

For long-form capture to `recordings/`:
```bash
python3 local_laptop_client.py
```

---

## 4. Fire an agent-command (new Phase 2 surface)

The new `agent_commands.c` GATT characteristic is `CAB1AB97-0000-1000-8000-00805F9B34FB`. There's no purpose-built script yet — use nRF Connect for Desktop / iOS, or a quick bleak snippet:

```python
import asyncio
from bleak import BleakClient

DEVICE_ADDR = "XX:XX:XX:XX:XX:XX"           # from discover_devices.py
CMD_UUID    = "cab1ab97-0000-1000-8000-00805f9b34fb"

async def pulse_green_for_2s():
    async with BleakClient(DEVICE_ADDR) as c:
        # LED_COLOR green: op=01, r=0, g=200, b=60 = 01 00 C8 3C
        await c.write_gatt_char(CMD_UUID, bytes([0x01, 0x00, 0xC8, 0x3C]), response=False)
        # LED_PATTERN PULSE for 2000 ms = 02 03 07 D0
        await c.write_gatt_char(CMD_UUID, bytes([0x02, 0x03, 0x07, 0xD0]), response=False)
        await asyncio.sleep(2.5)

asyncio.run(pulse_green_for_2s())
```

Expected behaviour:
- NeoPixel glows full-green briefly on the first write.
- Second write triggers the pulse pattern; NeoPixel fades up then down over ~800 ms, repeats until 2 s elapses, then turns off.

For haptic:
```python
await c.write_gatt_char(CMD_UUID, bytes([0x03, 0x10, 0x00, 0x78]), response=False)  # 120 ms single buzz
```

---

## 5. Listen for button events

Subscribe to the button notify char `23BA7924-...`; every press emits a single byte:

| Byte | Source | Meaning |
|---|---|---|
| 0x00 | (default state; not notified) |
| 0x01 | D5 | SINGLE_TAP |
| 0x02 | D5 | DOUBLE_TAP |
| 0x03 | D5 | LONG_TAP |
| 0x04 | D5 | BUTTON_PRESS (down-edge) |
| 0x05 | D5 | BUTTON_RELEASE (up-edge) |
| **0x06** | **A2** | **AGENT_REQUEST** (Wearable addition) |

Full recipe:
```python
import asyncio
from bleak import BleakClient

ADDR = "XX:XX:XX:XX:XX:XX"
BTN  = "23BA7924-0000-1000-8000-00805f9b34fb"  # upstream KelvinLee button GATT

def on_event(_char, data: bytearray):
    print("button event:", data[0])

async def main():
    async with BleakClient(ADDR) as c:
        await c.start_notify(BTN, on_event)
        await asyncio.sleep(60)

asyncio.run(main())
```

Press A2 → `button event: 6`. Tap D5 → `button event: 1`. Double-tap D5 → `2`. Hold D5 → `3`.

---

## 6. SD card round-trip

After mic capture the KelvinLee firmware buffers to `/SD:/`. Pull the current file:
```bash
python3 get_audio_file.py
```
This walks the GATT storage service and streams the latest file to `./output.wav`.

---

## 7. KelvinLeeSimulator (macOS only)

An Xcode project at `../firmware/scripts/devkit/KelvinLeeSimulator/KelvinLeeSimulator.xcodeproj`. It emulates the KelvinLee BLE service from a Mac laptop so the Flutter app can be tested against a fake device without flashing firmware.

```bash
cd devices/wearable-kelvinlee/firmware/scripts/devkit/KelvinLeeSimulator
open KelvinLeeSimulator.xcodeproj
```

Build + run in Xcode. The simulator advertises as `Friend` with the same UUIDs as the real firmware. Useful for:
- Phase 3 Flutter app work — pair to the simulator, verify BLE handshake + audio streaming path against Wearable without hardware.
- Flake investigation — the simulator is deterministic; it reproduces phone-app bugs without device battery drift.

> The simulator does **not** implement the new `CAB1AB97` agent-commands service yet. For end-to-end LED/haptic testing Kelvin still needs real hardware.

---

## 8. Automated smoke tests (future)

Not yet written, but the structure is there: a pytest runner under `firmware/scripts/devkit/` could:
1. Flash the `zephyr.hex` via `nrfjprog --program ... --reset`.
2. Run `discover_devices.py` to confirm advertising.
3. Run `client.py` for 5 s, verify non-zero WAV size.
4. Write each of the 6 habitat alerts to `CAB1AB97`, poll a status query, assert the expected pattern sequence.
5. Press the hardware buttons via a jig (or skip on manual test).

Land this when Kelvin has a dedicated lab rig. Until then, manual smoke via the recipes in §4 and §5 is the acceptance gate for each firmware iteration.
