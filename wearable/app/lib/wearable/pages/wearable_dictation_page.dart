// Copyright (c) 2025-2026 Kelvin Lee. Licensed under MIT.
//
// WearableDictationPage — Eloquent's treatment of the capture path that already
// exists. Pressing the wearable button is dictation (`overheard: false`); this
// page is the same thing driven from the phone mic, with the screen attached:
// record -> live transcript -> cleaned text -> tone chips -> copy.
//
// Nothing here transcribes. Segmentation is UtteranceBuffer (continuous/VAD),
// audio -> text is ZipformerTranscriber, text -> tone is polish.dart (Gemma,
// text only). This file is the shell around those three.
//
// On-device only: the page refuses to record unless the ASR model is
// installed and the platform can run it, because there is no cloud fallback
// for a page whose whole point is that the audio never leaves the phone.
//
// While this page is mounted it is the app's capture surface: it claims
// `WearableDeviceBridge.captureOwner`, so the wearable's A2 button drives this
// page's recorder instead of opening a capture window on the wearable mic.
// One tap starts, one tap stops and files, two taps cancel (spec §3 rows C/D/G).

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:record/record.dart';

import '../device_bridge.dart';
import '../local_llm/audio_buffer.dart';
import '../local_llm/capture_state.dart';
import '../services/vocabulary_store.dart';
import '../local_llm/opus_pcm_decoder.dart';
import '../local_llm/polish.dart';
import '../local_llm/zipformer_transcriber.dart';
import '../local_llm/transcription_mode.dart';
import '../wearable_theme.dart';

/// Capture rate — must match the on-device pipeline.
const int _kSampleRate = 16000;

/// Bars in the live meter.
const int _kBars = 28;

/// RMS that drives a bar to full height. Cosmetic only, tuned by eye against
/// the phone-mic range; needs a real device to confirm it isn't clipped flat.
const double _kWaveFullScaleRms = 4000.0;

class WearableDictationPage extends StatefulWidget {
  const WearableDictationPage({super.key});

  @override
  State<WearableDictationPage> createState() => _WearableDictationPageState();
}

enum _Stage { checking, unavailable, idle, recording, transcribing, ready }

class _WearableDictationPageState extends State<WearableDictationPage> {
  _Stage _stage = _Stage.checking;

  final AudioRecorder _recorder = AudioRecorder();
  StreamSubscription<Uint8List>? _pcmSub;
  UtteranceBuffer? _buffer;
  Timer? _tick;

  /// Serialises queued segment transcriptions so [_stop] has one thing to await.
  Future<void> _work = Future<void>.value();

  String _transcript = '';
  final List<double> _levels = <double>[];
  Duration _elapsed = Duration.zero;

  PolishTone _tone = PolishTone.polish;
  PolishResult? _polished;
  bool _polishing = false;

  @override
  void initState() {
    super.initState();
    WearableDeviceBridge.captureOwner = _onWearableGesture;
    _checkReady();
  }

  @override
  void dispose() {
    // Only release the slot if it is still ours — a page pushed on top of this
    // one owns capture until it pops.
    if (WearableDeviceBridge.captureOwner == _onWearableGesture) {
      WearableDeviceBridge.captureOwner = null;
    }
    if (_stage == _Stage.recording) CaptureState.instance.idle();
    _tick?.cancel();
    _pcmSub?.cancel();
    _recorder.stop().ignore();
    _recorder.dispose();
    super.dispose();
  }

  /// One resolved A2 gesture (spec §3). The bridge has already played the cue
  /// and worked out what the tap meant; this only has to obey.
  ///
  /// Returns false when this page cannot act — still checking, model missing,
  /// mid-transcribe, or covered by another route — so the bridge falls through
  /// to the wearable mic. Swallowing the tap would leave the white capture
  /// tell-tale lit with nothing recording anywhere.
  bool _onWearableGesture(WearableGestureAction action) {
    if (!mounted) return false;
    if (!(ModalRoute.of(context)?.isCurrent ?? false)) return false;
    switch (action) {
      case WearableGestureAction.startCapture:
      case WearableGestureAction.ackAndCapture:
        if (_stage != _Stage.idle && _stage != _Stage.ready) return false;
        _start();
        return true;
      case WearableGestureAction.stopAndFile:
        if (_stage != _Stage.recording) return false;
        _stop();
        return true;
      case WearableGestureAction.cancelCapture:
        if (_stage != _Stage.recording) return false;
        _cancel();
        return true;
      case WearableGestureAction.ackDismiss:
      case WearableGestureAction.dismissAlert:
      case WearableGestureAction.nop:
      case WearableGestureAction.linkAlive:
      case WearableGestureAction.none:
        return false; // nothing on this page answers these
    }
  }

