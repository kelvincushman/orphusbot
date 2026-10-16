// Copyright (c) 2025-2026 Kelvin Lee. Licensed under MIT.
//
// WearableClient — HTTP + WebSocket client for Wearable's device channel.
//
// Responsibilities:
//   - mDNS discovery of `_wearable._tcp.local` on the LAN (multicast_dns package)
//   - One-time pairing: operator pastes the Wearable dashboard bearer + device
//     pairing token returned by /api/device/register
//   - Persists (baseUrl, bearer, devId, pairingToken) in flutter_secure_storage
//   - Typed methods for the four device-facing HTTP endpoints plus an audio
//     WebSocket stream factory
//
// Designed to coexist with the upstream KelvinLee HTTP stack — does NOT replace
// `lib/backend/http/shared.dart`. When Kelvin hits "Pair to Wearable" in the app,
// WearableClient takes over device-channel traffic while the rest of the app
// keeps talking to Firebase/KelvinLee until Phase 3 strips it.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';
import 'package:multicast_dns/multicast_dns.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import 'chat/attachment_limits.dart';
import 'models/wearable_chat_event.dart';
import 'models/wearable_chat_thread.dart';
import 'models/wearable_mission_control.dart';
import 'models/wearable_schedule.dart';
import 'models/wearable_task.dart';

// Dev-time: Wearable's dashboard commonly uses a self-signed cert on LAN (see
// .env.example TLS section — "Generate: ./scripts/gen-self-signed-cert.sh").
// Accept self-signed so pairing works without manually installing a CA on
// the phone — but ONLY in debug/profile builds. Release builds enforce
// standard cert validation; if the operator runs a self-signed cert in
// production they must install the CA on the device. Without this gate,
// any MITM on the LAN could present any TLS cert and harvest the bearer
// token from request headers (CRIT finding from M-2 security review).
HttpClient _buildHttpClient() {
  final client = HttpClient();
  if (kDebugMode || kProfileMode) {
    client.badCertificateCallback = (cert, host, port) => true;
  }
  return client;
}

/// Thrown by [WearableClient.sendChatMessageWithAttachments] when the server
/// rejects the multipart request (not yet supported) or returns an error.
/// Callers should catch this and fall back to text-only send.
class ChatAttachmentServerException implements Exception {
  final String message;
  const ChatAttachmentServerException(this.message);
  @override
  String toString() => 'ChatAttachmentServerException: $message';
}

/// Default mDNS service type — matches `src/mdns.ts`.
const String _kWearableServiceType = '_wearable._tcp.local';

class _WearableStorageKeys {
  static const baseUrl = 'wearable.baseUrl';
  static const bearer = 'wearable.bearer';
  static const devId = 'wearable.devId';
  static const pairingToken = 'wearable.pairingToken';
}

/// Pairing credentials persisted across app launches.
class WearableCredentials {
  final String baseUrl;
  final String bearer;
  final String devId;
  final String pairingToken;

  const WearableCredentials({required this.baseUrl, required this.bearer, required this.devId, required this.pairingToken});
}

/// Result of an mDNS lookup.
class WearableDiscovery {
  final String host;
  final String address;
  final int port;
  final bool tls;
  final String version;
  const WearableDiscovery({
    required this.host,
    required this.address,
    required this.port,
    required this.tls,
    required this.version,
  });

  String get baseUrl => '${tls ? 'https' : 'http'}://$address:$port';
}

/// Longest speaker label the device channel carries. Mirrors the server-side
/// validation on `/api/device/text` so an over-long registry name truncates
/// here instead of 400-ing the whole transcript push.
const int kMaxTalkerLength = 64;

/// Body for `POST /api/device/text`.
///
/// Lifted out of [WearableClient.sendDeviceText] because it is the wire
/// contract and the only part of that method testable without a socket.
///
/// [talker] is a separate field, never fused into [text]. The bridge used to
/// push `'$talker: $text'`, which meant a speaker renamed on the phone could
/// never propagate — the label was already baked into the server's copy. The
/// key is omitted entirely when there is no label, so a transcript with no
/// speaker is byte-identical to what this sent before the field existed.
Map<String, dynamic> buildDeviceTextBody({
  required String text,
  required bool overheard,
  required int at,
  String? talker,
}) {
  final label = talker?.trim() ?? '';
  return <String, dynamic>{
    'text': text,
    'overheard': overheard,
    'at': at,
    if (label.isNotEmpty)
      'talker': label.length > kMaxTalkerLength ? label.substring(0, kMaxTalkerLength) : label,
  };
}

/// Narrow chat surface consumed by [WearableChatProvider]. Keeping this boundary
/// separate from the concrete credentialled client makes reconnect and
/// missed-SSE recovery deterministic in tests.
abstract interface class WearableChatApi {
  Future<WearableChatSendReceipt> sendChatMessageStreaming({
    required String message,
    required String chatId,
    String? businessId,
    List<String>? attachmentIds,
  });

  Future<List<WearableChatThread>> listThreads({int limit = 50});

  Future<List<WearableChatHistoryMessage>> getThreadMessages(String chatId, {int? before, int limit = 200});

  Future<WearableTaskDetail> getTaskDetail(String taskId);

  Future<void> replyToTask(String taskId, String answer);

  Stream<WearableChatFrame> chatStream(String chatId, {int? sinceId});
}

class WearableClient implements WearableChatApi {
  WearableClient._(this._storage);

  final FlutterSecureStorage _storage;
  final http.Client _http = IOClient(_buildHttpClient());
  WearableCredentials? _cached;

  // Active audio-WS arbitration — only one stream per device at a time. When
  // both the BLE bridge and phone mic want the mic, the most-recent requester
  // wins and the other gets a null back. Fixes FW-C3 silent-takeover race.
  WebSocketChannel? _activeAudioChannel;
  String? _activeAudioOwner;

