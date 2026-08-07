// Master-Manifest umschreiben und lokal ausliefern.
//
// Warum das noetig ist: VBWs HLS-Manifest ist GETRENNT aufgebaut — die
// Videostufen enthalten kein Audio, der Ton liegt in einer eigenen Spur
// (#EXT-X-MEDIA:TYPE=AUDIO). Daraus folgen zwei Dinge, die sich sonst
// gegenseitig ausschliessen:
//
//   * Nagelt man wie bisher eine Videostufe fest, um immer die beste
//     Qualitaet zu bekommen, spielt man Bild OHNE Ton.
//   * Gibt man ExoPlayer den Master, stimmt der Ton — aber die
//     Qualitaetswahl uebernimmt dessen ABR und faengt unten an (beobachtet:
//     540p bzw. 720p beim Start, danach klettert es hoch).
//
// Der Ausweg ist ein Master, der nur noch die BESTE Videostufe und die
// Tonspur enthaelt. Dann hat ExoPlayer keine Wahl mehr: hoechste Qualitaet
// ab dem ersten Bild, Ton inklusive.
//
// Nebenbei erledigt die Umschreibung zwei weitere Fallstricke:
//   * Alle Adressen werden absolut gemacht. Im Live-Master stehen sie
//     RELATIV, und die Live-Adresse ist eine Weiterleitungskette — relativ
//     gegen die erste Adresse aufgeloest ergibt das 404.
//   * Der in den Videostufen faelschlich mitdeklarierte Audio-Codec
//     ("mp4a.40.2,avc1…", obwohl die Stufe auf die separate Tonspur
//     verweist) wird entfernt. Sonst haelt ExoPlayer die Stufe fuer
//     vollstaendig und holt die Tonspur nicht.
//
// Ausgeliefert wird ueber einen winzigen HTTP-Server auf 127.0.0.1. Nur
// diese eine ~3 KB grosse Datei laeuft darueber; Videostufen und Segmente
// holt der Player direkt beim CDN.

import 'dart:io';

import 'package:flutter/foundation.dart';

class VbwManifestProxy {
  static HttpServer? _server;
  static final Map<String, String> _manifeste = {};
  static int _zaehler = 0;

  /// Liefert eine lokale Adresse, hinter der ein umgeschriebener Master
  /// liegt — oder null, wenn das nicht noetig oder nicht moeglich ist.
  ///
  /// null heisst ausdruecklich "nimm die Original-Adresse": bei gemuxten
  /// Streams (Laola, GBT) gibt es nichts zu reparieren.
  /// [besteFestnageln] bestimmt, ob nur die hoechste Videostufe uebrig
  /// bleibt (dann immer beste Qualitaet ab dem ersten Bild) oder alle
  /// Stufen erhalten bleiben (dann regelt ExoPlayers ABR).
  ///
  /// Fuer Aufzeichnungen festnageln: der Puffer faengt Schwankungen ab.
  /// Fuer LIVESTREAMS nicht — die 1080p-Stufe liegt dort bei ueber 10 Mbit,
  /// und ein Livestream hat keinen Vorlauf, auf den er zurueckfallen kann.
  /// Ein stockendes Bild waere schlimmer als eine Stufe weniger.
  static Future<String?> vorbereiten(String masterUrl,
      {bool besteFestnageln = true}) async {
    try {
      final geholt = await _holen(masterUrl);
      if (geholt == null) return null;
      final (basis, roh) = geholt;

      // Kein getrennter Ton -> nichts zu tun.
      if (!roh.contains('EXT-X-MEDIA:TYPE=AUDIO')) return null;

      final neu = _umschreiben(roh, basis, besteFestnageln);
      if (neu == null) return null;

      final server = await _serverStarten();
      if (server == null) return null;

      final schluessel = '${++_zaehler}';
      _manifeste[schluessel] = neu;
      // Aeltere Eintraege verwerfen: pro Wiedergabe einer, mehr als eine
      // Handvoll braucht niemand.
      if (_manifeste.length > 5) {
        final alt = _manifeste.keys.first;
        _manifeste.remove(alt);
      }
      final url = 'http://127.0.0.1:${server.port}/$schluessel.m3u8';
      debugPrint('[manifest-proxy] bereit: $url');
      return url;
    } catch (e) {
      debugPrint('[manifest-proxy] fehlgeschlagen: $e — Original-Adresse');
      return null;
    }
  }

