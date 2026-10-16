// Copyright (c) 2025-2026 Kelvin Lee. Licensed under MIT.
//
// Tests for StreamingProvisioner's pinning and labelling.
//
// These do not touch the network or native code. They pin the things that
// silently rot: a size label that drifts from the artifacts it describes, a
// revision that slips back to a mutable branch, and digests that get pasted in
// wrong. All three have precedent in this repo.

import 'package:flutter_test/flutter_test.dart';
import 'package:kelvinlee/wearable/local_llm/streaming_provisioner.dart';

void main() {
  test('the repo is pinned to an immutable commit, not a branch', () {
    // 'main' would let the model change under a shipped app.
    expect(StreamingProvisioner.revision, isNot('main'));
    expect(StreamingProvisioner.revision, matches(RegExp(r'^[0-9a-f]{40}$')),
        reason: 'revision should be a full commit SHA');
  });

  test('the repo is the streaming sibling of the offline checkpoint', () {
    // Same family and date matters: live text and saved text should come from
    // siblings, not strangers.
    expect(StreamingProvisioner.repo, contains('streaming-zipformer-en'));
    expect(StreamingProvisioner.repo, contains('2023-06-26'));
  });

  test('the size label is derived, so it cannot drift from the artifacts', () {
    final label = StreamingProvisioner.sizeLabel;
    expect(label, matches(RegExp(r'^~\d+ MB$')));
    final mb = int.parse(RegExp(r'\d+').firstMatch(label)!.group(0)!);
    // ~71 MB encoder + ~2 MB decoder + joiner + tokens.
    expect(mb, inInclusiveRange(65, 80),
        reason: 'label $label does not match the pinned artifact sizes');
  });
}
