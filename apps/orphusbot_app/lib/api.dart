// Talking to the OrphusBot server: device-link sign-in (D-019), the event
// stream, and the few actions the app takes. The session cookie is kept in the
// app's support folder, readable only by the owner.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:file_selector/file_selector.dart' show XFile;
import 'package:path_provider/path_provider.dart';

const userAgent = 'OrphusBot app';

class SignedOut implements Exception {}

/// The server couldn't be reached at all (this computer offline, the tunnel
/// reconnecting, the server restarting), as opposed to the server saying no.
bool isOffline(Object e) =>
    e is SocketException || e is http.ClientException || e is TimeoutException;

/// An error in words for the owner.
String explain(Object e) => isOffline(e)
    ? "Can't reach the OrphusBot server right now. It reconnects by itself; "
          'check this computer is online.'
    : '$e'.replaceFirst('Exception: ', '');

class Api {
  Api(this.server, this.cookie, [http.Client? client])
    : _http = client ?? http.Client();

  final String server;
  final String cookie;
  final http.Client _http;

  Map<String, String> get headers => {
    'cookie': cookie,
    'user-agent': userAgent,
  };

  static Future<File> _file() async {
    final dir = await getApplicationSupportDirectory();
    await dir.create(recursive: true);
    return File('${dir.path}/session.json');
  }

  /// The saved session, if this device has signed in before.
  static Future<Api?> load() async {
    final f = await _file();
    if (!await f.exists()) return null;
    final v = jsonDecode(await f.readAsString()) as Map<String, dynamic>;
    return Api(v['server'] as String, v['cookie'] as String);
  }

  Future<void> save() async {
    final f = await _file();
    await f.writeAsString(jsonEncode({'server': server, 'cookie': cookie}));
    if (!Platform.isWindows) await Process.run('chmod', ['600', f.path]);
  }

  static Future<void> forget() async {
    final f = await _file();
    if (await f.exists()) await f.delete();
  }

  /// Starts device linking: returns the code to approve and a stream that
  /// completes with a signed-in [Api] once the owner approves it.
  static Future<(String, Future<Api>)> link(String server) async {
    server = server.trim().replaceAll(RegExp(r'/+$'), '');
    final c = http.Client();
    final res = await c.post(
      Uri.parse('$server/auth/link/start'),
      headers: {'content-type': 'application/json', 'user-agent': userAgent},
      body: '{}',
    );
    if (res.statusCode != 200) {
      throw Exception('The server said ${res.statusCode}: ${res.body}');
    }
    final v = jsonDecode(res.body) as Map<String, dynamic>;
    final device = v['device_code'] as String;
    Future<Api> wait() async {
      while (true) {
        await Future<void>.delayed(const Duration(seconds: 2));
        final r = await c.post(
          Uri.parse('$server/auth/link/poll'),
          headers: {
            'content-type': 'application/json',
            'user-agent': userAgent,
          },
          body: jsonEncode({'device_code': device}),
        );
        if (r.statusCode == 202) continue;
        if (r.statusCode == 200) {
          final cookie = (r.headers['set-cookie'] ?? '').split(';').first;
          final api = Api(server, cookie);
          await api.save();
          return api;
        }
        throw Exception('Linking stopped: the code expired or was refused');
      }
    }

    return (v['user_code'] as String, wait());
  }

  Future<http.Response> _check(Future<http.Response> call) async {
    final r = await call;
    if (r.statusCode == 401) throw SignedOut();
    if (r.statusCode >= 400) {
      throw Exception(
        r.body.isEmpty ? 'The server said ${r.statusCode}' : r.body,
      );
    }
    return r;
  }

  Future<dynamic> get(String path) async => jsonDecode(
    (await _check(_http.get(Uri.parse('$server$path'), headers: headers))).body,
  );

  Future<http.Response> _post(String path, Object body) => _check(
    _http.post(
      Uri.parse('$server$path'),
      headers: {...headers, 'content-type': 'application/json'},
      body: jsonEncode(body),
    ),
  );

  Future<void> post(String path, Object body) => _post(path, body);

  /// A POST whose answer matters, such as a code the server made.
  Future<dynamic> postJson(String path, Object body) async =>
      jsonDecode((await _post(path, body)).body);

  Future<void> send(
    String bot,
    String text, {
    List<int> attachments = const [],
    bool room = false,
  }) => post('/api/messages', {
    'bot': bot,
    'text': text,
    'attachments': attachments,
    if (room) 'room': true,
  });

