// Copyright (c) 2025-2026 Kelvin Lee. Licensed under MIT.
//
// WearableVoicePage — settings sub-page for voice-profile enrollment and the
// S-4 hands-free capture toggle. Covers plan M-5.2 in
// docs/plans/wearable-one-product-pivot.md.
//
// What it exposes:
//   - enrollment status (has owner voice profile?) + shortcut to the
//     existing speech-profile enrollment flow (now routed through Wearable
//     via speech_profile.dart — see M-5.1)
//   - hands-free capture toggle (requires an enrolled owner profile)
//   - clear explanation of what hands-free does and when it's off

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:kelvinlee/wearable/local_llm/owner_voice.dart';
import 'package:kelvinlee/wearable/wearable_client.dart';
import 'package:kelvinlee/wearable/phone_mic.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../device_bridge.dart';
import '../../local_llm/zipformer_provisioner.dart';
import '../../local_llm/transcription_mode.dart';
import '../../wearable_theme.dart';
import 'wearable_enroll_voice_page.dart';
import 'wearable_on_device_model_page.dart';
import 'wearable_people_page.dart';

class WearableVoicePage extends StatefulWidget {
  const WearableVoicePage({super.key});

  @override
  State<WearableVoicePage> createState() => _WearableVoicePageState();
}

class _WearableVoicePageState extends State<WearableVoicePage> {
  bool _loading = true;
  bool _paired = false;
  bool _enrolled = false;
  bool _ownerEnrolled = false;
  String _ownerName = 'You';
  bool _handsFreeEnabled = false;
  bool _handsFreeAllowed = true;
  bool _phoneMicCapture = false;
  String? _error;

  static const String _phoneMicCaptureKey = 'wearable.phoneMicCapture';

  // On-device transcription (Moonshine ASR) state.
  TranscriptionMode _mode = TranscriptionMode.cloud;
  OnDeviceSegmentation _segmentation = OnDeviceSegmentation.button;
  bool _modelInstalled = false;
  bool _platformSupportsOnDevice = false;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      // On-device transcription state is independent of Wearable reachability.
      _mode = await TranscriptionSettings.mode();
      _segmentation = await TranscriptionSettings.segmentation();
      _platformSupportsOnDevice = await platformSupportsOnDevice();
      // The ASR model, not Gemma. Gemma is the optional text-polish stage and
      // its absence must not make on-device transcription look unavailable.
      _modelInstalled = await ZipformerProvisioner.instance.isInstalled();

      // Phone-mic capture. The switch must show what is ACTUALLY capturing, not
      // what the pref remembers: nothing restarts the streamer at launch, so a
      // pref-bound switch read ON after every restart while the mic was idle.
      // The pref is the wearer's intent, so honour it here — this page is where
      // the mic permission flow already lives — and correct it if it fails.
      final prefs = await SharedPreferences.getInstance();
      var phoneMic = prefs.getBool(_phoneMicCaptureKey) ?? false;
      if (phoneMic && !PhoneMicStreamer.instance.isRunning) {
        try {
          await PhoneMicStreamer.instance.start();
        } catch (_) {
          // Permission revoked, mic busy, no model — do not claim to be capturing.
        }
        phoneMic = PhoneMicStreamer.instance.isRunning;
        if (!phoneMic) await prefs.setBool(_phoneMicCaptureKey, false);
      }

      // Load on-device owner enrollment state.
      await OwnerVoice.instance.loadEnrollmentState();
      final ownerEnrolled = OwnerVoice.instance.isEnrolled;
      final ownerName = OwnerVoice.instance.ownerName;

