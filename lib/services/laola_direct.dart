// Laola1-Stream-URL ohne WebView.
//
// laola1 hat einen Endpunkt, der die fertige signierte Stream-URL als JSON
// herausgibt:
//   POST https://video.laola1.at/api/v3/contents/<id>/access/hls
//     200 -> { "status":"success", "data": { "stream": "https://…m3u8" } }
//     400 -> { "status":"error", "code":210, "message":"Stream not available." }
//            (nicht live, abgelaufen oder nicht freigegeben)
//
// Kein Login, keine Cookies, kein Browser. Der Code kannte den Endpunkt
// bisher nur als Live-Pruefung (laola_livestream_scraper: 200 = laeuft) —
// dass im 200er-Body die komplette Stream-URL steht, ist beim Ausmessen der
// Geo-Sperre in der Web-Variante aufgefallen.
//
// Bisher lud die App dafuer laola1s Player-Seite in eine WebView und fischte
// die m3u8 per JS-Hook heraus (LaolaStreamExtractor). Das entfaellt damit —
// samt Seitenaufbau, Player-Init und Werbung.
//
// Geprueft am 07.08.2026 an einem laufenden Wolfurt-Court: das Live-Manifest
// ist GEMUXT (Bild und Ton in einer Spur) und enthaelt ABSOLUTE Pfade. Damit
// drohen hier weder das Tonproblem des VBW-Manifests (getrennte Tonspur, die
// ExoPlayer wegen eines falschen CODECS-Feldes nicht holt) noch der
// Relativpfad-Fehler der VBW-Live-Adresse.

import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

class LaolaDirect {
  static const _base = 'https://video.laola1.at/api/v3/contents';

  /// Content-ID aus einer laola1-Player-Adresse ziehen.
  /// Beispiel: https://www.laola1.at/de/video/player/2208838/win2day-… -> 2208838
  static String? idFromPageUrl(String? pageUrl) {
    if (pageUrl == null) return null;
    return RegExp(r'/player/(\d+)').firstMatch(pageUrl)?.group(1);
  }

  /// Signierte HLS-URL, oder null wenn dieser Weg nicht traegt. Wirft nie —
  /// der Aufrufer soll ohne Sonderbehandlung auf den WebView-Weg
  /// zurueckfallen koennen.
  static Future<String?> streamUrl(
    String contentId, {
    Duration timeout = const Duration(seconds: 8),
  }) async {
    try {
      final res = await http
          .post(Uri.parse('$_base/$contentId/access/hls'), headers: {
            'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) '
                'AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36',
            'Referer': 'https://www.laola1.at/',
            'Origin': 'https://www.laola1.at',
          })
          .timeout(timeout);

      final body = jsonDecode(utf8.decode(res.bodyBytes));
      if (res.statusCode != 200) {
        // 400 ist die regulaere Antwort fuer "gibt es gerade nicht" — bei
        // Livestreams heisst das meist: noch nicht gestartet.
        final meldung = body is Map ? body["message"] : "";
        debugPrint('[laola-direct] $contentId HTTP ${res.statusCode}: $meldung');
        return null;
      }
      String? stream;
      if (body is Map) {
        final data = body['data'];
        if (data is Map) stream = data['stream'] as String?;
      }
      if (stream == null || stream.isEmpty) {
        debugPrint('[laola-direct] $contentId ohne stream im Body');
        return null;
      }
      debugPrint('[laola-direct] $contentId -> URL da');
      return stream;
    } catch (e) {
      debugPrint('[laola-direct] $contentId fehlgeschlagen: $e');
      return null;
    }
  }
}
