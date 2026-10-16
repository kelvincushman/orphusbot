// Copyright (c) 2025-2026 Kelvin Lee. Licensed under MIT.
//
// WearableDeviceProvider — the app's view of the BLE wearable: is one paired,
// is it connected right now, and what is its battery level.
//
// The first connect/scan flow lives in WearableScanPage, and the GATT traffic
// lives in WearableDeviceBridge. This provider holds the state those two
// produce, so the AppBar pill and the device page can watch it — plus the two
// jobs neither of them can own: climbing back onto the paired wearable after it
// drops, and keeping the battery percentage current.

import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart' as ble;
import 'package:shared_preferences/shared_preferences.dart';

import '../device_bridge.dart';

class WearableDeviceProvider extends ChangeNotifier with WidgetsBindingObserver {
  /// Remote id of the last device the user connected to. Persisted so the app
  /// can tell "never paired" from "paired but currently out of range" on a cold
  /// start — the question the status pill asks.
  static const String _prefsPairedIdKey = 'wearable_paired_device_id';

  /// Battery Service (0x180F) and its Battery Level characteristic (0x2A19),
  /// both live on the firmware's GATT table at handles 0x000C-0x0010. `Guid`
  /// normalises these short SIG forms to 128-bit, so they compare equal to
  /// whatever discovery hands back.
  static final ble.Guid _batteryService = ble.Guid('180F');
  static final ble.Guid _batteryLevelChar = ble.Guid('2A19');

  /// Backoff ladder for [reconnectPairedDevice]: wait, try, wait longer, try
  /// again. Five rungs is ~48s of trying, which covers the ordinary drop — the
  /// firmware re-advertises within ~24ms of a disconnect, so a device that is
  /// still in range is found on the first or second rung.
  ///
  /// PONYTAIL: past the last rung we stop rather than scan forever. A wearable
  /// left out of range for minutes does not come back on its own; it takes an
  /// app resume (see [didChangeAppLifecycleState]) or a manual scan. The
  /// alternative — a 30s rung repeating indefinitely — is a radio wakeup every
  /// half minute for as long as the app lives, which is not worth it.
  static const List<Duration> reconnectBackoff = [
    Duration(seconds: 1),
    Duration(seconds: 2),
    Duration(seconds: 5),
    Duration(seconds: 10),
    Duration(seconds: 30),
  ];

  /// How long one rung waits for the paired device to appear in a scan, and how
  /// long it then gives the connect.
  static const Duration _rungTimeout = Duration(seconds: 6);

  ble.BluetoothDevice? _connectedDevice;
  ble.BluetoothDevice? get connectedDevice => _connectedDevice;

  String? _pairedDeviceId;
  bool get hasPairedDevice => (_pairedDeviceId ?? '').isNotEmpty;
  String? get pairedDeviceId => _pairedDeviceId;

  /// Wearable battery percentage, or null when it has never been read.
  ///
  /// Null is load-bearing: the pill renders "BLE" rather than a stale or made-up
  /// number. Nothing here ever defaults it to 0 or 100. See [readBatteryLevel].
  int? _batteryLevel;
  int? get batteryLevel => _batteryLevel;

  StreamSubscription<ble.BluetoothConnectionState>? _connectionSub;
  StreamSubscription<List<int>>? _batterySub;

  /// Identity of the backoff ladder currently climbing, or null when none is.
  /// Every checkpoint in the loop compares against it, so clearing it cancels
  /// the ladder at the next await boundary and keeps a second call a no-op
  /// while one is already running.
  Object? _reconnectToken;

  bool _disposed = false;

  WearableDeviceProvider() {
    WidgetsBinding.instance.addObserver(this);
    unawaited(_loadPairedId());
  }

  Future<void> _loadPairedId() async {
    final prefs = await SharedPreferences.getInstance();
    if (_disposed) return;
    _pairedDeviceId = prefs.getString(_prefsPairedIdKey);
    notifyListeners();
    // Cold start with a wearable already paired: climb onto it without waiting
    // to be asked. The lifecycle observer below only sees *transitions*, so it
    // never fires for the launch itself, and main.dart's
    // `setOptions(restoreState: true)` often means the first rung takes the
    // no-scan fast path.
    unawaited(reconnectPairedDevice());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Coming back to the foreground is the other moment a reconnect is worth
    // trying: the drop may have happened while we were backgrounded, or a
    // ladder may have run out of rungs down there.
    if (state == AppLifecycleState.resumed) {
      unawaited(reconnectPairedDevice());
    }
  }

