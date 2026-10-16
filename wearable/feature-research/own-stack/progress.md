<!-- Copyright (c) 2025-2026 Kelvin Lee. Licensed under MIT. -->

# Own-stack progress

## Phase 0 — Toolchain + proven flash loop — COMPLETE (2026-09-06)

| Task | Result |
|---|---|
| T0.1 Zephyr SDK | SDK 1.0.1 on the external dev disk; gcc 14.3.0 verified compiling a Cortex-M4 object |
| T0.2 Zephyr tree | Upstream 4.4.2, 68/68 projects. **NCS 2.9.0 was already installed** at `/opt/nordic/ncs` (symlinked to ExtHdd) — found, not installed |
| T0.3 Build | 407/407 against NCS, **zero source changes**. FLASH 36.70%, RAM 71.74% |
| T0.4 Flash | Flashed over UF2; bootloader exited, device re-enumerated as ZEPHYR CDC, serial restored |

**The flash loop is proven end to end.** Recovery path confirmed working:
double-tap reset → `XIAO-SENSE` mounts → drag `.uf2` → device reboots.

Note: `cp` to the UF2 volume reports
`could not copy extended attributes … Device not configured`. That is normal —
the bootloader consumes the image and reboots before macOS can write xattrs.
The copy succeeded. Judge by re-enumeration, not by `cp`'s exit code.

Console is silent by design: `CONFIG_LOG` / `CONFIG_CONSOLE` / `CONFIG_UART_CONSOLE`
are all unset. The CDC endpoint carries data, not logs.

## Board target — corrected

`xiao_ble/nrf52840/sense`. Both strings previously in the repo were wrong:
`xiao_ble_sense` is the hwmv1 name (alias removed in Zephyr 4.4.2), and
`seeed_xiao_nrf52840_sense` is the UF2 bootloader's `--board-id`
(`nRF52840-SeeedXiaoSense-v1`), never a Zephyr board name.

## Blob-free port — done, not yet merged

Branch `fw/port-zephyr`. Builds against upstream Zephyr 4.4.2 with **no
nrfxlib**: `grep -r "nrfxlib\|softdevice_controller" build_upstream/` returns
nothing, `CONFIG_BT_LL_SW_SPLIT=y`. FLASH 31.99%, RAM 69.86% — *better* than
the NCS build on both.

**+8 dBm TX power is retained.** The port initially lost it: the old setting
used `BT_CTLR_TX_PWR_ANTENNA`, which `depends on !BT_LL_SW_SPLIT` and so exists
only on the SoftDevice Controller. The open link layer takes the level from the
`BT_CTLR_TX_PWR` choice instead, and `BT_CTLR_TX_PWR_PLUS_8` needs only
`HAS_HW_NRF_RADIO_TX_PWR_HIGH`, which the nRF52840 sets. One line restored it —
verified `CONFIG_BT_CTLR_TX_PWR_DBM=8`. **There is no radio cost to dropping
the blobs.**

Remaining upstream regression: the legacy USB device stack now `select`s
`DEPRECATED` (fatal under Zephyr's warnings-as-errors for handwritten
fragments), so `usb_charge` stays false and the green charging LED never
lights. Fix by reading `nrf_power_usbregstatus_vbusdet_get` or porting to
`usbd_*`. Not a blocker.

Merging is a one-way door — the NCS build does not survive the port
(`disk-name` DT requirement, `BT_LE_ADV_CONN_FAST_2`, the nrfx 4.2.0
`prescalers` sub-struct). Supporting both would need an `#ifdef` ladder.

## Verified pre-existing bugs — NOT fixed

1. **GPIO flags silently truncated to zero.** `gpio_dt_flags_t` is `uint16_t`
   in both NCS 2.9 and upstream 4.4.2, but hand-built `gpio_dt_spec`
   initialisers assign 32-bit constants:
   `sdcard.c:26` `GPIO_INT_DISABLE` `0x00200000` → `0x0000`;
   `button.c:66` `GPIO_OUTPUT_ACTIVE` `0x001A0000` → `0x0000`;
   `button.c:69` `GPIO_INT_EDGE_RISING` `0x05400000` → `0x0000`.
   All three flag sets are discarded at compile time. Most serious defect found.
