// The main screen: bots down the left, the chosen bot's whole conversation on
// the right (formatted text, pictures and files it shared, approvals to answer),
// and the composer at the bottom.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:pasteboard/pasteboard.dart';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:markdown_widget/markdown_widget.dart';

import 'api.dart';
import 'avatar.dart';
import 'discuss.dart';
import 'gallery.dart';
import 'push.dart';
import 'room.dart';
import 'schedules.dart';
import 'update.dart';
import 'settings.dart';
import 'social.dart';
import 'thread.dart' as t;
import 'viewer.dart';

class ChatScreen extends StatefulWidget {
  const ChatScreen({super.key, required this.api, required this.onSignedOut});
  final Api api;
  final VoidCallback onSignedOut;

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  List<Map<String, dynamic>> bots = [];
  final threads = <String, t.ThreadView>{};
  // The Orchestrator is the main bot; older servers start on the first bot listed.
  String chosen = 'orchestrator';
  String? problem;
  StreamSubscription<Map<String, dynamic>>? sub;
  final composer = TextEditingController();
  // Files waiting to go with the next message: (name, bytes).
  final pending = <(String, Uint8List)>[];
  static const maxBytes = 10 * 1024 * 1024;
  final scroll = ScrollController();
  final focus = FocusNode();

  @override
  void initState() {
    super.initState();
    _start();
    startPush(widget.api, (bot) {
      if (mounted) {
        setState(() {
          chosen = bot;
        });
      }
    }).then(
      (note) {
        if (note != null && mounted) setState(() => problem = note);
      },
      onError: (Object e) {
        if (mounted) setState(() => problem = 'Notifications: ${explain(e)}');
      },
    );
  }

  // Tokens per bot today and this week (`/api/usage`), shown in the header.
  Map<String, dynamic> usage = {};

  Future<void> _loadUsage() async {
    try {
      final got = await widget.api.get('/api/usage') as Map<String, dynamic>;
      if (mounted) setState(() => usage = got);
    } catch (_) {
      // Usage is a nicety; the chat works without it.
    }
  }

  /// "12.4k tokens today · 81k this week" for a bot, or '' if it hasn't run.
  String _usageLine(String slug) {
    int tokens(String key) =>
        ((usage[key] as List?) ?? []).cast<Map<String, dynamic>>().fold(
          0,
          (n, b) => b['bot'] == slug ? n + (b['tokens'] as num).toInt() : n,
        );
    final today = tokens('bots_today'), week = tokens('bots_week');
    if (week == 0) return '';
    return '${compactCount(today)} tokens today · ${compactCount(week)} this week';
  }

  Future<void> _loadBots() async {
    final list = await widget.api.get('/api/bots') as List<dynamic>;
    setState(() {
      bots = list
          .cast<Map<String, dynamic>>()
          .where((b) => b['disabled'] != true)
          .toList();
      if (bots.isNotEmpty && !bots.any((b) => b['slug'] == chosen)) {
        chosen = bots.first['slug'] as String;
      }
    });
  }

