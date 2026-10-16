// Copyright (c) 2025-2026 Kelvin Lee. Licensed under MIT.
//
// Tests for PunctuationProvisioner's pinning and labelling.
//
// These do not touch the network or native code. They pin the things that
// silently rot: a revision that slips back to a mutable branch, digests pasted
// in wrong, and a size label that drifts from the artifacts it describes.
// Same three failures StreamingProvisioner's tests guard, same reasons.

import 'package:flutter_test/flutter_test.dart';
import 'package:kelvinlee/wearable/local_llm/punctuation_provisioner.dart';

void main() {
  test('the repo is pinned to an immutable commit, not a branch', () {
    // 'main' would let the model change under a shipped app.
    expect(PunctuationProvisioner.revision, isNot('main'));
    expect(PunctuationProvisioner.revision, matches(RegExp(r'^[0-9a-f]{40}$')),
        reason: 'revision should be a full commit SHA');
  });

  test('the repo is the English punct+casing model, not the zh-en one', () {
    // The CT-Transformer alternative is Chinese-English, does no casing, and
    // declares no licence for its weights. Naming it here would be a silent
    // downgrade on all three counts.
    expect(PunctuationProvisioner.repo, contains('online-punct-en'));
    expect(PunctuationProvisioner.repo, isNot(contains('ct-transformer')));
  });

  test('the pinned digests are the official k2-fsa release bytes', () {
    // Verified 2026-09-11 by extracting
    //   punctuation-models/sherpa-onnx-online-punct-en-2024-08-06.tar.bz2
    // (itself matching that release's checksum.txt) and hashing its contents.
    // This test is the record: if someone re-pins to another host, the digests
    // must still be these, or the model is not the one whose licence and
    // behaviour were checked.
    expect(
      PunctuationProvisioner.pinnedDigests,
      containsAll(<String>[
        '9d611f445fe4a46186080fe161be6059d87d72eb88d3a8cb00c1a06e83a6067e', // model.int8.onnx
        'e118b7ad88c54db562517df49e1cffd4836d166c34fb190fd311d7f34eb238f5', // bpe.vocab
      ]),
    );
  });

  test('the size label is derived, so it cannot drift from the artifacts', () {
    final label = PunctuationProvisioner.sizeLabel;
    expect(label, matches(RegExp(r'^~\d+ MB$')));
    final mb = int.parse(RegExp(r'\d+').firstMatch(label)!.group(0)!);
    // 7.14 MB int8 model + 0.14 MB vocab. A label outside this band means the
    // pin moved to the fp32 model (29.7 MB) or to a different checkpoint.
    expect(mb, inInclusiveRange(6, 9),
        reason: 'label $label does not match the pinned artifact sizes');
  });
}