  /// Master holen und dabei Weiterleitungen folgen. Gibt die ENDGUELTIGE
  /// Adresse (Basis fuer relative Pfade) und den Inhalt zurueck.
  static Future<(Uri, String)?> _holen(String masterUrl) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 6);
    try {
      final req = await client.getUrl(Uri.parse(masterUrl));
      req.followRedirects = true;
      req.maxRedirects = 5;
      req.headers.set('User-Agent',
          'Mozilla/5.0 (Linux; Android 12) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Mobile Safari/537.36');
      final res = await req.close().timeout(const Duration(seconds: 8));
      if (res.statusCode != 200) {
        debugPrint('[manifest-proxy] Master HTTP ${res.statusCode}');
        return null;
      }
      // Endgueltige Adresse aus der Weiterleitungskette zusammensetzen.
      var basis = Uri.parse(masterUrl);
      for (final r in res.redirects) {
        basis = basis.resolveUri(r.location);
      }
      final text = await res.transform(const SystemEncoding().decoder).join();
      return (basis, text);
    } finally {
      client.close(force: true);
    }
  }

  /// Baut den neuen Master: Kopfzeilen + Tonspuren + Videostufen.
  ///
  /// Mit [besteFestnageln] bleibt nur die hoechste Stufe uebrig, sonst alle
  /// (dann in Originalreihenfolge, ExoPlayers ABR waehlt).
  static String? _umschreiben(String roh, Uri basis, bool besteFestnageln) {
    String abs(String u) => basis.resolve(u.trim()).toString();

    final zeilen = roh.split('\n');
    final kopf = <String>[];
    final audio = <String>[];
    // Alle Videostufen als (INF-Zeile, Adresse) — gebraucht wenn nicht
    // festgenagelt wird.
    final stufen = <(String, String)>[];
    String? besteInf;
    String? besteUrl;
    var besteHoehe = -1;
    var besteBandbreite = -1;

    for (var i = 0; i < zeilen.length; i++) {
      final z = zeilen[i].trim();
      if (z.isEmpty) continue;

      if (z.startsWith('#EXT-X-MEDIA:')) {
        // Nur Tonspuren uebernehmen — Untertitel/Closed-Captions
        // interessieren hier nicht und wuerden nur Fehlerquellen sein.
        if (!z.contains('TYPE=AUDIO')) continue;
        audio.add(z.replaceFirstMapped(
            RegExp(r'URI="([^"]+)"'), (m) => 'URI="${abs(m.group(1)!)}"'));
        continue;
      }

      if (z.startsWith('#EXT-X-STREAM-INF:')) {
        // Zugehoerige Adresse ist die naechste nicht-leere Zeile ohne '#'.
        var j = i + 1;
        while (j < zeilen.length && zeilen[j].trim().isEmpty) {
          j++;
        }
        if (j >= zeilen.length || zeilen[j].trim().startsWith('#')) continue;
        final url = zeilen[j].trim();
        i = j;

        // Reine Audio-Stufen ueberspringen (kein RESOLUTION, nur mp4a) —
        // die sind hier nicht die "beste Videostufe".
        final resm = RegExp(r'RESOLUTION=\d+x(\d+)').firstMatch(z);
        if (resm == null) continue;
        final hoehe = int.tryParse(resm.group(1)!) ?? 0;
        final bw = int.tryParse(
                RegExp(r'BANDWIDTH=(\d+)').firstMatch(z)?.group(1) ?? '0') ??
            0;

        // Audio-Codec aus CODECS werfen, wenn die Stufe auf eine
        // Tonspur-Gruppe verweist — sonst haelt ExoPlayer sie fuer
        // vollstaendig und holt den Ton nie. Gilt fuer JEDE Stufe, nicht
        // nur die beste: bei Live bleiben alle erhalten.
        final infZeile = z.contains('AUDIO="')
            ? z.replaceFirstMapped(RegExp(r'CODECS="([^"]*)"'), (m) {
                final rest = m
                    .group(1)!
                    .split(',')
                    .map((s) => s.trim())
                    .where((s) => !s.toLowerCase().startsWith('mp4a'))
                    .toList();
                return rest.isEmpty ? m.group(0)! : 'CODECS="${rest.join(",")}"';
              })
            : z;

        stufen.add((infZeile, abs(url)));
        if (hoehe > besteHoehe ||
            (hoehe == besteHoehe && bw > besteBandbreite)) {
          besteHoehe = hoehe;
          besteBandbreite = bw;
          besteUrl = abs(url);
          besteInf = infZeile;
        }
        continue;
      }

      // I-Frame-Stufen und Untertitel weglassen, Rest als Kopf uebernehmen.
      if (z.startsWith('#EXT-X-I-FRAME-STREAM-INF:')) continue;
      if (z.startsWith('#')) kopf.add(z);
    }

    if (besteInf == null || besteUrl == null || audio.isEmpty) {
      debugPrint('[manifest-proxy] nichts zum Umschreiben gefunden');
      return null;
    }

    final videoZeilen = besteFestnageln
        ? [besteInf, besteUrl]
        : [for (final (inf, url) in stufen) ...[inf, url]];
    debugPrint('[manifest-proxy] ${besteFestnageln ? "festgenagelt auf" : "beste verfuegbar"} '
        '${besteHoehe}p ($besteBandbreite bps), '
        '${besteFestnageln ? 1 : stufen.length} Stufe(n), '
        '${audio.length} Tonspur(en)');

    return [
      ...kopf.where((z) =>
          z.startsWith('#EXTM3U') ||
          z.startsWith('#EXT-X-VERSION') ||
          z.startsWith('#EXT-X-INDEPENDENT-SEGMENTS')),
      ...audio,
      ...videoZeilen,
      '',
    ].join('\n');
  }

  static Future<HttpServer?> _serverStarten() async {
    if (_server != null) return _server;
    try {
      final s = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      s.listen((req) async {
        final schluessel =
            req.uri.pathSegments.isEmpty ? '' : req.uri.pathSegments.last.replaceAll('.m3u8', '');
        final inhalt = _manifeste[schluessel];
        if (inhalt == null) {
          req.response.statusCode = HttpStatus.notFound;
          await req.response.close();
          return;
        }
        req.response.headers.contentType =
            ContentType('application', 'vnd.apple.mpegurl');
        req.response.write(inhalt);
        await req.response.close();
      });
      _server = s;
      debugPrint('[manifest-proxy] Server auf 127.0.0.1:${s.port}');
      return s;
    } catch (e) {
      debugPrint('[manifest-proxy] Server-Start fehlgeschlagen: $e');
      return null;
    }
  }
}
