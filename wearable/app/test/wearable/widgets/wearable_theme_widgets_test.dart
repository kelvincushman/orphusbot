// Copyright (c) 2025-2026 Kelvin Lee. Licensed under MIT.
//
// Guards the three Eloquent contracts that are easy to lose silently:
//   1. WearableGround actually paints the pastel wash.
//   2. A selected chip is a solid black pill with a white label.
//   3. The bottom bar's active destination is a black pill with a white icon
//      (it was black-on-near-black — i.e. invisible — before this pass).

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kelvinlee/wearable/wearable_theme.dart';
import 'package:kelvinlee/wearable/wearable_tokens.dart';
import 'package:kelvinlee/wearable/widgets/wearable_bottom_bar.dart';
import 'package:kelvinlee/wearable/widgets/wearable_ground.dart';

Widget _app(Widget child) => MaterialApp(
      theme: WearableTheme.light(),
      home: Scaffold(body: child),
    );

void main() {
  group('WearableGround', () {
    testWidgets('paints gradient-ground behind its child', (tester) async {
      await tester.pumpWidget(_app(const WearableGround(child: SizedBox.expand())));

      final box = tester.widget<DecoratedBox>(
        find.descendant(
          of: find.byType(WearableGround),
          matching: find.byType(DecoratedBox),
        ),
      );
      final gradient = (box.decoration as BoxDecoration).gradient as LinearGradient;

      expect(gradient.colors, WearableTokens.gradientGround.colors);
      expect(gradient.stops, WearableTokens.gradientGround.stops);
      expect(gradient.begin, Alignment.topLeft);
      expect(gradient.end, Alignment.bottomRight);
    });
  });

  group('ChipThemeData', () {
    ShapeDecoration fillOf(WidgetTester tester, String label) {
      final ink = tester.widget<Ink>(
        find.ancestor(of: find.text(label), matching: find.byType(Ink)),
      );
      return ink.decoration! as ShapeDecoration;
    }

    Color? labelColorOf(WidgetTester tester, String label) =>
        tester.renderObject<RenderParagraph>(find.text(label)).text.style?.color;

    testWidgets('selected chip is a black pill with a white label and no border',
        (tester) async {
      await tester.pumpWidget(_app(
        ChoiceChip(label: const Text('Polish'), selected: true, onSelected: (_) {}),
      ));

      final fill = fillOf(tester, 'Polish');
      expect(fill.color, WearableColors.primary);
      expect((fill.shape as RoundedRectangleBorder).side, BorderSide.none);
      expect(labelColorOf(tester, 'Polish'), WearableColors.onPrimary);
    });

    testWidgets('unselected chip is white with a hairline border and a black label',
        (tester) async {
      await tester.pumpWidget(_app(
        ChoiceChip(label: const Text('Formal'), selected: false, onSelected: (_) {}),
      ));

      final fill = fillOf(tester, 'Formal');
      expect(fill.color, WearableColors.card);
      expect((fill.shape as RoundedRectangleBorder).side.color, WearableColors.border);
      expect(labelColorOf(tester, 'Formal'), WearableColors.foreground);
    });
  });

  group('WearableBottomBar', () {
    testWidgets('active destination is a black pill with a white icon', (tester) async {
      await tester.pumpWidget(_app(
        WearableBottomBar(currentIndex: 0, onSelect: (_) {}, onChat: () {}),
      ));

      ShapeDecoration pillFor(IconData icon) => tester
          .widget<Container>(
            find.ancestor(of: find.byIcon(icon), matching: find.byType(Container)).first,
          )
          .decoration! as ShapeDecoration;

      expect(pillFor(Icons.subtitles_outlined).color, WearableColors.primary);
      expect(pillFor(Icons.checklist_outlined).color, Colors.transparent);

      expect(
        tester.widget<Icon>(find.byIcon(Icons.subtitles_outlined)).color,
        WearableColors.onPrimary,
      );
      expect(
        tester.widget<Icon>(find.byIcon(Icons.checklist_outlined)).color,
        WearableColors.mutedFg,
      );
    });
  });
}
