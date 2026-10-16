// Copyright (c) 2025-2026 Kelvin Lee. Licensed under MIT.
//
// Tests for ServerStt — the self-hosted STT client used for the accurate FINAL
// transcript, with the on-device zipformer as the fallback.
//
// The properties worth pinning are the wire contract (raw little-endian int16
// PCM body, bearer header, /transcribe path) and the null-on-error contract:
// transcribe() runs on the capture path, so it must return null — never throw —
// on every failure, and never touch the network when no server is configured.
// Secure storage is mocked in-memory via the plugin's own test seam; http via
// package:http/testing's MockClient.

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:kelvinlee/wearable/local_llm/server_stt.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
  });

  tearDown(() {
    ServerStt.instance.clientForTest = http.Client();
  });

  Int16List pcm(int n) {
    final s = Int16List(n);
    for (var i = 0; i < n; i++) {
      s[i] = (i % 100) - 50;
    }
    return s;
  }

  test('posts raw PCM with bearer header to /transcribe and returns text',
      () async {
    // Trailing slash on the URL must be normalised away.
    await ServerSttConfig.save(
        url: 'https://stt.example.io/', token: 'secret-key');
    http.Request? captured;
    ServerStt.instance.clientForTest = MockClient((req) async {
      captured = req;
      return http.Response(jsonEncode({'text': 'hello world', 'ms': 42}), 200);
    });

    final samples = pcm(8000); // 0.5 s @ 16 kHz
    final out = await ServerStt.instance.transcribe(samples);

    expect(out, 'hello world');
    expect(captured, isNotNull);
    expect(captured!.method, 'POST');
    expect(captured!.url.toString(), 'https://stt.example.io/transcribe');
    expect(captured!.headers['authorization'], 'Bearer secret-key');
    expect(captured!.headers['content-type'], contains('application/octet-stream'));
    // Raw PCM: exactly 2 bytes/sample, no WAV framing.
    expect(captured!.bodyBytes.length, samples.lengthInBytes);
    expect(captured!.bodyBytes.length, 16000);
    expect(String.fromCharCodes(captured!.bodyBytes.take(4)), isNot('RIFF'));
  });

  test('little-endian byte order matches the server dtype <i2', () async {
    await ServerSttConfig.save(url: 'https://x.io', token: 't');
    http.Request? captured;
    ServerStt.instance.clientForTest = MockClient((req) async {
      captured = req;
      return http.Response(jsonEncode({'text': 'x'}), 200);
    });
    final samples = Int16List.fromList([0x0102, -2]); // 258, -2
    await ServerStt.instance.transcribe(samples);
    // 258 = 0x0102 → LE bytes 0x02,0x01 ; -2 = 0xFFFE → LE bytes 0xFE,0xFF.
    expect(captured!.bodyBytes, [0x02, 0x01, 0xFE, 0xFF]);
  });

  test('returns null (fallback) on non-200', () async {
    await ServerSttConfig.save(url: 'https://stt.example.io', token: 'bad');
    ServerStt.instance.clientForTest =
        MockClient((req) async => http.Response('unauthorized', 401));
    expect(await ServerStt.instance.transcribe(pcm(8000)), isNull);
  });

  test('returns null (fallback) when the client throws', () async {
    await ServerSttConfig.save(url: 'https://stt.example.io', token: 'k');
    ServerStt.instance.clientForTest =
        MockClient((req) async => throw Exception('network down'));
    expect(await ServerStt.instance.transcribe(pcm(8000)), isNull);
  });

  test('returns null on unparseable body', () async {
    await ServerSttConfig.save(url: 'https://x.io', token: 't');
    ServerStt.instance.clientForTest =
        MockClient((req) async => http.Response('not json', 200));
    expect(await ServerStt.instance.transcribe(pcm(8000)), isNull);
  });

  test('makes no request and returns null when not configured', () async {
    var called = false;
    ServerStt.instance.clientForTest = MockClient((req) async {
      called = true;
      return http.Response('{}', 200);
    });
    expect(await ServerStt.instance.transcribe(pcm(8000)), isNull);
    expect(called, isFalse, reason: 'must not hit the network when disabled');
  });

  test('transcribeUtterance returns server text without invoking zipformer',
      () async {
    await ServerSttConfig.save(url: 'https://x.io', token: 't');
    ServerStt.instance.clientForTest = MockClient(
        (req) async => http.Response(jsonEncode({'text': 'from server'}), 200));
    // Server returns non-empty text, so the on-device (native) zipformer is
    // never reached — the shared server-first path resolves entirely here.
    expect(await transcribeUtterance(pcm(20000)), 'from server');
  });

  test('enabled tracks a configured URL; empty URL clears it', () async {
    expect(await ServerSttConfig.enabled(), isFalse);
    await ServerSttConfig.save(url: 'https://x.io', token: 't');
    expect(await ServerSttConfig.enabled(), isTrue);
    expect(await ServerSttConfig.url(), 'https://x.io');
    expect(await ServerSttConfig.token(), 't');
    await ServerSttConfig.save(url: '   ', token: '');
    expect(await ServerSttConfig.enabled(), isFalse);
    expect(await ServerSttConfig.url(), isNull);
  });
}
