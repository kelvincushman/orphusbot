// Copyright (c) 2025-2026 Kelvin Lee. Licensed under MIT.
//
// WearableEnrollVoicePage — on-device owner-voice enrollment using the phone
// microphone. Records ~8 s of PCM16 at 16 kHz via the `record` package,
// converts to Float32, and calls OwnerVoice.enrollFromSamples. No cloud
// calls; no "set language" step. Replaces the broken KelvinLee SpeechProfilePage
// flow that requires a cloud language API call which always fails.

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:record/record.dart';

import '../../local_llm/diarization_provisioner.dart';
import '../../local_llm/owner_voice.dart';
import '../../wearable_theme.dart';

/// Minimum duration of recorded audio required for enrollment (seconds).
const int _kMinRecordSeconds = 4;

/// Target recording duration (seconds).
const int _kRecordSeconds = 8;

/// Recording sample rate — must match OwnerVoice / wearable pipeline.
const int _kSampleRate = 16000;

class WearableEnrollVoicePage extends StatefulWidget {
  const WearableEnrollVoicePage({super.key});

  @override
  State<WearableEnrollVoicePage> createState() => _WearableEnrollVoicePageState();
}

enum _PageState { idle, checkingModels, noModels, recording, processing, enrolled, error }

class _WearableEnrollVoicePageState extends State<WearableEnrollVoicePage> {
  _PageState _state = _PageState.idle;
  String _ownerName = 'You';
  String? _errorMessage;
  int _countdown = _kRecordSeconds;
  Timer? _countdownTimer;

  // Raw PCM16 bytes accumulated during recording.
  final List<int> _pcmBytes = [];
  final AudioRecorder _recorder = AudioRecorder();

  @override
  void initState() {
    super.initState();
    _init();
  }

  @override
  void dispose() {
    _countdownTimer?.cancel();
    // ignore: unawaited_futures
    _recorder.stop().ignore();
    _recorder.dispose();
    super.dispose();
  }

  Future<void> _init() async {
    setState(() => _state = _PageState.checkingModels);
    await OwnerVoice.instance.loadEnrollmentState();
    final modelsInstalled = await DiarizationProvisioner.instance.isInstalled();
    if (!mounted) return;
    if (!modelsInstalled) {
      setState(() => _state = _PageState.noModels);
      return;
    }
    if (OwnerVoice.instance.isEnrolled) {
      setState(() {
        _ownerName = OwnerVoice.instance.ownerName;
        _state = _PageState.enrolled;
      });
    } else {
      setState(() => _state = _PageState.idle);
    }
  }

