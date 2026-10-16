// Copyright (c) 2025-2026 Kelvin Lee. Licensed under MIT.
//
// Pure helpers behind the multi-scale speaker embedding. No sherpa, no
// isolates, no Flutter: this file runs identically in a host unit test, on
// the UI isolate, and inside the speaker worker isolate, which is the point —
// the worker computes the whole robust embedding (up to 7 forward passes) so
// none of those passes touch the UI thread.
//
// Windowing and weighting are load-bearing: a stride bug silently embeds the
// wrong audio (no crash, no log, just a worse speaker match), and a weighting
// bug quietly biases every identity decision. See owner_voice_multiscale_test.

import 'dart:math' as math;
import 'dart:typed_data';

const int kSpeakerSampleRate = 16000;

/// Window lengths in seconds, taken in addition to the whole clip.
///
/// Zheng et al. (arXiv:2606.13095 SS2.1) pool CAM++ statistics inside
/// 400/200/100 ms chunks rather than over the whole sequence, and report
/// steadier speaker features for it. We cannot reach inside the WeSpeaker
/// ONNX graph, so the same idea is applied one level out: whole forward
/// passes over windows of several lengths, aggregated afterwards. The
/// windows are longer than the paper's because a full WeSpeaker pass needs
/// enough audio to yield an embedding at all -- shorter ones are refused by
/// isReady() and skipped.
const List<double> kRobustChunkSeconds = [2.0, 1.0];

/// Per-scale cap on windows. Each window is one ResNet34-LM forward pass and
/// identity runs once per diarization cluster, so an uncapped count would be
/// a real-time regression on long clusters. Fig. 3 of the same paper is the
/// licence to subsample: at a 1:0.25 speaker-to-speech frame ratio their
/// cpCER stays acceptable, so evenly spaced windows carry the information
/// without needing every one. Worst case here is 1 + 3 + 3 = 7 passes.
const int kRobustMaxChunksPerScale = 3;

/// Up to [maxChunks] evenly spaced windows of [scale] seconds.
///
/// Empty when the clip cannot hold two of them: a single window of a scale is
/// the whole clip over again, at the cost of another forward pass.
List<Float32List> embeddingWindows(
  Float32List samples,
  double scale, {
  int maxChunks = kRobustMaxChunksPerScale,
  int rate = kSpeakerSampleRate,
}) {
  final len = (scale * rate).round();
  if (len <= 0) return const [];
  final available = samples.length ~/ len;
  if (available < 2) return const [];
  final take = math.min(available, maxChunks);
  final stride = (samples.length - len) ~/ (take - 1);
  return [
    for (var i = 0; i < take; i++)
      Float32List.sublistView(samples, i * stride, i * stride + len),
  ];
}

/// Duration-weighted mean of unit vectors, re-normalised.
///
/// Pure and dimension-preserving: the caller stores and compares fixed-width
/// embeddings, so the paper's feature-axis concatenation is not available to
/// us. Returns a zero-length list for empty input, which callers treat the
/// same as a failed extraction.
Float32List weightedMeanEmbedding(List<Float32List> parts, List<double> weights) {
  assert(parts.length == weights.length, 'parts/weights length mismatch');
  if (parts.isEmpty) return Float32List(0);
  if (parts.length == 1) return parts.first;
  final dim = parts.first.length;
  final acc = Float64List(dim);
  for (var i = 0; i < parts.length; i++) {
    final p = parts[i];
    if (p.length != dim) continue; // defensive: never mix dimensions
    final w = weights[i];
    for (var j = 0; j < dim; j++) {
      acc[j] += p[j] * w;
    }
  }
  final out = Float32List(dim);
  for (var j = 0; j < dim; j++) {
    out[j] = acc[j];
  }
  return l2Normalize(out);
}

/// [v] scaled to unit length; a zero vector is returned as-is.
Float32List l2Normalize(Float32List v) {
  double norm = 0;
  for (final x in v) {
    norm += x * x;
  }
  norm = math.sqrt(norm);
  if (norm == 0) return v;
  final out = Float32List(v.length);
  for (var i = 0; i < v.length; i++) {
    out[i] = v[i] / norm;
  }
  return out;
}

/// The multi-scale embedding of [samples], built from single-pass [embedOne].
///
/// A transient -- a cough, a door, a moment of overlap -- contaminates the
/// statistics pooling of a whole-clip embedding entirely. Chunked windows
/// confine it to one window, and the mean over windows dilutes it. Weighting
/// each window by its duration mirrors the paper's length-aware speaker loss
/// (SS2.2), which weights longer segments more heavily for the same reason:
/// more audio gives a better-determined speaker estimate.
///
/// The whole clip is included as one weighted term, so this can only blend
/// toward the previous single-pass behaviour, never away from it. The
/// embedding is null only when [embedOne] fails on the whole clip -- if every
/// window is refused, the whole-clip embedding is used alone. [passes] counts
/// the forward passes that produced a vector, so the real cost is measured,
/// not assumed.
({Float32List? embedding, int passes}) robustEmbedding(
  Float32List samples,
  Float32List? Function(Float32List clip) embedOne, {
  int rate = kSpeakerSampleRate,
}) {
  final full = embedOne(samples);
  if (full == null || full.isEmpty) return (embedding: null, passes: 0);

  final seconds = samples.length / rate;
  final parts = <Float32List>[l2Normalize(full)];
  final weights = <double>[seconds];

  for (final scale in kRobustChunkSeconds) {
    for (final window in embeddingWindows(samples, scale, rate: rate)) {
      final emb = embedOne(window);
      if (emb == null || emb.isEmpty) continue;
      parts.add(l2Normalize(emb));
      weights.add(scale);
    }
  }

  return (embedding: weightedMeanEmbedding(parts, weights), passes: parts.length);
}