      final paired = await WearableClient.instance.isPaired();
      if (!paired) {
        if (!mounted) return;
        setState(() {
          _paired = false;
          _ownerEnrolled = ownerEnrolled;
          _ownerName = ownerName;
          _phoneMicCapture = phoneMic;
          _loading = false;
        });
        return;
      }
      final enrolled = await WearableClient.instance.hasSpeechProfile();
      final hf = await WearableClient.instance.handsFreeStatus();
      if (!mounted) return;
      setState(() {
        _paired = true;
        _enrolled = enrolled;
        _ownerEnrolled = ownerEnrolled;
        _ownerName = ownerName;
        _handsFreeEnabled = hf.enabled;
        _handsFreeAllowed = hf.allowed;
        _phoneMicCapture = phoneMic;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = 'Could not reach Wearable: $e';
        _loading = false;
      });
    }
  }

  Future<void> _toggleHandsFree(bool enabled) async {
    if (!_enrolled) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Enroll your voice first.')),
      );
      return;
    }
    try {
      await WearableClient.instance.setHandsFreeMode(enabled);
      setState(() => _handsFreeEnabled = enabled);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Hands-free toggle failed: $e')),
      );
    }
  }

  Future<void> _togglePhoneMic(bool enabled) async {
    // Check permission before starting.
    if (enabled) {
      final streamer = PhoneMicStreamer.instance;
      try {
        await streamer.start();
      } on StateError catch (e) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('$e')),
        );
        return;
      }
    } else {
      await PhoneMicStreamer.instance.stop();
    }
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_phoneMicCaptureKey, enabled);
    if (!mounted) return;
    setState(() => _phoneMicCapture = enabled);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: WearableColors.background,
      appBar: AppBar(
        title: const Text('Voice & Hands-Free'),
        backgroundColor: WearableColors.background,
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator(color: WearableColors.primary))
          : RefreshIndicator(
              color: WearableColors.primary,
              onRefresh: _refresh,
              child: ListView(
                padding: const EdgeInsets.all(20),
                children: [
                  if (_error != null) _ErrorBanner(message: _error!),
                  if (!_paired) const _NotPairedBanner() else ...[
                    const _SectionHeader(title: 'Voice profile'),
                    _EnrollmentTile(
                      enrolled: _enrolled,
                      ownerEnrolled: _ownerEnrolled,
                      ownerName: _ownerName,
                      onTap: () async {
                        await Navigator.of(context).push(
                          MaterialPageRoute(
                            builder: (_) => const WearableEnrollVoicePage(),
                          ),
                        );
                        if (!mounted) return;
                        await _refresh();
                      },
                      onRemoveOwner: () async {
                        await OwnerVoice.instance.clear();
                        if (!mounted) return;
                        await _refresh();
                      },
                    ),
                    const SizedBox(height: 24),
                    const _SectionHeader(title: 'Hands-free capture'),
                    _HandsFreeTile(
                      enabled: _handsFreeEnabled,
                      serverAllowed: _handsFreeAllowed,
                      enrollmentRequired: !_enrolled,
                      onChanged: _toggleHandsFree,
                    ),
                    const SizedBox(height: 12),
                    const _HandsFreeExplainer(),
                  ],
                  const SizedBox(height: 24),
                  // Outside the paired gate on purpose: deleting a stored
                  // voiceprint must not depend on a wearable being connected.
                  const _SectionHeader(title: 'People'),
                  _PeopleTile(onTap: () async {
                    await Navigator.of(context).push(
                      MaterialPageRoute(builder: (_) => const WearablePeoplePage()),
                    );
                    if (!mounted) return;
                    await _refresh();
                  }),
                  const SizedBox(height: 24),
                  const _SectionHeader(title: 'Phone microphone'),
                  _PhoneMicCaptureTile(
                    enabled: _phoneMicCapture,
                    onChanged: _togglePhoneMic,
                  ),
                  const SizedBox(height: 12),
                  const _PhoneMicExplainer(),
                  const SizedBox(height: 24),
                  const _SectionHeader(title: 'On-device transcription (beta)'),
                  _OnDeviceModeTile(
                    onDevice: _mode == TranscriptionMode.onDevice,
                    available: _platformSupportsOnDevice && _modelInstalled,
                    platformOk: _platformSupportsOnDevice,
                    modelInstalled: _modelInstalled,
                    onChanged: _toggleOnDevice,
                  ),
                  if (_mode == TranscriptionMode.onDevice) ...[
                    const SizedBox(height: 12),
                    _SegmentationTile(
                      segmentation: _segmentation,
                      onChanged: _setSegmentation,
                    ),
                  ],
                  const SizedBox(height: 12),
                  _ModelManageTile(
                    installed: _modelInstalled,
                    onTap: () async {
                      await Navigator.of(context).push(
                        MaterialPageRoute(builder: (_) => const WearableOnDeviceModelPage()),
                      );
                      if (!mounted) return;
                      await _refresh();
                    },
                  ),
                  const SizedBox(height: 12),
                  const _OnDeviceExplainer(),
                ],
              ),
            ),
    );
  }

  Future<void> _toggleOnDevice(bool enabled) async {
    if (enabled && !(_platformSupportsOnDevice && _modelInstalled)) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Install the on-device model first (and use a supported device).')),
      );
      return;
    }
    final mode = enabled ? TranscriptionMode.onDevice : TranscriptionMode.cloud;
    await TranscriptionSettings.setMode(mode);
    if (!mounted) return;
    setState(() => _mode = mode);
    _applyToLiveBridge('Transcription mode updated.');
  }

  Future<void> _setSegmentation(OnDeviceSegmentation seg) async {
    await TranscriptionSettings.setSegmentation(seg);
    if (!mounted) return;
    setState(() => _segmentation = seg);
    _applyToLiveBridge('Segmentation updated.');
  }

  /// Push a settings change to a connected wearable now.
  ///
  /// `reconfigureTranscription()` exists precisely so the wearer does not have
  /// to disconnect and reconnect, and had no callers: both toggles wrote the
  /// preference and left the bridge on the old one, one of them silently.
  void _applyToLiveBridge(String applied) {
    final bridge = WearableDeviceBridge.current;
    if (bridge == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Saved. Applies when the wearable connects.')),
      );
      return;
    }
    unawaited(bridge.reconfigureTranscription());
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(applied)));
  }
}

