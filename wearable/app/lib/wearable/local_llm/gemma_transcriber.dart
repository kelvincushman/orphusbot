// Copyright (c) 2025-2026 Kelvin Lee. Licensed under MIT.
//
// GemmaTranscriber — turns one utterance (<=30 s PCM16 mono) into cleaned text
// using the on-device Gemma 4 model. Audio is wrapped as a 16 kHz mono WAV (the
// self-describing format flutter_gemma/MediaPipe decode natively) via the app's
// existing WavBytesUtil, then sent as an audio Message.
//
// Inference is serialised — one clip at a time — because the native runtime
// holds a single model and concurrent sessions would contend for memory.

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_gemma/flutter_gemma.dart';

import '../services/vocabulary_store.dart';
import 'audio_buffer.dart' show normalizeGain;
import 'gemma_engine.dart';
import 'wav.dart';

class GemmaTranscriber {
  GemmaTranscriber._();
  static final GemmaTranscriber instance = GemmaTranscriber._();

  // The instruction is split so the wearer's personal dictionary can be spliced
  // in between the constraints and the output-format rules — see
  // [buildTranscriptionPrompt]. Concatenated head+tail is byte-identical to the
  // single string this replaces.
  static const String _promptHead =
      'You are a verbatim speech transcriber. Transcribe the attached audio to '
      'text in the original spoken language. Lightly clean the result: fix '
      'obvious disfluencies (um, uh, false starts, repeated words) and add '
      'natural punctuation and capitalization. Do NOT summarize, translate, '
      'answer questions, add commentary, or invent words that were not spoken. ';

  static const String _promptTail =
      'If the audio contains no intelligible speech, output exactly: [no speech]. '
      'Output only the transcript text and nothing else.';

  // Serialisation lane: each transcribe() chains after the previous one.
  Future<void> _tail = Future<void>.value();

  /// Transcribe a single utterance. Returns cleaned text, or '' when there is
  /// no intelligible speech. Clips longer than 30 s are truncated (the buffer
  /// should already segment to <=30 s; this is a safety net).
  Future<String> transcribe(Int16List samples, {int sampleRate = 16000}) {
    final result = _tail.then((_) => _run(samples, sampleRate));
    // Keep the lane alive regardless of success/failure of this call.
    _tail = result.then((_) {}, onError: (_) {});
    return result;
  }

  Future<String> _run(Int16List samples, int sampleRate) async {
    if (samples.isEmpty) return '';
    final maxSamples = sampleRate * 30;
    final clipped = samples.length > maxSamples ? samples.sublist(0, maxSamples) : samples;
    // FIX A: normalize gain so quiet wearable audio is audible to Gemma.
    final clip = normalizeGain(clipped);
    final wav = pcm16ToWav(clip, sampleRate);

    // Personal dictionary — a spelling hint, never a licence to insert. Reads
    // are cheap (SharedPreferences is an in-memory map after first load) and
    // never throw, so an unavailable store just means no hint this utterance.
    final prompt = buildTranscriptionPrompt(await VocabularyStore.promptWords());

    final model = await GemmaEngine.instance.ensureLoaded();
    // Deterministic decode (temperature 0, topK 1) — we want transcription, not
    // creative continuation. Fresh chat per utterance so prior audio context
    // doesn't bleed into the next transcript.
    final chat = await model.createChat(supportAudio: true, temperature: 0.0, topK: 1);

    try {
      await chat.addQueryChunk(Message.withAudio(text: prompt, audioBytes: wav, isUser: true));
      final response = await chat.generateChatResponse();
      final text = response is TextResponse ? response.token : '';
      // FIX C: reject non-transcript outputs from Gemma.
      return sanitizeTranscript(text);
    } finally {
      await chat.close();
    }
  }

}

// ---------------------------------------------------------------------------
// Prompt assembly — pure function, unit-testable.
// ---------------------------------------------------------------------------

/// Build the transcription instruction, biased toward the wearer's personal
/// dictionary.
///
/// [words] is the whole dictionary in insertion order; only the last
/// [VocabularyStore.promptCap] are used, so the newest words — the ones the
/// wearer just noticed being misheard — always make the cut. An empty list is a
/// no-op: the returned prompt is byte-identical to the one shipped before the
/// dictionary existed.
///
/// The hint is worded as a *spelling* instruction, not a vocabulary to draw
/// from, and repeats the no-invention rule at the point where the temptation to
/// break it is highest. It biases how a heard sound is written down; it does
/// not license writing down a word that was not heard.
String buildTranscriptionPrompt(List<String> words) {
  if (words.isEmpty) return GemmaTranscriber._promptHead + GemmaTranscriber._promptTail;
  final capped = words.length > VocabularyStore.promptCap
      ? words.sublist(words.length - VocabularyStore.promptCap)
      : words;
  return '${GemmaTranscriber._promptHead}'
      'The speaker often uses these names and terms: ${capped.join(', ')}. '
      'When you hear one of them, spell it exactly as written here. This list '
      'is a spelling guide only — never output a word from it that you did '
      'not hear. '
      '${GemmaTranscriber._promptTail}';
}

// ---------------------------------------------------------------------------
// FIX C: Output sanitization — pure function, unit-testable.
// ---------------------------------------------------------------------------

/// Phrases that indicate Gemma responded conversationally / couldn't decode
/// the audio rather than transcribing speech. Case-insensitive substring match.
const _kChatbotPhrases = [
  'verbatim speech transcriber',
  'attached audio to text',
  'you have not attached',
  'please provide the audio',
  "i'm able to help",
  'i cannot transcribe',
  'no audio file',
];

/// Exact-match (whole-transcript) ghost tokens Gemma emits when the audio is
/// silence/ambient noise rather than speech (e.g. background TV). These are
/// only dropped when they are the ENTIRE transcript — so a real sentence that
/// merely contains the word "student" is kept. Compared case-insensitively
/// after stripping surrounding punctuation/whitespace.
///
/// A personal-dictionary word can collide with one of these (a colleague named
/// "Bye", say). The collision only bites when that word is the ENTIRE
/// transcript, which is exactly the case a silence hallucination produces, so
/// the ghost filter still wins on purpose — see buildTranscriptionPrompt.
const _kGhostTokens = {
  'student',
  'you',
  'thank you',
  'thanks for watching',
  'thank you for watching',
  'bye',
  'okay',
  'ok',
  'so',
  'the',
  'yeah',
  'mm',
  'hmm',
  'uh',
  'um',
};

/// Return the cleaned transcript, or '' if [raw] is empty, equals `[no speech]`,
/// or contains any chatbot/prompt-echo phrase that signals Gemma did not
/// transcribe actual speech.
String sanitizeTranscript(String raw) {
  final trimmed = raw.trim();
  if (trimmed.isEmpty) return '';
  if (trimmed.toLowerCase() == '[no speech]') return '';
  final lower = trimmed.toLowerCase();
  for (final phrase in _kChatbotPhrases) {
    if (lower.contains(phrase)) return '';
  }
  // Drop whole-transcript ghost tokens (silence/ambient hallucinations).
  final stripped = lower.replaceAll(RegExp(r'[^a-z ]'), '').trim();
  if (_kGhostTokens.contains(stripped)) return '';
  return trimmed;
}
