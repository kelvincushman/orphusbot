import 'package:flutter_test/flutter_test.dart';
import 'package:orphusbot_app/thread.dart';

void main() {
  test('an idle bot waiting on teammates shows its thinking face', () {
    final view = ThreadView();
    expect(view.mood, 0);
    view.waitingOn = 2;
    expect(view.mood, 1);
  });
}
