import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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

  /// Regression: langes Druecken war eine Einbahnstrasse — einmal aufgedeckt
  /// liess sich der Schutz fuer diese Karte nicht wieder aktivieren.
  testWidgets('nochmal lange druecken verbirgt wieder', (tester) async {
    await tester.pumpWidget(_wrap(VideoCard(
      video: _final(),
      spoiler: true,
      onPressed: () {},
      genderBadge: const SizedBox.shrink(),
      statusBadge: const SizedBox.shrink(),
      dateStr: '31. Mai 2026',
    )));

    await tester.longPress(find.byType(VideoCard));
    await tester.pumpAndSettle();
    expect(find.textContaining(_teamA), findsOneWidget);

    await tester.longPress(find.byType(VideoCard));
    await tester.pumpAndSettle();
    expect(find.textContaining(_teamA), findsNothing);
    expect(find.text(S.spoilerActive), findsOneWidget);
  });

  /// Regression: GridView.builder recycelt den State nach Position. Ohne Key
  /// hat das Aufdecken eines Finales die Finale ALLER Turniere mit aufgedeckt,
  /// weil sie auf demselben Grid-Platz landen.
  testWidgets('Aufdecken wirkt nur auf das eigene Video', (tester) async {
    VideoItem other() => const VideoItem(
          id: 'y',
          title: 't2',
          teams: 'Mol/Sorum (NOR) vs Cherif/Ahmed (QAT)',
          gender: 'Men',
          round: 'Final',
          tournament: 'Gstaad I Elite I 2026',
          thumbnailUrl: '',
          duration: 0,
        );

    Widget grid(List<VideoItem> items) => MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 320,
              height: 400,
              child: ListView(
                children: [
                  for (final v in items)
                    // Der Key gehoert an das DIREKTE Listenkind — dort
                    // entscheidet Flutter, welcher State zu welchem Eintrag
                    // gehoert. In der App ist das die VideoCard selbst.
                    SizedBox(
                      key: ValueKey(v.id),
                      height: 160,
                      child: VideoCard(
                        video: v,
                        spoiler: true,
                        onPressed: () {},
                        genderBadge: const SizedBox.shrink(),
                        statusBadge: const SizedBox.shrink(),
                        dateStr: '31. Mai 2026',
                      ),
                    ),
                ],
              ),
            ),
          ),
        );

    await tester.pumpWidget(grid([_final(), other()]));
    expect(find.text(S.spoilerActive), findsNWidgets(2));

    // Erste Karte aufdecken
    await tester.longPress(find.byType(VideoCard).first);
    await tester.pumpAndSettle();
    expect(find.textContaining(_teamA), findsOneWidget);
    expect(find.text(S.spoilerActive), findsOneWidget,
        reason: 'die zweite Karte bleibt verdeckt');

    // Liste neu aufbauen — nur das erste Video wird ersetzt. Der Key sorgt
    // dafuer, dass der Aufdeck-Zustand nicht auf den neuen Eintrag rutscht.
    await tester.pumpWidget(grid([other(), _final()]));
    await tester.pumpAndSettle();
    expect(find.textContaining(_teamA), findsOneWidget,
        reason: 'der aufgedeckte Eintrag bleibt derselbe, egal an welcher Position');
    expect(find.text(S.spoilerActive), findsOneWidget);
  });

  /// Regression: Der Beenden-Dialog loest beim KeyDown aus und schliesst sich
  /// sofort. Das KeyUp desselben Tastendrucks landete danach auf der
  /// Videokachel darunter — und weil Spoiler-Karten wegen des Long-Press erst
  /// beim Loslassen ausloesen, hat der Bestaetigungsklick das Video geoeffnet.
  testWidgets('Bestaetigungsklick oeffnet nicht die Karte darunter',
      (tester) async {
    var opened = 0;
    var dialogOpen = true;

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: StatefulBuilder(
          builder: (ctx, setState) => Column(children: [
            // Steht fuer den Beenden-Dialog: loest beim KeyDown aus und ist
            // danach weg.
            if (dialogOpen)
              TvFocusButton(
                autofocus: true,
                onPressed: () => setState(() => dialogOpen = false),
                child: const Text('Beenden'),
              ),
            SizedBox(
              width: 300,
              height: 160,
              child: VideoCard(
                video: _final(),
                spoiler: true,
                onPressed: () => opened++,
                genderBadge: const SizedBox.shrink(),
                statusBadge: const SizedBox.shrink(),
                dateStr: '31. Mai 2026',
              ),
            ),
          ]),
        ),
      ),
    ));
    await tester.pumpAndSettle();

    // Taste druecken — der Dialog-Button verarbeitet das KeyDown und schliesst.
    await tester.sendKeyDownEvent(LogicalKeyboardKey.select);
    await tester.pumpAndSettle();
    expect(find.text('Beenden'), findsNothing);

    // Fokus faellt auf die Karte, DANN kommt das Loslassen an.
    Focus.of(tester.element(find.descendant(
            of: find.byType(VideoCard), matching: find.byType(GestureDetector))))
        .requestFocus();
    await tester.pumpAndSettle();
    await tester.sendKeyUpEvent(LogicalKeyboardKey.select);
    await tester.pumpAndSettle();

    expect(opened, 0,
        reason: 'das KeyUp gehoert zum Dialog-Druck, nicht zur Karte');

    // Ein vollstaendiger eigener Druck funktioniert weiterhin.
    await tester.sendKeyDownEvent(LogicalKeyboardKey.select);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.select);
    await tester.pumpAndSettle();
    expect(opened, 1);
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