  Future<void> _startRecording() async {
    final hasPerm = await _recorder.hasPermission();
    if (!hasPerm) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Microphone permission is required for enrollment.')),
      );
      return;
    }

    _pcmBytes.clear();
    setState(() {
      _state = _PageState.recording;
      _countdown = _kRecordSeconds;
    });

    final stream = await _recorder.startStream(const RecordConfig(
      encoder: AudioEncoder.pcm16bits,
      sampleRate: _kSampleRate,
      numChannels: 1,
    ));

    // Collect PCM chunks into _pcmBytes.
    stream.listen(
      (chunk) => _pcmBytes.addAll(chunk),
      onError: (Object _) {
        _countdownTimer?.cancel();
        if (!mounted) return;
        setState(() {
          _state = _PageState.error;
          _errorMessage = 'Microphone error during recording.';
        });
      },
      cancelOnError: true,
    );

    // Countdown and auto-stop after _kRecordSeconds.
    _countdownTimer = Timer.periodic(const Duration(seconds: 1), (t) async {
      if (!mounted) {
        t.cancel();
        return;
      }
      final remaining = _countdown - 1;
      setState(() => _countdown = remaining);
      if (remaining <= 0) {
        t.cancel();
        await _stopAndEnroll();
      }
    });
  }

  Future<void> _stopAndEnroll() async {
    _countdownTimer?.cancel();
    _countdownTimer = null;

    try {
      await _recorder.stop();
    } catch (_) {}

    if (!mounted) return;
    setState(() => _state = _PageState.processing);

    // Validate minimum duration: _kSampleRate samples/s * 2 bytes/sample.
    const minBytes = _kMinRecordSeconds * _kSampleRate * 2;
    if (_pcmBytes.length < minBytes) {
      setState(() {
        _state = _PageState.error;
        _errorMessage =
            'Recording was too short ($_kMinRecordSeconds s minimum). Please try again.';
      });
      return;
    }

    // Convert Int16 PCM bytes → Float32 normalised to [-1, 1].
    final f32 = _pcm16BytesToFloat32(_pcmBytes);

    // Split into 3 roughly equal clips for a more robust averaged embedding.
    final clips = _splitIntoClips(f32, count: 3);

    try {
      final name = _ownerName.trim().isEmpty ? 'You' : _ownerName.trim();
      await OwnerVoice.instance.enrollFromSamples(clips, name: name);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _state = _PageState.error;
        _errorMessage = 'Enrollment failed: $e';
      });
      return;
    }

    if (!mounted) return;
    // Verify enrollment actually succeeded (model might be absent despite check).
    if (!OwnerVoice.instance.isEnrolled) {
      setState(() {
        _state = _PageState.error;
        _errorMessage =
            'Embedding extraction failed — check that diarization models are fully installed.';
      });
      return;
    }

    setState(() {
      _ownerName = OwnerVoice.instance.ownerName;
      _state = _PageState.enrolled;
    });
  }

  Future<void> _removeEnrollment() async {
    await OwnerVoice.instance.clear();
    if (!mounted) return;
    setState(() {
      _ownerName = 'You';
      _state = _PageState.idle;
    });
  }

  // ---------------------------------------------------------------------------
  // Helpers
  // ---------------------------------------------------------------------------

  /// Convert raw Int16 little-endian PCM bytes to Float32 in [-1, 1].
  static Float32List _pcm16BytesToFloat32(List<int> bytes) {
    final byteData = Uint8List.fromList(bytes).buffer.asByteData();
    final sampleCount = bytes.length ~/ 2;
    final f32 = Float32List(sampleCount);
    for (var i = 0; i < sampleCount; i++) {
      final sample = byteData.getInt16(i * 2, Endian.little);
      f32[i] = sample / 32768.0;
    }
    return f32;
  }

  /// Split [samples] into [count] roughly equal Float32List clips.
  static List<Float32List> _splitIntoClips(Float32List samples, {required int count}) {
    if (count <= 1 || samples.length < count) return [samples];
    final clipLen = samples.length ~/ count;
    return List.generate(count, (i) {
      final start = i * clipLen;
      final end = (i == count - 1) ? samples.length : start + clipLen;
      return Float32List.sublistView(samples, start, end);
    });
  }

  // ---------------------------------------------------------------------------
  // Build
  // ---------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: WearableColors.background,
      appBar: AppBar(
        title: const Text('Enroll Your Voice'),
        backgroundColor: WearableColors.background,
      ),
      body: Padding(
        padding: const EdgeInsets.all(20),
        child: _buildBody(),
      ),
    );
  }

  Widget _buildBody() {
    switch (_state) {
      case _PageState.checkingModels:
        return const Center(child: CircularProgressIndicator(color: WearableColors.primary));

      case _PageState.noModels:
        return _NoModelsView();

      case _PageState.idle:
        return _IdleView(
          ownerName: _ownerName,
          onNameChanged: (v) => setState(() => _ownerName = v),
          onRecord: _startRecording,
        );

      case _PageState.recording:
        return _RecordingView(countdown: _countdown, onStop: _stopAndEnroll);

      case _PageState.processing:
        return const _ProcessingView();

      case _PageState.enrolled:
        return _EnrolledView(
          ownerName: _ownerName,
          onReEnroll: () => setState(() => _state = _PageState.idle),
          onRemove: _removeEnrollment,
        );

      case _PageState.error:
        return _ErrorView(
          message: _errorMessage ?? 'An unknown error occurred.',
          onRetry: () => setState(() {
            _state = _PageState.idle;
            _errorMessage = null;
          }),
        );
    }
  }
}

