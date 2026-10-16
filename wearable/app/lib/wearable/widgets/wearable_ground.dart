// Copyright (c) 2025-2026 Kelvin Lee. Licensed under MIT.
//
// WearableGround — the one widget that paints `gradient-ground`, the pastel
// coral → lilac → mint → sky wash that is the single most recognisable thing
// about the Eloquent look. It is a faint field behind white cards, never a
// loud gradient and never inside a card.
//
// Usage — wrap whatever owns the ground:
//
//   Drawer(child: WearableGround(child: ...))
//   MaterialApp(builder: (_, child) => WearableGround(child: child!))
//
// ponytail: the app-wide ground is not painted here yet, and this widget on
// its own cannot get it there. Every page Scaffold hardcodes
// `backgroundColor: WearableColors.background` (~20 call sites in pages/, none
// of them this lane's), so an opaque flat ground is painted on top of anything
// behind it. Wiring the wash app-wide is: wrap MaterialApp's builder in this
// widget, set `scaffoldBackgroundColor: Colors.transparent` in the theme, and
// delete those per-page `backgroundColor:` lines. All three or none — the
// transparent scaffold with nothing painted behind it renders black.

import 'package:flutter/material.dart';

import '../wearable_tokens.dart';

/// Paints [WearableTokens.gradientGround] behind [child].
class WearableGround extends StatelessWidget {
  const WearableGround({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(gradient: WearableTokens.gradientGround),
      child: child,
    );
  }
}
