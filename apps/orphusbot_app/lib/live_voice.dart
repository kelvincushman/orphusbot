// The Ideas Room's live voice (DESIGN §12.5, D-052): a hands-free conversation
// with Grok's realtime voice, which speaks for the Orchestrator. The server
// hands out a five-minute token and the session (instructions, voice, tools);
// the microphone streams to xAI as 24 kHz PCM, Grok's voice streams back and
// plays as it arrives, and server-side voice detection lets the owner talk
// over it. Anything about Kelvin's own work goes to the Orchestrator through
// the ask_orchestrator function, answered by [ask].
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_soloud/flutter_soloud.dart';
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';

import 'api.dart';

/// How loud a chunk of 16-bit little-endian PCM is, from 0 (silence) to 1.
double pcmLevel(Uint8List pcm) {
  final n = pcm.length ~/ 2;
  if (n == 0) return 0;
  final data = ByteData.sublistView(pcm);
  var sum = 0.0;
  for (var i = 0; i < n; i++) {
    final s = data.getInt16(i * 2, Endian.little) / 32768;
    sum += s * s;
  }
  // Speech sits around 0.02 to 0.2 RMS; stretch that to fill the orb.
  return (sqrt(sum / n) * 5).clamp(0.0, 1.0);
}

/// A diagnostic trail of the room's last conversation (no audio or words):
/// events, states and interruptions, in the app's cache folder as room.log.
IOSink? _logFile;
final _started = DateTime.now();
Future<void> openRoomLog() async {
  try {
    final dir = Directory(
      Platform.isLinux
          ? '${Platform.environment['HOME']}/.cache/orphusbot'
          : (await getApplicationSupportDirectory()).path,
    );
    await dir.create(recursive: true);
    _logFile = File('${dir.path}/room.log').openWrite();
  } catch (_) {}
}

void _log(String line) {
  final t = DateTime.now().difference(_started).inMilliseconds / 1000;
  _logFile?.writeln('${t.toStringAsFixed(2)} $line');
}

enum LiveState {
  connecting,
  listening,
  hearing,
  thinking,
  researching,
  speaking,
  closed,
}

class LiveVoice {
  LiveVoice({
    required this.api,
    required this.ask,
    required this.onState,
    required this.onLevel,
    required this.onYou,
    required this.onReply,
    required this.onError,
    this.onTurn,
  });

  final Api api;

  /// Answers a function call (`ask_orchestrator`, `save_idea`) with text.
  final Future<String> Function(String name, Map<String, dynamic> args) ask;
  final void Function(LiveState) onState;
  final void Function(double) onLevel;
  final void Function(String) onYou;
  final void Function(String) onReply;
  final void Function(String) onError;

  /// Each finished turn, for the session's transcript: who and what.
  final void Function(String who, String text)? onTurn;

  /// The server's record of this conversation (its memory), once started.
  int? sessionId;

  WebSocket? _ws;
  final _recorder = AudioRecorder();
  StreamSubscription<Uint8List>? _mic;
  // One stream for Grok's voice for the whole conversation, so replies play
  // one after another and never over each other; and when what's queued in it
  // will have finished playing.
  AudioSource? _out;
  SoundHandle? _playing;
  // How much audio has been queued on the stream; what's actually been
  // played comes from SoLoud, so "still talking" is the real remainder (plus a
  // moment for the speakers' tail), not a guess from when audio arrived.
  Duration _queued = Duration.zero;
  static const _tail = Duration(milliseconds: 400);

  /// On a computer the speakers reach the microphone loudly enough to sound
  /// like Kelvin, so while Grok talks (or a cue plays) the mic isn't sent at
  /// all; he interrupts by tapping the orb ([interrupt]). Phones cancel the
  /// echo themselves and can be talked over.
  final bool _speakers = !(Platform.isAndroid || Platform.isIOS);

  /// What's left of Grok's queued voice to play, as heard.
  Duration get _remaining {
    final out = _out;
    if (out == null) return Duration.zero;
    try {
      final left = _queued - SoLoud.instance.getStreamTimeConsumed(out);
      return left.isNegative ? Duration.zero : left;
    } catch (_) {
      return Duration.zero;
    }
  }