  static WearableClient? _instance;
  static WearableClient get instance {
    _instance ??= WearableClient._(_buildStorage());
    return _instance!;
  }

  /// Platform-hardened secure storage — iOS uses `first_unlock_this_device`
  /// accessibility so the keychain entry is wiped on device migration, and
  /// Android uses EncryptedSharedPreferences with a fresh app-reinstall key
  /// path. Fixes FW-H7 credential-reuse-across-reinstall risk.
  static FlutterSecureStorage _buildStorage() {
    return const FlutterSecureStorage(
      iOptions: IOSOptions(accessibility: KeychainAccessibility.first_unlock_this_device),
      aOptions: AndroidOptions(encryptedSharedPreferences: true, resetOnError: true),
    );
  }

  // -----------------------------------------------------------------------
  // Credential storage
  // -----------------------------------------------------------------------

  Future<bool> isPaired() async => (await loadCredentials()) != null;

  Future<WearableCredentials?> loadCredentials() async {
    if (_cached != null) return _cached;
    final b = await _storage.read(key: _WearableStorageKeys.baseUrl);
    final h = await _storage.read(key: _WearableStorageKeys.bearer);
    final d = await _storage.read(key: _WearableStorageKeys.devId);
    final p = await _storage.read(key: _WearableStorageKeys.pairingToken);
    if (b == null || h == null || d == null || p == null) return null;
    _cached = WearableCredentials(baseUrl: b, bearer: h, devId: d, pairingToken: p);
    return _cached;
  }

  Future<void> saveCredentials(WearableCredentials creds) async {
    await _storage.write(key: _WearableStorageKeys.baseUrl, value: creds.baseUrl);
    await _storage.write(key: _WearableStorageKeys.bearer, value: creds.bearer);
    await _storage.write(key: _WearableStorageKeys.devId, value: creds.devId);
    await _storage.write(key: _WearableStorageKeys.pairingToken, value: creds.pairingToken);
    _cached = creds;
  }

