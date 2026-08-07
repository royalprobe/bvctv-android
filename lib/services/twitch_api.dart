import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

/// Twitch-Integration fuer GBT (German Beach Tour) VODs vom Spontent-Channel.
/// Portierung des bvctv-web/server/services/twitchApi.js.
///
/// Nutzt den oeffentlichen GraphQL-Client-ID, den Twitchs eigener Web-
/// Player hardcoded verwendet. Keine OAuth-Credentials noetig.
///
/// Vorsicht: das ist gegen Twitch-ToS (Helix-API waere der offizielle Weg).
/// Wenn Twitch ihre GQL-API umbaut brechen wir und muessen die Queries
/// aktualisieren (yt-dlp/streamlink als Referenz).
class TwitchApi {
  static const _gqlUrl = 'https://gql.twitch.tv/gql';
  static const _clientId = 'kimne78kx3ncx6brgo4mv6wki5h1ko';
  static const _channelLogin = 'spontent';

  /// Filter auf GBT-Videos — Spontent streamt auch anderen Content
  /// (Flag Football etc.), den wollen wir nicht in der Liste.
  static final RegExp _gbtRe =
      RegExp(r'\bGBT\b|german beach tour', caseSensitive: false);

  static bool _isGbtRelevant(String title) => _gbtRe.hasMatch(title);

  /// 30 min Cache — VODs aendern sich selten.
  static List<Map<String, dynamic>>? _cachedVideos;
  static DateTime? _cachedAt;
  static Future<List<Map<String, dynamic>>>? _inflight;

  /// Liefert alle GBT-VODs vom Spontent-Channel, in der Reihenfolge neueste
  /// zuerst. Bei Netzwerk-/GQL-Fehler wird das gecachte Ergebnis (falls
  /// vorhanden) zurueckgegeben, sonst leere Liste — die Funktion wirft nie.
  ///
  /// Return-Format identisch zu VBW-Video-Items im HomeScreen (die Felder
  /// die _openVideo / VideoCard erwartet).
  static Future<List<Map<String, dynamic>>> fetchGbtVideos({bool force = false}) async {
    if (!force && _cachedVideos != null && _cachedAt != null &&
        DateTime.now().difference(_cachedAt!) < const Duration(minutes: 30)) {
      return _cachedVideos!;
    }
    if (_inflight != null) return _inflight!;
    _inflight = _run();
    try {
      return await _inflight!;
    } finally {
      _inflight = null;
    }
  }

  static Future<List<Map<String, dynamic>>> _run() async {
    try {
      final query = r'''
        query($login: String!) {
          user(login: $login) {
            id
            displayName
            stream {
              id
              title
              type
              previewImageURL
              createdAt
              game { name }
            }
            videos(first: 100, sort: TIME, type: ARCHIVE) {
              edges {
                node {
                  id
                  title
                  publishedAt
                  lengthSeconds
                  previewThumbnailURL(width: 320, height: 180)
                  game { name }
                }
              }
            }
          }
        }
      ''';
      final res = await http.post(
        Uri.parse(_gqlUrl),
        headers: {
          'Client-ID': _clientId,
          'Content-Type': 'application/json',
        },
        body: jsonEncode({
          'query': query,
          'variables': {'login': _channelLogin},
        }),
      ).timeout(const Duration(seconds: 10));
      if (res.statusCode != 200) {
        debugPrint('[twitch] HTTP ${res.statusCode}');
        return _cachedVideos ?? const [];
      }
      final Map<String, dynamic> body = jsonDecode(res.body);
      final user = body['data']?['user'];
      if (user == null) {
        debugPrint('[twitch] user not found: $_channelLogin');
        return _cachedVideos ?? const [];
      }
      final displayName = (user['displayName'] as String?) ?? _channelLogin;
      final List<Map<String, dynamic>> videos = [];

      final stream = user['stream'];
      if (stream != null && _isGbtRelevant((stream['title'] as String?) ?? '')) {
        videos.add({
          'id': 'live-$_channelLogin',
          'title': stream['title'] ?? '$displayName (LIVE)',
          'thumbnail': stream['previewImageURL'] ?? '',
          'matchDate': stream['createdAt'] ?? DateTime.now().toIso8601String(),
          'isLive': true,
          'tournament': 'German Beach Tour (GBT)',
          'source': 'twitch',
          'twitchLogin': _channelLogin,
        });
      }

      final edges = (user['videos']?['edges'] as List?) ?? const [];
      for (final edge in edges) {
        final v = edge?['node'];
        if (v == null) continue;
        final id = v['id'] as String?;
        final title = (v['title'] as String?) ?? '';
        if (id == null || id.isEmpty || !_isGbtRelevant(title)) continue;
        videos.add({
          'id': id,
          'title': title,
          'thumbnail': v['previewThumbnailURL'] ?? '',
          'matchDate': (v['publishedAt'] as String?) ?? '',
          'duration': v['lengthSeconds'] ?? 0,
          'isLive': false,
          'tournament': 'German Beach Tour (GBT)',
          'source': 'twitch',
        });
      }

      debugPrint('[twitch] $displayName: ${videos.length} GBT videos');
      _cachedVideos = videos;
      _cachedAt = DateTime.now();
      return videos;
    } catch (e) {
      debugPrint('[twitch] scrape failed: $e');
      return _cachedVideos ?? const [];
    }
  }

  static bool isTwitchTournamentId(String id) => id == 'twitch-gbt';
  static const String tournamentId = 'twitch-gbt';
  static const String tournamentTitle = 'German Beach Tour (GBT)';
}