// ---------------------------------------------------------------------------
// Sub-views (all stateless)
// ---------------------------------------------------------------------------

class _NoModelsView extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Center(
      child: Container(
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(
          color: WearableColors.cardAlt,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: WearableColors.border),
        ),
        child: const Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.download_for_offline_outlined, color: WearableColors.warning, size: 40),
            SizedBox(height: 16),
            Text(
              'Diarization models not installed',
              style: TextStyle(
                color: WearableColors.foreground,
                fontSize: 16,
                fontWeight: FontWeight.w600,
              ),
              textAlign: TextAlign.center,
            ),
            SizedBox(height: 8),
            Text(
              'Download the diarization models first from the Wearable tab before enrolling your voice.',
              style: TextStyle(color: WearableColors.mutedFg, fontSize: 13, height: 1.5),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }
}

class _IdleView extends StatelessWidget {
  const _IdleView({
    required this.ownerName,
    required this.onNameChanged,
    required this.onRecord,
  });

  final String ownerName;
  final ValueChanged<String> onNameChanged;
  final VoidCallback onRecord;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          padding: const EdgeInsets.all(16),
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
                  'Wearable will learn to recognise your voice on this device. '
                  'No audio is sent to the cloud — everything stays on your phone.',
                  style: TextStyle(color: WearableColors.mutedFg, fontSize: 12, height: 1.5),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 24),
        const Text(
          'Your name',
          style: TextStyle(
            color: WearableColors.mutedFg,
            fontSize: 11,
            fontWeight: FontWeight.w600,
            letterSpacing: 0.8,
          ),
        ),
        const SizedBox(height: 6),
        TextFormField(
          initialValue: ownerName,
          onChanged: onNameChanged,
          style: const TextStyle(color: WearableColors.foreground),
          decoration: const InputDecoration(
            hintText: 'e.g. You, Kelvin, …',
          ),
        ),
        const SizedBox(height: 32),
        ElevatedButton.icon(
          onPressed: onRecord,
          icon: const Icon(Icons.mic),
          label: const Text('Record Voice Sample'),
          style: ElevatedButton.styleFrom(
            backgroundColor: WearableColors.primary,
            foregroundColor: WearableColors.onPrimary,
            padding: const EdgeInsets.symmetric(vertical: 16),
          ),
        ),
        const SizedBox(height: 12),
        const Text(
          'Recording lasts $_kRecordSeconds seconds. '
          'Say a few sentences — describe your day, read something aloud — '
          'so Wearable can build a voice model.',
          style: TextStyle(color: WearableColors.mutedFg, fontSize: 12, height: 1.5),
          textAlign: TextAlign.center,
        ),
      ],
    );
  }
}

class _RecordingView extends StatelessWidget {
  const _RecordingView({required this.countdown, required this.onStop});

  final int countdown;
  final VoidCallback onStop;