2. `codec.c` encoder-size assert is a no-op — `OPUS_ENCODER_SIZE` defined twice
   (7180 then 10916) and `ASSERT_TRUE(a == b)` expands to `if (!a == b)`.
3. `sdcard.c:99` `LOG_ERR("error while opening directory ", err)` — no format
   specifier; `err` is dropped.
4. `prj_xiao_ble_sense_devkitv1.conf` is unbuildable: its overlay opens with a
   `#` shell comment, invalid DTS. `add-copyright-headers.sh` used the wrong
   comment syntax for `.overlay`. Only devkitv2 + wearable is verified green.

## Next

Phase 1 firmware rewrite. Slices from `scout-fw.md`: wave 1 is `mic`+`codec`,
`led`+`usb`, `battery`, `speaker`/haptic split (parallel); then
`transport`+`storage`+`sdcard` (~1,875 lines, cannot be split); then the button
FSM; then boot. Every slice can now use `west build` as a real acceptance
criterion, which is what Phase 0 existed to buy.

## Phase 1 wave 1 — COMPLETE, verified on hardware (2026-09-06)

All four slices merged: audio (mic + Opus), led/usb, battery, haptic.
FLASH 258124 -> 253072 B (31.99% -> 31.36%), RAM 183132 -> 158908 B
(69.86% -> 60.62%). 24 KB of RAM recovered.

**Boot abort found and fixed.** Six peripheral inits before transport_start()
each did `if (err) return err;`, so one failing peripheral silently killed BLE.
The device enumerated over USB (CDC comes up from SYS_INIT, before main) and
looked alive while doing nothing. Confirmed by raw-HCI scan: 13 advertisers
visible, none ours. Peripheral failures now warn and continue. Also fixed
accel_start() returning 1 on success, which `if (err)` treated as fatal.

**Rebrand nova -> wearable.** 228 files, 4,114 occurrences, 125 paths.
CONFIG_BT_DEVICE_NAME is "wearable". Bundle IDs and Firebase configs excluded
deliberately -- they change as a coupled set or not at all.

**speaker.c -> haptic.c.** Stubs, call sites and the Kconfig option removed.

**Verified over BLE:** the device advertises as `wearable`, MAC
<BLE MAC>, audio service 19B10000-E8F2-537E-4F6C-D104768A1214.

## GATT client — built, not yet run against the device

`~/dev/ble-gatt-test.py` (837 lines): raw HCI over the dongle;
scan -> LE connect -> MTU -> service/char/CCC discovery -> read codec id ->
subscribe to 19B10001 -> count notifications 10 s -> disconnect -> confirm
re-advertise. Endpoints read from the interface descriptor (0x81 INTR events,
0x02/0x82 BULK ACL). ACL fragmentation is mandatory: LE ACL length is 27
bytes, so one 247-byte notification is 10 fragments. Wire-format logic
self-tested offline 14/14 (UUID LE form, ACL header, 10-fragment
reassembly, packet_id/index parse). Defaults: 2 scan+connect attempts, 15 s
gap, 10 s collection, 8 s re-advertise check.

First run (23:37-23:49) got no device data: the wearable was absent from
USB entirely -- no CDC device, no serial port, no bootloader volume -- so it
had no power. Not a firmware fault: CDC enumerates from SYS_INIT before
main(), so a crashed wave-2 image would still appear on USB. Run it when the
device is back:  ~/dev/zephyr/venv/bin/python ~/dev/ble-gatt-test.py
One caveat from its author: the briefed connection interval is 30-50 ms, so
a notification rate under ~100/s should be checked against interval
throttling before blaming the pusher.

## Advertising never resumed after a disconnect — FIXED, hardware-verified (2026-09-07)

The first real BLE client to connect to a post-port image found the device
stopped being connectable after its first disconnect. Connect, stream 1,066
frames, clean disconnect (reason 0x16), then nothing for 56 s and later 11.5
minutes across 39 scan windows while 15 other advertisers stayed visible. USB
stayed enumerated throughout, so the kernel was alive and only the BLE state
was stuck.

