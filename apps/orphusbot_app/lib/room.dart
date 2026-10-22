// The Ideas Room (DESIGN §12.5, D-052): a live, hands-free conversation with
// Grok's realtime voice, speaking for the Orchestrator and asking it for
// anything about Kelvin's own work. Tap to start, just talk, talk over it any
// time, tap to end. The orb shows what's happening: cool blues listening,
// violet swirling while it thinks, green racing while it looks something up,
// warm pinks while it speaks. Soft looping sounds mark thinking and research.
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
  const IdeasRoom({super.key, required this.api, this.bot = 'orchestrator'});
  final Api api;
  final String bot;

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
  final orchestrator = OrchestratorLine();
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

  @override
  void initState() {
    super.initState();
    orchestrator.start(widget.api, widget.bot);
  }

  @override
  void dispose() {
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
    _cue(cueFor(p));
  }

  Future<void> _start() async {
    setState(() {
      note = null;
      heard = '';
      reply = '';
    });
    final voice = LiveVoice(
      api: widget.api,
      ask: (name, args) => orchestrator.ask(widget.api, widget.bot, name, args),
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
    try {
      await voice.start();
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
    await live?.stop();
    if (mounted) setState(() => live = null);
    _setPhase(Phase.idle);
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

  @override
  Widget build(BuildContext context) {
    final caption = TextStyle(color: Colors.white.withValues(alpha: 0.9));
    final quiet = TextStyle(color: Colors.white.withValues(alpha: 0.55));
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
                Expanded(
                  child: AnimatedBuilder(
                    animation: spin,
                    builder: (_, _) => CustomPaint(
                      painter: Orb(
                        time: spin.value,
                        phase: phase,
                        level: level,
                      ),
                      size: Size.infinite,
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 24),
                  child: Column(
                    children: [
                      Text(switch (phase) {
                        Phase.idle => 'Tap to start a conversation',
                        Phase.connecting => 'Connecting…',
                        Phase.listening => 'Listening… just talk; tap to end',
                        Phase.thinking => 'Thinking…',
                        Phase.researching => 'Looking into it…',
                        Phase.speaking => 'Talk any time to cut in',
                      }, style: quiet),
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

/// Grok's line to the Orchestrator: a function call becomes a room message
/// in the Orchestrator's thread, and its reply is the function's answer.
class OrchestratorLine {
  final thread = t.ThreadView();
  StreamSubscription<Map<String, dynamic>>? _events;
  Completer<String>? _waiting;
  int _from = 0;

  void start(Api api, String bot) {
    _events = api.events().listen((e) {
      if (e['bot'] != bot) return;
      thread.apply(e);
      final w = _waiting;
      if (w != null && e['type'] == 'run_ended') {
        _waiting = null;
        final fresh = thread.items
            .skip(_from)
            .whereType<t.Message>()
            .where((m) => !m.mine);
        w.complete(
          fresh.isEmpty ? "The Orchestrator didn't answer." : fresh.last.text,
        );
      }
    }, onError: (_) {});
  }

  void stop() => _events?.cancel();

  Future<String> ask(
    Api api,
    String bot,
    String name,
    Map<String, dynamic> args,
  ) async {
    final request = switch (name) {
      'save_idea' =>
        'Save this idea brief into the team wiki as wiki/ideas/<a short slug of the title>.md, '
            'add it to the wiki index, then reply only with where you saved it.\n\n'
            'Title: ${args['title']}\n\n${args['brief']}',
      _ => args['request'] as String? ?? '',
    };
    if (request.trim().isEmpty) return 'Nothing was asked.';
    final done = Completer<String>();
    _waiting = done;
    _from = thread.items.length;
    await api.send(bot, request, room: true);
    return done.future.timeout(
      const Duration(seconds: 90),
      onTimeout: () {
        _waiting = null;
        return 'The Orchestrator is still working on it; the answer will be in its chat.';
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