  // When the voice went (or will go) quiet; the tail after it still counts
  // as talking, since the room's echo lingers a moment.
  DateTime _silentAt = DateTime.fromMillisecondsSinceEpoch(0);

  bool get _grokTalking {
    final left = _remaining;
    if (left > Duration.zero) {
      _silentAt = DateTime.now().add(left);
      return true;
    }
    return DateTime.now().isBefore(_silentAt.add(_tail));
  }

  /// Set by the room while a thinking or research cue plays: on a computer
  /// that sound reaches the mic too, and mustn't be heard as Kelvin talking.
  bool cueOn = false;

  // What to show once Grok's queued words have played (thinking, research):
  // a cue never starts over its voice.
  LiveState? _next;
  Timer? _quiet;

  /// Moves to [s] now, or as soon as Grok has finished speaking.
  void _after(LiveState s) {
    if (_grokTalking) {
      _next = s;
      _armQuiet();
    } else {
      _set(s);
    }
  }

  /// When the queued voice ends: the waiting state, or back to listening.
  void _armQuiet() {
    _quiet?.cancel();
    _quiet = Timer(_remaining + _tail, () {
      if (_grokTalking) return _armQuiet();
      final next = _next ?? LiveState.listening;
      _next = null;
      if (_state == LiveState.speaking) _set(next);
    });
  }

  String _reply = '';
  LiveState _state = LiveState.connecting;

  /// Thinking or researching never lasts for ever: with no reply in this
  /// long, it goes back to listening (and its sound stops).
  static const _maxWait = {
    LiveState.thinking: Duration(seconds: 15),
    LiveState.researching: Duration(minutes: 2),
  };
  Timer? _watchdog;

  void _set(LiveState s) {
    _log('state ${s.name}');
    _watchdog?.cancel();
    final wait = _maxWait[s];
    if (wait != null) {
      _watchdog = Timer(wait, () {
        if (_state == s) {
          _log('gave up waiting in ${s.name}');
          _set(LiveState.listening);
        }
      });
    }
    _state = s;
    onState(s);
  }

  void _send(Map<String, Object?> event) => _ws?.add(jsonEncode(event));

  Future<void> start() async {
    await openRoomLog();
    _set(LiveState.connecting);
    final got =
        await api.postJson('/api/room/voice', {}) as Map<String, dynamic>;
    sessionId = (got['session_id'] as num?)?.toInt();
    if (!SoLoud.instance.isInitialized) await SoLoud.instance.init();
    _ws = await WebSocket.connect(
      got['url'] as String,
      headers: {'Authorization': 'Bearer ${got['token']}'},
    );
    _ws!.listen(
      (m) => m is String ? _event(jsonDecode(m) as Map<String, dynamic>) : null,
      onDone: () => stop(),
      onError: (Object e) => onError('Voice connection: $e'),
    );
    _send({'type': 'session.update', 'session': got['session']});
    if (!await _recorder.hasPermission()) {
      onError('Allow the microphone to talk in the room.');
      return stop();
    }
    final stream = await _recorder.startStream(
      const RecordConfig(
        encoder: AudioEncoder.pcm16bits,
        sampleRate: 24000,
        numChannels: 1,
        echoCancel: true,
        noiseSuppress: true,
      ),
    );
    _mic = stream.listen((chunk) {
      if (_speakers && (_grokTalking || cueOn)) return;
      _send({
        'type': 'input_audio_buffer.append',
        'audio': base64Encode(chunk),
      });
      if (_state == LiveState.listening || _state == LiveState.hearing) {
        onLevel(pcmLevel(chunk));
      }
    });
    _set(LiveState.listening);
  }

