// OrphusBot: the Flutter app for Omarchy/Linux, macOS, Android and iOS
// (DESIGN §12.1, D-033). It signs in by device linking and talks to the
// server's own API; the server holds everything, so the app holds no data.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:rive/rive.dart' show RiveNative;

import 'api.dart';
import 'chat.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await RiveNative.init();
  MediaKit.ensureInitialized();
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
    return MaterialApp(
      title: 'OrphusBot',
      theme: appTheme(Brightness.light),
      darkTheme: appTheme(Brightness.dark),
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

/// The app's look (DESIGN §12.4): monochrome like Grok's app. Pure black or
/// white, grey surfaces, pills and rounded cards, no accent colour; the bots'
/// faces bring the colour.
ThemeData appTheme(Brightness b) {
  final dark = b == Brightness.dark;
  final grey = dark ? const Color(0xFF1C1C1E) : const Color(0xFFF2F2F3);
  final greyHigh = dark ? const Color(0xFF2A2A2D) : const Color(0xFFE7E7E9);
  final scheme =
      ColorScheme.fromSeed(
        seedColor: Colors.grey,
        brightness: b,
        dynamicSchemeVariant: DynamicSchemeVariant.monochrome,
      ).copyWith(
        surface: dark ? Colors.black : Colors.white,
        onSurface: dark ? const Color(0xFFF2F2F2) : const Color(0xFF111111),
        primary: dark ? Colors.white : Colors.black,
        onPrimary: dark ? Colors.black : Colors.white,
        primaryContainer: greyHigh,
        onPrimaryContainer: dark ? Colors.white : Colors.black,
        surfaceContainerLow: grey,
        surfaceContainer: grey,
        surfaceContainerHigh: grey,
        surfaceContainerHighest: greyHigh,
        outline: const Color(0xFF8E8E93),
        outlineVariant: dark
            ? const Color(0xFF2C2C2E)
            : const Color(0xFFE5E5EA),
      );
  const pill = StadiumBorder();
  return ThemeData(
    colorScheme: scheme,
    useMaterial3: true,
    scaffoldBackgroundColor: scheme.surface,
    appBarTheme: AppBarTheme(
      backgroundColor: scheme.surface,
      surfaceTintColor: Colors.transparent,
      centerTitle: true,
      elevation: 0,
    ),
    cardTheme: CardThemeData(
      color: grey,
      elevation: 0,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
    ),
    filledButtonTheme: const FilledButtonThemeData(
      style: ButtonStyle(shape: WidgetStatePropertyAll(pill)),
    ),
    outlinedButtonTheme: const OutlinedButtonThemeData(
      style: ButtonStyle(shape: WidgetStatePropertyAll(pill)),
    ),
    chipTheme: ChipThemeData(
      shape: pill,
      side: BorderSide.none,
      backgroundColor: grey,
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: grey,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(16),
        borderSide: BorderSide.none,
      ),
    ),
    drawerTheme: DrawerThemeData(
      backgroundColor: scheme.surface,
      shape: const RoundedRectangleBorder(),
    ),
    dividerTheme: DividerThemeData(color: scheme.outlineVariant),
    snackBarTheme: const SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      shape: pill,
    ),
  );
}
