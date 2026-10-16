// Copyright (c) 2025-2026 Kelvin Lee. Licensed under MIT.
//
// WearablePairingPage — one-time onboarding flow:
//
//   1. Scan for `_wearable._tcp.local` advertisers (mDNS). List any found.
//   2. Operator picks an instance, OR falls back to manual URL entry.
//   3. Operator pastes the dashboard bearer (write-auth).
//   4. App calls POST /api/device/register → gets a one-time pairing token.
//   5. Credentials saved to FlutterSecureStorage; app is now "paired".
//
// This page is Wearable-theme-aware via wearable_theme.dart. Until main.dart swaps
// the MaterialApp theme to WearableTheme.light(), it will render in the upstream
// KelvinLee theme's colours — functional but not yet branded.

import 'dart:math';

import 'package:flutter/material.dart';

import '../wearable_client.dart';
import '../wearable_theme.dart';
import '../services/wearable_subscription_service.dart';

class WearablePairingPage extends StatefulWidget {
  const WearablePairingPage({super.key, this.onPaired});

  /// Called when pairing succeeds — the host app typically pops this page
  /// or transitions to the home screen.
  final VoidCallback? onPaired;

  @override
  State<WearablePairingPage> createState() => _WearablePairingPageState();
}

class _WearablePairingPageState extends State<WearablePairingPage> {
  final _client = WearableClient.instance;
  final _bearerController = TextEditingController();
  final _manualUrlController = TextEditingController();
  final _labelController = TextEditingController(text: 'My wearable');

  bool _scanning = false;
  bool _pairing = false;
  String? _status;
  List<WearableDiscovery> _found = const [];
  WearableDiscovery? _selected;

  @override
  void initState() {
    super.initState();
    _scan();
  }

  @override
  void dispose() {
    _bearerController.dispose();
    _manualUrlController.dispose();
    _labelController.dispose();
    super.dispose();
  }

  Future<void> _scan() async {
    setState(() { _scanning = true; _status = 'Scanning LAN…'; });
    final list = await _client.discover(timeout: const Duration(seconds: 4));
    if (!mounted) return;
    setState(() {
      _found = list;
      _scanning = false;
      _status = list.isEmpty
        ? 'No Wearable found on the LAN. Enter the URL manually below.'
        : 'Found ${list.length} Wearable instance(s).';
      if (_selected == null && list.isNotEmpty) _selected = list.first;
    });
  }

  Future<void> _pair() async {
    final baseUrl = _selected?.baseUrl ?? _manualUrlController.text.trim();
    final bearer = _bearerController.text.trim();
    final label = _labelController.text.trim().isEmpty ? null : _labelController.text.trim();
    if (baseUrl.isEmpty) {
      setState(() => _status = 'Pick a Wearable instance or enter a URL.');
      return;
    }
    if (bearer.isEmpty) {
      setState(() => _status = 'Paste your Wearable dashboard bearer token.');
      return;
    }
    setState(() { _pairing = true; _status = 'Registering device…'; });
    final devId = 'kelvinlee-${_randomSlug()}';
    try {
      final r = await _client.registerDevice(
        baseUrl: baseUrl,
        bearer: bearer,
        devId: devId,
        label: label,
      );
      final token = r['pairingToken'] as String?;
      if (token == null || token.isEmpty) {
        throw Exception('server did not return a pairingToken');
      }
      await _client.saveCredentials(WearableCredentials(
        baseUrl: baseUrl,
        bearer: bearer,
        devId: devId,
        pairingToken: token,
      ));
      // Tie the RevenueCat app user to the Wearable devId. Best-effort — a
      // failure here doesn't block the pair flow; the user can still
      // subscribe later against an anonymous RC user and then log in.
      if (WearableSubscriptionService.instance.isConfigured) {
        try {
          await WearableSubscriptionService.instance.identifyUser(devId);
        } catch (_) { /* swallowed */ }
      }
      if (!mounted) return;
      setState(() { _pairing = false; _status = 'Paired — device id: $devId'; });
      widget.onPaired?.call();
    } catch (e) {
      if (!mounted) return;
      setState(() { _pairing = false; _status = 'Pairing failed: $e'; });
    }
  }

  String _randomSlug() {
    const chars = 'abcdefghijklmnopqrstuvwxyz0123456789';
    final r = Random.secure();
    return List.generate(6, (_) => chars[r.nextInt(chars.length)]).join();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Pair to Wearable'),
        actions: [
          IconButton(
            tooltip: 'Rescan',
            icon: const Icon(Icons.refresh),
            onPressed: _scanning ? null : _scan,
          ),
        ],
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(20),
          children: [
            Text('Discovery', style: Theme.of(context).textTheme.labelSmall),
            const SizedBox(height: 8),
            if (_scanning)
              const LinearProgressIndicator(),
            ..._found.map((d) => Card(
              color: d == _selected
                  ? WearableColors.primary.withValues(alpha: 0.08)
                  : WearableColors.card,
              child: ListTile(
                leading: Icon(
                  d == _selected ? Icons.radio_button_checked : Icons.radio_button_off,
                  color: d == _selected ? WearableColors.primary : WearableColors.mutedFg,
                ),
                title: Text('${d.address}:${d.port}'),
                subtitle: Text('${d.host} · ${d.tls ? 'TLS' : 'HTTP'} · ${d.version}'),
                onTap: () => setState(() => _selected = d),
              ),
            )),
            const SizedBox(height: 24),
            Text('Or enter URL manually', style: Theme.of(context).textTheme.labelSmall),
            const SizedBox(height: 8),
            TextField(
              controller: _manualUrlController,
              decoration: const InputDecoration(hintText: 'https://wearable-server.local:3141'),
              keyboardType: TextInputType.url,
            ),
            const SizedBox(height: 24),
            Text('Dashboard bearer token', style: Theme.of(context).textTheme.labelSmall),
            const SizedBox(height: 8),
            TextField(
              controller: _bearerController,
              decoration: const InputDecoration(hintText: 'from WEARABLE_DASHBOARD_TOKEN'),
              obscureText: true,
            ),
            const SizedBox(height: 16),
            Text('Device label (optional)', style: Theme.of(context).textTheme.labelSmall),
            const SizedBox(height: 8),
            TextField(
              controller: _labelController,
              decoration: const InputDecoration(hintText: 'e.g. bedroom, office'),
            ),
            const SizedBox(height: 24),
            ElevatedButton.icon(
              onPressed: _pairing ? null : _pair,
              icon: _pairing
                  ? const SizedBox(
                      height: 16, width: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.link),
              label: Text(_pairing ? 'Pairing…' : 'Pair device'),
            ),
            if (_status != null) ...[
              const SizedBox(height: 20),
              Text(_status!, style: Theme.of(context).textTheme.bodySmall),
            ],
          ],
        ),
      ),
    );
  }
}
