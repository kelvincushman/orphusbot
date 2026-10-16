// Talking to the OrphusBot server: device-link sign-in (D-019), the event
// stream, and the few actions the app takes. The session cookie is kept in the
// app's support folder, readable only by the owner.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

const userAgent = 'OrphusBot app';

class SignedOut implements Exception {}

class Api {
  Api(this.server, this.cookie);

  final String server;
  final String cookie;
  final _http = http.Client();

  Map<String, String> get headers => {'cookie': cookie, 'user-agent': userAgent};

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
    final res = await c.post(Uri.parse('$server/auth/link/start'),
        headers: {'content-type': 'application/json', 'user-agent': userAgent}, body: '{}');
    if (res.statusCode != 200) throw Exception('The server said ${res.statusCode}: ${res.body}');
    final v = jsonDecode(res.body) as Map<String, dynamic>;
    final device = v['device_code'] as String;
    Future<Api> wait() async {
      while (true) {
        await Future<void>.delayed(const Duration(seconds: 2));
        final r = await c.post(Uri.parse('$server/auth/link/poll'),
            headers: {'content-type': 'application/json', 'user-agent': userAgent},
            body: jsonEncode({'device_code': device}));
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
    if (r.statusCode >= 400) throw Exception(r.body.isEmpty ? 'The server said ${r.statusCode}' : r.body);
    return r;
  }

  Future<dynamic> get(String path) async =>
      jsonDecode((await _check(_http.get(Uri.parse('$server$path'), headers: headers))).body);

  Future<void> post(String path, Object body) => _check(_http.post(Uri.parse('$server$path'),
      headers: {...headers, 'content-type': 'application/json'}, body: jsonEncode(body)));

  Future<void> send(String bot, String text) => post('/api/messages', {'bot': bot, 'text': text});
  Future<void> stop(String bot) => post('/api/runs/cancel', {'bot': bot});
  Future<void> answer(String id, Map<String, Object> how) => post('/api/dialogs/answer', {'id': id, ...how});

  String artifactUrl(int id) => '$server/api/artifacts/$id';

  /// The server's events, each `{bot?, type, …}`, from the start; reconnects after a drop.
  Stream<Map<String, dynamic>> events() async* {
    var after = 0;
    while (true) {
      try {
        final req = http.Request('GET', Uri.parse('$server/api/events?after=$after'))..headers.addAll(headers);
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
              if (line.startsWith('data:')) data.write(line.substring(5).trimLeft());
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
