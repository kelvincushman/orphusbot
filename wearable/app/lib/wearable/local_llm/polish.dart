// Copyright (c) 2025-2026 Kelvin Lee. Licensed under MIT.
//
// Polish — a SECOND Gemma pass over text that GemmaTranscriber already
// produced. The transcriber owns audio -> lightly-cleaned text; this file owns
// text -> text in a chosen tone (the Eloquent "Polish / Key points / Formal /
// Short" chips). Separate prompt, separate file, no audio.
//
// Everything here treats the model as untrusted: a model asked to rewrite can
// refuse, echo the instructions back, wrap the answer in a preamble, or answer
// the question it just read. [sanitizePolish] rejects those, and
// [polishTranscript] falls back to the original transcript rather than ever
// returning something worse than what it was given.
//
// Inference is serialised — one rewrite at a time — for the same reason
// GemmaTranscriber serialises: the native runtime holds a single model and
// concurrent sessions contend for memory.

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter_gemma/flutter_gemma.dart';

import '../services/vocabulary_store.dart';
import 'gemma_engine.dart';

/// The four Eloquent tone chips, plus [tidy].
///
/// [tidy] is not a chip. It is the automatic pass the capture path runs behind
/// the TidyGate, and it is deliberately the most constrained tone in the file:
/// nobody is watching its output before it replaces a saved note.
enum PolishTone {
  polish('Polish'),
  keyPoints('Key points'),
  formal('Formal'),
  short('Short'),
  tidy('Tidy');

  const PolishTone(this.label);

  /// Chip label.
  final String label;
}

/// The tones a user picks by hand, in chip order. Separate from
/// `PolishTone.values` so adding an automatic tone cannot silently grow the
/// dictation page's chip row.
const List<PolishTone> kPolishChips = [
  PolishTone.polish,
  PolishTone.keyPoints,
  PolishTone.formal,
  PolishTone.short,
];

/// Outcome of one rewrite. [polished] is false when [text] is the untouched
/// input — in that case [note] says why, so the UI can be honest about it.
class PolishResult {
  const PolishResult._(this.text, this.polished, this.note);

  /// The model rewrote the transcript and the result passed sanitization.
  const PolishResult.rewritten(String text) : this._(text, true, null);

  /// Polish did not produce anything usable; [text] is the original transcript.
  const PolishResult.original(String text, String note) : this._(text, false, note);

  final String text;
  final bool polished;
  final String? note;
}

/// Injection seam for tests — takes a full prompt, returns raw model output.
typedef PolishGenerator = Future<String> Function(String prompt);

// ---------------------------------------------------------------------------
// Prompts — pure, so the wording is unit-testable.
// ---------------------------------------------------------------------------

/// Constraints appended to every tone. Kept in one place so a tone can only
/// differ in its instruction, never in its guard rails.
const String kPolishRules =
    'Rules: write in the same language as the transcript; keep the speaker\'s '
    'own meaning, facts and requests; never answer a question found in the '
    'transcript, never add information, never address the reader; never add a '
    'title, preamble or explanation. Output only the rewritten text and '
    'nothing else.';

/// Extra constraints for [PolishTone.tidy], on top of [kPolishRules].
///
/// LatentASR (arXiv 2607.05051) Table 13 shows its frozen Qwen3-ASR baseline
/// prepending discourse openings that were never spoken — reference "Madame
/// President, the directive on services...", output "Thank you, Madame
/// President, the directive...". The authors state the fix is discourse-level,
/// not acoustic. That is a *systematic* property of an autoregressive model
/// writing text over text, and a tidy pass is exactly that. So the rule
/// against it is written into the prompt rather than left to the model's
/// discretion, and [tidyWordCeiling] enforces it again on the way out.
const String kTidyRules =
    'Do not add an opening, greeting, salutation, closing or sign-off that is '
    'not already in the transcript. Do not add sentences, clauses or words '
    'that are not in the transcript. Do not summarise, shorten, reorder or '
    'explain. Change only capitalisation, punctuation, and a word that was '
    'clearly misheard where the surrounding words make the intended word '
    'unambiguous. If nothing needs fixing, output the transcript unchanged.';

const Map<PolishTone, String> _kToneInstructions = {
  PolishTone.polish:
      'Rewrite the dictated transcript below as clean written prose. Remove '
          'filler words, false starts and mid-sentence self-corrections so that '
          'only what the speaker meant to say remains. Fix punctuation, '
          'capitalization and paragraph breaks. Keep roughly the same length.',
  PolishTone.keyPoints:
      'Condense the dictated transcript below into its key points. Output a '
          'bullet list, one point per line, each line starting with "- ", at most '
          'eight lines. Include only points the speaker actually made.',
  PolishTone.formal:
      'Rewrite the dictated transcript below in a formal, professional register '
          'suitable for a written business message. Remove filler and slang, use '
          'complete sentences, and keep the content unchanged.',
  PolishTone.short:
      'Rewrite the dictated transcript below so it says the same thing in as few '
          'words as possible. Keep every fact and request; drop repetition, '
          'filler and hedging. Aim for at most half the original length.',
  PolishTone.tidy:
      'Correct the speech-recognition transcript below. It was produced by a '
          'recogniser that writes in capitals with no punctuation, and it may '
          'contain words that sound like what was said but are not it.',
};

