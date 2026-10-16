// Copyright (c) 2025-2026 Kelvin Lee. Licensed under MIT.
//
// WearableSessionServerPage — drawer/settings target showing the currently
// bound Wearable server base URL, the devId the wearable registered as, and
// "Pair to a server" / "Forget Server" actions.
//
// A server is OPTIONAL. The app pairs to the wearable over BLE and transcribes
// on-device; a server only pushes transcripts onward and backs the tasks and
// hive views. This page is where that optional connection is made, which is why
// pairing lives here now rather than gating the whole app at launch.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../wearable_client.dart';
import '../pairing_page.dart';
import '../../wearable_theme.dart';

class WearableSessionServerPage extends StatefulWidget {
  const WearableSessionServerPage({super.key});

  @override
  State<WearableSessionServerPage> createState() => _WearableSessionServerPageState();
}

class _WearableSessionServerPageState extends State<WearableSessionServerPage> {
  WearableCredentials? _creds;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  /// Open the pairing page. It used to be the app's launch gate; it is a
  /// setting now, so it comes back here when the credentials land.
  Future<void> _pair() async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => WearablePairingPage(onPaired: () => Navigator.of(context).maybePop()),
      ),
    );
    if (!mounted) return;
    setState(() => _loading = true);
    await _load();
  }

  Future<void> _load() async {
    final c = await WearableClient.instance.loadCredentials();
    if (!mounted) return;
    setState(() {
      _creds = c;
      _loading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: WearableColors.background,
      appBar: AppBar(
        title: const Text('Session Server'),
        backgroundColor: WearableColors.background,
      ),
      body: _loading
          ? const Center(
              child: CircularProgressIndicator(color: WearableColors.primary),
            )
          : ListView(
              padding: const EdgeInsets.all(20),
              children: [
                if (_creds == null) ...[
                  const _NotPairedCard(),
                  const SizedBox(height: 20),
                  FilledButton.icon(
                    icon: const Icon(Icons.link_outlined),
                    label: const Text('Pair to a server'),
                    style: FilledButton.styleFrom(padding: const EdgeInsets.symmetric(vertical: 16)),
                    onPressed: _pair,
                  ),
                ] else ...[
                  _row('Base URL', _creds!.baseUrl),
                  _row('Device ID', _creds!.devId, copyable: true),
                  _row('Pairing token', '${_creds!.pairingToken.substring(0, 8)}…', copyable: false),
                  const SizedBox(height: 24),
                  OutlinedButton.icon(
                    icon: const Icon(Icons.logout_outlined),
                    label: const Text('Forget Server'),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: WearableColors.destructive,
                      side: const BorderSide(color: WearableColors.destructive),
                      padding: const EdgeInsets.symmetric(vertical: 14),
                    ),
                    onPressed: _forget,
                  ),
                ],
              ],
            ),
    );
  }

  Widget _row(String label, String value, {bool copyable = false}) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: const TextStyle(color: WearableColors.mutedFg, fontSize: 12)),
          const SizedBox(height: 6),
          Row(
            children: [
              Expanded(
                child: SelectableText(
                  value,
                  style: const TextStyle(color: WearableColors.foreground, fontSize: 14),
                ),
              ),
              if (copyable)
                IconButton(
                  iconSize: 18,
                  color: WearableColors.mutedFg,
                  onPressed: () {
                    Clipboard.setData(ClipboardData(text: value));
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('Copied')),
                    );
                  },
                  icon: const Icon(Icons.copy_outlined),
                ),
            ],
          ),
        ],
      ),
    );
  }

  Future<void> _forget() async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Forget Wearable server?'),
        content: const Text(
          'This clears the pairing token, devId, and base URL. You will have to re-pair from the Wearable pairing page.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: WearableColors.destructive),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Forget'),
          ),
        ],
      ),
    );
    if (confirm != true) return;
    await WearableClient.instance.forget();
    if (!mounted) return;
    setState(() => _creds = null);
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Wearable server forgotten')),
    );
  }
}

class _NotPairedCard extends StatelessWidget {
  const _NotPairedCard();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: WearableColors.card,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: WearableColors.border),
      ),
      child: const Column(
        children: [
          Icon(Icons.link_off_outlined, color: WearableColors.mutedFg, size: 36),
          SizedBox(height: 12),
          Text(
            'Not paired to a Wearable server yet.',
            style: TextStyle(color: WearableColors.foreground, fontSize: 14, fontWeight: FontWeight.w500),
          ),
          SizedBox(height: 6),
          Text(
            'Optional. The wearable pairs over BLE and transcribes on-device '
            'without one; a server pushes transcripts onward and backs the '
            'tasks and hive views.',
            textAlign: TextAlign.center,
            style: TextStyle(color: WearableColors.mutedFg, fontSize: 12, height: 1.4),
          ),
        ],
      ),
    );
  }
}
