// Copyright (c) 2025-2026 Kelvin Lee. Licensed under MIT.
//
// The preview latch feeds TidyGate the streaming text of the clip that just
// closed. It must be readable exactly once: the same offline pass also serves
// the SD backlog and continuous segmentation, which never run the preview, and
// a getter would hand all of them the last button clip's text.
//
// No native recogniser here: stop() with no open stream skips the sherpa
// calls and only latches whatever `partial` holds.
import 'package:flutter_test/flutter_test.dart';
import 'package:kelvinlee/wearable/local_llm/streaming_transcriber.dart';

void main() {
  final t = StreamingTranscriber.instance;

  setUp(() {
    t.partial.value = '';
    t.takeLastPreview(); // drain anything a previous test left behind
  });

  test('stop latches the preview and the first read consumes it', () {
    t.partial.value = 'hello there';
    expect(t.stop(), 'hello there');
    expect(t.takeLastPreview(), 'hello there');
    expect(t.takeLastPreview(), '', reason: 'a second clip must not inherit it');
  });

  test('nothing decoded means nothing latched', () {
    expect(t.stop(), '');
    expect(t.takeLastPreview(), '');
  });
}
