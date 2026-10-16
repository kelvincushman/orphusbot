/* Copyright (c) 2025-2026 Kelvin Lee. Licensed under MIT. */
//
// Covers the reconnect backoff ladder and the battery payload decode.
//
// The ladder is exercised through a subclass that replaces the two members that
// need a radio: `sleep` records the rung instead of waiting it out, and
// `reconnectOnce` reports a scripted outcome. Everything between them — the
// bail-out guards, the rung order, the cancellation checkpoints — is the real
// code. The GATT work inside the real `reconnectOnce` / `readBatteryLevel`
// needs the wearable and is not covered here.

import 'package:flutter_blue_plus/flutter_blue_plus.dart' as ble;
import 'package:flutter_test/flutter_test.dart';
import 'package:kelvinlee/wearable/providers/wearable_device_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

const String _pairedId = 'AA:BB:CC:DD:EE:FF';

/// A provider whose constructor-time cold-start reconnect has already run and
/// found nothing paired, so the test measures only the ladder it starts itself.
Future<_LadderProvider> _quietProvider({int? succeedOnAttempt}) async {
  final provider = _LadderProvider(pairedId: null, succeedOnAttempt: succeedOnAttempt);
  await pumpEventQueue();
  provider.pair(_pairedId);
  return provider;
}

class _LadderProvider extends WearableDeviceProvider {
  _LadderProvider({String? pairedId = _pairedId, this.succeedOnAttempt})
      : _pairedOverride = pairedId;

  String? _pairedOverride;
  ble.BluetoothDevice? connectedOverride;

  /// Attempt number that "finds" the wearable, or null to never succeed.
  final int? succeedOnAttempt;

  /// Every rung actually waited, in order.
  final List<Duration> waits = [];
  int attempts = 0;

  /// Run inside a rung, so a test can change the world mid-ladder.
  void Function(int attempt)? onAttempt;

  /// Run inside a backoff wait — the other half of the ladder, where a real
  /// cancellation almost always lands.
  void Function(int rung)? onWait;

  @override
  String? get pairedDeviceId => _pairedOverride;

  @override
  ble.BluetoothDevice? get connectedDevice => connectedOverride;

  void pair(String deviceId) => _pairedOverride = deviceId;

  void pairDifferentDevice() => pair('AA:BB:CC:DD:EE:FF');

  @override
  Future<void> sleep(Duration duration) async {
    waits.add(duration);
    onWait?.call(waits.length);
  }

  @override
  Future<bool> reconnectOnce(String deviceId) async {
    attempts++;
    onAttempt?.call(attempts);
    return attempts == succeedOnAttempt;
  }
}

