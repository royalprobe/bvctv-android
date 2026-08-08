import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

/// Scrapt die Laola1-TV-Live-Uebersicht und liefert dynamisch alle
/// Beach-Volleyball-Turniere die gerade live uebertragen werden.
///
/// Datenquelle: https://www.laola1.at/de/tvthek/livestreams/
/// Server-rendered HTML, jeder Live-Eintrag ist ein Link der Form
///   `/de/video/player/<ID>/<slug>/`
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

  /// Klasse am Anker, die einen ECHTEN Livestream-Eintrag auszeichnet.
  ///
  /// Die Seite fuehrt zwei Bereiche mit demselben Link-Format:
  ///   <a class="livestream-card__link"   …>  laufend / angesetzt
  ///   <a class="video-slider-card__link" …>  Archiv-Aufzeichnung
  /// Ohne diese Unterscheidung landen alte Aufzeichnungen als vermeintliche
  /// Livestreams in der Uebersicht — beobachtet am 08.08.2026: die
  /// Medaillen-Entscheidung von Tulln (ID 2198938, Laufzeit 4:13:46) stand
  /// als Kachel mit dem heutigen Datum in der Liste, obwohl das Turnier
  /// laengst vorbei war. Der Verfuegbarkeits-Check half nicht: der prueft
  /// nur, ob sich etwas abspielen laesst, und eine Aufzeichnung laesst sich
  /// abspielen.
  static const String _livestreamKlasse = 'livestream-card__link';

  /// Trennt im Slug: serie, location-bezeichner -- (oder ---) court.
  /// Praefix vor `pro-<serie>-` ist bewusst NICHT verankert (kein `^`),
  /// weil laola1.at den Slug ueber die Jahre mehrfach umgebaut hat:
  ///   pro-masters-innsbruck---center-court               (2024)
  ///   win2day-pro-masters-poertschach---medaillen-...    (2025)
  ///   win2day-pro-masters-neusiedl--medaillen-...        (2025)
  ///   win2day-beach-tour-pro-masters-wien---center-court (2026)
  ///   win2day-beach-tour-pro-open-tulln--center-court    (2026)
  /// Mit `^` verankert wuerde das 2026er-Format NIE matchen ("beach-tour-"
  /// steht zwischen "win2day-" und "pro-masters-").
  ///
  /// Die Serie ist ebenfalls NICHT auf "masters" fixiert: die win2day Beach
  /// Tour faehrt mehrere Serien parallel (PRO MASTERS, PRO OPEN, PRO TOUR).
  /// Ein hartes "pro-masters-" hat die komplette PRO-OPEN-Schiene (z.B.
  /// Tulln) aus der Scraper-Ausbeute fallen lassen.
  /// Gruppe 1 = Serie, Gruppe 2 = Location, Gruppe 3 = Court.
  static final RegExp _slugRe = RegExp(
      r'(?:^|-)pro-(masters|open|tour)-([a-z0-9]+(?:-[a-z0-9]+)*?)-{2,3}(.+?)-?$');

  /// Liefert eine Liste von Tournament-Maps im Format, das der Render-Pfad in
  /// home_screen.dart erwartet (`_scrapedLaolaTournaments`). Das ist seit dem
  /// Wegfall der hartcodierten Turnier-Tabelle die einzige Laola-Quelle.
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
      // 12s statt 6: der Scrape startet seit v1.0.174 SOFORT beim App-Start
      // und teilt sich die Leitung mit 28 Titel-Abrufen und den Bridge-Feeds.
      // Auf dem Fire Stick lief er dadurch in seine Frist
      // ("TimeoutException after 0:00:06") und die Laola-Livestreams fehlten
      // bis zum naechsten periodischen Versuch.
      ).timeout(const Duration(seconds: 12));
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

  /// Parst direkt aus einem HTML-String — kein Netz, kein I/O. Genau der
  /// Pfad, den findBeachTournaments nach dem Download nimmt, deshalb der
  /// Ansatzpunkt fuer Unit-Tests.
  static List<Map<String, Object>> parseHtml(String html) => _parse(html);

  ///
  /// WICHTIG: dedupe NICHT auf eine ID pro (location, courtSlug) — laola1
  /// vergibt pro Court mehrere Player-IDs im Tagesverlauf (eine pro Match-
  /// Session), und die hoechste ID ist NICHT zuverlaessig die gerade live
  /// laufende (kann auch ein spaeteres, noch nicht gestartetes Match sein).
  /// Wir liefern ALLE Kandidaten-IDs pro Court zurueck; der Caller
  /// (home_screen.dart::_scrapeLaolaLivestreams) prueft alle Kandidaten
  /// gegen /access/hls und behaelt nur den tatsaechlich live-Kandidaten
  /// pro Court.
  static List<Map<String, Object>> _parse(String html) {
    final seenIds = <String>{};
    // "serie:location:court" -> alle Kandidaten-Videos fuer diesen Court
    final byKey = <String, List<Map<String, String>>>{};

    for (final m in _livestreamLinks(html)) {
      final id = m.group(1)!;
      final slug = m.group(2)!;
      if (seenIds.contains(id)) continue;
      // Nur Beach-Turniere: Slug muss `pro-<serie>-<location>` enthalten.
      // (Andere Sportarten wie Kickboxen oder LAOLA1 TV erfuellen das nicht.)
      final s = _slugRe.firstMatch(slug);
      if (s == null) continue;
      seenIds.add(id);
      final series = s.group(1)!;
      final location = s.group(2)!;
      final courtSlug = s.group(3)!;
      // Serie gehoert in den Key: PRO MASTERS und PRO OPEN koennen am selben
      // Ort stattfinden und sind trotzdem verschiedene Turniere.
      final key = '$series:$location:$courtSlug';
      // Original-Slug behalten (nicht neu zusammenbauen) — der Praefix
      // variiert ("win2day-", "win2day-beach-tour-", ...) und die
      // Player-URL braucht den ECHTEN Slug, sonst 404 bei laola1.at.
      byKey.putIfAbsent(key, () => []).add({
        'id': id,
        'title': _prettify(courtSlug),
        'url': 'https://www.laola1.at/de/video/player/$id/$slug',
        'thumbnail': '',
        'series': series,
        'location': location,
        // Court-Kennung mitgeben. Ohne sie kann der Aufrufer nach dem
        // Verfuegbarkeits-Check nicht mehr "einen pro Court" auswaehlen —
        // dann stehen fuer denselben Court mehrere Sessions in der Liste
        // (beobachtet in Wolfurt: 7 Eintraege statt 3).
        'court': courtSlug,
      });
    }

    // Ein Tournament-Eintrag pro (Serie, Location).
    final byTournament = <String, List<Map<String, String>>>{};
    for (final candidates in byKey.values) {
      final c = candidates.first;
      final tKey = '${c['series']}:${c['location']}';
      byTournament.putIfAbsent(tKey, () => []).addAll(candidates);
    }

    final result = <Map<String, Object>>[];
    final yearStr = DateTime.now().year.toString();
    final today =
        '$yearStr-${_pad(DateTime.now().month)}-${_pad(DateTime.now().day)}';

    for (final entry in byTournament.entries) {
      final series = entry.value.first['series']!;
      final location = entry.value.first['location']!;
      final locationDisplay = _prettify(location);
      final seriesDisplay = _prettify(series);
      result.add({
        'id': '__laola_scraped_${series}_${location}_$yearStr',
        'title': 'Pro $seriesDisplay $locationDisplay $yearStr',
        'matchDate': today,
        'tournament':
            'win2day PRO ${series.toUpperCase()} $locationDisplay',
        // Mehrere Kandidaten pro Court moeglich — Caller reduziert per
        // Live-Check auf einen Treffer pro Court (siehe Doc oben).
        'videos': entry.value
            .map((c) => <String, String>{
                  'id': c['id']!,
                  'title': c['title']!,
                  'url': c['url']!,
                  'thumbnail': c['thumbnail']!,
                  'court': c['court']!,
                })
            .toList(),
      });
    }

    return result;
  }

  /// Alle Player-Links, die an einem Livestream-Anker haengen.
  ///
  /// Zerlegt bewusst am Anker statt mit einem grossen Regex ueber das ganze
  /// Dokument: die Reihenfolge von class und href ist nicht garantiert, ein
  /// Regex mit fester Reihenfolge waere stillschweigend kaputt, sobald
  /// laola1 die Attribute tauscht.
  ///
  /// KEIN Rueckfall auf "alle Player-Links", falls sich keiner findet. Das
  /// war der erste Entwurf, ist aber falsch: an einem Tag ohne laufende
  /// Uebertragung gibt es schlicht keine Livestream-Anker, und der Rueckfall
  /// wuerde dann ausgerechnet das Archiv einlesen — also genau der Fehler,
  /// den diese Methode verhindern soll. Eine leere Liste ist der Normalfall
  /// an den meisten Tagen; eine falsche Kachel mit dem heutigen Datum ist es
  /// nicht.
  static Iterable<RegExpMatch> _livestreamLinks(String html) {
    final treffer = <RegExpMatch>[];
    var playerLinks = 0;
    for (final teil in html.split('<a ')) {
      final tagEnde = teil.indexOf('>');
      if (tagEnde < 0) continue;
      final tag = teil.substring(0, tagEnde);
      final m = _playerRe.firstMatch(tag);
      if (m == null) continue;
      playerLinks++;
      if (tag.contains(_livestreamKlasse)) treffer.add(m);
    }
    // Nur auffaellig, wenn es ueberhaupt Player-Links gibt: dann koennte
    // laola1 die Klasse umbenannt haben, und wir waeren blind.
    if (treffer.isEmpty && playerLinks > 0) {
      debugPrint('[laola-scrape] $playerLinks Player-Links, aber keiner mit '
          '"$_livestreamKlasse" — Auszeichnung geaendert?');
    }
    return treffer;
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
