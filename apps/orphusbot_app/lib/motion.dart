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

Future<void> saveMotion(Motion m) async {
  motion.value = m;
  await (await _file()).writeAsString(m.name);
}

/// What applies here: the choice, or calm at most when the system asks for
/// less motion.
Motion motionOf(BuildContext context) =>
    motion.value == Motion.full &&
        (MediaQuery.maybeDisableAnimationsOf(context) ?? false)
    ? Motion.calm
    : motion.value;
