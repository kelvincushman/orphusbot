// Copyright (c) 2025-2026 Kelvin Lee. Licensed under MIT.
//
// The PCM tap is the one public hook a screen has on the WEARABLE channel
// (P1's guided enrolment needs it; the phone mic is the wrong voice). The
// frame sink that invokes it only exists behind a BLE attach, so this pins
// the contract — off by default, plain samples in, nothing returned — and
// the call site is covered by analysis, not by this test.
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:kelvinlee/wearable/device_bridge.dart';

void main() {
  tearDown(() => WearableDeviceBridge.pcmTap = null);

  test('no tap is installed until a screen asks for one', () {
    expect(WearableDeviceBridge.pcmTap, isNull);
  });

  test('an installed tap receives the decoded samples as given', () {
    Int16List? seen;
    WearableDeviceBridge.pcmTap = (s) => seen = s;
    final samples = Int16List.fromList([1, -2, 3]);
    WearableDeviceBridge.pcmTap?.call(samples);
    expect(seen, same(samples));
  });
}
