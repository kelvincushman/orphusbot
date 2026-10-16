// Copyright (c) 2025-2026 Kelvin Lee. Licensed under MIT.
//
// WearableDictionaryPage — the personal dictionary. Names, project words and
// jargon the wearer says every day, fed to the on-device recogniser as a
// spelling guide (see local_llm/gemma_transcriber.dart).
//
// Two tabs, mirroring the Eloquent shape: "All words" is one flat alphabetical
// list; "Collections" is the same entries grouped by category.

import 'package:flutter/material.dart';

import '../services/vocabulary_store.dart';
import '../wearable_theme.dart';

class WearableDictionaryPage extends StatefulWidget {
  const WearableDictionaryPage({super.key});

  @override
  State<WearableDictionaryPage> createState() => _WearableDictionaryPageState();
}

class _WearableDictionaryPageState extends State<WearableDictionaryPage>
    with SingleTickerProviderStateMixin {
  late final TabController _tabs = TabController(length: 2, vsync: this);
  final TextEditingController _input = TextEditingController();

  List<VocabularyEntry> _entries = const [];
  String? _category;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  @override
  void dispose() {
    _tabs.dispose();
    _input.dispose();
    super.dispose();
  }

  Future<void> _reload() async {
    final entries = await VocabularyStore.entries();
    if (!mounted) return;
    setState(() {
      _entries = entries;
      _loading = false;
    });
  }

  Future<void> _add() async {
    final word = _input.text;
    if (VocabularyStore.normalize(word).isEmpty) return;
    final added = await VocabularyStore.add(word, category: _category);
    if (!mounted) return;
    if (!added) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('"${VocabularyStore.normalize(word)}" is already in your dictionary')),
      );
      return;
    }
    _input.clear();
    await _reload();
  }

  Future<void> _remove(VocabularyEntry entry) async {
    await VocabularyStore.remove(entry.word);
    await _reload();
  }

  /// Alphabetical, case-insensitive — matches the Eloquent list. Storage keeps
  /// insertion order because that is what the prompt cap slices from.
  List<VocabularyEntry> get _sorted {
    final list = [..._entries]
      ..sort((a, b) => a.word.toLowerCase().compareTo(b.word.toLowerCase()));
    return list;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: WearableColors.background,
      // The body is a fixed header (blurb, tabs, add row, category row) over one
      // Expanded list. On a short screen the keyboard leaves less height than the
      // header alone needs, and the Column overflowed by up to 198 px at 320x568.
      // The text field sits near the top, so letting the keyboard overlay rather
      // than resize keeps it visible and removes the failure entirely.
      resizeToAvoidBottomInset: false,
      appBar: AppBar(title: const Text('Dictionary')),
      body: Column(
        children: [
          const Padding(
            padding: EdgeInsets.fromLTRB(20, 4, 20, 12),
            child: Text(
              'Add names or jargon you often use to improve accuracy.',
              style: TextStyle(color: WearableColors.mutedFg, fontSize: 13),
            ),
          ),
          TabBar(
            controller: _tabs,
            tabs: const [Tab(text: 'All words'), Tab(text: 'Collections')],
          ),
          _addRow(),
          _categoryRow(),
          if (_entries.length > VocabularyStore.promptCap) _capNotice(),
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : TabBarView(
                    controller: _tabs,
                    children: [_allWords(), _collections()],
                  ),
          ),
        ],
      ),
    );
  }

  // --- Add row: white card, text field, black circular + button ------------

  Widget _addRow() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 0),
      child: Container(
        decoration: BoxDecoration(
          color: WearableColors.card,
          borderRadius: BorderRadius.circular(WearableRadii.lg),
          boxShadow: [WearableShadows.card],
        ),
        padding: const EdgeInsets.fromLTRB(18, 8, 8, 8),
        child: Row(
          children: [
            Expanded(
              child: TextField(
                controller: _input,
                textInputAction: TextInputAction.done,
                textCapitalization: TextCapitalization.words,
                maxLength: VocabularyStore.maxWordLength,
                onSubmitted: (_) => _add(),
                decoration: const InputDecoration(
                  hintText: 'e.g. "LiteRT"',
                  filled: false,
                  counterText: '',
                  border: InputBorder.none,
                  enabledBorder: InputBorder.none,
                  focusedBorder: InputBorder.none,
                  contentPadding: EdgeInsets.symmetric(vertical: 14),
                ),
              ),
            ),
            const SizedBox(width: 8),
            Semantics(
              button: true,
              label: 'Add word',
              child: InkWell(
                onTap: _add,
                customBorder: const CircleBorder(),
                child: Container(
                  width: 44,
                  height: 44,
                  decoration: const BoxDecoration(
                    color: WearableColors.primary,
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(Icons.add, color: WearableColors.onPrimary, size: 22),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Which collection the next added word lands in. Black pill = selected.
  Widget _categoryRow() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 4),
      child: Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          _pickerChip(null, 'No collection'),
          ...kVocabularyCategories.map((c) => _pickerChip(c, c)),
        ],
      ),
    );
  }

  Widget _pickerChip(String? value, String label) {
    final selected = _category == value;
    return GestureDetector(
      onTap: () => setState(() => _category = value),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
        decoration: BoxDecoration(
          color: selected ? WearableColors.primary : WearableColors.muted,
          borderRadius: BorderRadius.circular(WearableRadii.full),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: selected ? WearableColors.onPrimary : WearableColors.mutedFg,
            fontSize: 12,
            fontWeight: FontWeight.w500,
          ),
        ),
      ),
    );
  }

  Widget _capNotice() {
    return const Padding(
      padding: EdgeInsets.fromLTRB(20, 8, 20, 0),
      child: Text(
        'Only the ${VocabularyStore.promptCap} most recently added words are sent '
        'to the recogniser. The rest are kept here.',
        style: TextStyle(color: WearableColors.warning, fontSize: 12),
      ),
    );
  }

  // --- Lists ---------------------------------------------------------------

  Widget _allWords() {
    if (_entries.isEmpty) return _empty();
    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 32),
      children: _sorted.map(_entryCard).toList(),
    );
  }

  Widget _collections() {
    if (_entries.isEmpty) return _empty();
    final groups = <String, List<VocabularyEntry>>{};
    for (final e in _sorted) {
      groups.putIfAbsent(e.category ?? 'No collection', () => []).add(e);
    }
    final names = groups.keys.toList()..sort();
    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 32),
      children: [
        for (final name in names) ...[
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 8, 4, 8),
            child: Text(
              '$name  ·  ${groups[name]!.length}',
              style: const TextStyle(
                color: WearableColors.mutedFg,
                fontSize: 12,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          ...groups[name]!.map(_entryCard),
        ],
      ],
    );
  }

  Widget _entryCard(VocabularyEntry entry) {
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      decoration: BoxDecoration(
        color: WearableColors.card,
        borderRadius: BorderRadius.circular(WearableRadii.lg),
        boxShadow: [WearableShadows.card],
      ),
      padding: const EdgeInsets.fromLTRB(18, 14, 8, 14),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  entry.word,
                  style: const TextStyle(
                    color: WearableColors.foreground,
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                if (entry.category != null) ...[
                  const SizedBox(height: 6),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                    decoration: BoxDecoration(
                      color: WearableColors.muted,
                      borderRadius: BorderRadius.circular(WearableRadii.full),
                    ),
                    child: Text(
                      entry.category!,
                      style: const TextStyle(color: WearableColors.mutedFg, fontSize: 11),
                    ),
                  ),
                ],
              ],
            ),
          ),
          IconButton(
            icon: const Icon(Icons.delete_outline, size: 20),
            color: WearableColors.mutedFg,
            tooltip: 'Remove ${entry.word}',
            onPressed: () => _remove(entry),
          ),
        ],
      ),
    );
  }

  Widget _empty() {
    return const Center(
      child: Padding(
        padding: EdgeInsets.symmetric(horizontal: 40),
        child: Text(
          'No words yet. Add the names and terms you say most and the recogniser '
          'will spell them your way.',
          textAlign: TextAlign.center,
          style: TextStyle(color: WearableColors.mutedFg, fontSize: 14),
        ),
      ),
    );
  }
}
