// Copyright (c) 2025-2026 Kelvin Lee. Licensed under MIT.
//
// UtteranceBuffer — accumulates PCM16 samples (16 kHz mono) and emits discrete
// "utterances" for on-device transcription. Gemma audio inference is batch and
// capped at 30 s per clip, so every emitted utterance is guaranteed <= maxSeconds.
//
// Two segmentation strategies (see OnDeviceSegmentation):
//   - button     : openWindow() on AGENT_REQUEST, addWindowed() while talking,
//                  closeWindow() on release/timeout → one utterance.
//   - continuous : addContinuous() feeds frames; the buffer flushes on a run of
//                  trailing near-silence (RMS-based VAD) or the 30 s hard cap.
//
// Pure Dart (operates on Int16List) so the segmentation logic is unit-testable
// without any native/audio dependency.

import 'dart:math' as math;
import 'dart:typed_data';

typedef UtteranceCallback = void Function(Int16List samples);

class UtteranceBuffer {
  UtteranceBuffer({
    required this.onUtterance,
    this.sampleRate = 16000,
    this.maxSeconds = 30,
    this.silenceMs = 1000,
    this.silenceRmsThreshold = 1000.0,
    this.minUtteranceMs = 300,
    this.minSpeechMs = 800,
    this.vadPreGain = 8.0,
    this.captureGain = 1.0,
    this.preRollMs = 1500,
  });

  /// Invoked with each complete utterance (<= maxSeconds of samples).
  final UtteranceCallback onUtterance;
  final int sampleRate;

  /// Hard cap per utterance — matches Gemma's 30 s audio limit.
  final int maxSeconds;

  /// Trailing near-silence that ends an utterance in continuous mode.
  /// Increased to 1000 ms so brief between-word gaps don't prematurely flush.
  final int silenceMs;

  /// RMS amplitude (post-vadPreGain scale) below which a frame counts as silence.
  /// With vadPreGain=8: quiet speech (raw 200–400) → 1600–3200; silence
  /// (raw 60–200) → 480–1600. Threshold of 1000 sits between the two ranges.
  final double silenceRmsThreshold;

  /// Utterances shorter than this are dropped as noise (continuous mode only).
  final int minUtteranceMs;

  /// Minimum detected speech content (non-silence frames) required before
  /// flushing. Prevents flushing on trailing-silence-only buffers when the
  /// speaker hasn't said enough yet.
  final int minSpeechMs;

  /// Pre-gain applied to each frame before the VAD energy decision ONLY.
  /// Lifts quiet wearable audio (raw RMS ~60–400) into a range where the VAD
  /// threshold can reliably separate speech from silence. It never reaches the
  /// audio that is kept — see [captureGain].
  final double vadPreGain;

  /// Gain applied to the audio that is actually stored and transcribed.
  ///
  /// Wearable audio arrives very quiet and wants the same 8× lift. Phone-mic
  /// audio arrives at conversational level and must NOT be touched: this used
  /// to share [vadPreGain], which hard-clipped roughly a quarter of the samples
  /// of a normally-spoken phone dictation and handed Gemma a square wave.
  /// Default 1.0 — the safe value. Callers with quiet sources opt in.
  ///
  /// Continuous mode only. Button windows stay raw — see [addWindowed].
  final double captureGain;

  /// Audio kept from *before* the window opened, so the first word survives.
  ///
  /// The firmware waits out a 750 ms multi-tap window before it reports a tap,
  /// and the BLE hop costs more on top. Without this the wearer loses whatever
  /// they said in that gap and learns "tap, wait, then talk".
  ///
  /// Only frames the audio session was already decoding are held, only in
  /// button mode, only in memory, and only this many milliseconds of them.
  final int preRollMs;

  final List<int> _samples = <int>[];

  /// Rolling tail of the most recent [preRollMs] while the window is closed.
  final List<int> _preRoll = <int>[];
  bool _windowOpen = false;
  int _trailingSilence = 0;
  /// Count of speech (non-silence) samples accumulated since last flush.
  int _speechSamples = 0;

  int get _maxSamples => sampleRate * maxSeconds;
  int get _silenceSamples => (silenceMs * sampleRate / 1000).round();
  int get _minSamples => (minUtteranceMs * sampleRate / 1000).round();
  int get _minSpeechSamplesRequired => (minSpeechMs * sampleRate / 1000).round();
  int get _preRollSamples => (preRollMs * sampleRate / 1000).round();

  /// Current buffered sample count (exposed for tests / metrics).
  int get bufferedSamples => _samples.length;

  /// Pre-roll held while the window is closed (exposed for tests / metrics).
  int get preRollSamples => _preRoll.length;
  bool get isWindowOpen => _windowOpen;

  // --- button-window mode ---------------------------------------------------

  void openWindow() {
    _windowOpen = true;
    _samples
      ..clear()
      ..addAll(_preRoll); // the run-up to the tap, not silence
    _preRoll.clear();
    _trailingSilence = 0;
  }

