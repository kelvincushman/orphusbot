// Copyright (c) 2025-2026 Kelvin Lee. Licensed under MIT.
//
// WearableSafetyRulesPage — read-only view of `config/safety.rules` pulled
// from the Wearable server at `GET /api/safety-rules`. Per design spec §Screen 10
// Wearable Advanced group.
//
// Read-only intentionally: writing rules is an operator-grade action that
// belongs in the dashboard SPA where the full AgentSpec linter runs.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';
import 'dart:io';

import '../../wearable_client.dart';
import '../../wearable_theme.dart';

class WearableSafetyRulesPage extends StatefulWidget {
  const WearableSafetyRulesPage({super.key});

  @override
  State<WearableSafetyRulesPage> createState() => _WearableSafetyRulesPageState();
}

class _WearableSafetyRulesPageState extends State<WearableSafetyRulesPage> {
  String? _rules;
  String? _error;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  http.Client _buildClient() => IOClient(
    HttpClient()..badCertificateCallback = (_, __, ___) => true,
  );

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    final creds = await WearableClient.instance.loadCredentials();
    if (creds == null) {
      setState(() {
        _loading = false;
        _error = 'Not paired — open the Wearable pairing page first.';
      });
      return;
    }
    final client = _buildClient();
    try {
      final r = await client.get(
        Uri.parse('${creds.baseUrl}/api/safety-rules'),
        headers: {'Authorization': 'Bearer ${creds.bearer}'},
      );
      if (!mounted) return;
      if (r.statusCode >= 400) {
        setState(() {
          _loading = false;
          _error = 'HTTP ${r.statusCode}: ${r.body}';
        });
        return;
      }
      setState(() {
        _loading = false;
        _rules = r.body;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = e.toString();
      });
    } finally {
      client.close();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: WearableColors.background,
      appBar: AppBar(
        title: const Text('Safety Rules'),
        backgroundColor: WearableColors.background,
        actions: [
          IconButton(
            onPressed: _load,
            icon: const Icon(Icons.refresh_outlined),
          ),
          if (_rules != null)
            IconButton(
              icon: const Icon(Icons.copy_outlined),
              tooltip: 'Copy to clipboard',
              onPressed: () {
                Clipboard.setData(ClipboardData(text: _rules!));
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Rules copied')),
                );
              },
            ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator(color: WearableColors.primary))
          : _error != null
              ? _ErrorCard(message: _error!)
              : _RulesViewer(text: _rules ?? ''),
    );
  }
}

class _ErrorCard extends StatelessWidget {
  const _ErrorCard({required this.message});
  final String message;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(20),
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: WearableColors.card,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: WearableColors.destructive.withValues(alpha: 0.4)),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Icon(Icons.error_outline, color: WearableColors.destructive, size: 20),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                message,
                style: const TextStyle(color: WearableColors.foreground, fontSize: 13, height: 1.4),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _RulesViewer extends StatelessWidget {
  const _RulesViewer({required this.text});
  final String text;

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(20),
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: WearableColors.card,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: WearableColors.border),
        ),
        child: SelectableText(
          text.isEmpty ? '(safety.rules is empty)' : text,
          style: const TextStyle(
            color: WearableColors.foreground,
            fontSize: 12,
            height: 1.4,
            fontFamily: 'monospace',
          ),
        ),
      ),
    );
  }
}
