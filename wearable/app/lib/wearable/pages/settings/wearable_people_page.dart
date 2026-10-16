// Copyright (c) 2025-2026 Kelvin Lee. Licensed under MIT.
//
// WearablePeoplePage — the registry, visible and deletable.
//
// SpeakerRegistry has had remove() and clearAll() since it landed, with no UI
// path to either: the app could store a voiceprint for anyone the wearer named
// and offer no way to take it back. The sheet's own copy already says "Remove
// someone in Settings" — this is that Settings.
//
// Two rules shape the page:
//
//  - Say what is stored. These are speaker embeddings: 256-float vectors that
//    identify a voice. Calling them "voice profiles" and leaving it there
//    would be technically true and practically misleading, so the delete-all
//    confirmation names them for what they are.
//  - The owner is deleted through OwnerVoice.clear(), not SpeakerRegistry
//    .remove(). The registry only knows about the registry; OwnerVoice also
//    holds the legacy SharedPreferences enrolment keys, and those keys are
//    re-migrated into a fresh owner profile the next time OwnerVoice loads.
//    Deleting the profile without the keys would resurrect the vector the
//    user just deleted.

import 'package:flutter/material.dart';

import '../../local_llm/owner_voice.dart';
import '../../local_llm/speaker_registry.dart';
import '../../wearable_theme.dart';

class WearablePeoplePage extends StatefulWidget {
  const WearablePeoplePage({super.key});

  @override
  State<WearablePeoplePage> createState() => _WearablePeoplePageState();
}

class _WearablePeoplePageState extends State<WearablePeoplePage> {
  bool _loading = true;
  List<SpeakerProfile> _profiles = const [];

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    await SpeakerRegistry.instance.ensureLoaded();
    if (!mounted) return;
    setState(() {
      _profiles = SpeakerRegistry.instance.profiles;
      _loading = false;
    });
  }

  Future<void> _remove(SpeakerProfile p) async {
    // See the file header: the owner has state outside the registry.
    if (p.isOwner) {
      await OwnerVoice.instance.clear();
    } else {
      await SpeakerRegistry.instance.remove(p.id);
    }
    if (!mounted) return;
    await _refresh();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text('Deleted ${_displayName(p)}'),
      duration: const Duration(seconds: 2),
    ));
  }

  Future<void> _deleteAll() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: WearableColors.card,
        title: const Text('Delete all voices?',
            style: TextStyle(color: WearableColors.foreground, fontSize: 17)),
        content: const Text(
          'This deletes every stored voiceprint — the numeric vectors that let '
          'the app recognise a voice. They are biometric data. They never left '
          'this phone, and after this they will not exist on it either.\n\n'
          'Transcripts already captured keep the names they were given. Future '
          'recordings go back to "Talker 1", "Talker 2" until someone is named '
          'again.',
          style: TextStyle(color: WearableColors.mutedFg, fontSize: 13, height: 1.4),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel', style: TextStyle(color: WearableColors.mutedFg)),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Delete everything',
                style: TextStyle(color: WearableColors.destructive)),
          ),
        ],
      ),
    );
    if (ok != true) return;
    // Owner first: OwnerVoice.clear() also removes the legacy enrolment keys,
    // which clearAll() knows nothing about.
    await OwnerVoice.instance.clear();
    await SpeakerRegistry.instance.clearAll();
    if (!mounted) return;
    await _refresh();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
      content: Text('All voices deleted'),
      duration: Duration(seconds: 2),
    ));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: WearableColors.background,
      appBar: AppBar(
        title: const Text('People'),
        backgroundColor: WearableColors.background,
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator(color: WearableColors.primary))
          : ListView(
              padding: const EdgeInsets.all(20),
              children: [
                _SectionHeader(title: 'Known voices (${_profiles.length})'),
                if (_profiles.isEmpty)
                  const _EmptyState()
                else
                  for (final p in _profiles) ...[
                    _ProfileTile(
                      name: _displayName(p),
                      detail: _detail(p),
                      isOwner: p.isOwner,
                      incompatible: !p.isCompatible,
                      onRemove: () => _remove(p),
                    ),
                    const SizedBox(height: 8),
                  ],
                const SizedBox(height: 16),
                const _Explainer(),
                const SizedBox(height: 24),
                const _SectionHeader(title: 'Privacy'),
                _DeleteAllTile(
                  enabled: _profiles.isNotEmpty,
                  onTap: _deleteAll,
                ),
              ],
            ),
    );
  }
}

