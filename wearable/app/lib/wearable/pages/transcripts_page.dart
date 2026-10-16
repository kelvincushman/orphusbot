// Copyright (c) 2025-2026 Kelvin Lee. Licensed under MIT.
//
// TranscriptsPage — dedicated full-screen page for on-device transcript feed.
// Shows the OnDeviceTranscriptLog feed (newest first) as a scrollable list.
// Moved here from the 280-px card that previously lived on DeviceStatusPage.
//
// It also carries the owner-enrolment proposal: when one unnamed voice keeps
// turning up across separate captures, this is where it is pointed out. That
// card lives here rather than in Settings because this is where the evidence
// is visible — the wearer can read the lines the proposal is made of before
// agreeing that they are theirs.

import 'package:flutter/material.dart';

import '../local_llm/capture_mute.dart';
import '../local_llm/capture_state.dart';
import '../local_llm/owner_voice.dart';
import '../local_llm/speaker_registry.dart';
import '../local_llm/streaming_transcriber.dart';
import '../local_llm/transcript_log.dart';
import '../local_llm/voice_training.dart';
import '../widgets/name_speaker_sheet.dart';
import '../wearable_theme.dart';

/// Whether the wearer has waved away the "is it you?" card.
///
/// Session-scoped and deliberately not persisted: the proposal is built from
/// the in-memory transcript log, which is also session-scoped, so a dismissal
/// that outlived the evidence would silently suppress a better proposal
/// tomorrow. Asking once per app run is the intended frequency.
@visibleForTesting
bool ownerProposalDismissedForSession = false;

class TranscriptsPage extends StatefulWidget {
  const TranscriptsPage({super.key});

  @override
  State<TranscriptsPage> createState() => _TranscriptsPageState();
}

