// Copyright (c) 2025-2026 Kelvin Lee. Licensed under MIT.

import 'package:flutter_test/flutter_test.dart';
import 'package:kelvinlee/wearable/chat/attachment_limits.dart';

void main() {
  test('attachment contract matches server limits', () {
    expect(kWearableMaxAttachments, 8);
    expect(kWearableMaxAttachmentBytes, 25 * 1024 * 1024);
  });

  test('accepts a file exactly at the 25 MB limit', () {
    expect(wearableAttachmentSizeError(name: 'report.pdf', bytes: kWearableMaxAttachmentBytes), isNull);
  });

  test('rejects a file larger than 25 MB with a useful message', () {
    final error = wearableAttachmentSizeError(name: 'recording.mp4', bytes: kWearableMaxAttachmentBytes + 1);

    expect(error, contains('recording.mp4'));
    expect(error, contains('maximum attachment size is 25 MB'));
  });

  test('formats attachment sizes for picker feedback', () {
    expect(wearableAttachmentSizeLabel(12), '12 B');
    expect(wearableAttachmentSizeLabel(1536), '1.5 KB');
    expect(wearableAttachmentSizeLabel(3 * 1024 * 1024), '3.0 MB');
  });
}
