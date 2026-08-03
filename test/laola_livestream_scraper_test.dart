import 'package:flutter_test/flutter_test.dart';
import 'package:vbtv_app/services/laola_livestream_scraper.dart';

/// Baut ein Stueck laola1-aehnliches HTML aus Player-Links.
String html(List<String> hrefs) =>
    hrefs.map((h) => '<a href="$h">Link</a>').join('\n');

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

    test('kommt mit leerem HTML klar', () {
      expect(LaolaLivestreamScraper.parseHtml(''), isEmpty);
      expect(LaolaLivestreamScraper.parseHtml('<html><body></body></html>'), isEmpty);
    });
  });
}
