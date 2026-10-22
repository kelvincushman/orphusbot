import 'package:flutter_test/flutter_test.dart';
import 'package:orphusbot_app/room.dart';

void main() {
  test('the orb follows the voice: quiet is still, loud is full', () {
    expect(levelOf(-80), 0);
    expect(levelOf(-55), 0);
    expect(levelOf(-30), closeTo(0.5, 0.001));
    expect(levelOf(0), 1);
  });
}
