// The Team stage (DESIGN §12.7): every bot's robot standing in its own spot,
// in its current state and holding what it's working with. When one bot asks
// another it goes across, hands the note over and comes back, and while the
// teammate has the job a thin line joins the two, arching over the robots
// between them. Each spot has its bot's name and what it's doing in words,
// and each line its ticket, so the stage reads the same with Animation off.
import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'api.dart';
import 'avatar.dart';
import 'handoff.dart';
import 'motion.dart';
import 'thread.dart';

class TeamStage extends StatefulWidget {
  const TeamStage({
    super.key,
    required this.api,
    required this.changed,
    required this.bots,
    required this.threads,
    required this.open,
    required this.handoffs,
    required this.onOpen,
  });
  final Api api;

  /// Tells the stage that what the three below give has changed. They're
  /// the chat screen's own, fed by its one event stream.
  final Listenable changed;
  final List<Map<String, dynamic>> Function() bots;
  final Map<String, ThreadView> threads;

  /// Unfinished hand-offs (`/api/team/open`): `id`, `bot`, `asked_by`, `blocked`.
  final List<Map<String, dynamic>> Function() open;

  /// `asked` and `answered` events as they happen, one per hand-off.
  final Stream<Map<String, dynamic>> handoffs;

  /// Opens a bot's chat.
  final void Function(String slug) onOpen;

  @override
  State<TeamStage> createState() => _TeamStageState();
}

class _TeamStageState extends State<TeamStage> {
  static const cell = Size(150, 264);
  static const robot = 96.0;
  // Room above each row's robots for the lines to arch through.
  static const headroom = 84.0;
  static const walk = Duration(milliseconds: 700);

  final faces = <String, GlobalKey<BotAvatarState>>{};
  // A bot that has gone across to another: visitor's slug → host's slug.
  final away = <String, String>{};
  final timers = <Timer>[];
  StreamSubscription<Map<String, dynamic>>? sub;

  void _changed() => setState(() {});

  @override
  void initState() {
    super.initState();
    widget.changed.addListener(_changed);
    sub = widget.handoffs.listen((e) => _handOver(e['from'], e['to']));
  }

  @override
  void dispose() {
    widget.changed.removeListener(_changed);
    sub?.cancel();
    for (final t in timers) {
      t.cancel();
    }
    super.dispose();
  }

  void _after(Duration wait, VoidCallback then) => timers.add(
    Timer(wait, () {
      if (mounted) then();
    }),
  );

  /// [giver] hands [taker] a note. Full: it goes across first and comes back
  /// after. Calm: both react where they stand. Off: nothing moves.
  void _handOver(Object? giver, Object? taker) {
    if (giver is! String || taker is! String) return;
    final m = motionOf(context);
    if (m == Motion.off) return;
    void pass() {
      faces[giver]?.currentState?.give();
      faces[taker]?.currentState?.receive();
    }

    if (m == Motion.calm) return pass();
    setState(() => away[giver] = taker);
    _after(walk, pass);
    _after(walk + const Duration(milliseconds: 1200), () {
      // Unless it has since set off to someone else.
      if (away[giver] == taker) setState(() => away.remove(giver));
    });
  }

