// The opening animation (design/app-logo, built with the Rive CLI): the logo's
// head pops in, its eyes blink on, the coil springs up and the antenna light
// pulses, about 1.6 s, then the app carries on (DESIGN §12.4).
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:rive/rive.dart' as rive;

/// How long the intro shows before the app takes over.
const introLength = Duration(milliseconds: 1900);

class Intro extends StatefulWidget {
  const Intro({super.key});

  @override
  State<Intro> createState() => _IntroState();
}

class _IntroState extends State<Intro> {
  rive.RiveWidgetController? controller;

  @override
  void initState() {
    super.initState();
    rive.File.asset(
      'assets/brand/intro.riv',
      riveFactory: rive.Factory.flutter,
    ).then((f) {
      if (f == null || !mounted) return;
      setState(
        () => controller = rive.RiveWidgetController(
          f,
          artboardSelector: rive.ArtboardSelector.byName('Intro'),
        ),
      );
    }, onError: (_) {});
  }

  @override
  Widget build(BuildContext context) => AnnotatedRegion<SystemUiOverlayStyle>(
    // Black bars too, so the launch screen, intro and phone chrome are one.
    value: SystemUiOverlayStyle.light.copyWith(
      statusBarColor: Colors.black,
      systemNavigationBarColor: Colors.black,
    ),
    child: ColoredBox(
      // The mark is white with a cyan light, so it always plays on black.
      color: Colors.black,
      child: Center(
        child: SizedBox.square(
          dimension: 220,
          child: controller == null
              ? null
              : rive.RiveWidget(controller: controller!, fit: rive.Fit.contain),
        ),
      ),
    ),
  );
}
