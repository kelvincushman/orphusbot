import 'package:flutter_test/flutter_test.dart';
import 'package:orphusbot_app/update.dart';

void main() {
  test('only a stamped build that differs from the newest is out of date', () {
    expect(outOfDate('abc123', {'build': 'def456'}), isTrue);
    expect(outOfDate('abc123', {'build': 'abc123'}), isFalse);
    expect(outOfDate('', {'build': 'def456'}), isFalse); // development build
    expect(outOfDate('abc123', null), isFalse); // nothing published
    expect(outOfDate('abc123', {'build': ''}), isFalse);
  });
}