  Future<void> forget() async {
    await _storage.delete(key: _WearableStorageKeys.baseUrl);
    await _storage.delete(key: _WearableStorageKeys.bearer);
    await _storage.delete(key: _WearableStorageKeys.devId);
    await _storage.delete(key: _WearableStorageKeys.pairingToken);
    _cached = null;
    // Wipe the boardroom chatId too — otherwise a re-pair on a shared
    // device picks up the prior user's session id and immediately
    // subscribes to their conversation history (still in the server's
    // ring buffer). chatId is not auth, but cross-user reuse is a
    // privacy violation. Mirrors the secure-storage clear above.
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove('wearable.chatId');
    } catch (_) {
      // Best effort — if prefs is unavailable, the chat provider will
      // mint a fresh id on next ensureChatId() either way.
    }
  }

  // -----------------------------------------------------------------------
  // mDNS discovery
  // -----------------------------------------------------------------------

  /// Scan the LAN for `_wearable._tcp.local` advertisers. Timeout-bounded.
  /// Returns all instances found within [timeout]. Empty list on any error
  /// — the UI falls back to manual URL entry.
  Future<List<WearableDiscovery>> discover({Duration timeout = const Duration(seconds: 4)}) async {
    // The default MDnsClient binds its socket with reusePort: true, which
    // Android and Linux do not support — the VM logs "Dart Socket ERROR:
    // reusePort not supported on this platform" and the bind fails. Discovery
    // has therefore never worked on Android, and the catch below turned that
    // into a silent empty list: the pairing page said "No Wearable found on the
    // LAN", which reads as "the server is off" rather than "this never ran".
    // The socket factory is the package's own documented Android workaround.
    final mdns = MDnsClient(rawDatagramSocketFactory: (
      dynamic host,
      int port, {
      bool? reuseAddress,
      bool? reusePort,
      int? ttl,
    }) =>
        RawDatagramSocket.bind(host, port,
            reuseAddress: reuseAddress ?? true, reusePort: false, ttl: ttl ?? 255));
    try {
      await mdns.start();
    } catch (e) {
      debugPrint('[WearableClient] mDNS start failed: $e');
      return const [];
    }

    final discovered = <String, WearableDiscovery>{};
    final deadline = DateTime.now().add(timeout);

    try {
      await for (final ptr in mdns.lookup<PtrResourceRecord>(ResourceRecordQuery.serverPointer(_kWearableServiceType))) {
        if (DateTime.now().isAfter(deadline)) break;
        final srvName = ptr.domainName;

        String? host;
        int? port;
        await for (final srv in mdns.lookup<SrvResourceRecord>(ResourceRecordQuery.service(srvName))) {
          host = srv.target;
          port = srv.port;
          break;
        }
        if (host == null || port == null) continue;

        String? address;
        await for (final a in mdns.lookup<IPAddressResourceRecord>(ResourceRecordQuery.addressIPv4(host))) {
          address = a.address.address;
          break;
        }
        if (address == null) continue;

        bool tls = false;
        String version = 'unknown';
        await for (final txt in mdns.lookup<TxtResourceRecord>(ResourceRecordQuery.text(srvName))) {
          for (final entry in txt.text.split('\n')) {
            final idx = entry.indexOf('=');
            if (idx <= 0) continue;
            final k = entry.substring(0, idx);
            final v = entry.substring(idx + 1);
            if (k == 'version') version = v;
            if (k == 'tls') tls = v == '1';
          }
          break;
        }

        discovered[srvName] = WearableDiscovery(host: host, address: address, port: port, tls: tls, version: version);
      }
    } catch (_) {
      // Partial results are fine.
    } finally {
      mdns.stop();
    }
    return discovered.values.toList();
  }

  // -----------------------------------------------------------------------
  // HTTP device endpoints
  // -----------------------------------------------------------------------

  /// Operator-only: register a new device and receive the one-time pairing
  /// token. Requires the dashboard bearer. Returns the full response JSON
  /// including `pairingToken` (shown to the user once, then saved).
  Future<Map<String, dynamic>> registerDevice({
    required String baseUrl,
    required String bearer,
    required String devId,
    String? label,
    String businessId = 'default',
  }) async {
    final r = await _http.post(
      Uri.parse('$baseUrl/api/device/register'),
      headers: {'Authorization': 'Bearer $bearer', 'Content-Type': 'application/json'},
      body: jsonEncode({'devId': devId, if (label != null) 'label': label, 'businessId': businessId}),
    );
    if (r.statusCode >= 400) {
      // Status-only — register sends the dashboard bearer in headers; a
      // misbehaving proxy that echoed the request body could include
      // bizarre payloads, but the bearer itself is not in the body. The
      // wider concern is consistency with the rest of WearableClient: every
      // other endpoint omits r.body from exception strings.
      throw Exception('register failed (${r.statusCode})');
    }
    return jsonDecode(r.body) as Map<String, dynamic>;
  }

  Future<Map<String, dynamic>> sendEvent({
    required String kind, // "button" | "heartbeat"
    String? code, // "AGENT_REQUEST" | "SINGLE" | "DOUBLE" | "LONG"
    int? at,
  }) async {
    final c = await _requireCreds();
    final body = <String, dynamic>{'kind': kind};
    if (code != null) body['code'] = code;
    if (at != null) body['at'] = at;
    final r = await _http.post(
      Uri.parse('${c.baseUrl}/api/device/event'),
      headers: _deviceHeaders(c),
      body: jsonEncode(body),
    );
    if (r.statusCode >= 400) {
      // Status-only error string — never echo r.body, which a misbehaving
      // proxy could populate with the request's pairing token from the
      // device headers.
      throw Exception('event failed (${r.statusCode})');
    }
    return jsonDecode(r.body) as Map<String, dynamic>;
  }

  /// POST /api/device/text — push a transcript that was produced ON-DEVICE
  /// (Gemma 4 on the phone) instead of streaming raw audio to the server for
  /// cloud STT. The server strips any `@role:` prefix (S-3) and dispatches the
  /// turn on the device channel. Returns the `chatId` the agent's reply will
  /// stream on (subscribe via [chatStream]).
  Future<String> sendDeviceText({
    required String text,
    bool overheard = false,
    int? at,
    String? talker,
  }) async {
    final c = await _requireCreds();
    final body = buildDeviceTextBody(
      text: text,
      overheard: overheard,
      at: at ?? DateTime.now().millisecondsSinceEpoch,
      talker: talker,
    );
    final r = await _http.post(
      Uri.parse('${c.baseUrl}/api/device/text'),
      headers: _deviceHeaders(c),
      body: jsonEncode(body),
    );
    if (r.statusCode >= 400) {
      // Status-only — never echo r.body (it may carry the pairing token from
      // the device headers if a proxy misbehaves). Matches sendEvent.
      throw Exception('device text failed (${r.statusCode})');
    }
    final decoded = jsonDecode(r.body) as Map<String, dynamic>;
    return (decoded['chatId'] as String?) ?? 'device:${c.devId}';
  }

  /// Convenience: trigger an AGENT_REQUEST on the paired wearable. Same
  /// payload the firmware sends on a single button press. The server
  /// arms its overheard-detector window and forwards the next final
  /// transcript to `intake()` as a normal user turn. Used by M-2.2 mic
  /// button on the Boardroom Ask-Wearable bar.
  Future<void> requestAgentCapture() async {
    await sendEvent(kind: 'button', code: 'AGENT_REQUEST');
  }

  // -----------------------------------------------------------------------
  // Speech-profile (KelvinLee-compat — S-4 server endpoints, M-5 client wiring)
  // -----------------------------------------------------------------------

  /// GET /api/v3/speech-profile — returns whether this device has an enrolled
  /// owner voice profile. Matches the shape of KelvinLee cloud's v3/speech-profile
  /// so the existing speech_profile_provider can consume it unchanged.
  Future<bool> hasSpeechProfile() async {
    final c = await _requireCreds();
    final r = await _http.get(Uri.parse('${c.baseUrl}/api/v3/speech-profile'), headers: _deviceHeaders(c));
    if (r.statusCode >= 400) {
      throw Exception('hasSpeechProfile failed (${r.statusCode})');
    }
    final body = jsonDecode(r.body) as Map<String, dynamic>;
    return body['has_profile'] == true;
  }

  /// POST /api/v3/upload-audio — multipart WAV upload. Returns true on 200.
  /// The server persists the sample under voice-samples/<devId>/<ulid>.wav
  /// and creates the owner profile on first call.
  Future<bool> uploadSpeechProfile(File wav) async {
    final c = await _requireCreds();
    final req = http.MultipartRequest('POST', Uri.parse('${c.baseUrl}/api/v3/upload-audio'));
    req.headers['X-Device-Id'] = c.devId;
    req.headers['X-Device-Token'] = c.pairingToken;
    req.files.add(await http.MultipartFile.fromPath('file', wav.path));
    final streamed = await _http.send(req);
    // Drain the body even on success — necessary to release the underlying
    // socket — but do NOT include it in the thrown error. A rogue LAN proxy
    // could otherwise plant attacker-controlled text (or echoed bearer
    // headers) into the exception message via Exception.toString.
    await streamed.stream.bytesToString();
    if (streamed.statusCode >= 400) {
      throw Exception('uploadSpeechProfile failed (${streamed.statusCode})');
    }
    return true;
  }

  /// GET /api/v4/speech-profile — returns a relative URL the caller can GET
  /// through this server (with device auth) to download the latest sample.
  /// `null` means no sample exists yet. Never a raw filesystem path.
  ///
  /// The server response is a path like `/api/device/voice-sample/latest`.
  /// We validate it is origin-relative and does NOT smuggle a scheme or
  /// protocol-relative (`//host`) form before concatenating with baseUrl —
  /// a compromised or rogue Wearable instance otherwise could redirect the
  /// next authenticated download request to an attacker-controlled host.
  Future<String?> speechProfileDownloadUrl() async {
    final c = await _requireCreds();
    final r = await _http.get(Uri.parse('${c.baseUrl}/api/v4/speech-profile'), headers: _deviceHeaders(c));
    if (r.statusCode >= 400) return null;
    final body = jsonDecode(r.body) as Map<String, dynamic>;
    final rel = body['url'];
    if (rel is! String || rel.isEmpty) return null;
    // Must be single-slash origin-relative: starts with `/` and the next
    // character is NOT `/` (rejects `//evil.com/path`). Also reject any
    // explicit scheme (`http://`, `javascript:`, etc.) via the colon check.
    if (!rel.startsWith('/') || rel.startsWith('//') || rel.contains(':')) {
      return null;
    }
    final resolved = Uri.parse(c.baseUrl).resolve(rel);
    // Final belt-and-braces check: host must match the paired baseUrl.
    if (resolved.host != Uri.parse(c.baseUrl).host) return null;
    return resolved.toString();
  }

  // -----------------------------------------------------------------------
  // Hands-free mode toggle (S-4)
  // -----------------------------------------------------------------------

  /// GET /api/device/hands-free — returns the current per-device flag and
  /// whether the server is allowing hands-free globally.
  Future<({bool enabled, bool allowed})> handsFreeStatus() async {
    final c = await _requireCreds();
    final r = await _http.get(Uri.parse('${c.baseUrl}/api/device/hands-free'), headers: _deviceHeaders(c));
    if (r.statusCode >= 400) {
      throw Exception('handsFreeStatus failed (${r.statusCode})');
    }
    final body = jsonDecode(r.body) as Map<String, dynamic>;
    return (enabled: body['handsFreeMode'] == true, allowed: body['allowed'] == true);
  }

  /// POST /api/device/hands-free — flip the per-device hands-free flag.
  /// Server rejects with 409 if no owner voice profile exists, and with 403
  /// if the operator has disabled hands-free globally.
  Future<void> setHandsFreeMode(bool enabled) async {
    final c = await _requireCreds();
    final r = await _http.post(
      Uri.parse('${c.baseUrl}/api/device/hands-free'),
      headers: _deviceHeaders(c),
      body: jsonEncode({'enabled': enabled}),
    );
    if (r.statusCode >= 400) {
      throw Exception('setHandsFreeMode failed (${r.statusCode})');
    }
  }

  // -----------------------------------------------------------------------
  // Task ledger (M-3 — consumes S-2 endpoints shipped in commit 70a0b71)
  // -----------------------------------------------------------------------

  /// Server-side task IDs are minted as UUID v4 by the dispatcher (Phase β
  /// commit 1f0c089) — older artifacts may still be ULIDs. Either format
  /// is accepted; anything else is treated as a forged/malformed value
  /// and rejected before it lands in URL interpolation. The same
  /// defense-in-depth lives server-side in
  /// `src/harness/inngest/delegation-parser.ts` (`isValidTaskId`).
  static final RegExp _kUlidRe = RegExp(r'^[0-7][0-9A-HJKMNP-TV-Zahjkmnp-tv-z]{25}$');
  static final RegExp _kUuidRe = RegExp(
    r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$',
  );

  static void _assertTaskId(String taskId) {
    if (!_kUlidRe.hasMatch(taskId) && !_kUuidRe.hasMatch(taskId)) {
      throw ArgumentError('invalid taskId format');
    }
  }

  /// GET /api/tasks?status=…&limit=… — list recent tasks, optionally
  /// filtered by derived status. Sorted by mtime desc on the server.
  ///
  /// Error messages deliberately exclude the raw response body so the
  /// bearer token (which some misbehaving proxies/debug middlewares echo
  /// back) cannot leak through Exception.toString into logs/crash reports.
  Future<List<WearableTaskSummary>> listTasks({WearableTaskStatus? status, int limit = 50}) async {
    final c = await _requireCreds();
    final qp = <String, String>{'limit': limit.toString()};
    if (status != null && status != WearableTaskStatus.unknown) {
      qp['status'] = status.wire;
    }
    final uri = Uri.parse('${c.baseUrl}/api/tasks').replace(queryParameters: qp);
    final r = await _http.get(uri, headers: _bearerHeaders(c));
    if (r.statusCode >= 400) {
      throw Exception('listTasks failed (${r.statusCode})');
    }
    final body = jsonDecode(r.body) as Map<String, dynamic>;
    final raw = (body['tasks'] as List?) ?? const [];
    return raw
        .cast<Map<dynamic, dynamic>>()
        .map((e) => WearableTaskSummary.fromJson(e.cast<String, dynamic>()))
        .toList(growable: false);
  }

  /// GET /api/tasks/:taskId/detail — contract + full RESPONSE.md + pending
  /// input + children. Used by TaskDetailPage.
  @override
  Future<WearableTaskDetail> getTaskDetail(String taskId) async {
    _assertTaskId(taskId);
    final c = await _requireCreds();
    final r = await _http.get(Uri.parse('${c.baseUrl}/api/tasks/$taskId/detail'), headers: _bearerHeaders(c));
    if (r.statusCode >= 400) {
      throw Exception('getTaskDetail failed (${r.statusCode})');
    }
    return WearableTaskDetail.fromJson(jsonDecode(r.body) as Map<String, dynamic>);
  }

  /// POST /api/tasks/:taskId/reply — user answers a pending_input question.
  /// Server requires WEARABLE_DASHBOARD_TOKEN bearer for this write endpoint.
  @override
  Future<void> replyToTask(String taskId, String answer) async {
    _assertTaskId(taskId);
    final c = await _requireCreds();
    final r = await _http.post(
      Uri.parse('${c.baseUrl}/api/tasks/$taskId/reply'),
      headers: _bearerHeaders(c, json: true),
      body: jsonEncode({'answer': answer}),
    );
    if (r.statusCode >= 400) {
      throw Exception('replyToTask failed (${r.statusCode})');
    }
  }

  /// POST /api/tasks/:taskId/cancel — advisory cancel. Server flips the
  /// derived status to `failed` with reason=user_cancelled (default) so the
  /// app can render "cancelled by you". Bearer required.
  Future<void> cancelTask(String taskId, {String? reason}) async {
    _assertTaskId(taskId);
    final c = await _requireCreds();
    final r = await _http.post(
      Uri.parse('${c.baseUrl}/api/tasks/$taskId/cancel'),
      headers: _bearerHeaders(c, json: true),
      body: jsonEncode({if (reason != null && reason.isNotEmpty) 'reason': reason}),
    );
    if (r.statusCode >= 400) {
      throw Exception('cancelTask failed (${r.statusCode})');
    }
  }

  // -----------------------------------------------------------------------
  // Mission Control — front-page asynchronous-PM aggregator. Drives the
  // in-app Mission Control page. Bearer auth, status-only error strings.
  // -----------------------------------------------------------------------

  /// GET /api/mission-control — full aggregate (budget, active task rows,
  /// per-role agent stats, recent course corrections). Optional [businessId]
  /// filters active rows + budget rollup; omit for the default tenant.
  Future<WearableMissionControl> getMissionControl({String? businessId}) async {
    final c = await _requireCreds();
    final qp = <String, String>{};
    if (businessId != null && businessId.isNotEmpty) {
      qp['businessId'] = businessId;
    }
    final uri = Uri.parse('${c.baseUrl}/api/mission-control').replace(queryParameters: qp.isEmpty ? null : qp);
    final r = await _http.get(uri, headers: _bearerHeaders(c));
    if (r.statusCode >= 400) {
      throw Exception('getMissionControl failed (${r.statusCode})');
    }
    return WearableMissionControl.fromJson(jsonDecode(r.body) as Map<String, dynamic>);
  }

  /// GET /api/mission-control/tasks/:taskId — drill-in: per-task row plus
  /// handoffs and the last 50 trace events.
  Future<WearableMissionControlTaskDetail> getMissionControlTask(String taskId) async {
    _assertTaskId(taskId);
    final c = await _requireCreds();
    final r = await _http.get(Uri.parse('${c.baseUrl}/api/mission-control/tasks/$taskId'), headers: _bearerHeaders(c));
    if (r.statusCode >= 400) {
      throw Exception('getMissionControlTask failed (${r.statusCode})');
    }
    return WearableMissionControlTaskDetail.fromJson(jsonDecode(r.body) as Map<String, dynamic>);
  }

  /// GET /api/mission-control/active — lightweight per-role "what's running
  /// now" snapshot. ~1 KB, suitable for a 5 s poll.
  Future<WearableMissionActive> getMissionControlActive() async {
    final c = await _requireCreds();
    final r = await _http.get(Uri.parse('${c.baseUrl}/api/mission-control/active'), headers: _bearerHeaders(c));
    if (r.statusCode >= 400) {
      throw Exception('getMissionControlActive failed (${r.statusCode})');
    }
    return WearableMissionActive.fromJson(jsonDecode(r.body) as Map<String, dynamic>);
  }

  // -----------------------------------------------------------------------
  // Schedules (M-4 — consumes S-3 endpoints shipped in commit 70a0b71)
  // -----------------------------------------------------------------------

  static void _assertScheduleId(int id) {
    if (id <= 0) throw ArgumentError('invalid schedule id');
  }

  Future<List<WearableSchedule>> listSchedules() async {
    final c = await _requireCreds();
    final r = await _http.get(Uri.parse('${c.baseUrl}/api/schedules'), headers: _bearerHeaders(c));
    if (r.statusCode >= 400) throw Exception('listSchedules failed (${r.statusCode})');
    final body = jsonDecode(r.body) as Map<String, dynamic>;
    final raw = (body['schedules'] as List?) ?? const [];
    return raw
        .cast<Map<dynamic, dynamic>>()
        .map((e) => WearableSchedule.fromJson(e.cast<String, dynamic>()))
        .toList(growable: false);
  }

  Future<WearableSchedule> createSchedule({
    required String name,
    required String cron,
    required String message,
    required String chatId,
    required String channel,
  }) async {
    final c = await _requireCreds();
    final r = await _http.post(
      Uri.parse('${c.baseUrl}/api/schedules'),
      headers: _bearerHeaders(c, json: true),
      body: jsonEncode({'name': name, 'cron': cron, 'message': message, 'chatId': chatId, 'channel': channel}),
    );
    if (r.statusCode >= 400) throw Exception('createSchedule failed (${r.statusCode})');
    final body = jsonDecode(r.body) as Map<String, dynamic>;
    return WearableSchedule.fromJson((body['schedule'] as Map).cast<String, dynamic>());
  }

  /// PATCH /api/schedules/:id — any subset of name/cron/message/enabled.
  Future<WearableSchedule> updateSchedule(int id, {String? name, String? cron, String? message, bool? enabled}) async {
    _assertScheduleId(id);
    final c = await _requireCreds();
    final body = <String, dynamic>{
      if (name != null) 'name': name,
      if (cron != null) 'cron': cron,
      if (message != null) 'message': message,
      if (enabled != null) 'enabled': enabled,
    };
    if (body.isEmpty) {
      throw ArgumentError('updateSchedule: at least one field required');
    }
    final r = await _http.patch(
      Uri.parse('${c.baseUrl}/api/schedules/$id'),
      headers: _bearerHeaders(c, json: true),
      body: jsonEncode(body),
    );
    if (r.statusCode >= 400) throw Exception('updateSchedule failed (${r.statusCode})');
    final decoded = jsonDecode(r.body) as Map<String, dynamic>;
    return WearableSchedule.fromJson((decoded['schedule'] as Map).cast<String, dynamic>());
  }

  Future<void> deleteSchedule(int id) async {
    _assertScheduleId(id);
    final c = await _requireCreds();
    final r = await _http.delete(Uri.parse('${c.baseUrl}/api/schedules/$id'), headers: _bearerHeaders(c));
    if (r.statusCode >= 400) throw Exception('deleteSchedule failed (${r.statusCode})');
  }

  /// POST /api/schedules/:id/run-now — force immediate dispatch, independent
  /// of the cron cadence. Rejects with 409 when the schedule is disabled.
  Future<void> runScheduleNow(int id) async {
    _assertScheduleId(id);
    final c = await _requireCreds();
    final r = await _http.post(
      Uri.parse('${c.baseUrl}/api/schedules/$id/run-now'),
      headers: _bearerHeaders(c, json: true),
      body: '{}',
    );
    if (r.statusCode >= 400) throw Exception('runScheduleNow failed (${r.statusCode})');
  }

  // -----------------------------------------------------------------------
  // Chat (M-2) — fire-and-forget POST + SSE event stream
  // -----------------------------------------------------------------------

  /// `web:` is the prefix the server's chatId regex enforces for browser /
  /// mobile chat sessions. We mint a stable per-install id so the Karpathy
  /// memory layer threads correctly across app launches. Caller persists the
  /// id and passes it back on every send + every stream subscribe.
  static final RegExp _kChatIdRe = RegExp(r'^[0-9a-zA-Z_:.-]{1,64}$');

  static void _assertChatId(String chatId) {
    if (!_kChatIdRe.hasMatch(chatId)) {
      throw ArgumentError('invalid chatId format');
    }
  }

  /// POST /api/chat?stream=1 — fire-and-forget. Returns the chatId the server
  /// echoed back (which may differ if we passed an empty/invalid hint and the
  /// server minted a fresh one). The actual reply arrives via [chatStream]
  /// as `assistant_message` and possibly `delegation_started` / `child_done`
  /// events. The 202 response carries no LLM text.
  ///
  /// [attachmentIds] is an optional list of upload IDs returned by a prior
  /// call to the two-step `/api/chat/uploads` endpoint. When provided, the
  /// server resolves the IDs, injects file content into the agent prompt, and
  /// streams the reply on the existing SSE channel.
  @override
  Future<WearableChatSendReceipt> sendChatMessageStreaming({
    required String message,
    required String chatId,
    String? businessId,
    List<String>? attachmentIds,
  }) async {
    _assertChatId(chatId);
    final c = await _requireCreds();
    final body = {
      'message': message,
      'chatId': chatId,
      if (businessId != null && businessId.isNotEmpty) 'businessId': businessId,
      if (attachmentIds != null && attachmentIds.isNotEmpty) 'attachments': attachmentIds,
    };
    final r = await _http.post(
      Uri.parse('${c.baseUrl}/api/chat?stream=1'),
      headers: _bearerHeaders(c, json: true),
      body: jsonEncode(body),
    );
    // 202 = queued; 200 not expected in stream mode but tolerate it.
    if (r.statusCode != 202 && r.statusCode != 200) {
      // Status-only error string — never echo r.body, which a misbehaving
      // proxy could populate with the bearer token from the request.
      throw Exception('sendChatMessage failed (${r.statusCode})');
    }
    // Server echoes chatId back (ours or one it minted). Defend against the
    // server returning a chatId for a different shape than what we sent.
    final decoded = jsonDecode(r.body) as Map<String, dynamic>;
    final receipt = WearableChatSendReceipt.fromJson(decoded, fallbackChatId: chatId);
    if (!_kChatIdRe.hasMatch(receipt.chatId)) {
      throw Exception('server returned malformed chatId');
    }
    if (receipt.taskId != null) _assertTaskId(receipt.taskId!);
    return receipt;
  }

  /// Two-step attachment flow:
  ///
  /// Step 1 — POST /api/chat/uploads?chatId=<chatId> as multipart/form-data
  ///           with each file under the field name `files`. Requires bearer
  ///           auth (endpoint is behind `requireWriteAuth`). Returns JSON
  ///           `{ "uploads": [{ "id": "<uuid>", "name": ..., ... }] }`.
  ///
  /// Step 2 — POST /api/chat?stream=1 as JSON with `attachments: [<id>, ...]`
  ///           alongside `message` and `chatId` — the same endpoint the
  ///           text-only path uses, so the SSE reply arrives on the existing
  ///           subscription with no extra wiring.
  ///
  /// Throws [ChatAttachmentServerException] on upload failure (non-2xx, no
  /// ids, or network error) so the caller can show a user-friendly error and
  /// optionally fall back to text-only send.
  Future<WearableChatSendReceipt> sendChatMessageWithAttachments({
    required String message,
    required String chatId,
    String? businessId,
    required List<File> files,
  }) async {
    _assertChatId(chatId);
    if (files.isEmpty) {
      throw const ChatAttachmentServerException('Select at least one attachment');
    }
    if (files.length > kWearableMaxAttachments) {
      throw const ChatAttachmentServerException('A maximum of 8 attachments can be sent at once');
    }
    for (final file in files) {
      int bytes;
      try {
        bytes = await file.length();
      } catch (_) {
        throw ChatAttachmentServerException("Couldn't read ${file.uri.pathSegments.last}");
      }
      final error = wearableAttachmentSizeError(name: file.uri.pathSegments.last, bytes: bytes);
      if (error != null) throw ChatAttachmentServerException(error);
    }
    final c = await _requireCreds();

    // ── Step 1: upload files ─────────────────────────────────────────────────
    final uploadUri = Uri.parse('${c.baseUrl}/api/chat/uploads').replace(queryParameters: {'chatId': chatId});

    final req = http.MultipartRequest('POST', uploadUri);
    // Add only the Authorization header — multipart sets its own Content-Type.
    req.headers['Authorization'] = 'Bearer ${c.bearer}';
    for (final f in files) {
      req.files.add(await http.MultipartFile.fromPath('files', f.path));
    }

    final streamed = await _http.send(req);
    final uploadBody = await streamed.stream.bytesToString();

    if (streamed.statusCode < 200 || streamed.statusCode >= 300) {
      throw ChatAttachmentServerException('Upload failed (${streamed.statusCode})');
    }

    final uploadDecoded = jsonDecode(uploadBody) as Map<String, dynamic>;
    final rawUploads = uploadDecoded['uploads'] as List?;
    if (rawUploads == null || rawUploads.isEmpty) {
      throw const ChatAttachmentServerException('Upload succeeded but server returned no upload IDs');
    }
    final uploadIds = rawUploads.cast<Map<dynamic, dynamic>>().map((u) => u['id'] as String).toList(growable: false);

    // ── Step 2: send message with attachment IDs ─────────────────────────────
    return sendChatMessageStreaming(message: message, chatId: chatId, businessId: businessId, attachmentIds: uploadIds);
  }

  /// GET /api/chat/threads — list recent boardroom threads (M-2.3
  /// side-sheet). Server filters to web-channel threads with at least
  /// one turn, ordered by last activity desc.
  @override
  Future<List<WearableChatThread>> listThreads({int limit = 50}) async {
    final c = await _requireCreds();
    final uri = Uri.parse('${c.baseUrl}/api/chat/threads').replace(queryParameters: {'limit': limit.toString()});
    final r = await _http.get(uri, headers: _bearerHeaders(c));
    if (r.statusCode >= 400) {
      throw Exception('listThreads failed (${r.statusCode})');
    }
    final body = jsonDecode(r.body) as Map<String, dynamic>;
    final raw = (body['threads'] as List?) ?? const [];
    return raw
        .cast<Map<dynamic, dynamic>>()
        .map((e) => WearableChatThread.fromJson(e.cast<String, dynamic>()))
        .toList(growable: false);
  }

  /// GET /api/chat/threads/:chatId/messages — page through one chat's
  /// history. Returns turns in chronological order (oldest first).
  /// `before` is a createdAt cutoff in millis; subsequent pages pass
  /// the oldest createdAt observed.
  @override
  Future<List<WearableChatHistoryMessage>> getThreadMessages(String chatId, {int? before, int limit = 200}) async {
    _assertChatId(chatId);
    final c = await _requireCreds();
    final qp = <String, String>{'limit': limit.toString()};
    if (before != null && before > 0) qp['before'] = before.toString();
    final uri = Uri.parse('${c.baseUrl}/api/chat/threads/$chatId/messages').replace(queryParameters: qp);
    final r = await _http.get(uri, headers: _bearerHeaders(c));
    if (r.statusCode >= 400) {
      throw Exception('getThreadMessages failed (${r.statusCode})');
    }
    final body = jsonDecode(r.body) as Map<String, dynamic>;
    final raw = (body['messages'] as List?) ?? const [];
    return raw
        .cast<Map<dynamic, dynamic>>()
        .map((e) => WearableChatHistoryMessage.fromJson(e.cast<String, dynamic>()))
        .toList(growable: false);
  }

  /// Open the SSE chat-event stream for [chatId]. The returned [Stream]
  /// yields one [WearableChatFrame] per server event, plus heartbeat frames
  /// roughly every 25s so the caller can detect stale connections without
  /// a separate timer. The stream completes (no error) when the server or
  /// network closes the connection — the caller is responsible for
  /// reconnect strategy.
  ///
  /// [sinceId] is optional and lets reconnects resume from the last seen
  /// envelope id; events older than this are filtered server-side.
  ///
  /// Auth: server requires `Authorization: Bearer …` (requireWriteAuth).
  /// 429 is returned when the per-chat subscriber ceiling is hit.
  @override
  Stream<WearableChatFrame> chatStream(String chatId, {int? sinceId}) async* {
    _assertChatId(chatId);
    final c = await _requireCreds();
    final qp = <String, String>{'chatId': chatId};
    if (sinceId != null && sinceId > 0) qp['since'] = sinceId.toString();
    final uri = Uri.parse('${c.baseUrl}/api/chat/stream').replace(queryParameters: qp);

    final req = http.Request('GET', uri);
    req.headers.addAll(_bearerHeaders(c));
    req.headers['Accept'] = 'text/event-stream';
    // Disable buffered redirects — SSE follows must keep credentials.
    req.followRedirects = false;

    final res = await _http.send(req);
    if (res.statusCode == 401) {
      throw Exception('chatStream auth rejected (401)');
    }
    if (res.statusCode == 429) {
      throw Exception('chatStream busy (429)');
    }
    if (res.statusCode >= 400) {
      throw Exception('chatStream failed (${res.statusCode})');
    }

    // Manual SSE parse. Spec § 9.2:
    //   - Lines split by LF, CRLF, or CR.
    //   - Empty line dispatches the accumulated event.
    //   - Lines starting with ":" are comments (used here for keepalives).
    //   - "field:value" lines accumulate into the current event.
    String? curId;
    final dataBuf = StringBuffer();

    await for (final line
        in res.stream
            .transform(utf8.decoder)
            // ignore: prefer_const_constructors  — SDK rejects const here
            .transform(LineSplitter())) {
      if (line.isEmpty) {
        // Dispatch accumulated event.
        if (dataBuf.isNotEmpty) {
          final raw = dataBuf.toString();
          final parsed = WearableChatEvent.tryDecode(raw);
          // Skip unknown event types silently — server may add variants
          // ahead of the client during a staged rollout.
          if (parsed != null) {
            int? id;
            if (curId != null) id = int.tryParse(curId);
            yield WearableChatFrame(id: id, event: parsed);
          }
        }
        curId = null;
        dataBuf.clear();
        continue;
      }
      if (line.startsWith(':')) {
        // Comment — server's `: keepalive` marker. Surface as a heartbeat
        // frame so the provider can reset its stale-connection timer
        // without waiting for a real event.
        yield WearableChatFrame.heartbeat();
        continue;
      }
      // SSE field:value parse.
      final colon = line.indexOf(':');
      if (colon < 0) continue; // malformed line — ignore
      final field = line.substring(0, colon);
      // Per spec, single leading space after the colon is stripped.
      var value = line.substring(colon + 1);
      if (value.startsWith(' ')) value = value.substring(1);
      switch (field) {
        case 'id':
          curId = value;
          break;
        case 'data':
          if (dataBuf.isNotEmpty) dataBuf.write('\n');
          dataBuf.write(value);
          break;
        // SSE 'event' field, 'retry' hint, and unknown fields: ignored.
        // The Dart parser dispatches on the JSON `type` discriminant inside
        // the data payload, so we don't need the SSE event-name routing.
        // The retry hint is overridden by the provider's own backoff.
      }
    }
  }

  /// Poll queued LED/haptic commands. Each element is a raw map from Wearable's
  /// `DeviceCommand` shape; the caller encodes it to the 4-byte GATT packet
  /// using the device-side encoder (see lib/wearable/command_codec.dart).
  Future<List<Map<String, dynamic>>> pollCommands() async {
    final c = await _requireCreds();
    final r = await _http.post(Uri.parse('${c.baseUrl}/api/device/command/poll'), headers: _deviceHeaders(c));
    if (r.statusCode >= 400) {
      // Device-bearer (pairing-token) headers; status-only error.
      throw Exception('poll failed (${r.statusCode})');
    }
    final body = jsonDecode(r.body) as Map<String, dynamic>;
    return (body['commands'] as List).cast<Map<String, dynamic>>();
  }

  // -----------------------------------------------------------------------
  // WebSocket audio
  // -----------------------------------------------------------------------

  /// Open an audio WebSocket. The caller pushes binary frames via `sink.add`.
  /// Closing the sink tears down the STT session server-side.
  ///
  /// [encoding] is `"opus"` (default — matches the firmware) or `"linear16"`
  /// (for phone mic streaming 16-bit PCM). Sample rate must match the source.
  ///
  /// [owner] is an arbitrary tag (`'ble'`, `'phone_mic'`, etc.) identifying
  /// who requested the stream. Only one stream per [WearableClient] is active at
  /// a time — a new request with a different owner supersedes the old one
  /// (older WS is closed with code 4000). Fixes FW-C3 silent-takeover race.
  Future<WebSocketChannel> openAudioStream({
    String encoding = 'opus',
    int sampleRate = 16000,
    int frameMs = 10,
    required String owner,
    void Function(dynamic message)? onMessage,
  }) async {
    final c = await _requireCreds();
    // Arbitrate — close any prior stream first. This is explicit supersede,
    // not silent takeover: the old owner will see `sink.add` error out.
    if (_activeAudioChannel != null) {
      try {
        await _activeAudioChannel!.sink.close(4000, 'superseded by $owner');
      } catch (_) {
        /* ignore */
      }
    }
    final scheme = c.baseUrl.startsWith('https') ? 'wss' : 'ws';
    final hostPort = c.baseUrl.replaceFirst(RegExp(r'^https?://'), '');
    // Pairing token now travels in Sec-WebSocket-Protocol (`wearable-token, <t>`)
    // to keep it out of URL access logs. devId stays in the query since it's
    // not a secret and is useful for server-side audit filtering. Fixes SEC-H1.
    // frameMs tells the server which Opus packetization the firmware is using
    // (10ms for CODEC_ID=20, 20ms for CODEC_ID=21 aka opus_fs320).
    final uri = Uri.parse(
      '$scheme://$hostPort/api/device/ws/audio'
      '?devId=${Uri.encodeQueryComponent(c.devId)}'
      '&encoding=$encoding'
      '&sampleRate=$sampleRate'
      '&frameMs=$frameMs',
    );
    final channel = IOWebSocketChannel.connect(
      uri,
      protocols: ['wearable-token', c.pairingToken],
      customClient: _buildHttpClient(),
    );
    _activeAudioChannel = channel;
    _activeAudioOwner = owner;
    // Clear arbitration bookkeeping when the stream closes so the next
    // opener doesn't try to double-close a dead channel. This is the sole
    // subscriber — WebSocketChannel streams are single-subscription, so we
    // forward each incoming frame to the caller's [onMessage] callback
    // rather than letting them add a second `listen` that would throw.
    channel.stream.listen(
      (msg) {
        onMessage?.call(msg);
      },
      onError: (_) => _clearActiveIf(channel),
      onDone: () => _clearActiveIf(channel),
      cancelOnError: false,
    );
    return channel;
  }

  void _clearActiveIf(WebSocketChannel ch) {
    if (identical(_activeAudioChannel, ch)) {
      _activeAudioChannel = null;
      _activeAudioOwner = null;
    }
  }

  String? get activeAudioOwner => _activeAudioOwner;

  // -----------------------------------------------------------------------
  // Internal helpers
  // -----------------------------------------------------------------------

  Future<WearableCredentials> _requireCreds() async {
    final c = await loadCredentials();
    if (c == null) {
      throw StateError('Not paired to Wearable yet — call saveCredentials() first');
    }
    return c;
  }

  Map<String, String> _deviceHeaders(WearableCredentials c) => {
    'X-Device-Id': c.devId,
    'X-Device-Token': c.pairingToken,
    'Content-Type': 'application/json',
  };

  /// Dashboard-bearer headers for the /api/tasks* + dashboard-gated routes.
  /// Reads (GET /api/tasks, /detail) are open on today's server but we send
  /// the bearer anyway so a future gating change does not require an app
  /// release.
  Map<String, String> _bearerHeaders(WearableCredentials c, {bool json = false}) => {
    'Authorization': 'Bearer ${c.bearer}',
    if (json) 'Content-Type': 'application/json',
  };
}
