// The Gallery (DESIGN §12.2): files kept for the bots, such as reference
// pictures, brand material, documents and video. Browse, search, upload, edit
// details and mark items as standing context for bots; the chat's 📎 can pick
// from here too.
import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';

import 'api.dart';
import 'viewer.dart';

bool isImage(Map<String, dynamic> i) =>
    (i['mime'] as String).startsWith('image/') && i['mime'] != 'image/svg+xml';

IconData kindIcon(Map<String, dynamic> i) {
  final mime = i['mime'] as String;
  if (mime.startsWith('video/')) return Icons.movie_outlined;
  if (mime.startsWith('audio/')) return Icons.audiotrack_outlined;
  if (mime == 'application/pdf') return Icons.picture_as_pdf_outlined;
  return Icons.description_outlined;
}

String sizeText(int bytes) => bytes < 1024 * 1024
    ? '${(bytes / 1024).ceil()} KB'
    : '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB';

/// The grid; with [picking] it returns the chosen items instead of editing them.
class GalleryScreen extends StatefulWidget {
  const GalleryScreen({
    super.key,
    required this.api,
    required this.bots,
    this.picking = false,
  });
  final Api api;
  final List<Map<String, dynamic>> bots;
  final bool picking;
  @override
  State<GalleryScreen> createState() => _GalleryScreenState();
}

class _GalleryScreenState extends State<GalleryScreen> {
  List<Map<String, dynamic>> items = [];
  final search = TextEditingController();
  final picked = <int>{};
  String? note;
  bool uploading = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    search.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final got = await widget.api.gallery(search.text.trim());
      if (mounted) setState(() => items = got);
    } catch (e) {
      if (mounted) setState(() => note = explain(e));
    }
  }

  Future<void> _upload() async {
    final files = await openFiles();
    if (files.isEmpty) return;
    setState(() {
      uploading = true;
      note = 'Adding ${files.length} file${files.length == 1 ? '' : 's'}…';
    });
    var done = 0;
    for (final f in files) {
      try {
        final item = await widget.api.galleryUpload(f, f.name);
        // Picking for a message: what was just added is what's wanted.
        if (widget.picking && item['id'] is int) picked.add(item['id'] as int);
        done++;
      } catch (e) {
        if (mounted) setState(() => note = '${f.name}: ${explain(e)}');
      }
    }
    if (!mounted) return;
    setState(() {
      uploading = false;
      if (done == files.length) note = 'Added $done.';
    });
    _load();
  }

  Future<void> _open(Map<String, dynamic> item) async {
    if (widget.picking) {
      setState(
        () => picked.contains(item['id'])
            ? picked.remove(item['id'])
            : picked.add(item['id'] as int),
      );
      return;
    }
    await _edit(item);
  }

  /// The item's details page: rename, tags, description, bots, view, delete.
  Future<void> _edit(Map<String, dynamic> item) async {
    final changed = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) =>
            _ItemSheet(api: widget.api, item: item, bots: widget.bots),
      ),
    );
    if (changed == true) _load();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.picking ? 'Choose from the gallery' : 'Gallery'),
        actions: [
          if (widget.picking)
            Padding(
              padding: const EdgeInsets.only(right: 12),
              child: FilledButton(
                onPressed: picked.isEmpty
                    ? null
                    : () => Navigator.pop(
                        context,
                        items.where((i) => picked.contains(i['id'])).toList(),
                      ),
                child: Text('Attach ${picked.isEmpty ? '' : picked.length}'),
              ),
            ),
        ],
      ),
      // Adding works while picking too, so an empty gallery isn't a dead end.
      floatingActionButton: FloatingActionButton.extended(
        onPressed: uploading ? null : _upload,
        icon: const Icon(Icons.add_photo_alternate_outlined),
        label: const Text('Add files'),
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
            child: TextField(
              controller: search,
              decoration: const InputDecoration(
                prefixIcon: Icon(Icons.search),
                hintText: 'Search names, descriptions and tags',
              ),
              onSubmitted: (_) => _load(),
              onChanged: (v) => v.isEmpty ? _load() : null,
            ),
          ),
          if (note != null)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Text(note!, style: Theme.of(context).textTheme.bodySmall),
            ),
          Expanded(
            child: items.isEmpty
                ? Center(
                    child: Padding(
                      padding: const EdgeInsets.all(24),
                      child: Text(
                        search.text.isEmpty
                            ? 'Nothing here yet. Add pictures, video, audio or '
                                  'documents your bots can use: reference images, '
                                  'brand material, notes.'
                            : 'Nothing matches.',
                        textAlign: TextAlign.center,
                      ),
                    ),
                  )
                : GridView.extent(
                    maxCrossAxisExtent: 180,
                    padding: const EdgeInsets.all(12),
                    mainAxisSpacing: 10,
                    crossAxisSpacing: 10,
                    children: [
                      for (final i in items)
                        _Tile(
                          api: widget.api,
                          item: i,
                          picked: picked.contains(i['id']),
                          onTap: () => _open(i),
                          onLongPress: () => _edit(i),
                          scheme: scheme,
                        ),
                    ],
                  ),
          ),
        ],
      ),
    );
  }
}

