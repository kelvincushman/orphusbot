// A hand-off between two bots in a chat (DESIGN §12.7): a strip with the two
// faces that plays once when it arrives (one gives, a note flies across, the
// other takes it), then rests as a plain line that opens the ticket. The line
// is there while it plays too, so nothing is told by motion alone.
import 'dart:async';

import 'package:flutter/material.dart';

import 'api.dart';
import 'avatar.dart';
import 'motion.dart';

class HandoffStrip extends StatefulWidget {
  const HandoffStrip({
    super.key,
    required this.asker,
    required this.teammate,
    required this.line,
    required this.answer,
    required this.ok,
    required this.play,
    required this.onOpen,
  });

  /// The two bots' face styles ([faceOf]). The asker sits on the left.
  final String asker;
  final String teammate;

  /// The plain line, such as "Researcher asked Coder · OB-142".
  final String line;

  /// The answer going back (teammate to asker) rather than the ask.
  final bool answer;

  /// For an answer: the teammate finished the job.
  final bool ok;

  /// Play it now. Read once, when the strip first shows.
  final bool play;
  final VoidCallback onOpen;

  @override
  State<HandoffStrip> createState() => _HandoffStripState();
}

class _HandoffStripState extends State<HandoffStrip>
    with SingleTickerProviderStateMixin {
  final asker = GlobalKey<BotAvatarState>();
  final teammate = GlobalKey<BotAvatarState>();
  late final flight = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 900),
  );
  final timers = <Timer>[];
  // Null until the first build decides; then whether the strip is playing.
  bool? playing;
  // The note has arrived, so the bot that took it reacts.
  bool caught = false;

  void _after(int ms, VoidCallback then) => timers.add(
    Timer(Duration(milliseconds: ms), () {
      if (mounted) then();
    }),
  );

  void _play(Motion m) {
    final (giver, taker) = widget.answer
        ? (teammate, asker)
        : (asker, teammate);
    // A moment for the faces to load, then: give, the note's flight, receive.
    _after(300, () {
      giver.currentState?.give();
      // Calm drops the travel: the faces react, the note doesn't fly.
      if (m == Motion.full) flight.forward();
    });
    _after(1200, () {
      taker.currentState?.receive();
      setState(() => caught = true);
    });
    _after(3000, () => setState(() => playing = false));
  }

  @override
  void dispose() {
    for (final t in timers) {
      t.cancel();
    }
    flight.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    if (playing == null) {
      final m = motionOf(context);
      playing = widget.play && m != Motion.off;
      if (playing!) _play(m);
    }
    final line = Text(
      widget.line,
      textAlign: TextAlign.center,
      style: TextStyle(color: scheme.outline),
    );
    return Semantics(
      button: true,
      hint: 'Opens the ticket',
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: widget.onOpen,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: playing!
              ? Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [_faces(scheme), line],
                )
              : Center(child: line),
        ),
      ),
    );
  }

  Widget _faces(ColorScheme scheme) => ExcludeSemantics(
    child: Center(
      child: SizedBox(
        width: 220,
        height: 52,
        child: Row(
          children: [
            BotAvatar(
              key: asker,
              slug: widget.asker,
              // Its "done" wiggle when a good answer lands.
              mood: widget.answer && caught && widget.ok ? 4 : 0,
              size: 44,
            ),
            Expanded(
              child: AnimatedBuilder(
                animation: flight,
                builder: (_, _) {
                  final t = Curves.easeInOut.transform(flight.value);
                  final x = (widget.answer ? 1 - t : t) * 2 - 1;
                  return Opacity(
                    opacity: flight.value > 0 && flight.value < 1 ? 1 : 0,
                    child: Align(
                      // An arc: up in the middle, down at each face.
                      alignment: Alignment(x, 0.6 - 1.6 * 4 * t * (1 - t)),
                      child: Icon(
                        Icons.sticky_note_2_outlined,
                        size: 18,
                        color: scheme.onSurface,
                      ),
                    ),
                  );
                },
              ),
            ),
            BotAvatar(
              key: teammate,
              slug: widget.teammate,
              // It starts on the job once it has the note.
              mood: !widget.answer && caught ? 2 : 0,
              size: 44,
              flip: true,
            ),
          ],
        ),
      ),
    ),
  );
}

/// Shows ticket OB-[id] from the board: what was asked, of whom, and where
/// it stands.
Future<void> showTicket(BuildContext context, Api api, int id) => showDialog(
  context: context,
  builder: (c) => FutureBuilder<dynamic>(
    future: api.get('/api/tickets'),
    builder: (c, got) {
      final ticket = (got.data as List? ?? [])
          .cast<Map<String, dynamic>>()
          .where((t) => t['id'] == id)
          .firstOrNull;
      final body = ticket?['body'] as String? ?? '';
      return AlertDialog(
        title: Text('OB-$id${ticket == null ? '' : ' · ${ticket['title']}'}'),
        content: SizedBox(
          width: 480,
          child: SingleChildScrollView(
            child: got.hasError
                ? Text(explain(got.error!))
                : !got.hasData
                ? const LinearProgressIndicator()
                : ticket == null
                ? const Text("That ticket isn't on the board any more.")
                : Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        '${ticket['status']} · ${ticket['bot'] ?? 'nobody yet'}',
                        style: TextStyle(
                          color: Theme.of(c).colorScheme.outline,
                        ),
                      ),
                      if (body.isNotEmpty) ...[
                        const SizedBox(height: 12),
                        SelectableText(body),
                      ],
                    ],
                  ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c),
            child: const Text('Close'),
          ),
        ],
      );
    },
  ),
);
