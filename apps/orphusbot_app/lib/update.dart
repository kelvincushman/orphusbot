// Keeps every copy of the app on the same build (DESIGN §12.3). Each build is
// stamped with its git commit; the server publishes the newest one at
// /app/latest.json, and an older copy says so. Android updates itself from the
// server's /app/orphusbot.apk; other platforms are rebuilt by their scripts.
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:url_launcher/url_launcher.dart';

import 'api.dart';

/// This build's commit, from `--dart-define=ORPHUSBOT_BUILD=…`; empty for a
/// development build, which never nags.
const appBuild = String.fromEnvironment('ORPHUSBOT_BUILD');

/// Whether a published build should replace this one.
bool outOfDate(String mine, Map<String, dynamic>? latest) {
  final newest = latest?['build'] as String?;
  return mine.isNotEmpty &&
      newest != null &&
      newest.isNotEmpty &&
      newest != mine;
}

/// A banner when the server has published a newer build of the app.
class UpdateBanner extends StatefulWidget {
  final Api api;
  const UpdateBanner({super.key, required this.api});

  @override
  State<UpdateBanner> createState() => _UpdateBannerState();
}

class _UpdateBannerState extends State<UpdateBanner> {
  Map<String, dynamic>? latest;
  bool hidden = false;

  @override
  void initState() {
    super.initState();
    _check();
  }

  Future<void> _check() async {
    if (appBuild.isEmpty) return;
    try {
      final r = await http
          .get(Uri.parse('${widget.api.server}/app/latest.json'))
          .timeout(const Duration(seconds: 10));
      if (r.statusCode != 200 || !mounted) return;
      setState(() => latest = jsonDecode(r.body) as Map<String, dynamic>);
    } catch (_) {
      // ponytail: no published build or offline; checked again next start.
    }
  }

  @override
  Widget build(BuildContext context) {
    if (hidden || !outOfDate(appBuild, latest)) return const SizedBox.shrink();
    final apk = Platform.isAndroid && latest?['android'] != null;
    return MaterialBanner(
      leading: const Icon(Icons.system_update),
      content: Text(
        apk
            ? 'A newer version of the app is ready (${latest!['build']}).'
            : 'A newer version of the app is ready (${latest!['build']}). '
                  'Run its update script on this computer.',
      ),
      actions: [
        TextButton(
          onPressed: () => setState(() => hidden = true),
          child: const Text('Later'),
        ),
        if (apk)
          FilledButton(
            onPressed: () => launchUrl(
              Uri.parse('${widget.api.server}/app/${latest!['android']}'),
              mode: LaunchMode.externalApplication,
            ),
            child: const Text('Update'),
          ),
      ],
    );
  }
}
