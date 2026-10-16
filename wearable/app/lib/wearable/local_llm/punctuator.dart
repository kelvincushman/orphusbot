// Copyright (c) 2025-2026 Kelvin Lee. Licensed under MIT.
//
// Punctuator — casing and punctuation for a finished transcript.
//
// The recogniser hands us `JEST LOOKIN SEE IF I NEEDER HAD A DIARIN`. This
// turns it into `Jest lookin, see if I needer had a diarin`. It does not fix
// the mishearings — that is Gemma's job in polish.dart, and Gemma costs 2.6 GB
// and seconds. This costs 7 MB and milliseconds, so it runs on every note.
//
// Optional throughout. If the model is not installed, or loading fails, or the
// native call throws, every path returns the input unchanged. Nothing here may
// be able to lose a transcript.

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa;

import 'punctuation_provisioner.dart';

/// Whether [output] is [input] with only casing and punctuation changed.
///
/// The guard that lets this run unsupervised on saved notes. The model is a
/// tagger, not a generator, so in principle it can only insert marks and flip
/// case — but "in principle" is how the fabricated-name incident happened
/// (see ZipformerTranscriber._containsSpeech). Reducing both sides to their
/// bare letters and digits and comparing is cheap, total, and testable without
/// the model; anything that fails it is discarded in favour of the input.
bool preservesWords(String input, String output) => _bareWords(input) == _bareWords(output);

String _bareWords(String s) => s
    .toLowerCase()
    .replaceAll(RegExp(r'[^a-z0-9]+'), ' ')
    .trim();

class Punctuator {
  Punctuator._();
  static final Punctuator instance = Punctuator._();

  sherpa.OnlinePunctuation? _punct;
  Future<sherpa.OnlinePunctuation?>? _loading;
  Future<void> _tail = Future<void>.value();

  /// Whether the model files are on disk. Cheap — a size check, not a hash.
  Future<bool> isInstalled() => PunctuationProvisioner.instance.isInstalled();

  /// Restore casing and punctuation in [text], or return it unchanged.
  ///
  /// Calls are serialised the way ZipformerTranscriber serialises decodes: the
  /// native call is synchronous FFI on the calling isolate, so overlapping
  /// callers would block each other anyway and a shared handle is not
  /// documented as reentrant.
  ///
  /// [audioMs] is the duration of the clip this text came from, when the caller
  /// knows it. It buys nothing but the log line — and that log line is the
  /// number that decides whether this stays always-on.
  Future<String> restore(String text, {int? audioMs}) {
    final result = _tail.then((_) => _run(text, audioMs));
    _tail = result.then((_) {}, onError: (_) {});
    return result;
  }

  Future<String> _run(String text, int? audioMs) async {
    if (text.trim().isEmpty) return text;
    try {
      final punct = await _ensureLoaded();
      if (punct == null) return text;

      final sw = Stopwatch()..start();
      // Lowercase FIRST. Measured on 2026-09-11 against the pinned model: fed
      // `JEST LOOKIN SEE IF I NEEDER HAD A DIARIN` it returns that string
      // untouched, and fed the same words lowercased it returns
      // `Jest lookin, see if I needer had a diarin`. The BPE vocabulary is
      // lowercase unigram, so upper-case input simply tokenises to nothing the
      // tagger recognises. Nothing is lost by folding: the recogniser's output
      // is upper-case throughout, so it carries no case information to destroy.
      final out = punct.addPunct(text.toLowerCase());
      sw.stop();

      if (out.trim().isEmpty || !preservesWords(text, out)) {
        debugPrint('[Punctuator] output rejected (words changed); keeping raw text');
        return text;
      }

      final words = _bareWords(text).split(' ').length;
      final rtf = (audioMs == null || audioMs == 0)
          ? ''
          : ' (${(audioMs / (sw.elapsedMilliseconds == 0 ? 1 : sw.elapsedMilliseconds)).toStringAsFixed(1)}x realtime)';
      debugPrint('[Punctuator] $words words in ${sw.elapsedMilliseconds}ms$rtf');
      return out;
    } catch (e) {
      // Never throw: a transcript that reads badly beats no transcript.
      debugPrint('[Punctuator] unavailable ($e); keeping raw text');
      return text;
    }
  }

  Future<sherpa.OnlinePunctuation?> _ensureLoaded() {
    final existing = _punct;
    if (existing != null) return Future<sherpa.OnlinePunctuation?>.value(existing);
    return _loading ??= _load();
  }

  Future<sherpa.OnlinePunctuation?> _load() async {
    try {
      final p = PunctuationProvisioner.instance;
      if (!await p.isInstalled()) return null;

      sherpa.initBindings();
      final sw = Stopwatch()..start();
      final punct = sherpa.OnlinePunctuation(
        config: sherpa.OnlinePunctuationConfig(
          model: sherpa.OnlinePunctuationModelConfig(
            cnnBiLstm: await p.modelPath(),
            bpeVocab: await p.bpeVocabPath(),
            // One thread: this runs after the ASR has finished and takes tens
            // of milliseconds, so it has nothing to gain from contending with
            // the BLE/audio isolate.
            numThreads: 1,
            provider: 'cpu',
            debug: false,
          ),
        ),
      );
      debugPrint('[Punctuator] ready in ${sw.elapsedMilliseconds}ms');
      return _punct = punct;
    } catch (e) {
      debugPrint('[Punctuator] load failed ($e); transcripts stay as recognised');
      return null;
    } finally {
      _loading = null;
    }
  }

  Future<void> dispose() async {
    final p = _punct;
    _punct = null;
    p?.free();
  }
}
