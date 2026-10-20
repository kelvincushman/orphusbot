import 'package:flutter_test/flutter_test.dart';
import 'package:orphusbot_app/chat.dart';

void main() {
  test('token counts read at a glance', () {
    expect(compactCount(950), '950');
    expect(compactCount(12420), '12k');
    expect(compactCount(4321), '4.3k');
    expect(compactCount(3100000), '3.1M');
  });
}
