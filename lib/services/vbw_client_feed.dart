// Signierte VBW-Stream-URL ohne WebView.
//
// tv.volleyballworld.com/api/client-feed ist ein Proxy auf VBWs eigener
// Seite: er holt den zapp-Feed und reichert jeden Eintrag mit einer fertig
// signierten content.src an:
//   https://cdn.jwplayer.com/manifests/<id>.m3u8?exp=…&sig=…
// Signiert wird also SERVERSEITIG bei VBW. Die frühere Annahme, das
// passiere clientseitig im Player-Bundle und sei nur über einen echten
// Browser zu bekommen, war falsch.
//
// Was das bringt: bisher lädt die App für ein VBW-Video die komplette
// Player-Seite in einer WebView — Bundle, Player-Init, Werbung. Mit der
// signierten URL spielt stattdessen der native Player direkt los. In der
// Web-Variante gemessen: 456–708 ms statt 10–15 s.
//
// Der Endpunkt braucht die Sitzung. Welches Merkmal genau sie ausweist, ist
// nicht abschließend geklärt — deshalb wird beides mitgeschickt, was die App
// hat: die tv.volleyballworld.com-Cookies aus dem WebView-Cookie-Store und
// der Access-Token als Bearer. Genau diese Kombination ist in der
// Web-Variante erprobt.
//
// Fehlt `src` in der Antwort, heißt das nicht "Aufruf falsch", sondern
// "für diesen Account nicht freigeschaltet": beobachtet an einem Video, für
// das auch der WebView-Weg auf /premium-upgrade landet und nie ein Manifest
// findet. In diesem Fall gibt die Funktion null zurück und der Aufrufer
// nimmt weiter den WebView-Weg.

import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:http/http.dart' as http;

class VbwClientFeed {
  static const _origin = 'https://tv.volleyballworld.com';
  static const _zappBase = 'https://zapp-5434-volleyball-tv.web.app';
  static const _ua =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36';

  /// Signierte HLS-URL für ein VBW-Video, oder null wenn dieser Weg nicht
  /// trägt. Wirft nie — der Aufrufer soll ohne Sonderbehandlung auf den
  /// WebView-Weg zurückfallen können.
  static Future<String?> signedStreamUrl(
    String mediaId, {
    required String accessToken,
    Duration timeout = const Duration(seconds: 8),
  }) async {
    try {
      final feedUrl = '$_zappBase/jw/media/$mediaId?disablePlayNext=false';
      final url = Uri.parse(
        '$_origin/api/client-feed'
        '?feed-url=${Uri.encodeComponent(feedUrl)}&language=en',
      );

      final headers = <String, String>{
        'User-Agent': _ua,
        'Referer': '$_origin/',
        'Accept': 'application/json',
      };
      final cookie = await _tvCookieHeader();
      if (cookie.isNotEmpty) headers['Cookie'] = cookie;
      if (accessToken.isNotEmpty) {
        headers['Authorization'] = 'Bearer $accessToken';
      }

      final res = await http.get(url, headers: headers).timeout(timeout);
      if (res.statusCode != 200) {
        debugPrint('[client-feed] HTTP ${res.statusCode} für $mediaId');
        return null;
      }

      final body = jsonDecode(utf8.decode(res.bodyBytes));
      final entries = (body is Map ? body['entry'] : null) as List? ?? const [];
      Map<String, dynamic>? hit;
      for (final e in entries) {
        if (e is Map<String, dynamic> && e['id'] == mediaId) {
          hit = e;
          break;
        }
      }
      hit ??= entries.isNotEmpty && entries.first is Map<String, dynamic>
          ? entries.first as Map<String, dynamic>
          : null;

      final content = hit?['content'];
      final src = content is Map ? content['src'] as String? : null;
      if (src == null || src.isEmpty) {
        debugPrint('[client-feed] kein src für $mediaId '
            '(content-Keys: ${content is Map ? content.keys.join(",") : "keine"}) '
            '— nicht freigeschaltet, weiter mit WebView');
        return null;
      }
      debugPrint('[client-feed] $mediaId -> signierte URL da');
      return src;
    } catch (e) {
      debugPrint('[client-feed] fehlgeschlagen für $mediaId: $e');
      return null;
    }
  }

  /// Cookies des WebView-Stores für tv.volleyballworld.com als Header.
  /// Derselbe Store, den der WebView-Player nach dem Silent-Login gefüllt
  /// hat — die App liest ihn an anderer Stelle schon aus
  /// (webview_player_screen.dart).
  static Future<String> _tvCookieHeader() async {
    try {
      final cm = CookieManager.instance();
      final cookies = await cm.getCookies(url: WebUri(_origin));
      return cookies.map((c) => '${c.name}=${c.value}').join('; ');
    } catch (e) {
      debugPrint('[client-feed] Cookies nicht lesbar: $e');
      return '';
    }
  }
}
