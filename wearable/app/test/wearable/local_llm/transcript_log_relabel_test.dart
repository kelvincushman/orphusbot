// Copyright (c) 2025-2026 Kelvin Lee. Licensed under MIT.
//
// Tests for OnDeviceTranscriptLog.relabel — the back-fill rule.
//
// relabel() is the one place a name is applied to lines the user did not tap.
// It is safe only because its scope is exactly (clipId, clusterIndex): lines
// the diarizer already declared to be one speaker, with no similarity
// threshold involved. The tests below pin that scope. A regression that
// widened it — to the whole clip, or to every entry with the same cluster
// index across clips — would silently put words in the wrong person's mouth,
// which is the worst failure this feature can have.
//
// A separate file from transcript_log_test.dart: P0 does not own the log's
// source and adding to its existing test file would collide with P2, which
// does.
//
// The log is a process-wide singleton with no clear(), so every test uses its
// own clip id and asserts on counts rather than on the whole list.

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:kelvinlee/wearable/local_llm/transcript_log.dart';

Float32List _vec(double seed) => Float32List.fromList([seed, seed + 1, seed + 2]);

void main() {
  final log = OnDeviceTranscriptLog.instance;

  List<TranscriptEntry> entriesFor(String clipId) =>
      log.entries.where((e) => e.clipId == clipId).toList();

  test('relabels every line of the same clip and cluster, and counts them', () {
    const clip = 'clip-a';
    log.add('one', clipId: clip, clusterIndex: 0, embedding: _vec(1), talker: 'Talker 1');
    log.add('two', clipId: clip, clusterIndex: 0, embedding: _vec(1), talker: 'Talker 1');

    final n = log.relabel(clipId: clip, clusterIndex: 0, talker: 'Ana', profileId: 'p1');

    expect(n, 2);
    final got = entriesFor(clip);
    expect(got.map((e) => e.talker), everyElement('Ana'));
    expect(got.map((e) => e.profileId), everyElement('p1'));
  });

  test('leaves other clusters in the same clip alone', () {
    const clip = 'clip-b';
    log.add('mine', clipId: clip, clusterIndex: 0, embedding: _vec(1), talker: 'Talker 1');
    log.add('theirs', clipId: clip, clusterIndex: 1, embedding: _vec(9), talker: 'Talker 2');

    final n = log.relabel(clipId: clip, clusterIndex: 0, talker: 'Ana');

    expect(n, 1);
    final byText = {for (final e in entriesFor(clip)) e.text: e};
    expect(byText['mine']!.talker, 'Ana');
    expect(byText['theirs']!.talker, 'Talker 2');
  });

  test('leaves the same cluster index in a different clip alone', () {
    // Cluster indices are per-clip. "Talker 1" in Tuesday's recording is not
    // the same person as "Talker 1" in Wednesday's, and relabel must not
    // assume otherwise.
    log.add('tue', clipId: 'clip-c1', clusterIndex: 0, embedding: _vec(1), talker: 'Talker 1');
    log.add('wed', clipId: 'clip-c2', clusterIndex: 0, embedding: _vec(2), talker: 'Talker 1');

    final n = log.relabel(clipId: 'clip-c1', clusterIndex: 0, talker: 'Ana');

    expect(n, 1);
    expect(entriesFor('clip-c1').single.talker, 'Ana');
    expect(entriesFor('clip-c2').single.talker, 'Talker 1');
  });

  test('no match returns 0 and changes nothing', () {
    const clip = 'clip-d';
    log.add('only line', clipId: clip, clusterIndex: 0, embedding: _vec(1), talker: 'Talker 1');
    final before = log.entries;

    final n = log.relabel(clipId: clip, clusterIndex: 7, talker: 'Ana');

    expect(n, 0);
    // Identical list instance: relabel must not churn the notifier on a miss,
    // or every ValueListenableBuilder on the transcript list rebuilds for
    // nothing.
    expect(identical(log.entries, before), isTrue);
  });

  test('entries with no clip evidence are never touched', () {
    log.add('phone mic line, no diarization');
    final n = log.relabel(clipId: 'clip-e', clusterIndex: 0, talker: 'Ana');
    expect(n, 0);
    expect(log.entries.first.talker, isNull);
  });
}
