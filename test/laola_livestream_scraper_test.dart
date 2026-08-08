import 'package:flutter_test/flutter_test.dart';
import 'package:vbtv_app/services/laola_livestream_scraper.dart';

/// Baut ein Stueck laola1-aehnliches HTML aus Player-Links.
///
/// Die Klasse am Anker ist NICHT schmueckendes Beiwerk: nur damit gilt ein
/// Link als Livestream. Die Seite fuehrt daneben ein Archiv mit demselben
/// Link-Format, aber der Klasse `video-slider-card__link`.
String html(List<String> hrefs) => hrefs
    .map((h) => '<a class="livestream-card__link" href="$h">Link</a>')
    .join('\n');

/// Archiv-Eintrag — gleiches Link-Format, andere Klasse.
String archivHtml(List<String> hrefs) => hrefs
    .map((h) => '<a class="video-slider-card__link" href="$h">Link</a>')
    .join('\n');

String player(String id, String slug) => '/de/video/player/$id/$slug/';

void main() {
  group('Slug-Parser', () {
    test('erkennt alle Slug-Formate die laola1 ueber die Jahre hatte', () {
      final r = LaolaLivestreamScraper.parseHtml(html([
        player('1', 'pro-masters-innsbruck---center-court'), // 2024
        player('2', 'win2day-pro-masters-poertschach---court-2'), // 2025
        player('3', 'win2day-pro-masters-neusiedl--court-3'), // 2025, 2 Bindestriche
        player('4', 'win2day-beach-tour-pro-masters-wien---center-court'), // 2026
      ]));
      final titles = r.map((t) => t['title'] as String).toList();
      expect(titles, hasLength(4));
      expect(titles, contains(startsWith('Pro Masters Innsbruck')));
      expect(titles, contains(startsWith('Pro Masters Poertschach')));
      expect(titles, contains(startsWith('Pro Masters Neusiedl')));
      expect(titles, contains(startsWith('Pro Masters Wien')));
    });

    /// Regression: der Regex war hart auf "pro-masters-" verdrahtet. Die
    /// win2day Beach Tour faehrt mehrere Serien parallel, wodurch die
    /// komplette PRO-OPEN-Schiene (Tulln) unsichtbar war.
    test('erkennt PRO OPEN, nicht nur PRO MASTERS', () {
      final r = LaolaLivestreamScraper.parseHtml(html([
        player('2198933', 'win2day-beach-tour-pro-open-tulln--center-court'),
        player('2198935', 'win2day-beach-tour-pro-open-tulln--court-2'),
      ]));
      expect(r, hasLength(1));
      expect(r.first['title'], startsWith('Pro Open Tulln'));
      expect(r.first['tournament'], 'win2day PRO OPEN Tulln');
      expect((r.first['videos'] as List), hasLength(2));
    });

    test('trennt gleiche Location in verschiedenen Serien', () {
      final r = LaolaLivestreamScraper.parseHtml(html([
        player('10', 'win2day-beach-tour-pro-masters-wien---center-court'),
        player('11', 'win2day-beach-tour-pro-open-wien--center-court'),
      ]));
      expect(r, hasLength(2), reason: 'Masters und Open in Wien sind zwei Turniere');
    });

    test('ignoriert andere Sportarten', () {
      final r = LaolaLivestreamScraper.parseHtml(html([
        player('100', 'laola1-tv'),
        player('101', 'vendetta-fight-night-54'),
        player('102', 'fc-red-bull-salzburg---spg-suedburgenland---tsv-hartberg'),
        player('103', 'skn-st--poelten---young-violets-austria-wien'),
        player('104', 'ulsan-hyundai-fc---gimcheon-sangmu-fc'),
      ]));
      expect(r, isEmpty);
    });

    /// laola1 vergibt pro Court mehrere Player-IDs im Tagesverlauf. Der
    /// Scraper darf NICHT auf eine reduzieren — welche davon live ist,
    /// entscheidet erst der Verfuegbarkeits-Check im Caller.
    test('behaelt alle Kandidaten-IDs pro Court', () {
      final r = LaolaLivestreamScraper.parseHtml(html([
        player('200', 'win2day-beach-tour-pro-open-tulln--center-court'),
        player('201', 'win2day-beach-tour-pro-open-tulln--center-court'),
        player('202', 'win2day-beach-tour-pro-open-tulln--center-court'),
      ]));
      expect(r, hasLength(1));
      expect((r.first['videos'] as List), hasLength(3));
    });

    test('dedupliziert identische Player-IDs', () {
      final r = LaolaLivestreamScraper.parseHtml(html([
        player('300', 'win2day-beach-tour-pro-open-tulln--center-court'),
        player('300', 'win2day-beach-tour-pro-open-tulln--center-court'),
      ]));
      expect((r.first['videos'] as List), hasLength(1));
    });

    /// Der Praefix variiert; die Player-URL braucht den ECHTEN Slug, sonst
    /// laeuft laola1 in einen 404.
    test('behaelt den Original-Slug in der URL', () {
      final r = LaolaLivestreamScraper.parseHtml(
          html([player('400', 'win2day-beach-tour-pro-open-tulln--court-3')]));
      final video = (r.first['videos'] as List).first as Map<String, String>;
      expect(video['url'],
          'https://www.laola1.at/de/video/player/400/win2day-beach-tour-pro-open-tulln--court-3');
    });

    test('macht aus Court-Slugs lesbare Titel', () {
      final r = LaolaLivestreamScraper.parseHtml(html([
        player('500', 'win2day-beach-tour-pro-open-tulln--medaillen-entscheidung'),
      ]));
      final video = (r.first['videos'] as List).first as Map<String, String>;
      expect(video['title'], 'Medaillen Entscheidung');
    });

    /// Regression 08.08.2026: die Livestream-Seite fuehrt UNTER den
    /// Livestreams noch ein Archiv mit demselben Link-Format. Ohne
    /// Unterscheidung stand die Medaillen-Entscheidung von Tulln (Turnier
    /// laengst vorbei, Laufzeit 4:13:46) als Livestream-Kachel mit dem
    /// heutigen Datum in der Uebersicht.
    test('ignoriert Archiv-Aufzeichnungen auf derselben Seite', () {
      final r = LaolaLivestreamScraper.parseHtml(archivHtml([
        player('2198938', 'win2day-beach-tour-pro-open-tulln--medaillen-entscheidung'),
      ]));
      expect(r, isEmpty);
    });

    test('nimmt nur den Livestream, nicht die Aufzeichnung daneben', () {
      final gemischt = html([
            player('2208841', 'win2day-beach-tour-pro-masters-wolfurt---center-court'),
          ]) +
          archivHtml([
            player('2198938', 'win2day-beach-tour-pro-open-tulln--medaillen-entscheidung'),
          ]);
      final r = LaolaLivestreamScraper.parseHtml(gemischt);
      expect(r, hasLength(1));
      expect(r.first['tournament'], 'win2day PRO MASTERS Wolfurt');
    });

    /// Bewusst KEIN Rueckfall auf "alle Player-Links": an einem Tag ohne
    /// Uebertragung gibt es keine Livestream-Anker, und der Rueckfall wuerde
    /// dann das Archiv einlesen.
    test('liefert nichts, wenn kein Link als Livestream ausgezeichnet ist', () {
      final r = LaolaLivestreamScraper.parseHtml(
        '<a href="/de/video/player/600/win2day-beach-tour-pro-masters-wolfurt---court-2/">x</a>',
      );
      expect(r, isEmpty);
    });

    test('kommt mit leerem HTML klar', () {
      expect(LaolaLivestreamScraper.parseHtml(''), isEmpty);
      expect(LaolaLivestreamScraper.parseHtml('<html><body></body></html>'), isEmpty);
    });
  });
}
