<!-- Copyright (c) 2025-2026 Kelvin Lee. Licensed under MIT. -->

# Wearable / Wearable device test harness (Mac-side)

Two tools to test the on-device-STT feature without a physical wearable.

| Tool | Drives | How |
|---|---|---|
| `wearable_driver.py` | the **Wearable backend** directly (HTTP) | python3 (stdlib) |
| `WearableSim.app` + `wearable_ctl.py` | the **phone app** over **BLE** (faithful wearable) | ObjC/CoreBluetooth `.app` + python controller |

---

## 1. `wearable_driver.py` — backend driver (no phone needed)

Exercises the new `POST /api/device/text`, button events, LED/haptic command
poll, and the agent reply stream — what the phone sends *after* on-device
transcription. Stdlib-only.

```bash
export WEARABLE_BASE_URL=http://<wearable-host>:3141
export WEARABLE_BEARER=<dashboard-token>
python3 wearable_driver.py register --label "Mac sim"     # one-time: gets a device token
python3 wearable_driver.py turn "what's on my calendar today"   # button+text+reply+LED
python3 wearable_driver.py text "remind me to call Alice" --overheard
python3 wearable_driver.py button AGENT_REQUEST
python3 wearable_driver.py poll          # pending LED/haptic commands
python3 wearable_driver.py stream        # tail the device chat SSE
```
Creds cache to `.wearable_test.json` (chmod 600, git-ignored).

---

## 2. BLE wearable emulator — drives the phone app

`WearableSim.app` advertises the KelvinLee GATT profile so the phone connects to the
Mac **as if it were the wearable**, then streams a WAV as audio frames and fires
button presses. The phone runs its real path: BLE audio → `device_bridge` →
Gemma on-device → `POST /api/device/text`. LED/haptic packets are logged.

### Why a `.app` + a Swift/ObjC binary (not Python)
macOS TCC **aborts** any process that touches CoreBluetooth unless it's a
LaunchServices-registered `.app` bundle carrying `NSBluetoothAlwaysUsageDescription`.
A bare Python (or bare CLI) crashes with SIGABRT. So the sim is a native ObjC
binary packaged as `WearableSim.app`, launched via `open`, and controlled over a
local TCP socket (127.0.0.1:8765).

### Build
```bash
./build.sh          # clang → WearableSim.app (ad-hoc signed)
```
Needs the Xcode Command Line Tools (`clang`). No sudo, no Swift (the CLT Swift
toolchain is broken on this machine; clang/ObjC is fine).

### Run
```bash
./run.sh            # launches WearableSim.app and tails /tmp/wearable-sim.log
```
**First run: macOS shows a "WearableSim wants to use Bluetooth" prompt — click
Allow** (or System Settings → Privacy & Security → Bluetooth → enable WearableSim,
then `./run.sh` again). The log should then print `advertising 'KelvinLee' …`.

### Control (from another terminal)
```bash
python3 wearable_ctl.py                 # interactive REPL
python3 wearable_ctl.py status          # advertising / not-ready
python3 wearable_ctl.py say samples/remind_alice.wav   # AGENT_REQUEST + stream one utterance
python3 wearable_ctl.py audio samples/calendar_query.wav   # stream audio only (VAD mode)
python3 wearable_ctl.py button agent
```
Sample 16 kHz mono WAVs are in `samples/`; make more with:
`say -o x.aiff "..." && afconvert -f WAVE -d LEI16@16000 -c 1 x.aiff out.wav`

### Notes / limits
- Advertises codec=**linear16**, so no Opus encoding on the Mac; `device_bridge`
  decodes via `pcm16BytesToSamples`.
- Button is sent on both the upstream (`23ba7925…7450`) and `device_bridge`
  (`23ba7924…8000`) characteristics so the on-device capture window opens.
- The phone must initiate the BLE connection (one tap on the app's scan screen).
- If large audio notifies fail, the negotiated MTU is small — lower `FRAME_BYTES`.

---

## End-to-end on-device test (full loop)
1. Wearable running + reachable from the phone; app paired; Gemma model installed;
   **Settings → Voice & Hands-Free → On-device transcription = ON**.
2. `./run.sh` → **Allow Bluetooth** → wait for `advertising 'KelvinLee'`.
3. On the phone: scan/pair screen → connect to **KelvinLee**.
4. `python3 wearable_ctl.py say samples/remind_alice.wav`
5. Expect: local transcript in the app → `POST /api/device/text` on Wearable (audit
   `device.prompt.text`) → agent runs → LED/haptic command logged in
   `/tmp/wearable-sim.log`.
