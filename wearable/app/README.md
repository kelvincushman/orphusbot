<!-- Copyright (c) 2025-2026 Kelvin Lee. Licensed under MIT. -->

# Wearable — phone app

The phone side of a self-hosted, body-worn audio wearable. It pairs to a server
you run yourself, bridges the wearable's BLE audio and button streams to it, and
transcribes speech on-device with Gemma. There is no cloud account, no sign-in
and no crash reporter — the app talks only to the server you point it at.

## Layout

Everything is under `lib/wearable/`. `lib/main.dart` is a thin entrypoint: six
init steps, nine providers, one route.

| Path | What lives there |
|---|---|
| `wearable_client.dart` | Server transport — HTTP + WS, mDNS discovery, bearer token in `flutter_secure_storage` |
| `device_bridge.dart` | BLE ↔ server bridge: forwards audio and button events, drains the LED/haptic command queue |
| `local_llm/` | On-device speech-to-text (Gemma 4 E2B via `flutter_gemma`) plus sherpa-onnx diarization and speaker ID |
| `pages/`, `widgets/` | UI. `wearable_home_page.dart` is the four-tab shell |
| `providers/` | `ChangeNotifier`s for connection, device, tabs, tasks, chat, schedules |
| `wearable_theme.dart` | The single light theme. There is no dark variant |

## Build

Flutter is pinned to 3.44.1 via fvm (`.fvmrc`).

```bash
fvm flutter pub get
fvm flutter analyze          # expect 0 errors
fvm flutter test test/wearable/
fvm flutter build apk --debug
```

Flavors are `dev` and `prod` (`fvm flutter run --flavor dev`). Application ids
are `com.kelvinlee.wearable` and `com.kelvinlee.wearable.dev`.

## Pairing

1. The wearable server advertises itself over mDNS on the LAN; the pairing page
   discovers it, or you type a base URL by hand.
2. The server issues a `devId` and a bearer token, which are stored in
   `flutter_secure_storage`. `WearableRoot` gates the whole app on this: unpaired
   shows the pairing page, paired shows the home shell.
3. Settings → Session Server re-pairs or repoints at a different server.

The BLE wearable is paired separately, from the Wearable tab → Connect device,
which scans for the audio service and hands the connected device to
`WearableDeviceBridge.attach()`.

## Notes

- Upstream lineage: this tree began as a fork and the ~298 upstream Dart files
  were removed. `LICENSE-UPSTREAM` and the per-file attribution headers on the
  files that retain upstream portions still apply.
- `assets/` is not bundled — nothing calls `Image.asset` or `rootBundle`. The
  font binaries under `assets/fonts/` are bundled by the `fonts:` block in
  `pubspec.yaml`, which `WearableType.fallback` depends on.
- `setup.sh` and `setup/` are stale upstream onboarding scripts that copy
  Firebase config files this tree no longer has. Use the commands above instead.