class _NotPairedBanner extends StatelessWidget {
  const _NotPairedBanner();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: WearableColors.cardAlt,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: WearableColors.border),
      ),
      child: const Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.info_outline, color: WearableColors.mutedFg, size: 18),
          SizedBox(width: 10),
          Expanded(
            child: Text(
              'Pair this app to a Wearable server to manage voice profile and hands-free capture.',
              style: TextStyle(color: WearableColors.mutedFg, fontSize: 13, height: 1.4),
            ),
          ),
        ],
      ),
    );
  }
}

class _ErrorBanner extends StatelessWidget {
  const _ErrorBanner({required this.message});
  final String message;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 16),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: WearableColors.destructive.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: WearableColors.destructive.withValues(alpha: 0.4)),
      ),
      child: Row(
        children: [
          const Icon(Icons.warning_amber_outlined, color: WearableColors.destructive, size: 18),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              message,
              style: const TextStyle(color: WearableColors.foreground, fontSize: 12, height: 1.4),
            ),
          ),
        ],
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader({required this.title});
  final String title;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8, top: 4),
      child: Text(
        title.toUpperCase(),
        style: const TextStyle(
          color: WearableColors.mutedFg,
          fontSize: 11,
          fontWeight: FontWeight.w600,
          letterSpacing: 0.8,
        ),
      ),
    );
  }
}

class _EnrollmentTile extends StatelessWidget {
  const _EnrollmentTile({
    required this.enrolled,
    required this.ownerEnrolled,
    required this.ownerName,
    required this.onTap,
    required this.onRemoveOwner,
  });

  final bool enrolled;
  final bool ownerEnrolled;
  final String ownerName;
  final VoidCallback onTap;
  final VoidCallback onRemoveOwner;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: onTap,
          child: Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: WearableColors.card,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: WearableColors.border),
            ),
            child: Row(
              children: [
                Icon(
                  enrolled ? Icons.check_circle_outline : Icons.mic_none_outlined,
                  color: enrolled ? WearableColors.primary : WearableColors.mutedFg,
                  size: 22,
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        enrolled ? 'Voice profile enrolled' : 'Enroll your voice',
                        style: const TextStyle(
                          color: WearableColors.foreground,
                          fontSize: 14,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        enrolled
                            ? 'Tap to re-enroll'
                            : 'Record a short sample so Wearable can recognise you.',
                        style: const TextStyle(color: WearableColors.mutedFg, fontSize: 12),
                      ),
                    ],
                  ),
                ),
                const Icon(Icons.chevron_right, color: WearableColors.mutedFg, size: 18),
              ],
            ),
          ),
        ),
        if (ownerEnrolled) ...[
          const SizedBox(height: 6),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            decoration: BoxDecoration(
              color: WearableColors.cardAlt,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: WearableColors.border),
            ),
            child: Row(
              children: [
                const Icon(Icons.person_outline, color: WearableColors.primary, size: 18),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    'Recognised as "$ownerName" on this device',
                    style: const TextStyle(color: WearableColors.foreground, fontSize: 13),
                  ),
                ),
                TextButton(
                  onPressed: onRemoveOwner,
                  style: TextButton.styleFrom(
                    foregroundColor: WearableColors.destructive,
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    minimumSize: const Size(0, 32),
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                  child: const Text('Remove', style: TextStyle(fontSize: 12)),
                ),
              ],
            ),
          ),
        ],
      ],
    );
  }
}

