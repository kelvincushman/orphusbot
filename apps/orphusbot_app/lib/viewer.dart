// Viewing what bots make and what the owner sends, inside the app: PDFs page
// by page, pictures with zoom, video and audio with controls, Markdown
// rendered, and code or data highlighted. Anything else opens outside.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:markdown_widget/markdown_widget.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:pdfrx/pdfrx.dart';
import 'package:url_launcher/url_launcher.dart';

import 'api.dart';
import 'chat.dart' show markdownConfig;

enum Kind { image, pdf, video, audio, markdown, text, other }

/// Code and data shown highlighted, by extension → the fence language.
const _code = {
  'txt': '',
  'log': '',
  'csv': '',
  'json': 'json',
  'yaml': 'yaml',
  'yml': 'yaml',
  'toml': 'toml',
  'xml': 'xml',
  'html': 'html',
  'css': 'css',
  'js': 'javascript',
  'ts': 'typescript',
  'py': 'python',
  'rs': 'rust',
  'dart': 'dart',
  'sh': 'bash',
  'sql': 'sql',
  'go': 'go',
  'java': 'java',
  'kt': 'kotlin',
  'c': 'c',
  'h': 'c',
  'cpp': 'cpp',
  'swift': 'swift',
};

String _ext(String name) {
  final dot = name.lastIndexOf('.');
  return dot < 0 ? '' : name.substring(dot + 1).toLowerCase();
}

Kind kindOf(String name) => switch (_ext(name)) {
  'png' || 'jpg' || 'jpeg' || 'gif' || 'webp' || 'bmp' => Kind.image,
  'pdf' => Kind.pdf,
  'mp4' || 'webm' || 'mov' || 'mkv' || 'm4v' => Kind.video,
  'mp3' || 'wav' || 'ogg' || 'oga' || 'opus' || 'm4a' || 'flac' => Kind.audio,
  'md' || 'markdown' => Kind.markdown,
  final e when _code.containsKey(e) => Kind.text,
  _ => Kind.other,
};

IconData kindIconFor(String name) => switch (kindOf(name)) {
  Kind.image => Icons.image_outlined,
  Kind.pdf => Icons.picture_as_pdf_outlined,
  Kind.video => Icons.movie_outlined,
  Kind.audio => Icons.audiotrack_outlined,
  Kind.markdown => Icons.article_outlined,
  Kind.text => Icons.code,
  Kind.other => Icons.description_outlined,
};

// ponytail: big text files are cut at 1 MB; a paged reader if bots make bigger ones.
const _textLimit = 1024 * 1024;

/// Text as Markdown: Markdown as it is, code fenced so it gets highlighted.
String asMarkdown(String name, List<int> bytes) {
  final cut = bytes.length > _textLimit;
  final text = utf8.decode(
    cut ? bytes.sublist(0, _textLimit) : bytes,
    allowMalformed: true,
  );
  final more = cut
      ? '\n\n*(The rest is cut off here; save the file to see it all.)*'
      : '';
  if (kindOf(name) == Kind.markdown) return '$text$more';
  final fence = text.contains('```') ? '~~~~' : '```';
  return '$fence${_code[_ext(name)] ?? ''}\n$text\n$fence$more';
}

Future<void> openViewer(
  BuildContext context,
  Api api,
  String name,
  String url,
) => Navigator.push(
  context,
  MaterialPageRoute(
    builder: (_) => Viewer(api: api, name: name, url: url),
  ),
);

class Viewer extends StatefulWidget {
  const Viewer({
    super.key,
    required this.api,
    required this.name,
    required this.url,
  });
  final Api api;
  final String name;
  final String url;
  @override
  State<Viewer> createState() => _ViewerState();
}

class _ViewerState extends State<Viewer> {
  late final kind = kindOf(widget.name);
  Future<Uint8List>? bytes;
  Player? player;
  VideoController? video;
  String? error;

  @override
  void initState() {
    super.initState();
    if (kind == Kind.video || kind == Kind.audio) {
      player = Player();
      video = VideoController(player!);
      player!.open(Media(widget.url, httpHeaders: widget.api.headers));
    } else if (kind != Kind.image) {
      bytes = widget.api.download(widget.url).then(Uint8List.fromList);
    }
  }

  @override
  void dispose() {
    player?.dispose();
    super.dispose();
  }

