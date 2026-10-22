// The Ideas Room (DESIGN §12.5): talking with the Orchestrator by voice to
// get ideas ready. Tap the microphone, speak, tap again: the box writes it
// down (qwen-stt), the Orchestrator answers as a spoken conversation, and the
// reply is read aloud (ElevenLabs). The orb shows who's doing what: cool and
// close while it listens (moving with your voice), swirling while it thinks,
// warm and pulsing while it speaks.
import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';

import 'api.dart';
import 'thread.dart' as t;

enum Phase { idle, listening, writing, thinking, speaking }

/// The finished sentences in [text] after [from], joined into chunks of at
/// least [min] characters so the voice doesn't stutter, and where the next
/// look should start. A sentence ends at . ! ? or a new line followed by space.
(List<String>, int) sentencesAfter(String text, int from, {int min = 40}) {
  final out = <String>[];
  var start = from;
  var buffer = StringBuffer();
  final end = RegExp(r'[.!?\n]+(\s+)');
  for (final m in end.allMatches(text, from)) {
    // Keep the space after it, so joined sentences read naturally.
    buffer.write(text.substring(start, m.end));
    start = m.end;
    if (buffer.toString().trim().length >= min) {
      out.add(buffer.toString().trim());
      buffer = StringBuffer();
      from = start;
    }
  }
  return (out, from);
}