**Root cause: the Zephyr 4.4.2 port, not the transport rewrite.** On the NCS
baseline BT_LE_ADV_CONN made the host resume advertising by itself after a
disconnect, so nothing in transport.c ever restarted it -- nothing had to.
The port replaced that removed macro with BT_LE_ADV_CONN_FAST_2, whose
BT_LE_ADV_OPT_CONN is one-shot: the host no longer resumes and the
application must. Silent behaviour change, present in every image since the
port, invisible to a passive scan and to any build-time check. It took a
client that actually connects and drops to surface it.

**Fix:** a bt_conn_cb.recycled handler that restarts advertising, gated on an
adv_wanted flag set after each successful bt_le_adv_start() and cleared at the
top of bt_off() so power-down is respected. recycled rather than disconnected
because on CONFIG_BT_MAX_CONN=1 the connection slot is still being torn down
inside disconnected and bt_le_adv_start can fail -ENOMEM there; recycled fires
once the slot is free, which is what Zephyr documents it for. -EALREADY is
treated as success. 37 lines, FLASH +80 B, RAM unchanged, warnings unchanged.

**Hardware-verified, three consecutive connect/disconnect cycles:**
re-advertising at +24 ms, +2791 ms and +8 ms after Disconnection Complete
(was: never). The 2791 ms is scanner latency, not firmware -- the check opens
a fresh HCI scan window after the disconnect and can miss the first
advertising event; the firmware path is identical in all three. Streaming
healthy throughout: 566/463/466 notifications at 111-115/s (~100/s expected
for 10 ms Opus frames), codec id 0x14 = 20, packet_id monotonic, zero
index anomalies, disconnect reason 0x16 each time.

The 450 ms sleep wave 2 moved into a work item was a red herring: it sits
between two LED cues and never touched advertising.

**This also retires the wave-2 open item** "disconnect -> SD fallback and
reconnect, needs the phone": the disconnect half is now exercised and clean.

## Test rig

A Realtek RTL8761B USB dongle, driven over raw HCI with pyusb -- bypasses macOS
CoreBluetooth and its TCC prompt entirely. The dongle ships in ROM mode and
needs its firmware uploaded first (RAM patch, lost on unplug):
`~/dev/rtl-load.py` then `~/dev/ble-scan.py [secs]`.

`prj_wearable_debug.conf` is NOT flashable: UART_CONSOLE on CDC blocks in
poll-out before a host attaches and the device hangs during boot. Fix options
are recorded in the file.

## Open

- Which peripheral was actually failing is now a WRN line, not a silent death,
  but reading it needs the console fix above.
- Bundle ID / Firebase rename: a deliberate coupled change, owner's call.
- The `nova` namespace meant the *server*, not the device. WearableClient (25
  files) and WearableConnectionStatus (7 files) now carry a device name for a
  backend client. Consistent and building, but ServerClient may be the honest
  name -- owner's call.
- Phase 1 wave 2: transport + storage + sdcard, ~1,875 lines, cannot be split.

## Phase 1 wave 2 — transport + storage + sdcard — MERGED (2026-09-06)

One agent, the three files rewritten as a unit because they share five
mutable globals.

**Hardware-verified (boot + BLE):** flashed via the UF2 helper -- terminal
shows the 507392-byte merged image go on and the bootloader exit -- then a
raw-HCI scan found `wearable` at <BLE MAC>, RSSI -58, advertising the
19B10000 audio service, 9 advertisers visible. So the pusher/GATT/advertising
rewrite did not break the radio path. Still unverified on hardware: the
disconnect -> SD fallback and reconnect (the one behavioural change, below),
storage download end-to-end, and DFU. Those need the phone app.

FLASH 253072 -> 253564 B (+492, all .text), RAM unchanged at 158908 B.
Warnings 35 -> 13, zero in the six files. Symbol set: nothing removed;
five sd_* accessors added.

**Real bugs fixed, all pre-existing:**
- sdcard.c: use-after-free in initialize_audio_file() (freed the path, then
  passed it to create_file()); unbounded write into the 2-element
  file_num_array from the directory walk; unchecked fs_open/read/write.
