// Copyright (c) 2025-2026 Kelvin Lee. Licensed under MIT.
//
// ZipformerTranscriber — audio -> raw transcript, stage one of two.
//
// Replaces MoonshineTranscriber. Same two-stage shape (raw ASR here, LLM text
// polish in polish.dart); different first stage, for measured reasons recorded
// in docs/research/ASR_CANDIDATES.md.
//
// NO WINDOWING. This is the quiet win. Moonshine's graph fixed the input at
// exactly 5.000 s, so we had to split every clip ourselves and a word landing
// on a boundary could be clipped in both halves. Zipformer is a transducer over
// a streaming-style encoder and takes an utterance of any length, so the whole
// windowing apparatus — and the boundary-clipping limitation it carried — is
// deleted rather than reimplemented.
//
// Runs through sherpa_onnx, already in the APK for diarization. Like
// DiarizationEngine and OwnerVoice, every sherpa call is confined to this file
// so the rest of the app stays API-stable.
//
// NOTE on isolates: decode is a synchronous native FFI call on the calling
// isolate, the same constraint DiarizationEngine documents. At RTF ~0.02 on a
// laptop a 5 s clip is ~130 ms, so this is tolerable for now; it is the same
// TODO as diarization and should be fixed once for both.

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show debugPrint, visibleForTesting;
import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa;

import 'audio_buffer.dart' show normalizeGain;
import 'capture_diagnostics.dart';
import 'gemma_transcriber.dart' show sanitizeTranscript;
import 'punctuator.dart';
import 'zipformer_provisioner.dart';

class ZipformerTranscriber {
  ZipformerTranscriber._();
  static final ZipformerTranscriber instance = ZipformerTranscriber._();

  sherpa.OfflineRecognizer? _recognizer;
  sherpa.VoiceActivityDetector? _vad;
  Future<sherpa.OfflineRecognizer>? _loading;
  Future<void> _tail = Future<void>.value();

  /// Whether the model files are on disk. Cheap — a size check, not a hash.
  Future<bool> isInstalled() => ZipformerProvisioner.instance.isInstalled();

  Future<sherpa.OfflineRecognizer> _ensureLoaded() {
    final existing = _recognizer;
    if (existing != null) return Future<sherpa.OfflineRecognizer>.value(existing);
    return _loading ??= _load();
  }

  Future<sherpa.OfflineRecognizer> _load() async {
    final sw = Stopwatch()..start();
    try {
      sherpa.initBindings();
      final p = ZipformerProvisioner.instance;
      final config = sherpa.OfflineRecognizerConfig(
        model: sherpa.OfflineModelConfig(
          transducer: sherpa.OfflineTransducerModelConfig(
            encoder: await p.encoderPath(),
            decoder: await p.decoderPath(),
            joiner: await p.joinerPath(),
          ),
          tokens: await p.tokensPath(),
          // Two threads, matching DiarizationEngine. More contends with the
          // BLE/audio isolate for little gain at this model size.
          numThreads: 2,
          modelType: 'transducer',
          debug: false,
        ),
      );
      final r = sherpa.OfflineRecognizer(config);

      // Speech gate. Without this the ASR is handed whatever the button
      // captured — including silence — and invents plausible words to fit it.
      // On 2026-09-10 a button press with nobody speaking produced a person's
      // name from audio whose decoded level was 56. A blocklist cannot catch
      // that: you cannot enumerate the names a model might invent. The fix is
      // to not ask it.
      _vad = sherpa.VoiceActivityDetector(
        config: sherpa.VadModelConfig(
          sileroVad: sherpa.SileroVadModelConfig(
            model: await p.vadPath(),
            // The library default. This was raised to 0.6 to be conservative
            // against fabrication, back when the gate ran on raw -50 dBFS
            // audio; combined, those two choices discarded almost all real
            // speech. A false negative is not "one missed note the wearer can
            // repeat" — the wearer does not know it happened.
            threshold: 0.5,
            minSpeechDuration: 0.25,
            minSilenceDuration: 0.5,
            // Both were previously left to library defaults. windowSize is the
            // chunk _speechOnly feeds and the two must agree. maxSpeechDuration
            // defaults to 5 s, which force-splits anything longer — harmless
            // here because segments are concatenated again, but a capture cap
            // belongs in one place, not hidden in a default.
            windowSize: _vadWindow,
            maxSpeechDuration: 30.0,
          ),
          sampleRate: 16000,
          numThreads: 1,
        ),
        bufferSizeInSeconds: 30,
      );
      _recognizer = r;
      CaptureDiagnostics.instance.event('ASR ready in ${sw.elapsedMilliseconds} ms');
      return r;
    } finally {
      _loading = null;
    }
  }

