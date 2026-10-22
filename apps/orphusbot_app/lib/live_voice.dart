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
  });

  final Api api;

  /// Answers a function call (`ask_orchestrator`, `save_idea`) with text.
  final Future<String> Function(String name, Map<String, dynamic> args) ask;
  final void Function(LiveState) onState;
  final void Function(double) onLevel;
  final void Function(String) onYou;
  final void Function(String) onReply;
  final void Function(String) onError;

  WebSocket? _ws;
  final _recorder = AudioRecorder();
  StreamSubscription<Uint8List>? _mic;
  // One stream for Grok's voice for the whole conversation, so replies play
  // one after another and never over each other; and when what's queued in it
  // will have finished playing.
  AudioSource? _out;
  SoundHandle? _playing;
  DateTime _playsUntil = DateTime.now();

  /// On a computer the speakers reach the microphone, so while Grok talks the
  /// mic is only sent when Kelvin is clearly louder than its echo. Phones
  /// cancel the echo themselves and stay fully hands-free.
  final bool _speakers = !(Platform.isAndroid || Platform.isIOS);
  static const _talkingOver = 0.35;

  bool get _grokTalking => DateTime.now().isBefore(_playsUntil);
  String _reply = '';
  LiveState _state = LiveState.connecting;

  void _set(LiveState s) {
    _state = s;
    onState(s);
  }

  void _send(Map<String, Object?> event) => _ws?.add(jsonEncode(event));

  Future<void> start() async {
    _set(LiveState.connecting);
    final got =
        await api.postJson('/api/room/voice', {}) as Map<String, dynamic>;
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
      final level = pcmLevel(chunk);
      if (_speakers && _grokTalking) {
        if (level < _talkingOver) return; // Its own voice through the speakers.
        _hush(); // Kelvin is talking over it.
      }
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
    switch (e['type']) {
      case 'input_audio_buffer.speech_started':
        // The owner is talking: stop Grok mid-sentence.
        await _hush();
        _set(LiveState.hearing);
      case 'input_audio_buffer.speech_stopped':
        _set(LiveState.thinking);
      case 'conversation.item.input_audio_transcription.completed':
        onYou((e['transcript'] as String? ?? '').trim());
      case 'response.created':
        _reply = '';
      case 'response.output_item.added':
        // Anything but its spoken answer is a lookup: a call to the
        // Orchestrator, a wiki save, or a web search on xAI's side.
        final kind = (e['item'] as Map?)?['type'];
        if (kind != null && kind != 'message') _set(LiveState.researching);
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
        final start = _grokTalking ? _playsUntil : DateTime.now();
        _playsUntil = start.add(
          Duration(microseconds: pcm.length * 1000000 ~/ 48000),
        );
        onLevel(pcmLevel(pcm));
      case 'response.done':
        // Back to listening once the last queued words have played; the
        // stream stays open for the next reply.
        final left = _playsUntil.difference(DateTime.now());
        Future<void>.delayed(
          left.isNegative
              ? Duration.zero
              : left + const Duration(milliseconds: 200),
          () {
            if (_state == LiveState.speaking && !_grokTalking) {
              _set(LiveState.listening);
            }
          },
        );
      case 'response.function_call_arguments.done':
        _set(LiveState.researching);
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
    _set(LiveState.thinking);
  }

  bool get isOpen => _state != LiveState.closed && _ws != null;

  /// Stops Grok mid-sentence and drops what was queued; the next reply opens
  /// a fresh stream.
  Future<void> _hush() async {
    final h = _playing;
    final src = _out;
    _playing = null;
    _out = null;
    _playsUntil = DateTime.now();
    if (h != null) await SoLoud.instance.stop(h);
    if (src != null) await SoLoud.instance.disposeSource(src);
  }

  Future<void> stop() async {
    if (_state == LiveState.closed) return;
    _set(LiveState.closed);
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
