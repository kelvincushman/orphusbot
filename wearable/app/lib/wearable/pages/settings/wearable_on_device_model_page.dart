// Copyright (c) 2025-2026 Kelvin Lee. Licensed under MIT.
//
// WearableOnDeviceModelPage — download / remove the on-device SPEECH model
// used for local speech-to-text (lib/wearable/local_llm/).
//
// That model is zipformer-small-en (int8 transducer, Apache-2.0) plus the
// Silero v5 VAD that gates it. Sizes come from ZipformerProvisioner so this
// page and the voice page can never disagree; see
// docs/research/ASR_CANDIDATES.md for why it beat Moonshine on our channel.

import 'package:flutter/material.dart';

import '../../local_llm/model_provisioner.dart';
import '../../local_llm/punctuation_provisioner.dart';
import '../../local_llm/server_stt.dart';
import '../../local_llm/tidy_runner.dart';
import '../../local_llm/streaming_provisioner.dart';
import '../../local_llm/zipformer_provisioner.dart';
import '../../local_llm/transcription_mode.dart';
import '../../wearable_theme.dart';

class WearableOnDeviceModelPage extends StatefulWidget {
  const WearableOnDeviceModelPage({super.key});

  @override
  State<WearableOnDeviceModelPage> createState() => _WearableOnDeviceModelPageState();
}

