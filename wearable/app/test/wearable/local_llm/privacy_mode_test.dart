// Copyright (c) 2025-2026 Kelvin Lee. Licensed under MIT.
//
// Privacy Mode is stored as the old `OnDeviceSegmentation` enum value, not as a
// new key. These pin that migration: a wearer who had already chosen "Button"
// wakes up in Privacy Mode, and one who had chosen "Continuous" does not.

import 'package:flutter_test/flutter_test.dart';
import 'package:kelvinlee/wearable/local_llm/transcription_mode.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('an install that chose Button reads back as Privacy Mode on', () async {
    SharedPreferences.setMockInitialValues({
      TranscriptionSettings.segmentationKey: 'button',
    });
    expect(await TranscriptionSettings.privacyMode(), isTrue);
  });

  test('an install that chose Continuous reads back as Privacy Mode off', () async {
    SharedPreferences.setMockInitialValues({
      TranscriptionSettings.segmentationKey: 'continuous',
    });
    expect(await TranscriptionSettings.privacyMode(), isFalse);
  });

  test('unset is Privacy Mode off — this is a capture device', () async {
    expect(await TranscriptionSettings.privacyMode(), isFalse);
    expect(await TranscriptionSettings.segmentation(), OnDeviceSegmentation.continuous);
  });

  test('setPrivacyMode writes the segmentation key, not a second one', () async {
    await TranscriptionSettings.setPrivacyMode(true);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString(TranscriptionSettings.segmentationKey), 'button');
    expect(await TranscriptionSettings.privacyMode(), isTrue);

    await TranscriptionSettings.setPrivacyMode(false);
    expect(prefs.getString(TranscriptionSettings.segmentationKey), 'continuous');
    expect(await TranscriptionSettings.privacyMode(), isFalse);
  });

  test('the pure mapping matches the stored form both ways', () {
    expect(TranscriptionSettings.privacyModeFor(OnDeviceSegmentation.button), isTrue);
    expect(TranscriptionSettings.privacyModeFor(OnDeviceSegmentation.continuous), isFalse);
  });
}
