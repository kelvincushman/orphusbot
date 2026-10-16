// Copyright (c) 2025-2026 Kelvin Lee. Licensed under MIT.
//
// NameSpeakerSheet — tap a talker label, say who it is.
//
// This is the enrolment path that matters. The voice pages enrol from the
// PHONE mic; every match happens against WEARABLE audio, and a chest-worn MEMS
// mic at 25 cm is a different acoustic channel from a phone held at arm's
// length. Naming a voice here enrols the exact vector the registry just scored,
// so enrolment and matching share a channel by construction.
//
// Naming relabels every line from the same clip and cluster immediately —
// those are the same speaker by the diarizer's own grouping, no threshold
// involved. It does NOT touch other clips: retroactive relabelling across
// history without confirmation is the single worst failure this feature can
// have, and it is deliberately not built.

import 'package:flutter/material.dart';

import '../local_llm/owner_voice.dart';
import '../local_llm/speaker_registry.dart';
import '../local_llm/transcript_log.dart';
import '../wearable_theme.dart';

Future<void> showNameSpeakerSheet(BuildContext context, TranscriptEntry entry) {
  return showModalBottomSheet<void>(
    context: context,
    backgroundColor: WearableColors.background,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
    ),
    isScrollControlled: true,
    builder: (_) => _NameSpeakerSheet(entry: entry),
  );
}

class _NameSpeakerSheet extends StatefulWidget {
  const _NameSpeakerSheet({required this.entry});
  final TranscriptEntry entry;

  @override
  State<_NameSpeakerSheet> createState() => _NameSpeakerSheetState();
}

class _NameSpeakerSheetState extends State<_NameSpeakerSheet> {
  final _name = TextEditingController();
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  TranscriptEntry get e => widget.entry;
  bool get _enoughEvidence => e.durationS >= SpeakerRegistry.minEvidenceS;

  /// [action] enrols and returns the resulting (talker, profileId). The id
  /// has to come back from the action rather than be read beforehand: on a
  /// first "This is me" there is no owner yet, and for "someone new" the
  /// profile does not exist until enrol() returns. Reading it early relabels
  /// the lines with a null profileId, and the transcript list keeps showing
  /// them as unnamed.
  Future<void> _apply(Future<(String, String?)> Function() action) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final (talker, profileId) = await action();
      final n = OnDeviceTranscriptLog.instance.relabel(
        clipId: e.clipId!,
        clusterIndex: e.clusterIndex!,
        talker: talker,
        profileId: profileId,
      );
      if (!mounted) return;
      Navigator.of(context).pop();
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(n == 1 ? 'Labelled 1 line as $talker' : 'Labelled $n lines as $talker'),
        duration: const Duration(seconds: 2),
      ));
    } catch (err) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = '$err';
      });
    }
  }

  Future<void> _thisIsMe() => _apply(() async {
        await OwnerVoice.instance.enrollFromEmbedding(e.embedding!);
        return (OwnerVoice.instance.ownerName, SpeakerRegistry.instance.owner?.id);
      });

  Future<void> _known(SpeakerProfile p) => _apply(() async {
        await SpeakerRegistry.instance.addEnrolled(p.id, e.embedding!);
        return (p.name, p.id);
      });

  Future<void> _someoneNew() async {
    final name = _name.text.trim();
    if (name.isEmpty) return;
    await _apply(() async {
      final p = await SpeakerRegistry.instance.enrol(name: name, vectors: [e.embedding!]);
      return (p.name, p.id);
    });
  }

  @override
  Widget build(BuildContext context) {
    final reg = SpeakerRegistry.instance;
    final others = reg.profiles
        .where((p) => !p.isOwner && p.isCompatible && p.name.trim().isNotEmpty)
        .toList();
    final ownerEnrolled = reg.owner?.isCompatible ?? false;
    final secs = e.durationS.toStringAsFixed(1);

    // Scrollable because the option list grows with the registry: at
    // maxNamed people plus the owner row it is taller than the sheet on a
    // phone, and a Column alone overflows.
    return SingleChildScrollView(
      padding: EdgeInsets.only(
        left: 20,
        right: 20,
        top: 16,
        bottom: MediaQuery.of(context).viewInsets.bottom + 24,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Who is ${e.talker ?? 'this'}?',
              style: const TextStyle(
                  color: WearableColors.foreground, fontSize: 18, fontWeight: FontWeight.w600)),
          const SizedBox(height: 4),
          Text(
            _enoughEvidence
                ? '$secs s of speech in this clip. Naming applies to every line from this voice here.'
                : 'Only $secs s of speech — under the ${SpeakerRegistry.minEvidenceS.toStringAsFixed(0)} s '
                    'needed to enrol a voice reliably. Let them talk a little longer next time.',
            style: const TextStyle(color: WearableColors.mutedFg, fontSize: 12, height: 1.4),
          ),
          const SizedBox(height: 16),

          if (_enoughEvidence) ...[
            _Option(
              icon: Icons.person_outline,
              label: ownerEnrolled ? 'This is me (${OwnerVoice.instance.ownerName})' : 'This is me',
              subtitle: ownerEnrolled
                  ? 'Adds this voice sample to your profile.'
                  : 'Enrols your voice from this recording — the same mic that will recognise you.',
              onTap: _busy ? null : _thisIsMe,
            ),
            for (final p in others)
              _Option(
                icon: Icons.person,
                label: p.name,
                subtitle: 'Add this sample to ${p.name}.',
                onTap: _busy ? null : () => _known(p),
              ),
            const SizedBox(height: 8),
            if (reg.canAddNamed) ...[
              TextField(
                controller: _name,
                enabled: !_busy,
                textCapitalization: TextCapitalization.words,
                decoration: InputDecoration(
                  hintText: 'Someone new — their name',
                  hintStyle: const TextStyle(color: WearableColors.mutedFg),
                  filled: true,
                  fillColor: WearableColors.secondary,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(10),
                    borderSide: BorderSide.none,
                  ),
                  suffixIcon: IconButton(
                    icon: const Icon(Icons.check, color: WearableColors.primary),
                    onPressed: _busy ? null : _someoneNew,
                  ),
                ),
                onSubmitted: (_) => _someoneNew(),
              ),
            ] else
              const Text(
                'Registry full — ${SpeakerRegistry.maxNamed} people is the limit. '
                'Remove someone in Settings to add another.',
                style: TextStyle(color: WearableColors.mutedFg, fontSize: 12),
              ),
          ],

          if (_error != null) ...[
            const SizedBox(height: 10),
            Text(_error!, style: const TextStyle(color: WearableColors.destructive, fontSize: 12)),
          ],
          const SizedBox(height: 8),
          TextButton(
            onPressed: _busy ? null : () => Navigator.of(context).pop(),
            child: Text('Leave as ${e.talker ?? 'is'}',
                style: const TextStyle(color: WearableColors.mutedFg)),
          ),
        ],
      ),
    );
  }
}

class _Option extends StatelessWidget {
  const _Option({required this.icon, required this.label, required this.subtitle, this.onTap});
  final IconData icon;
  final String label;
  final String subtitle;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(10),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 10),
        child: Row(
          children: [
            Icon(icon, color: onTap == null ? WearableColors.mutedFg : WearableColors.primary, size: 22),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(label,
                      style: const TextStyle(
                          color: WearableColors.foreground, fontSize: 14, fontWeight: FontWeight.w500)),
                  Text(subtitle, style: const TextStyle(color: WearableColors.mutedFg, fontSize: 12)),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