  /// Saves a copy and opens it with the computer's own app.
  Future<void> _openOutside() async {
    try {
      final data = await widget.api.download(widget.url);
      final dir = await Directory.systemTemp.createTemp('orphusbot-');
      final file = File('${dir.path}/${widget.name.split('/').last}');
      await file.writeAsBytes(data);
      await launchUrl(Uri.file(file.path));
    } catch (e) {
      setState(() => error = explain(e));
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final desktop = Platform.isLinux || Platform.isMacOS || Platform.isWindows;
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.name, overflow: TextOverflow.ellipsis),
        actions: [
          if (desktop)
            IconButton(
              tooltip: 'Open with another app',
              icon: const Icon(Icons.open_in_new),
              onPressed: _openOutside,
            ),
        ],
      ),
      body: error != null
          ? Center(child: Text(error!))
          : switch (kind) {
              Kind.image => InteractiveViewer(
                maxScale: 8,
                child: Center(
                  child: Image.network(
                    widget.url,
                    headers: widget.api.headers,
                    errorBuilder: (_, _, _) =>
                        const Text("Couldn't load the picture"),
                  ),
                ),
              ),
              Kind.video || Kind.audio => Center(
                child: Video(
                  controller: video!,
                  // Audio has no picture: a short bar of controls is enough.
                  height: kind == Kind.audio ? 120 : null,
                ),
              ),
              _ => FutureBuilder<Uint8List>(
                future: bytes,
                builder: (context, got) {
                  if (got.hasError) {
                    return Center(child: Text(explain(got.error!)));
                  }
                  if (!got.hasData) {
                    return const Center(child: CircularProgressIndicator());
                  }
                  return switch (kind) {
                    Kind.pdf => PdfViewer.data(
                      got.data!,
                      sourceName: widget.url,
                      params: PdfViewerParams(
                        backgroundColor: scheme.surfaceContainer,
                      ),
                    ),
                    Kind.markdown || Kind.text => MarkdownWidget(
                      data: asMarkdown(widget.name, got.data!),
                      padding: const EdgeInsets.all(20),
                      config: markdownConfig(
                        Theme.of(context).brightness == Brightness.dark,
                        scheme,
                      ),
                    ),
                    _ => Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            kindIconFor(widget.name),
                            size: 64,
                            color: scheme.outline,
                          ),
                          const SizedBox(height: 12),
                          const Text("The app can't show this kind of file."),
                          if (desktop)
                            TextButton(
                              onPressed: _openOutside,
                              child: const Text('Open with another app'),
                            ),
                        ],
                      ),
                    ),
                  };
                },
              ),
            },
    );
  }
}

/// A look inside a file in the chat: a PDF's first page or the start of a
/// Markdown document. Tapping it opens the full viewer.
class Peek extends StatefulWidget {
  const Peek({
    super.key,
    required this.api,
    required this.name,
    required this.url,
  });
  final Api api;
  final String name;
  final String url;

  static bool shows(String name) =>
      const {Kind.pdf, Kind.markdown}.contains(kindOf(name));

  @override
  State<Peek> createState() => _PeekState();
}

class _PeekState extends State<Peek> {
  // Fetched once, not on every rebuild of the chat.
  late final bytes = widget.api.download(widget.url);
  String get name => widget.name;
  String get url => widget.url;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SizedBox(
      height: 220,
      child: FutureBuilder<List<int>>(
        future: bytes,
        builder: (context, got) {
          if (!got.hasData) {
            return Center(
              child: got.hasError
                  ? Icon(kindIconFor(name), color: scheme.outline)
                  : const CircularProgressIndicator(),
            );
          }
          if (kindOf(name) == Kind.pdf) {
            return PdfDocumentViewBuilder(
              documentRef: PdfDocumentRefData(
                Uint8List.fromList(got.data!),
                sourceName: url,
              ),
              builder: (context, doc) => PdfPageView(
                document: doc,
                pageNumber: 1,
                backgroundColor: Colors.white,
              ),
            );
          }
          // The first lines, fading out at the bottom.
          final text = utf8.decode(
            got.data!.take(3000).toList(),
            allowMalformed: true,
          );
          return ShaderMask(
            shaderCallback: (r) => const LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [Colors.white, Colors.white, Colors.transparent],
              stops: [0, 0.7, 1],
            ).createShader(r),
            blendMode: BlendMode.dstIn,
            child: IgnorePointer(
              child: MarkdownWidget(
                data: text,
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                padding: const EdgeInsets.all(12),
                config: markdownConfig(
                  Theme.of(context).brightness == Brightness.dark,
                  scheme,
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}