  Future<void> _settings() async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) =>
            SettingsScreen(api: widget.api, onSignedOut: widget.onSignedOut),
      ),
    );
    if (mounted) _act(_loadBots);
  }

  Future<void> _start() async {
    try {
      await _loadBots();
      _loadUsage();
    } on SignedOut {
      return widget.onSignedOut();
    } catch (e) {
      setState(() => problem = '$e');
    }
    sub = widget.api.events().listen(
      (e) {
        final bot = e['bot'] as String?;
        if (bot == null) return;
        setState(() => threads.putIfAbsent(bot, t.ThreadView.new).apply(e));
        if (bot == chosen) _toBottom();
        if (e['type'] == 'run_ended') _loadUsage();
      },
      onError: (Object e) => e is SignedOut
          ? widget.onSignedOut()
          : setState(() => problem = '$e'),
    );
  }

  @override
  void dispose() {
    sub?.cancel();
    composer.dispose();
    search.dispose();
    scroll.dispose();
    focus.dispose();
    super.dispose();
  }

  void _toBottom() => WidgetsBinding.instance.addPostFrameCallback((_) {
    if (scroll.hasClients) scroll.jumpTo(scroll.position.maxScrollExtent);
  });

  Future<void> _act(Future<void> Function() action) async {
    try {
      await action();
      setState(() => problem = null);
    } on SignedOut {
      widget.onSignedOut();
    } catch (e) {
      setState(() => problem = explain(e));
    }
  }

  void _send() {
    final text = composer.text.trim();
    if (text.isEmpty && pending.isEmpty) return;
    final files = List.of(pending);
    final bot = chosen;
    composer.clear();
    setState(pending.clear);
    _deliver(bot, text, files);
    focus.requestFocus();
  }

  /// Sends, waiting for the server for up to two minutes if it can't be
  /// reached (the tunnel reconnects by itself); if it still can't, or the
  /// server says no, the text and files go back in the composer, never lost.
  Future<void> _deliver(
    String bot,
    String text,
    List<(String, Uint8List)> files,
  ) async {
    final until = DateTime.now().add(const Duration(minutes: 2));
    while (true) {
      try {
        final ids = <int>[];
        for (final (name, bytes) in files) {
          ids.add(await widget.api.upload(bot, name, bytes));
        }
        await widget.api.send(bot, text, attachments: ids);
        if (mounted) setState(() => problem = null);
        return;
      } on SignedOut {
        return widget.onSignedOut();
      } catch (e) {
        if (isOffline(e) && DateTime.now().isBefore(until)) {
          if (mounted) {
            setState(
              () => problem =
                  'Waiting for the server; your message will send when '
                  "it's back.",
            );
          }
          await Future<void>.delayed(const Duration(seconds: 5));
          continue;
        }
        if (!mounted) return;
        setState(() {
          problem = '${explain(e)} Your message is back in the box.';
          if (composer.text.trim().isEmpty) composer.text = text;
          if (pending.isEmpty) pending.addAll(files);
          chosen = bot;
        });
        return;
      }
    }
  }

  void _add(String name, Uint8List bytes) {
    final total = pending.fold<int>(bytes.length, (n, f) => n + f.$2.length);
    if (total > maxBytes) {
      setState(() => problem = 'Files sent together can be up to 10 MB.');
    } else if (pending.length >= 10) {
      setState(() => problem = 'Send at most ten files at once.');
    } else {
      setState(() => pending.add((name, bytes)));
    }
  }

  Future<void> _attach() async {
    for (final f in await openFiles()) {
      _add(f.name, await f.readAsBytes());
    }
  }

  /// Picks items from the gallery and attaches them like any file.
  Future<void> _fromGallery() async {
    final picked = await Navigator.of(context).push<List<Map<String, dynamic>>>(
      MaterialPageRoute(
        builder: (_) =>
            GalleryScreen(api: widget.api, bots: bots, picking: true),
      ),
    );
    for (final item in picked ?? <Map<String, dynamic>>[]) {
      if ((item['size'] as int) > maxBytes) {
        setState(
          () => problem =
              "${item['name']} is over 10 MB, too big to send in a chat.",
        );
        continue;
      }
      await _act(() async {
        final bytes = await widget.api.download(
          widget.api.galleryUrl(item['id'] as int),
        );
        _add(item['name'] as String, Uint8List.fromList(bytes));
      });
    }
    focus.requestFocus();
  }

  /// Ctrl+V: a copied picture becomes an attachment; text pastes as usual.
  Future<void> _paste() async {
    final image = await Pasteboard.image;
    if (image != null) {
      _add('pasted-${DateTime.now().millisecondsSinceEpoch}.png', image);
      return;
    }
    final text = (await Clipboard.getData(Clipboard.kTextPlain))?.text;
    if (text == null) return;
    final sel = composer.selection;
    final start = sel.isValid ? sel.start : composer.text.length;
    final end = sel.isValid ? sel.end : composer.text.length;
    composer.value = TextEditingValue(
      text: composer.text.replaceRange(start, end, text),
      selection: TextSelection.collapsed(offset: start + text.length),
    );
  }

  /// Saves bytes where the owner chooses.
  Future<void> _save(String suggested, List<int> Function() bytes) async {
    final where = await getSaveLocation(suggestedName: suggested);
    if (where == null) return;
    await File(where.path).writeAsBytes(bytes());
    setState(() => problem = 'Saved to ${where.path}');
  }

  Map<String, dynamic>? get _bot =>
      bots.where((b) => b['slug'] == chosen).firstOrNull;

  /// The chosen bot's model, short: `claude-opus-5` for `claude-bridge/claude-opus-5`.
  String _modelLabel() {
    final model = _bot?['model'] as String?;
    return model == null ? 'Default model' : model.split('/').last;
  }

  /// Switches the chosen bot's model from the chat; it takes effect on its next message.
  Future<void> _changeModel() async {
    final bot = _bot;
    if (bot == null) return;
    List<String> models = [];
    try {
      models = [
        for (final m in await widget.api.get('/api/models') as List)
          m['id'] as String,
      ];
    } catch (_) {
      // The picker still lets the owner type one.
    }
    if (!mounted) return;
    final picked = await pickModel(
      context,
      models,
      bot['model'] as String? ?? '',
    );
    if (picked == null) return;
    final edited = {...bot, 'model': picked.isEmpty ? null : picked};
    await _act(() async {
      await widget.api.post('/api/bots/update', edited);
      await _loadBots();
    });
  }

  t.ThreadView get view => threads[chosen] ?? t.ThreadView();

  /// Filters the bot list in the menu.
  final search = TextEditingController();

  /// A wide window keeps the menu beside the chat; a phone or a narrow
  /// window opens it as a drawer from the top bar's menu button.
  bool _wide(BoxConstraints box) => box.maxWidth >= 840;

  final scaffold = GlobalKey<ScaffoldState>();

  void _open(String slug) {
    setState(() => chosen = slug);
    if (scaffold.currentState?.isDrawerOpen ?? false) {
      Navigator.of(context).pop();
    }
    _toBottom();
    focus.requestFocus();
  }

  void _push(Widget screen) {
    if (scaffold.currentState?.isDrawerOpen ?? false) {
      Navigator.of(context).pop();
    }
    Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => screen));
  }

  // Layout after Grok's app (DESIGN §12.4): one conversation full screen, a
  // menu with everything else, a round button each side of the top bar and a
  // card-shaped composer. Our own bots' faces stand where Grok has its mark.
  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return LayoutBuilder(
      builder: (context, box) {
        final wide = _wide(box);
        return Scaffold(
          key: scaffold,
          drawer: wide
              ? null
              : Drawer(width: box.maxWidth * 0.86, child: _menu(scheme)),
          body: SafeArea(
            child: Column(
              children: [
                UpdateBanner(api: widget.api),
                Expanded(
                  child: wide
                      ? Row(
                          children: [
                            SizedBox(width: 280, child: _menu(scheme)),
                            VerticalDivider(
                              width: 1,
                              color: scheme.outlineVariant,
                            ),
                            Expanded(child: _conversation(scheme, wide)),
                          ],
                        )
                      : _conversation(scheme, wide),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  /// A round grey button, as in the top bar and the menu's foot.
  Widget _round(
    IconData icon,
    String tooltip,
    VoidCallback onPressed,
    ColorScheme scheme,
  ) => IconButton.filledTonal(
    tooltip: tooltip,
    style: IconButton.styleFrom(
      backgroundColor: scheme.surfaceContainerHigh,
      foregroundColor: scheme.onSurface,
    ),
    icon: Icon(icon, size: 20),
    onPressed: onPressed,
  );

  /// The menu: places, then the bots, then search and settings at the foot.
  Widget _menu(ColorScheme scheme) {
    final text = Theme.of(context).textTheme;
    final q = search.text.trim().toLowerCase();
    final shown = [
      for (final b in bots)
        if (q.isEmpty || '${b['name']} ${b['remit']}'.toLowerCase().contains(q))
          b,
    ];
    Widget place(IconData icon, String label, Widget screen) => ListTile(
      leading: Icon(icon),
      title: Text(label, style: text.titleMedium),
      dense: true,
      onTap: () => _push(screen),
    );
    return Stack(
      children: [
        ListView(
          padding: const EdgeInsets.fromLTRB(8, 16, 8, 96),
          children: [
            ListTile(
              leading: CircleAvatar(
                backgroundColor: scheme.surfaceContainerHighest,
                child: Icon(Icons.hub_outlined, color: scheme.onSurface),
              ),
              title: Text('OrphusBot', style: text.titleMedium),
              subtitle: Text(
                Uri.tryParse(widget.api.server)?.host ?? widget.api.server,
              ),
            ),
            const SizedBox(height: 8),
            place(
              Icons.bubble_chart_outlined,
              'Ideas Room',
              IdeasRoom(api: widget.api),
            ),
            place(
              Icons.alarm,
              'Schedules',
              SchedulesScreen(api: widget.api, bots: bots),
            ),
            place(
              Icons.campaign_outlined,
              'Social',
              SocialScreen(api: widget.api),
            ),
            place(
              Icons.photo_library_outlined,
              'Gallery',
              GalleryScreen(api: widget.api, bots: bots),
            ),
            place(
              Icons.forum_outlined,
              'Discussions',
              DiscussionsScreen(api: widget.api, bots: bots),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 20, 16, 6),
              child: Text(
                'Bots',
                style: text.labelLarge?.copyWith(color: scheme.outline),
              ),
            ),
            for (final b in shown) _botTile(b, scheme),
          ],
        ),
        // The foot, floating over the list as in Grok's menu.
        Positioned(
          left: 12,
          right: 12,
          bottom: 12,
          child: Row(
            children: [
              Expanded(
                child: TextField(
                  controller: search,
                  onChanged: (_) => setState(() {}),
                  decoration: InputDecoration(
                    hintText: 'Search bots',
                    prefixIcon: const Icon(Icons.search),
                    isDense: true,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(28),
                      borderSide: BorderSide.none,
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              _round(Icons.settings_outlined, 'Settings', () {
                if (scaffold.currentState?.isDrawerOpen ?? false) {
                  Navigator.of(context).pop();
                }
                _settings();
              }, scheme),
            ],
          ),
        ),
      ],
    );
  }

  Widget _botTile(Map<String, dynamic> b, ColorScheme scheme) {
    final slug = b['slug'] as String;
    final v = threads[slug];
    final waiting = v?.waiting ?? 0;
    final working = v != null && v.run != t.RunState.idle;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 1),
      child: ListTile(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        leading: BotAvatar(
          key: ValueKey(slug),
          slug: faceOf(b, slug),
          mood: v?.mood ?? 0,
          size: 36,
        ),
        selected: slug == chosen,
        selectedTileColor: scheme.surfaceContainerHigh,
        selectedColor: scheme.onSurface,
        title: Text(b['name'] as String),
        subtitle: Text(
          waiting > 0
              ? 'Needs you'
              : (working ? 'Working…' : (b['remit'] as String? ?? '')),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(color: waiting > 0 ? scheme.error : scheme.outline),
        ),
        trailing: waiting > 0 ? Badge(label: Text('$waiting')) : null,
        onTap: () => _open(slug),
      ),
    );
  }

  /// Things to ask a bot with an empty chat, as Grok's quick actions.
  static const starters = [
    'What can you do for me?',
    'What are you working on?',
    'Summarise what you did today',
  ];

  Widget _conversation(ColorScheme scheme, bool wide) {
    final v = view;
    final name =
        bots.firstWhere(
              (b) => b['slug'] == chosen,
              orElse: () => {'name': chosen},
            )['name']
            as String;
    final status = [
      switch (v.run) {
        t.RunState.idle => 'Ready',
        t.RunState.queued => 'Waiting${v.where == null ? '' : ': ${v.where}'}',
        t.RunState.running => 'Working${v.where == null ? '' : ' ${v.where}'}',
      },
      _usageLine(chosen),
    ].where((p) => p.isNotEmpty).join(' · ');
    return Column(
      children: [
        // Top bar: menu, who (a pill with the bot's face), model.
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
          child: Row(
            children: [
              if (!wide)
                _round(
                  Icons.menu,
                  'Menu',
                  () => scaffold.currentState?.openDrawer(),
                  scheme,
                )
              else
                const SizedBox(width: 48),
              Expanded(
                child: Center(
                  child: Tooltip(
                    message: status,
                    child: Container(
                      padding: const EdgeInsets.fromLTRB(6, 4, 14, 4),
                      decoration: ShapeDecoration(
                        color: scheme.surfaceContainerHigh,
                        shape: const StadiumBorder(),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          BotAvatar(
                            key: ValueKey('pill-$chosen'),
                            slug: faceOf(_bot, chosen),
                            mood: v.mood,
                            size: 26,
                          ),
                          const SizedBox(width: 8),
                          Flexible(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Text(
                                  name,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: Theme.of(context).textTheme.labelLarge,
                                ),
                                Text(
                                  status,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: Theme.of(context).textTheme.labelSmall
                                      ?.copyWith(color: scheme.outline),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
              _round(
                Icons.tune,
                'Model: ${_modelLabel()}',
                _changeModel,
                scheme,
              ),
            ],
          ),
        ),
        if (problem != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 4, 12, 0),
            child: Material(
              color: scheme.surfaceContainerHigh,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(16),
              ),
              child: ListTile(
                dense: true,
                title: Text(problem!),
                trailing: IconButton(
                  tooltip: 'Dismiss',
                  icon: const Icon(Icons.close, size: 18),
                  onPressed: () => setState(() => problem = null),
                ),
              ),
            ),
          ),
        Expanded(
          child: v.items.isEmpty && v.streaming == null
              ? _empty(scheme, name, v.mood)
              : ListView(
                  controller: scroll,
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                  children: [
                    for (final item in v.items) _item(item, scheme, name),
                    if (v.streaming != null)
                      _bubble(v.streaming!, false, scheme),
                  ],
                ),
        ),
        _composer(name, scheme, v),
      ],
    );
  }

  /// An empty chat: the bot itself in the middle (poke it), quick starters
  /// just above the composer.
  Widget _empty(ColorScheme scheme, String name, int mood) => Column(
    children: [
      Expanded(
        child: Center(
          child: SingleChildScrollView(
            child: Column(
              children: [
                BotAvatar(
                  key: ValueKey('stage-$chosen'),
                  slug: faceOf(_bot, chosen),
                  mood: mood,
                  size: 170,
                  body: true,
                ),
                const SizedBox(height: 12),
                Text(
                  'Ask $name anything',
                  style: TextStyle(color: scheme.outline),
                ),
              ],
            ),
          ),
        ),
      ),
      SizedBox(
        height: 44,
        child: ListView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          children: [
            for (final s in starters)
              Padding(
                padding: const EdgeInsets.only(right: 8),
                child: ActionChip(
                  label: Text(s),
                  onPressed: () {
                    composer.text = s;
                    _send();
                  },
                ),
              ),
          ],
        ),
      ),
    ],
  );

  Widget _item(t.Item item, ColorScheme scheme, String name) => switch (item) {
    t.Message(:final mine, :final text) => _bubble(text, mine, scheme),
    t.Notice(:final text, :final error) => Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Center(
        child: Text(
          text,
          textAlign: TextAlign.center,
          style: TextStyle(color: error ? scheme.error : scheme.outline),
        ),
      ),
    ),
    t.Artifact() => _artifact(item, scheme),
    t.Attached() => _attached(item, scheme),
    t.Card() => _card(item, scheme, name),
  };

  /// The owner's words in a grey bubble on the right; a bot's reply as plain
  /// text across the page with its actions underneath, as in Grok.
  Widget _bubble(String text, bool mine, ColorScheme scheme) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    if (mine) {
      return Align(
        alignment: Alignment.centerRight,
        child: Container(
          constraints: const BoxConstraints(maxWidth: 560),
          margin: const EdgeInsets.fromLTRB(48, 8, 0, 8),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          decoration: BoxDecoration(
            color: scheme.surfaceContainerHigh,
            borderRadius: BorderRadius.circular(22),
          ),
          child: SelectableText(text),
        ),
      );
    }
    Widget action(IconData icon, String tip, VoidCallback onPressed) =>
        IconButton(
          tooltip: tip,
          iconSize: 18,
          visualDensity: VisualDensity.compact,
          color: scheme.outline,
          icon: Icon(icon),
          onPressed: onPressed,
        );
    return Align(
      alignment: Alignment.centerLeft,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 760),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: MarkdownBlock(
                data: text,
                selectable: true,
                config: markdownConfig(dark, scheme),
              ),
            ),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                action(Icons.copy_outlined, 'Copy', () {
                  Clipboard.setData(ClipboardData(text: text));
                  setState(() => problem = 'Copied.');
                }),
                action(
                  Icons.file_download_outlined,
                  'Save as a file',
                  () => _save('$chosen-reply.md', () => utf8.encode(text)),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  /// A file the owner sent: pictures show; anything else is a tile.
  Widget _attached(t.Attached a, ColorScheme scheme) {
    final url = widget.api.attachmentUrl(a.id);
    return Align(
      alignment: Alignment.centerRight,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 6),
        constraints: const BoxConstraints(maxWidth: 360),
        decoration: BoxDecoration(
          color: scheme.primaryContainer,
          borderRadius: BorderRadius.circular(12),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: () => openViewer(context, widget.api, a.name, url),
          child: a.image
              ? Image.network(
                  url,
                  headers: widget.api.headers,
                  fit: BoxFit.contain,
                  errorBuilder: (_, _, _) => ListTile(
                    leading: const Icon(Icons.image_outlined),
                    title: Text(a.name),
                  ),
                )
              : ListTile(
                  leading: Icon(kindIconFor(a.name)),
                  title: Text(a.name),
                  subtitle: Text('${(a.size / 1024).ceil()} KB'),
                ),
        ),
      ),
    );
  }

  /// A file the bot shared: pictures show in the chat; everything opens or saves.
  Widget _artifact(t.Artifact a, ColorScheme scheme) {
    final url = widget.api.artifactUrl(a.id);
    final label =
        '${a.name}${a.version > 1 ? ' (version ${a.version})' : ''} · ${(a.size / 1024).ceil()} KB';
    return Align(
      alignment: Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 6),
        constraints: const BoxConstraints(maxWidth: 480),
        decoration: BoxDecoration(
          border: Border.all(color: scheme.outlineVariant),
          borderRadius: BorderRadius.circular(12),
        ),
        clipBehavior: Clip.antiAlias,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (a.isImage)
              InkWell(
                onTap: () => openViewer(context, widget.api, a.name, url),
                child: Image.network(
                  url,
                  headers: widget.api.headers,
                  fit: BoxFit.contain,
                  errorBuilder: (_, _, _) => const Padding(
                    padding: EdgeInsets.all(12),
                    child: Text("Couldn't load the picture"),
                  ),
                ),
              )
            else if (Peek.shows(a.name))
              InkWell(
                onTap: () => openViewer(context, widget.api, a.name, url),
                child: Peek(
                  key: ValueKey(url),
                  api: widget.api,
                  name: a.name,
                  url: url,
                ),
              ),
            ListTile(
              onTap: () => openViewer(context, widget.api, a.name, url),
              leading: Icon(kindIconFor(a.name)),
              title: Text(label),
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  IconButton(
                    tooltip: 'Save to the gallery',
                    icon: const Icon(Icons.add_photo_alternate_outlined),
                    onPressed: () async {
                      await _act(() => widget.api.galleryFromArtifact(a.id));
                      if (mounted && problem == null) {
                        setState(
                          () => problem = 'Saved ${a.name} to the gallery.',
                        );
                      }
                    },
                  ),
                  IconButton(
                    tooltip: 'Save',
                    icon: const Icon(Icons.download),
                    onPressed: () => _act(() async {
                      final bytes = await widget.api.download(url);
                      await _save(a.name, () => bytes);
                    }),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _card(t.Card c, ColorScheme scheme, String name) {
    final k = c.kind;
    final title = switch (k['kind']) {
      'approval' => 'Allow $name to use ${k['tool']}?',
      'takeover' => '$name needs you on its screen',
      _ => (k['title'] as String?) ?? 'A question',
    };
    final detail = switch (k['kind']) {
      'approval' => const JsonEncoder.withIndent('  ').convert(k['input']),
      'takeover' => k['reason'] as String? ?? '',
      _ => k['message'] as String? ?? '',
    };
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 8),
      shape: RoundedRectangleBorder(
        side: BorderSide(
          color: c.outcome == null ? scheme.error : scheme.outlineVariant,
        ),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: Theme.of(context).textTheme.titleSmall),
            if (detail.isNotEmpty) ...[
              const SizedBox(height: 8),
              SelectableText(
                detail,
                style: const TextStyle(fontFamily: 'monospace'),
              ),
            ],
            const SizedBox(height: 10),
            if (c.outcome != null)
              Text(c.outcome!, style: TextStyle(color: scheme.outline))
            else if (c.approval)
              Wrap(
                spacing: 8,
                children: [
                  FilledButton(
                    onPressed: () => _act(
                      () => widget.api.answer(c.id, {'decision': 'allow'}),
                    ),
                    child: const Text('Allow once'),
                  ),
                  OutlinedButton(
                    onPressed: () => _act(
                      () => widget.api.answer(c.id, {'decision': 'always'}),
                    ),
                    child: Text('Always allow ${k['tool']}'),
                  ),
                  OutlinedButton(
                    style: OutlinedButton.styleFrom(
                      foregroundColor: scheme.error,
                    ),
                    onPressed: () => _act(
                      () => widget.api.answer(c.id, {'decision': 'deny'}),
                    ),
                    child: const Text('Deny'),
                  ),
                ],
              )
            else if (k['kind'] == 'takeover')
              FilledButton(
                onPressed: () =>
                    _act(() => widget.api.answer(c.id, {'confirmed': true})),
                child: const Text("I'm done"),
              )
            else
              _QuestionAnswer(
                options: (k['options'] as List<dynamic>? ?? []).cast<String>(),
                onAnswer: (v) =>
                    _act(() => widget.api.answer(c.id, {'value': v})),
              ),
          ],
        ),
      ),
    );
  }

  /// Grok's composer: one rounded card, the text on top, then attach, the
  /// model pill, and send (or Stop while the bot works).
  Widget _composer(String name, ColorScheme scheme, t.ThreadView v) {
    final working = v.run != t.RunState.idle;
    final hasText = composer.text.trim().isNotEmpty || pending.isNotEmpty;
    return Padding(
      padding: const EdgeInsets.fromLTRB(10, 6, 10, 10),
      child: Container(
        decoration: BoxDecoration(
          color: scheme.surfaceContainerHigh,
          borderRadius: BorderRadius.circular(28),
        ),
        padding: const EdgeInsets.fromLTRB(14, 6, 8, 8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (pending.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 6, bottom: 4),
                child: Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final (i, (fname, bytes)) in pending.indexed)
                      InputChip(
                        backgroundColor: scheme.surfaceContainerHighest,
                        avatar:
                            RegExp(
                              r'\.(png|jpe?g|gif|webp)$',
                              caseSensitive: false,
                            ).hasMatch(fname)
                            ? ClipRRect(
                                borderRadius: BorderRadius.circular(4),
                                child: Image.memory(
                                  bytes,
                                  width: 24,
                                  height: 24,
                                  fit: BoxFit.cover,
                                ),
                              )
                            : const Icon(Icons.attach_file, size: 18),
                        label: Text(
                          '$fname · ${(bytes.length / 1024).ceil()} KB',
                        ),
                        onDeleted: () => setState(() => pending.removeAt(i)),
                      ),
                  ],
                ),
              ),
            CallbackShortcuts(
              bindings: {
                const SingleActivator(LogicalKeyboardKey.enter): _send,
                const SingleActivator(LogicalKeyboardKey.keyV, control: true):
                    _paste,
              },
              child: TextField(
                controller: composer,
                focusNode: focus,
                autofocus: !(Platform.isAndroid || Platform.isIOS),
                minLines: 1,
                maxLines: 6,
                onChanged: (_) => setState(() {}),
                decoration: InputDecoration(
                  hintText: 'Ask $name anything',
                  filled: false,
                  border: InputBorder.none,
                  contentPadding: const EdgeInsets.symmetric(vertical: 10),
                ),
              ),
            ),
            Row(
              children: [
                PopupMenuButton<String>(
                  tooltip: 'Attach pictures or files',
                  onSelected: (how) =>
                      how == 'gallery' ? _fromGallery() : _attach(),
                  itemBuilder: (_) => const [
                    PopupMenuItem(
                      value: 'computer',
                      child: ListTile(
                        leading: Icon(Icons.computer),
                        title: Text('From this device'),
                      ),
                    ),
                    PopupMenuItem(
                      value: 'gallery',
                      child: ListTile(
                        leading: Icon(Icons.photo_library_outlined),
                        title: Text('From the gallery'),
                      ),
                    ),
                  ],
                  child: CircleAvatar(
                    radius: 18,
                    backgroundColor: scheme.surfaceContainerHighest,
                    child: Icon(
                      Icons.attach_file,
                      size: 18,
                      color: scheme.onSurface,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: ActionChip(
                      avatar: const Icon(Icons.auto_awesome_outlined, size: 16),
                      backgroundColor: scheme.surfaceContainerHighest,
                      label: Text(
                        _modelLabel(),
                        overflow: TextOverflow.ellipsis,
                      ),
                      onPressed: _changeModel,
                    ),
                  ),
                ),
                if (working && !hasText)
                  FilledButton.icon(
                    onPressed: () => _act(() => widget.api.stop(chosen)),
                    icon: const Icon(Icons.stop, size: 18),
                    label: const Text('Stop'),
                  )
                else
                  IconButton.filled(
                    tooltip: 'Send (Enter)',
                    onPressed: hasText ? _send : null,
                    icon: const Icon(Icons.arrow_upward),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// Pick an option, or type an answer.
class _QuestionAnswer extends StatefulWidget {
  const _QuestionAnswer({required this.options, required this.onAnswer});
  final List<String> options;
  final void Function(String) onAnswer;
  @override
  State<_QuestionAnswer> createState() => _QuestionAnswerState();
}

class _QuestionAnswerState extends State<_QuestionAnswer> {
  final text = TextEditingController();
  @override
  Widget build(BuildContext context) => widget.options.isNotEmpty
      ? Wrap(
          spacing: 8,
          children: [
            for (final o in widget.options)
              OutlinedButton(
                onPressed: () => widget.onAnswer(o),
                child: Text(o),
              ),
          ],
        )
      : Row(
          children: [
            Expanded(
              child: TextField(
                controller: text,
                decoration: const InputDecoration(hintText: 'Your answer'),
              ),
            ),
            const SizedBox(width: 8),
            FilledButton(
              onPressed: () => widget.onAnswer(text.text),
              child: const Text('Answer'),
            ),
          ],
        );
}

/// How replies look: clear headings and body text, highlighted code blocks
/// with their language and a copy button, and tinted inline code.
MarkdownConfig markdownConfig(bool dark, ColorScheme scheme) {
  final body = TextStyle(fontSize: 15, height: 1.45, color: scheme.onSurface);
  TextStyle heading(double size) => TextStyle(
    fontSize: size,
    height: 1.3,
    fontWeight: FontWeight.w700,
    color: scheme.onSurface,
  );
  final pre = (dark ? PreConfig.darkConfig : const PreConfig()).copy(
    textStyle: const TextStyle(
      fontFamily: 'monospace',
      fontSize: 13.5,
      height: 1.4,
    ),
    decoration: BoxDecoration(
      color: scheme.surfaceContainerHighest,
      borderRadius: BorderRadius.circular(8),
    ),
    wrapper: (child, code, language) => Stack(
      children: [
        child,
        Positioned(
          top: 2,
          right: 2,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (language.isNotEmpty)
                Text(
                  language,
                  style: TextStyle(fontSize: 11, color: scheme.outline),
                ),
              IconButton(
                tooltip: 'Copy code',
                iconSize: 16,
                visualDensity: VisualDensity.compact,
                icon: const Icon(Icons.copy),
                onPressed: () => Clipboard.setData(ClipboardData(text: code)),
              ),
            ],
          ),
        ),
      ],
    ),
  );
  final base = dark ? MarkdownConfig.darkConfig : MarkdownConfig.defaultConfig;
  return base.copy(
    configs: [
      pre,
      PConfig(textStyle: body),
      H1Config(style: heading(21)),
      H2Config(style: heading(18)),
      H3Config(style: heading(16)),
      CodeConfig(
        style: TextStyle(
          fontFamily: 'monospace',
          fontSize: 13.5,
          backgroundColor: scheme.surfaceContainerHighest,
        ),
      ),
    ],
  );
}

/// 950, 12.4k, 3.1M.
String compactCount(int n) => n < 1000
    ? '$n'
    : n < 1000000
    ? '${(n / 1000).toStringAsFixed(n < 10000 ? 1 : 0)}k'
    : '${(n / 1000000).toStringAsFixed(1)}M';
