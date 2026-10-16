// Copyright (c) 2025-2026 Kelvin Lee. Licensed under MIT.
//
// A2 button grammar (spec §3–§5): wire code → name, name × app state → action,
// action → habitat cues.
//
// These are the pure halves of the bridge, deliberately lifted out of the class
// so they can be tested without a radio. The GATT write that carries a cue and
// the capture window it opens both need the wearable and are not covered here.

import 'package:flutter_test/flutter_test.dart';
import 'package:kelvinlee/wearable/device_bridge.dart';

/// Resolve a code against a state, defaulting the alert kind to informational.
WearableGestureAction _resolve(String code, WearableAppState state, {bool question = false}) =>
    resolveButtonGesture(code: code, state: state, alertIsQuestion: question);

void main() {
  group('buttonCodeFor', () {
    test('A2 codes keep their values and take their new names', () {
      expect(buttonCodeFor(6), 'CANCEL');
      expect(buttonCodeFor(7), 'CAPTURE_TOGGLE');
      expect(buttonCodeFor(8), 'LINK_RECOVER');
    });

    test('power codes 9/10/11 decode', () {
      expect(buttonCodeFor(9), 'POWER_OFF_ARMED');
      expect(buttonCodeFor(10), 'POWER_OFF_ABORTED');
      expect(buttonCodeFor(11), 'POWER_OFF_COMMITTED');
    });

    test('D5 stays telemetry and press/release stay undispatchable', () {
      expect(buttonCodeFor(1), 'SINGLE');
      expect(buttonCodeFor(2), 'DOUBLE');
      expect(buttonCodeFor(3), 'LONG');
      expect(buttonCodeFor(4), isNull);
      expect(buttonCodeFor(5), isNull);
      expect(buttonCodeFor(99), isNull);
    });
  });

  group('appStateAt', () {
    final now = DateTime(2026, 1, 1, 12);

    test('capture beats a pending alert', () {
      expect(
        appStateAt(capturing: true, at: now, alertPendingAt: now.subtract(const Duration(seconds: 5))),
        WearableAppState.capturing,
      );
    });

    test('a settled alert is pending', () {
      expect(
        appStateAt(capturing: false, at: now, alertPendingAt: now.subtract(const Duration(milliseconds: 300))),
        WearableAppState.alertPending,
      );
    });

    test('an alert younger than 300 ms resolves against the pre-alert state', () {
      expect(
        appStateAt(capturing: false, at: now, alertPendingAt: now.subtract(const Duration(milliseconds: 299))),
        WearableAppState.idle,
      );
    });

    test('no alert is idle', () {
      expect(appStateAt(capturing: false, at: now), WearableAppState.idle);
    });
  });

  group('single tap — "yes"', () {
    test('idle starts capture', () {
      expect(_resolve('CAPTURE_TOGGLE', WearableAppState.idle), WearableGestureAction.startCapture);
    });

    test('capturing stops and files', () {
      expect(_resolve('CAPTURE_TOGGLE', WearableAppState.capturing), WearableGestureAction.stopAndFile);
    });

    test('a question acknowledges and opens the mic', () {
      expect(
        _resolve('CAPTURE_TOGGLE', WearableAppState.alertPending, question: true),
        WearableGestureAction.ackAndCapture,
      );
    });

    test('an informational alert acknowledges without the mic', () {
      expect(
        _resolve('CAPTURE_TOGGLE', WearableAppState.alertPending),
        WearableGestureAction.ackDismiss,
      );
    });
  });

  group('double tap — "no"', () {
    test('capturing cancels the note', () {
      expect(_resolve('CANCEL', WearableAppState.capturing), WearableGestureAction.cancelCapture);
    });

    test('an alert is dismissed unactioned, question or not', () {
      expect(_resolve('CANCEL', WearableAppState.alertPending), WearableGestureAction.dismissAlert);
      expect(
        _resolve('CANCEL', WearableAppState.alertPending, question: true),
        WearableGestureAction.dismissAlert,
      );
    });

    test('idle is an explicit safe no-op, never an error', () {
      expect(_resolve('CANCEL', WearableAppState.idle), WearableGestureAction.nop);
    });
  });

  group('triple tap and unknown codes', () {
    test('row K — the app answers "your phone is right here" in every state', () {
      for (final state in WearableAppState.values) {
        expect(_resolve('LINK_RECOVER', state), WearableGestureAction.linkAlive);
      }
    });

    test('power codes and D5 telemetry drive nothing', () {
      for (final code in ['POWER_OFF_ARMED', 'POWER_OFF_ABORTED', 'POWER_OFF_COMMITTED', 'SINGLE', 'LONG']) {
        expect(_resolve(code, WearableAppState.idle), WearableGestureAction.none, reason: code);
      }
    });
  });

  group('habitatCuesFor', () {
    test('row E is the only two-cue phrase: tick, then the capture ramp', () {
      expect(
        habitatCuesFor(WearableGestureAction.ackAndCapture),
        <int>[HabitatCue.ack, HabitatCue.captureOpen],
      );
    });

    test('cancel and dismiss share one cue, because they share one meaning', () {
      expect(habitatCuesFor(WearableGestureAction.cancelCapture), <int>[HabitatCue.discarded]);
      expect(habitatCuesFor(WearableGestureAction.dismissAlert), <int>[HabitatCue.discarded]);
    });

    test('every acted-on gesture writes at least one cue (the watchdog disarm)', () {
      for (final action in WearableGestureAction.values) {
        if (action == WearableGestureAction.none) continue;
        expect(habitatCuesFor(action), isNotEmpty, reason: '$action');
      }
      expect(habitatCuesFor(WearableGestureAction.none), isEmpty);
    });
  });

  group('alertIsQuestionForCue', () {
    test('awaiting_input asks, error informs, everything else is not an alert', () {
      expect(alertIsQuestionForCue(HabitatCue.awaitingInput), isTrue);
      expect(alertIsQuestionForCue(HabitatCue.error), isFalse);
      expect(alertIsQuestionForCue(HabitatCue.taskRunning), isNull);
      expect(alertIsQuestionForCue(HabitatCue.noteFiled), isNull);
    });
  });

  group('consumesAlert — which gestures actually answer an alert', () {
    // Regression: _onButtonCode used to clear ALERT_PENDING on *any* code that
    // arrived while one was armed, so a D5 telemetry press or a power-hold code
    // silently dropped the alert with no cue and no acknowledgement.
    test('only the three answering actions consume it', () {
      expect(consumesAlert(WearableGestureAction.ackAndCapture), isTrue);
      expect(consumesAlert(WearableGestureAction.ackDismiss), isTrue);
      expect(consumesAlert(WearableGestureAction.dismissAlert), isTrue);
    });

    test('D5 telemetry, the power codes and link recovery leave it standing', () {
      // Every D5 code and every power code resolves to `none` (spec row Q).
      for (final code in <String>[
        'SINGLE', 'DOUBLE', 'LONG',
        'POWER_OFF_ARMED', 'POWER_OFF_ABORTED', 'POWER_OFF_COMMITTED',
      ]) {
        final action = resolveButtonGesture(
          code: code,
          state: WearableAppState.alertPending,
          alertIsQuestion: true,
        );
        expect(action, WearableGestureAction.none, reason: code);
        expect(consumesAlert(action), isFalse, reason: code);
      }
      expect(consumesAlert(WearableGestureAction.linkAlive), isFalse);
    });
  });

  group('an armed alert decays', () {
    // Without an upper bound, an informational alert the wearer never answers
    // turns single-tap-to-talk into single-tap-to-acknowledge for the rest of
    // the session — undetectable on a device with no screen.
    final armed = DateTime(2026, 9, 7, 12, 0, 0);

    test('claims the tap once it has settled', () {
      expect(
        appStateAt(capturing: false, at: armed.add(const Duration(seconds: 1)), alertPendingAt: armed),
        WearableAppState.alertPending,
      );
    });

    test('still too fresh to have been reacted to', () {
      expect(
        appStateAt(capturing: false, at: armed.add(const Duration(milliseconds: 100)), alertPendingAt: armed),
        WearableAppState.idle,
      );
    });

    test('lets go, so the button goes back to meaning "talk"', () {
      for (final age in const <Duration>[
        Duration(minutes: 3),
        Duration(hours: 8),
        Duration(days: 30),
      ]) {
        expect(
          appStateAt(capturing: false, at: armed.add(age), alertPendingAt: armed),
          WearableAppState.idle,
          reason: 'an alert $age old must not still be claiming taps',
        );
      }
    });

    test('capturing always wins, however old the alert', () {
      expect(
        appStateAt(capturing: true, at: armed.add(const Duration(seconds: 1)), alertPendingAt: armed),
        WearableAppState.capturing,
      );
    });
  });

  group('instructionArmIsLive', () {
    final now = DateTime(2026, 1, 1, 12);

    test('no press means the utterance is ambient', () {
      expect(instructionArmIsLive(null, now), isFalse);
    });

    test('a press the wearer followed with speech claims the utterance', () {
      expect(instructionArmIsLive(now.subtract(const Duration(seconds: 2)), now), isTrue);
    });

    test('a press answered by silence expires rather than claiming a later one', () {
      expect(
        instructionArmIsLive(now.subtract(instructionArmWindow), now),
        isTrue,
        reason: 'the boundary itself is still live',
      );
      expect(
        instructionArmIsLive(
            now.subtract(instructionArmWindow + const Duration(milliseconds: 1)), now),
        isFalse,
      );
    });

    test('a press timestamped in the future does not arm anything', () {
      expect(instructionArmIsLive(now.add(const Duration(seconds: 1)), now), isFalse);
    });
  });
}
