// OrphusBot: the Flutter app for Omarchy/Linux, macOS, Android and iOS
// (DESIGN §12.1, D-033). It signs in by device linking and talks to the
// server's own API; the server holds everything, so the app holds no data.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:rive/rive.dart' show RiveNative;

import 'api.dart';
import 'chat.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await RiveNative.init();
  runApp(const OrphusBotApp());
}

class OrphusBotApp extends StatefulWidget {
  const OrphusBotApp({super.key});
  @override
  State<OrphusBotApp> createState() => _OrphusBotAppState();
}

class _OrphusBotAppState extends State<OrphusBotApp> {
  Api? api;
  bool loading = true;

  @override
  void initState() {
    super.initState();
    Api.load().then(
      (a) => setState(() {
        api = a;
        loading = false;
      }),
    );
  }

  Future<void> signedOut() async {
    await Api.forget();
    setState(() => api = null);
  }

  @override
  Widget build(BuildContext context) {
    ThemeData theme(Brightness b) => ThemeData(
      colorScheme: ColorScheme.fromSeed(
        seedColor: const Color(0xFF2F6BFF),
        brightness: b,
      ),
      useMaterial3: true,
    );
    return MaterialApp(
      title: 'OrphusBot',
      theme: theme(Brightness.light),
      darkTheme: theme(Brightness.dark),
      home: loading
          ? const Scaffold(body: Center(child: CircularProgressIndicator()))
          : api == null
          ? SignIn(onSignedIn: (a) => setState(() => api = a))
          : ChatScreen(api: api!, onSignedOut: signedOut),
    );
  }
}

/// First run: the server's address, then a code to approve from a signed-in device.
class SignIn extends StatefulWidget {
  const SignIn({super.key, required this.onSignedIn});
  final void Function(Api) onSignedIn;
  @override
  State<SignIn> createState() => _SignInState();
}

class _SignInState extends State<SignIn> {
  // On a phone the server is reached at its domain; on a laptop through the tunnel.
  final server = TextEditingController(
    text: Platform.isAndroid || Platform.isIOS
        ? 'https://bots.kelvinlee.io'
        : 'http://localhost:7480',
  );
  String? code;
  String? error;

  Future<void> start() async {
    setState(() => error = null);
    try {
      final (userCode, approved) = await Api.link(server.text);
      setState(() => code = userCode);
      widget.onSignedIn(await approved);
    } catch (e) {
      setState(() {
        error = '$e';
        code = null;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final base = server.text.trim().replaceAll(RegExp(r'/+$'), '');
    return Scaffold(
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 440),
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  'OrphusBot',
                  style: Theme.of(context).textTheme.headlineMedium,
                ),
                const SizedBox(height: 16),
                if (code == null) ...[
                  TextField(
                    controller: server,
                    decoration: const InputDecoration(
                      labelText: "Your server's address",
                    ),
                  ),
                  const SizedBox(height: 12),
                  FilledButton(
                    onPressed: start,
                    child: const Text('Sign in with another device'),
                  ),
                ] else ...[
                  const Text("On a device where you're signed in, open"),
                  SelectableText(
                    '$base/?link=$code',
                    style: const TextStyle(fontFamily: 'monospace'),
                  ),
                  const SizedBox(height: 8),
                  const Text('or go to Settings → Link a device and enter'),
                  SelectableText(
                    code!,
                    style: Theme.of(context).textTheme.headlineSmall,
                  ),
                  const SizedBox(height: 12),
                  const LinearProgressIndicator(),
                ],
                if (error != null) ...[
                  const SizedBox(height: 12),
                  Text(
                    error!,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
