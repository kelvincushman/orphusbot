// Copyright (c) 2025-2026 Kelvin Lee. Licensed under MIT.
import 'package:flutter_test/flutter_test.dart';
import 'package:kelvinlee/wearable/local_llm/transcription_mode.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('defaults to cloud + continuous when unset', () async {
    expect(await TranscriptionSettings.mode(), TranscriptionMode.cloud);
    // Continuous, i.e. Privacy Mode off — see privacy_mode_test.dart.
    expect(await TranscriptionSettings.segmentation(), OnDeviceSegmentation.continuous);
  });

  test('mode round-trips through SharedPreferences', () async {
    await TranscriptionSettings.setMode(TranscriptionMode.onDevice);
    expect(await TranscriptionSettings.mode(), TranscriptionMode.onDevice);
    await TranscriptionSettings.setMode(TranscriptionMode.cloud);
    expect(await TranscriptionSettings.mode(), TranscriptionMode.cloud);
  });

  test('segmentation round-trips through SharedPreferences', () async {
    await TranscriptionSettings.setSegmentation(OnDeviceSegmentation.continuous);
    expect(await TranscriptionSettings.segmentation(), OnDeviceSegmentation.continuous);
  });

  test('unknown stored value falls back to default', () async {
    SharedPreferences.setMockInitialValues({
      TranscriptionSettings.modeKey: 'garbage',
      TranscriptionSettings.segmentationKey: 'garbage',
    });
    expect(await TranscriptionSettings.mode(), TranscriptionMode.cloud);
    expect(await TranscriptionSettings.segmentation(), OnDeviceSegmentation.continuous);
  });
}
