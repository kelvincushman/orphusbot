// Copyright (c) 2025-2026 Kelvin Lee. Licensed under MIT.
//
// DeviceStatusPage — consolidated view of BLE + Wearable server health.
// Reads the live `WearableDeviceBridge.current` + `WearableClient.instance`
// singletons, plus WearableConnectionProvider for server-health polling state.
//
// Per design spec v1.0 §Screen 8. This initial version surfaces what we
// already have (connection + device identity + audio-WS ownership).
// Sync queue + habitat alerts land in a follow-up once those server
// endpoints are available.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../device_bridge.dart';
import '../local_llm/capture_diagnostics.dart';
import '../local_llm/diarization_provisioner.dart';
import '../local_llm/transcription_mode.dart';
import '../wearable_client.dart';
import '../wearable_theme.dart';
import '../providers/wearable_connection_provider.dart';
import 'wearable_scan_page.dart';
import 'settings/wearable_diarization_page.dart';

class DeviceStatusPage extends StatefulWidget {
  const DeviceStatusPage({super.key});

  @override
  State<DeviceStatusPage> createState() => _DeviceStatusPageState();
}

class _DeviceStatusPageState extends State<DeviceStatusPage> {
  WearableCredentials? _creds;
  bool _diarInstalled = false;
  bool _privacyMode = TranscriptionSettings.privacyModeFor(TranscriptionSettings.defaultSegmentation);

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    // Privacy Mode is read first and settled on its own. It is a privacy
    // control: it must never be left showing the permissive default because an
    // unrelated credential or model-directory read threw on the way past.
    final privacy = await TranscriptionSettings.privacyMode();
    if (!mounted) return;
    setState(() => _privacyMode = privacy);