  String _status(ThreadView? v) => v == null
      ? 'Ready'
      : v.waiting > 0
      ? 'Needs you'
      : switch (v.run) {
          RunState.running => '${v.doing ?? 'Working'}…',
          RunState.queued => 'Waiting to start',
          RunState.idle =>
            v.waitingOn > 0
                ? 'Waiting on a teammate'
                : (v.failed ? 'Failed' : (v.done ? 'Done' : 'Ready')),
        };

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final bots = widget.bots();
    final full = motionOf(context) == Motion.full;
    String name(String slug) =>
        bots.where((b) => b['slug'] == slug).firstOrNull?['name'] as String? ??
        slug;
    return Scaffold(
      appBar: AppBar(title: const Text('Team')),
      body: bots.isEmpty
          ? const Center(child: Text('No bots yet.'))
          : LayoutBuilder(
              builder: (context, box) {
                final cols = max(1, box.maxWidth ~/ cell.width);
                final width = box.maxWidth / cols;
                final rows = (bots.length / cols).ceil();
                // Each bot's own spot: the top left of its cell.
                final spot = {
                  for (final (i, b) in bots.indexed)
                    b['slug'] as String: Offset(
                      (i % cols) * width + (width - cell.width) / 2,
                      (i ~/ cols) * cell.height,
                    ),
                };
                // A visitor stands beside its host, on the left unless the
                // host is at the left edge.
                bool leftOf(String host) => spot[host]!.dx >= robot * 0.5;
                Offset at(String slug) {
                  final host = away[slug];
                  if (host == null || !spot.containsKey(host)) {
                    return spot[slug]!;
                  }
                  return spot[host]! +
                      Offset(leftOf(host) ? -robot * 0.7 : robot * 0.7, 0);
                }

                // Give and receive reach to the right, so whoever has its
                // partner on the left is mirrored.
                bool flipped(String slug) {
                  final host = away[slug];
                  if (host != null) return !leftOf(host);
                  final visited = away.values.contains(slug);
                  return visited && leftOf(slug);
                }

                final open = [
                  for (final o in widget.open())
                    if (spot.containsKey(o['bot']) &&
                        spot.containsKey(o['asked_by']))
                      o,
                ];
                // A line leaves from just above a robot's head and arches
                // up, higher the further it goes, so a long line clears a
                // short one under it; a pair's second ticket arches higher
                // still. The lines and their tickets then don't sit on each
                // other.
                Offset head(String slug) =>
                    spot[slug]! + Offset(cell.width / 2, headroom);
                bool pair(Map<String, dynamic> a, Map<String, dynamic> b) =>
                    a['bot'] == b['bot'] && a['asked_by'] == b['asked_by'];
                Offset bend(int i, Map<String, dynamic> o) {
                  final from = head(o['asked_by'] as String);
                  final to = head(o['bot'] as String);
                  final before = open.take(i).where((p) => pair(p, o)).length;
                  return Offset.lerp(from, to, 0.5)! -
                      Offset(
                        0,
                        28 + 0.22 * (to - from).distance + 52.0 * before,
                      );
                }

                return SingleChildScrollView(
                  child: SizedBox(
                    width: box.maxWidth,
                    height: rows * cell.height + 16,
                    child: Stack(
                      children: [
                        // The lines, under the robots.
                        Positioned.fill(
                          child: CustomPaint(
                            painter: _Lines([
                              for (final (i, o) in open.indexed)
                                (
                                  head(o['asked_by'] as String),
                                  bend(i, o),
                                  head(o['bot'] as String),
                                  o['blocked'] == true
                                      ? scheme.error
                                      : scheme.outline,
                                ),
                            ]),
                          ),
                        ),
                        // Each bot's spot: its name and status stay put, and
                        // take the tap, while its robot may be away.
                        for (final b in bots)
                          _spot(b, spot[b['slug'] as String]!, scheme),
                        for (final b in bots)
                          _robot(
                            b,
                            at(b['slug'] as String),
                            flipped(b['slug'] as String),
                            full,
                          ),
                        // Each line's ticket, at the top of its arch (the
                        // curve passes half way to its bend).
                        for (final (i, o) in open.indexed)
                          _ticket(
                            o,
                            Offset.lerp(
                              Offset.lerp(
                                head(o['asked_by'] as String),
                                head(o['bot'] as String),
                                0.5,
                              ),
                              bend(i, o),
                              0.5,
                            )!,
                            name,
                            scheme,
                          ),
                      ],
                    ),
                  ),
                );
              },
            ),
    );
  }

  Widget _spot(Map<String, dynamic> b, Offset at, ColorScheme scheme) {
    final slug = b['slug'] as String;
    final status = _status(widget.threads[slug]);
    return Positioned(
      left: at.dx,
      top: at.dy,
      width: cell.width,
      height: cell.height,
      child: Semantics(
        button: true,
        label: '${b['name']}: $status',
        hint: 'Opens its chat',
        onTap: () => widget.onOpen(slug),
        excludeSemantics: true,
        child: InkWell(
          borderRadius: BorderRadius.circular(16),
          onTap: () => widget.onOpen(slug),
          child: Column(
            children: [
              const SizedBox(height: headroom + robot * 1.3),
              Text(
                b['name'] as String,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.labelLarge,
              ),
              Text(
                status,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.labelSmall?.copyWith(
                  color: status == 'Needs you' ? scheme.error : scheme.outline,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _robot(Map<String, dynamic> b, Offset at, bool flip, bool full) {
    final slug = b['slug'] as String;
    final v = widget.threads[slug];
    return AnimatedPositioned(
      key: ValueKey(slug),
      // Calm and off never travel, so nothing to animate.
      duration: full ? walk : Duration.zero,
      curve: Curves.easeInOut,
      left: at.dx + (cell.width - robot) / 2,
      top: at.dy + headroom,
      // Taps go through to the spot underneath.
      child: IgnorePointer(
        child: BotAvatar(
          key: faces.putIfAbsent(slug, GlobalKey<BotAvatarState>.new),
          slug: faceOf(b, slug),
          mood: v?.mood ?? 0,
          doing: v?.doingKind ?? 0,
          size: robot,
          body: true,
          flip: flip,
        ),
      ),
    );
  }

  Widget _ticket(
    Map<String, dynamic> o,
    Offset at,
    String Function(String) name,
    ColorScheme scheme,
  ) {
    final id = o['id'] as int;
    final blocked = o['blocked'] == true;
    final said =
        '${name(o['asked_by'] as String)} is waiting on '
        '${name(o['bot'] as String)}, OB-$id${blocked ? ', blocked on a card' : ''}';
    return Positioned(
      left: at.dx - 60,
      top: at.dy - 14,
      width: 120,
      child: Center(
        child: Tooltip(
          message: said,
          child: Semantics(
            button: true,
            label: said,
            hint: 'Opens the ticket',
            onTap: () => showTicket(context, widget.api, id),
            excludeSemantics: true,
            child: Material(
              color: scheme.surfaceContainerHigh,
              shape: const StadiumBorder(),
              child: InkWell(
                customBorder: const StadiumBorder(),
                onTap: () => showTicket(context, widget.api, id),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 6,
                  ),
                  child: Text(
                    'OB-$id${blocked ? ' · blocked' : ''}',
                    style: Theme.of(context).textTheme.labelSmall?.copyWith(
                      color: blocked ? scheme.error : scheme.onSurface,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// A thin line from each asker to the teammate that has its job, arched
/// towards a bend point.
class _Lines extends CustomPainter {
  _Lines(this.lines);
  final List<(Offset, Offset, Offset, Color)> lines;

  @override
  void paint(Canvas canvas, Size size) {
    for (final (from, bend, to, colour) in lines) {
      canvas.drawPath(
        Path()
          ..moveTo(from.dx, from.dy)
          ..quadraticBezierTo(bend.dx, bend.dy, to.dx, to.dy),
        Paint()
          ..color = colour
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.5,
      );
    }
  }

  @override
  bool shouldRepaint(_Lines old) => !listEquals(old.lines, lines);
}