/// Names and jargon the rewrite must not "correct".
///
/// The personal dictionary biases transcription so a heard sound is written the
/// way the wearer spells it. Polish then rewrites that text with no knowledge of
/// the list, and happily turns "LiteRT" into "Lite RT" — undoing, on the last
/// hop, the one feature the wearer maintains by hand. The text they read and
/// copy is the polished one, so the dictionary's whole effect was reversible
/// with nothing on screen to say so.
String vocabularyClause(List<String> words) {
  if (words.isEmpty) return '';
  final capped = words.length > VocabularyStore.promptCap
      ? words.sublist(words.length - VocabularyStore.promptCap)
      : words;
  return ' Leave these spellings exactly as they appear, including their '
      'capitalisation and spacing: ${capped.join(', ')}.';
}

/// The exact prompt sent to Gemma for [tone] over [transcript].
String polishPrompt(PolishTone tone, String transcript, {List<String> vocabulary = const <String>[]}) {
  final rules = tone == PolishTone.tidy ? '$kPolishRules $kTidyRules' : kPolishRules;
  return '${_kToneInstructions[tone]}\n\n$rules${vocabularyClause(vocabulary)}'
      '\n\nTranscript:\n$transcript';
}

// ---------------------------------------------------------------------------
// Rewrite
// ---------------------------------------------------------------------------

// Serialisation lane: each polishTranscript() chains after the previous one.
//
// ponytail: this is a SECOND lane — GemmaTranscriber has its own private one —
// so a polish and a transcription can still overlap on the single native model.
// The dictation flow is record -> transcribe -> polish, strictly sequential, so
// it does not bite today. The real fix is one shared lane owned by GemmaEngine;
// that is a change to a file this lane does not own.
Future<void> _tail = Future<void>.value();

/// Rewrite [transcript] in [tone] using the on-device model.
///
/// Never returns text worse than the input: on any failure — model error,
/// refusal, prompt echo, runaway length — the result carries the original
/// transcript with `polished == false` and a [PolishResult.note] explaining it.
///
/// [generate] is the injection seam for tests; production callers omit it.
Future<PolishResult> polishTranscript(
  String transcript,
  PolishTone tone, {
  PolishGenerator? generate,
  List<String> vocabulary = const <String>[],
}) {
  final result = _tail.then((_) => _run(transcript, tone, generate ?? _gemmaGenerate, vocabulary));
  // Keep the lane alive regardless of success/failure of this call.
  _tail = result.then((_) {}, onError: (_) {});
  return result;
}

Future<PolishResult> _run(String transcript, PolishTone tone, PolishGenerator generate,
    List<String> vocabulary) async {
  if (transcript.trim().isEmpty) {
    return PolishResult.original(transcript, 'Nothing to polish.');
  }
  String raw;
  try {
    raw = await generate(polishPrompt(tone, transcript, vocabulary: vocabulary));
  } catch (_) {
    return PolishResult.original(transcript, 'On-device polish failed — showing the transcript as recorded.');
  }
  // The tidy tone is the only one that runs unattended, so it is the only one
  // that gets a word ceiling on top of the shared character cap.
  final cleaned = sanitizePolish(
    raw,
    original: transcript,
    maxWords: tone == PolishTone.tidy ? tidyWordCeiling(countWords(transcript)) : null,
  );
  if (cleaned == null) {
    return PolishResult.original(transcript, 'Polish result looked wrong — showing the transcript as recorded.');
  }
  return PolishResult.rewritten(cleaned);
}

/// Production generator — one fresh deterministic chat per rewrite, mirroring
/// GemmaTranscriber. Fresh chat so the previous tone's output cannot bleed in.
Future<String> _gemmaGenerate(String prompt) async {
  final model = await GemmaEngine.instance.ensureLoaded();
  final chat = await model.createChat(temperature: 0.0, topK: 1);
  try {
    await chat.addQueryChunk(Message.text(text: prompt, isUser: true));
    final response = await chat.generateChatResponse();
    return response is TextResponse ? response.token : '';
  } finally {
    await chat.close();
  }
}

// ---------------------------------------------------------------------------
// Output sanitization — pure function, unit-testable.
// ---------------------------------------------------------------------------

/// The model declining, or narrating itself, instead of rewriting.
/// Case-insensitive substring match.
const _kRefusalPhrases = [
  'as an ai',
  'as a language model',
  'i cannot',
  "i can't",
  'i am unable',
  "i'm unable",
  'i am not able',
  'sorry, i',
];