- storage.c: remaining_length decremented by a fixed 440 regardless of bytes
  sent, so any file not a multiple of 440 wrapped to ~4 GB and streamed past
  EOF forever. Now decrements by bytes actually sent.
- transport.c: get_offset()'s -1 stored raw as 0xFFFFFFFF, above
  MAX_STORAGE_BYTES, silently disabling offline capture whenever info.txt
  was unreadable. The pusher now removes a frame from the ring only once its
  destination is known, closing the disconnect window.

**Locking:** one mutex owned by sdcard.c, guarding every FAT entry point, not
just the two counters -- FATFS is not reentrant and the scratch buffers are
shared, so a metadata-only lock would have left the pusher-appends-while-
storage-reads hazard open. write_sdcard_mutex kept, always taken first.

**0x19B10003 correction.** The coordinator's brief called this characteristic
wire contract. It is not: it sits under CONFIG_KELVINLEE_ENABLE_SPEAKER, which
was removed from Kconfig, so the block never compiles; and the app declares
19B10001/2/5/6 and never 19B10003. The emitted GATT table is byte-identical
to before. Left under the dead guard rather than deleted.

**Behavioural change needing hardware:** the 450 ms k_msleep moved out of the
BT RX disconnect callback into a delayable work item. Verify the
disconnect -> SD fallback and reconnect on the device.

**Recommended next slice: current_connection lifetime.** A use-after-free
class: the pusher refs it unsynchronised, storage.c holds the bare pointer
across blocking FAT reads, and bt_off() vs _transport_disconnected can
double-unref. The fix changes exported get_current_connection(), which
button.c calls, so it belongs with the button slice (wave 3), not here.

Also left alone, pre-existing: bare k_yield() spin loops in both threads;
NUKE is a no-op because file_count is pinned to 1; DELETE ignores file_num;
block_offset not flushed on sd_off(); the accel service compiles in but is
never registered.

## Phase 1 wave 3 — button FSM + connection lifetime — MERGED (2026-09-06)

button.c 905 -> 794 lines. Two interleaved FSMs (D5 upstream, A2 IoT button)
became one tick with two GPIO sources; five work items became one; a2_mutex
removed -- safe by construction, since every deleted work item was already
serialised on the system workqueue. The 171-line commented-out block at
621-791 the firmware scout reported was real (the coordinator's grep had
truncated it with head -8). Wire contract intact: 23BA7924/23BA7925,
final_button_state[2], codes 1-8, every timing now a named constant.

**Connection lifetime (use-after-free class, found by wave 2).**
current_connection is now static behind a spinlock, owns exactly one ref
while non-NULL, and get_current_connection() returns a NEW reference the
caller must release. conn_swap() is the only writer. This closes: the pusher
and storage threads reading a bare pointer with no ref; bt_off() and
_transport_disconnected both unreffing; and a second get_current_connection()
in storage.c that leaked one ref per completed transfer. An independent
adversarial review cleared the design on nine scenarios including all
power-down paths and a deadlock check; the NULL guard is load-bearing because
CONFIG_ASSERT is off.

**M1, found by that review, fixed before merge.** Merging the tick coupled
D5's tick-counting arithmetic to A2's edge timing: an A2 press could shorten
a measured D5 press by up to ~60 ms, and a ~340 ms press read as SINGLE_TAP
-- which powers the device off. The reviewer's suggested catch-up was half
the fix (still 9/40 phases wrong): the shared tick also moved D5's sample
instant. Fixed by carrying the remainder (d5_ticks == floor(elapsed/40) for
all time) AND aligning the next tick to the D5 grid boundary. A 40-phase
sweep of 280-360 ms presses with concurrent A2 traffic now matches the old
two-work-item code on every case; idle wake-ups 249/10 s vs 250 before.

**Timing honesty.** Notify retry is now 40-80 ms (was exactly 40) and
tap-commit 750-790 ms (was exactly 750): deadlines are serviced on the first
tick at or after. Same counts, quantised delay.