class _HandsFreeTile extends StatelessWidget {
  const _HandsFreeTile({
    required this.enabled,
    required this.serverAllowed,
    required this.enrollmentRequired,
    required this.onChanged,
  });

  final bool enabled;
  final bool serverAllowed;
  final bool enrollmentRequired;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final interactive = serverAllowed && !enrollmentRequired;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: WearableColors.card,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: WearableColors.border),
      ),
      child: Row(
        children: [
          const Icon(Icons.hearing_outlined, color: WearableColors.primary, size: 20),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Hands-free capture',
                  style: TextStyle(
                    color: WearableColors.foreground,
                    fontSize: 14,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  !serverAllowed
                      ? 'Disabled by operator policy.'
                      : enrollmentRequired
                          ? 'Enroll your voice first to enable.'
                          : enabled
                              ? 'Wearable filters audio to your voice.'
                              : 'Only the button opens capture.',
                  style: const TextStyle(color: WearableColors.mutedFg, fontSize: 12),
                ),
              ],
            ),
          ),
          Switch.adaptive(
            value: enabled,
            activeThumbColor: WearableColors.primary,
            onChanged: interactive ? onChanged : null,
          ),
        ],
      ),
    );
  }
}

class _OnDeviceModeTile extends StatelessWidget {
  const _OnDeviceModeTile({
    required this.onDevice,
    required this.available,
    required this.platformOk,
    required this.modelInstalled,
    required this.onChanged,
  });

  final bool onDevice;
  final bool available;
  final bool platformOk;
  final bool modelInstalled;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final String subtitle;
    if (!platformOk) {
      subtitle = 'Unsupported device (needs a real Android/iOS device).';
    } else if (!modelInstalled) {
      subtitle = 'Install the model below to enable.';
    } else if (onDevice) {
      subtitle = 'Audio is transcribed on this phone (Zipformer).';
    } else {
      subtitle = 'Audio is transcribed in the cloud (Deepgram).';
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: WearableColors.card,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: WearableColors.border),
      ),
      child: Row(
        children: [
          const Icon(Icons.memory_outlined, color: WearableColors.primary, size: 20),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Transcribe on-device',
                  style: TextStyle(color: WearableColors.foreground, fontSize: 14, fontWeight: FontWeight.w500),
                ),
                const SizedBox(height: 2),
                Text(subtitle, style: const TextStyle(color: WearableColors.mutedFg, fontSize: 12)),
              ],
            ),
          ),
          Switch.adaptive(
            value: onDevice,
            activeThumbColor: WearableColors.primary,
            onChanged: available ? onChanged : null,
          ),
        ],
      ),
    );
  }
}

class _SegmentationTile extends StatelessWidget {
  const _SegmentationTile({required this.segmentation, required this.onChanged});
  final OnDeviceSegmentation segmentation;
  final ValueChanged<OnDeviceSegmentation> onChanged;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: WearableColors.card,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: WearableColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('Capture trigger',
              style: TextStyle(color: WearableColors.foreground, fontSize: 14, fontWeight: FontWeight.w500)),
          const SizedBox(height: 8),
          SegmentedButton<OnDeviceSegmentation>(
            segments: const [
              ButtonSegment(value: OnDeviceSegmentation.button, label: Text('Button'), icon: Icon(Icons.touch_app_outlined)),
              ButtonSegment(value: OnDeviceSegmentation.continuous, label: Text('Continuous'), icon: Icon(Icons.graphic_eq)),
            ],
            selected: {segmentation},
            onSelectionChanged: (s) => onChanged(s.first),
          ),
          if (segmentation == OnDeviceSegmentation.continuous) ...[
            const SizedBox(height: 8),
            const Text(
              'Continuous mode runs the model on every utterance — higher battery and thermal load.',
              style: TextStyle(color: WearableColors.mutedFg, fontSize: 11, height: 1.4),
            ),
          ],
        ],
      ),
    );
  }
}