/// Fragments of our own prompt coming back — the model echoed instead of
/// rewriting. Case-insensitive substring match.
const _kEchoPhrases = [
  'rewrite the dictated transcript',
  'condense the dictated transcript',
  'the dictated transcript below',
  'output only the rewritten text',
  'write in the same language as the transcript',
];

/// A single meta line the model likes to open with ("Sure, here is the polished
/// version:"). Only stripped when real content follows it.
final _kPreambleLine = RegExp(
  r"^(sure|okay|ok|certainly|of course|here'?s?|here is|here are)\b[^\n]{0,80}:\s*$",
  caseSensitive: false,
);

/// Return the usable rewrite of [raw], or null when the model misbehaved and
/// the caller should keep [original].
///
/// Rejects: empty output, refusals, prompt echoes, runaway expansion (a
/// rewrite that balloons past twice the input is the model answering or
/// inventing, not rewriting), and — when [maxWords] is given — a rewrite that
/// grew past that word count. Strips a markdown code fence and a single
/// meta preamble line, which are formatting noise rather than misbehaviour.
/// Lowercase, drop everything that is not a letter, digit or space, and collapse
/// runs of whitespace. Lets a refusal phrase be compared against transcript and
/// rewrite alike without punctuation or capitalisation deciding the answer.
String _flatten(String s) => s
    .toLowerCase()
    .replaceAll(RegExp(r'[^a-z0-9 ]'), '')
    .replaceAll(RegExp(r'\s+'), ' ')
    .trim();

/// Words in [text], counted the way [sanitizePolish] compares them: lowercase
/// alphanumeric runs, punctuation ignored.
int countWords(String text) => _flatten(text).split(' ').where((w) => w.isNotEmpty).length;

/// The most words a [PolishTone.tidy] rewrite may contain, given [inputWords].
///
/// The rule is input + 10%. The floor of two extra words exists because
/// splitting a run-together mishearing is a legitimate tidy — "A DIARIN" ->
/// "a diary in" adds two words — and 10% of a ten-word note is one word, so a
/// pure ratio would reject the repair the pass exists to make.
///
/// Integer arithmetic on purpose: `(100 * 1.1).ceil()` is 111, because 110.0
/// is not representable. A ceiling that drifts by a word with the input length
/// is not a ceiling anyone can reason about.
int tidyWordCeiling(int inputWords) =>
    math.max(inputWords + 2, inputWords + inputWords ~/ 10);

String? sanitizePolish(String raw, {required String original, int? maxWords}) {
  var text = _stripCodeFence(raw.trim());
  text = _stripPreamble(text);
  if (text.isEmpty) return null;

  final lower = text.toLowerCase();
  // Compared with punctuation and case stripped, because adding punctuation is
  // precisely what polish does: the wearer says "sorry i cant make tuesday" and
  // the model returns "Sorry, I can't make Tuesday." A raw substring comparison
  // never matches those two, so it would reject the very case it exists to
  // allow.
  final flatText = _flatten(text);
  final flatOriginal = _flatten(original);
  for (final phrase in _kRefusalPhrases) {
    // Only a refusal if the MODEL introduced it. "Sorry, I can't make Tuesday"
    // is an ordinary thing to dictate, and a rewrite that keeps it is doing its
    // job. Matching the phrase anywhere in the output silently disabled polish
    // for a whole class of everyday messages -- and told the user the model had
    // misbehaved when it had not.
    final flatPhrase = _flatten(phrase);
    if (flatText.contains(flatPhrase) && !flatOriginal.contains(flatPhrase)) {
      return null;
    }
  }
  for (final phrase in _kEchoPhrases) {
    if (lower.contains(phrase)) return null;
  }

  // Runaway expansion. The floor keeps very short dictations (a one-line note)
  // from tripping the ratio on a legitimately punctuated rewrite.
  if (text.length > math.max(original.length * 2, 240)) return null;

  // Word ceiling — tidy only. The character cap above is generous enough that
  // an invented "Thank you, Madame President" opening slips under it on any
  // note of ordinary length; counting words catches the sentence that the
  // character budget hides.
  if (maxWords != null && countWords(text) > maxWords) return null;

  return text;
}

String _stripCodeFence(String text) {
  if (!text.startsWith('```') || !text.endsWith('```')) return text;
  final lines = text.split('\n');
  if (lines.length < 3) return text;
  return lines.sublist(1, lines.length - 1).join('\n').trim();
}

String _stripPreamble(String text) {
  final newline = text.indexOf('\n');
  if (newline < 0) return text;
  final first = text.substring(0, newline).trim();
  if (!_kPreambleLine.hasMatch(first)) return text;
  final rest = text.substring(newline + 1).trim();
  return rest.isEmpty ? text : rest;
}
