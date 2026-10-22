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

enum LiveState { connecting, listening, hearing, thinking, speaking, closed }

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
  AudioSource? _out;
  SoundHandle? _playing;
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
          _set(LiveState.speaking);
        }
        SoLoud.instance.addAudioDataStream(_out!, pcm);
        onLevel(pcmLevel(pcm));
      case 'response.output_audio.done' || 'response.audio.done':
        if (_out != null) SoLoud.instance.setDataIsEnded(_out!);
      case 'response.done':
        _out = null;
        // Back to listening once the last words have played.
        Future<void>.delayed(const Duration(milliseconds: 600), () {
          if (_state == LiveState.speaking) _set(LiveState.listening);
        });
      case 'response.function_call_arguments.done':
        _set(LiveState.thinking);
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

  Future<void> _hush() async {
    final h = _playing;
    _playing = null;
    _out = null;
    if (h != null) await SoLoud.instance.stop(h);
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
