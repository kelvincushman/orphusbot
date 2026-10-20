// A bot's animated face, drawn by Rive from design/bot-avatar: each house bot
// has its own style (assets/faces/<slug>.riv), others get default.riv. Each
// file has two artboards, `Avatar` (the head) and `Robot` (the whole bot on
// legs, wheels, tracks, rotors…), each with the state machine `Bot`: a
// `state` input that follows the bot (ThreadView.mood) and a `poke` trigger.
// Tapping fires poke from inside the file; idle robots also fidget now and
// then by themselves.
import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:rive/rive.dart' as rive;

// Loaded once per style and shared by every face using it.
final _files = <String, Future<rive.File?>>{};
Future<rive.File?> _load(String style) => _files.putIfAbsent(
  style,
  () => rive.File.asset(
    'assets/faces/$style.riv',
    riveFactory: rive.Factory.flutter,
  ),
);

/// The bot's face file, or the default one if it has no style of its own.
Future<rive.File?> faceFile(String slug) async {
  try {
    final f = await _load(slug);
    if (f != null) return f;
  } catch (_) {
    // No style for this bot: the default face.
  }
  return _load('default');
}

/// The face a bot shows: its library style, else its own (by slug).
String faceOf(Map<String, dynamic>? bot, String slug) =>
    bot?['face'] as String? ?? slug;

class BotAvatar extends StatefulWidget {
  const BotAvatar({
    super.key,
    required this.slug,
    required this.mood,
    this.size = 40,
    this.body = false,
  });
  final String slug;
  final int mood;
  final double size;

  /// The whole robot (`Robot`, [size] wide and 1.3 times as tall) instead of the head.
  final bool body;

  @override
  State<BotAvatar> createState() => _BotAvatarState();
}

class _BotAvatarState extends State<BotAvatar> {
  rive.RiveWidgetController? controller;
  rive.NumberInput? state;
  rive.TriggerInput? poke;
  Timer? fidget;

  @override
  void initState() {
    super.initState();
    faceFile(widget.slug).then((f) {
      if (f == null || !mounted) return;
      setState(() {
        controller = rive.RiveWidgetController(
          f,
          artboardSelector: widget.body
              ? rive.ArtboardSelector.byName('Robot')
              : const rive.ArtboardDefault(),
        );
        // ignore: deprecated_member_use
        state = controller!.stateMachine.number('state');
        // ignore: deprecated_member_use
        poke = controller!.stateMachine.trigger('poke');
        state?.value = widget.mood.toDouble();
      });
    });
    if (widget.body) _fidgetLater();
  }

  // An idle robot gets bored: every 20–50 s it does its poke reaction.
  void _fidgetLater() {
    fidget = Timer(Duration(seconds: 20 + Random().nextInt(30)), () {
      if (!mounted) return;
      if (widget.mood == 0) poke?.fire();
      _fidgetLater();
    });
  }

  @override
  void didUpdateWidget(BotAvatar old) {
    super.didUpdateWidget(old);
    state?.value = widget.mood.toDouble();
  }

  @override
  void dispose() {
    fidget?.cancel();
    poke?.dispose();
    state?.dispose();
    controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => SizedBox(
    width: widget.size,
    height: widget.body ? widget.size * 1.3 : widget.size,
    child: controller == null
        ? null
        : rive.RiveWidget(controller: controller!, fit: rive.Fit.contain),
  );
}

/// Every face in the library: the styles shipped in assets/faces.
Future<List<String>> faceStyles() async {
  final manifest = await AssetManifest.loadFromAssetBundle(rootBundle);
  return [
    for (final a in manifest.listAssets())
      if (a.startsWith('assets/faces/') && a.endsWith('.riv'))
        a.substring('assets/faces/'.length, a.length - '.riv'.length),
  ]..sort();
}

/// Chooses a face: a grid of every style, animated. Returns '' for "its own
/// face" (its slug's style or the default), null if cancelled.
Future<String?> pickFace(BuildContext context, String? current) async {
  final styles = await faceStyles();
  if (!context.mounted) return null;
  return showDialog<String>(
    context: context,
    builder: (c) => AlertDialog(
      title: const Text('Choose a face'),
      content: SizedBox(
        width: 560,
        height: 440,
        child: GridView.extent(
          maxCrossAxisExtent: 96,
          mainAxisSpacing: 8,
          crossAxisSpacing: 8,
          children: [
            for (final style in ['', ...styles])
              InkWell(
                borderRadius: BorderRadius.circular(12),
                onTap: () => Navigator.pop(c, style),
                child: Container(
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(
                      color: (current ?? '') == style
                          ? Theme.of(c).colorScheme.primary
                          : Colors.transparent,
                      width: 2,
                    ),
                  ),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      style.isEmpty
                          ? const SizedBox(
                              height: 52,
                              child: Icon(Icons.auto_awesome, size: 32),
                            )
                          : BotAvatar(
                              key: ValueKey(style),
                              slug: style,
                              mood: 0,
                              size: 52,
                            ),
                      Text(
                        style.isEmpty ? 'its own' : style,
                        style: Theme.of(c).textTheme.labelSmall,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(c),
          child: const Text('Cancel'),
        ),
      ],
    ),
  );
}