  Future<void> _event(Map<String, dynamic> e) async {
    final type = e['type'] as String? ?? '';
    if (!type.endsWith('.delta')) {
      final item = (e['item'] as Map?)?['type'];
      _log('event $type${item == null ? '' : ' ($item)'}');
    }
    switch (e['type']) {
      case 'input_audio_buffer.speech_started':
        // The owner is talking: stop Grok mid-sentence.
        _next = null;
        await _hush();
        _set(LiveState.hearing);
      case 'input_audio_buffer.speech_stopped':
        _after(LiveState.thinking);
      case 'conversation.item.input_audio_transcription.completed':
        final said = (e['transcript'] as String? ?? '').trim();
        onYou(said);
        if (said.isNotEmpty) onTurn?.call('Kelvin', said);
      case 'response.output_audio_transcript.done':
        final said = (e['transcript'] as String? ?? _reply).trim();
        if (said.isNotEmpty) onTurn?.call('Grok', said);
      case 'response.created':
        _reply = '';
      case 'response.output_item.added':
        // Anything but its spoken answer is a lookup: a call to the
        // Orchestrator, a wiki save, or a web search on xAI's side.
        final kind = (e['item'] as Map?)?['type'];
        if (kind != null && kind != 'message') _after(LiveState.researching);
      case 'response.output_audio_transcript.delta':
        _reply += e['delta'] as String? ?? '';
        onReply(_reply);
      case 'response.output_audio.delta' || 'response.audio.delta':
        final pcm = base64Decode(e['delta'] as String? ?? '');
        if (_out == null) {
          _out = SoLoud.instance.setBufferStream(
            bufferingType: BufferingType.released,
            bufferingTimeNeeds: 0.1,
            sampleRate: 24000,
            channels: Channels.mono,
            format: BufferType.s16le,
          );
          _playing = SoLoud.instance.play(_out!);
        }
        if (_state != LiveState.speaking) _set(LiveState.speaking);
        SoLoud.instance.addAudioDataStream(_out!, pcm);
        // 24 kHz, 16-bit mono: 48,000 bytes a second.
        _queued += Duration(microseconds: pcm.length * 1000000 ~/ 48000);
        _armQuiet();
        onLevel(pcmLevel(pcm));
      case 'response.done':
        // Back to listening (or what's waiting) once the queued words have
        // played; the stream stays open for the next reply. A reply with
        // nothing said (no audio) ends the thinking too.
        _armQuiet();
        if (!_grokTalking && _state == LiveState.thinking) {
          _set(LiveState.listening);
        }
      case 'response.function_call_arguments.done':
        _after(LiveState.researching);
        String output;
        try {
          final args = jsonDecode(e['arguments'] as String? ?? '{}');
          output = await ask(e['name'] as String, args as Map<String, dynamic>);
        } catch (err) {
          output = "That didn't work: $err";
        }
        _send({
          'type': 'conversation.item.create',
          'item': {
            'type': 'function_call_output',
            'call_id': e['call_id'],
            'output': output,
          },
        });
        _send({'type': 'response.create'});
      case 'error':
        onError('Grok: ${(e['error'] as Map?)?['message'] ?? e}');
    }
  }

  /// Kelvin tapped the orb: stop Grok now and drop what it was going to say.
  Future<void> interrupt() async {
    _log('interrupted by tap');
    _next = null;
    _send({'type': 'response.cancel'});
    await _hush();
    _set(LiveState.listening);
  }

  /// Something typed: said into the same conversation.
  void sendText(String text) {
    _send({
      'type': 'conversation.item.create',
      'item': {
        'type': 'message',
        'role': 'user',
        'content': [
          {'type': 'input_text', 'text': text},
        ],
      },
    });
    _send({'type': 'response.create'});
    _after(LiveState.thinking);
  }

  bool get isOpen => _state != LiveState.closed && _ws != null;

  /// Stops Grok mid-sentence and drops what was queued; the next reply opens
  /// a fresh stream.
  Future<void> _hush() async {
    if (_playing != null) _log('voice stopped');
    final h = _playing;
    final src = _out;
    _playing = null;
    _out = null;
    _queued = Duration.zero;
    _silentAt = DateTime.fromMillisecondsSinceEpoch(0);
    _quiet?.cancel();
    if (h != null) await SoLoud.instance.stop(h);
    if (src != null) await SoLoud.instance.disposeSource(src);
  }

  Future<void> stop() async {
    if (_state == LiveState.closed) return;
    _set(LiveState.closed);
    _watchdog?.cancel();
    _quiet?.cancel();
    await _mic?.cancel();
    try {
      await _recorder.stop();
    } catch (_) {}
    await _hush();
    await _ws?.close();
    _ws = null;
  }

  Future<void> dispose() async {
    await stop();
    await _recorder.dispose();
  }
}
