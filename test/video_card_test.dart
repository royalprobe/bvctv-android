import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vbtv_app/l10n/strings.dart';
import 'package:vbtv_app/models/video_item.dart';
import 'package:vbtv_app/widgets/tv_widgets.dart';

const _teamA = 'Ahman/Hellvig (SWE)';
const _teamB = 'Perusic/Sedlak (CZE)';

VideoItem _final() => const VideoItem(
      id: 'x',
      title: 't',
      teams: '$_teamA vs $_teamB',
      gender: 'Men',
      round: 'Final',
      tournament: 'Ostrava I Elite I 2026',
      thumbnailUrl: '',
      duration: 0,
    );

Widget _wrap(Widget child) => MaterialApp(
      home: Scaffold(body: SizedBox(width: 300, height: 160, child: child)),
    );

void main() {
  testWidgets('Spoiler-Karte verbirgt die Teamnamen', (tester) async {
    await tester.pumpWidget(_wrap(VideoCard(
      video: _final(),
      spoiler: true,
      onPressed: () {},
      genderBadge: const SizedBox.shrink(),
      statusBadge: const SizedBox.shrink(),
      dateStr: '31. Mai 2026',
    )));

    expect(find.textContaining(_teamA), findsNothing);
    expect(find.textContaining(_teamB), findsNothing);
    expect(find.text(S.spoilerActive), findsOneWidget);
  });

  testWidgets('ohne Spoiler-Schutz stehen die Teams da', (tester) async {
    await tester.pumpWidget(_wrap(VideoCard(
      video: _final(),
      spoiler: false,
      onPressed: () {},
      genderBadge: const SizedBox.shrink(),
      statusBadge: const SizedBox.shrink(),
      dateStr: '31. Mai 2026',
    )));

    expect(find.text(S.spoilerActive), findsNothing);
    expect(find.textContaining(_teamA), findsOneWidget);
  });

  /// Der Hinweis soll nur auf der fokussierten Karte stehen — sonst waere die
  /// Kachelwand noch voller Text.
  testWidgets('Aufdecken-Hinweis erscheint erst bei Fokus', (tester) async {
    await tester.pumpWidget(_wrap(VideoCard(
      video: _final(),
      spoiler: true,
      onPressed: () {},
      genderBadge: const SizedBox.shrink(),
      statusBadge: const SizedBox.shrink(),
      dateStr: '31. Mai 2026',
    )));

    expect(find.text(S.spoilerRevealHint), findsNothing,
        reason: 'unfokussiert bleibt die Karte ruhig');

    final ctx = tester.element(find.byType(VideoCard));
    FocusScope.of(ctx).requestFocus(Focus.of(
        tester.element(find.descendant(
            of: find.byType(VideoCard), matching: find.byType(GestureDetector)))));
    await tester.pumpAndSettle();

    expect(find.text(S.spoilerRevealHint), findsOneWidget,
        reason: 'fokussiert weist die Karte auf das Aufdecken hin');
    expect(find.text(S.spoilerActive), findsOneWidget,
        reason: 'der Hinweis ersetzt die Sperr-Zeile nicht');
  });

  testWidgets('langes Druecken deckt genau diese Karte auf', (tester) async {
    var opened = 0;
    await tester.pumpWidget(_wrap(VideoCard(
      video: _final(),
      spoiler: true,
      onPressed: () => opened++,
      genderBadge: const SizedBox.shrink(),
      statusBadge: const SizedBox.shrink(),
      dateStr: '31. Mai 2026',
    )));

    expect(find.textContaining(_teamA), findsNothing);

    await tester.longPress(find.byType(VideoCard));
    await tester.pumpAndSettle();

    expect(find.textContaining(_teamA), findsOneWidget);
    expect(find.text(S.spoilerActive), findsNothing);
    expect(opened, 0, reason: 'Aufdecken darf das Video nicht starten');
  });

  testWidgets('kurzer Tap oeffnet das Video statt aufzudecken', (tester) async {
    var opened = 0;
    await tester.pumpWidget(_wrap(VideoCard(
      video: _final(),
      spoiler: true,
      onPressed: () => opened++,
      genderBadge: const SizedBox.shrink(),
      statusBadge: const SizedBox.shrink(),
      dateStr: '31. Mai 2026',
    )));

    await tester.tap(find.byType(VideoCard));
    await tester.pumpAndSettle();

    expect(opened, 1);
    expect(find.text(S.spoilerActive), findsOneWidget);
  });
}