/// PlaybackAccessToken + Master-URL fuer Twitch-VODs / Live-Streams.
/// Portierung des bvctv-web/server/services/twitchStream.js.
class TwitchStream {
  static const _gqlUrl = 'https://gql.twitch.tv/gql';
  static const _clientId = 'kimne78kx3ncx6brgo4mv6wki5h1ko';
  static const _usherBase = 'https://usher.ttvnw.net';

  /// Warum der letzte extractMasterUrl-Aufruf leer ausging, sofern Twitch
  /// einen Grund genannt hat ('GEOBLOCKED', sonst der rohe reason-String).
  /// null heisst: kein Sperrgrund, also Netz- oder API-Problem.
  ///
  /// Bewusst ein statisches Feld statt eines Rueckgabetyps — es gibt genau
  /// einen Aufrufer (home_screen::_openTwitchVideo) und der liest es
  /// unmittelbar nach dem await, ohne dass dazwischen ein zweiter Abruf
  /// laufen kann.
  static String? lastAbsageGrund;

  /// videoId ist entweder eine numerische VOD-ID oder `live-<login>`.
  /// Liefert die signed usher.ttvnw.net-Master-m3u8 URL, oder null bei
  /// Netz-/API-Fehler.
  static Future<String?> extractMasterUrl(String videoId) async {
    lastAbsageGrund = null;
    try {
      final isLive = videoId.startsWith('live-');
      final login = isLive ? videoId.substring(5) : '';
      final vodId = isLive ? '' : videoId;

      final body = jsonEncode({
        'operationName': 'PlaybackAccessToken',
        'extensions': {
          'persistedQuery': {
            'version': 1,
            // Stabil seit Jahren; falls Twitch rotiert, hier aktualisieren.
            'sha256Hash': '0828119ded1c13477966434e15800ff57ddacf13ba1911c129dc2200705b0712',
          },
        },
        'variables': {
          'isLive': isLive,
          'isVod': !isLive,
          'login': isLive ? login : '',
          'vodID': vodId,
          'playerType': 'site',
        },
      });

      final res = await http.post(
        Uri.parse(_gqlUrl),
        headers: {
          'Client-ID': _clientId,
          'Content-Type': 'application/json',
        },
        body: body,
      ).timeout(const Duration(seconds: 10));
      if (res.statusCode != 200) {
        debugPrint('[twitch-stream] GQL ${res.statusCode}');
        return null;
      }
      final data = jsonDecode(res.body);
      final root = data is Map ? data['data'] : null;
      final tokenObj = root is Map
          ? (isLive
              ? root['streamPlaybackAccessToken']
              : root['videoPlaybackAccessToken'])
          : null;
      final tokenMap = tokenObj is Map ? tokenObj : null;
      final tokenValue = tokenMap?['value'];
      final signature = tokenMap?['signature'];
      if (tokenValue == null || signature == null) {
        debugPrint('[twitch-stream] no playback token (geo-blocked?)');
        return null;
      }

      // Bei gesperrten Inhalten liefert Twitch TROTZDEM ein Token-Objekt,
      // die Absage steckt erst im JSON darin:
      //   {"authorization":{"forbidden":true,"reason":"GEOBLOCKED"}, ...}
      // Ungeprueft bauen wir daraus eine usher-URL, der Player laedt sie und
      // scheitert ohne verwertbare Meldung. Gemessen am 08.08.2026 fuer alle
      // GBT-VODs des Kanals spontent, von oesterreichischer Leitung aus.
      final grund = _absageGrund(tokenValue.toString());
      if (grund != null) {
        debugPrint('[twitch-stream] verweigert: $grund');
        lastAbsageGrund = grund;
        return null;
      }

      final rand = Random().nextInt(10000000);
      final psid = _randomHex(32);
      final params = <String, String>{
        'client_id': _clientId,
        'token': tokenValue.toString(),
        'sig': signature.toString(),
        'allow_source': 'true',
        'allow_audio_only': 'true',
        'allow_spectre': 'true',
        'fast_bread': 'true',
        'p': rand.toString(),
        'play_session_id': psid,
        'player_backend': 'mediaplayer',
        'playlist_include_framerate': 'true',
        'reassignments_supported': 'true',
        'supported_codecs': 'avc1',
        'cdm': 'wv',
        'transcode_mode': 'cbr_v1',
      };
      final qs = params.entries
          .map((e) => '${Uri.encodeQueryComponent(e.key)}=${Uri.encodeQueryComponent(e.value)}')
          .join('&');
      final masterUrl = isLive
          ? '$_usherBase/api/channel/hls/${Uri.encodeComponent(login)}.m3u8?$qs'
          : '$_usherBase/vod/${Uri.encodeComponent(vodId)}.m3u8?$qs';
      return masterUrl;
    } catch (e) {
      debugPrint('[twitch-stream] extract err: $e');
      return null;
    }
  }

  /// Liest den Absage-Grund aus dem Token-JSON, oder null wenn frei.
  /// Kaputtes JSON gilt bewusst als "frei" — dann soll der Player es
  /// versuchen duerfen statt an unserer Vorpruefung zu scheitern.
  static String? _absageGrund(String tokenValue) {
    try {
      final decoded = jsonDecode(tokenValue);
      final auth = decoded is Map ? decoded['authorization'] : null;
      if (auth is Map && auth['forbidden'] == true) {
        final r = auth['reason'];
        return (r is String && r.isNotEmpty) ? r : 'FORBIDDEN';
      }
    } catch (_) {}
    return null;
  }

  static String _randomHex(int len) {
    final r = Random();
    const chars = '0123456789abcdef';
    return List.generate(len, (_) => chars[r.nextInt(16)]).join();
  }
}
