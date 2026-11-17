// The Ideas Room (DESIGN §12.5, D-052): a live, hands-free conversation with
// Grok's realtime voice, speaking for the Orchestrator and asking it for
// anything about Kelvin's own work. Tap to start, just talk, talk over it any
// time, tap to end. The orb shows what's happening: cool blues listening,
// violet swirling while it thinks, green racing while it looks something up,
// warm pinks while it speaks. Soft looping sounds mark thinking and research.
// The same orb, as a panel over a bot's chat, is a call with that bot (D-074).
import 'dart:async';
import 'dart:math';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_soloud/flutter_soloud.dart';

import 'api.dart';
import 'live_voice.dart';
import 'thread.dart' as t;

enum Phase { idle, connecting, listening, thinking, researching, speaking }

Phase phaseOf(LiveState s) => switch (s) {
  LiveState.connecting => Phase.connecting,
  LiveState.listening || LiveState.hearing => Phase.listening,
  LiveState.thinking => Phase.thinking,
  LiveState.researching => Phase.researching,
  LiveState.speaking => Phase.speaking,
  LiveState.closed => Phase.idle,
};

/// The looping sound for a phase, if it has one (`assets/sounds/`).
String? cueFor(Phase p) => switch (p) {
  Phase.thinking => 'assets/sounds/thinking.mp3',
  Phase.researching => 'assets/sounds/research.mp3',
  _ => null,
};

class IdeasRoom extends StatefulWidget {
  const IdeasRoom({
    super.key,
    required this.api,
    this.bot = 'orchestrator',
    this.name = 'The Orchestrator',
    this.onClose,
  });
  final Api api;
  final String bot;

  /// The bot's name, as the voice says it.
  final String name;

  /// Set when it's a call in the bot's chat, not the room itself (D-074).
  final VoidCallback? onClose;

  @override
  State<IdeasRoom> createState() => _IdeasRoomState();
}