/// A microphone level in dBFS (about -60 quiet to 0 loud) as 0 to 1.
double levelOf(double dbfs) => ((dbfs + 55) / 50).clamp(0.0, 1.0);

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
  final recorder = AudioRecorder();
  final player = Player();
  final view = t.ThreadView();
  final typed = TextEditingController();
  StreamSubscription<Map<String, dynamic>>? events;
  StreamSubscription<Amplitude>? amplitude;
  Phase phase = Phase.idle;
  double level = 0;
  String heard = '';
  String reply = '';
  String? note;
  // Replies before this count were already there when we asked.
  int? waitingFrom;
  // Speaking while it writes: how far into the reply has been sent to the
  // voice, the clips waiting to play in order, and whether the run has ended.
  int spokenTo = 0;
  final clips = <Uint8List>[];
  Future<void> voicing = Future.value();
  int voicesPending = 0;
  bool playing = false;
  bool ended = true;

  @override
  void initState() {
    super.initState();
    events = widget.api.events().listen((e) {
      if (e['bot'] != widget.bot) return;
      setState(() => view.apply(e));
      if (waitingFrom == null) return;
      if (view.streaming != null) {
        setState(() => reply = view.streaming!);
        _speakFinished(view.streaming!);
      }
      if (e['type'] == 'run_ended') _replied();
    }, onError: (_) {});
    player.stream.completed.listen((done) {
      if (!done || !mounted) return;
      playing = false;
      _playNext();
    });
  }

  @override
  void dispose() {
    events?.cancel();
    amplitude?.cancel();
    recorder.dispose();
    player.dispose();
    spin.dispose();
    typed.dispose();
    super.dispose();
  }

  Future<void> _listen() async {
    if (phase == Phase.speaking) await _hush();
    if (!await recorder.hasPermission()) {
      setState(() => note = 'Allow the microphone to talk in the room.');
      return;
    }
    final dir = await getTemporaryDirectory();
    await recorder.start(
      const RecordConfig(
        encoder: AudioEncoder.wav,
        sampleRate: 16000,
        numChannels: 1,
      ),
      path: '${dir.path}/ideas-room.wav',
    );
    amplitude = recorder
        .onAmplitudeChanged(const Duration(milliseconds: 80))
        .listen((a) => setState(() => level = levelOf(a.current)));
    setState(() {
      phase = Phase.listening;
      note = null;
    });
  }

  Future<void> _stopListening() async {
    await amplitude?.cancel();
    final path = await recorder.stop();
    setState(() {
      phase = Phase.writing;
      level = 0;
    });
    try {
      final bytes = await File(path!).readAsBytes();
      final text = await widget.api.transcribe(bytes);
      if (text.trim().isEmpty) {
        setState(() {
          phase = Phase.idle;
          note = "I didn't catch that. Try again a bit closer.";
        });
        return;
      }
      await _say(text);
    } catch (e) {
      setState(() {
        phase = Phase.idle;
        note = explain(e);
      });
    }
  }

  /// Sends what was said (or typed) to the Orchestrator as a room message.
  Future<void> _say(String text) async {
    setState(() {
      heard = text.trim();
      reply = '';
      phase = Phase.thinking;
      waitingFrom = view.items.length;
      spokenTo = 0;
      ended = false;
    });
    try {
      await widget.api.send(widget.bot, heard, room: true);
    } catch (e) {
      setState(() {
        phase = Phase.idle;
        waitingFrom = null;
        note = explain(e);
      });
    }
  }

  /// Sends each finished sentence to the voice as soon as it's written.
  void _speakFinished(String text) {
    final (chunks, to) = sentencesAfter(text, spokenTo);
    spokenTo = to;
    chunks.forEach(_voice);
  }

  /// Voices [text] in order with the rest, then queues it to play.
  void _voice(String text) {
    voicesPending++;
    voicing = voicing.then((_) async {
      try {
        final audio = await widget.api.speak(text);
        clips.add(Uint8List.fromList(audio));
        _playNext();
      } catch (e) {
        if (mounted) setState(() => note = 'Voice: ${explain(e)}');
      } finally {
        voicesPending--;
        _maybeDone();
      }
    });
  }

  Future<void> _playNext() async {
    if (playing || !mounted) return;
    if (clips.isEmpty) return _maybeDone();
    playing = true;
    setState(() => phase = Phase.speaking);
    await player.open(await Media.memory(clips.removeAt(0)));
  }

  /// Back to idle once the run has ended and every clip has played.
  void _maybeDone() {
    if (ended && !playing && clips.isEmpty && voicesPending == 0 && mounted) {
      setState(() {
        if (phase == Phase.speaking || phase == Phase.thinking) {
          phase = Phase.idle;
        }
      });
    }
  }

  /// The run ended: voice whatever the stream hadn't finished yet.
  Future<void> _replied() async {
    final from = waitingFrom;
    if (from == null) return;
    waitingFrom = null;
    final fresh = view.items
        .skip(from)
        .whereType<t.Message>()
        .where((m) => !m.mine);
    if (fresh.isNotEmpty) {
      final text = fresh.last.text;
      setState(() => reply = text);
      // The rest after what's been voiced (or all of it if nothing streamed).
      final rest = spokenTo <= text.length
          ? text.substring(spokenTo).trim()
          : '';
      if (rest.isNotEmpty) _voice(rest);
    }
    ended = true;
    _maybeDone();
  }

  /// Stops the voice and drops what was still to come.
  Future<void> _hush() async {
    clips.clear();
    await player.stop();
    playing = false;
    setState(() => phase = Phase.idle);
  }

  void _mic() {
    switch (phase) {
      case Phase.listening:
        _stopListening();
      case Phase.writing || Phase.thinking:
        break;
      case Phase.idle || Phase.speaking:
        _listen();
    }
  }

  @override
  Widget build(BuildContext context) {
    final caption = TextStyle(color: Colors.white.withValues(alpha: 0.9));
    final quiet = TextStyle(color: Colors.white.withValues(alpha: 0.55));
    return Theme(
      data: ThemeData.dark(useMaterial3: true),
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
                child: GestureDetector(
                  // Tapping the orb while it talks stops it.
                  onTap: phase == Phase.speaking ? _hush : null,
                  child: AnimatedBuilder(
                    animation: spin,
                    builder: (_, _) => CustomPaint(
                      painter: Orb(
                        time: spin.value,
                        phase: phase,
                        level: phase == Phase.speaking
                            // Speaking has no live level; a lively stand-in.
                            ? 0.45 + 0.35 * sin(spin.value * 2 * pi * 9).abs()
                            : level,
                      ),
                      size: Size.infinite,
                    ),
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 24),
                child: Column(
                  children: [
                    Text(switch (phase) {
                      Phase.idle => 'Tap the microphone and talk',
                      Phase.listening => 'Listening… tap to send',
                      Phase.writing => 'Writing it down…',
                      Phase.thinking => 'Thinking…',
                      Phase.speaking => 'Tap the orb to stop',
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
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
                child: Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: typed,
                        onSubmitted: (v) {
                          if (v.trim().isEmpty) return;
                          typed.clear();
                          _say(v);
                        },
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
                        tooltip: phase == Phase.listening ? 'Send' : 'Talk',
                        style: IconButton.styleFrom(
                          backgroundColor: phase == Phase.listening
                              ? Colors.redAccent
                              : Colors.white,
                          foregroundColor: Colors.black,
                        ),
                        onPressed:
                            phase == Phase.writing || phase == Phase.thinking
                            ? null
                            : _mic,
                        icon: Icon(
                          phase == Phase.listening ? Icons.stop : Icons.mic,
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
    Phase.writing: [
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
    final speed = phase == Phase.thinking ? 3.0 : 1.0;
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
