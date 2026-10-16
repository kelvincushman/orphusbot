// Copyright (c) 2025-2026 Kelvin Lee. Licensed under MIT.
//
// OnDeviceTranscriptLog — in-memory store for on-device transcripts.
// Exposes a ValueListenable so UI widgets (ValueListenableBuilder) react to
// new entries without polling. The singleton is populated by both
// WearableDeviceBridge (wearable path) and PhoneMicStreamer (phone-mic path).
//
// Persistence is intentionally omitted in v1; entries live only for the
// duration of the app session.

import 'package:flutter/foundation.dart';

/// A single on-device transcript entry.
@immutable
class TranscriptEntry {
  const TranscriptEntry({
    required this.id,
    required this.text,
    required this.at,
    required this.overheard,
    this.talker,
    this.clipId,
    this.clusterIndex,
    this.embedding,
    this.durationS = 0,
    this.profileId,
    this.isTidied = false,
  });

  /// Stable handle for this entry, assigned by [OnDeviceTranscriptLog.add].
  ///
  /// ULID-ish: base-36 microseconds since the epoch plus a counter, so it
  /// sorts by creation time and stays unique when two entries land in the same
  /// microsecond (a diarized clip logs several at once). Exists so work that
  /// finishes after the entry is already on screen — the tidy pass — can find
  /// the right line again. Index and text are both unsafe for that: the list
  /// is capped and newest-first, and the text is what the tidy pass changes.
  final String id;

  /// The transcribed text (never empty).
  final String text;

  /// Wall-clock time when the entry was added.
  final DateTime at;

  /// True when the audio came from ambient/continuous capture (phone mic or
  /// wearable continuous mode) rather than an explicit button press.
  final bool overheard;

  /// Speaker label shown in the UI — a registry name, or 'Talker N'.
  /// Null when diarization is unavailable.
  final String? talker;

  /// Identity evidence, so a tap on the label can name this voice and relabel
  /// every line from the same speaker in the same clip without re-running
  /// anything. [clipId] groups one capture; [clusterIndex] is the diarizer's
  /// per-clip speaker index; [embedding] is that cluster's pooled speaker
  /// vector over [durationS] seconds of its speech; [profileId] is set when
  /// the registry already named it.
  ///
  /// Held in memory only, alongside the 50-entry window. Persisting these to
  /// disk is a separate change with a privacy review attached — they are
  /// biometric vectors.
  final String? clipId;
  final int? clusterIndex;
  final Float32List? embedding;
  final double durationS;
  final String? profileId;

  /// True once the Gemma tidy pass replaced [text]. The UI can mark these
  /// lines so a wearer can tell what a model rewrote from what was heard.
  final bool isTidied;

  /// True when there is enough evidence attached to name this voice.
  bool get canName => embedding != null && clipId != null && clusterIndex != null;

  TranscriptEntry copyWith({
    String? text,
    String? talker,
    String? profileId,
    bool? isTidied,
  }) =>
      TranscriptEntry(
        id: id,
        text: text ?? this.text,
        at: at,
        overheard: overheard,
        talker: talker ?? this.talker,
        clipId: clipId,
        clusterIndex: clusterIndex,
        embedding: embedding,
        durationS: durationS,
        profileId: profileId ?? this.profileId,
        isTidied: isTidied ?? this.isTidied,
      );
}

/// Singleton in-memory log of on-device transcripts, newest first.
class OnDeviceTranscriptLog {
  OnDeviceTranscriptLog._();

  static final OnDeviceTranscriptLog instance = OnDeviceTranscriptLog._();

  static const int _maxEntries = 50;

  final ValueNotifier<List<TranscriptEntry>> _notifier =
      ValueNotifier<List<TranscriptEntry>>(const []);

  /// Subscribe to this from ValueListenableBuilder widgets.
  ValueListenable<List<TranscriptEntry>> get listenable => _notifier;

  /// Current snapshot (unmodifiable).
  List<TranscriptEntry> get entries => _notifier.value;

  /// Add a new transcript entry. Empty strings and the sentinel
  /// `[no speech]` are silently ignored. The list is capped at 50 entries
  /// (oldest are dropped when the cap is exceeded).
  ///
  /// [talker] is the speaker label from diarization (e.g. 'Talker 1'); null
  /// when diarization is unavailable or produced a single-speaker result.
  ///
  /// Returns the new entry's [TranscriptEntry.id], or null when the text was
  /// ignored — callers that want to revise the line later (the tidy pass) need
  /// the handle, and a null tells them there is nothing to revise.
  String? add(
    String text, {
    bool overheard = false,
    String? talker,
    String? clipId,
    int? clusterIndex,
    Float32List? embedding,
    double durationS = 0,
    String? profileId,
  }) {
    final trimmed = text.trim();
    if (trimmed.isEmpty || trimmed == '[no speech]') return null;

    final entry = TranscriptEntry(
      id: _nextId(),
      text: trimmed,
      at: DateTime.now(),
      overheard: overheard,
      talker: talker,
      clipId: clipId,
      clusterIndex: clusterIndex,
      embedding: embedding,
      durationS: durationS,
      profileId: profileId,
    );

    // Prepend (newest first) and enforce the cap.
    final updated = [entry, ..._notifier.value];
    _notifier.value = updated.length > _maxEntries
        ? updated.sublist(0, _maxEntries)
        : updated;
    return entry.id;
  }

  /// The entry with [id], or null when it has aged out of the 50-entry window.
  TranscriptEntry? byId(String id) {
    for (final e in _notifier.value) {
      if (e.id == id) return e;
    }
    return null;
  }

  /// Replace the text of entry [id] — the tidy pass landing on a line that is
  /// already on screen. Returns false when the entry has gone (aged out of the
  /// window, or the log was never given the id), when [text] is blank, or when
  /// it is identical to what is already there; in every one of those cases the
  /// log is left exactly as it was, listeners included.
  bool replaceText(String id, String text, {bool tidied = true}) {
    final trimmed = text.trim();
    if (trimmed.isEmpty) return false;
    final current = _notifier.value;
    for (var i = 0; i < current.length; i++) {
      final e = current[i];
      if (e.id != id) continue;
      if (e.text == trimmed && e.isTidied == tidied) return false;
      final next = [...current];
      next[i] = e.copyWith(text: trimmed, isTidied: tidied);
      _notifier.value = next;
      return true;
    }
    return false;
  }

  // Monotonic within the session; the counter disambiguates the several
  // entries a diarized clip logs inside one microsecond.
  int _seq = 0;
  String _nextId() =>
      '${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}-'
      '${(_seq++).toRadixString(36)}';

  /// Relabel every entry from the same clip and cluster — tier 1 of the
  /// back-fill rule. These lines are the same speaker by construction (the
  /// diarizer assigned them one index), not by similarity, so no threshold is
  /// involved and it is safe to do silently. Returns how many changed.
  int relabel({
    required String clipId,
    required int clusterIndex,
    required String talker,
    String? profileId,
  }) {
    var n = 0;
    final next = <TranscriptEntry>[];
    for (final e in _notifier.value) {
      if (e.clipId == clipId && e.clusterIndex == clusterIndex) {
        next.add(e.copyWith(talker: talker, profileId: profileId));
        n++;
      } else {
        next.add(e);
      }
    }
    if (n > 0) _notifier.value = next;
    return n;
  }
}