  Future<void> _checkReady() async {
    bool ready;
    try {
      ready = await ZipformerTranscriber.instance.isInstalled() && await platformSupportsOnDevice();
    } catch (_) {
      ready = false;
    }
    if (!mounted) return;
    setState(() => _stage = ready ? _Stage.idle : _Stage.unavailable);
  }

  // --- capture --------------------------------------------------------------

  Future<void> _start() async {
    if (!await _recorder.hasPermission()) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Microphone permission is required to dictate.')),
      );
      return;
    }

    if (!mounted) return;
    // WearableDeviceBridge resolves CAPTURING from this singleton, so a page
    // that records without publishing here would have the next tap read as
    // "start" instead of "stop".
    CaptureState.instance.recording();
    setState(() {
      _stage = _Stage.recording;
      _transcript = '';
      _polished = null;
      _elapsed = Duration.zero;
      _levels.clear();
    });

    _buffer = UtteranceBuffer(sampleRate: _kSampleRate, onUtterance: _queueSegment);
    try {
      final stream = await _recorder.startStream(const RecordConfig(
        encoder: AudioEncoder.pcm16bits,
        sampleRate: _kSampleRate,
        numChannels: 1,
      ));
      _pcmSub = stream.listen(_onChunk, onError: (Object _) => _stop(), cancelOnError: true);
    } catch (_) {
      _buffer = null;
      CaptureState.instance.idle();
      if (!mounted) return;
      setState(() => _stage = _Stage.idle);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Could not start the microphone.')),
      );
      return;
    }
    _tick = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() => _elapsed += const Duration(seconds: 1));
    });
  }

  void _onChunk(Uint8List chunk) {
    final samples = pcm16BytesToSamples(chunk);
    _buffer?.addContinuous(samples);
    final level = (pcmRms(samples) / _kWaveFullScaleRms).clamp(0.05, 1.0);
    if (!mounted) return;
    setState(() {
      _levels.add(level);
      if (_levels.length > _kBars) _levels.removeRange(0, _levels.length - _kBars);
    });
  }

  /// Each completed utterance is transcribed in order, appended as it lands —
  /// that is what makes the transcript "live" with an offline recogniser.
  void _queueSegment(Int16List samples) {
    _work = _work.then((_) => _transcribeSegment(samples)).catchError((Object _) {});
  }

  Future<void> _transcribeSegment(Int16List samples) async {
    final text = await ZipformerTranscriber.instance.transcribe(samples, sampleRate: _kSampleRate);
    if (text.trim().isEmpty || !mounted) return;
    setState(() => _transcript = _transcript.isEmpty ? text : '$_transcript $text');
  }

  Future<void> _stop() async {
    // Synchronous re-entry guard: the stop button and the stream's onError can
    // both land here, and the teardown below has await points. If the page is
    // already gone, dispose() owns the teardown.
    if (_stage != _Stage.recording || !mounted) return;
    CaptureState.instance.transcribing();
    setState(() => _stage = _Stage.transcribing);
    _tick?.cancel();
    _tick = null;
    try {
      await _recorder.stop();
    } catch (_) {
      // Already stopped, or the platform channel is gone — nothing to undo.
    }
    await _pcmSub?.cancel();
    _pcmSub = null;
    // An explicit press is always intentional, so the tail is kept even if it
    // is below the VAD's minimum — same reasoning as UtteranceBuffer.closeWindow.
    _buffer?.flushPending();
    _buffer = null;

    await _work;
    CaptureState.instance.idle();
    if (!mounted) return;

    if (_transcript.trim().isEmpty) {
      setState(() => _stage = _Stage.idle);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No speech detected.')),
      );
      return;
    }
    setState(() => _stage = _Stage.ready);
    await _runPolish();
  }

  /// Row G — cancel the note. [_stop]'s teardown minus the transcript: nothing
  /// is transcribed, nothing is kept.
  ///
  /// ponytail: no ten-minute recovery here. The bridge keeps cancelled wearable
  /// audio because it holds the whole window; this page hands each utterance
  /// straight to Gemma and never has the PCM to give back.
  Future<void> _cancel() async {
    if (_stage != _Stage.recording || !mounted) return;
    setState(() => _stage = _Stage.transcribing); // re-entry guard, same as _stop
    _tick?.cancel();
    _tick = null;
    try {
      await _recorder.stop();
    } catch (_) {
      // Already stopped, or the platform channel is gone — nothing to undo.
    }
    await _pcmSub?.cancel();
    _pcmSub = null;
    _buffer?.reset(); // drops the pending audio instead of flushing it
    _buffer = null;
    CaptureState.instance.idle();
    if (!mounted) return;
    setState(() {
      _stage = _Stage.idle;
      _transcript = '';
      _levels.clear();
    });
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Discarded.')),
    );
  }

  // --- polish ---------------------------------------------------------------

  Future<void> _runPolish() async {
    setState(() => _polishing = true);
    // The dictionary spells these; polish must not re-spell them.
    final result = await polishTranscript(_transcript, _tone,
        vocabulary: await VocabularyStore.promptWords());
    if (!mounted) return;
    setState(() {
      _polished = result;
      _polishing = false;
    });
  }

  void _selectTone(PolishTone tone) {
    if (_polishing || tone == _tone) return;
    setState(() => _tone = tone);
    _runPolish();
  }

  Future<void> _copy() async {
    await Clipboard.setData(ClipboardData(text: _polished?.text ?? _transcript));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Copied.')),
    );
  }

  // --- build ----------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: WearableColors.background,
      appBar: AppBar(
        title: const Text('Dictation'),
        backgroundColor: WearableColors.background,
      ),
      body: SafeArea(
        child: Padding(padding: const EdgeInsets.all(20), child: _body()),
      ),
    );
  }

  Widget _body() {
    switch (_stage) {
      case _Stage.checking:
        return const Center(child: CircularProgressIndicator(color: WearableColors.primary));
      case _Stage.unavailable:
        return const _UnavailableView();
      case _Stage.idle:
      case _Stage.recording:
      case _Stage.transcribing:
      case _Stage.ready:
        return Column(
          children: [
            Expanded(
              child: SingleChildScrollView(
                child: _stage == _Stage.ready ? _cleanedCard() : _liveCard(),
              ),
            ),
            const SizedBox(height: 20),
            _controls(),
          ],
        );
    }
  }

  Widget _liveCard() {
    final empty = _transcript.isEmpty;
    return _Card(
      title: 'Live transcription',
      child: Text(
        empty
            ? 'Tap the microphone and start talking. Speech is transcribed on this '
                'phone — nothing is uploaded.'
            : _transcript,
        style: TextStyle(
          color: empty ? WearableColors.mutedFg : WearableColors.foreground,
          fontSize: 15,
          height: 24 / 15,
        ),
      ),
    );
  }

  Widget _cleanedCard() {
    final result = _polished;
    return _Card(
      title: 'Cleaned up text',
      action: IconButton(
        onPressed: _polishing ? null : _copy,
        icon: const Icon(Icons.copy_rounded, size: 18),
        color: WearableColors.mutedFg,
        splashRadius: 18,
        tooltip: 'Copy',
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (_polishing)
            const Row(
              children: [
                SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(strokeWidth: 2, color: WearableColors.primary),
                ),
                SizedBox(width: 10),
                Text('Rewriting…', style: TextStyle(color: WearableColors.mutedFg, fontSize: 13)),
              ],
            )
          else
            Text(
              result?.text ?? _transcript,
              style: const TextStyle(
                color: WearableColors.foreground,
                fontSize: 15,
                height: 24 / 15,
              ),
            ),
          if (!_polishing && result != null && result.note != null) ...[
            const SizedBox(height: 10),
            Text(
              result.note!,
              style: const TextStyle(color: WearableColors.mutedFg, fontSize: 12, height: 16 / 12),
            ),
          ],
          const SizedBox(height: 16),
          _toneChips(),
        ],
      ),
    );
  }

  Widget _toneChips() {
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      // kPolishChips, not PolishTone.values: the enum also carries the
      // automatic `tidy` tone, which is not a chip the wearer picks.
      children: kPolishChips.map((tone) {
        final selected = tone == _tone;
        return ChoiceChip(
          label: Text(tone.label),
          selected: selected,
          onSelected: _polishing ? null : (_) => _selectTone(tone),
          // ponytail: the Eloquent chip look is spelled out here because this
          // worktree has no ChipThemeData yet. When the theme pass lands one
          // (black fill when selected, hairline border otherwise), delete the
          // six styling arguments below and let the theme drive it.
          showCheckmark: false,
          backgroundColor: WearableColors.card,
          selectedColor: WearableColors.primary,
          side: const BorderSide(color: WearableColors.border),
          shape: const StadiumBorder(),
          labelStyle: TextStyle(
            color: selected ? WearableColors.onPrimary : WearableColors.foreground,
            fontSize: 13,
            fontWeight: FontWeight.w600,
          ),
        );
      }).toList(),
    );
  }

  Widget _controls() {
    switch (_stage) {
      case _Stage.recording:
        return Column(
          children: [
            Text(
              _formatElapsed(_elapsed),
              style: const TextStyle(
                color: WearableColors.mutedFg,
                fontSize: 13,
                fontWeight: FontWeight.w500,
                letterSpacing: 1,
              ),
            ),
            const SizedBox(height: 12),
            _Waveform(levels: _levels),
            const SizedBox(height: 16),
            // ponytail: stop only. Eloquent also offers pause/resume; that is a
            // third capture state for a feature nobody has asked for yet.
            _CircleButton(icon: Icons.stop_rounded, label: 'Stop dictation', onTap: _stop),
          ],
        );
      case _Stage.transcribing:
        return const Column(
          children: [
            CircularProgressIndicator(color: WearableColors.primary),
            SizedBox(height: 14),
            Text('Transcribing…', style: TextStyle(color: WearableColors.mutedFg, fontSize: 13)),
          ],
        );
      case _Stage.idle:
      case _Stage.ready:
        return _CircleButton(icon: Icons.mic_rounded, label: 'Start dictation', onTap: _start);
      case _Stage.checking:
      case _Stage.unavailable:
        return const SizedBox.shrink();
    }
  }
}