FLASH 253564 -> 253432 B, RAM 158908 -> 158780 B. Warnings 13 -> 11, zero
in button/transport/storage/sdcard. The simulation harness was not persisted;
the sweep rests on the agent's pasted output.

**OWNER DECISION -- P0.04.** button_init() drives P0.04 as GPIO_OUTPUT_ACTIVE
(push-pull high). docs/PIN_MAP.md says P0.04 is the IMU's I2C SDA. Either the
pin map is stale or the IMU bus is being clobbered on every boot. Kept as-is
with an in-code comment; this is a hardware call, not a code one.

Needs hardware: every D5 and A2 gesture; the hold bands; boot with A2 held;
and specifically D5 pressed ~1/3 s while working A2, to confirm the device
does not switch itself off. Note the 3 s power-on confirm is unobservable --
System OFF exit is a full SoC reset, so that FSM branch is dead in both old
and new code.

Also noted, out of scope: firmware/kelvinlee/src/lib/core/transport.c still
carries the old use-after-free pattern if that app is ever built.

## App wave 1 — boot on lib/wearable/ alone — MERGED (2026-09-06)

The keystone slice. 383 files, +775 / -68,774. lib/ 373 -> 82 Dart files,
81,727 -> 19,307 lines; pubspec runtime deps 89 -> 26. All 11 outbound
edges from lib/wearable/ into the upstream tree resolved; zero remain.
Analyzer 607 -> 15 (0 errors, 0 warnings; all 15 pre-existing info lints).
110 tests green across 13 files. Debug APK builds (`--flavor dev` is
required; the repo has mandatory flavors), manifest confirmed
com.kelvinlee.wearable.dev / launcher com.kelvinlee.wearable.MainActivity
by decoding the binary manifest's UTF-16 string pool.

**Bundle identifier -- OWNER DECISION.** com.kelvinlee.wearable (.dev,
.development) is the coordinator's default, not a confirmed choice. It is
trivially changeable now and permanent once published. Correction to the
earlier analysis: iOS never carried com.novapai.* -- the pbxproj still had
upstream's com.friend-app-with-wearable.ios12, which the earlier
identity-coupled grep could not have found. Moved to com.kelvinlee.wearable*.

**Two hooks left for the next slice**, both in
lib/wearable/providers/wearable_device_provider.dart, empty and documented:
readBatteryLevel() (GATT 0x180F/0x2A19; batteryLevel is int?, null renders
"BLE" rather than a stale number) and reconnectPairedDevice() (already called
on disconnect; fill with scan-by-id + adopt on a 1/2/5/10/30 s ladder;
WearableDeviceBridge.attachByDeviceId kept for it).

**13 files, 3,441 lines unreachable from main.dart** -- OWNER DECISION.
The scout's 8 (Mission Control, Schedules, Subscription) plus 5 orphaned by
the deletion (ask FAB, routing sheet, schedule editor, cron picker, pro
gate). All compile. Wire in or delete deliberately.

**Losses.** Battery % and BLE auto-reconnect -> hooks above. Firmware OTA
(nordic_dfu / mcumgr_flutter) -> no slice assigned. Foreground-service audio
+ geolocation -> not ported. CaptureProvider transcript mirror -> dropped,
no user-visible effect.

**Found, left alone.** io.intercom.android:intercom-sdk:latest.release is
still in build.gradle -- 412 APK entries of dead weight on a
non-deterministic pin; MyApp.kt was already an Intercom-free stub. The
fonts: block is load-bearing (WearableType.fallback names SF Pro Display),
contradicting the scout's "zero asset references"; kept. macos/linux/windows
targets vestigial; setup.sh still copies deleted Firebase configs.

**The sanitizeTranscript test.** A pre-existing failing test
(expected sanitizeTranscript('OK') == 'OK'; 'ok' is deliberately in
_kGhostTokens, so '' is correct) was fixed by a side-task and landed inside
this commit. Verified test-only: sanitizeTranscript() and _kGhostTokens are
byte-identical to the branch base.

**Not verified:** install, launch, first screen, logcat. The phone had
dropped off ADB by the time the slice reached that step. Expected first
screen with the server down is the pairing page.