class _WearableOnDeviceModelPageState extends State<WearableOnDeviceModelPage> {
  bool _installed = false;
  bool _liveInstalled = false;
  bool _punctInstalled = false;
  bool _polishInstalled = false;
  bool _autoTidy = TidySettings.defaultEnabled;
  bool _platformOk = false;
  bool _busy = false;
  int? _progress; // 0–100 during download
  String? _status;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    final platformOk = await platformSupportsOnDevice();
    final installed = await ZipformerProvisioner.instance.isInstalled();
    final live = await StreamingProvisioner.instance.isInstalled();
    final punct = await PunctuationProvisioner.instance.isInstalled();
    final polish = GemmaModelProvisioner.instance.isInstalled;
    final autoTidy = await TidySettings.enabled();
    if (!mounted) return;
    setState(() {
      _installed = installed;
      _liveInstalled = live;
      _punctInstalled = punct;
      _polishInstalled = polish;
      _autoTidy = autoTidy;
      _platformOk = platformOk;
    });
  }

  Future<void> _download() async {
    setState(() {
      _busy = true;
      _progress = 0;
      _status = null;
    });
    try {
      await ZipformerProvisioner.instance.download(
        onProgress: (p) {
          if (mounted) setState(() => _progress = p);
        },
      );
      if (!mounted) return;
      setState(() => _status = 'Model installed.');
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
      await ZipformerProvisioner.instance.remove();
      if (!mounted) return;
      setState(() => _status = 'Model removed.');
    } catch (e) {
      if (!mounted) return;
      setState(() => _status = 'Remove failed: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
      await _refresh();
    }
  }

  Future<void> _downloadLive() async {
    setState(() {
      _busy = true;
      _progress = 0;
      _status = null;
    });
    try {
      await StreamingProvisioner.instance.download(
        onProgress: (p) {
          if (mounted) setState(() => _progress = p);
        },
      );
      if (!mounted) return;
      setState(() => _status = 'Live preview installed.');
    } catch (e) {
      if (!mounted) return;
      setState(() => _status = 'Download failed: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
      await _refresh();
    }
  }

  Future<void> _removeLive() async {
    setState(() => _busy = true);
    try {
      await StreamingProvisioner.instance.remove();
      if (!mounted) return;
      setState(() => _status = 'Live preview removed.');
    } catch (e) {
      if (!mounted) return;
      setState(() => _status = 'Remove failed: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
      await _refresh();
    }
  }

  Future<void> _downloadPunct() async {
    setState(() {
      _busy = true;
      _progress = 0;
      _status = null;
    });
    try {
      await PunctuationProvisioner.instance.download(
        onProgress: (p) {
          if (mounted) setState(() => _progress = p);
        },
      );
      if (!mounted) return;
      setState(() => _status = 'Punctuation installed.');
    } catch (e) {
      if (!mounted) return;
      setState(() => _status = 'Download failed: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
      await _refresh();
    }
  }

  Future<void> _removePunct() async {
    setState(() => _busy = true);
    try {
      await PunctuationProvisioner.instance.remove();
      if (!mounted) return;
      setState(() => _status = 'Punctuation removed.');
    } catch (e) {
      if (!mounted) return;
      setState(() => _status = 'Remove failed: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
      await _refresh();
    }
  }

  Future<void> _downloadPolish() async {
    setState(() {
      _busy = true;
      _progress = 0;
      _status = null;
    });
    try {
      await GemmaModelProvisioner.instance.downloadFromNetwork(
        onProgress: (p) {
          if (mounted) setState(() => _progress = p);
        },
      );
      if (!mounted) return;
      setState(() => _status = 'Polish model installed.');
    } catch (e) {
      if (!mounted) return;
      // The provisioner's stall watchdog surfaces here as a TimeoutException
      // with a message that says what to do; show it verbatim.
      setState(() => _status = 'Download failed: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
      await _refresh();
    }
  }

  Future<void> _removePolish() async {
    setState(() => _busy = true);
    try {
      await GemmaModelProvisioner.instance.remove();
      if (!mounted) return;
      setState(() => _status = 'Polish model removed.');
    } catch (e) {
      if (!mounted) return;
      setState(() => _status = 'Remove failed: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
      await _refresh();
    }
  }

  Future<void> _setAutoTidy(bool value) async {
    await TidySettings.setEnabled(value);
    if (!mounted) return;
    setState(() {
      _autoTidy = value;
      _status = value
          ? 'Saved notes will be tidied when the recogniser struggled.'
          : 'Automatic tidy off. Notes stay as the recogniser wrote them.';
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: WearableColors.background,
      appBar: AppBar(
        title: const Text('On-device model'),
        backgroundColor: WearableColors.background,
      ),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          _StatusCard(installed: _installed, platformOk: _platformOk),
          const SizedBox(height: 16),
          // Server STT is independent of on-device platform support — it works
          // even where the local model can't run — so it sits above the gate.
          const _ServerSttSection(),
          const SizedBox(height: 16),
          if (!_platformOk)
            const _InfoCard(
              text:
                  'This device cannot run the on-device model (needs a real Android/iOS device, arm64, iOS 16+, 8 GB+ RAM recommended).',
            )
          else ...[
            if (_busy && _progress != null) ...[
              LinearProgressIndicator(
                value: _progress! / 100.0,
                color: WearableColors.primary,
                backgroundColor: WearableColors.cardAlt,
              ),
              const SizedBox(height: 6),
              Text('Downloading… $_progress%',
                  style: const TextStyle(color: WearableColors.mutedFg, fontSize: 12)),
              const SizedBox(height: 12),
            ],
            if (!_installed)
              _ActionTile(
                icon: Icons.cloud_download_outlined,
                label: 'Download model (${ZipformerProvisioner.sizeLabel})',
                subtitle: 'Zipformer-small from Hugging Face. Wi-Fi recommended.',
                onTap: _busy ? null : _download,
              )
            else
              _ActionTile(
                icon: Icons.delete_outline,
                label: 'Remove model',
                subtitle: 'Free ${ZipformerProvisioner.sizeLabel} of storage.',
                onTap: _busy ? null : _remove,
              ),

            // --- Optional: punctuation ---
            //
            // Sits between the recogniser and the polish model because that is
            // where it sits in cost. Zipformer emits upper-case with no marks;
            // this 7 MB tagger restores both in tens of milliseconds, so it can
            // run on every note. Gemma repairs mishearings too, but at 2.6 GB
            // and seconds per note it is the pass you gate.
            const SizedBox(height: 24),
            const Text('Punctuation (optional)',
                style: TextStyle(
                    color: WearableColors.foreground,
                    fontSize: 13,
                    fontWeight: FontWeight.w600)),
            const SizedBox(height: 8),
            if (!_punctInstalled)
              _ActionTile(
                icon: Icons.text_fields,
                label: 'Download punctuation (${PunctuationProvisioner.sizeLabel})',
                subtitle: 'Adds capitalisation and punctuation to every saved '
                    'note. Small and fast enough to always be on.',
                onTap: _busy ? null : _downloadPunct,
              )
            else
              _ActionTile(
                icon: Icons.delete_outline,
                label: 'Remove punctuation',
                subtitle: 'Free ${PunctuationProvisioner.sizeLabel}. Notes are '
                    'still transcribed; they go back to upper case with no marks.',
                onTap: _busy ? null : _removePunct,
              ),

            // --- Optional: live preview ---
            //
            // Separate download because it is genuinely optional and it is the
            // larger of the two. Without it capture behaves exactly as before:
            // you see nothing until the window closes, then the transcript
            // appears. With it you see text as you speak, decoded by a model
            // measured at 16.26% WER on our channel against the offline
            // model's 11.19%. The saved transcript comes from the offline pass
            // either way, which is why the copy says "preview".
            const SizedBox(height: 24),
            const Text('Live preview (optional)',
                style: TextStyle(
                    color: WearableColors.foreground,
                    fontSize: 13,
                    fontWeight: FontWeight.w600)),
            const SizedBox(height: 8),
            if (!_liveInstalled)
              _ActionTile(
                icon: Icons.graphic_eq,
                label: 'Download live model (${StreamingProvisioner.sizeLabel})',
                subtitle: 'Shows text while you speak. Saved transcripts still '
                    'use the more accurate offline model.',
                onTap: _busy ? null : _downloadLive,
              )
            else
              _ActionTile(
                icon: Icons.delete_outline,
                label: 'Remove live model',
                subtitle: 'Free ${StreamingProvisioner.sizeLabel}. Transcription '
                    'keeps working; only the live text stops.',
                onTap: _busy ? null : _removeLive,
              ),

            // Polish: a Gemma pass over the TEXT the recogniser produced, for
            // casing, punctuation and the kind of error a language model can
            // repair from context. It never sees audio. This tile was missing
            // for a while — the page was rewired to the ASR provisioner and
            // the Gemma download went with it, which left the polish stage
            // permanently uninstallable.
            const SizedBox(height: 24),
            const Text('Polish (optional)',
                style: TextStyle(
                    color: WearableColors.foreground,
                    fontSize: 13,
                    fontWeight: FontWeight.w600)),
            const SizedBox(height: 8),
            if (!_polishInstalled)
              _ActionTile(
                icon: Icons.auto_fix_high_outlined,
                label: 'Download polish model (${GemmaModelProvisioner.sizeLabel})',
                subtitle: 'Gemma 4 E2B tidies capitalisation, punctuation and '
                    'wording of saved notes. Large — use Wi-Fi.',
                onTap: _busy ? null : _downloadPolish,
              )
            else ...[
              _ActionTile(
                icon: Icons.delete_outline,
                label: 'Remove polish model',
                subtitle: 'Free ${GemmaModelProvisioner.sizeLabel}. Notes are '
                    'still transcribed; they just stay as the recogniser wrote them.',
                onTap: _busy ? null : _removePolish,
              ),
              // Off by default, and gated again at capture time. The gate is
              // the point: running Gemma over every note costs seconds and
              // battery on captures where the recogniser did fine, and every
              // run is a chance for a language model to rewrite something the
              // wearer already read. See docs/research/ASR_CANDIDATES.md
              // § "Revisit — LatentASR".
              SwitchListTile(
                value: _autoTidy,
                onChanged: _busy ? null : _setAutoTidy,
                activeThumbColor: WearableColors.primary,
                contentPadding: EdgeInsets.zero,
                title: const Text('Tidy saved notes automatically',
                    style: TextStyle(color: WearableColors.foreground, fontSize: 14)),
                subtitle: const Text(
                    'Only runs on captures where a measurement says the '
                    'recogniser struggled. Fixes capitalisation, punctuation '
                    'and obvious mishearings; never adds words.',
                    style: TextStyle(color: WearableColors.mutedFg, fontSize: 12)),
              ),
            ],
          ],
          if (_status != null) ...[
            const SizedBox(height: 16),
            Text(_status!, style: const TextStyle(color: WearableColors.mutedFg, fontSize: 12)),
          ],
        ],
      ),
    );
  }
}

/// Transcription server (optional) — a self-hosted STT endpoint that produces
/// the accurate FINAL transcript. The on-device model stays the fallback.
class _ServerSttSection extends StatefulWidget {
  const _ServerSttSection();

  @override
  State<_ServerSttSection> createState() => _ServerSttSectionState();
}

class _ServerSttSectionState extends State<_ServerSttSection> {
  final _urlController = TextEditingController();
  final _tokenController = TextEditingController();
  bool _obscureToken = true;
  bool _saving = false;
  String? _status;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final url = await ServerSttConfig.url();
    final token = await ServerSttConfig.token();
    if (!mounted) return;
    setState(() {
      _urlController.text = url ?? '';
      _tokenController.text = token ?? '';
    });
  }

  @override
  void dispose() {
    _urlController.dispose();
    _tokenController.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    try {
      await ServerSttConfig.save(
        url: _urlController.text,
        token: _tokenController.text,
      );
      if (!mounted) return;
      final on = _urlController.text.trim().isNotEmpty;
      setState(() => _status = on
          ? 'Saved. Transcripts will use the server, with on-device as fallback.'
          : 'Cleared. Transcribing on-device only.');
    } catch (e) {
      if (mounted) setState(() => _status = 'Save failed: $e');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('Transcription server (optional)',
            style: TextStyle(
                color: WearableColors.foreground,
                fontSize: 13,
                fontWeight: FontWeight.w600)),
        const SizedBox(height: 4),
        const Text(
          'Server transcripts are more accurate; the on-device model is the '
          'fallback when the server is unreachable. Audio is sent only to the '
          'server you enter here.',
          style: TextStyle(color: WearableColors.mutedFg, fontSize: 12, height: 1.4),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _urlController,
          keyboardType: TextInputType.url,
          autocorrect: false,
          enableSuggestions: false,
          style: const TextStyle(color: WearableColors.foreground, fontSize: 14),
          decoration: InputDecoration(
            labelText: 'Server URL',
            labelStyle: const TextStyle(color: WearableColors.mutedFg),
            hintText: 'https://stt.example.io',
            hintStyle: const TextStyle(color: WearableColors.mutedFg),
            filled: true,
            fillColor: WearableColors.cardAlt,
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(8),
              borderSide: const BorderSide(color: WearableColors.border),
            ),
          ),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _tokenController,
          obscureText: _obscureToken,
          autocorrect: false,
          enableSuggestions: false,
          style: const TextStyle(color: WearableColors.foreground, fontSize: 14),
          decoration: InputDecoration(
            labelText: 'Bearer token',
            labelStyle: const TextStyle(color: WearableColors.mutedFg),
            filled: true,
            fillColor: WearableColors.cardAlt,
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(8),
              borderSide: const BorderSide(color: WearableColors.border),
            ),
            suffixIcon: IconButton(
              icon: Icon(
                _obscureToken ? Icons.visibility_outlined : Icons.visibility_off_outlined,
                color: WearableColors.mutedFg,
              ),
              onPressed: () => setState(() => _obscureToken = !_obscureToken),
            ),
          ),
        ),
        const SizedBox(height: 12),
        Align(
          alignment: Alignment.centerRight,
          child: FilledButton(
            onPressed: _saving ? null : _save,
            style: FilledButton.styleFrom(
              backgroundColor: WearableColors.primary,
              foregroundColor: WearableColors.onPrimary,
            ),
            child: Text(_saving ? 'Saving…' : 'Save'),
          ),
        ),
        if (_status != null) ...[
          const SizedBox(height: 8),
          Text(_status!,
              style: const TextStyle(color: WearableColors.mutedFg, fontSize: 12)),
        ],
      ],
    );
  }
}

class _StatusCard extends StatelessWidget {
  const _StatusCard({required this.installed, required this.platformOk});
  final bool installed;
  final bool platformOk;

  @override
  Widget build(BuildContext context) {
    final ok = installed && platformOk;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: WearableColors.card,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: WearableColors.border),
      ),
      child: Row(
        children: [
          Icon(ok ? Icons.check_circle_outline : Icons.download_for_offline_outlined,
              color: ok ? WearableColors.primary : WearableColors.mutedFg, size: 22),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              installed ? 'Installed ✓' : 'Not installed',
              style: const TextStyle(color: WearableColors.foreground, fontSize: 14, fontWeight: FontWeight.w500),
            ),
          ),
        ],
      ),
    );
  }
}

class _ActionTile extends StatelessWidget {
  const _ActionTile({required this.icon, required this.label, required this.subtitle, required this.onTap});
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
                    Text(label,
                        style: const TextStyle(color: WearableColors.foreground, fontSize: 14, fontWeight: FontWeight.w500)),
                    const SizedBox(height: 2),
                    Text(subtitle, style: const TextStyle(color: WearableColors.mutedFg, fontSize: 12)),
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
      child: Text(text, style: const TextStyle(color: WearableColors.mutedFg, fontSize: 12, height: 1.4)),
    );
  }
}
