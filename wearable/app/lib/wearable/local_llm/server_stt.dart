// Copyright (c) 2025-2026 Kelvin Lee. Licensed under MIT.
//
// ServerStt — POST a completed utterance to a self-hosted STT server for the
// accurate FINAL transcript, with the on-device zipformer kept as the fallback.
//
// This is self-contained: it talks straight to the user's own STT box over
// ordinary HTTPS (e.g. a Cloudflare-tunnelled Qwen3-ASR endpoint), with no
// nova-pai / Wearable-server dependency. The streaming zipformer still drives
// the instant live preview; this only replaces the saved transcript, and only
// when a server is configured.
//
// It NEVER throws. transcribe() runs on the capture path, so any failure
// (disabled, network, 401, timeout, bad JSON) returns null and the caller falls
// back to the on-device transcript — a note is never lost to a server problem.
//
// Wire format: the server accepts raw 16 kHz mono int16 PCM (little-endian) as
// the request body, or a WAV. We send raw PCM because the app already holds the
// audio as Int16List — its backing bytes are already little-endian int16 on the
// ARM device, so no re-encoding or WAV framing is needed. Response is JSON
// {"text": "...", "ms": <int>}.

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;

import 'capture_diagnostics.dart';
import 'zipformer_transcriber.dart';

/// Base URL + bearer token for the transcription server, in secure storage.
///
/// The token is a secret, so it lives in [FlutterSecureStorage] (same hardened
/// options as the pairing credentials in wearable_client.dart), never in
/// SharedPreferences and never hardcoded in the shipped app. [enabled] is true
/// exactly when a non-empty base URL is stored.
class ServerSttConfig {
  ServerSttConfig._();

  static const String urlKey = 'wearable.serverStt.url';
  static const String tokenKey = 'wearable.serverStt.token';

  static FlutterSecureStorage _storage = _buildStorage();

  static FlutterSecureStorage _buildStorage() => const FlutterSecureStorage(
        iOptions: IOSOptions(
            accessibility: KeychainAccessibility.first_unlock_this_device),
        aOptions:
            AndroidOptions(encryptedSharedPreferences: true, resetOnError: true),
      );

  /// Swap the backing store in tests. Production always uses secure storage.
  @visibleForTesting
  static set storageForTest(FlutterSecureStorage storage) => _storage = storage;

  /// Configured base URL (e.g. `https://stt.example.io`), trimmed, or null.
  static Future<String?> url() async {
    final raw = await _storage.read(key: urlKey);
    final trimmed = raw?.trim();
    return (trimmed == null || trimmed.isEmpty) ? null : trimmed;
  }

  /// Bearer token, or null when none has been saved.
  static Future<String?> token() async => _storage.read(key: tokenKey);

  /// Server STT is on exactly when a base URL is configured.
  static Future<bool> enabled() async => (await url()) != null;

  /// Persist [url] and [token]. An empty value deletes that key, so clearing the
  /// URL field turns server STT off and the app reverts to on-device only.
  static Future<void> save({required String url, required String token}) async {
    final u = url.trim();
    if (u.isEmpty) {
      await _storage.delete(key: urlKey);
    } else {
      await _storage.write(key: urlKey, value: u);
    }
    final t = token.trim();
    if (t.isEmpty) {
      await _storage.delete(key: tokenKey);
    } else {
      await _storage.write(key: tokenKey, value: t);
    }
  }
}

/// Client for `POST <baseUrl>/transcribe`.
class ServerStt {
  ServerStt._();

  static final ServerStt instance = ServerStt._();

  /// How long to wait for the server before giving up and falling back. A
  /// completed utterance is at most ~30 s of audio; the round trip plus GPU
  /// decode is normally well under this.
  static const Duration _timeout = Duration(seconds: 20);

  http.Client _client = http.Client();

  /// Inject a mock client in tests. Not used in production.
  @visibleForTesting
  set clientForTest(http.Client client) => _client = client;

  /// Transcribe one completed utterance ([pcm16], mono int16 at [sampleRate]).
  ///
  /// Returns the server's transcript, or null on ANY error — the caller treats
  /// null as "fall back to the on-device zipformer". Returns null immediately
  /// (no request) when no server is configured. Never throws.
  ///
  /// Logs one `[ServerSTT]` line per call (http status + elapsed ms + char
  /// count) and mirrors it to [CaptureDiagnostics], matching the zipformer's
  /// telemetry so the Transcripts page can tell the two backends apart.
  Future<String?> transcribe(Int16List pcm16, {int sampleRate = 16000}) async {
    final baseUrl = await ServerSttConfig.url();
    if (baseUrl == null) return null; // not configured — silent no-op
    final token = await ServerSttConfig.token() ?? '';
    final endpoint = Uri.parse('${_stripTrailingSlashes(baseUrl)}/transcribe');

    final sw = Stopwatch()..start();
    try {
      // Int16List's backing bytes are already little-endian int16 on-device,
      // which is exactly the raw PCM body the server decodes with np.frombuffer
      // dtype='<i2'. Slice by byte offset/length so a sublist view sends only
      // its own samples.
      final body = pcm16.buffer
          .asUint8List(pcm16.offsetInBytes, pcm16.lengthInBytes);
      final resp = await _client
          .post(
            endpoint,
            headers: {
              'Authorization': 'Bearer $token',
              'Content-Type': 'application/octet-stream',
            },
            body: body,
          )
          .timeout(_timeout);
      sw.stop();

      if (resp.statusCode != 200) {
        _log(resp.statusCode, sw.elapsedMilliseconds, 0, note: 'non-200');
        return null;
      }
      final decoded = jsonDecode(resp.body);
      final text =
          (decoded is Map && decoded['text'] is String) ? decoded['text'] as String : '';
      _log(resp.statusCode, sw.elapsedMilliseconds, text.length);
      return text;
    } catch (e) {
      sw.stop();
      _log(0, sw.elapsedMilliseconds, 0, note: '$e');
      return null;
    }
  }

  static String _stripTrailingSlashes(String url) {
    var u = url;
    while (u.endsWith('/')) {
      u = u.substring(0, u.length - 1);
    }
    return u;
  }

  void _log(int status, int ms, int chars, {String? note}) {
    final suffix = note == null ? '' : ' ($note)';
    debugPrint('[ServerSTT] $status ${ms}ms chars=$chars$suffix');
    CaptureDiagnostics.instance
        .event('Server STT $status ${ms}ms chars=$chars$suffix');
  }
}

/// Server-first transcription with on-device fallback for one completed
/// utterance, shared by the wearable bridge and the phone-mic capture path.
///
/// Tries the configured server for the accurate FINAL transcript; on ANY miss
/// (not configured, network/401/timeout, or an empty result) the on-device
/// zipformer runs instead, so a note is never lost. Callers MUST apply their own
/// speech/energy gate first — this forwards [samples] to the server as given.
Future<String> transcribeUtterance(Int16List samples, {int sampleRate = 16000}) async {
  if (await ServerSttConfig.enabled()) {
    final srv = await ServerStt.instance.transcribe(samples, sampleRate: sampleRate);
    if (srv != null && srv.trim().isNotEmpty) return srv;
  }
  return ZipformerTranscriber.instance.transcribe(samples, sampleRate: sampleRate);
}