  /// Record a device the user has just connected to. WearableScanPage calls
  /// this after WearableDeviceBridge.attach() succeeds, and so does the
  /// reconnect ladder.
  Future<void> adopt(ble.BluetoothDevice device) async {
    // Whatever we were climbing towards, this supersedes it — including the
    // case where the user pairs a *different* wearable mid-ladder.
    _cancelReconnect();

    // Drop the previous device's battery before announcing the new one.
    // notifyListeners() below rebuilds the status pill, and without this a
    // freshly adopted wearable renders the *last* one's percentage until its
    // own read lands. null reads as "not known yet", which is honest.
    if (_connectedDevice?.remoteId.str != device.remoteId.str) {
      _batterySub?.cancel();
      _batterySub = null;
      _batteryLevel = null;
    }

    _connectedDevice = device;
    _pairedDeviceId = device.remoteId.str;
    notifyListeners();

    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_prefsPairedIdKey, device.remoteId.str);

    _connectionSub?.cancel();
    _connectionSub = device.connectionState.listen((state) {
      if (state == ble.BluetoothConnectionState.disconnected) {
        _onDisconnected();
      }
    });

    unawaited(readBatteryLevel());
  }

  void _onDisconnected() {
    _connectedDevice = null;
    _batteryLevel = null;
    _connectionSub?.cancel();
    _connectionSub = null;
    _batterySub?.cancel();
    _batterySub = null;
    // Tear the bridge down so its audio WS and GATT subscriptions don't leak
    // across reconnects.
    unawaited(WearableDeviceBridge.current?.dispose() ?? Future<void>.value());
    notifyListeners();
    unawaited(reconnectPairedDevice());
  }

  /// Re-attach to the paired wearable after it drops or the app resumes.
  ///
  /// Climbs [reconnectBackoff]: wait the rung, then try one scan-connect-adopt.
  /// Returns when the wearable is back, when the ladder is cancelled, or when
  /// the rungs run out.
  ///
  /// No-op when there is no paired device, when one is already connected, or
  /// when a ladder is already climbing — so the disconnect callback and an app
  /// resume arriving together still produce exactly one ladder.
  ///
  /// Cancellation is by token: [adopt] and [dispose] clear it, and the loop
  /// unwinds at its next checkpoint. A ladder therefore never outlives the
  /// provider and never stacks two deep.
  Future<void> reconnectPairedDevice() async {
    final deviceId = pairedDeviceId;
    if (deviceId == null || deviceId.isEmpty) return;
    if (connectedDevice != null) return;
    if (_reconnectToken != null) return;

    final token = Object();
    _reconnectToken = token;
    try {
      for (final rung in reconnectBackoff) {
        await sleep(rung);
        // Anything that happened during the wait outranks the ladder.
        if (!identical(_reconnectToken, token)) return; // cancelled or superseded
        if (connectedDevice != null) break; // the scan page got there first
        if (pairedDeviceId != deviceId) break; // a different wearable was paired
        if (await reconnectOnce(deviceId)) return; // adopt() cleared the token
        if (!identical(_reconnectToken, token)) return;
      }
    } finally {
      if (identical(_reconnectToken, token)) _reconnectToken = null;
    }
  }

  /// Stop any ladder in flight. Idempotent and cheap — the loop checks the
  /// token after every await, so it unwinds at the next boundary rather than
  /// being torn out mid-scan.
  void _cancelReconnect() => _reconnectToken = null;

  /// The ladder's wait between rungs.
  ///
  /// Overridden in tests so the backoff can be observed without spending 48
  /// real seconds on it.
  @protected
  @visibleForTesting
  Future<void> sleep(Duration duration) => Future<void>.delayed(duration);

  /// One rung: get back onto [deviceId] and [adopt] it. True once the wearable
  /// is connected and the bridge is attached.
  ///
  /// Overridden in tests — every line below is a flutter_blue_plus static or a
  /// live radio, so the ladder above it is what unit tests exercise.
  @protected
  @visibleForTesting
  Future<bool> reconnectOnce(String deviceId) async {
    // The whole body is guarded, not just connect(). Every call here can throw a
    // PlatformException — attachByDeviceId and adopt hit the keystore and GATT,
    // _scanFor drives the radio — and all three call sites of
    // reconnectPairedDevice() are unawaited, so an escaping throw is an
    // unhandled async error AND silently ends the ladder on whichever rung it
    // lands. A rung that fails must return false so the next one runs.
    try {
      // Fast path: the OS still holds the link — main.dart asks flutter_blue_plus
      // to restore state across relaunches, and a bridge teardown does not drop
      // the BLE connection. No scan needed, just put the bridge back on it.
      for (final device in ble.FlutterBluePlus.connectedDevices) {
        if (device.remoteId.str != deviceId) continue;
        if (await WearableDeviceBridge.attachByDeviceId(deviceId) == null) return false;
        await adopt(device);
        return true;
      }

      // A scan is already running, which means WearableScanPage owns the radio
      // and will adopt on its own. Skip the rung rather than hijack it —
      // startScan() silently stops an in-flight scan instead of refusing.
      if (ble.FlutterBluePlus.isScanningNow) return false;

      final device = await _scanFor(deviceId);
      if (device == null) return false;

      await device.connect(timeout: _rungTimeout);
      // Bridge attach only fails when the *server* pairing is missing. Leave
      // the BLE link up: the next rung takes the fast path above and retries
      // the attach without paying for another scan.
      if (await WearableDeviceBridge.attach(device) == null) return false;
      await adopt(device);
      return true;
    } catch (e) {
      debugPrint('[WearableDevice] reconnect to $deviceId failed: $e');
      return false;
    }
  }

  /// Scan for one known remote id. Null when it does not show up in time.
  Future<ble.BluetoothDevice?> _scanFor(String deviceId) async {
    final seen = Completer<ble.BluetoothDevice?>();
    StreamSubscription<List<ble.ScanResult>>? scanSub;
    try {
      scanSub = ble.FlutterBluePlus.scanResults.listen((results) {
        for (final r in results) {
          if (r.device.remoteId.str == deviceId && !seen.isCompleted) {
            seen.complete(r.device);
          }
        }
      });
      await ble.FlutterBluePlus.startScan(withRemoteIds: [deviceId], timeout: _rungTimeout);
      return await seen.future.timeout(_rungTimeout, onTimeout: () => null);
    } catch (e) {
      debugPrint('[WearableDevice] reconnect scan for $deviceId failed: $e');
      return null;
    } finally {
      await scanSub?.cancel();
      // Stop our own scan before connecting — a connect during a scan is flaky
      // on Android.
      await ble.FlutterBluePlus.stopScan();
    }
  }

  /// Read the wearable's battery percentage over GATT, then keep it live.
  ///
  /// Battery Service 0x180F, characteristic 0x2A19 — one uint8, 0-100. Reads
  /// once and, when the characteristic supports notify, subscribes so the
  /// firmware pushes changes instead of us waking the radio to poll. [adopt]
  /// calls this; [_onDisconnected] tears it back down.
  ///
  /// A device without the service, or a read that fails, leaves [batteryLevel]
  /// null on purpose — the pill then shows "BLE" rather than a number nobody
  /// can stand behind.
  Future<void> readBatteryLevel() async {
    final device = _connectedDevice;
    if (device == null) return;
    try {
      // The bridge has already run discovery by the time adopt() calls us, so
      // reuse its result rather than paying for a second GATT walk.
      final services = device.servicesList.isNotEmpty ? device.servicesList : await device.discoverServices();
      ble.BluetoothCharacteristic? level;
      for (final service in services) {
        if (service.uuid != _batteryService) continue;
        for (final characteristic in service.characteristics) {
          if (characteristic.uuid == _batteryLevelChar) level = characteristic;
        }
      }
      if (level == null) return;

      final value = await level.read();
      if (!identical(_connectedDevice, device)) return; // dropped mid-read
      _applyBatteryValue(value);

      if (!level.properties.notify) return;
      await level.setNotifyValue(true);
      await _batterySub?.cancel();
      _batterySub = level.lastValueStream.listen(_applyBatteryValue);
    } catch (e) {
      debugPrint('[WearableDevice] battery read failed: $e');
    }
  }

  void _applyBatteryValue(List<int> value) {
    final level = parseBatteryLevel(value);
    if (level == null || level == _batteryLevel || _disposed) return;
    _batteryLevel = level;
    notifyListeners();
  }

  /// Decode a Battery Level (0x2A19) payload: one uint8, 0-100. Null for an
  /// empty or out-of-range payload, which leaves [batteryLevel] at never-read
  /// instead of inventing a percentage.
  @visibleForTesting
  static int? parseBatteryLevel(List<int> value) {
    if (value.isEmpty) return null;
    final level = value.first;
    return (level >= 0 && level <= 100) ? level : null;
  }

  @override
  void dispose() {
    _disposed = true;
    _cancelReconnect();
    WidgetsBinding.instance.removeObserver(this);
    _connectionSub?.cancel();
    _batterySub?.cancel();
    super.dispose();
  }
}