String _formatElapsed(Duration d) {
  // ponytail: mm:ss. A dictation long enough to need an hours field has already
  // blown past what the on-device model can usefully hold.
  final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
  final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
  return '$m:$s';
}

// ---------------------------------------------------------------------------
// Pieces
// ---------------------------------------------------------------------------

class _Card extends StatelessWidget {
  const _Card({required this.title, required this.child, this.action});

  final String title;
  final Widget child;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
      decoration: BoxDecoration(
        color: WearableColors.card,
        borderRadius: BorderRadius.circular(WearableRadii.lg),
        boxShadow: [WearableShadows.card],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  title,
                  style: const TextStyle(
                    color: WearableColors.foreground,
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              if (action != null) action!,
            ],
          ),
          const SizedBox(height: 10),
          child,
        ],
      ),
    );
  }
}

/// Live level meter — thin vertical bars, centred, newest on the right.
class _Waveform extends StatelessWidget {
  const _Waveform({required this.levels});

  final List<double> levels;

  @override
  Widget build(BuildContext context) {
    final pad = List<double>.filled((_kBars - levels.length).clamp(0, _kBars), 0.05);
    final bars = [...pad, ...levels];
    return SizedBox(
      height: 44,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.center,
        children: bars
            .map((level) => Container(
                  width: 3,
                  height: 4 + level * 36,
                  margin: const EdgeInsets.symmetric(horizontal: 2),
                  decoration: BoxDecoration(
                    color: WearableColors.primary,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ))
            .toList(),
      ),
    );
  }
}