  /// Append while a button window is open. Flushes in 30 s chunks if the wearer
  /// holds the button longer than the cap.
  ///
  /// While the window is closed the chunk feeds the pre-roll ring instead of
  /// being dropped, so [openWindow] can seed itself with what came just before.
  void addWindowed(Int16List chunk) {
    // Deliberately NOT gained. _transcribeSamples' silence gate is tuned for raw
    // button-window PCM (minRms 250, peak 650); lifting the window 8x would put
    // ordinary room silence above the threshold and send it to Gemma, which
    // answers conversationally instead of transcribing.
    if (!_windowOpen) {
      if (_preRollSamples <= 0) return;
      _preRoll.addAll(chunk);
      final excess = _preRoll.length - _preRollSamples;
      if (excess > 0) _preRoll.removeRange(0, excess);
      return;
    }
    _appendWithCap(chunk);
  }

  /// Close the window and emit whatever was captured (no min-length gate — an
  /// explicit press is always intentional).
  void closeWindow() {
    if (!_windowOpen) return;
    _windowOpen = false;
    _flush(enforceMin: false);
  }

  // --- continuous / VAD mode ------------------------------------------------

  void addContinuous(Int16List chunk) {
    // Two different gains on purpose: the VAD needs the signal lifted to make an
    // energy decision, the transcriber needs it undistorted. Sharing one knob is
    // what clipped phone-mic dictation.
    _appendWithCap(_applyGain(chunk, captureGain));
    if (_samples.isEmpty) return;
    final probe = _applyGain(chunk, vadPreGain);
    if (_rms(probe) < silenceRmsThreshold) {
      _trailingSilence += chunk.length;
      if (_trailingSilence >= _silenceSamples) {
        _flush(enforceMin: true);
      }
    } else {
      _trailingSilence = 0;
      _speechSamples += chunk.length;
    }
  }

  /// Force-emit any buffered audio (e.g. on stop / mode switch).
  void flushPending({bool enforceMin = false}) => _flush(enforceMin: enforceMin);

  void reset() {
    _samples.clear();
    _preRoll.clear();
    _windowOpen = false;
    _trailingSilence = 0;
    _speechSamples = 0;
  }

  // --- internals ------------------------------------------------------------

  void _appendWithCap(Int16List chunk) {
    _samples.addAll(chunk);
    // Emit full 30 s slices while over the cap so no utterance exceeds the limit.
    while (_samples.length >= _maxSamples) {
      final slice = Int16List.fromList(_samples.sublist(0, _maxSamples));
      _samples.removeRange(0, _maxSamples);
      _trailingSilence = 0;
      onUtterance(slice);
    }
  }

  void _flush({required bool enforceMin}) {
    _trailingSilence = 0;
    final speechCount = _speechSamples;
    _speechSamples = 0;
    if (_samples.isEmpty) return;
    if (enforceMin) {
      // Drop if total duration is below minimum.
      if (_samples.length < _minSamples) {
        _samples.clear();
        return;
      }
      // Drop if not enough detected speech content (avoids flushing silence
      // accumulations with only a brief noise spike at the start).
      if (speechCount < _minSpeechSamplesRequired) {
        _samples.clear();
        return;
      }
    }
    final out = Int16List.fromList(_samples);
    _samples.clear();
    onUtterance(out);
  }

  static double _rms(Int16List chunk) {
    if (chunk.isEmpty) return 0;
    var sumSquares = 0.0;
    for (final s in chunk) {
      sumSquares += s.toDouble() * s.toDouble();
    }
    return math.sqrt(sumSquares / chunk.length);
  }

  /// Apply a fixed gain to [chunk], clipping to int16 range [-32768, 32767].
  /// Returns a new [Int16List] — never mutates [chunk].
  static Int16List _applyGain(Int16List chunk, double gain) {
    if (gain == 1.0) return chunk;
    final out = Int16List(chunk.length);
    for (var i = 0; i < chunk.length; i++) {
      final scaled = (chunk[i] * gain).round();
      out[i] = scaled.clamp(-32768, 32767);
    }
    return out;
  }
}

// ---------------------------------------------------------------------------
// Gain normalization helper — pure function, no side effects.
// ---------------------------------------------------------------------------

/// Normalize the gain of [samples] (int16 PCM) so the peak amplitude is
/// approximately [targetPeak] (default 0.65 × 32767 ≈ 21299).
///
/// The computed gain factor is clamped to [maxGain] (default 20×) so that
/// pure-noise buffers with a very small peak are not blasted to full scale.
/// Samples are clipped to the int16 range [-32768, 32767] after scaling.
///
/// Returns a new [Int16List] — never mutates [samples].
Int16List normalizeGain(
  Int16List samples, {
  double targetPeak = 0.65 * 32767,
  double maxGain = 20.0,
}) {
  if (samples.isEmpty) return samples;

  // Find the peak absolute amplitude.
  var peak = 0;
  for (final s in samples) {
    final abs = s < 0 ? -s : s;
    if (abs > peak) peak = abs;
  }

  if (peak == 0) return samples; // pure silence — nothing to normalize

  final gain = (targetPeak / peak).clamp(1.0, maxGain);
  if (gain == 1.0) return Int16List.fromList(samples); // already loud enough

  final out = Int16List(samples.length);
  for (var i = 0; i < samples.length; i++) {
    final scaled = (samples[i] * gain).round();
    out[i] = scaled.clamp(-32768, 32767);
  }
  return out;
}

/// Compute the RMS amplitude of [samples] on the int16 PCM scale (0..32767).
double pcmRms(Int16List samples) {
  if (samples.isEmpty) return 0.0;
  var sumSquares = 0.0;
  for (final s in samples) {
    sumSquares += s.toDouble() * s.toDouble();
  }
  return math.sqrt(sumSquares / samples.length);
}