void main() {
  // The provider registers a WidgetsBindingObserver so an app resume retries a
  // reconnect, so it needs a binding.
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('reconnect ladder', () {
    test('a cold start with a stored id climbs without being asked', () async {
      SharedPreferences.setMockInitialValues({'wearable_paired_device_id': _pairedId});
      final provider = _LadderProvider();
      // Nobody calls reconnectPairedDevice() here — loading the stored id does.
      await pumpEventQueue();

      expect(provider.waits, WearableDeviceProvider.reconnectBackoff);
      expect(provider.attempts, WearableDeviceProvider.reconnectBackoff.length);
      provider.dispose();
    });

    test('a cold start with nothing paired stays quiet', () async {
      final provider = _LadderProvider(pairedId: null);
      await pumpEventQueue();

      expect(provider.attempts, 0);
      expect(provider.waits, isEmpty);
      provider.dispose();
    });

    test('no paired device is a no-op', () async {
      final provider = _LadderProvider(pairedId: null);
      await provider.reconnectPairedDevice();
      expect(provider.attempts, 0);
      expect(provider.waits, isEmpty);
      provider.dispose();
    });

    test('an empty paired id is a no-op too', () async {
      final provider = _LadderProvider(pairedId: '');
      await provider.reconnectPairedDevice();
      expect(provider.attempts, 0);
      provider.dispose();
    });

    test('already connected is a no-op', () async {
      final provider = (await _quietProvider())..connectedOverride = ble.BluetoothDevice.fromId(_pairedId);
      await provider.reconnectPairedDevice();
      expect(provider.attempts, 0);
      expect(provider.waits, isEmpty);
      provider.dispose();
    });

    test('backs off 1s, 2s, 5s, 10s, 30s and then gives up', () async {
      final provider = await _quietProvider();
      await provider.reconnectPairedDevice();

      expect(provider.waits, const [
        Duration(seconds: 1),
        Duration(seconds: 2),
        Duration(seconds: 5),
        Duration(seconds: 10),
        Duration(seconds: 30),
      ]);
      expect(provider.waits, WearableDeviceProvider.reconnectBackoff);
      expect(provider.attempts, 5);
      provider.dispose();
    });

    test('stops as soon as a rung reconnects', () async {
      final provider = await _quietProvider(succeedOnAttempt: 3);
      await provider.reconnectPairedDevice();

      expect(provider.attempts, 3);
      expect(provider.waits, const [Duration(seconds: 1), Duration(seconds: 2), Duration(seconds: 5)]);
      provider.dispose();
    });

    test('a second call while a ladder is climbing does not stack', () async {
      final provider = await _quietProvider();
      final first = provider.reconnectPairedDevice();
      final second = provider.reconnectPairedDevice();
      await Future.wait([first, second]);

      expect(provider.attempts, WearableDeviceProvider.reconnectBackoff.length);
      expect(provider.waits, WearableDeviceProvider.reconnectBackoff);
      provider.dispose();
    });

    test('an exhausted ladder releases its token so a later drop can climb again', () async {
      final provider = await _quietProvider();
      await provider.reconnectPairedDevice();
      await provider.reconnectPairedDevice();

      expect(provider.attempts, 10);
      expect(provider.waits, [...WearableDeviceProvider.reconnectBackoff, ...WearableDeviceProvider.reconnectBackoff]);
      provider.dispose();
    });

    test('dispose cancels the ladder', () async {
      final provider = await _quietProvider();
      provider.onAttempt = (attempt) {
        if (attempt == 2) provider.dispose();
      };
      await provider.reconnectPairedDevice();

      expect(provider.attempts, 2);
      expect(provider.waits, const [Duration(seconds: 1), Duration(seconds: 2)]);
    });

    test('dispose during a backoff wait stops the ladder before the next rung', () async {
      final provider = await _quietProvider();
      provider.onWait = (rung) {
        if (rung == 2) provider.dispose();
      };
      await provider.reconnectPairedDevice();

      // Waited twice, but only attempted once: the second wait was cancelled
      // before its rung ran.
      expect(provider.waits, const [Duration(seconds: 1), Duration(seconds: 2)]);
      expect(provider.attempts, 1);
    });

    test('connecting by another route mid-ladder stops it', () async {
      final provider = await _quietProvider();
      provider.onAttempt = (attempt) {
        // The scan page got there first.
        if (attempt == 2) provider.connectedOverride = ble.BluetoothDevice.fromId(_pairedId);
      };
      await provider.reconnectPairedDevice();

      expect(provider.attempts, 2);
      provider.dispose();
    });

    test('pairing a different wearable mid-ladder stops it', () async {
      final provider = await _quietProvider();
      provider.onAttempt = (attempt) {
        if (attempt == 2) provider.pairDifferentDevice();
      };
      await provider.reconnectPairedDevice();

      expect(provider.attempts, 2);
      provider.dispose();
    });
  });

  group('paired id persistence', () {
    test('nothing stored means never paired', () async {
      final provider = WearableDeviceProvider();
      await pumpEventQueue();
      expect(provider.hasPairedDevice, isFalse);
      expect(provider.pairedDeviceId, isNull);
      provider.dispose();
    });

    test('a stored id is restored on construction', () async {
      SharedPreferences.setMockInitialValues({'wearable_paired_device_id': _pairedId});
      final provider = WearableDeviceProvider();
      await pumpEventQueue();
      expect(provider.hasPairedDevice, isTrue);
      expect(provider.pairedDeviceId, _pairedId);
      provider.dispose();
    });
  });

  group('battery level', () {
    test('starts null — never read, not zero', () async {
      final provider = WearableDeviceProvider();
      await pumpEventQueue();
      expect(provider.batteryLevel, isNull);
      provider.dispose();
    });

    test('decodes a 0x2A19 uint8 percentage', () {
      expect(WearableDeviceProvider.parseBatteryLevel([82]), 82);
      expect(WearableDeviceProvider.parseBatteryLevel([0]), 0);
      expect(WearableDeviceProvider.parseBatteryLevel([100]), 100);
    });

    test('an empty or out-of-range payload stays null rather than inventing a number', () {
      expect(WearableDeviceProvider.parseBatteryLevel([]), isNull);
      expect(WearableDeviceProvider.parseBatteryLevel([101]), isNull);
      expect(WearableDeviceProvider.parseBatteryLevel([255]), isNull);
    });

    test('reads only the first byte of a longer payload', () {
      expect(WearableDeviceProvider.parseBatteryLevel([47, 99, 12]), 47);
    });
  });
}
