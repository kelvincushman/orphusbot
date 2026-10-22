import 'package:flutter_test/flutter_test.dart';
import 'package:orphusbot_app/room.dart';

void main() {
  test('the orb follows the voice: quiet is still, loud is full', () {
    expect(levelOf(-80), 0);
    expect(levelOf(-55), 0);
    expect(levelOf(-30), closeTo(0.5, 0.001));
    expect(levelOf(0), 1);
  });

  test('finished sentences are voiced as they arrive, in chunks', () {
    const text = 'That is a great idea. Who is it for? Tell me more about the';
    final (first, to) = sentencesAfter(text, 0, min: 10);
    expect(first, ['That is a great idea.', 'Who is it for?']);
    // The unfinished sentence waits for more text.
    final (later, _) = sentencesAfter(text, to, min: 10);
    expect(later, isEmpty);
    // Short sentences join until they're long enough.
    final (joined, _) = sentencesAfter(
      'Yes. Good. Now the plan is set. ',
      0,
      min: 20,
    );
    expect(joined, ['Yes. Good. Now the plan is set.']);
  });
}
