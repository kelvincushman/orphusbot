// Copyright (c) 2025-2026 Kelvin Lee. Licensed under MIT.
//
// VocabularyStore — the wearer's personal dictionary: colleague names, project
// words and jargon the recogniser hears every day. Entries are folded into the
// Gemma transcription prompt as a spelling guide (see gemma_transcriber.dart).
//
// Persistence is one JSON array under one SharedPreferences key. That is the
// boring choice on purpose: a list of short strings, read once per utterance
// and written only when the user taps + or the trash icon. A database would be
// more machinery than the data deserves.

import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Categories a word can be filed under. Fixed set — Eloquent's "Learned from
/// edits" is deliberately absent because nothing in this app learns from edits
/// yet; inventing the label would be a lie in the UI.
///
/// ponytail: no custom-category creation. Ceiling: a user whose vocabulary
/// doesn't split along these four lines has to file words under `Terms` or
/// leave them uncategorised. Adding free-text categories is a text field and a
/// de-dup, whenever someone actually asks.
const List<String> kVocabularyCategories = <String>[
  'Projects',
  'Coworkers',
  'Places',
  'Terms',
];

/// One dictionary entry: a word plus an optional grouping category.
@immutable
class VocabularyEntry {
  const VocabularyEntry({required this.word, this.category});

  /// The word or phrase as it should be spelled. Never empty.
  final String word;

  /// One of [kVocabularyCategories], or null when uncategorised.
  final String? category;

  Map<String, Object?> toJson() => <String, Object?>{
    'w': word,
    if (category != null) 'c': category,
  };

  /// Returns null when [raw] is not a usable entry (wrong shape, blank word).
  static VocabularyEntry? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final word = VocabularyStore.normalize(raw['w'] is String ? raw['w'] as String : '');
    if (word.isEmpty) return null;
    final category = raw['c'];
    return VocabularyEntry(
      word: word,
      category: category is String && kVocabularyCategories.contains(category) ? category : null,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is VocabularyEntry && other.word == word && other.category == category;

  @override
  int get hashCode => Object.hash(word, category);
}

class VocabularyStore {
  VocabularyStore._();

  static const String storageKey = 'wearable.vocabulary';

  /// How many words may ride along in a transcription prompt.
  ///
  /// A name or term costs roughly three tokens including its separator, so 60
  /// words is ~180 tokens on top of a ~90-token base instruction. A full 30 s
  /// clip is already ~750 audio tokens, and short clips are far less — past
  /// this the hint starts to outweigh the audio it is meant to help decode.
  /// Everything above the cap still persists and still shows in the UI; only
  /// the 60 most recently added words are sent (see [promptWords]).
  static const int promptCap = 60;

  /// Longest single entry we keep. Names and jargon are short; the limit stops
  /// one pasted paragraph from dominating every prompt.
  static const int maxWordLength = 64;

  /// All entries, oldest first (insertion order).
  static Future<List<VocabularyEntry>> entries() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return decode(prefs.getString(storageKey));
    } catch (_) {
      // Prefs unavailable (plugin not registered, corrupt store) — an empty
      // dictionary is always a safe answer.
      return const <VocabularyEntry>[];
    }
  }

  /// Words in the order they were added, for [buildTranscriptionPrompt] to cap.
  /// Never throws: transcription must not fail because the dictionary did.
  static Future<List<String>> promptWords() async =>
      (await entries()).map((e) => e.word).toList(growable: false);

  /// Add [word] under an optional [category]. Returns false when the word is
  /// blank or already present (case-insensitive), leaving the store untouched.
  static Future<bool> add(String word, {String? category}) async {
    final clean = normalize(word);
    if (clean.isEmpty) return false;
    final current = await entries();
    final lower = clean.toLowerCase();
    if (current.any((e) => e.word.toLowerCase() == lower)) return false;
    final next = <VocabularyEntry>[
      ...current,
      VocabularyEntry(
        word: clean,
        category: kVocabularyCategories.contains(category) ? category : null,
      ),
    ];
    await _write(next);
    return true;
  }

  /// Remove the entry whose word matches [word] case-insensitively.
  static Future<void> remove(String word) async {
    final lower = normalize(word).toLowerCase();
    final current = await entries();
    final next = current.where((e) => e.word.toLowerCase() != lower).toList();
    if (next.length == current.length) return;
    await _write(next);
  }

  /// Trim, collapse all whitespace (newlines included) to single spaces, and
  /// clamp to [maxWordLength].
  ///
  /// ponytail: this is the whole sanitiser. Ceiling: a user can still type a
  /// full sentence into a dictionary entry and thereby steer the transcription
  /// prompt. It is their device, their dictionary and their prompt, so we
  /// collapse the layout-breaking characters and stop there.
  static String normalize(String raw) {
    final collapsed = raw.trim().replaceAll(RegExp(r'\s+'), ' ');
    return collapsed.length > maxWordLength ? collapsed.substring(0, maxWordLength).trim() : collapsed;
  }

  /// Parse the persisted JSON. Anything unparseable yields an empty list rather
  /// than throwing — a broken dictionary must not break transcription.
  static List<VocabularyEntry> decode(String? raw) {
    if (raw == null || raw.isEmpty) return const <VocabularyEntry>[];
    try {
      final parsed = jsonDecode(raw);
      if (parsed is! List) return const <VocabularyEntry>[];
      return parsed
          .map(VocabularyEntry.fromJson)
          .whereType<VocabularyEntry>()
          .toList(growable: false);
    } catch (_) {
      return const <VocabularyEntry>[];
    }
  }

  static Future<void> _write(List<VocabularyEntry> entries) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(storageKey, jsonEncode(entries.map((e) => e.toJson()).toList()));
  }
}