scripts/adb-e2e/_lib.sh PKG updated to com.kelvinlee.wearable.dev -- it had
been com.wearable.app.dev since the rebrand, matching nothing.

---

## Wave: A2 button grammar (2026-09-07, `1793310`)

Three schemes designed independently (convention-led / failure-led /
memory-led), judged three ways, decided into one spec, then built across
firmware, app and server-contract in parallel worktrees.

**The scheme, in three rules: tap = yes, tap twice = no, hold = power.**
State supplies the fourth dimension. A tap is *start talking* when idle,
*stop and file* when listening, *yes* when the device is asking. Two taps
is *scratch that* mid-note, *not now* on an alert. Hold 2 s to wake, 4 s
to shut down. Triple tap is a link-recovery hatch. There is no pairing
gesture — `CONFIG_BT_SMP` is commented out, so there are no bonds to
clear. D5's single-tap power-off is deleted; D5 is telemetry only.

**What the design found in the existing firmware**, none of it new work:

- The power-on confirm hold is dead code. `button_init()` sets
  `a2_pressed` but never `a2_hold_armed`, so `a2_track_hold()` never runs
  on a System OFF wake.
- `nrf_gpio_cfg_sense_set(P0.28, SENSE_LOW)` means powering off with the
  button still held latches DETECT and blocks System OFF: power-off →
  instant wake → boot. Fixed by gating `sys_poweroff()` on release.
- `AGENT_OP_HAPTIC` ignored its pattern byte, so every app-sent haptic was
  one undifferentiated buzz.

**What the merge found that no lane could see.** Both are wire breaks
between lanes; each on its own dropped every button cue silently:

- Firmware had no `AGENT_OP_HABITAT`. The fw lane's report noted its new
  cues "were dropped by --gc-sections" and read that as a saving. All
  twelve are linked now.
- The server queues cues by *name*; the app's fallback encoder required
  an int and returned null.

`device.test.ts` had not loaded since extraction — three stale
`../src/harness/` import paths — so nothing in `commands.ts` was covered
by an executing test. Fixed; the `stt.ts` half (imports an `env.js` that
never came across) is split into its own file so it fails alone. 68 → 96.

**Verified:** west build against upstream Zephyr 4.4.2, FLASH 254328 B
(31.52%), RAM unchanged, 11 warnings (the same 11, none in touched
files); `flutter analyze` 15 issues 0 errors; 221 app tests; 96 server
tests.

**Not verified:** no gesture has been performed on hardware. Every timing,
every cue and every row of the behaviour table is reasoned from code, not
measured. The release-gated power-off in particular needs a real press.

---

## Hardware session: the A2 grammar's first real button press (2026-09-07 evening)

Everything before tonight was compile-time. The firmware ships
`CONFIG_CONSOLE=n` with no log output, so a button press is observable only
as a GATT notify, an LED or a buzz — which is why
`firmware/scripts/ble-gesture-test.py` exists. It drives an RTL8761B over raw
HCI and plays the *app's* half of the loop as well as the listener's, because
the firmware arms a 1500 ms watchdog on every committed gesture and cues an
error if no cue write comes back.

**The grammar passed.** Codes 7 (single tap), 6 (double tap), 9
(`POWER_OFF_ARMED`, 1.5 s) and 11 (`POWER_OFF_COMMITTED`, 4 s) all arrived,
sequence numbers 1,2,3 consecutive, no drops. `AGENT_OP_HABITAT` works: cue
ops that were rejected before the flash are accepted after it, which makes it
the first of the merge blockers confirmed on real hardware.

**Every gesture now verified on hardware.** Second session, after the two
fixes below plus the app-ack wiring:

| Gesture | Code | Result |
|---|---|---|
| Single tap | 7 CAPTURE | pass |
| Double tap | 6 CANCEL | pass |
| Triple tap | 8 LINK_RECOVER | pass, link survives |
| Hold 1.5 s | 9 POWER_OFF_ARMED | pass |
| Hold 4 s | 11 POWER_OFF_COMMITTED | pass |
| After power-off | — | stays off |
| Hold 2 s from off | — | wakes (by hand) |

