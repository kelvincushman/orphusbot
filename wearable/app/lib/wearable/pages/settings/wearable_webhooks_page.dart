// Copyright (c) 2025-2026 Kelvin Lee. Licensed under MIT.
//
// WearableWebhooksPage — settings sub-page for registering HTTP webhooks that
// Wearable should POST to on agent events (audio.final, agent.result, etc.).
// Per design spec v1.0 §Screen 10 (Integrations group, "Custom Webhooks").
//
// This is the visual shell. The real GET/POST/DELETE /api/webhooks
// endpoints are on Wearable's backlog — once they land, replace the local
// in-memory list with a WearableClient-backed state provider.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../wearable_theme.dart';

class WearableWebhooksPage extends StatefulWidget {
  const WearableWebhooksPage({super.key});

  @override
  State<WearableWebhooksPage> createState() => _WearableWebhooksPageState();
}

class _WearableWebhooksPageState extends State<WearableWebhooksPage> {
  final List<String> _webhooks = [];
  final _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _add() {
    final url = _controller.text.trim();
    if (url.isEmpty) return;
    if (!url.startsWith('http://') && !url.startsWith('https://')) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('URL must start with http:// or https://')),
      );
      return;
    }
    setState(() {
      _webhooks.add(url);
      _controller.clear();
    });
  }

  void _remove(int i) {
    setState(() => _webhooks.removeAt(i));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: WearableColors.background,
      appBar: AppBar(
        title: const Text('Custom Webhooks'),
        backgroundColor: WearableColors.background,
      ),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          const Text(
            'URLs below receive a POST with every final agent response.',
            style: TextStyle(color: WearableColors.mutedFg, fontSize: 12, height: 1.4),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _controller,
            keyboardType: TextInputType.url,
            inputFormatters: [FilteringTextInputFormatter.deny(RegExp(r'\s'))],
            style: const TextStyle(color: WearableColors.foreground, fontSize: 14),
            decoration: InputDecoration(
              hintText: 'https://example.com/wearable-webhook',
              hintStyle: const TextStyle(color: WearableColors.mutedFg),
              filled: true,
              fillColor: WearableColors.cardAlt,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(8),
                borderSide: const BorderSide(color: WearableColors.border),
              ),
              suffixIcon: IconButton(
                icon: const Icon(Icons.add_outlined, color: WearableColors.primary),
                onPressed: _add,
              ),
            ),
            onSubmitted: (_) => _add(),
          ),
          const SizedBox(height: 20),
          if (_webhooks.isEmpty)
            const _EmptyState()
          else
            ..._webhooks.asMap().entries.map(
              (e) => _WebhookTile(url: e.value, onDelete: () => _remove(e.key)),
            ),
          const SizedBox(height: 24),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: WearableColors.cardAlt,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: WearableColors.border),
            ),
            child: const Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(Icons.info_outline, color: WearableColors.mutedFg, size: 16),
                SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Local-only preview: entries reset on app relaunch. Server-side persistence + HMAC signing lands when /api/webhooks is implemented.',
                    style: TextStyle(color: WearableColors.mutedFg, fontSize: 11, height: 1.4),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 40),
      child: Column(
        children: [
          Icon(Icons.webhook_outlined, color: WearableColors.mutedFg.withValues(alpha: 0.5), size: 40),
          const SizedBox(height: 12),
          const Text(
            'No webhooks yet',
            style: TextStyle(color: WearableColors.mutedFg, fontSize: 13),
          ),
        ],
      ),
    );
  }
}

class _WebhookTile extends StatelessWidget {
  const _WebhookTile({required this.url, required this.onDelete});

  final String url;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: WearableColors.card,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: WearableColors.border),
      ),
      child: Row(
        children: [
          const Icon(Icons.link_outlined, color: WearableColors.mutedFg, size: 16),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              url,
              style: const TextStyle(
                color: WearableColors.foreground,
                fontSize: 13,
                fontFamily: 'monospace',
              ),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          IconButton(
            iconSize: 18,
            color: WearableColors.destructive,
            icon: const Icon(Icons.close_outlined),
            onPressed: onDelete,
          ),
        ],
      ),
    );
  }
}