    final c = await WearableClient.instance.loadCredentials();
    final diar = await DiarizationProvisioner.instance.isInstalled();
    if (!mounted) return;
    setState(() {
      _creds = c;
      _diarInstalled = diar;
    });
  }

  /// Privacy Mode is the one capture setting with a consequence the wearer has
  /// to be able to reach in one gesture, so it lives on the card that shows
  /// what capture is doing rather than three taps into Settings.
  Future<void> _setPrivacyMode(bool on) async {
    await TranscriptionSettings.setPrivacyMode(on);
    if (!mounted) return;
    setState(() => _privacyMode = on);
    // Applies to the live bridge now — the audio path reads this at configure
    // time, so without this the wearer keeps being recorded until they
    // reconnect the wearable.
    unawaited(WearableDeviceBridge.current?.reconfigureTranscription() ?? Future<void>.value());
  }

  @override
  Widget build(BuildContext context) {
    final conn = context.watch<WearableConnectionProvider>();
    final bridge = WearableDeviceBridge.current;
    return Scaffold(
      backgroundColor: WearableColors.background,
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          Align(
            alignment: Alignment.centerRight,
            child: IconButton(
              onPressed: () {
                conn.poke();
                setState(() {});
              },
              icon: const Icon(Icons.refresh_outlined, color: WearableColors.mutedFg),
              tooltip: 'Refresh',
            ),
          ),
          // The wearable comes first: it is the thing this screen is about, and
          // it works with no server at all. Server state used to sit above it
          // under the bare title "Connection", so a perfectly attached wearable
          // read as "Status: unpaired" — the exact confusion that made a working
          // BLE bridge look broken.
          _card(
            title: 'Wearable',
            rows: [
              _row('BLE bridge', bridge == null ? 'not attached' : 'active'),
              if (bridge != null) _row('Device', bridge.deviceName),
            ],
          ),
          const SizedBox(height: 16),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton.icon(
              icon: Icon(
                bridge == null ? Icons.bluetooth_searching : Icons.bluetooth_connected,
              ),
              label: Text(bridge == null ? 'Connect device' : 'Reconnect device'),
              onPressed: () async {
                await Navigator.push<WearableDeviceBridge>(
                  context,
                  MaterialPageRoute(builder: (_) => const WearableScanPage()),
                );
                // WearableScanPage calls WearableDeviceBridge.attach() on success;
                // refresh state so the Wearable card reflects the new bridge.
                if (mounted) setState(() {});
              },
            ),
          ),
          const SizedBox(height: 12),
          _card(
            title: 'Server (optional)',
            rows: [
              _row('Paired', _creds == null ? 'no' : 'yes'),
              if (_creds == null)
                _row('', 'Transcription runs on-device without one.')
              else ...[
                _row('Status', _statusLabel(conn.status), color: _statusColor(conn.status)),
                _row('Last healthy', conn.lastHealthyAt?.toLocal().toString() ?? '—'),
                _row('Device ID', _creds!.devId),
                _row('Base URL', _creds!.baseUrl),
                _row('Active audio owner', WearableClient.instance.activeAudioOwner ?? '—'),
              ],
            ],
          ),
          const SizedBox(height: 12),
          _captureCard(),
          const SizedBox(height: 12),
          _diarizationCard(),
        ],
      ),
    );
  }

  /// Capture diagnostics.
  ///
  /// CaptureDiagnostics is a ChangeNotifier with twenty writers and, until now,
  /// no listeners: "SD sync failed", "On-device audio unavailable", "Note
  /// discarded, recoverable for 10 min" and every button event were raised for
  /// the user and rendered nowhere. This is the one screen that already exists
  /// to answer "what is the wearable actually doing".
  Widget _captureCard() {
    return AnimatedBuilder(
      animation: CaptureDiagnostics.instance,
      builder: (context, _) {
        final d = CaptureDiagnostics.instance;
        final rms = d.decodedRms;
        return _card(
          title: 'Capture',
          rows: [
            _privacyModeRow(),
            _row('Mode', d.mode?.name ?? '—'),
            _row('Audio', d.frameMs > 0 ? '${d.encoding} · ${d.frameMs} ms frames' : d.encoding),
            _row('Frames', d.frameCount == 0 ? '—' : '${d.frameCount}'),
            _row('Decoded level', rms == null ? '—' : rms.toStringAsFixed(0)),
            if (d.message != null) _row('Last event', d.message!),
            if (d.updatedAt != null) _row('Updated', d.updatedAt!.toLocal().toString().split('.').first),
          ],
        );
      },
    );
  }

  /// The toggle, plus the sentence that says what it actually does. "Privacy
  /// Mode" alone does not tell anyone whether the room is being transcribed.
  Widget _privacyModeRow() {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Privacy Mode',
                  style: TextStyle(
                    color: WearableColors.foreground,
                    fontSize: 14,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  _privacyMode
                      ? 'Only what you capture with the button is transcribed. Everything else is discarded.'
                      : 'Capturing continuously. Press the button to mark what you say next as an instruction.',
                  style: const TextStyle(color: WearableColors.mutedFg, fontSize: 12, height: 1.35),
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          Switch.adaptive(
            value: _privacyMode,
            activeThumbColor: WearableColors.primary,
            onChanged: _setPrivacyMode,
          ),
        ],
      ),
    );
  }

  Widget _diarizationCard() {
    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: () async {
        await Navigator.push<void>(
          context,
          MaterialPageRoute(builder: (_) => const WearableDiarizationPage()),
        );
        // Refresh installed state when returning from the settings page.
        final installed = await DiarizationProvisioner.instance.isInstalled();
        if (mounted) setState(() => _diarInstalled = installed);
      },
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: WearableColors.card,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: WearableColors.border),
        ),
        child: Row(
          children: [
            Icon(
              _diarInstalled
                  ? Icons.record_voice_over_outlined
                  : Icons.download_for_offline_outlined,
              color: _diarInstalled ? WearableColors.primary : WearableColors.mutedFg,
              size: 22,
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Diarization models',
                    style: TextStyle(
                      color: WearableColors.foreground,
                      fontSize: 14,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    _diarInstalled ? 'Installed ✓' : 'Not installed — tap to download (~32 MB)',
                    style: const TextStyle(
                      color: WearableColors.mutedFg,
                      fontSize: 12,
                    ),
                  ),
                ],
              ),
            ),
            const Icon(
              Icons.chevron_right,
              color: WearableColors.mutedFg,
              size: 18,
            ),
          ],
        ),
      ),
    );
  }

  Widget _card({required String title, required List<Widget> rows}) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: WearableColors.card,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: WearableColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: const TextStyle(
              color: WearableColors.foreground,
              fontSize: 16,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 10),
          ...rows,
        ],
      ),
    );
  }

  Widget _row(String label, String value, {Color? color}) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Expanded(
            flex: 2,
            child: Text(
              label,
              style: const TextStyle(color: WearableColors.mutedFg, fontSize: 13),
            ),
          ),
          Expanded(
            flex: 3,
            child: Text(
              value,
              textAlign: TextAlign.right,
              style: TextStyle(
                color: color ?? WearableColors.foreground,
                fontSize: 13,
                fontWeight: FontWeight.w500,
              ),
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }

  String _statusLabel(WearableConnectionStatus s) => switch (s) {
    WearableConnectionStatus.connected => 'connected',
    WearableConnectionStatus.syncing => 'syncing',
    WearableConnectionStatus.disconnected => 'disconnected',
    WearableConnectionStatus.error => 'error',
    WearableConnectionStatus.unpaired => 'unpaired',
  };

  Color _statusColor(WearableConnectionStatus s) => switch (s) {
    WearableConnectionStatus.connected => WearableColors.primary,
    WearableConnectionStatus.syncing => WearableColors.warning,
    WearableConnectionStatus.disconnected => WearableColors.mutedFg,
    WearableConnectionStatus.error => WearableColors.destructive,
    WearableConnectionStatus.unpaired => WearableColors.mutedFg,
  };
}