  /// The Ideas Room's ears: a 16 kHz mono WAV, written down by the server.
  Future<String> transcribe(List<int> wav) async {
    final r = await _check(
      _http.post(
        Uri.parse('$server/api/room/transcribe'),
        headers: {...headers, 'content-type': 'audio/wav'},
        body: wav,
      ),
    );
    return (jsonDecode(r.body) as Map<String, dynamic>)['text'] as String? ??
        '';
  }

  /// The Ideas Room's voice: the reply read aloud, as MP3 bytes.
  Future<List<int>> speak(String text) async =>
      (await _post('/api/room/speak', {'text': text})).bodyBytes;

  /// Uploads a file for `bot`; returns its id, to send with the message.
  Future<int> upload(String bot, String name, List<int> bytes) async {
    final uri = Uri.parse('$server/api/attachments')
        .replace(queryParameters: {'bot': bot, 'name': name});
    final r = await _check(
      _http.post(
        uri,
        headers: {...headers, 'content-type': 'application/octet-stream'},
        body: bytes,
      ),
    );
    return (jsonDecode(r.body) as Map<String, dynamic>)['id'] as int;
  }

  /// A file's bytes (an artifact or an attachment), with the session.
  Future<List<int>> download(String url) async =>
      (await _check(_http.get(Uri.parse(url), headers: headers))).bodyBytes;

  String attachmentUrl(int id) => '$server/api/attachments/$id';
  Future<void> stop(String bot) => post('/api/runs/cancel', {'bot': bot});
  Future<void> answer(String id, Map<String, Object> how) =>
      post('/api/dialogs/answer', {'id': id, ...how});

  String artifactUrl(int id) => '$server/api/artifacts/$id';

  /// The Gallery (DESIGN §12.2): newest first, `q` matching a name, a
  /// description or a tag.
  Future<List<Map<String, dynamic>>> gallery([String q = '']) async =>
      (await get('/api/gallery?q=${Uri.encodeQueryComponent(q)}') as List)
          .cast<Map<String, dynamic>>();

  String galleryUrl(int id) => '$server/api/gallery/$id/file';

  /// Streams a picked file into the gallery. On desktops it streams from disk,
  /// so a long video never sits in memory; Android's picker hands over the
  /// bytes with a content address rather than a file, so read it through the
  /// XFile either way.
  Future<Map<String, dynamic>> galleryUpload(XFile file, String name) async {
    final req =
        http.StreamedRequest(
            'POST',
            Uri.parse('$server/api/gallery')
                .replace(queryParameters: {'name': name}),
          )
          ..headers.addAll({
            ...headers,
            'content-type': 'application/octet-stream',
          })
          ..contentLength = await file.length();
    file.openRead().listen(
      req.sink.add,
      onDone: req.sink.close,
      onError: req.sink.addError,
    );
    final res = await http.Response.fromStream(await _http.send(req));
    await _check(Future.value(res));
    return jsonDecode(res.body) as Map<String, dynamic>;
  }

  /// A file a bot shared, kept in the gallery.
  Future<Map<String, dynamic>> galleryFromArtifact(int artifact) async =>
      await postJson('/api/gallery/from-artifact', {'artifact': artifact})
          as Map<String, dynamic>;

  /// The server's events, each `{bot?, type, …}`, from the start; reconnects after a drop.
  Stream<Map<String, dynamic>> events() async* {
    var after = 0;
    while (true) {
      try {
        final req = http.Request(
          'GET',
          Uri.parse('$server/api/events?after=$after'),
        )..headers.addAll(headers);
        final res = await _http.send(req);
        if (res.statusCode == 401) throw SignedOut();
        var pending = '';
        await for (final chunk in res.stream.transform(utf8.decoder)) {
          pending += chunk;
          int end;
          while ((end = pending.indexOf('\n\n')) >= 0) {
            final block = pending.substring(0, end);
            pending = pending.substring(end + 2);
            String? id;
            final data = StringBuffer();
            for (final line in block.split('\n')) {
              if (line.startsWith('id:')) id = line.substring(3).trim();
              if (line.startsWith('data:')) {
                data.write(line.substring(5).trimLeft());
              }
            }
            if (id != null) after = int.tryParse(id) ?? after;
            if (data.isEmpty) continue;
            yield jsonDecode(data.toString()) as Map<String, dynamic>;
          }
        }
      } on SignedOut {
        rethrow;
      } catch (_) {
        // Dropped: wait and pick up from the last event seen.
      }
      await Future<void>.delayed(const Duration(seconds: 3));
    }
  }
}
