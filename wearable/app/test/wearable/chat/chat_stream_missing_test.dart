import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:kelvinlee/wearable/providers/wearable_chat_provider.dart';

void main() {
  test('a server with no chat stream is told apart from an outage', () {
    expect(chatStreamMissing(Exception('chatStream failed (404)')), isTrue);
    expect(chatStreamMissing(Exception('chatStream failed (405)')), isTrue);
    expect(chatStreamMissing(Exception('chatStream failed (502)')), isFalse);
    expect(
      chatStreamMissing(Exception('chatStream auth rejected (401)')),
      isFalse,
    );
    expect(chatStreamMissing(const SocketException('down')), isFalse);
  });
}