class _IdeasRoomState extends State<IdeasRoom>
    with SingleTickerProviderStateMixin {
  late final spin = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 12),
  )..repeat();
  final typed = TextEditingController();
  late final orchestrator = OrchestratorLine(
    inChat: inChat,
    name: widget.name,
    onNews: _news,
  );
  LiveVoice? live;
  Phase phase = Phase.idle;
  double level = 0;
  String heard = '';
  String reply = '';
  String? note;
  // The cue sound playing now, and which one.
  SoundHandle? cue;
  String? cuePath;
  final loaded = <String, AudioSource>{};
  // The conversation so far (the session's memory), and news for Grok (the
  // Orchestrator's live view, or a finished job on a call), waiting for a
  // pause to be passed on.
  final transcript = <String>[];
  Timer? chimeIn;
  String? news;
  int? sessionId;
  bool ending = false;
  // The last try at sending what was said to the chat failed.
  bool unsent = false;

  @override
  void initState() {
    super.initState();
    orchestrator.start(widget.api, widget.bot);
    if (inChat) WidgetsBinding.instance.addPostFrameCallback((_) => _start());
  }

  bool get inChat => widget.onClose != null;

  @override
  void dispose() {
    chimeIn?.cancel();
    _cue(null);
    live?.dispose();
    orchestrator.stop();
    spin.dispose();
    typed.dispose();
    super.dispose();
  }

  /// Plays the phase's looping sound, quietly, and stops the last one.
  Future<void> _cue(String? path) async {
    if (path == cuePath) return;
    cuePath = path;
    final old = cue;
    cue = null;
    if (old != null) {
      // A short fade, so changing sounds doesn't click.
      SoLoud.instance.fadeVolume(old, 0, const Duration(milliseconds: 250));
      SoLoud.instance.scheduleStop(old, const Duration(milliseconds: 260));
    }
    if (path == null || !SoLoud.instance.isInitialized) return;
    try {
      final src = loaded[path] ??= await SoLoud.instance.loadAsset(path);
      if (cuePath != path) return;
      cue = SoLoud.instance.play(src, volume: 0, looping: true);
      SoLoud.instance.fadeVolume(cue!, 0.15, const Duration(milliseconds: 300));
    } catch (_) {
      // The room works without its sounds.
    }
  }

  void _setPhase(Phase p) {
    if (!mounted) return;
    setState(() => phase = p);
    // News goes in at a pause, never over Grok.
    final said = news;
    if (p == Phase.listening &&
        live?.state == LiveState.listening &&
        said != null &&
        (live?.isOpen ?? false)) {
      news = null;
      live!.sendText(said);
    }
    final path = cueFor(p);
    // The voice holds the mic back while a cue plays (on computers).
    live?.cueOn = path != null;
    _cue(path);
  }

  Future<void> _start() async {
    setState(() {
      note = null;
      heard = '';
      reply = '';
    });
    final voice = LiveVoice(
      api: widget.api,
      path: inChat ? '/api/bots/${widget.bot}/voice' : '/api/room/voice',
      ask: (name, args) {
        if (name == 'save_idea') {
          widget.api
              .post('/api/room/ideas', {
                'session': live?.sessionId,
                'title': args['title'],
                'brief': args['brief'],
              })
              .catchError((_) {});
        }
        return orchestrator.ask(widget.api, widget.bot, name, args);
      },
      onTurn: (who, text) => transcript.add('$who: $text'),
      onState: (s) {
        if (s == LiveState.closed && mounted) setState(() => live = null);
        _setPhase(phaseOf(s));
      },
      onLevel: (v) {
        if (mounted) setState(() => level = v);
      },
      onYou: (text) {
        if (mounted && text.isNotEmpty) setState(() => heard = text);
      },
      onReply: (text) {
        if (mounted) setState(() => reply = text);
      },
      onError: (msg) {
        if (mounted) setState(() => note = msg);
      },
    );
    setState(() => live = voice);
    transcript.clear();
    try {
      await voice.start();
      sessionId = voice.sessionId;
      // Every few minutes of a longer talk, the Orchestrator gives its view.
      if (!inChat) {
        chimeIn = Timer.periodic(const Duration(minutes: 5), (_) => _chimeIn());
      }
    } catch (e) {
      await voice.stop();
      if (mounted) {
        setState(() {
          live = null;
          note = explain(e);
        });
        _setPhase(Phase.idle);
      }
    }
  }

  Future<void> _end() async {
    // One wrap-up at a time: a second tap mustn't send the transcript twice.
    if (ending) return;
    ending = true;
    try {
      chimeIn?.cancel();
      news = null;
      await live?.stop();
      if (mounted) setState(() => live = null);
      _setPhase(Phase.idle);
      await _wrapUp();
    } finally {
      ending = false;
    }
    // In the chat, what was said stays until it's sent: the panel stays open
    // with the error, and End tries again.
    if (!inChat || transcript.isEmpty) widget.onClose?.call();
  }

  /// The Orchestrator's view of the conversation so far, for Grok to pass on.
  Future<void> _chimeIn() async {
    // Not over one of Grok's own questions to it, or with too little said.
    if (transcript.length < 4 ||
        orchestrator.busy ||
        !(live?.isOpen ?? false)) {
      return;
    }
    final view = await orchestrator.ask(
      widget.api,
      widget.bot,
      'ask_orchestrator',
      {
        'request':
            "You've been listening in on Kelvin's Ideas Room conversation with Grok. "
            'In two or three sentences: the strongest point so far, the biggest risk, '
            'and one question worth exploring next.\n\n${_recent()}',
      },
    );
    if (mounted && (live?.isOpen ?? false)) {
      _news('(The Orchestrator has been listening and says: $view)');
    }
  }

  /// Passes [text] into the conversation at the next pause.
  void _news(String text) {
    if (!mounted || !(live?.isOpen ?? false)) return;
    news = news == null ? text : '$news\n$text';
    if (phase == Phase.listening) _setPhase(Phase.listening);
  }

  /// The last part of the conversation, short enough to send.
  String _recent([int chars = 12000]) {
    final all = transcript.join('\n');
    return all.length <= chars ? all : '…${all.substring(all.length - chars)}';
  }

  /// After a conversation: keep it as memory, ask the Orchestrator for its
  /// review in its chat, and ask Kelvin how it went.
  Future<void> _wrapUp() async {
    if (inChat) {
      // The chat is the record: the Orchestrator picks up what was said, even
      // if it was only the owner's turn.
      if (transcript.isNotEmpty) {
        try {
          // Marked as from the call, so it stays with this bot (the inbox's
          // triage skips it) and runs on its own model.
          await widget.api.send(
            widget.bot,
            voice: true,
            work: true,
            'Here is what was said on our call, for the record. What I asked '
            "or handed you on it has already reached you, so don't start it "
            'again; reply in a line or two with anything still open.'
            '\n\n${_recent()}',
          );
          transcript.clear();
          unsent = false;
        } catch (e) {
          if (mounted) {
            setState(() {
              unsent = true;
              note = 'Not sent to the chat yet: ${explain(e)}';
            });
          }
        }
      }
      return;
    }
    final id = sessionId;
    if (id == null || transcript.isEmpty) return;
    final text = transcript.join('\n');
    try {
      await widget.api.post('/api/room/sessions/end', {
        'id': id,
        'transcript': text,
      });
      if (transcript.length >= 2) {
        await widget.api.send(
          widget.bot,
          'Review this Ideas Room conversation for me: what\'s strong, the risks, '
          'what to check or research, and the next steps. Keep it short.\n\n${_recent()}',
        );
      }
    } catch (e) {
      if (mounted) setState(() => note = explain(e));
    }
    if (!mounted) return;
    final rated = await showModalBottomSheet<(int, String)>(
      context: context,
      backgroundColor: const Color(0xFF1C1C1E),
      builder: (_) => const RateSession(),
    );
    if (rated == null) return;
    try {
      await widget.api.post('/api/room/sessions/rate', {
        'id': id,
        'rating': rated.$1,
        'note': rated.$2,
      });
    } catch (_) {}
  }

  /// Typed text goes into the same live conversation, starting one if needed.
  Future<void> _type(String text) async {
    if (text.trim().isEmpty) return;
    typed.clear();
    if (live == null || !live!.isOpen) await _start();
    if (live?.isOpen ?? false) {
      setState(() => heard = text.trim());
      live!.sendText(text.trim());
    }
  }

  /// The orb; tapping it stops Grok (on a computer, the only way to cut in,
  /// since its voice reaches the mic).
  Widget _orb() => GestureDetector(
    behavior: HitTestBehavior.opaque,
    onTap:
        phase == Phase.speaking ||
            phase == Phase.thinking ||
            phase == Phase.researching
        ? () => live?.interrupt()
        : null,
    child: AnimatedBuilder(
      animation: spin,
      builder: (_, _) => CustomPaint(
        painter: Orb(time: spin.value, phase: phase, level: level),
        size: Size.infinite,
      ),
    ),
  );

  /// The same conversation as a panel above the chat's composer.
  Widget _panel(TextStyle caption, TextStyle quiet) => Theme(
    data: ThemeData.dark(useMaterial3: true),
    child: Container(
      color: Colors.black,
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
      child: Row(
        children: [
          SizedBox.square(dimension: 96, child: _orb()),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('On a call with ${widget.name}', style: caption),
                Text(_status, style: quiet),
                if (heard.isNotEmpty)
                  Text(
                    'You: $heard',
                    style: quiet,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                if (reply.isNotEmpty)
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxHeight: 72),
                    child: SingleChildScrollView(
                      reverse: true,
                      child: Text(reply, style: caption),
                    ),
                  ),
                if (note != null)
                  Text(note!, style: const TextStyle(color: Colors.redAccent)),
                // A way out when sending keeps failing, such as with no signal.
                if (unsent)
                  TextButton(
                    onPressed: () {
                      transcript.clear();
                      widget.onClose?.call();
                    },
                    child: const Text('Close without sending'),
                  ),
              ],
            ),
          ),
          IconButton.filled(
            tooltip: 'End',
            style: IconButton.styleFrom(
              backgroundColor: Colors.redAccent,
              foregroundColor: Colors.black,
            ),
            // Also when the session has already dropped: what was said still
            // has to reach the chat before the panel closes.
            onPressed: phase == Phase.connecting ? null : _end,
            icon: Icon(live == null ? Icons.close : Icons.call_end),
          ),
        ],
      ),
    ),
  );

  String get _status => switch (phase) {
    Phase.idle => 'Tap to start a conversation',
    Phase.connecting => 'Connecting…',
    Phase.listening => 'Listening… just talk; tap to end',
    Phase.thinking => 'Thinking…',
    Phase.researching => 'Looking into it…',
    Phase.speaking => 'Tap the orb to stop it',
  };

  @override
  Widget build(BuildContext context) {
    final caption = TextStyle(color: Colors.white.withValues(alpha: 0.9));
    final quiet = TextStyle(color: Colors.white.withValues(alpha: 0.55));
    if (inChat) return _panel(caption, quiet);
    return Theme(
      data: ThemeData.dark(useMaterial3: true),
      child: AnnotatedRegion<SystemUiOverlayStyle>(
        value: SystemUiOverlayStyle.light,
        child: Scaffold(
          backgroundColor: Colors.black,
          appBar: AppBar(
            backgroundColor: Colors.black,
            title: const Text('Ideas Room'),
          ),
          body: SafeArea(
            child: Column(
              children: [
                Expanded(child: _orb()),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 24),
                  child: Column(
                    children: [
                      Text(_status, style: quiet),
                      if (heard.isNotEmpty) ...[
                        const SizedBox(height: 10),
                        Text(
                          'You: $heard',
                          style: quiet,
                          textAlign: TextAlign.center,
                        ),
                      ],
                      if (reply.isNotEmpty) ...[
                        const SizedBox(height: 8),
                        ConstrainedBox(
                          constraints: const BoxConstraints(maxHeight: 160),
                          child: SingleChildScrollView(
                            reverse: true,
                            child: Text(
                              reply,
                              style: caption,
                              textAlign: TextAlign.center,
                            ),
                          ),
                        ),
                      ],
                      if (note != null) ...[
                        const SizedBox(height: 8),
                        Text(
                          note!,
                          style: const TextStyle(color: Colors.redAccent),
                        ),
                      ],
                    ],
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: typed,
                          onSubmitted: _type,
                          decoration: InputDecoration(
                            hintText: 'Or type',
                            filled: true,
                            fillColor: const Color(0xFF1C1C1E),
                            border: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(28),
                              borderSide: BorderSide.none,
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 12),
                      SizedBox.square(
                        dimension: 64,
                        child: IconButton.filled(
                          tooltip: live == null ? 'Talk' : 'End',
                          style: IconButton.styleFrom(
                            backgroundColor: live == null
                                ? Colors.white
                                : Colors.redAccent,
                            foregroundColor: Colors.black,
                          ),
                          onPressed: phase == Phase.connecting
                              ? null
                              : (live == null ? _start : _end),
                          icon: Icon(
                            live == null ? Icons.mic : Icons.call_end,
                            size: 30,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Grok's line to the bot. In the Ideas Room, `ask_orchestrator` becomes a
/// room message and its reply is the function's answer. On a call (D-074),
/// `ask` works the same on the quick model, and `do` starts real work and
/// answers "started"; when that run ends, [onNews] passes the result into
/// the call. A card the run waits on is never answered here: the voice is
/// told it needs Kelvin's tap on the screen (hard rule 5).
class OrchestratorLine {
  OrchestratorLine({
    this.inChat = false,
    this.name = 'The Orchestrator',
    this.onNews,
  });

  /// Grok is on a call in the bot's chat, not in the Ideas Room.
  final bool inChat;

  /// The bot's name, as the voice says it.
  final String name;

  /// Something to pass into the call at the next pause.
  final void Function(String)? onNews;
  final thread = t.ThreadView();
  StreamSubscription<Map<String, dynamic>>? _events;
  Completer<String>? _waiting;
  // A job from the call is running; its result goes to [onNews].
  bool _doing = false;
  // Jobs from the call still being sent: one may start a new run after the
  // last one ended, so the end of that run doesn't end [_doing].
  int _sending = 0;
  int _from = 0;

  /// The stream replays the whole history first, then the current state,
  /// which always starts with `nodes`. Until then nothing is acted on, so an
  /// old reply can't pass for a new one.
  final _live = Completer<void>();

  void start(Api api, String bot) {
    _events = api.events().listen((e) {
      if (e['type'] == 'nodes' || e['bot'] == bot) handle(e);
    }, onError: (_) {});
  }

  /// Folds in one of the bot's events, answering what's waiting on it.
  void handle(Map<String, dynamic> e) {
    if (e['type'] == 'nodes') {
      if (!_live.isCompleted) _live.complete();
      return;
    }
    thread.apply(e);
    if (!_live.isCompleted) return;
    switch (e['type']) {
      case 'dialog_opened' when inChat && (busy || _doing):
        final kind = ((e['dialog'] as Map?)?['kind'] as Map?)?['kind'];
        final need = kind == 'approval'
            ? 'needs your OK on the screen'
            : 'needs you on the screen';
        final w = _waiting;
        if (w != null) {
          // The answer comes later, once Kelvin has tapped.
          _waiting = null;
          _doing = true;
          w.complete('$name $need. It carries on once Kelvin has tapped.');
        } else {
          onNews?.call('($name $need.)');
        }
      case 'run_ended':
        final fresh = thread.items
            .skip(_from)
            .whereType<t.Message>()
            .where((m) => !m.mine);
        final reply = fresh.isEmpty ? null : fresh.last.text;
        final w = _waiting;
        if (w != null) {
          _waiting = null;
          _doing = _sending > 0;
          w.complete(reply ?? "$name didn't answer.");
        } else if (_doing) {
          _doing = _sending > 0;
          _from = thread.items.length;
          onNews?.call(
            e['outcome'] == 'completed'
                ? '($name has finished: ${reply ?? 'it said nothing more'})'
                : '($name stopped without finishing${reply == null ? '' : ': $reply'})',
          );
        }
    }
  }

  void stop() => _events?.cancel();

  /// Waiting on an answer already; one question at a time.
  bool get busy => _waiting != null;

  Future<String> ask(
    Api api,
    String bot,
    String tool,
    Map<String, dynamic> args,
  ) async {
    // Caught up with the history first (it's normally done long before Grok
    // has heard a word); a stream that never connects doesn't block the call.
    await _live.future.timeout(const Duration(seconds: 20), onTimeout: () {});
    if (tool == 'do') {
      final task = args['task'] as String? ?? '';
      if (task.trim().isEmpty) return 'Nothing was asked.';
      // A job sent now would join the question's run, on the quick model.
      if (busy) {
        return '$name is still answering your question. Hand it the job '
            'once the answer is in.';
      }
      if (!_doing) _from = thread.items.length;
      final already = _doing;
      _doing = true;
      _sending++;
      try {
        await api.send(bot, task, voice: true, work: true);
      } catch (_) {
        _doing = already;
        rethrow;
      } finally {
        _sending--;
      }
      return "Started. $name will say when it's finished.";
    }
    final request = switch (tool) {
      'save_idea' =>
        'Save this idea brief into the team wiki as wiki/ideas/<a short slug of the title>.md, '
            'add it to the wiki index, then reply only with where you saved it.\n\n'
            'Title: ${args['title']}\n\n${args['brief']}',
      _ => args['request'] as String? ?? '',
    };
    if (request.trim().isEmpty) return 'Nothing was asked.';
    // A job that was sent as its run ended joined that run: nothing is left.
    if (_doing && _sending == 0 && thread.run == t.RunState.idle) {
      _doing = false;
    }
    // The bot runs one thing at a time: a question would wait for the job,
    // or be steered into a run on the bot's own model.
    if (_doing) {
      return "$name is still on the job you gave it, so it can't answer yet. "
          "It will say when it's finished.";
    }
    if (inChat && thread.run != t.RunState.idle) {
      return "$name is busy with another task, so it can't answer quickly "
          'now. Hand it a job with do, or ask again when it has finished.';
    }
    final done = Completer<String>();
    _waiting = done;
    _from = thread.items.length;
    // The chat's voice stays in the chat's session, the room's in its own (D-063).
    try {
      await api.send(bot, request, room: !inChat, voice: inChat);
    } catch (_) {
      _waiting = null;
      rethrow;
    }
    return done.future.timeout(
      const Duration(seconds: 90),
      onTimeout: () {
        _waiting = null;
        // On a call, the answer still comes, as news.
        _doing = inChat;
        return '$name is still working on it; the answer will be in its chat.';
      },
    );
  }
}

/// The orb: a cloud of coloured light. Soft blobs drift round a centre; how
/// big and bright they are follows [level], and their colours follow [phase].
class Orb extends CustomPainter {
  Orb({required this.time, required this.phase, required this.level});
  final double time;
  final Phase phase;
  final double level;

  static const _palettes = {
    Phase.idle: [
      Color(0xFF00E5FF),
      Color(0xFF7C4DFF),
      Color(0xFF2979FF),
      Color(0xFFFF4081),
    ],
    Phase.listening: [
      Color(0xFF00E5FF),
      Color(0xFF18FFFF),
      Color(0xFF2979FF),
      Color(0xFF64FFDA),
    ],
    Phase.connecting: [
      Color(0xFF00E5FF),
      Color(0xFF7C4DFF),
      Color(0xFF2979FF),
      Color(0xFF64FFDA),
    ],
    Phase.thinking: [
      Color(0xFF7C4DFF),
      Color(0xFFE040FB),
      Color(0xFF536DFE),
      Color(0xFF00B0FF),
    ],
    Phase.researching: [
      Color(0xFF00E676),
      Color(0xFF1DE9B6),
      Color(0xFF00B0FF),
      Color(0xFF76FF03),
    ],
    Phase.speaking: [
      Color(0xFFFF4081),
      Color(0xFFFF9100),
      Color(0xFFE040FB),
      Color(0xFFFFD740),
    ],
  };

  @override
  void paint(Canvas canvas, Size size) {
    final c = size.center(Offset.zero);
    final base = min(size.width, size.height) * 0.22;
    final colours = _palettes[phase]!;
    // Thinking swirls faster; everything breathes a little.
    final speed = switch (phase) {
      Phase.thinking => 3.0,
      Phase.researching => 4.5,
      _ => 1.0,
    };
    final breathe = 1 + 0.06 * sin(time * 2 * pi * 2);
    final r = base * breathe * (1 + 0.35 * level);
    for (var i = 0; i < 6; i++) {
      final a = time * 2 * pi * speed + i * pi / 3;
      final drift = r * (0.32 + 0.12 * sin(time * 2 * pi * 3 + i));
      final centre = c + Offset(cos(a), sin(a * 1.3)) * drift;
      final colour = colours[i % colours.length];
      final blob = r * (0.75 + 0.2 * sin(time * 2 * pi * 2 + i * 1.7));
      canvas.drawCircle(
        centre,
        blob,
        Paint()
          ..shader = RadialGradient(
            colors: [
              colour.withValues(alpha: 0.85),
              colour.withValues(alpha: 0.0),
            ],
          ).createShader(Rect.fromCircle(center: centre, radius: blob))
          ..blendMode = BlendMode.plus
          ..imageFilter = ImageFilter.blur(sigmaX: 18, sigmaY: 18),
      );
    }
    // A bright core that swells with the voice.
    canvas.drawCircle(
      c,
      r * (0.35 + 0.25 * level),
      Paint()
        ..shader = RadialGradient(
          colors: [
            Colors.white.withValues(alpha: 0.75),
            Colors.white.withValues(alpha: 0),
          ],
        ).createShader(Rect.fromCircle(center: c, radius: r * 0.6)),
    );
  }

  @override
  bool shouldRepaint(Orb old) =>
      old.time != time || old.phase != phase || old.level != level;
}

/// After a conversation: was it useful? An optional note says why.
class RateSession extends StatefulWidget {
  const RateSession({super.key});

  @override
  State<RateSession> createState() => _RateSessionState();
}

class _RateSessionState extends State<RateSession> {
  final note = TextEditingController();
  int? rating;

  @override
  void dispose() {
    note.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Padding(
    padding: EdgeInsets.fromLTRB(
      20,
      20,
      20,
      20 + MediaQuery.of(context).viewInsets.bottom,
    ),
    child: Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Text(
          'Was that useful?',
          style: TextStyle(fontSize: 18, color: Colors.white),
        ),
        const SizedBox(height: 4),
        const Text(
          "The Orchestrator is writing its review in its chat. Your rating helps the next one.",
          style: TextStyle(color: Colors.white54),
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            for (final (value, icon) in const [
              (1, Icons.thumb_up_alt_outlined),
              (-1, Icons.thumb_down_alt_outlined),
            ])
              Padding(
                padding: const EdgeInsets.only(right: 8),
                child: ChoiceChip(
                  label: Icon(icon, size: 20),
                  selected: rating == value,
                  onSelected: (_) => setState(() => rating = value),
                ),
              ),
          ],
        ),
        TextField(
          controller: note,
          maxLength: 2000,
          minLines: 1,
          maxLines: 3,
          decoration: const InputDecoration(
            hintText: 'Anything to do differently next time? (optional)',
          ),
        ),
        Row(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Skip'),
            ),
            FilledButton(
              onPressed: rating == null
                  ? null
                  : () => Navigator.pop(context, (rating!, note.text.trim())),
              child: const Text('Send'),
            ),
          ],
        ),
      ],
    ),
  );
}
