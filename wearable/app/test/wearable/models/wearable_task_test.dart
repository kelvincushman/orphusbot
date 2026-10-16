// Copyright (c) 2025-2026 Kelvin Lee. Licensed under MIT.

import 'package:flutter_test/flutter_test.dart';
import 'package:kelvinlee/wearable/models/wearable_task.dart';

void main() {
  test('task detail retains artifacts and valid HTTPS Drive links', () {
    final detail = WearableTaskDetail.fromJson({
      'contract': {'taskId': 'task-123', 'role': 'research', 'createdAt': 1234},
      'status': 'completed',
      'response': 'Done',
      'artifacts': [
        {'path': 'reports/final.pdf', 'size': 4096, 'mtime': 9876.5},
        {'path': '', 'size': 10, 'mtime': 1},
      ],
      'driveLinks': [
        'https://drive.google.com/file/d/abc123/view',
        'https://docs.google.com/document/d/doc123/edit',
        'http://drive.google.com/insecure',
        'not a URL',
      ],
    });

    expect(detail.artifacts, hasLength(1));
    expect(detail.artifacts.single.path, 'reports/final.pdf');
    expect(detail.artifacts.single.size, 4096);
    expect(detail.artifacts.single.modifiedAt, 9876);
    expect(detail.driveLinks, [
      'https://drive.google.com/file/d/abc123/view',
      'https://docs.google.com/document/d/doc123/edit',
    ]);
  });

  test('task detail tolerates missing artifact fields', () {
    final detail = WearableTaskDetail.fromJson({
      'contract': {'taskId': 'task-123'},
      'status': 'active',
    });

    expect(detail.artifacts, isEmpty);
    expect(detail.driveLinks, isEmpty);
  });
}
