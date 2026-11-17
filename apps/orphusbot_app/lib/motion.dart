// How much the app moves (DESIGN §12.7): full, calm or off. Calm keeps what
// follows a change (a face's state, give and receive) and drops travel and
// idle fidgets; off shows still faces and plain lines. It's kept on this
// device, beside the session, and the system's reduce-motion setting makes
// full calm.
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:path_provider/path_provider.dart';

enum Motion { full, calm, off }

/// This device's choice. Full unless the owner chose otherwise.
final motion = ValueNotifier(Motion.full);

Future<File> _file() async =>
    File('${(await getApplicationSupportDirectory()).path}/motion');

/// Reads the saved choice at launch.
Future<void> loadMotion() async {
  try {
    final saved = (await (await _file()).readAsString()).trim();
    motion.value = Motion.values.byName(saved);
  } catch (_) {
    // Never chosen, or unreadable: the default.
  }
}

// The last save, so saves are written in the order they were chosen.
Future<void> _saved = Future.value();

Future<void> saveMotion(Motion m) {
  motion.value = m;
  Future<void> write() async => (await _file()).writeAsString(m.name);
  // Whether or not the one before worked.
  return _saved = _saved.then((_) => write(), onError: (_) => write());
}

/// What applies here: the choice, or calm at most when the system asks for
/// less motion.
Motion motionOf(BuildContext context) =>
    motion.value == Motion.full &&
        (MediaQuery.maybeDisableAnimationsOf(context) ?? false)
    ? Motion.calm
    : motion.value;