  @override
  Widget build(BuildContext context) {
    final progress = ((_kRecordSeconds - countdown) / _kRecordSeconds).clamp(0.0, 1.0);
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Stack(
            alignment: Alignment.center,
            children: [
              SizedBox(
                width: 120,
                height: 120,
                child: CircularProgressIndicator(
                  value: progress,
                  color: WearableColors.primary,
                  backgroundColor: WearableColors.border,
                  strokeWidth: 6,
                ),
              ),
              Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.mic, color: WearableColors.primary, size: 32),
                  const SizedBox(height: 4),
                  Text(
                    '$countdown',
                    style: const TextStyle(
                      color: WearableColors.foreground,
                      fontSize: 28,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ],
              ),
            ],
          ),
          const SizedBox(height: 24),
          const Text(
            'Recording…',
            style: TextStyle(color: WearableColors.foreground, fontSize: 16, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 8),
          const Text(
            'Say a few sentences so Wearable learns your voice.',
            style: TextStyle(color: WearableColors.mutedFg, fontSize: 13, height: 1.5),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 32),
          OutlinedButton(
            onPressed: onStop,
            style: OutlinedButton.styleFrom(
              foregroundColor: WearableColors.foreground,
              side: const BorderSide(color: WearableColors.border),
            ),
            child: const Text('Stop Early'),
          ),
        ],
      ),
    );
  }
}

class _ProcessingView extends StatelessWidget {
  const _ProcessingView();

  @override
  Widget build(BuildContext context) {
    return const Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          CircularProgressIndicator(color: WearableColors.primary),
          SizedBox(height: 20),
          Text(
            'Building voice model…',
            style: TextStyle(color: WearableColors.foreground, fontSize: 15),
          ),
          SizedBox(height: 8),
          Text(
            'This may take a few seconds.',
            style: TextStyle(color: WearableColors.mutedFg, fontSize: 12),
          ),
        ],
      ),
    );
  }
}

class _EnrolledView extends StatelessWidget {
  const _EnrolledView({
    required this.ownerName,
    required this.onReEnroll,
    required this.onRemove,
  });

  final String ownerName;
  final VoidCallback onReEnroll;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          padding: const EdgeInsets.all(20),
          decoration: BoxDecoration(
            color: WearableColors.primary.withValues(alpha: 0.08),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: WearableColors.primary.withValues(alpha: 0.4)),
          ),
          child: Column(
            children: [
              const Icon(Icons.check_circle_outline, color: WearableColors.primary, size: 40),
              const SizedBox(height: 12),
              Text(
                'Enrolled as "$ownerName"',
                style: const TextStyle(
                  color: WearableColors.foreground,
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 6),
              const Text(
                'Wearable will recognise your voice on this device during diarization.',
                style: TextStyle(color: WearableColors.mutedFg, fontSize: 12, height: 1.5),
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
        const SizedBox(height: 24),
        OutlinedButton.icon(
          onPressed: onReEnroll,
          icon: const Icon(Icons.mic, size: 18),
          label: const Text('Re-enroll'),
          style: OutlinedButton.styleFrom(
            foregroundColor: WearableColors.foreground,
            side: const BorderSide(color: WearableColors.border),
            padding: const EdgeInsets.symmetric(vertical: 14),
          ),
        ),
        const SizedBox(height: 12),
        OutlinedButton.icon(
          onPressed: onRemove,
          icon: const Icon(Icons.delete_outline, size: 18),
          label: const Text('Remove enrollment'),
          style: OutlinedButton.styleFrom(
            foregroundColor: WearableColors.destructive,
            side: BorderSide(color: WearableColors.destructive.withValues(alpha: 0.5)),
            padding: const EdgeInsets.symmetric(vertical: 14),
          ),
        ),
      ],
    );
  }
}

class _ErrorView extends StatelessWidget {
  const _ErrorView({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: WearableColors.destructive.withValues(alpha: 0.08),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: WearableColors.destructive.withValues(alpha: 0.4)),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Icon(Icons.warning_amber_outlined, color: WearableColors.destructive, size: 18),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    message,
                    style: const TextStyle(color: WearableColors.foreground, fontSize: 13, height: 1.4),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 20),
          ElevatedButton(
            onPressed: onRetry,
            style: ElevatedButton.styleFrom(
              backgroundColor: WearableColors.primary,
              foregroundColor: WearableColors.onPrimary,
            ),
            child: const Text('Try Again'),
          ),
        ],
      ),
    );
  }
}