class _Tile extends StatelessWidget {
  const _Tile({
    required this.api,
    required this.item,
    required this.picked,
    required this.onTap,
    required this.onLongPress,
    required this.scheme,
  });
  final Api api;
  final Map<String, dynamic> item;
  final bool picked;
  final VoidCallback onTap, onLongPress;
  final ColorScheme scheme;

  @override
  Widget build(BuildContext context) => InkWell(
    onTap: onTap,
    onLongPress: onLongPress,
    borderRadius: BorderRadius.circular(12),
    child: Container(
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: picked ? scheme.primary : Colors.transparent,
          width: 3,
        ),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            child: isImage(item)
                ? Image.network(
                    api.galleryUrl(item['id'] as int),
                    headers: api.headers,
                    fit: BoxFit.cover,
                    errorBuilder: (_, _, _) =>
                        Icon(kindIcon(item), size: 40, color: scheme.outline),
                  )
                : Icon(kindIcon(item), size: 40, color: scheme.outline),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 6, 8, 6),
            child: Text(
              item['name'] as String,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
        ],
      ),
    ),
  );
}

/// One item: preview, details to edit, standing context for bots, open, delete.
class _ItemSheet extends StatefulWidget {
  const _ItemSheet({required this.api, required this.item, required this.bots});
  final Api api;
  final Map<String, dynamic> item;
  final List<Map<String, dynamic>> bots;
  @override
  State<_ItemSheet> createState() => _ItemSheetState();
}

class _ItemSheetState extends State<_ItemSheet> {
  late final name = TextEditingController(text: widget.item['name'] as String);
  final tagInput = TextEditingController();
  late final tags = [...(widget.item['tags'] as List).cast<String>()];
  late final description = TextEditingController(
    text: widget.item['description'] as String,
  );
  late final pinned = {...(widget.item['pinned_for'] as List).cast<String>()};
  String? error;

  @override
  void dispose() {
    for (final c in [name, tagInput, description]) {
      c.dispose();
    }
    super.dispose();
  }

  /// Adds what's typed as tags (commas split several), lower case, no repeats.
  void _addTags([String? text]) {
    final added = (text ?? tagInput.text)
        .split(',')
        .map((t) => t.trim().toLowerCase())
        .where((t) => t.isNotEmpty && !tags.contains(t));
    setState(() {
      tags.addAll(added);
      tagInput.clear();
    });
  }

  Future<void> _save() async {
    if (tagInput.text.trim().isNotEmpty) _addTags();
    if (name.text.trim().isEmpty) {
      return setState(() => error = 'Give it a name.');
    }
    try {
      await widget.api.post('/api/gallery/update', {
        'id': widget.item['id'],
        'name': name.text.trim(),
        'tags': tags,
        'description': description.text.trim(),
        'pinned_for': pinned.toList(),
      });
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      setState(() => error = explain(e));
    }
  }