class _TranscriptsPageState extends State<TranscriptsPage>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pulse;

  /// The recurring unnamed voice, if there is one worth asking about.
  OwnerProposal? _proposal;

  /// Starts true so the card cannot flash before the registry has been read.
  /// Stays true if reading it fails: suppressing the offer is the safe side —
  /// the wrong answer here writes someone else's vector into "You".
  bool _ownerEnrolled = true;

  bool _enrolling = false;

  @override
  void initState() {
    super.initState();
    CaptureMute.instance.addListener(_onChanged);
    CaptureState.instance.addListener(_onChanged);
    OnDeviceTranscriptLog.instance.listenable.addListener(_refreshProposal);
    _pulse = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 850),
    )..repeat(reverse: true);
    _loadOwnerState();
  }

  @override
  void dispose() {
    CaptureMute.instance.removeListener(_onChanged);
    CaptureState.instance.removeListener(_onChanged);
    OnDeviceTranscriptLog.instance.listenable.removeListener(_refreshProposal);
    _pulse.dispose();
    super.dispose();
  }

  void _onChanged() => setState(() {});

  Future<void> _loadOwnerState() async {
    var enrolled = true;
    try {
      await OwnerVoice.instance.loadEnrollmentState();
      enrolled = OwnerVoice.instance.isEnrolled;
    } catch (_) {
      // Registry unavailable — no card, and certainly no transcript list
      // taken down by an enrolment lookup.
    }
    if (!mounted) return;
    setState(() => _ownerEnrolled = enrolled);
    _refreshProposal();
  }

  /// Recompute the proposal from the current log.
  ///
  /// Done here rather than inside build() because it is O(clusters squared)
  /// cosine work and build() runs on every capture-state tick.
  void _refreshProposal() {
    final next = _ownerEnrolled
        ? null
        : findOwnerProposal(OnDeviceTranscriptLog.instance.entries);
    if (!mounted || (next == null && _proposal == null)) return;
    setState(() => _proposal = next);
  }

  /// One tap: enrol every one of the proposal's vectors as the owner, then
  /// relabel the lines they came from.
  ///
  /// Each cluster is enrolled separately — [OwnerVoice.enrollFromEmbedding]
  /// appends rather than averaging, so three captures stay three references.
  /// That variety is the whole reason this is better than one recording.
  Future<void> _acceptProposal(OwnerProposal proposal) async {
    setState(() => _enrolling = true);
    var lines = 0;
    try {
      for (final cluster in proposal.clusters) {
        await OwnerVoice.instance.enrollFromEmbedding(cluster.embedding);
      }
      final name = OwnerVoice.instance.ownerName;
      final profileId = SpeakerRegistry.instance.owner?.id;
      for (final cluster in proposal.clusters) {
        lines += OnDeviceTranscriptLog.instance.relabel(
          clipId: cluster.clipId,
          clusterIndex: cluster.clusterIndex,
          talker: name,
          profileId: profileId,
        );
      }
      if (!mounted) return;
      setState(() {
        _ownerEnrolled = true;
        _enrolling = false;
        _proposal = null;
      });
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('Enrolled as $name — $lines '
            '${lines == 1 ? 'line' : 'lines'} relabelled'),
        duration: const Duration(seconds: 3),
      ));
    } catch (e) {
      if (!mounted) return;
      setState(() => _enrolling = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not enrol that voice: $e')),
      );
    }
  }

  void _dismissProposal() {
    ownerProposalDismissedForSession = true;
    setState(() {});
  }

  /// The magic moment: one voice is in nearly everything you have recorded.
  Widget _buildProposalCard(OwnerProposal proposal) {
    final seconds = proposal.totalSeconds.round();
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      padding: const EdgeInsets.fromLTRB(16, 14, 8, 14),
      decoration: BoxDecoration(
        color: WearableColors.primary.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(WearableRadii.md),
        border: Border.all(color: WearableColors.primary.withValues(alpha: 0.35)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.record_voice_over_outlined,
              color: WearableColors.primary, size: 20),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'This voice is in most of your recordings — is it you?',
                  style: TextStyle(
                    color: WearableColors.foreground,
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    height: 1.35,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  '${proposal.clipCount} separate captures, $seconds s of speech. '
                  'Saying yes enrols it as you and labels those lines. '
                  'Nothing leaves this phone.',
                  style: const TextStyle(
                    color: WearableColors.mutedFg,
                    fontSize: 12,
                    height: 1.4,
                  ),
                ),
                const SizedBox(height: 10),
                Row(
                  children: [
                    ElevatedButton(
                      onPressed:
                          _enrolling ? null : () => _acceptProposal(proposal),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: WearableColors.primary,
                        foregroundColor: WearableColors.onPrimary,
                        visualDensity: VisualDensity.compact,
                      ),
                      child: _enrolling
                          ? const SizedBox(
                              width: 14,
                              height: 14,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                valueColor: AlwaysStoppedAnimation<Color>(
                                    WearableColors.onPrimary),
                              ),
                            )
                          : const Text("Yes, that's me"),
                    ),
                    const SizedBox(width: 8),
                    TextButton(
                      onPressed: _enrolling ? null : _dismissProposal,
                      child: const Text(
                        'Not me',
                        style: TextStyle(color: WearableColors.mutedFg),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          Semantics(
            button: true,
            label: 'Dismiss voice suggestion',
            child: IconButton(
              onPressed: _enrolling ? null : _dismissProposal,
              icon: const Icon(Icons.close, size: 16),
              color: WearableColors.mutedFg,
              splashRadius: 16,
            ),
          ),
        ],
      ),
    );
  }

  /// Live banner shown while a voice note is being captured or transcribed —
  /// the visible feedback the wearer needs after a single-tap.
  Widget _buildCaptureBanner() {
    final recording = CaptureState.instance.isRecording;
    final nothingHeard = CaptureState.instance.isNothingHeard;
    final color = recording
        ? WearableColors.destructive
        : nothingHeard
            ? WearableColors.mutedFg
            : WearableColors.primary;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      color: color.withValues(alpha: 0.12),
      child: Row(
        children: [
          if (recording)
            FadeTransition(
              opacity: _pulse,
              child: Icon(Icons.fiber_manual_record, color: color, size: 15),
            )
          else if (nothingHeard)
            Icon(Icons.mic_off_outlined, color: color, size: 15)
          else
            SizedBox(
              width: 15,
              height: 15,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                valueColor: AlwaysStoppedAnimation<Color>(color),
              ),
            ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              recording
                  ? 'Recording voice note…  tap the button again to stop'
                  : nothingHeard
                      ? 'No speech found in that capture — nothing saved'
                      : 'Transcribing…',
              style: TextStyle(
                color: color,
                fontSize: 13,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// Live text from the streaming model, shown while a capture is open.
  ///
  /// Explicitly labelled as a preview. It is decoded by a smaller streaming
  /// model measured at 16.26% WER on our channel against the offline model's
  /// 11.19%, and it is NOT what gets saved — when the window closes the offline
  /// pass re-decodes the whole utterance and that transcript is the one that
  /// appears in the list below. Saying so on screen matters: text that visibly
  /// changes after you stop speaking reads as a bug unless the reader knows a
  /// better pass is replacing it.
  Widget _buildLivePreview() {
    return ValueListenableBuilder<String>(
      valueListenable: StreamingTranscriber.instance.partial,
      builder: (context, live, _) {
        final text = StreamingTranscriber.instance.text;
        if (text.isEmpty) return const SizedBox.shrink();
        return Container(
          width: double.infinity,
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
          color: WearableColors.primary.withValues(alpha: 0.06),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Row(
                children: [
                  Icon(Icons.graphic_eq,
                      size: 13, color: WearableColors.mutedFg),
                  SizedBox(width: 6),
                  Text(
                    'Live preview',
                    style: TextStyle(
                      color: WearableColors.mutedFg,
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                      letterSpacing: 0.3,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              Text(
                text,
                style: const TextStyle(
                  color: WearableColors.foreground,
                  fontSize: 14,
                  height: 1.4,
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final muted = CaptureMute.instance.muted;
    return Scaffold(
      backgroundColor: WearableColors.background,
      body: Column(
        children: [
          // Mute toggle bar
          Container(
            padding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
            decoration: const BoxDecoration(
              border: Border(
                bottom: BorderSide(color: WearableColors.border, width: 0.5),
              ),
            ),
            child: Row(
              children: [
                Icon(
                  muted ? Icons.mic_off : Icons.mic,
                  color: muted ? WearableColors.destructive : WearableColors.primary,
                  size: 20,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    muted ? 'Mic paused' : 'Mic live',
                    style: TextStyle(
                      color: muted ? WearableColors.destructive : WearableColors.foreground,
                      fontSize: 14,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),
                Semantics(
                  button: true,
                  label: muted ? 'Unmute microphone' : 'Mute microphone',
                  child: TextButton.icon(
                    onPressed: CaptureMute.instance.toggle,
                    icon: Icon(
                      muted ? Icons.mic : Icons.mic_off,
                      size: 18,
                      color: muted ? WearableColors.primary : WearableColors.mutedFg,
                    ),
                    label: Text(
                      muted ? 'Unmute' : 'Mute',
                      style: TextStyle(
                        color: muted ? WearableColors.primary : WearableColors.mutedFg,
                        fontSize: 13,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
          // Mic paused banner
          if (muted)
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              color: WearableColors.destructive.withValues(alpha: 0.12),
              child: const Row(
                children: [
                  Icon(Icons.pause_circle_outline,
                      color: WearableColors.destructive, size: 16),
                  SizedBox(width: 8),
                  Text(
                    'Mic paused — audio frames are being dropped.',
                    style: TextStyle(
                      color: WearableColors.destructive,
                      fontSize: 12,
                      height: 1.3,
                    ),
                  ),
                ],
              ),
            ),
          // Voice-note capture banner (recording / transcribing)
          if (CaptureState.instance.isActive) _buildCaptureBanner(),
          // Live text, while the wearer is still speaking.
          _buildLivePreview(),
          // "Is it you?" — only while nobody is enrolled and the evidence holds.
          if (_proposal != null && !ownerProposalDismissedForSession)
            _buildProposalCard(_proposal!),
          // Transcript list
          Expanded(
            child: ValueListenableBuilder<List<TranscriptEntry>>(
              valueListenable: OnDeviceTranscriptLog.instance.listenable,
              builder: (context, entries, _) {
                if (entries.isEmpty) {
                  return const Center(
                    child: Padding(
                      padding: EdgeInsets.symmetric(horizontal: 32),
                      child: Text(
                        'No transcripts yet — speak into the wearable.',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          color: WearableColors.mutedFg,
                          fontSize: 15,
                          height: 1.5,
                        ),
                      ),
                    ),
                  );
                }
                return ListView.separated(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
                  itemCount: entries.length,
                  separatorBuilder: (_, __) => const Divider(
                    color: WearableColors.border,
                    height: 20,
                    thickness: 1,
                  ),
                  itemBuilder: (_, i) {
                    final e = entries[i];
                    final ts =
                        '${e.at.hour.toString().padLeft(2, '0')}:${e.at.minute.toString().padLeft(2, '0')}:${e.at.second.toString().padLeft(2, '0')}';
                    return Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              if (e.talker != null)
                                GestureDetector(
                                  // Tap a voice to name it. Only when the line
                                  // carries the evidence to do so; a label from
                                  // a path without diarization has nothing to
                                  // enrol from.
                                  onTap: e.canName ? () => showNameSpeakerSheet(context, e) : null,
                                  child: Container(
                                  margin: const EdgeInsets.only(bottom: 6),
                                  padding: const EdgeInsets.symmetric(
                                      horizontal: 6, vertical: 2),
                                  decoration: BoxDecoration(
                                    color: WearableColors.secondary,
                                    borderRadius: BorderRadius.circular(4),
                                    border:
                                        Border.all(color: WearableColors.primary),
                                  ),
                                  child: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Text(
                                        e.talker!,
                                        style: const TextStyle(
                                          color: WearableColors.primary,
                                          fontSize: 10,
                                          fontWeight: FontWeight.w600,
                                          letterSpacing: 0.4,
                                        ),
                                      ),
                                      if (e.canName && e.profileId == null) ...[
                                        const SizedBox(width: 4),
                                        const Icon(Icons.edit_outlined,
                                            size: 10, color: WearableColors.primary),
                                      ],
                                    ],
                                  ),
                                  ),
                                ),
                              Text(
                                e.text,
                                style: const TextStyle(
                                  color: WearableColors.foreground,
                                  fontSize: 14,
                                  height: 1.4,
                                ),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(width: 12),
                        Column(
                          crossAxisAlignment: CrossAxisAlignment.end,
                          children: [
                            Text(
                              ts,
                              style: const TextStyle(
                                color: WearableColors.mutedFg,
                                fontSize: 11,
                              ),
                            ),
                            if (e.overheard)
                              Container(
                                margin: const EdgeInsets.only(top: 4),
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 6, vertical: 2),
                                decoration: BoxDecoration(
                                  color: WearableColors.muted,
                                  borderRadius: BorderRadius.circular(4),
                                  border:
                                      Border.all(color: WearableColors.border),
                                ),
                                child: const Text(
                                  'overheard',
                                  style: TextStyle(
                                    color: WearableColors.mutedFg,
                                    fontSize: 10,
                                    letterSpacing: 0.4,
                                  ),
                                ),
                              ),
                          ],
                        ),
                      ],
                    );
                  },
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}
