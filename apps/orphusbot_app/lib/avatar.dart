// A bot's animated face, drawn by Rive from design/bot-avatar: each house bot
// has its own style (assets/faces/<slug>.riv), others get default.riv. Each
// face has its own state machine whose `state` input follows the bot
// (ThreadView.mood).
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
  });
  final String slug;
  final int mood;
  final double size;

  @override
  State<BotAvatar> createState() => _BotAvatarState();
}

class _BotAvatarState extends State<BotAvatar> {
  rive.RiveWidgetController? controller;
  rive.NumberInput? state;

  @override
  void initState() {
    super.initState();
    faceFile(widget.slug).then((f) {
      if (f == null || !mounted) return;
      setState(() {
        controller = rive.RiveWidgetController(f);
        // ignore: deprecated_member_use
        state = controller!.stateMachine.number('state');
        state?.value = widget.mood.toDouble();
      });
    });
  }

  @override
  void didUpdateWidget(BotAvatar old) {
    super.didUpdateWidget(old);
    state?.value = widget.mood.toDouble();
  }

  @override
  void dispose() {
    state?.dispose();
    controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => SizedBox.square(
    dimension: widget.size,
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
