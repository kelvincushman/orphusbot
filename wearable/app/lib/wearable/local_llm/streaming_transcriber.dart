// Copyright (c) 2025-2026 Kelvin Lee. Licensed under MIT.
//
// StreamingTranscriber — live text while the wearer is still speaking.
//
// This is the PREVIEW half of a two-model design. It decodes audio as it
// arrives, so text appears within a chunk or so of being spoken. What gets
// SAVED is not this: when the capture window closes, ZipformerTranscriber
// re-decodes the whole utterance offline and that transcript is the artifact.
//
// The split is measured, not stylistic. On the channel built from this
// firmware's own Opus settings plus reverb and babble, the offline model scores
// 11.19% WER and this streaming one 16.26% — about 45% more errors. That is
// tolerable in text you watch scroll past and correct as you speak; it is not
// tolerable in a note you keep and act on weeks later. Since the phone decodes
// offline at 46.73x realtime, running both costs headroom we demonstrably have.
//
// So: live text is feedback, the saved transcript is the record. They come from
// siblings (both zipformer, both 2023-06-26), so they rarely disagree
// dramatically, and where they do the saved one is the better of the two.
//
// Availability is optional throughout. If the streaming model is not installed
// the preview simply does not appear and capture behaves exactly as before —
// this must never be able to break transcription.

import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa;

import 'streaming_provisioner.dart';

class StreamingTranscriber {
  StreamingTranscriber._();
  static final StreamingTranscriber instance = StreamingTranscriber._();

  sherpa.OnlineRecognizer? _recognizer;
  sherpa.OnlineStream? _stream;
  Future<sherpa.OnlineRecognizer?>? _loading;

  /// Live text for the utterance in progress, '' when there is none.
  ///
  /// A ValueNotifier rather than a stream so the UI can rebuild from the
  /// current value on first frame without having missed anything.
  final ValueNotifier<String> partial = ValueNotifier<String>('');

  /// Text committed by endpoint detection during this capture, oldest first.
  ///
  /// A long note produces several of these as the speaker pauses. They are
  /// preview only — the saved transcript still comes from the offline pass.
  final List<String> _committed = <String>[];

  bool get isActive => _stream != null;

  /// Everything the preview decoded during the capture that just ended, ''
  /// when there was none (no live model installed, or nothing decoded).
  ///
  /// [stop] clears the working state, so without this the preview is gone by
  /// the time the offline pass finishes. TidyGate needs both transcripts of
  /// the same clip to measure how much the two decoders disagreed, and the
  /// offline one does not exist until after stop() has run.
  ///
  /// Consumed on read, and also cleared by [start]. Only a button capture
  /// runs the preview, but the offline pass also serves the SD backlog and
  /// continuous segmentation, neither of which ever calls [start]: a getter
  /// would hand every one of those utterances the last button clip's text
  /// and the gate would fire on all of them.
  String takeLastPreview() {
    final p = _lastPreview;
    _lastPreview = '';
    return p;
  }

  String _lastPreview = '';

  /// Everything decoded so far this capture: committed segments plus the
  /// in-progress one.
  String get text {
    final live = partial.value;
    final parts = [..._committed, if (live.isNotEmpty) live];
    return parts.join(' ').trim();
  }

  Future<sherpa.OnlineRecognizer?> _ensureLoaded() {
    final existing = _recognizer;
    if (existing != null) return Future<sherpa.OnlineRecognizer?>.value(existing);
    return _loading ??= _load();
  }

  Future<sherpa.OnlineRecognizer?> _load() async {
    try {
      final p = StreamingProvisioner.instance;
      if (!await p.isInstalled()) return null;

      sherpa.initBindings();
      final sw = Stopwatch()..start();
      final r = sherpa.OnlineRecognizer(sherpa.OnlineRecognizerConfig(
        model: sherpa.OnlineModelConfig(
          transducer: sherpa.OnlineTransducerModelConfig(
            encoder: await p.encoderPath(),
            decoder: await p.decoderPath(),
            joiner: await p.joinerPath(),
          ),
          tokens: await p.tokensPath(),
          numThreads: 1,
          provider: 'cpu',
          debug: false,
        ),
        // Endpointing splits the preview at natural pauses so the live line
        // does not grow without bound during a long note. It has no bearing on
        // what is saved.
        enableEndpoint: true,
        rule1MinTrailingSilence: 2.4,
        rule2MinTrailingSilence: 1.2,
        rule3MinUtteranceLength: 20,
      ));
      sw.stop();
      debugPrint('[Streaming] recognizer ready in ${sw.elapsedMilliseconds} ms');
      return _recognizer = r;
    } catch (e) {
      // A preview that fails to load must not take capture down with it.
      debugPrint('[Streaming] load failed: $e');
      return null;
    } finally {
      _loading = null;
    }
  }

  /// True when the model is installed and the preview can run.
  Future<bool> isAvailable() => StreamingProvisioner.instance.isInstalled();

  /// Begin a live utterance. Safe to call when already started.
  Future<void> start() async {
    if (_stream != null) return;
    final r = await _ensureLoaded();
    if (r == null) return;
    _committed.clear();
    partial.value = '';
    _lastPreview = '';
    _stream = r.createStream();
  }

  /// Feed PCM16 as it arrives from the wearable.
  ///
  /// Never throws: this runs on the audio path, and an exception here would
  /// take frames down with it.
  void accept(Int16List samples, {int sampleRate = 16000}) {
    final r = _recognizer;
    final s = _stream;
    if (r == null || s == null || samples.isEmpty) return;
    try {
      final f32 = Float32List(samples.length);
      for (var i = 0; i < samples.length; i++) {
        f32[i] = samples[i] / 32768.0;
      }
      s.acceptWaveform(samples: f32, sampleRate: sampleRate);

      while (r.isReady(s)) {
        r.decode(s);
      }

      final result = r.getResult(s).text.trim();
      if (r.isEndpoint(s)) {
        // Commit and reset so the next phrase decodes from a clean state.
        if (result.isNotEmpty) _committed.add(result);
        r.reset(s);
        partial.value = '';
      } else if (result != partial.value) {
        partial.value = result;
      }
    } catch (e) {
      debugPrint('[Streaming] accept failed: $e');
    }
  }

  /// End the live utterance and return everything decoded, for logging only.
  ///
  /// The caller does NOT save this. It exists so the preview can be compared
  /// against the offline transcript in the log, which is the only way to see
  /// the two models diverging on real audio rather than on a benchmark.
  String stop() {
    final s = _stream;
    final r = _recognizer;
    final out = text;
    if (s != null) {
      try {
        if (r != null) r.reset(s);
        s.free();
      } catch (e) {
        debugPrint('[Streaming] stop failed: $e');
      }
    }
    _stream = null;
    _committed.clear();
    partial.value = '';
    _lastPreview = out;
    return out;
  }

  /// Free the native recogniser. The next start() reloads it.
  void dispose() {
    stop();
    _recognizer?.free();
    _recognizer = null;
  }
}
