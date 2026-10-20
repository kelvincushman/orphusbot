import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:orphusbot_app/api.dart';

void main() {
  test('an unreachable server is told apart from a refusal', () {
    final refused = SocketException('Connection refused');
    expect(isOffline(refused), isTrue);
    expect(isOffline(http.ClientException('Connection closed')), isTrue);
    expect(explain(refused), startsWith("Can't reach the OrphusBot server"));
    expect(isOffline(Exception('That bot is disabled')), isFalse);
    expect(explain(Exception('That bot is disabled')), 'That bot is disabled');
  });
}