  Future<void> dispose() async {
    final r = _recognizer;
    final v = _vad;
    _recognizer = null;
    _vad = null;
    r?.free();
    v?.free();
  }

  /// Transcribe one utterance of PCM16 mono. '' when there is no speech.
  Future<String> transcribe(Int16List samples, {int sampleRate = 16000}) {
    final result = _tail.then((_) => _run(samples, sampleRate));
    _tail = result.then((_) {}, onError: (_) {});
    return result;
  }

  Future<String> _run(Int16List samples, int sampleRate) async {
    if (samples.isEmpty) return '';
    final recognizer = await _ensureLoaded();

    // Normalise FIRST, then gate on the normalised clip.
    //
    // This used to run the other way round, on the theory that normalising
    // first would ask the VAD whether amplified noise looks like speech. That
    // reasoning was wrong: normalizeGain applies a single linear scale factor,
    // so it cannot change the ratio between noise and speech at all — it only
    // moves both to the level Silero was trained on. Gating raw audio cost us
    // 98% of a real 17 s capture (322 ms survived, and decoded to nothing),
    // because a chest mic delivers speech around -50 dBFS and the VAD simply
    // could not see it down there.
    //
    // What rejects a silent capture is unchanged and does not depend on level:
    // a button click is a ~30 ms transient, and minSpeechDuration keeps
    // anything under 250 ms out however loud it is.
    final clip = normalizeGain(samples);
    final ranges = _speechRanges(clip);
    if (ranges != null && ranges.isEmpty) {
      CaptureDiagnostics.instance.event('No speech in capture — not transcribed');
      debugPrint('[Zipformer] VAD found no speech; skipped');
      return '';
    }
    // Decode the speech, padded, not the window. With the VAD unavailable
    // (ranges == null) the whole clip goes through — never discard audio on a
    // broken gate.
    final speech = ranges == null
        ? clip
        : joinSpeechRanges(clip, ranges, pad: _padSamples);
    if (ranges != null) {
      debugPrint('[Zipformer] decoding ${speech.length * 1000 ~/ sampleRate}ms '
          'of ${clip.length * 1000 ~/ sampleRate}ms after padding');
    }

    final sw = Stopwatch()..start();
    final stream = recognizer.createStream();
    String text;
    try {
      stream.acceptWaveform(samples: _toFloat32(speech), sampleRate: sampleRate);
      recognizer.decode(stream);
      text = recognizer.getResult(stream).text;
    } finally {
      stream.free();
    }
    sw.stop();

    // The measurement that decides whether continuous capture is viable:
    // seconds of audio per second of wall clock. Below 1.0x it cannot keep up
    // with live speech. Logged on every utterance so the answer accumulates
    // from real use rather than needing a special harness.
    final audioMs = (speech.length * 1000) ~/ sampleRate;
    final rt = sw.elapsedMilliseconds == 0
        ? double.infinity
        : audioMs / sw.elapsedMilliseconds;
    final line = 'ASR ${audioMs}ms audio in ${sw.elapsedMilliseconds}ms '
        '(${rt.toStringAsFixed(2)}x realtime)';
    debugPrint('[Zipformer] $line');
    CaptureDiagnostics.instance.event(line);

    // Sanitise BEFORE punctuating, not after. The ghost-token and
    // chatbot-phrase filters match on the text stripped to bare letters, so
    // they must see the recogniser's own words: a comma landing inside
    // "thank you for watching" would carry a hallucination past the filter
    // that exists to catch it. Sanitising first also means a discarded clip
    // never pays for the punctuation pass.
    final clean = sanitizeTranscript(text);
    if (clean.isEmpty) return '';
    return Punctuator.instance.restore(clean, audioMs: audioMs);
  }

  /// Padding kept on each side of a VAD segment before decoding: 300 ms.
  ///
  /// VAD boundaries land inside word onsets and releases; a few hundred ms
  /// keeps the edges of speech at the cost of a few hundred ms of noise per
  /// segment — against the 15-20 s of noise a whole continuous window carries.
  static const int _padSamples = 4800;

