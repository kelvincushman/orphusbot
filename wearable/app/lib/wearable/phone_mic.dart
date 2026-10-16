// Copyright (c) 2025-2026 Kelvin Lee. Licensed under MIT.
//
// PhoneMicStreamer — secondary audio path. Streams 16 kHz PCM from the phone
// microphone directly to Wearable's /api/device/ws/audio endpoint when the
// wearable is disconnected or out of range.
//
// Design notes:
//   - Uses the `record` package (no binary Opus encoder on-device; Wearable's
//     STT handles linear16 PCM just fine, at the cost of ~10× the bandwidth
//     vs Opus). Trade-off is acceptable over Wi-Fi / LAN.
//   - Auto-engages when `WearableDeviceBridge` observes BLE disconnect for
//     longer than [activationDelay] (wrapper caller decides — this class
//     is stateless about BLE state).
//   - Respects a global on/off switch stored in the existing KelvinLee shared
//     preferences key `'wearable.phoneMicEnabled'` (defaults to true).

import 'dart:async';
import 'dart:typed_data';

import 'package:record/record.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import 'wearable_client.dart';
import 'local_llm/audio_buffer.dart';
import 'local_llm/capture_mute.dart';
import 'local_llm/opus_pcm_decoder.dart';
import 'local_llm/server_stt.dart';
import 'local_llm/transcript_log.dart';
import 'local_llm/transcription_mode.dart';
import 'local_llm/zipformer_transcriber.dart';

class PhoneMicStreamer {
  /// Shared singleton used by the phone-mic capture toggle and other callers.
  static final PhoneMicStreamer instance = PhoneMicStreamer();

  PhoneMicStreamer({this.sampleRate = 16000});

  final int sampleRate;
  final AudioRecorder _recorder = AudioRecorder();
  WebSocketChannel? _ws;
  StreamSubscription<Uint8List>? _pcmSub;
  bool _running = false;

  // On-device path: when active, mic PCM is transcribed locally (continuous
  // VAD) instead of streamed to the WS. Phone mic is ambient by nature, so it
  // always uses continuous segmentation when on-device.
  bool _onDevice = false;
  UtteranceBuffer? _utteranceBuffer;

  bool get isRunning => _running;

  /// Starts streaming. Throws if mic permission denied or Wearable not paired.
  /// Idempotent — a second call is a no-op.
  Future<void> start() async {
    if (_running) return;
    if (!await _recorder.hasPermission()) {
      throw StateError('Microphone permission denied');
    }

    _onDevice = await TranscriptionSettings.mode() == TranscriptionMode.onDevice &&
        await ZipformerTranscriber.instance.isInstalled() &&
        await platformSupportsOnDevice();

    if (_onDevice) {
      _utteranceBuffer = UtteranceBuffer(
        sampleRate: sampleRate,
        onUtterance: _transcribeAndSend,
      );
    } else {
      _ws = await WearableClient.instance.openAudioStream(
        encoding: 'linear16',
        sampleRate: sampleRate,
        owner: 'phone_mic',
      );
    }

    final stream = await _recorder.startStream(RecordConfig(
      encoder: AudioEncoder.pcm16bits,
      sampleRate: sampleRate,
      numChannels: 1,
    ));

    _pcmSub = stream.listen(
      (chunk) {
        // Drop frames while muted — do NOT stop the recorder.
        if (CaptureMute.instance.muted) return;
        if (_onDevice) {
          _utteranceBuffer?.addContinuous(pcm16BytesToSamples(chunk));
          return;
        }
        final ws = _ws;
        if (ws == null) return;
        try {
          ws.sink.add(chunk);
        } catch (_) {
          // WS died — tear down; caller may restart on next BLE disconnect.
          stop();
        }
      },
      onError: (_) => stop().catchError((_) {}),
      onDone: () => stop().catchError((_) {}),
    );
    _running = true;
  }

  Future<void> _transcribeAndSend(Int16List samples) async {
    try {
      // Server STT first when configured, on-device zipformer as the fallback
      // (transcribeUtterance handles the server→local decision). The
      // UtteranceBuffer's silence gate is looser than the recogniser's own VAD,
      // so only forward clips that carry real speech energy to the network;
      // near-silence goes straight to the on-device model, which drops it.
      final text = _hasSpeechEnergy(samples)
          ? await transcribeUtterance(samples, sampleRate: sampleRate)
          : await ZipformerTranscriber.instance.transcribe(samples, sampleRate: sampleRate);
      if (text.trim().isEmpty || !_running) return;
      // Phone mic is always ambient — log locally before the network push so
      // the transcript appears in the Wearable tab even if Wearable is unreachable.
      OnDeviceTranscriptLog.instance.add(text, overheard: true);
      await WearableClient.instance.sendDeviceText(text: text, overheard: true);
    } catch (_) {
      // Drop a failed utterance; the next one will retry.
    }
  }

  /// Whether [s] carries enough speech to be worth sending to the server — at
  /// least 0.8 s and ambient-speech energy. Mirrors the wearable bridge's gate
  /// (raw speech RMS ~200–400, room ~60–100) so silence never leaves the phone.
  static bool _hasSpeechEnergy(Int16List s) =>
      s.length >= 12800 && pcmRms(s) >= 100.0;

  Future<void> stop() async {
    if (!_running) return;
    _running = false;
    try { await _recorder.stop(); } catch (_) { /* ignore */ }
    await _pcmSub?.cancel();
    _pcmSub = null;
    try { await _ws?.sink.close(); } catch (_) { /* ignore */ }
    _ws = null;
    _utteranceBuffer?.reset();
    _utteranceBuffer = null;
    _onDevice = false;
  }
}