Sequence numbers ran 1..6 consecutive across the triple-tap session with no
dropped notifications, and zero phantom D5 events.

**A third defect, found while setting the triple-tap test up.**
`button_note_app_ack()` had no callers — `agent_commands.c` never included
`button.h`. So `a2_app_ack_ms` stayed 0 forever, and two things followed:
the 1500 ms confirmation watchdog never disarmed, firing `habitat_error()`
(red flash 3 s + triple buzz) after *every* committed gesture however
correctly the app answered; and `a2_link_recover()`'s health gate was
permanently false, so a triple tap always dropped the BLE link instead of
notifying code 8. The gesture could not have passed before this was wired.
The comment above `a2_link_recover` predicted it exactly — "an unwired build
is loudly wrong rather than quietly wrong". It was loudly wrong for weeks;
nobody was listening, because the error is an LED and a buzz on a device
with no console.

**Two inherited defects, found in the same capture.**

D5 floats. `gpio_pin_configure_dt(&d5_pin_input, GPIO_INPUT)` with `dt_flags`
0 leaves P0.05 with no pull while `GPIO_INT_EDGE_BOTH` is armed on it. Every
A2 press produced a matching D5 SINGLE/LONG/RELEASE — a finger's capacitance
near the board, not a press.

The device powered off and woke straight back up. `turnoff_all()` armed
`GPIO_INT_LEVEL_INACTIVE` on that same floating pin as a System OFF wake
source; with `dt_flags` 0 that is SENSE on physical LOW, which a floating line
drifts to. DETECT was asserted the instant `SYSTEMOFF` was written. The A2
release gate was working the whole time — this is the failure the spec
predicted for A2, arriving through the one pin nobody had looked at. D5 is no
longer a wake source at all.

**Flashing, which cost more than the debugging.** Three attempts:

1. A flash reported success and wrote a *stale* image — `flash-wearable.sh`
   defaulted to a hand-copied `~/dev/wearable.uf2` and hid `cp`
   errors behind `2>/dev/null`. Only fingerprinting the device caught it.
2. macOS gates writes to removable volumes per-application. An agent shell
   gets `Permission denied` on `/Volumes/XIAO-SENSE` even with the sandbox
   disabled, while the user's own terminal succeeds.