/// The black filled circular primary action — 72 dp, design-tokens §6.
class _CircleButton extends StatelessWidget {
  const _CircleButton({required this.icon, required this.label, required this.onTap});

  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: label,
      child: GestureDetector(
        onTap: () {
          HapticFeedback.mediumImpact();
          onTap();
        },
        child: Container(
          width: 72,
          height: 72,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: WearableColors.primary,
            boxShadow: [WearableShadows.button],
          ),
          child: Icon(icon, color: WearableColors.onPrimary, size: 30),
        ),
      ),
    );
  }
}

class _UnavailableView extends StatelessWidget {
  const _UnavailableView();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Container(
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(
          color: WearableColors.cardAlt,
          borderRadius: BorderRadius.circular(WearableRadii.md),
          border: Border.all(color: WearableColors.border),
        ),
        child: const Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.download_for_offline_outlined, color: WearableColors.warning, size: 40),
            SizedBox(height: 16),
            Text(
              'On-device model not installed',
              style: TextStyle(
                color: WearableColors.foreground,
                fontSize: 16,
                fontWeight: FontWeight.w600,
              ),
              textAlign: TextAlign.center,
            ),
            SizedBox(height: 8),
            Text(
              'Dictation transcribes and rewrites entirely on this phone. Install '
              'the on-device model from Settings first. The iOS simulator and '
              'desktop cannot run it.',
              style: TextStyle(color: WearableColors.mutedFg, fontSize: 13, height: 1.5),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }
}