String _displayName(SpeakerProfile p) {
  final n = p.name.trim();
  if (p.isOwner) return n.isEmpty ? 'You' : '$n (you)';
  return n.isEmpty ? 'Unnamed' : n;
}

/// "2 enrolled · 5 observed · added 2026-04-27".
///
/// The enrolled/observed split is the registry's rollback story made visible:
/// enrolled vectors are the ones the user gave deliberately and are never
/// evicted; observed ones accumulated automatically and are FIFO-capped.
String _detail(SpeakerProfile p) {
  final e = p.enrolled.length;
  final o = p.observed.length;
  return '$e enrolled · $o observed · added ${_date(p.createdAt)}';
}

/// ISO-ish and locale-neutral. `intl` is not a direct dependency of this app
/// and one date line does not justify making it one.
String _date(DateTime d) {
  String two(int n) => n.toString().padLeft(2, '0');
  return '${d.year}-${two(d.month)}-${two(d.day)}';
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader({required this.title});
  final String title;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8, top: 4),
      child: Text(
        title.toUpperCase(),
        style: const TextStyle(
          color: WearableColors.mutedFg,
          fontSize: 11,
          fontWeight: FontWeight.w600,
          letterSpacing: 0.8,
        ),
      ),
    );
  }
}

class _ProfileTile extends StatelessWidget {
  const _ProfileTile({
    required this.name,
    required this.detail,
    required this.isOwner,
    required this.incompatible,
    required this.onRemove,
  });

  final String name;
  final String detail;
  final bool isOwner;
  final bool incompatible;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: WearableColors.card,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: WearableColors.border),
      ),
      child: Row(
        children: [
          Icon(isOwner ? Icons.person : Icons.person_outline,
              color: WearableColors.primary, size: 22),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(name,
                    style: const TextStyle(
                        color: WearableColors.foreground,
                        fontSize: 14,
                        fontWeight: FontWeight.w500)),
                const SizedBox(height: 2),
                Text(detail,
                    style: const TextStyle(color: WearableColors.mutedFg, fontSize: 12)),
                if (incompatible) ...[
                  const SizedBox(height: 2),
                  const Text(
                    'Stored by an older voice model — cannot be matched. Re-enrol.',
                    style: TextStyle(color: WearableColors.warning, fontSize: 12),
                  ),
                ],
              ],
            ),
          ),
          IconButton(
            onPressed: onRemove,
            icon: const Icon(Icons.delete_outline,
                color: WearableColors.destructive, size: 20),
            tooltip: 'Delete $name',
          ),
        ],
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: WearableColors.card,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: WearableColors.border),
      ),
      child: const Text(
        'No voices stored yet. Tap a speaker label on a transcript to name '
        'that voice, and it will appear here.',
        style: TextStyle(color: WearableColors.mutedFg, fontSize: 13, height: 1.4),
      ),
    );
  }
}

class _Explainer extends StatelessWidget {
  const _Explainer();

  @override
  Widget build(BuildContext context) {
    return const Text(
      'A voice is stored as a set of numeric vectors, not as audio — the '
      'recordings are not kept. Up to ${SpeakerRegistry.maxNamed} named people '
      'can be stored; the list is deliberately small because recognition gets '
      'less reliable as it grows.',
      style: TextStyle(color: WearableColors.mutedFg, fontSize: 12, height: 1.4),
    );
  }
}

class _DeleteAllTile extends StatelessWidget {
  const _DeleteAllTile({required this.enabled, required this.onTap});
  final bool enabled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final tint = enabled ? WearableColors.destructive : WearableColors.mutedFg;
    return InkWell(
      borderRadius: BorderRadius.circular(8),
      onTap: enabled ? onTap : null,
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: WearableColors.card,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: WearableColors.border),
        ),
        child: Row(
          children: [
            Icon(Icons.delete_forever_outlined, color: tint, size: 22),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Delete all voices',
                      style: TextStyle(color: tint, fontSize: 14, fontWeight: FontWeight.w500)),
                  const SizedBox(height: 2),
                  Text(
                    enabled
                        ? 'Removes every stored voiceprint from this phone.'
                        : 'Nothing stored.',
                    style: const TextStyle(color: WearableColors.mutedFg, fontSize: 12),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
