import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

/// Scrapt die Laola1-TV-Live-Uebersicht und liefert dynamisch alle
/// Beach-Volleyball-Turniere die gerade live uebertragen werden.
///
/// Datenquelle: https://www.laola1.at/de/tvthek/livestreams/
/// Server-rendered HTML, jeder Live-Eintrag ist ein Link der Form
///   /de/video/player/<ID>/<slug>/
/// Beispiel:
///   /de/video/player/2173012/win2day-pro-masters-innsbruck---center-court/
///
/// Aus dem Slug parsen wir Tournament-Location + Court-Name.
class LaolaLivestreamScraper {
  static const String _url = 'https://www.laola1.at/de/tvthek/livestreams/';

  /// Trifft auf URLs wie:
  ///   /de/video/player/2173012/win2day-pro-masters-innsbruck---center-court/
  /// Gruppe 1 = numerische Player-ID, Gruppe 2 = Slug bis zum naechsten '/'.
  static final RegExp _playerRe =
      RegExp(r'/de/video/player/(\d+)/([a-z0-9][a-z0-9\-]*)/');

  /// Trennt im Slug: location-bezeichner -- (oder ---) court-bezeichner.
  /// Beispiele die matchen:
  ///   pro-masters-innsbruck---center-court
  ///   win2day-pro-masters-poertschach---medaillen-entscheidung
  ///   win2day-pro-masters-neusiedl--medaillen-entscheidung
  static final RegExp _slugRe = RegExp(
      r'^(?:win2day-)?pro-masters-([a-z0-9]+(?:-[a-z0-9]+)*?)-{2,3}(.+?)-?$');

  /// Liefert eine Liste von Tournament-Maps in dem gleichen Format wie die
  /// hardcoded `_laolaTournamentData`-Tabelle in home_screen.dart, sodass
  /// die Treffer direkt in den bestehenden Render-Pfad eingefuegt werden
  /// koennen.
  ///
  /// Returns leere Liste bei Netzfehler / parse-Fehler — KEIN throw, der
  /// Scraper ist Best-Effort und darf den Caller nie kaputtmachen.
  static Future<List<Map<String, Object>>> findBeachTournaments() async {
    try {
      final res = await http.get(
        Uri.parse(_url),
        headers: const {
          'User-Agent': 'Mozilla/5.0',
          'Accept': 'text/html,application/xhtml+xml',
        },
      ).timeout(const Duration(seconds: 6));
      if (res.statusCode != 200) {
        debugPrint('[laola-scrape] HTTP ${res.statusCode}');
        return const [];
      }
      return _parse(res.body);
    } catch (e) {
      debugPrint('[laola-scrape] error: $e');
      return const [];
    }
  }

  /// Public fuer Unit-Tests / lokales Debugging: parsed direkt aus einem
  /// HTML-String. Kein Netz, kein I/O.
  static List<Map<String, Object>> _parse(String html) {
    // location -> list of {id, courtSlug}
    final byLocation = <String, List<Map<String, String>>>{};
    final seenIds = <String>{};

    for (final m in _playerRe.allMatches(html)) {
      final id = m.group(1)!;
      final slug = m.group(2)!;
      if (seenIds.contains(id)) continue;
      // Nur Beach-Turniere: Slug muss `pro-masters-<location>` enthalten.
      // (Andere Sportarten wie Kickboxen oder LAOLA1 TV erfuellen das nicht.)
      final s = _slugRe.firstMatch(slug);
      if (s == null) continue;
      seenIds.add(id);
      final location = s.group(1)!;
      final courtSlug = s.group(2)!;
      byLocation.putIfAbsent(location, () => []).add({
        'id': id,
        'courtSlug': courtSlug,
      });
    }

    final result = <Map<String, Object>>[];
    final yearStr = DateTime.now().year.toString();
    final today =
        '$yearStr-${_pad(DateTime.now().month)}-${_pad(DateTime.now().day)}';

    for (final entry in byLocation.entries) {
      final location = entry.key;
      final courts = entry.value;
      final locationDisplay = _prettify(location);
      result.add({
        'id': '__laola_scraped_${location}_$yearStr',
        'title': 'Pro Masters $locationDisplay $yearStr',
        'matchDate': today,
        'tournament': 'win2day PRO MASTERS $locationDisplay',
        'videos': courts
            .map((c) => <String, String>{
                  'id': c['id']!,
                  'title': _prettify(c['courtSlug']!),
                  'url':
                      'https://www.laola1.at/de/video/player/${c['id']}/${'win2day-pro-masters-$location---${c['courtSlug']}'}',
                  'thumbnail': '',
                })
            .toList(),
      });
    }

    return result;
  }

  /// "center-court" -> "Center Court"
  /// "court-2" -> "Court 2"
  /// "medaillen-entscheidung" -> "Medaillen-Entscheidung"
  static String _prettify(String slug) {
    return slug
        .split('-')
        .map((w) => w.isEmpty
            ? w
            : '${w[0].toUpperCase()}${w.substring(1).toLowerCase()}')
        .join(' ')
        // Court-Nummern bleiben numerisch (nicht "Court 2" -> "Court 2", schon ok),
        // aber wir vermeiden " 2" am Ende zu zerschneiden — nichts zu tun.
        ;
  }

  static String _pad(int n) => n.toString().padLeft(2, '0');
}