class _PeopleTile extends StatelessWidget {
  const _PeopleTile({required this.onTap});
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      borderRadius: BorderRadius.circular(8),
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: WearableColors.card,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: WearableColors.border),
        ),
        child: const Row(
          children: [
            Icon(Icons.people_outline, color: WearableColors.primary, size: 22),
            SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Known voices',
                      style: TextStyle(
                          color: WearableColors.foreground,
                          fontSize: 14,
                          fontWeight: FontWeight.w500)),
                  SizedBox(height: 2),
                  Text('Who the app can recognise, and how to delete them.',
                      style: TextStyle(color: WearableColors.mutedFg, fontSize: 12)),
                ],
              ),
            ),
            Icon(Icons.chevron_right, color: WearableColors.mutedFg, size: 18),
          ],
        ),
      ),
    );
  }
}

class _ModelManageTile extends StatelessWidget {
  const _ModelManageTile({required this.installed, required this.onTap});
  final bool installed;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      borderRadius: BorderRadius.circular(8),
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: WearableColors.card,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: WearableColors.border),
        ),
        child: Row(
          children: [
            Icon(installed ? Icons.check_circle_outline : Icons.download_for_offline_outlined,
                color: installed ? WearableColors.primary : WearableColors.mutedFg, size: 22),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(installed ? 'On-device model installed' : 'Install on-device model',
                      style: const TextStyle(color: WearableColors.foreground, fontSize: 14, fontWeight: FontWeight.w500)),
                  const SizedBox(height: 2),
                  Text(installed
                      ? 'Manage / remove (${ZipformerProvisioner.sizeLabel})'
                      : 'Download (${ZipformerProvisioner.sizeLabel})',
                      style: const TextStyle(color: WearableColors.mutedFg, fontSize: 12)),
                ],
              ),
            ),
            const Icon(Icons.chevron_right, color: WearableColors.mutedFg, size: 18),
          ],
        ),
      ),
    );
  }
}

class _OnDeviceExplainer extends StatelessWidget {
  const _OnDeviceExplainer();

  @override
  Widget build(BuildContext context) {
    return Container(
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
              'On-device mode transcribes wearable/mic audio locally with Zipformer and sends only the text to Wearable — no audio leaves the phone. English only. When off, audio streams to the server for cloud transcription.',
              style: TextStyle(color: WearableColors.mutedFg, fontSize: 11, height: 1.4),
            ),
          ),
        ],
      ),
    );
  }
}

class _HandsFreeExplainer extends StatelessWidget {
  const _HandsFreeExplainer();

  @override
  Widget build(BuildContext context) {
    return Container(
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
              'When off, Wearable only listens during a button-press window. When on, Wearable filters captured audio to your enrolled voice via diarisation — non-owner voices are dropped before they leave the device boundary.',
              style: TextStyle(color: WearableColors.mutedFg, fontSize: 11, height: 1.4),
            ),
          ),
        ],
      ),
    );
  }
}

class _PhoneMicCaptureTile extends StatelessWidget {
  const _PhoneMicCaptureTile({
    required this.enabled,
    required this.onChanged,
  });

  final bool enabled;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: WearableColors.card,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: WearableColors.border),
      ),
      child: Row(
        children: [
          const Icon(Icons.smartphone_outlined, color: WearableColors.primary, size: 20),
          const SizedBox(width: 12),
          const Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Use phone microphone',
                  style: TextStyle(
                    color: WearableColors.foreground,
                    fontSize: 14,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                SizedBox(height: 2),
                Text(
                  'Capture audio from this phone\'s mic instead of (or in addition to) the wearable.',
                  style: TextStyle(color: WearableColors.mutedFg, fontSize: 12),
                ),
              ],
            ),
          ),
          Switch.adaptive(
            value: enabled,
            activeThumbColor: WearableColors.primary,
            onChanged: onChanged,
          ),
        ],
      ),
    );
  }
}

class _PhoneMicExplainer extends StatelessWidget {
  const _PhoneMicExplainer();

  @override
  Widget build(BuildContext context) {
    return Container(
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
              'When on, the phone mic feeds audio into the same on-device transcription pipeline as the wearable. Both sources can run simultaneously — each utterance is processed independently so there is no double-capture within a single utterance, though back-to-back speech on both mics may produce duplicate transcripts.',
              style: TextStyle(color: WearableColors.mutedFg, fontSize: 11, height: 1.4),
            ),
          ),
        ],
      ),
    );
  }
}