3. Python's `shutil.copyfile` does get through, and reports `[Errno 5]
   Input/output error` **on success** — the bootloader reboots the moment it
   has the whole image.

Rule that came out of it, now in `firmware/scripts/README.md`: verify a flash
by fingerprinting the device, never by trusting a "Flashed" line.

Legacy BLE DFU (`firmware/scripts/ble-dfu-flash.py`) is written and its
transport is proven — a full 12709-packet transfer completed with every stage
ACKed — but the resulting image does not boot, most likely because legacy DFU
carries no address while this image links at 0x27000. It refuses to run
without `--i-know-it-does-not-boot`. UF2 is the flash path.

---

## App on hardware: build, install, and the model (2026-09-07 evening)

Installed on a Galaxy S24 FE and driven through adb.

**Two structural bugs, both the same shape.** The app gated itself on a
Wearable *server* in two places, and the thing it actually exists to do —
pair to the wearable over BLE — sat behind both. `WearableRoot` demanded a
base URL and bearer token before rendering anything, and `attach()` opened
with `if (!await client.isPaired()) return null;`, so the scan could find
the device at -55 dBm, connect to it, and then be refused with "Bridge
attach failed — Wearable pairing missing?" — a message that blamed the
wearable for the server's absence. Both gates removed; a server is now what
it always was, optional enrichment, reachable from Settings. Verified on
hardware: bridge active, battery read live over GATT, no server paired.

**mDNS discovery had never worked on Android.** `Dart Socket ERROR:
reusePort not supported on this platform` — the default `MDnsClient` binds
with `reusePort: true`, which Android rejects, and `discover()` swallowed
the throw and returned an empty list. The pairing page said "No Wearable
found on the LAN", which reads as "the server is off". Manual URL entry had
been carrying the whole flow. Fixed with the package's own socket-factory
workaround.

**Model: Gemma 4 E2B → E4B**, 2.59 GB → 3.66 GB, on the owner's call for
best accuracy in testing. Not the `-gpu` variant (2.97 GB): it drops the CPU
weights and `PreferredBackend.gpu` is a preference, so a device that falls
back would hold a model it cannot run. Pinned by immutable commit SHA, byte
count and SHA-256, all read from the HF API.

**Build sizes.** The debug APK is 532 MB and `--target-platform android-arm64`
barely dents it (509 MB) — debug builds keep every ABI, and the weight is
native libs: MediaPipe, LiteRT, ONNX Runtime, Qualcomm QNN, plus a 64 MB
`kernel_blob.bin`. A **release** build of the `dev` flavour is 350 MB, and
installing it *freed* space rather than consuming it.

Two traps worth knowing:
- `flutter build apk` reports "Gradle build failed to produce an .apk file"
  when the project has product flavours. The APK is fine, in
  `android/app/build/outputs/`. Do not trust the failure line.
- `assembleRelease` fails with `SigningConfig "release" is missing required
  property "storeFile"` — there is no keystore and no `key.properties`. Only
  the `prod` flavour uses it; `dev` signs with the debug key. Failing is the
  correct behaviour for prod, so it is left alone. **Owner item: a release
  keystore is needed before anything ships.**

**Storage is the current blocker.** 110 GB device, 2.0 GB free before this
work: photos 20.3 GB, videos 5.5 GB, app data 40.8 GB, installed apps 39.8
GB. `pm trim-caches` freed nothing (Android had already trimmed). The
release install brought it to 3.71 GB, which is still too tight for a
3.66 GB model plus working space.

**Never run on hardware yet:** the Gemma model has never been downloaded to
the phone, so on-device transcription is entirely unproven end to end.

---

## Owner decisions on capture, storage and background (2026-09-09)

Four forks settled by the owner. Recorded here because they change the shape
of the app, not just its settings.

1. **Push to talk.** A press ARMS the next utterance — you press, then speak
   the instruction. Not "act on what I just said". The 1500 ms capture
   pre-roll already covers the gap between the press and the first word.

2. **The "Button" capture trigger becomes PRIVACY MODE**, and moves to the
   main dashboard. This inverts the default: continuous transcription becomes
   normal, and privacy mode is the opt-in where nothing is transcribed unless
   the wearer presses. The battery and thermal cost of continuous has never
   been measured on this hardware — that measurement is now on the critical
   path, not a nice-to-have.

3. **A long capture segments and continues.** At the cap, file that segment
   and immediately start a new one, so a 20-minute meeting becomes
   consecutive parts and nothing is lost. Today the cap is 120 s and it simply
   stops.

4. **The wearable must live in the BACKGROUND.** Capture, transcription and
   BLE keep running with the app closed, with notifications reaching the phone
   screen. Today there is no foreground service and no notification package at
   all — `POST_NOTIFICATIONS` and the `FOREGROUND_SERVICE_*` permissions are
   declared in the manifest but nothing implements them, inherited from
   upstream. This is the largest single piece of work outstanding.

5. **A MicroSD is fitted and wired.** So offline recording can be enabled and
   tested. Both halves are already written — `transport.c` records to SD when
   no phone is attached, and the app has a full backlog sync that pulls,
   decodes and transcribes it — but `CONFIG_DISK_DRIVER_SDMMC` and
   `CONFIG_SPI` are commented out of the shipping config. The variant that
   enables them, `prj_wearable_phase3_sd.conf`, also sets
   `CONFIG_KELVINLEE_ENABLE_BATTERY=n` and `CONFIG_KELVINLEE_ENABLE_USB=n`.
   Whether that trade is a real pin conflict or stale config is unresolved and
   must be answered before flipping it on.

**Agent haptic feedback is NOT a missing feature.** The channel was dead until
`AGENT_OP_HABITAT` landed tonight and is now confirmed on hardware. The cue
the owner described — "look at your phone, I need your approval" — already
exists as `awaiting_input` (amber pulse + long buzz), and the app arms an
alert state so the next tap answers it. What is missing is anything that
DECIDES to send it, which is the agent's job and needs a server.