  Future<void> _delete() async {
    final sure = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text('Delete ${widget.item['name']}?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c, false),
            child: const Text('Keep'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(c, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (sure != true) return;
    try {
      await widget.api.post('/api/gallery/delete', {'id': widget.item['id']});
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      setState(() => error = explain(e));
    }
  }

  /// Opens it full screen: PDFs, video, audio, pictures, Markdown, code.
  Future<void> _view() => openViewer(
    context,
    widget.api,
    widget.item['name'] as String,
    widget.api.galleryUrl(widget.item['id'] as int),
  );

  @override
  Widget build(BuildContext context) {
    final i = widget.item;
    final scheme = Theme.of(context).colorScheme;
    final small = Theme.of(context).textTheme.bodySmall
        ?.copyWith(color: scheme.outline);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Details'),
        actions: [
          IconButton(
            tooltip: 'View',
            icon: const Icon(Icons.open_in_full),
            onPressed: _view,
          ),
          Padding(
            padding: const EdgeInsets.only(right: 12),
            child: FilledButton(onPressed: _save, child: const Text('Save')),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
        children: [
          InkWell(
            onTap: _view,
            borderRadius: BorderRadius.circular(16),
            child: Container(
              height: 180,
              decoration: BoxDecoration(
                color: scheme.surfaceContainerHigh,
                borderRadius: BorderRadius.circular(16),
              ),
              clipBehavior: Clip.antiAlias,
              child: isImage(i)
                  ? Image.network(
                      widget.api.galleryUrl(i['id'] as int),
                      headers: widget.api.headers,
                      fit: BoxFit.contain,
                    )
                  : Icon(kindIcon(i), size: 56, color: scheme.outline),
            ),
          ),
          const SizedBox(height: 6),
          Text(
            '${i['mime']} · ${sizeText(i['size'] as int)}'
            '${(i['source'] as String).startsWith('bot:') ? ' · made by ${(i['source'] as String).substring(4)}' : ''}',
            style: small,
          ),
          const SizedBox(height: 16),
          TextField(
            controller: name,
            decoration: const InputDecoration(labelText: 'Name'),
          ),
          const SizedBox(height: 16),
          Text('Tags', style: Theme.of(context).textTheme.titleSmall),
          const SizedBox(height: 6),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (final t in tags)
                InputChip(
                  label: Text(t),
                  onDeleted: () => setState(() => tags.remove(t)),
                ),
            ],
          ),
          const SizedBox(height: 6),
          TextField(
            controller: tagInput,
            textInputAction: TextInputAction.done,
            onSubmitted: _addTags,
            decoration: InputDecoration(
              hintText: 'Add a tag, such as brand or logo',
              suffixIcon: IconButton(
                tooltip: 'Add tag',
                icon: const Icon(Icons.add),
                onPressed: _addTags,
              ),
            ),
          ),
          const SizedBox(height: 16),
          TextField(
            controller: description,
            minLines: 2,
            maxLines: 5,
            maxLength: 2000,
            decoration: const InputDecoration(
              labelText: 'Description (what it is and when to use it)',
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'Bots told it exists (standing context)',
            style: Theme.of(context).textTheme.titleSmall,
          ),
          const SizedBox(height: 6),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (final b in widget.bots)
                FilterChip(
                  label: Text(b['name'] as String),
                  selected: pinned.contains(b['slug']),
                  onSelected: (on) => setState(
                    () => on
                        ? pinned.add(b['slug'] as String)
                        : pinned.remove(b['slug']),
                  ),
                ),
            ],
          ),
          if (error != null)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Text(error!, style: TextStyle(color: scheme.error)),
            ),
          const SizedBox(height: 24),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              style: TextButton.styleFrom(foregroundColor: scheme.error),
              onPressed: _delete,
              icon: const Icon(Icons.delete_outline),
              label: const Text('Delete from the gallery'),
            ),
          ),
        ],
      ),
    );
  }
}
