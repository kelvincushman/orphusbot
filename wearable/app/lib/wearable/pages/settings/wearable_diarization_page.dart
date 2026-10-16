// Copyright (c) 2025-2026 Kelvin Lee. Licensed under MIT.
//
// WearableDiarizationPage — download / remove the sherpa-onnx speaker-diarization
// models (pyannote segmentation ~6.6 MB + wespeaker embedding ~25.3 MB).
// Infrastructure only — diarization is not yet wired into the live audio
// pipeline; this page provisions the models so the next step can enable it.

import 'package:flutter/material.dart';

import '../../local_llm/diarization_provisioner.dart';
import '../../wearable_theme.dart';

class WearableDiarizationPage extends StatefulWidget {
  const WearableDiarizationPage({super.key});

  @override
  State<WearableDiarizationPage> createState() => _WearableDiarizationPageState();
}

class _WearableDiarizationPageState extends State<WearableDiarizationPage> {
  bool _installed = false;
  bool _busy = false;
  int? _progress; // 0–100 during download
  String? _status;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    final installed = await DiarizationProvisioner.instance.isInstalled();
    if (!mounted) return;
    setState(() => _installed = installed);
  }

  Future<void> _download() async {
    setState(() {
      _busy = true;
      _progress = 0;
      _status = null;
    });
    try {
      await DiarizationProvisioner.instance.download(
        onProgress: (p) {
          if (mounted) setState(() => _progress = p);
        },
      );
      if (!mounted) return;
      setState(() => _status = 'Models installed.');
    } catch (e) {
      if (!mounted) return;
      setState(() => _status = 'Download failed: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
      await _refresh();
    }
  }

  Future<void> _remove() async {
    setState(() => _busy = true);
    try {
      await DiarizationProvisioner.instance.remove();
      if (!mounted) return;
      setState(() => _status = 'Models removed.');
    } catch (e) {
      if (!mounted) return;
      setState(() => _status = 'Remove failed: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
      await _refresh();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: WearableColors.background,
      appBar: AppBar(
        title: const Text('Diarization models'),
        backgroundColor: WearableColors.background,
      ),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          _StatusCard(installed: _installed),
          const SizedBox(height: 12),
          const _InfoCard(
            text:
                'Two ONNX models enable on-device speaker diarization (~32 MB total):\n'
                '• Pyannote segmentation (~6.6 MB)\n'
                '• WeSpeaker ResNet34-LM embedding (~25.3 MB)\n\n'
                'Download requires an internet connection. Models are stored in '
                'application support (durable, never evicted).',
          ),
          const SizedBox(height: 16),
          if (_busy && _progress != null) ...[
            LinearProgressIndicator(
              value: _progress! / 100.0,
              color: WearableColors.primary,
              backgroundColor: WearableColors.cardAlt,
            ),
            const SizedBox(height: 6),
            Text(
              'Downloading… $_progress%',
              style: const TextStyle(color: WearableColors.mutedFg, fontSize: 12),
            ),
            const SizedBox(height: 12),
          ],
          if (!_installed)
            _ActionTile(
              icon: Icons.cloud_download_outlined,
              label: 'Download diarization models (~32 MB)',
              subtitle: 'Pyannote segmentation + WeSpeaker embedding. Use Wi-Fi.',
              onTap: _busy ? null : _download,
            )
          else
            _ActionTile(
              icon: Icons.delete_outline,
              label: 'Remove models',
              subtitle: 'Free ~32 MB of storage.',
              onTap: _busy ? null : _remove,
            ),
          if (_status != null) ...[
            const SizedBox(height: 16),
            Text(
              _status!,
              style: const TextStyle(color: WearableColors.mutedFg, fontSize: 12),
            ),
          ],
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Private widgets — mirror wearable_on_device_model_page.dart patterns exactly.
// ---------------------------------------------------------------------------

class _StatusCard extends StatelessWidget {
  const _StatusCard({required this.installed});
  final bool installed;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: WearableColors.card,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: WearableColors.border),
      ),
      child: Row(
        children: [
          Icon(
            installed
                ? Icons.check_circle_outline
                : Icons.download_for_offline_outlined,
            color: installed ? WearableColors.primary : WearableColors.mutedFg,
            size: 22,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              installed ? 'Installed ✓' : 'Not installed',
              style: const TextStyle(
                color: WearableColors.foreground,
                fontSize: 14,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ActionTile extends StatelessWidget {
  const _ActionTile({
    required this.icon,
    required this.label,
    required this.subtitle,
    required this.onTap,
  });
  final IconData icon;
  final String label;
  final String subtitle;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      borderRadius: BorderRadius.circular(8),
      onTap: onTap,
      child: Opacity(
        opacity: onTap == null ? 0.5 : 1,
        child: Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: WearableColors.card,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: WearableColors.border),
          ),
          child: Row(
            children: [
              Icon(icon, color: WearableColors.primary, size: 20),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      label,
                      style: const TextStyle(
                        color: WearableColors.foreground,
                        fontSize: 14,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      subtitle,
                      style: const TextStyle(
                        color: WearableColors.mutedFg,
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _InfoCard extends StatelessWidget {
  const _InfoCard({required this.text});
  final String text;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: WearableColors.cardAlt,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: WearableColors.border),
      ),
      child: Text(
        text,
        style: const TextStyle(
          color: WearableColors.mutedFg,
          fontSize: 12,
          height: 1.5,
        ),
      ),
    );
  }
}
