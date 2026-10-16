// Copyright (c) 2025-2026 Kelvin Lee. Licensed under MIT.
//
// The wiring between a freshly saved transcript, [TidyGate] and [polish.dart].
//
// Separate from tidy_gate.dart so the gate stays a pure function with no
// plugins behind it, and separate from device_bridge.dart because the capture
// path should carry one call, not a policy. The contract with the capture path
// is deliberately narrow:
//
//   - fire-and-forget: the entry is already on screen when this starts, and
//     nothing here may delay the next capture;
//   - never throws: it runs unawaited on the audio path;
//   - no-op unless the wearer turned it on AND the model is installed.
//
// What it does when it does run is replace text a wearer has already read. So
// the two guards from polish.dart apply at full strength — the tidy prompt
// forbids additions, and the word ceiling rejects the rewrite that made them
// anyway — and a rejected rewrite leaves the line exactly as the recogniser
// wrote it.

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'model_provisioner.dart';
import 'polish.dart';
import 'tidy_gate.dart';
import 'transcript_log.dart';

/// The wearer's opt-in for the automatic tidy pass.
///
/// Off by default: it spends seconds of a ~2.6 GB model per note and it
/// rewrites text the wearer has already read. Whether it should default on
/// once the decision log shows how often the gate actually fires is an open
/// question for the owner (plan § 6.3), not a default to assume.
class TidySettings {
  TidySettings._();

  static const String enabledKey = 'wearable.autoTidy';
  static const bool defaultEnabled = false;

  static Future<bool> enabled() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(enabledKey) ?? defaultEnabled;
  }

  static Future<void> setEnabled(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(enabledKey, value);
  }
}

/// Tidy the entry [entryId] if — and only if — a measurement says the
/// recogniser struggled on it.
///
/// [entryId] comes straight from [OnDeviceTranscriptLog.add], so a null (the
/// text was ignored) is a no-op. [preview] is the streaming model's text for
/// the same clip; pass null when the preview covers more audio than this
/// entry's text does — see [TidyGate.decide]. [clipSeconds] is the length of
/// the captured audio, used only when the entry carries no pooled speech
/// duration of its own.
///
/// [log], [generate] and [enabled] are injection seams for tests; production
/// callers pass the id, the preview and the clip length and nothing else.
Future<void> maybeTidy(
  String? entryId, {
  String? preview,
  double clipSeconds = 0,
  OnDeviceTranscriptLog? log,
  PolishGenerator? generate,
  Future<bool> Function()? enabled,
}) async {
  if (entryId == null) return;
  final sw = Stopwatch()..start();
  try {
    final on = await (enabled ?? _enabledByDefault)();
    if (!on) return;

    final store = log ?? OnDeviceTranscriptLog.instance;
    final entry = store.byId(entryId);
    if (entry == null) return;

    // The diarizer's pooled speech for this speaker is the better duration
    // when we have it: on a multi-speaker clip the clip length belongs to
    // everyone in it, and words-per-second computed against it is nonsense.
    final speechSeconds = entry.durationS > 0 ? entry.durationS : clipSeconds;
    final decision = TidyGate.decide(
      text: entry.text,
      preview: preview,
      speechSeconds: speechSeconds,
    );

    if (!decision.run) {
      _logDecision(decision, sw, applied: false);
      return;
    }

    final result = await polishTranscript(entry.text, PolishTone.tidy, generate: generate);
    // result.polished == false means the sanitiser rejected the rewrite — a
    // refusal, an echo, or growth past the word ceiling. The recogniser's own
    // text stays on screen; that is the whole point of the fallback.
    final applied = result.polished && store.replaceText(entryId, result.text);
    _logDecision(decision, sw, applied: applied, note: result.note);
  } catch (e) {
    // Unawaited on the capture path: an exception here would be unhandled.
    debugPrint('[TidyGate] failed: $e');
  }
}

Future<bool> _enabledByDefault() async =>
    GemmaModelProvisioner.instance.isInstalled && await TidySettings.enabled();

void _logDecision(TidyDecision d, Stopwatch sw, {required bool applied, String? note}) {
  sw.stop();
  debugPrint('[TidyGate] $d latencyMs=${sw.elapsedMilliseconds} applied=$applied'
      '${note == null ? '' : ' note=$note'}');
}
