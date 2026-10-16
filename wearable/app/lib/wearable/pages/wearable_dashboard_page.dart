// Copyright (c) 2025-2026 Kelvin Lee. Licensed under MIT.
//
// WearableDashboardPage — in-app WebView that loads the Wearable dashboard SPA.
// Per design spec v1.0 §Screen 7c (drawer target).
//
// Handles self-signed TLS on LAN via onWebResourceError fallback (Android
// NDK accepts the bad cert when we already accepted it in WearableClient via
// badCertificateCallback). The user is the same operator who's already
// paired the device — trusting the cert is consistent with the rest of
// the Wearable client stack.

import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../wearable_client.dart';
import '../wearable_theme.dart';

class WearableDashboardPage extends StatefulWidget {
  const WearableDashboardPage({super.key});

  @override
  State<WearableDashboardPage> createState() => _WearableDashboardPageState();
}

class _WearableDashboardPageState extends State<WearableDashboardPage> {
  WebViewController? _controller;
  String? _error;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    final creds = await WearableClient.instance.loadCredentials();
    if (!mounted) return;
    if (creds == null) {
      setState(() {
        _loading = false;
        _error = 'Wearable is not paired yet — pair the device first to load the dashboard.';
      });
      return;
    }
    final c = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(WearableColors.background)
      ..setNavigationDelegate(NavigationDelegate(
        onPageStarted: (_) => setState(() => _loading = true),
        onPageFinished: (_) => setState(() => _loading = false),
        onWebResourceError: (err) {
          setState(() {
            _loading = false;
            _error = '${err.errorType ?? ''} — ${err.description}';
          });
        },
      ))
      ..loadRequest(
        Uri.parse(creds.baseUrl),
        headers: {'Authorization': 'Bearer ${creds.bearer}'},
      );
    setState(() => _controller = c);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: WearableColors.background,
      appBar: AppBar(
        title: const Text('Dashboard'),
        backgroundColor: WearableColors.background,
        actions: [
          IconButton(
            onPressed: () => _controller?.reload(),
            icon: const Icon(Icons.refresh_outlined),
          ),
        ],
      ),
      body: Stack(
        children: [
          if (_controller != null)
            WebViewWidget(controller: _controller!),
          if (_loading)
            const LinearProgressIndicator(
              color: WearableColors.primary,
              backgroundColor: WearableColors.cardAlt,
            ),
          if (_error != null && _controller == null)
            _ErrorCard(message: _error!),
        ],
      ),
    );
  }
}

class _ErrorCard extends StatelessWidget {
  const _ErrorCard({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Container(
          padding: const EdgeInsets.all(20),
          decoration: BoxDecoration(
            color: WearableColors.card,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: WearableColors.border),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.cloud_off_outlined, color: WearableColors.destructive, size: 36),
              const SizedBox(height: 12),
              Text(
                message,
                textAlign: TextAlign.center,
                style: const TextStyle(color: WearableColors.foreground, fontSize: 13, height: 1.4),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
