// A bot's animated face, drawn by Rive from design/bot-avatar: each house bot
// has its own style (assets/faces/<slug>.riv), others get default.riv. Each
// face has its own state machine whose `state` input follows the bot
// (ThreadView.mood).
import 'package:flutter/material.dart';
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
