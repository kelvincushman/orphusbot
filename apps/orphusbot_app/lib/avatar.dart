// A bot's animated face, drawn by Rive from design/bot-avatar: one file shared
// by every face, each face with its own state machine whose `state` input
// follows the bot (ThreadView.mood).
import 'package:flutter/material.dart';
import 'package:rive/rive.dart' as rive;

class BotAvatar extends StatefulWidget {
  const BotAvatar({super.key, required this.mood, this.size = 40});
  final int mood;
  final double size;

  @override
  State<BotAvatar> createState() => _BotAvatarState();
}

class _BotAvatarState extends State<BotAvatar> {
  static final _file = rive.File.asset(
    'assets/bot-avatar.riv',
    riveFactory: rive.Factory.flutter,
  );
  rive.RiveWidgetController? controller;
  rive.NumberInput? state;

  @override
  void initState() {
    super.initState();
    _file.then((f) {
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