  /// Where the speech is in [samples], as [start, end) sample ranges — empty
  /// when there is none, null when the VAD is unavailable.
  ///
  /// This has been a segmenter, then a gate, and is a segmenter again, and the
  /// history matters because each reversal was for a measured reason:
  ///
  ///  - It trimmed first, and a driver bug (whole buffer in one call, queue
  ///    drained too late) made it return a constant 322 ms whatever the input.
  ///    A 17 s note became an empty transcript. The trimming took the blame
  ///    and it became a yes/no gate with the whole clip decoded, on the
  ///    argument that a transducer emits blanks over silence.
  ///  - That argument is right about silence and wrong about noise. Once
  ///    continuous capture became the default, windows were 20-30 s of
  ///    amplified room with a few seconds of speech in them, and the
  ///    recogniser turned the room into words: one window decoded 40 words
  ///    from 4.2 s of speech — three times faster than anyone talks.
  ///
  /// The driver bug is fixed (the segment counts below are real and vary with
  /// the audio), so the reason for decoding the whole clip is gone and the
  /// reason for not doing so is back. Segments are padded (see [_padSamples])
  /// so the earlier failure — clipped word edges — cannot recur, and the
  /// VAD-unavailable case still decodes everything.
  List<(int, int)>? _speechRanges(Int16List samples) {
    final vad = _vad;
    if (vad == null) return null; // gate unavailable: never discard audio
    vad.reset();

    // Feed in windowSize chunks and drain the segment queue as we go.
    //
    // The whole buffer used to go in with a single acceptWaveform call, which
    // is what the package's own doc comment shows. It produced exactly 322 ms
    // of "speech" from a 17 s capture and again from a 30 s capture — the same
    // number from different audio, which is not a detection result, it is a
    // constant. sherpa's detector is a streaming one: it consumes windowSize
    // at a time and pushes completed segments onto a queue. Draining that
    // queue only after the whole buffer has gone in leaves segments to be
    // dropped rather than collected.
    final f32 = _toFloat32(samples);
    final ranges = <(int, int)>[];
    var kept = 0; // samples of detected speech

    void drain() {
      while (!vad.isEmpty()) {
        final seg = vad.front();
        ranges.add((seg.start, seg.start + seg.samples.length));
        kept += seg.samples.length;
        vad.pop();
      }
    }

    for (var i = 0; i < f32.length; i += _vadWindow) {
      final end = (i + _vadWindow) < f32.length ? i + _vadWindow : f32.length;
      vad.acceptWaveform(Float32List.sublistView(f32, i, end));
      drain();
    }
    vad.flush();
    drain();

    debugPrint('[Zipformer] VAD ${ranges.length} segment(s), '
        '${kept * 1000 ~/ 16000}ms speech in '
        '${samples.length * 1000 ~/ 16000}ms capture');

    return ranges;
  }

  /// [src] restricted to [ranges], each widened by [pad] samples on both
  /// sides, clamped to the clip, merged where they touch, in order.
  ///
  /// Pure and public for tests: a bug here silently decodes the wrong audio.
  @visibleForTesting
  static Int16List joinSpeechRanges(Int16List src, List<(int, int)> ranges, {required int pad}) {
    if (ranges.isEmpty || src.isEmpty) return Int16List(0);
    final sorted = [...ranges]..sort((a, b) => a.$1.compareTo(b.$1));
    final merged = <(int, int)>[];
    for (final (s0, e0) in sorted) {
      final s = (s0 - pad).clamp(0, src.length);
      final e = (e0 + pad).clamp(0, src.length);
      if (e <= s) continue;
      if (merged.isNotEmpty && s <= merged.last.$2) {
        final last = merged.removeLast();
        merged.add((last.$1, e > last.$2 ? e : last.$2));
      } else {
        merged.add((s, e));
      }
    }
    final total = merged.fold<int>(0, (n, r) => n + (r.$2 - r.$1));
    final out = Int16List(total);
    var k = 0;
    for (final (s, e) in merged) {
      out.setRange(k, k + (e - s), src, s);
      k += e - s;
    }
    return out;
  }

  /// Silero v5's frame size at 16 kHz. Must match SileroVadModelConfig.
  static const int _vadWindow = 512;

  /// PCM16 -> float32 in [-1, 1], which is what sherpa's waveform API takes.
  static Float32List _toFloat32(Int16List samples) {
    final out = Float32List(samples.length);
    for (var i = 0; i < samples.length; i++) {
      out[i] = samples[i] / 32768.0;
    }
    return out;
  }
}
