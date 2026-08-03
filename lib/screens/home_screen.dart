import 'package:flutter/material.dart';

import 'package:flutter/services.dart';
import '../l10n/app_language.dart';
import '../app_variant.dart';
import '../l10n/strings.dart';
import 'package:url_launcher/url_launcher.dart';
import 'login_screen.dart';
import 'package:http/http.dart' as http;
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:webview_flutter_android/webview_flutter_android.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'dart:async';
import 'dart:collection' show UnmodifiableListView;
import 'dart:convert';
import 'dart:io' show Platform;
import 'package:package_info_plus/package_info_plus.dart';
import '../services/update_checker.dart';
import '../services/auth_service.dart';
import '../services/auth_state.dart';
import '../services/silent_login_flow.dart';
import '../services/laola_stream_extractor.dart';
import '../services/laola_livestream_scraper.dart';
import '../services/twitch_api.dart';
import 'player_screen.dart';

class VideoItem {
  final String id;
  final String title;
  final String teams;
  final String gender;
  final String round;
  final String tournament;
  final String thumbnailUrl;
  final int duration;
  final DateTime? matchDate;
  final String eventState;
  final DateTime? scheduledEnd;
  final String? linkUrl;

  const VideoItem({
    required this.id,
    required this.title,
    required this.teams,
    required this.gender,
    required this.round,
    required this.tournament,
    required this.thumbnailUrl,
    required this.duration,
    this.matchDate,
    this.eventState = 'VOD_PUBLIC',
    this.scheduledEnd,
    this.linkUrl,
  });

  bool get isExternal => linkUrl != null && !isTwitch;
  bool get isYouTube => linkUrl != null && linkUrl!.contains('youtube.com');
  bool get isLaola => linkUrl != null && linkUrl!.contains('laola1.at');
  // Twitch-Videos werden nicht extern per launchUrl geoeffnet — stattdessen
  // ueber TwitchStream.extractMasterUrl und dem native PlayerScreen.
  bool get isTwitch => linkUrl != null && linkUrl!.startsWith('twitch:');
  String? get twitchVideoId => isTwitch ? linkUrl!.substring(7) : null;
  bool get isLive => eventState == 'LIVE' || eventState == 'LIVE_PUBLISHED';
  bool get isInstantVod {
    if (eventState != 'INSTANT_VOD') return false;
    final end = scheduledEnd ?? matchDate;
    if (end == null) return true;
    return DateTime.now().toUtc().difference(end.toUtc()) < const Duration(hours: 2);
  }
  bool get isUpcoming {
    if (matchDate == null) return false;
    return matchDate!.isAfter(DateTime.now().toUtc());
  }
}

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  List<VideoItem> _videos = [];
  List<VideoItem> _liveVideos = [];
  Timer? _liveRefreshTimer;
  Timer? _videoRefreshTimer;
  Timer? _preloadFocusTimer;
  // Dynamisch aus https://www.laola1.at/de/tvthek/livestreams/ gescrapte
  // Beach-Turniere. Format identisch zu _laolaTournamentData, sodass der
  // bestehende Lookup-Pfad in _loadVideos gegen beide Listen sucht.
  List<Map<String, Object>> _scrapedLaolaTournaments = const [];
  WebViewController? _preloadController;
  String? _preloadedVideoId;
  bool _isLoading = true;
  String? _errorMessage;
  int _videosLoadEpoch = 0;
  String _genderFilter = 'all';
  String _currentPlaylistId = 'QN15YAsv';
  List<Map<String, String>> _availableTournaments = [];
  bool _isLoadingTournaments = true;
  String? _playerFilter;
  String? _countryFilter;
  bool _twoHourMode = true;
  bool _spoilerFree = true;

  // Source-Toggles (identisch zur Web-App) — bestimmen welche Turniere im
  // Dropdown gelistet werden. Alle drei standardmaessig aktiv, persistiert
  // in FlutterSecureStorage unter 'source_vbw'/'source_laola'/'source_twitch'.
  bool _sourceVbw = true;
  bool _sourceLaola = true;
  bool _sourceTwitch = true;

  final _storage = const FlutterSecureStorage();
  String _appVersion = '';

  static const _spoilerRounds = {'Final', 'Semifinal', '3rd Place'};
  bool _isSpoiler(String round) => _spoilerFree && _spoilerRounds.contains(round);

  List<VideoItem> get _allVideos {
    final liveIds = _liveVideos.map((v) => v.id).toSet();
    final merged = [..._liveVideos, ..._videos.where((v) => !liveIds.contains(v.id))];
    // Source-Filter: _liveVideos wird nur alle 60s neu befuellt
    // (_loadLiveAndUpcoming) und kann bis dahin ein Twitch/Laola-Video
    // enthalten das der User gerade per Source-Toggle ausgeblendet hat —
    // ohne diesen Filter wuerde das Live-Banner z.B. ein GBT-Video zeigen
    // obwohl der GBT-Toggle deaktiviert ist.
    return merged.where((v) {
      if (v.isTwitch) return _sourceTwitch;
      if (v.isLaola) return _sourceLaola;
      return _sourceVbw;
    }).toList();
  }

  List<String> get _availableCountries {
    final countries = <String>{};
    final source = _genderFilter == 'men'
        ? _allVideos.where((v) => v.gender == 'Men')
        : _genderFilter == 'women'
            ? _allVideos.where((v) => v.gender == 'Women')
            : _allVideos;
    for (final v in source) {
      for (final m in RegExp(r'\(([A-Z]{2,3})\)').allMatches(v.teams)) {
        countries.add(m.group(1)!);
      }
    }
    return countries.toList()..sort();
  }

  List<String> get _availablePlayers {
    final players = <String>{};
    final source = _genderFilter == 'men'
        ? _allVideos.where((v) => v.gender == 'Men')
        : _genderFilter == 'women'
            ? _allVideos.where((v) => v.gender == 'Women')
            : _allVideos;
    for (final v in source) {
      final teamParts = v.teams.split(RegExp(r'\s+v(?:s)?\s+'));
      for (final team in teamParts) {
        final cleaned = team.replaceAll(RegExp(r'\s*\([A-Z]{2,3}\)\s*$'), '').trim();
        for (final player in cleaned.split('/')) {
          final p = player.trim();
          if (p.isNotEmpty && p.length > 1) players.add(p);
        }
      }
    }
    return players.toList()..sort();
  }

  List<VideoItem> get _filteredVideos {
    var videos = _allVideos.where((v) => v.isLive || !v.isUpcoming).toList();
    if (_genderFilter == 'men') videos = videos.where((v) => v.gender == 'Men').toList();
    if (_genderFilter == 'women') videos = videos.where((v) => v.gender == 'Women').toList();
    if (_playerFilter != null) {
      final pf = _playerFilter!;
      videos = videos.where((v) => v.teams.contains(pf)).toList();
    }
    if (_countryFilter != null) {
      final cf = '($_countryFilter)';
      videos = videos.where((v) => v.teams.contains(cf)).toList();
    }
    // LIVE first, then upcoming, then rest (already sorted by date)
    videos.sort((a, b) {
      if (a.isLive != b.isLive) return a.isLive ? -1 : 1;
      if (a.isUpcoming != b.isUpcoming) return a.isUpcoming ? -1 : 1;
      if (a.matchDate == null) return 1;
      if (b.matchDate == null) return -1;
      return b.matchDate!.compareTo(a.matchDate!);
    });
    return videos;
  }

  @override
  void initState() {
    super.initState();
    _loadSettings();
    _loadTournamentList();
    _loadLiveAndUpcoming();
    WidgetsBinding.instance.addPostFrameCallback((_) => _maybeShowNoCredsHint());
    // Frühe Retries falls der erste Aufruf scheiterte oder langsam war
    Future.delayed(const Duration(seconds: 4), () {
      if (mounted && _liveVideos.isEmpty) _loadLiveAndUpcoming();
    });
    Future.delayed(const Duration(seconds: 12), () {
      if (mounted && _liveVideos.isEmpty) _loadLiveAndUpcoming();
    });
    _liveRefreshTimer = Timer.periodic(const Duration(seconds: 60), (_) => _loadLiveAndUpcoming());
    _videoRefreshTimer = Timer.periodic(const Duration(seconds: 90), (_) {
      if (_isLoading) return;
      final pid = _currentPlaylistId;
      if (pid.isEmpty) return;
      // Externe Quellen (YouTube/Laola) ändern sich kaum und haben keinen
      // Live-State – nicht im Hintergrund refreshen.
      if (pid.startsWith('__yt_') || pid.startsWith('__laola_')) return;
      // Virtuelle Turniere sind abgeschlossene Events, kein Refresh.
      if (pid.startsWith('__') && pid != _allId) return;
      _loadVideos(null, true, true);
    });
    if (Platform.isAndroid) {
      PackageInfo.fromPlatform().then((i) { if (mounted) setState(() => _appVersion = i.version); });
      Future.delayed(const Duration(seconds: 10), _checkForUpdateOnce);
    }
    // Laola1-Livestream-Scraper laeuft erst NACH dem App-Start, damit VBW-
    // Playlists und Update-Check nicht durch einen externen Fetch verzoegert
    // werden. KEIN periodischer Refresh — Court-IDs bleiben den Tag ueber
    // stabil. Bei Bedarf trifft der User den Aktualisieren-Button in der
    // AppBar, der re-triggert auch den Scrape.
    Future.delayed(const Duration(seconds: 8), _scrapeLaolaLivestreams);
  }

  Future<void> _checkForUpdateOnce() async {
    final info = await UpdateChecker.checkOncePerSession();
    if (info != null && mounted) _showUpdateDialog(info);
  }

  /// Holt die Laola1-Live-Uebersicht, parst alle Pro-Masters-Eintraege, prueft
  /// pro Court /access/hls, und merged Treffer in die Tournament-Liste. Falls
  /// das aktuell aktive Tournament durch die Scrape-Daten ueberschrieben oder
  /// neu eingefuegt wird, wird kein automatischer Reload ausgeloest — der
  /// User soll seinen aktuellen Video-Stream nicht durch einen Hintergrund-
  /// Refresh verlieren.
  Future<void> _scrapeLaolaLivestreams() async {
    // Neutrale Variante zeigt nur VBTV — der Scrape waere reiner Netz-Traffic
    // fuer Eintraege, die _visibleTournaments ohnehin sofort wegfiltert.
    // Greift fuer beide Aufrufer (Start-Delay und Aktualisieren-Button).
    if (AppVariant.vbtvOnly) return;
    final scraped = await LaolaLivestreamScraper.findBeachTournaments();
    if (!mounted || scraped.isEmpty) return;

    // Pro Tournament die Court-IDs gegen /access/hls validieren und nicht
    // verfuegbare Courts entfernen. Tournament mit 0 Live-Courts faellt raus.
    final validated = <Map<String, Object>>[];
    for (final t in scraped) {
      final videos = (t['videos'] as List).cast<Map<String, String>>();
      final ids = videos.map((v) => v['id']!).toList();
      final avail = await _fetchLaolaAvailability(ids);
      _laolaAvailCache[t['id'] as String] = avail;
      final liveVideos =
          videos.where((v) => avail[v['id']!] ?? false).toList();
      if (liveVideos.isEmpty) continue;
      validated.add({
        ...t,
        'videos': liveVideos,
      });
    }

    if (!mounted) return;

    // Dedup: wenn die hardcoded _laolaTournamentData die gleiche Player-ID
    // hat (gleiche Court-IDs am gleichen Tag), Scrape-Eintrag verwerfen —
    // hardcoded Tabelle hat ggf. korrekte Court-Namen + Thumbnails.
    final hardcodedIds = _laolaTournamentData
        .expand((t) => (t['videos'] as List).cast<Map<String, String>>())
        .map((v) => v['id']!)
        .toSet();
    final deduped = validated.where((t) {
      final vids = (t['videos'] as List).cast<Map<String, String>>();
      return !vids.every((v) => hardcodedIds.contains(v['id']!));
    }).toList();

    _scrapedLaolaTournaments = deduped;
    if (deduped.isEmpty) return;

    // Die Aggregat-Ansicht ("Alle Turniere") zieht ihre Laola-Items aus
    // _scrapedLaolaTournaments — die war beim App-Start aber noch leer, weil
    // der Scrape erst 8s spaeter laeuft, und das Ergebnis liegt seitdem in
    // _videosCache. Ohne Invalidierung + Reload bleibt ein gerade gestartetes
    // Laola-Turnier bis zum naechsten manuellen Refresh unsichtbar, obwohl
    // der Scraper es laengst gefunden hat.
    _videosCache.remove(_allId);
    if (_currentPlaylistId == _allId && _sourceLaola) {
      _loadVideos(null, true, true);
    }

    // Tournament-Liste fuer den User aktualisieren — bestehende Eintraege
    // bleiben, gescrapte werden vorne eingefuegt (= aktuellste Spieltage
    // oben). Aktuell ausgewaehltes Tournament wird NICHT umgeschaltet.
    final newEntries = deduped
        .map((t) => {
              'id': t['id'] as String,
              'title': t['title'] as String,
              'matchDate': t['matchDate'] as String,
            })
        .toList();
    final existingIds = _availableTournaments.map((t) => t['id']).toSet();
    final additions =
        newEntries.where((e) => !existingIds.contains(e['id'])).toList();
    if (additions.isNotEmpty) {
      setState(() {
        _availableTournaments = [...additions, ..._availableTournaments];
      });
    }
  }

  void _showUpdateDialog(UpdateInfo info) {
    double? progress;
    String? error;
    showDialog(
      context: context,
      barrierDismissible: true,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialog) => AlertDialog(
          backgroundColor: const Color(0xFF1A1A1A),
          title: Row(children: [
            const Icon(Icons.system_update, color: Colors.orange, size: 20),
            const SizedBox(width: 8),
            Expanded(child: Text('Update v${info.versionName}',
                style: const TextStyle(color: Colors.white, fontSize: 16))),
          ]),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (info.changelog.isNotEmpty) ...[
                Text(info.changelog,
                    style: const TextStyle(color: Colors.white70, fontSize: 12),
                    maxLines: 6, overflow: TextOverflow.ellipsis),
                const SizedBox(height: 12),
              ],
              if (progress != null) ...[
                LinearProgressIndicator(
                    value: progress, color: Colors.orange, backgroundColor: Colors.white12),
                const SizedBox(height: 6),
                Text(S.downloadProgress((progress! * 100).toInt()),
                    style: const TextStyle(color: Colors.white38, fontSize: 11)),
              ],
              if (error != null)
                Text(error!, style: const TextStyle(color: Colors.redAccent, fontSize: 11)),
            ],
          ),
          actions: progress == null
              ? [
                  TextButton(
                    autofocus: true,
                    onPressed: () => Navigator.pop(ctx),
                    child: Text(S.later, style: const TextStyle(color: Colors.white54)),
                  ),
                  TextButton(
                    onPressed: () async {
                      setDialog(() { progress = 0.0; error = null; });
                      await UpdateChecker.downloadAndInstall(
                        info.downloadUrl,
                        info.versionName,
                        onProgress: (p) { if (ctx.mounted) setDialog(() => progress = p); },
                        onError: (e) { if (ctx.mounted) setDialog(() { progress = null; error = S.errorMsg(e.toString()); }); },
                      );
                    },
                    child: Text(S.installNow, style: const TextStyle(color: Colors.orange)),
                  ),
                ]
              : const [],
        ),
      ),
    );
  }

  void _startPreload(VideoItem video) {
    if (_preloadedVideoId == video.id) return;
    _preloadFocusTimer?.cancel();
    // Debounce-Fenster fuer Scroll-Bewegungen ueber Cards. 300ms reicht,
    // dass schnelles Durchblaettern keine Preloads ausloest, ohne dass
    // sich der Player-Start auf der einzelnen Card spuerbar verzoegert.
    _preloadFocusTimer = Timer(const Duration(milliseconds: 300), () {
      if (!mounted) return;
      final ctx = _buildCtx();
      final selfLink = Uri.encodeComponent(
        'https://zapp-5434-volleyball-tv.web.app/jw/media/${video.id}?disablePlayNext=false&withErrors=false&ctx=$ctx',
      );
      final playerUrl = 'https://tv.volleyballworld.com/player?self-link=$selfLink&screen-id=696c5338-8a65-44fb-94c6-41411be52290';
      final ctrl = WebViewController()
        ..setJavaScriptMode(JavaScriptMode.unrestricted)
        ..setUserAgent('Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36')
        ..loadRequest(Uri.parse(playerUrl));
      setState(() { _preloadController = ctrl; _preloadedVideoId = video.id; });
    });
  }

  @override
  void dispose() {
    _liveRefreshTimer?.cancel();
    _videoRefreshTimer?.cancel();
    _preloadFocusTimer?.cancel();
    try { _preloadController?.loadRequest(Uri.parse('about:blank')); } catch (_) {}
    super.dispose();
  }

  Future<void> _loadSettings() async {
    final th = await _storage.read(key: 'two_hour_mode');
    final sf = await _storage.read(key: 'spoiler_free');
    final sv = await _storage.read(key: 'source_vbw');
    final sl = await _storage.read(key: 'source_laola');
    final st = await _storage.read(key: 'source_twitch');
    if (mounted) {
      setState(() {
        _twoHourMode = th != 'false';
        _spoilerFree = sf != 'false';
        // Neutrale Variante: Quellen hart auf VBTV, gespeicherte Werte werden
        // ignoriert. Sonst koennte ein alter source_laola=true-Eintrag aus dem
        // Storage Laola-Inhalte einblenden, obwohl es keine Chips mehr gibt
        // mit denen der User sie wieder abschalten koennte.
        _sourceVbw = AppVariant.vbtvOnly ? true : sv != 'false';
        _sourceLaola = AppVariant.vbtvOnly ? false : sl != 'false';
        _sourceTwitch = AppVariant.vbtvOnly ? false : st != 'false';
      });
    }
  }

  /// Ordnet einer Tournament-ID die Source-Kategorie zu — bestimmt vom
  /// ID-Praefix / -Match analog zur Web-App. Die Zuordnung ist die Basis
  /// fuer den Source-Toggle-Filter im Dropdown.
  String _tournamentSource(String id) {
    if (TwitchApi.isTwitchTournamentId(id)) return 'twitch';
    if (id.startsWith('__laola_')) return 'laola';
    return 'vbw';
  }

  /// Liste der Turniere die aktuell gemaess Source-Toggles im Dropdown
  /// gezeigt werden sollen. "Alle Turniere" bleibt sichtbar wenn
  /// mindestens eine Source aktiv ist.
  List<Map<String, String>> _visibleTournaments() {
    return _availableTournaments.where((t) {
      final id = t['id'] ?? '';
      if (id == _allId) return _sourceVbw || _sourceLaola || _sourceTwitch;
      switch (_tournamentSource(id)) {
        case 'twitch': return _sourceTwitch;
        case 'laola':  return _sourceLaola;
        default:       return _sourceVbw;
      }
    }).toList();
  }

  /// Handler fuer die drei Source-Toggle-Chips oben ueber dem Dropdown.
  void _toggleSource(String src) {
    setState(() {
      switch (src) {
        case 'vbw':    _sourceVbw    = !_sourceVbw;    break;
        case 'laola':  _sourceLaola  = !_sourceLaola;  break;
        case 'twitch': _sourceTwitch = !_sourceTwitch; break;
      }
    });
    _storage.write(key: 'source_vbw',    value: _sourceVbw.toString());
    _storage.write(key: 'source_laola',  value: _sourceLaola.toString());
    _storage.write(key: 'source_twitch', value: _sourceTwitch.toString());
    // Wenn das aktuell gewaehlte Turnier von der neuen Filter-Auswahl
    // ausgeblendet wird, auf das erste sichtbare umschalten.
    final visible = _visibleTournaments();
    if (visible.isEmpty) return;
    if (!visible.any((t) => t['id'] == _currentPlaylistId)) {
      final newFirst = visible.first['id']!;
      _loadVideos(newFirst);
    }
  }

  Future<void> _loadLiveAndUpcoming() async {
    // 1. Live-Events aus aktuell geladenem View sofort zeigen (kein Netzwerk nötig)
    final liveInView = _videos.where((v) => v.isLive).toList();
    if (liveInView.isNotEmpty && mounted) {
      setState(() => _liveVideos = liveInView);
    }

    // 2. Nur das neueste Turnier auf Live-Events prüfen (API-Reihenfolge: neueste zuerst).
    //    Externe Quellen (YouTube/Laola/virtuelle) haben keinen Live-State und werden übersprungen.
    //    VBW-Bridges (__vbw_*) sind echte VBW-Inhalte und müssen mitgeprüft werden,
    //    weil bei einem gerade gestarteten Turnier (z.B. Ostrava 2026) die Live-
    //    Streams ausschließlich über die Bridge gefunden werden.
    final toCheck = _availableTournaments
        .where((t) {
          final id = t['id']!;
          if (id == _allId) return false;
          if (id.startsWith('__yt_') || id.startsWith('__laola_')) return false;
          if (id.startsWith('__') && !id.startsWith('__vbw_')) return false;
          return true;
        })
        .take(1)
        .map((t) => t['id']!)
        .toSet();

    if (toCheck.isEmpty) return; // Turnierliste noch nicht geladen → nächste Retry

    final ctx = _buildCtx();
    final liveItems = <VideoItem>[];
    final seen = <String>{};
    int successCount = 0;

    await Future.wait(toCheck.map((id) async {
      try {
        // VBW-Bridge: pro Media-ID gegen /jw/media/{id} prüfen — frischer
        // event_state nötig, der gecachte VideoItem-Stand kann veraltet sein.
        if (id.startsWith('__vbw_')) {
          final ci = id.substring('__vbw_'.length);
          // NICHT alle Bridge-Items pruefen: seit die Bridge auch den
          // "Latest Replays"-Feed liest, haengen an einem laufenden Turnier
          // ueber 100 Media-IDs — die alle im 60s-Takt einzeln abzufragen
          // wuerde den Fire Stick fluten. Ein abgeschlossenes Replay kann
          // ohnehin nicht mehr live gehen, also bleiben nur Items im
          // Zeitfenster um ihren Anpfiff uebrig.
          final now = DateTime.now().toUtc();
          final mediaIds = (_vbwBridgeItems[ci] ?? const <VideoItem>[])
              .where((v) {
                if (v.isLive) return true;
                if (v.eventState == 'VOD_PUBLIC') return false;
                final d = v.matchDate?.toUtc();
                if (d == null) return false;
                return now.isAfter(d.subtract(const Duration(minutes: 30))) &&
                    now.isBefore(d.add(const Duration(hours: 6)));
              })
              .map((v) => v.id)
              .toList();
          if (mediaIds.isEmpty) return;
          int localSuccess = 0;
          final entries = await Future.wait(mediaIds.map((mid) async {
            try {
              final res = await http.get(
                Uri.parse(
                    'https://zapp-5434-volleyball-tv.web.app/jw/media/$mid?ctx=$ctx'),
                headers: {'Origin': 'https://tv.volleyballworld.com'},
              ).timeout(const Duration(seconds: 6));
              if (res.statusCode != 200) return null;
              localSuccess++;
              final data = jsonDecode(res.body);
              final list = data['entry'] as List? ?? [];
              return list.isNotEmpty ? list.first : null;
            } catch (_) {
              return null;
            }
          }));
          if (localSuccess > 0) successCount++;
          for (final entry in entries) {
            if (entry == null) continue;
            final state = entry['extensions']?['event_state'] as String? ?? '';
            if (state == 'LIVE' || state == 'LIVE_PUBLISHED') {
              final item = _itemFromJson(entry);
              if (seen.add(item.id)) liveItems.add(item);
            }
          }
          return;
        }

        // Reguläre VBW-Playlist: 1 Aufruf liefert alle Items mit event_state.
        final res = await http.get(
          Uri.parse('https://zapp-5434-volleyball-tv.web.app/jw/playlists/$id?overrideFeedType=moreinfo&ctx=$ctx'),
          headers: {'Origin': 'https://tv.volleyballworld.com'},
        ).timeout(const Duration(seconds: 10));
        if (res.statusCode != 200) return;
        successCount++;
        final data = jsonDecode(res.body);
        final entries = data['entry'] as List? ?? [];
        for (final entry in entries) {
          final state = entry['extensions']?['event_state'] as String? ?? '';
          if (state == 'LIVE' || state == 'LIVE_PUBLISHED') {
            final item = _itemFromJson(entry);
            if (seen.add(item.id)) liveItems.add(item);
          }
        }
        // Bridge-Extras für diese Playlist (PRE_LIVE/LIVE-Spiele die VBW noch
        // nicht in die offizielle Playlist gelegt hat) ebenfalls auf LIVE
        // prüfen — sonst wird ein gerade laufendes Match in der Pool-Phase
        // nicht im Live-Banner sichtbar.
        final ci = _vbwPlaylistCi[id];
        if (ci != null) {
          final existing = entries
              .map((e) => e['id'] as String? ?? '')
              .where((s) => s.isNotEmpty)
              .toSet();
          final extraIds = (_vbwBridgeItems[ci] ?? const <VideoItem>[])
              .map((v) => v.id)
              .where((mid) => !existing.contains(mid))
              .toList();
          if (extraIds.isNotEmpty) {
            final extras = await Future.wait(extraIds.map((mid) async {
              try {
                final r = await http.get(
                  Uri.parse(
                      'https://zapp-5434-volleyball-tv.web.app/jw/media/$mid?ctx=$ctx'),
                  headers: {'Origin': 'https://tv.volleyballworld.com'},
                ).timeout(const Duration(seconds: 6));
                if (r.statusCode != 200) return null;
                final list = jsonDecode(r.body)['entry'] as List? ?? [];
                return list.isNotEmpty ? list.first : null;
              } catch (_) {
                return null;
              }
            }));
            for (final entry in extras) {
              if (entry == null) continue;
              final state =
                  entry['extensions']?['event_state'] as String? ?? '';
              if (state == 'LIVE' || state == 'LIVE_PUBLISHED') {
                final item = _itemFromJson(entry);
                if (seen.add(item.id)) liveItems.add(item);
              }
            }
          }
        }
      } catch (_) {}
    }));

    if (!mounted) return;
    if (liveItems.isNotEmpty) {
      // liveItems stammt ausschliesslich aus VBW-Quellen — Laola/Twitch sind
      // oben per toCheck-Filter ausgeschlossen. Ein blosses Ersetzen wuerde
      // laufende Laola-/GBT-Streams aus dem Live-Banner werfen, sobald
      // irgendein VBW-Turnier live geht. Externe Live-Items aus der aktuellen
      // Ansicht deshalb behalten.
      final vbwIds = liveItems.map((v) => v.id).toSet();
      final externalLive = liveInView.where(
          (v) => (v.isLaola || v.isTwitch) && !vbwIds.contains(v.id));
      setState(() => _liveVideos = [...liveItems, ...externalLive]);
    } else if (successCount > 0 && liveInView.isEmpty) {
      // API confirmed no live games and current view also has none → clear
      setState(() => _liveVideos = []);
    }
    // If network failed (successCount == 0), keep existing _liveVideos intact
  }

  Future<String?> _promptSingleValue({
    required BuildContext outerCtx,
    required String label,
    required String initialValue,
    bool obscure = false,
    TextInputType keyboardType = TextInputType.text,
  }) {
    final ctrl = TextEditingController(text: initialValue);
    return showDialog<String>(
      context: outerCtx,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1A1A1A),
        title: Text(label, style: const TextStyle(color: Colors.white)),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          obscureText: obscure,
          keyboardType: keyboardType,
          style: const TextStyle(color: Colors.white),
          decoration: InputDecoration(
            filled: true,
            fillColor: const Color(0xFF2A2A2A),
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(8),
              borderSide: const BorderSide(color: Colors.orange, width: 2),
            ),
          ),
          onSubmitted: (_) => Navigator.pop(ctx, ctrl.text),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(S.cancel,
                style: const TextStyle(color: Colors.white54)),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.orange,
              foregroundColor: Colors.black,
            ),
            onPressed: () => Navigator.pop(ctx, ctrl.text),
            child: const Text('OK',
                style: TextStyle(fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    );
  }

  Future<void> _showSavedCredentialsDialog(BuildContext outerCtx) async {
    String email = await _storage.read(key: 'saved_email') ?? '';
    String pw = await _storage.read(key: 'saved_password') ?? '';
    if (!mounted) return;
    await showDialog<void>(
      context: outerCtx,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialog) {
          Widget fieldRow({
            required String label,
            required String value,
            required String placeholder,
            required bool obscure,
            required VoidCallback onEdit,
            bool autofocus = false,
          }) {
            final display = value.isEmpty
                ? placeholder
                : (obscure ? '•' * value.length.clamp(0, 12) : value);
            return _TvFocusButton(
              autofocus: autofocus,
              borderRadius: 8,
              onPressed: onEdit,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                decoration: BoxDecoration(
                  color: const Color(0xFF2A2A2A),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Row(children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(label,
                            style: const TextStyle(
                                color: Colors.white54, fontSize: 11)),
                        const SizedBox(height: 2),
                        Text(
                          display,
                          style: TextStyle(
                            color: value.isEmpty ? Colors.white38 : Colors.white,
                            fontSize: 15,
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                    ),
                  ),
                  const Icon(Icons.edit, color: Colors.white38, size: 18),
                ]),
              ),
            );
          }

          return AlertDialog(
            backgroundColor: const Color(0xFF1A1A1A),
            title: Text(S.savedCredentials,
                style: const TextStyle(color: Colors.white)),
            content: SizedBox(
              width: 360,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(S.savedCredentialsHint,
                      style: const TextStyle(color: Colors.white54, fontSize: 12)),
                  const SizedBox(height: 16),
                  fieldRow(
                    label: S.emailAddress,
                    value: email,
                    placeholder: S.credentialsNotSet,
                    obscure: false,
                    autofocus: true,
                    onEdit: () async {
                      final result = await _promptSingleValue(
                        outerCtx: ctx,
                        label: S.emailAddress,
                        initialValue: email,
                        keyboardType: TextInputType.emailAddress,
                      );
                      if (result != null) setDialog(() => email = result.trim());
                    },
                  ),
                  const SizedBox(height: 10),
                  fieldRow(
                    label: S.password,
                    value: pw,
                    placeholder: S.credentialsNotSet,
                    obscure: true,
                    onEdit: () async {
                      final result = await _promptSingleValue(
                        outerCtx: ctx,
                        label: S.password,
                        initialValue: pw,
                        obscure: true,
                      );
                      if (result != null) setDialog(() => pw = result);
                    },
                  ),
                  const SizedBox(height: 12),
                  Text(S.autoFillNotice,
                      style: const TextStyle(color: Colors.white38, fontSize: 11)),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () async {
                  await _storage.delete(key: 'saved_email');
                  await _storage.delete(key: 'saved_password');
                  if (ctx.mounted) Navigator.pop(ctx);
                },
                child: Text(S.clear,
                    style: const TextStyle(color: Colors.redAccent)),
              ),
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: Text(S.cancel,
                    style: const TextStyle(color: Colors.white54)),
              ),
              ElevatedButton(
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.orange,
                  foregroundColor: Colors.black,
                ),
                onPressed: () async {
                  if (email.isNotEmpty) {
                    await _storage.write(key: 'saved_email', value: email);
                  } else {
                    await _storage.delete(key: 'saved_email');
                  }
                  if (pw.isNotEmpty) {
                    await _storage.write(key: 'saved_password', value: pw);
                  } else {
                    await _storage.delete(key: 'saved_password');
                  }
                  // Der gecachte Silent-Login-Result (invalidCredentials
                  // vom vorherigen Versuch) ist jetzt stale — beim naechsten
                  // Video-Click soll der Login mit den neuen Daten frisch
                  // durchlaufen.
                  AuthState.lastSilentLoginResult = null;
                  if (ctx.mounted) Navigator.pop(ctx);
                },
                child: Text(S.save,
                    style: const TextStyle(fontWeight: FontWeight.bold)),
              ),
            ],
          );
        },
      ),
    );
  }

  /// Wird genau einmal pro App-Start nach dem ersten Frame aufgerufen. Liest
  /// drei Keys aus SecureStorage parallel (sub-Millisekunde) — zeigt den
  /// Hinweis-Dialog nur wenn weder Email noch Passwort gespeichert sind UND
  /// der User den Hinweis noch nicht weggedrückt hat.
  Future<void> _maybeShowNoCredsHint() async {
    if (!mounted) return;
    final results = await Future.wait([
      _storage.read(key: 'saved_email'),
      _storage.read(key: 'saved_password'),
      _storage.read(key: 'hide_no_creds_hint'),
    ]);
    final hasEmail = (results[0] ?? '').isNotEmpty;
    final hasPw = (results[1] ?? '').isNotEmpty;
    final hidden = (results[2] ?? '') == '1';
    if (hasEmail && hasPw) return;
    if (hidden) return;
    if (!mounted) return;
    _showNoCredsHintDialog();
  }

  Future<void> _showNoCredsHintDialog() async {
    if (!mounted) return;
    bool dontShowAgain = false;
    await showDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialog) {
          Future<void> persistHide() async {
            if (dontShowAgain) {
              await _storage.write(key: 'hide_no_creds_hint', value: '1');
            }
          }
          return AlertDialog(
            backgroundColor: const Color(0xFF1A1A1A),
            title: Row(children: [
              const Icon(Icons.info_outline, color: Colors.orange, size: 22),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  S.isEn
                      ? 'Sign-in for VBW videos'
                      : 'Anmeldung für VBW-Videos',
                  style: const TextStyle(color: Colors.white, fontSize: 17),
                ),
              ),
            ]),
            contentPadding: const EdgeInsets.fromLTRB(24, 12, 24, 0),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  S.isEn
                      ? 'Without saved credentials only YouTube and Laola videos can be watched. VBW streams need an account.'
                      : 'Ohne gespeicherte Anmeldedaten lassen sich nur YouTube- und Laola-Videos schauen. VBW-Streams brauchen einen Account.',
                  style: const TextStyle(
                      color: Colors.white70, fontSize: 14, height: 1.4),
                ),
                const SizedBox(height: 12),
                CheckboxListTile(
                  value: dontShowAgain,
                  onChanged: (v) =>
                      setDialog(() => dontShowAgain = v ?? false),
                  title: Text(
                    S.isEn ? "Don't show again" : 'Nicht mehr zeigen',
                    style: const TextStyle(
                        color: Colors.white70, fontSize: 13),
                  ),
                  controlAffinity: ListTileControlAffinity.leading,
                  activeColor: Colors.orange,
                  checkColor: Colors.black,
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                ),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () async {
                  await persistHide();
                  if (ctx.mounted) Navigator.pop(ctx);
                },
                child: Text(
                  S.isEn ? 'Later' : 'Später',
                  style: const TextStyle(color: Colors.white54),
                ),
              ),
              ElevatedButton(
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.orange,
                  foregroundColor: Colors.black,
                ),
                onPressed: () async {
                  await persistHide();
                  if (ctx.mounted) Navigator.pop(ctx);
                  if (mounted) _showSavedCredentialsDialog(context);
                },
                child: Text(
                  S.isEn ? 'Enter credentials' : 'Anmeldedaten eingeben',
                  style: const TextStyle(fontWeight: FontWeight.bold),
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  /// [focusSavedCredentials] setzt den Initial-Fokus auf den "Gespeicherte
  /// Zugangsdaten"-Button statt auf den Logout-Knopf. Wird von den Login-
  /// Fehler-Flows benutzt, damit der User beim Klick auf "Zugangsdaten
  /// korrigieren" direkt visuell in der richtigen Sektion landet.
  void _showSettings({bool focusSavedCredentials = false}) {
    String? updateMsg;
    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialog) => AlertDialog(
          backgroundColor: const Color(0xFF1A1A1A),
          title: Text(S.settings, style: const TextStyle(color: Colors.white)),
          contentPadding: const EdgeInsets.fromLTRB(24, 8, 24, 16),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(S.twoHourMode, style: const TextStyle(color: Colors.white70)),
                subtitle: Text(
                  _twoHourMode ? S.twoHourModeOnDesc : S.twoHourModeOffDesc,
                  style: const TextStyle(color: Colors.white38, fontSize: 12),
                ),
                value: _twoHourMode,
                activeThumbColor: Colors.orange,
                onChanged: (val) {
                  setDialog(() {});
                  setState(() => _twoHourMode = val);
                  _storage.write(key: 'two_hour_mode', value: val.toString());
                },
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(S.spoilerProtection, style: const TextStyle(color: Colors.white70)),
                subtitle: Text(
                  _spoilerFree ? S.spoilerOnDesc : S.spoilerOffDesc,
                  style: const TextStyle(color: Colors.white38, fontSize: 12),
                ),
                value: _spoilerFree,
                activeThumbColor: Colors.orange,
                onChanged: (val) {
                  setDialog(() {});
                  setState(() => _spoilerFree = val);
                  _storage.write(key: 'spoiler_free', value: val.toString());
                },
              ),
              const Divider(color: Colors.white12, height: 16),
              _TvFocusButton(
                borderRadius: 6,
                onPressed: () async {
                  final result = await showDialog<String>(
                    context: ctx,
                    builder: (c) => AlertDialog(
                      backgroundColor: const Color(0xFF1A1A1A),
                      title: Text(S.language, style: const TextStyle(color: Colors.white)),
                      contentPadding: const EdgeInsets.fromLTRB(0, 8, 0, 8),
                      content: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          ListTile(
                            autofocus: S.isEn,
                            title: Text('English', style: TextStyle(
                              color: S.isEn ? Colors.orange : Colors.white70,
                              fontWeight: S.isEn ? FontWeight.bold : FontWeight.normal,
                            )),
                            trailing: S.isEn ? const Icon(Icons.check, color: Colors.orange, size: 18) : null,
                            onTap: () => Navigator.pop(c, 'en'),
                          ),
                          ListTile(
                            autofocus: !S.isEn,
                            title: Text('Deutsch', style: TextStyle(
                              color: !S.isEn ? Colors.orange : Colors.white70,
                              fontWeight: !S.isEn ? FontWeight.bold : FontWeight.normal,
                            )),
                            trailing: !S.isEn ? const Icon(Icons.check, color: Colors.orange, size: 18) : null,
                            onTap: () => Navigator.pop(c, 'de'),
                          ),
                        ],
                      ),
                      actions: const [],
                    ),
                  );
                  if (result != null) {
                    appLanguage.value = result;
                    _storage.write(key: 'language', value: result);
                  }
                },
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  child: Row(children: [
                    Expanded(child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(S.language, style: const TextStyle(color: Colors.white70)),
                        Text(
                          S.isEn ? S.languageEnglish : S.languageGerman,
                          style: const TextStyle(color: Colors.white38, fontSize: 12),
                        ),
                      ],
                    )),
                    const Icon(Icons.chevron_right, color: Colors.white38, size: 18),
                  ]),
                ),
              ),
              const Divider(color: Colors.white12, height: 16),
              FutureBuilder<bool>(
                future: _storage.read(key: 'saved_email').then((v) => v != null && v.isNotEmpty),
                builder: (futureCtx, snapshot) {
                  final stored = snapshot.data ?? false;
                  return _TvFocusButton(
                    autofocus: focusSavedCredentials,
                    borderRadius: 6,
                    onPressed: () async {
                      await _showSavedCredentialsDialog(ctx);
                      setDialog(() {});
                    },
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      child: Row(children: [
                        Expanded(child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(S.savedCredentials,
                                style: const TextStyle(color: Colors.white70)),
                            Text(
                              stored ? S.credentialsSet : S.credentialsNotSet,
                              style: TextStyle(
                                color: stored ? Colors.greenAccent : Colors.white38,
                                fontSize: 12,
                              ),
                            ),
                          ],
                        )),
                        const Icon(Icons.chevron_right, color: Colors.white38, size: 18),
                      ]),
                    ),
                  );
                },
              ),
              const Divider(color: Colors.white12, height: 24),
              Row(children: [
                _TvFocusButton(
                  // Wenn wir vom Login-Fehler-Flow her kommen, sitzt der
                  // Initial-Fokus auf den Gespeicherte-Zugangsdaten-Button.
                  // Sonst wie gehabt auf Logout.
                  autofocus: !focusSavedCredentials,
                  borderRadius: 6,
                  onPressed: () async {
                    Navigator.pop(ctx);
                    final confirm = await showDialog<bool>(
                      context: context,
                      builder: (c) => AlertDialog(
                        backgroundColor: const Color(0xFF1A1A1A),
                        title: Text(S.logoutTitle, style: const TextStyle(color: Colors.white)),
                        content: Text(S.logoutDesc, style: const TextStyle(color: Colors.white70)),
                        actions: [
                          TextButton(autofocus: true, onPressed: () => Navigator.pop(c, false),
                              child: Text(S.cancel, style: const TextStyle(color: Colors.white54))),
                          TextButton(onPressed: () => Navigator.pop(c, true),
                              child: Text(S.logout, style: const TextStyle(color: Colors.redAccent))),
                        ],
                      ),
                    );
                    if (confirm == true && mounted) {
                      await AuthService.logout();
                      AuthState.token.value = '';
                      if (mounted) {
                        Navigator.pushReplacement(context,
                            MaterialPageRoute(builder: (_) => const LoginScreen()));
                      }
                    }
                  },
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                    child: Text(S.logout, style: const TextStyle(color: Colors.redAccent)),
                  ),
                ),
                const Spacer(),
                _TvFocusButton(
                  borderRadius: 6,
                  onPressed: () => Navigator.pop(ctx),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                    child: Text(S.done, style: const TextStyle(color: Colors.orange)),
                  ),
                ),
              ]),
              if (_appVersion.isNotEmpty) ...[
                const SizedBox(height: 8),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text('v$_appVersion',
                        style: const TextStyle(color: Colors.white24, fontSize: 11)),
                    _TvFocusButton(
                      borderRadius: 6,
                      onPressed: () async {
                        setDialog(() => updateMsg = null);
                        UpdateChecker.resetSession();
                        final info = await UpdateChecker.check();
                        if (!ctx.mounted || !mounted) return;
                        if (info != null) {
                          Navigator.pop(ctx);
                          _showUpdateDialog(info);
                        } else {
                          setDialog(() => updateMsg = S.alreadyUpToDate);
                        }
                      },
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
                        child: Text(
                          updateMsg ?? S.checkForUpdates,
                          style: TextStyle(
                            color: updateMsg != null ? Colors.green.shade300 : Colors.white38,
                            fontSize: 11,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ],
          ),
          actions: const [],
        ),
      ),
    );
  }

  String _buildCtx() {
    final payload = jsonEncode({
      'quick-bricky-login-flow.access_token': AuthState.token.value,
      'platform': 'web',
    });
    return base64Url.encode(utf8.encode(payload));
  }

  String _extractThumbnail(dynamic item) {
    final groups = item['media_group'] as List? ?? [];
    for (final group in groups) {
      final items = group['media_item'] as List? ?? [];
      if (items.isNotEmpty) return items.first['src'] ?? '';
    }
    return '';
  }

  String _parseTeams(String title) {
    final pipeIdx = title.indexOf(' | ');
    final firstPart = pipeIdx > 0 ? title.substring(0, pipeIdx) : title;
    final commaIdx = firstPart.indexOf(',');
    if (commaIdx > 0) return firstPart.substring(0, commaIdx).trim();
    final dashGender = RegExp(r'\s-\s[MW]\s-').firstMatch(firstPart);
    if (dashGender != null) return firstPart.substring(0, dashGender.start).trim();
    // WM-Format: "Teams - Beach Volleyball - WC - Women/Men"
    final dashIdx = firstPart.indexOf(' - ');
    if (dashIdx > 0) return firstPart.substring(0, dashIdx).trim();
    return firstPart.trim();
  }

  String _parseGender(String title) {
    // 2026 elite: ", Women ..." / ", Men ..."
    if (RegExp(r',\s*Women(\s|$)').hasMatch(title)) return 'Women';
    if (RegExp(r',\s*Men(\s|$)').hasMatch(title)) return 'Men';
    // 2025 parentheses: "(W)" / "(M)"
    if (title.contains('(W)')) return 'Women';
    if (title.contains('(M)')) return 'Men';
    // Men's / Women's text format
    if (RegExp(r"\bWomen's\b").hasMatch(title)) return 'Women';
    if (RegExp(r"\bMen's\b").hasMatch(title)) return 'Men';
    // Alanya dash format: "- W -" / "- M -"
    if (RegExp(r'\s-\sW\s-').hasMatch(title)) return 'Women';
    if (RegExp(r'\s-\sM\s-').hasMatch(title)) return 'Men';
    // WM/Fallback: "... - Women" / "... - Men"
    if (RegExp(r'\bWomen\b').hasMatch(title)) return 'Women';
    if (RegExp(r'\bMen\b').hasMatch(title)) return 'Men';
    return '';
  }

  String _parseRound(String title) {
    // 2026 elite: ", Men/Women ROUND on Court"
    final m1 = RegExp(r',\s*(?:Men|Women)\s+(.+?)\s+on\s+\w').firstMatch(title);
    if (m1 != null) return _translateRound(m1.group(1)!.trim());
    // Dash-gender: "- M - ROUND" / "- W - ROUND"
    final m2 = RegExp(r'\s-\s[MW]\s-\s([^|]+)').firstMatch(title);
    if (m2 != null) return _translateRound(m2.group(1)!.trim());
    // Pipe format: "Teams | ROUND | Tournament"
    final pipes = title.split(' | ');
    if (pipes.length >= 2) {
      var round = pipes[1].trim();
      round = round.replaceAll(RegExp(r"\b(?:Men's|Women's)\s*"), '').trim();
      round = round.replaceAll(RegExp(r'\s*\([MW]\)\s*$'), '').trim();
      return _translateRound(round);
    }
    return '';
  }

  String _translateRound(String raw) {
    final l = raw.toLowerCase();
    if (l.contains('1st') || l.contains('gold')) return 'Final';
    if (l.contains('3rd') || l.contains('bronze')) return '3rd Place';
    if (l.contains('semi')) return 'Semifinal';
    if (l.contains('quarter')) return 'Quarterfinal';
    if (l.contains('final')) return 'Final';
    if (l.contains('round of 16')) return 'Round of 16';
    if (l.contains('pool')) return 'Pool Play';
    return raw;
  }

  String _parseTournament(String title) {
    // Three-part pipe format: "Teams | Round | Tournament"
    final pipes = title.split(' | ');
    if (pipes.length >= 3) {
      final t = pipes[2].trim();
      final replayIdx = t.lastIndexOf(' - Replay');
      return replayIdx > 0 ? t.substring(0, replayIdx).trim() : t;
    }
    // Fallback: single pipe "Teams | Tournament - Replay"
    final pipe = title.indexOf(' | ');
    if (pipe < 0) return '';
    final rest = title.substring(pipe + 3).trim();
    final end = rest.indexOf(' - Replay');
    return end > 0 ? rest.substring(0, end).trim() : rest;
  }


  String _shortTitle(String title) {
    final i = title.indexOf(' I ');
    if (i > 0) return title.substring(0, i);
    final j = title.indexOf(' | ');
    if (j > 0) return title.substring(0, j);
    return title;
  }

  Future<void> _loadTournamentList() async {
    try {
      // Beide Competition Groups PARALLEL fetchen (war vorher sequential)
      final cgPlaylistIds = <String>[];
      await Future.wait(_beachChannelGroupIds.map((cgId) async {
        try {
          final cgRes = await http.get(
            Uri.parse('https://zapp-5434-volleyball-tv.web.app/jw/media/$cgId'),
            headers: {'Origin': 'https://tv.volleyballworld.com'},
          ).timeout(const Duration(seconds: 8));
          if (cgRes.statusCode != 200) return;
          final cgData = jsonDecode(cgRes.body);
          final ps = cgData['entry']?[0]?['extensions']?['playlists'] as String? ?? '';
          cgPlaylistIds.addAll(ps.split(',').map((s) => s.trim()).where((s) => s.isNotEmpty));
        } catch (_) {}
      }));

      // Virtuelle + Laola1-Turniere immer anhängen
      final virtualEntries = _virtualTournamentData
          .map((vt) => {'id': vt['id'] as String, 'title': vt['title'] as String})
          .toList();
      final laolaFallbackEntries = AppVariant.vbtvOnly
          ? const <Map<String, String>>[]
          : _laolaTournamentData
              .map((lt) =>
                  {'id': lt['id'] as String, 'title': lt['title'] as String})
              .toList();

      if (cgPlaylistIds.isEmpty) {
        // Kein API-Ergebnis → sofort Laola1 + virtuelle Turniere zeigen
        final fallback = [...laolaFallbackEntries, ...virtualEntries];
        if (mounted) {
          setState(() {
            _availableTournaments = fallback;
            _currentPlaylistId = fallback.first['id']!;
          });
          _loadVideos(fallback.first['id']!);
        }
        return;
      }

      // Erste Playlist SOFORT laden, ohne auf Titel aller anderen zu warten
      final firstId = cgPlaylistIds.first;
      if (mounted) {
        setState(() {
          _availableTournaments = [{'id': firstId, 'title': '…'}, ...virtualEntries];
          _currentPlaylistId = firstId;
        });
        _loadVideos(firstId);
      }

      // Titel + match_date + competition_item des neuesten Items holen –
      // 3072 Bytes reichen sicher (match_date liegt bei ~1900-2000 Bytes;
      // TCP-Burst sendet ~14KB auf einmal, daher keine Ladezeit-Erhöhung
      // gegenüber 512 Bytes). Die ci dient als Dedup-Key gegen Bridge-
      // Tournaments und als Merge-Key für PRE_LIVE/LIVE-Spiele die VBW noch
      // nicht in die offizielle Playlist gehängt hat.
      Future<Map<String, String>?> fetchTitle(String id) async {
        try {
          final client = http.Client();
          final req = http.Request('GET',
              Uri.parse('https://zapp-5434-volleyball-tv.web.app/jw/playlists/$id'));
          req.headers['Origin'] = 'https://tv.volleyballworld.com';
          final streamed = await client.send(req).timeout(const Duration(seconds: 8));
          if (streamed.statusCode != 200) { client.close(); return null; }
          final buf = StringBuffer();
          await for (final chunk in streamed.stream) {
            buf.write(utf8.decode(chunk, allowMalformed: true));
            if (buf.length >= 3072) break;
          }
          client.close();
          final raw = buf.toString();
          final m = RegExp(r'"title"\s*:\s*"((?:[^"\\]|\\.)*)"').firstMatch(raw);
          if (m == null) return null;
          final title = jsonDecode('"${m.group(1)}"') as String;
          if (title.isEmpty) return null;
          final dm = RegExp(r'"match_date"\s*:\s*"(\d{4}-\d{2}-\d{2})').firstMatch(raw);
          final cim = RegExp(r'"competition_item"\s*:\s*"([A-Za-z0-9]+)"').firstMatch(raw);
          if (cim != null) _vbwPlaylistCi[id] = cim.group(1)!;
          return {
            'id': id,
            'title': title,
            if (dm != null) 'matchDate': dm.group(1)!,
            if (cim != null) 'ci': cim.group(1)!,
          };
        } catch (_) {
          return null;
        }
      }

      // Reguläre Turniere UND YouTube-Playlists parallel laden
      final realTournamentsF = Future.wait(cgPlaylistIds.map(fetchTitle))
          .then((r) => r.whereType<Map<String, String>>().toList());
      final youtubeTournamentsF = Future.wait(_youtubePlaylistIds.map((pid) async {
        final data = await _fetchYoutubePlaylist(pid);
        if (data == null) return null;
        _youtubeCache[pid] = data;
        return <String, String>{
          'id': '__yt_$pid',
          'title': data['title'] as String,
          'matchDate': data['sortDate'] as String,
        };
      })).then((r) => r.whereType<Map<String, String>>().toList());

      // Dynamische Laola1-Listen (HTML-Scrape) parallel laden – Tour Pro etc.
      // In der neutralen Variante komplett uebersprungen (siehe AppVariant).
      final laolaDynamicF = AppVariant.vbtvOnly
          ? Future.value(const <Map<String, String>>[])
          : Future.wait(_laolaDynamicPlaylists.map((config) async {
              final data = await _fetchLaolaList(config);
              if (data == null) return null;
              _laolaListCache[config['id']!] = data;
              return <String, String>{
                'id': config['id']!,
                'title': data['title'] as String,
                'matchDate': data['sortDate'] as String,
              };
            })).then((r) => r.whereType<Map<String, String>>().toList());

      // VBW-Bridge: Homepage nach Replays scrapen, die zu einem competition_item
      // gehören welches noch nicht durch eine offizielle Playlist abgedeckt
      // ist. Wartet auf realTournamentsF damit der ci-Set verfügbar ist —
      // verhindert Doppel-Einträge wie "BPT Elite Ostrava 2026" parallel zu
      // "Ostrava | Elite | 2026" wenn beide die gleiche competition_item haben.
      final vbwBridgeF = realTournamentsF.then((rts) {
        final knownCis =
            rts.map((m) => m['ci']).whereType<String>().toSet();
        return _fetchVbwBridgeTournaments(cgPlaylistIds.toSet(), knownCis);
      });

      // Laola1-Turniere: pro Tournament gegen /access/hls checken welche
      // Streams gerade live sind. Tournaments mit 0 verfügbaren Streams gar
      // nicht in die Liste aufnehmen. Cache wird in _loadVideos wiederverwendet.
      final laolaTournamentsF = AppVariant.vbtvOnly
          ? Future.value(const <Map<String, String>>[])
          : Future.wait(_laolaTournamentData.map((lt) async {
              final tournId = lt['id'] as String;
              final videos = (lt['videos'] as List).cast<Map<String, String>>();
              final ids = videos.map((v) => v['id']!).toList();
              final avail = await _fetchLaolaAvailability(ids);
              _laolaAvailCache[tournId] = avail;
              if (!avail.values.any((v) => v)) return null;
              return <String, String>{
                'id': tournId,
                'title': lt['title'] as String,
                'matchDate': lt['matchDate'] as String,
              };
            })).then((r) => r.whereType<Map<String, String>>().toList());

      final realTournaments = await realTournamentsF;
      final youtubeTournaments = await youtubeTournamentsF;
      final laolaDynamicTournaments = await laolaDynamicF;
      final laolaTournaments = await laolaTournamentsF;
      final vbwBridgeTournaments = await vbwBridgeF;
      // Twitch-GBT — Best-Effort. Wenn der GQL-Endpoint nicht antwortet
      // oder keine GBT-Videos da sind, wird das Turnier weggelassen (der
      // Service returned dann eine leere Liste).
      final twitchVideos = AppVariant.vbtvOnly
          ? const <Map<String, dynamic>>[]
          : await TwitchApi.fetchGbtVideos().catchError(
              (Object _) => const <Map<String, dynamic>>[]);
      final List<Map<String, String>> twitchTournaments = [];
      if (twitchVideos.isNotEmpty) {
        final latestDate = twitchVideos
            .map((v) => (v['matchDate'] as String?) ?? '')
            .where((d) => d.isNotEmpty)
            .fold<String>('', (a, b) => b.compareTo(a) > 0 ? b : a);
        twitchTournaments.add({
          'id': TwitchApi.tournamentId,
          'title': TwitchApi.tournamentTitle,
          'matchDate': latestDate.isNotEmpty ? latestDate : '',
        });
      }
      final results = [
        ...realTournaments,
        ...youtubeTournaments,
        ...laolaDynamicTournaments,
        ...laolaTournaments,
        ...vbwBridgeTournaments,
        ...twitchTournaments,
      ];

      // Sortierung: match_date des neuesten Videos (descending), Fallback: Jahr im Titel
      int titleYear(String t) {
        final m = RegExp(r'\b(20\d{2})\b').firstMatch(t);
        return m != null ? int.parse(m.group(1)!) : 0;
      }
      results.sort((a, b) {
        final da = a['matchDate'] ?? '';
        final db = b['matchDate'] ?? '';
        if (da.isNotEmpty && db.isNotEmpty) return db.compareTo(da);
        if (da.isNotEmpty) return -1;
        if (db.isNotEmpty) return 1;
        return titleYear(b['title']!).compareTo(titleYear(a['title']!));
      });

      results.addAll(virtualEntries);

      if (mounted) {
        final newFirst = results.first['id']!;
        // Reload nötig wenn (a) anderes Default-Turnier sortiert wurde
        // ODER (b) die aktuell geladene Playlist Bridge-Extras erhalten hat,
        // die beim First-Load (parallel zur Bridge gestartet) noch nicht im
        // Cache waren — sonst fehlen PRE_LIVE/LIVE-Spiele in der Liste.
        final currentCi = _vbwPlaylistCi[_currentPlaylistId];
        final hasNewBridgeExtras = currentCi != null &&
            (_vbwBridgeItems[currentCi]?.isNotEmpty ?? false);
        final needsReload =
            newFirst != _currentPlaylistId || hasNewBridgeExtras;
        setState(() {
          _availableTournaments = results;
          _currentPlaylistId = newFirst;
        });
        if (needsReload) {
          _videosLoadEpoch++;
          // Cache verwerfen damit Merge frisch durchläuft
          _videosCache.remove(newFirst);
          _loadVideos(newFirst);
        }
      }
    } catch (_) {} finally {
      if (mounted) setState(() => _isLoadingTournaments = false);
    }
  }

  static const _allId = '__all__';

  // YouTube-Playlists werden als eigene Turniere ohne API-Key via RSS-Feed geladen
  // (https://www.youtube.com/feeds/videos.xml?playlist_id=...). Klick öffnet YouTube App.
  static const List<String> _youtubePlaylistIds = [
    'PLQUMXo3n8RdbkhsBbZIJE2Xm9iwe7oHW6',
    'PLQUMXo3n8RdaxKFvodbdAEdF7RDz9g37O',
    'PLQUMXo3n8Rdbne15axkZXDNnksOVVE6CB',
    'PLQUMXo3n8RdaWp2OaQCbl_4HjzD7HyANE',
  ];

  // Cache der RSS-Ergebnisse (Title + Latest-Date + Entries)
  // Befüllt in _loadTournamentList, gelesen in _loadVideos.
  final Map<String, Map<String, dynamic>> _youtubeCache = {};

  // Cache der Laola-Stream-Verfügbarkeit pro Tournament: tournamentId →
  // (videoId → live). Befüllt in _loadTournamentList (für Tournament-Hide),
  // wiederverwendet in _loadVideos (für Video-Filter) damit nicht doppelt
  // gegen /access/hls gepostet wird.
  final Map<String, Map<String, bool>> _laolaAvailCache = {};

  // SWR-Cache für reguläre VBW-Playlists, virtuelle Turniere und __all__:
  // Cache-Hit zeigt die Liste sofort, dann läuft ein silent re-fetch im
  // Hintergrund. Externe Quellen (YouTube/Laola) haben ihren eigenen Cache.
  final Map<String, List<VideoItem>> _videosCache = {};

  // VBW-Bridge: laufende Turniere, die VBW noch nicht (vollständig) in die
  // Channel-Group-playlists eingehängt hat. Wir scrapen die Homepage und
  // gruppieren gefundene Media-IDs nach competition_item.
  //   • Orphan ci (kein offizielles Tournament): wird als __vbw_<ci> Eintrag
  //     in der Turnier-Dropdown sichtbar.
  //   • Bekanntes ci (offizielle Playlist existiert): Bridge-Items werden in
  //     die offizielle Playlist gemergt (typisch: PRE_LIVE/LIVE-Spiele die
  //     VBW erst nach Match-Start als VOD in die Playlist legt).
  // Befüllt in _loadTournamentList, gelesen in _loadVideos und _loadLiveAndUpcoming.
  final Map<String, List<VideoItem>> _vbwBridgeItems = {};
  // Mapping reguläre VBW-Playlist-ID → competition_item. Befüllt während
  // fetchTitle (parst aus den ersten 3KB der Playlist-Antwort). Lookup-Key
  // für den Bridge-Merge.
  final Map<String, String> _vbwPlaylistCi = {};

  // VBW Channel Groups, die diese App zeigt. Beide sind Beach Pro Tour —
  // alles andere (VNL Halle, Champions League, World Champs Halle) wird
  // vom Bridge-Filter ignoriert.
  static const Set<String> _beachChannelGroupIds = {'aBT42rPR', 'rkwGm18m'};

  /// Zusaetzliche VBW-Feeds fuer den Bridge-Scrape. Sie haengen NICHT in den
  /// Channel-Group-playlists, sind aber auf
  /// https://tv.volleyballworld.com/competition-groups/aBT42rPR verlinkt.
  ///
  /// Warum die noetig sind: VBW legt die Turnier-Playlist ("Rio de Janeiro I
  /// Elite I 2026") erst NACH dem Turnier an. Solange es laeuft, stehen die
  /// bereits gespielten Matches ausschliesslich in "Latest Replays" — die
  /// Homepage zeigt nur kommende Spiele. Ohne diese Feeds war ein laufendes
  /// Turnier in der App komplett leer.
  static const List<String> _vbwExtraFeeds = [
    'jyMbcJFi', // Latest Replays — VOD_PUBLIC/INSTANT_VOD, alle Sportarten
    'BqFYBy9b', // Beach Pro Tour — PRE_LIVE/LIVE, nur Beach
  ];

  /// Der Endpoint liefert ohne page_limit nur 10 Entries. 300 deckt ein
  /// komplettes Elite-Turnier (~120 Matches) plus Nachbarturniere ab und
  /// kostet ~650 KB; 500 waere 1 MB fuer neun weitere Matches.
  static const int _vbwExtraFeedLimit = 300;

  // Dynamische Laola1-Listen: URL → Cache der gefetchten Videos. Wird in
  // _loadTournamentList befüllt (parallel zu YouTube + VBW) und in _loadVideos
  // gelesen. So bleiben die Listen auch nach Neustart aktuell.
  static const List<Map<String, String>> _laolaDynamicPlaylists = [
    {
      'id': '__laola_tour_pro__',
      'title': 'win2day Beach Volleyball Tour Pro',
      'baseUrl':
          'https://www.laola1.at/de/daten/videos/beachvolleyball/win2day-beachvolleyball-tour-pro/',
      'pages': '4',
    },
  ];
  final Map<String, Map<String, dynamic>> _laolaListCache = {};

  Future<Map<String, dynamic>?> _fetchLaolaList(
      Map<String, String> config) async {
    final baseUrl = config['baseUrl']!;
    final pages = int.tryParse(config['pages'] ?? '1') ?? 1;
    try {
      // Pages parallel fetchen damit's nicht 4× nacheinander dauert.
      final pageBodies = await Future.wait(List.generate(pages, (i) async {
        final url = i == 0 ? baseUrl : '$baseUrl?page=${i + 1}';
        try {
          final res = await http
              .get(Uri.parse(url), headers: {'User-Agent': 'Mozilla/5.0'})
              .timeout(const Duration(seconds: 10));
          return res.statusCode == 200 ? res.body : '';
        } catch (_) {
          return '';
        }
      }));

      final entries = <Map<String, String>>[];
      final seen = <String>{};
      // <a href=".../de/video/player/{id}/{slug}" class="t-big">
      //   <picture><img src="{thumb}?v=YYYYMMDD..." alt="{title}">
      final pattern = RegExp(
        r'<a href="https://www\.laola1\.at/de/video/player/(\d+)[^"]*"[^>]*class="t-big"[^>]*>\s*<picture[^>]*>\s*<img\s+src="([^"]+)"[^>]*alt="([^"]*)"',
        dotAll: true,
      );
      String latestDate = '';
      for (final body in pageBodies) {
        if (body.isEmpty) continue;
        for (final m in pattern.allMatches(body)) {
          final id = m.group(1)!;
          if (!seen.add(id)) continue;
          final thumb = m.group(2)!;
          final title = _decodeHtml(m.group(3)!).trim();
          final dateMatch =
              RegExp(r'\?v=(\d{4})(\d{2})(\d{2})').firstMatch(thumb);
          final dateStr = dateMatch != null
              ? '${dateMatch.group(1)}-${dateMatch.group(2)}-${dateMatch.group(3)}'
              : '';
          if (dateStr.isNotEmpty &&
              (latestDate.isEmpty || dateStr.compareTo(latestDate) > 0)) {
            latestDate = dateStr;
          }
          entries.add({
            'videoId': id,
            'title': title,
            'thumbnail': thumb,
            'date': dateStr,
            'url': 'https://www.laola1.at/de/video/player/$id',
          });
        }
      }

      if (entries.isEmpty) return null;
      // Neueste zuerst — Laola listet schon so, aber sicherstellen.
      entries.sort((a, b) => (b['date'] ?? '').compareTo(a['date'] ?? ''));

      return {
        'id': config['id']!,
        'title': config['title']!,
        'sortDate': latestDate,
        'entries': entries,
      };
    } catch (_) {
      return null;
    }
  }

  /// Sucht VBW-Items, die noch nicht (vollständig) in den Channel-Group-
  /// playlists gelistet sind. Wir scrapen die Homepage, holen Metadata pro
  /// Media-ID, parsen in VideoItems und gruppieren nach `competition_item`.
  ///
  /// Cache-Befüllung (immer): `_vbwBridgeItems[ci]` — wird von `_loadVideos`
  /// zum Mergen in offizielle Playlists und vom Bridge-Branch direkt genutzt.
  ///
  /// Rückgabe (nur orphans): Tournaments für ci's, die weder als playlist-id
  /// in `knownPlaylistIds` noch als competition_item in `knownCompetitionItems`
  /// schon abgedeckt sind. Verhindert doppelte Einträge wie z.B. "BPT Elite
  /// Ostrava 2026" (Bridge) parallel zu "Ostrava I Elite I 2026" (offiziell).
  Future<List<Map<String, String>>> _fetchVbwBridgeTournaments(
      Set<String> knownPlaylistIds, Set<String> knownCompetitionItems) async {
    try {
      // Alle gefundenen Entries, dedupliziert ueber die Media-ID. Gespeist aus
      // zwei Quellen: Homepage-Scrape (unten) und den Extra-Feeds.
      final entriesById = <String, Map<String, dynamic>>{};

      // ── Quelle 1: Extra-Feeds ────────────────────────────────────────────
      // Diese Feeds liefern Entries INKLUSIVE competition_group_item und
      // competition_item — ein Request statt hunderter /jw/media-Aufrufe.
      // Ohne sie fehlen die bereits gespielten Matches eines LAUFENDEN
      // Turniers komplett: VBW legt die Turnier-Playlist ("Rio de Janeiro I
      // Elite I 2026") erst NACH dem Turnier an, und die Homepage zeigt nur
      // das Upcoming-Karussell.
      await Future.wait(_vbwExtraFeeds.map((fid) async {
        try {
          final res = await http.get(
            Uri.parse('https://zapp-5434-volleyball-tv.web.app/jw/playlists/'
                '$fid?page_limit=$_vbwExtraFeedLimit'),
            headers: {'Origin': 'https://tv.volleyballworld.com'},
          ).timeout(const Duration(seconds: 12));
          if (res.statusCode != 200) return;
          final list = jsonDecode(res.body)['entry'] as List? ?? [];
          for (final raw in list) {
            if (raw is! Map<String, dynamic>) continue;
            final ext = raw['extensions'] as Map<String, dynamic>? ?? {};
            // Beach-Filter: "Latest Replays" mischt VNL/Halle mit rein.
            if (!_beachChannelGroupIds
                .contains(ext['competition_group_item'])) {
              continue;
            }
            final mid = raw['id'] as String?;
            if (mid == null || ext['competition_item'] == null) continue;
            entriesById[mid] = raw;
          }
        } catch (_) {}
      }));

      // ── Quelle 2: Homepage-Scrape ────────────────────────────────────────
      // Faengt Items ab, die (noch) in keinem der Extra-Feeds stehen.
      // Darf fehlschlagen ohne die Feed-Ausbeute mitzureissen.
      final homeRes = await http.get(
        Uri.parse('https://tv.volleyballworld.com/'),
        headers: {'User-Agent': 'Mozilla/5.0'},
      ).timeout(const Duration(seconds: 8)).catchError(
          (_) => http.Response('', 599));
      // VBW nutzt zwei Link-Formate auf der Homepage:
      //   altes: jw%2Fmedia%2F<id>?... (URL-encoded self-link)
      //   neues: /media/<id>?disablePlayNext=... (Klar-Pfad, seit ~Mai 2026)
      // Poster-URLs (/media/<id>/poster.jpg) dürfen NICHT matchen — Anker auf
      // "?disablePlayNext" verhindert das.
      final ids = homeRes.statusCode != 200
          ? const <String>[]
          : <String>{
              ...RegExp(r'jw%2Fmedia%2F([A-Za-z0-9]+)')
                  .allMatches(homeRes.body)
                  .map((m) => m.group(1)!),
              ...RegExp(r'/media/([A-Za-z0-9]+)\?disablePlayNext')
                  .allMatches(homeRes.body)
                  .map((m) => m.group(1)!),
            }.where((id) => !entriesById.containsKey(id)).toList();

      // Metadata pro ID parallel holen — wir behalten das ganze Entry damit
      // _itemFromJson direkt VideoItems daraus baut. Limit 4s pro Request.
      // Beach-Filter: nur Items deren competition_group_item in unseren
      // bekannten Beach Channel Groups liegt (aBT42rPR/rkwGm18m). Sonst
      // landen auch VNL/Champions-League/Halle-Spiele in der Liste, die
      // diese App nicht zeigen soll.
      final metas = await Future.wait(ids.map((id) async {
        try {
          final res = await http.get(
            Uri.parse(
                'https://zapp-5434-volleyball-tv.web.app/jw/media/$id'),
            headers: {'Origin': 'https://tv.volleyballworld.com'},
          ).timeout(const Duration(seconds: 4));
          if (res.statusCode != 200) return null;
          final entry = (jsonDecode(res.body)['entry'] as List?)
                  ?.cast<Map<String, dynamic>>()
                  .firstOrNull;
          if (entry == null) return null;
          final ext = entry['extensions'] as Map<String, dynamic>? ?? {};
          final cgi = ext['competition_group_item'] as String?;
          if (cgi == null || !_beachChannelGroupIds.contains(cgi)) return null;
          final ci = ext['competition_item'] as String?;
          if (ci == null) return null;
          return {'ci': ci, 'entry': entry};
        } catch (_) {
          return null;
        }
      }));

      for (final m in metas) {
        if (m == null) continue;
        final entry = m['entry'] as Map<String, dynamic>;
        final mid = entry['id'] as String?;
        if (mid != null) entriesById[mid] = entry;
      }

      // Gruppieren nach competition_item — wir cachen ALLE ci's (auch die mit
      // bekannter Playlist), damit _loadVideos sie in die offizielle Playlist
      // mergen kann. Nur die Turnier-Auflistung filtert orphans.
      final groups = <String, List<Map<String, dynamic>>>{};
      for (final entry in entriesById.values) {
        final ci = (entry['extensions'] as Map<String, dynamic>?)?['competition_item']
            as String?;
        if (ci == null) continue;
        groups.putIfAbsent(ci, () => []).add(entry);
      }
      if (groups.isEmpty) return [];

      // Cache füllen: alle ci's bekommen ihre VideoItems in _vbwBridgeItems.
      for (final entry in groups.entries) {
        _vbwBridgeItems[entry.key] =
            entry.value.map(_itemFromJson).toList(growable: false);
      }

      // Tournament-Einträge NUR für ci's bauen, die noch nicht über eine
      // offizielle Playlist abgedeckt sind. knownPlaylistIds enthält die
      // Playlist-IDs aus der Channel Group; knownCompetitionItems enthält die
      // ci's der bereits geladenen Playlists (extrahiert in fetchTitle).
      //
      // Zusaetzlich muss mindestens EIN Item tatsaechlich abspielbar sein.
      // _filteredVideos blendet reine Zukunfts-Matches aus (v.isLive ||
      // !v.isUpcoming) — ein Turnier das ausschliesslich aus angesetzten
      // Spielen besteht (z.B. Hamburg mit Anpfiff in vier Tagen) waere sonst
      // ein Dropdown-Eintrag, der garantiert eine leere Liste zeigt.
      final orphanCis = groups.entries.where((e) =>
          !knownPlaylistIds.contains(e.key) &&
          !knownCompetitionItems.contains(e.key) &&
          (_vbwBridgeItems[e.key] ?? const <VideoItem>[])
              .any((v) => v.isLive || !v.isUpcoming));

      final result = await Future.wait(orphanCis.map((entry) async {
        final ci = entry.key;
        final items = entry.value;
        String? title;
        try {
          final res = await http.get(
            Uri.parse(
                'https://zapp-5434-volleyball-tv.web.app/jw/media/$ci'),
            headers: {'Origin': 'https://tv.volleyballworld.com'},
          ).timeout(const Duration(seconds: 4));
          if (res.statusCode == 200) {
            final e = (jsonDecode(res.body)['entry'] as List?)?.firstOrNull;
            title = e?['title'] as String?;
          }
        } catch (_) {}
        if (title == null || title.isEmpty) return null;

        // Neuestes match_date als Sortier-Datum (für Dropdown-Reihenfolge).
        String matchDate = '';
        for (final i in items) {
          final d = (i['extensions']?['match_date'] as String? ?? '')
              .split('T')
              .first;
          if (d.compareTo(matchDate) > 0) matchDate = d;
        }

        return <String, String>{
          'id': '__vbw_$ci',
          'title': title,
          'matchDate': matchDate,
        };
      }));
      return result.whereType<Map<String, String>>().toList();
    } catch (_) {
      return [];
    }
  }

  /// Prüft für jede Laola-Content-ID den HLS-Access-Endpoint per POST. Das
  /// Schedule (autoBroadcast/autoOffline) ist nicht immer akkurat — der
  /// /access/hls-Endpoint liefert dagegen direkt:
  ///   200 = Stream gerade live + URL
  ///   400 = noch nicht / nicht mehr verfügbar
  /// Bei 400 wird der Stream rausgefiltert. Bei Netz-Fehler oder anderem
  /// HTTP-Status → default true (lieber zeigen + User klickt, als guten
  /// Content versehentlich verbergen).
  Future<Map<String, bool>> _fetchLaolaAvailability(List<String> ids) async {
    final results = await Future.wait(ids.map((id) async {
      try {
        final res = await http.post(
          Uri.parse('https://video.laola1.at/api/v3/contents/$id/access/hls'),
          headers: {
            'User-Agent': 'Mozilla/5.0',
            'Referer': 'https://www.laola1.at/',
            'Origin': 'https://www.laola1.at',
          },
        ).timeout(const Duration(seconds: 4));
        final live = res.statusCode != 400;
        debugPrint('[laola-avail] $id POST /access/hls → ${res.statusCode} '
            '(live=$live)');
        return MapEntry(id, live);
      } catch (e) {
        debugPrint('[laola-avail] $id failed: $e — defaulting to visible');
        return MapEntry(id, true);
      }
    }));
    return Map.fromEntries(results);
  }

  static String _decodeHtml(String s) {
    return s
        .replaceAll('&amp;', '&')
        .replaceAll('&lt;', '<')
        .replaceAll('&gt;', '>')
        .replaceAll('&quot;', '"')
        .replaceAll('&#39;', "'")
        .replaceAll('&auml;', 'ä')
        .replaceAll('&ouml;', 'ö')
        .replaceAll('&uuml;', 'ü')
        .replaceAll('&Auml;', 'Ä')
        .replaceAll('&Ouml;', 'Ö')
        .replaceAll('&Uuml;', 'Ü')
        .replaceAll('&szlig;', 'ß');
  }

  static String _decodeXmlEntities(String s) {
    return s
        .replaceAll('&amp;', '&')
        .replaceAll('&lt;', '<')
        .replaceAll('&gt;', '>')
        .replaceAll('&quot;', '"')
        .replaceAll('&#39;', "'");
  }

  Future<Map<String, dynamic>?> _fetchYoutubePlaylist(String playlistId) async {
    try {
      final res = await http
          .get(Uri.parse('https://www.youtube.com/feeds/videos.xml?playlist_id=$playlistId'))
          .timeout(const Duration(seconds: 8));
      if (res.statusCode != 200) return null;
      final body = res.body;

      // Playlist-Titel: erstes <title> AUSSERHALB einer <entry>
      final feedTitleMatch =
          RegExp(r'</yt:channelId>\s*<title>([^<]*)</title>', dotAll: true).firstMatch(body);
      final playlistTitle = _decodeXmlEntities(feedTitleMatch?.group(1)?.trim() ?? 'YouTube');

      final entries = <Map<String, String>>[];
      final entryPattern = RegExp(
        r'<entry>.*?<yt:videoId>([^<]+)</yt:videoId>.*?<title>([^<]+)</title>.*?<published>([^<]+)</published>.*?<media:thumbnail\s+url="([^"]+)"',
        dotAll: true,
      );
      for (final m in entryPattern.allMatches(body)) {
        entries.add({
          'videoId': m.group(1)!,
          'title': _decodeXmlEntities(m.group(2)!),
          'published': m.group(3)!,
          'thumbnail': m.group(4)!,
        });
      }

      String sortDate = '';
      if (entries.isNotEmpty) {
        final pub = entries.first['published'] ?? '';
        sortDate = pub.length >= 10 ? pub.substring(0, 10) : '';
      }

      return {
        'playlistId': playlistId,
        'title': playlistTitle,
        'sortDate': sortDate,
        'entries': entries,
      };
    } catch (_) {
      return null;
    }
  }

  // Laola1.at-Turniere: externer Stream, klick öffnet Browser/App.
  // Jeder Court ist ein eigenes "Video" innerhalb des Turniers.
  static const List<Map<String, Object>> _laolaTournamentData = [
    {
      'id': '__laola_innsbruck_2026__',
      'title': 'Pro Masters Innsbruck 2026',
      'matchDate': '2026-06-06',
      'tournament': 'win2day PRO MASTERS Innsbruck',
      'videos': [
        {
          'id': '2173012',
          'title': 'Center Court',
          'url': 'https://www.laola1.at/de/video/player/2173012',
          'thumbnail': '',
        },
        {
          'id': '2173014',
          'title': 'Court 2',
          'url': 'https://www.laola1.at/de/video/player/2173014',
          'thumbnail': '',
        },
      ],
    },
    {
      'id': '__laola_poertschach_2026__',
      'title': 'Pro Masters Pörtschach 2026',
      'matchDate': '2026-05-24',
      'tournament': 'win2day PRO MASTERS Pörtschach',
      'videos': [
        {
          'id': '2166464',
          'title': 'Center Court (2)',
          'url': 'https://www.laola1.at/de/video/player/2166464',
          'thumbnail':
              'https://video.laola1.at/image/800x450/a23abc46-642b-4c83-a48d-0dd1c4939841.jpg',
        },
        {
          'id': '2166465',
          'title': 'Court 2 (2)',
          'url': 'https://www.laola1.at/de/video/player/2166465',
          'thumbnail':
              'https://video.laola1.at/image/800x450/48173962-5ca9-4d5a-aa95-b3955e960881.jpg',
        },
        // Filtering passiert dynamisch in _loadVideos über _fetchLaolaAvailability
        // (Laola-API liefert autoBroadcast / autoOffline-Fenster).
        {
          'id': '2166466',
          'title': 'Center Court (3)',
          'url': 'https://www.laola1.at/de/video/player/2166466',
          'thumbnail':
              'https://video.laola1.at/image/800x450/d5306f03-26a8-4942-93b1-aae809ef6af7.jpg',
        },
        {
          'id': '2166467',
          'title': 'Medaillen-Entscheidung',
          'url': 'https://www.laola1.at/de/video/player/2166467',
          'thumbnail':
              'https://video.laola1.at/image/800x450/7706cdb5-120e-4cde-8319-929d81bbf7cc.jpg',
        },
      ],
    },
  ];

  static const List<Map<String, Object>> _virtualTournamentData = [
    {
      'id': '__vienna_2024__',
      'title': 'Vienna Major 2024',
      'mediaIds': ['4RG6E1wA', 'n6NDlmCj', 'XQVdmpFC', 'laCkprbO', 'FLZtiJ9Z',
        '8li0jBJe', '5JOX9Zpz', 'BOWRuzeN', 'VywVMOqw', 'd1NqbjrE',
        'ZpN2Vhnw', 'IRVhVQ2t', 'DCFk0ZYf', 'UVvmO0r9', '5FZAHSsV',
        '8XUQvIE3', 'ogri3G7h', 'RxqdUmDp', 'usMGFmN4', 'wD1zmqgb',
        'wtj3USLB', 'N8vHjvMY', 'TTVKq5tB', '2fX2rQ2A', 't3vVHMOk'],
    },
    {
      'id': '__gstaad_2024__',
      'title': 'Gstaad Elite 16 2024',
      'mediaIds': ['l0qOShMO', 'I1koTibO', 'iNbKD4di', 'tFFKBGyC', 'fh12jyMp',
        'Q4fhGHXb', 'n9lNrdhv', '3BKffIP4', 'uJAbnTbv', 'JsNjX9k3',
        'kC9a5m0F', 'czsKhte7', 'B8DJejXV', 'NTfMsa0g', 'AAuLHsCf',
        'xgYZIIL6', '9OR1dC3f', 'rF0dKawq', 'uo94x2LN', 'ldSojZLA',
        '4HeH8h2G', 'fUKcEDwH', 'qqoXMRUo', 'mnLEAed6', 'qL5OiaNx'],
    },
  ];

  VideoItem _itemFromJson(dynamic item) {
    final title = item['title'] as String? ?? '';
    final dateStr = item['extensions']?['match_date'] as String?
        ?? item['extensions']?['scheduled_start'] as String?;
    final endStr = item['extensions']?['scheduled_end'] as String?;
    final eventState = item['extensions']?['event_state'] as String? ?? 'VOD_PUBLIC';
    final contentType = item['extensions']?['contentType'] as String?;
    final rawLink = item['extensions']?['linkUrl'] as String?;
    final linkUrl = contentType == 'link' ? rawLink : null;
    return VideoItem(
      id: item['id'] ?? '',
      title: title,
      teams: _parseTeams(title),
      gender: _parseGender(title),
      round: _parseRound(title),
      tournament: _parseTournament(title),
      thumbnailUrl: _extractThumbnail(item),
      duration: item['extensions']?['duration'] ?? 0,
      matchDate: dateStr != null ? DateTime.tryParse(dateStr) : null,
      eventState: eventState,
      scheduledEnd: endStr != null ? DateTime.tryParse(endStr) : null,
      linkUrl: linkUrl,
    );
  }

  Future<List<VideoItem>> _loadVirtualTournament(Map<String, Object> vtData) async {
    final ctx = _buildCtx();
    final mediaIds = vtData['mediaIds'] as List<Object?>;
    final futures = mediaIds.map((mid) async {
      try {
        final res = await http.get(
          Uri.parse('https://zapp-5434-volleyball-tv.web.app/jw/media/$mid?ctx=$ctx'),
          headers: {'Origin': 'https://tv.volleyballworld.com'},
        ).timeout(const Duration(seconds: 8));
        if (res.statusCode == 200) {
          final data = jsonDecode(res.body);
          final entries = data['entry'] as List? ?? [];
          if (entries.isNotEmpty) return _itemFromJson(entries.first);
        }
      } catch (_) {}
      return null;
    });
    return (await Future.wait(futures)).whereType<VideoItem>().toList();
  }

  /// Sammelt VideoItems aus ALLEN bekannten Laola-Turnieren (hardcoded
  /// Fallback + gescrapte Live-Courts + dynamische Tour-Pro-Replay-Liste)
  /// fuer die "Alle Turniere"-Aggregation. Best-effort: Fehler pro Turnier
  /// werden verschluckt, ein kaputter Endpoint darf die restlichen
  /// Quellen nicht mitreissen.
  Future<List<VideoItem>> _allLaolaVideoItemsForAggregate() async {
    final out = <VideoItem>[];

    final liveTournaments = [..._laolaTournamentData, ..._scrapedLaolaTournaments];
    for (final lt in liveTournaments) {
      try {
        final tournamentName = lt['tournament'] as String? ?? '';
        final dateStr = lt['matchDate'] as String?;
        final date = dateStr != null ? DateTime.tryParse(dateStr) : null;
        final allEntries = (lt['videos'] as List).cast<Map<String, String>>();
        final tid = lt['id'] as String;
        final availability = _laolaAvailCache[tid] ??
            await _fetchLaolaAvailability(allEntries.map((e) => e['id']!).toList());
        _laolaAvailCache[tid] = availability;
        for (final e in allEntries.where((e) => availability[e['id']] ?? true)) {
          out.add(VideoItem(
            id: e['id']!,
            title: e['title']!,
            teams: e['title']!,
            gender: '',
            round: '',
            tournament: tournamentName,
            thumbnailUrl: e['thumbnail'] ?? '',
            duration: 0,
            matchDate: date,
            eventState: 'LIVE',
            scheduledEnd: null,
            linkUrl: e['url'],
          ));
        }
      } catch (_) {}
    }

    for (final config in _laolaDynamicPlaylists) {
      try {
        final cid = config['id']!;
        final data = _laolaListCache[cid] ?? await _fetchLaolaList(config);
        if (data == null) continue;
        _laolaListCache[cid] = data;
        final tournamentName = data['title'] as String;
        final entries = (data['entries'] as List).cast<Map<String, String>>();
        for (final e in entries) {
          final dateStr = e['date'] ?? '';
          out.add(VideoItem(
            id: e['videoId']!,
            title: e['title']!,
            teams: e['title']!,
            gender: '',
            round: '',
            tournament: tournamentName,
            thumbnailUrl: e['thumbnail'] ?? '',
            duration: 0,
            matchDate: dateStr.isNotEmpty ? DateTime.tryParse(dateStr) : null,
            eventState: 'VOD_PUBLIC',
            scheduledEnd: null,
            linkUrl: e['url'],
          ));
        }
      } catch (_) {}
    }
    return out;
  }

  /// Wie oben, fuer Twitch/GBT — mappt TwitchApi.fetchGbtVideos() auf
  /// VideoItem (gleiche Mapping-Logik wie im dedizierten Twitch-
  /// Tournament-Branch in _loadVideos).
  Future<List<VideoItem>> _allTwitchVideoItemsForAggregate() async {
    try {
      final entries = await TwitchApi.fetchGbtVideos();
      return entries.map((e) {
        final dateStr = (e['matchDate'] as String?) ?? '';
        final duration = (e['duration'] is int)
            ? (e['duration'] as int)
            : int.tryParse(e['duration']?.toString() ?? '') ?? 0;
        return VideoItem(
          id: (e['id'] as String?) ?? '',
          title: (e['title'] as String?) ?? '',
          teams: (e['title'] as String?) ?? '',
          gender: '',
          round: '',
          tournament: (e['tournament'] as String?) ?? TwitchApi.tournamentTitle,
          thumbnailUrl: (e['thumbnail'] as String?) ?? '',
          duration: duration,
          matchDate: dateStr.isNotEmpty ? DateTime.tryParse(dateStr) : null,
          eventState: (e['isLive'] == true) ? 'LIVE' : 'VOD_PUBLIC',
          scheduledEnd: null,
          linkUrl: 'twitch:${e['id']}',
        );
      }).toList();
    } catch (_) {
      return const <VideoItem>[];
    }
  }

  Future<void> _loadVideos([
    String? playlistId,
    bool silent = false,
    bool forceRefresh = false,
  ]) async {
    final pid = playlistId ?? _currentPlaylistId;
    final epoch = _videosLoadEpoch;
    if (playlistId != null && mounted) setState(() { _currentPlaylistId = pid; });

    // Stale-while-revalidate: bei Cache-Hit sofort zeigen + im Hintergrund
    // refreshen. Externe Quellen (YouTube/Laola/Twitch) bringen eigenen
    // Cache mit und sind hier ausgeschlossen.
    final isExternalSource = pid.startsWith('__yt_') ||
        pid.startsWith('__laola_') ||
        TwitchApi.isTwitchTournamentId(pid);
    final cached = _videosCache[pid];
    if (!forceRefresh && !isExternalSource && cached != null) {
      if (mounted) {
        setState(() {
          _videos = cached;
          _isLoading = false;
          _errorMessage = null;
        });
      }
      silent = true;
    }

    if (!silent) setState(() { _isLoading = true; _errorMessage = null; });
    try {
      // Twitch-GBT: Videos kommen aus dem TwitchApi-GQL-Cache. Kein
      // Merge mit VBW/Laola — die Twitch-Videos haben keine gender/round.
      if (TwitchApi.isTwitchTournamentId(pid)) {
        final entries = await TwitchApi.fetchGbtVideos(force: forceRefresh);
        final videos = entries.map((e) {
          final dateStr = (e['matchDate'] as String?) ?? '';
          final duration = (e['duration'] is int)
              ? (e['duration'] as int)
              : int.tryParse(e['duration']?.toString() ?? '') ?? 0;
          return VideoItem(
            id: (e['id'] as String?) ?? '',
            title: (e['title'] as String?) ?? '',
            teams: (e['title'] as String?) ?? '',
            gender: '',
            round: '',
            tournament: (e['tournament'] as String?) ?? TwitchApi.tournamentTitle,
            thumbnailUrl: (e['thumbnail'] as String?) ?? '',
            duration: duration,
            matchDate: dateStr.isNotEmpty ? DateTime.tryParse(dateStr) : null,
            eventState: (e['isLive'] == true) ? 'LIVE' : 'VOD_PUBLIC',
            scheduledEnd: null,
            // Praefix "twitch:" identifiziert Twitch-Videos in _openVideo
            // ohne dass wir das Datenmodell aendern muessten.
            linkUrl: 'twitch:${e['id']}',
          );
        }).toList();
        if (_videosLoadEpoch == epoch && mounted) {
          setState(() {
            _videos = videos;
            _isLoading = false;
            _errorMessage = null;
          });
        }
        return;
      }
      // Laola1-Turnier: Liste mit hardcoded URLs/Thumbnails, kein API-Call.
      if (pid.startsWith('__laola_')) {
        // Dynamische Laola-Liste (z.B. Tour Pro) – Cache wurde in
        // _loadTournamentList befüllt; fallback: jetzt fetchen.
        final dynConfig = _laolaDynamicPlaylists
            .firstWhere((c) => c['id'] == pid, orElse: () => const {});
        if (dynConfig.isNotEmpty) {
          Map<String, dynamic>? data = _laolaListCache[pid];
          data ??= await _fetchLaolaList(dynConfig);
          if (data != null) {
            _laolaListCache[pid] = data;
            final tournamentName = data['title'] as String;
            final entries = (data['entries'] as List).cast<Map<String, String>>();
            final videos = entries.map((e) {
              final dateStr = e['date'] ?? '';
              return VideoItem(
                id: e['videoId']!,
                title: e['title']!,
                teams: e['title']!,
                gender: '',
                round: '',
                tournament: tournamentName,
                thumbnailUrl: e['thumbnail'] ?? '',
                duration: 0,
                matchDate: dateStr.isNotEmpty ? DateTime.tryParse(dateStr) : null,
                eventState: 'VOD_PUBLIC',
                scheduledEnd: null,
                linkUrl: e['url'],
              );
            }).toList();
            if (_videosLoadEpoch == epoch && mounted) {
              setState(() => _videos = videos);
            }
          }
          return;
        }

        // Lookup gegen hardcoded Tabelle UND gegen die zur Laufzeit
        // gescrapten Eintraege aus LaolaLivestreamScraper.
        final ltData = [..._laolaTournamentData, ..._scrapedLaolaTournaments]
            .firstWhere((t) => t['id'] == pid, orElse: () => const {});
        if (ltData.isNotEmpty) {
          final tournamentName = ltData['tournament'] as String? ?? '';
          final dateStr = ltData['matchDate'] as String?;
          final date = dateStr != null ? DateTime.tryParse(dateStr) : null;
          final allEntries =
              (ltData['videos'] as List).cast<Map<String, String>>();
          // Per-Stream Verfügbarkeit (POST /access/hls): wenn der Tournament-
          // List-Load das gerade gemacht hat, kommt's aus dem Cache. Sonst
          // jetzt fetchen (z.B. wenn der User direkt zu diesem Tournament
          // springt ohne dass _loadTournamentList neu lief).
          final availability = _laolaAvailCache[pid] ??
              await _fetchLaolaAvailability(
                  allEntries.map((e) => e['id']!).toList());
          _laolaAvailCache[pid] = availability;
          final entries =
              allEntries.where((e) => availability[e['id']] ?? true).toList();
          final videos = entries.map((e) {
            return VideoItem(
              id: e['id']!,
              title: e['title']!,
              teams: e['title']!,
              gender: '',
              round: '',
              tournament: tournamentName,
              thumbnailUrl: e['thumbnail'] ?? '',
              duration: 0,
              matchDate: date,
              // LIVE statt VOD_PUBLIC — availability kommt aus /access/hls
              // und filtert bereits auf gerade laufende Courts, das sind
              // also per Definition Live-Streams (kein Replay-Archiv wie
              // bei der dynamischen Tour-Pro-Liste). Vorher war das hart
              // auf VOD_PUBLIC gesetzt → isLive war nie true, kein
              // LIVE-Badge auf der Kachel.
              eventState: 'LIVE',
              scheduledEnd: null,
              linkUrl: e['url'],
            );
          }).toList();
          if (_videosLoadEpoch == epoch && mounted) {
            setState(() => _videos = videos);
          }
        }
        return;
      }

      // YouTube-Playlist
      if (pid.startsWith('__yt_')) {
        final ytPid = pid.substring('__yt_'.length);
        Map<String, dynamic>? data = _youtubeCache[ytPid];
        data ??= await _fetchYoutubePlaylist(ytPid);
        if (data != null) {
          _youtubeCache[ytPid] = data;
          final entries = (data['entries'] as List).cast<Map<String, String>>();
          final videos = entries.map((e) {
            final title = e['title'] ?? '';
            final publishedStr = e['published'] ?? '';
            return VideoItem(
              id: e['videoId']!,
              title: title,
              teams: _parseTeams(title),
              gender: _parseGender(title),
              round: _parseRound(title),
              tournament: _parseTournament(title),
              thumbnailUrl: e['thumbnail'] ?? '',
              duration: 0,
              matchDate: DateTime.tryParse(publishedStr),
              eventState: 'VOD_PUBLIC',
              scheduledEnd: null,
              linkUrl: 'https://www.youtube.com/watch?v=${e['videoId']}&list=$ytPid',
            );
          }).toList()
            ..sort((a, b) {
              if (a.matchDate == null) return 1;
              if (b.matchDate == null) return -1;
              return b.matchDate!.compareTo(a.matchDate!);
            });
          if (_videosLoadEpoch == epoch && mounted) setState(() => _videos = videos);
        }
        return;
      }

      // VBW-Bridge: VideoItems wurden beim Bridge-Scrape schon geparst und
      // gecached — kein zusätzliches Netzwerk nötig.
      if (pid.startsWith('__vbw_')) {
        final ci = pid.substring('__vbw_'.length);
        final cached = _vbwBridgeItems[ci];
        if (cached != null && cached.isNotEmpty) {
          final videos = [...cached]..sort((a, b) {
              if (a.matchDate == null) return 1;
              if (b.matchDate == null) return -1;
              return b.matchDate!.compareTo(a.matchDate!);
            });
          _videosCache[pid] = videos;
          if (_videosLoadEpoch == epoch && mounted) {
            setState(() => _videos = videos);
          }
        }
        return;
      }

      // Virtuelles Turnier (einzelne Media-IDs)
      if (pid.startsWith('__') && pid != _allId) {
        final vtData = _virtualTournamentData.cast<Map<String, Object>>()
            .firstWhere((v) => v['id'] == pid, orElse: () => const {});
        if (vtData.isNotEmpty) {
          final videos = await _loadVirtualTournament(vtData)
            ..sort((a, b) {
              if (a.matchDate == null) return 1;
              if (b.matchDate == null) return -1;
              return b.matchDate!.compareTo(a.matchDate!);
            });
          _videosCache[pid] = videos;
          if (_videosLoadEpoch == epoch && mounted) {
            setState(() => _videos = videos);
          }
        }
        return;
      }

      if (pid == _allId) {
        final ctx = _buildCtx();
        // VBW-Playlists + Bridge-Virtual-Tournaments nur wenn der VBTV-
        // Toggle aktiv ist — sonst leaken VBW-Videos in "Alle Turniere"
        // rein obwohl der User nur Laola1/GBT sehen will.
        final Iterable<Future<List<VideoItem>>> playlistFutures = _sourceVbw
            ? _availableTournaments
                .where((t) => !t['id']!.startsWith('__'))
                .map<Future<List<VideoItem>>>((t) async {
                  try {
                    final res = await http.get(
                      Uri.parse('https://zapp-5434-volleyball-tv.web.app/jw/playlists/${t['id']}?overrideFeedType=moreinfo&ctx=$ctx'),
                      headers: {'Origin': 'https://tv.volleyballworld.com'},
                    ).timeout(const Duration(seconds: 10));
                    if (res.statusCode == 200) {
                      final data = jsonDecode(res.body);
                      return (data['entry'] as List? ?? []).map(_itemFromJson).toList();
                    }
                  } catch (_) {}
                  return <VideoItem>[];
                })
            : const <Future<List<VideoItem>>>[];
        final Iterable<Future<List<VideoItem>>> vtFutures = _sourceVbw
            ? _virtualTournamentData.map(_loadVirtualTournament)
            : const <Future<List<VideoItem>>>[];
        // Laola: gescrapte Live-Courts + hardcoded Fallback + dynamische
        // Tour-Pro-Replay-Liste — nur wenn Laola1-Toggle aktiv.
        final laolaFuture = _sourceLaola
            ? _allLaolaVideoItemsForAggregate()
            : Future.value(const <VideoItem>[]);
        // Twitch/GBT — nur wenn Toggle aktiv.
        final twitchFuture = _sourceTwitch
            ? _allTwitchVideoItemsForAggregate()
            : Future.value(const <VideoItem>[]);

        final allResults = await Future.wait([
          ...playlistFutures,
          ...vtFutures,
          laolaFuture,
          twitchFuture,
        ]);
        final all = allResults.expand((l) => l).toList();
        final seen = <String>{};
        final unique = all.where((v) => seen.add(v.id)).toList()
          ..sort((a, b) {
            if (a.isLive != b.isLive) return a.isLive ? -1 : 1;
            if (a.matchDate == null) return 1;
            if (b.matchDate == null) return -1;
            return b.matchDate!.compareTo(a.matchDate!);
          });
        _videosCache[pid] = unique;
        if (_videosLoadEpoch == epoch && mounted) {
          setState(() => _videos = unique);
        }
        return;
      }

      final ctx = _buildCtx();
      final response = await http.get(
        Uri.parse('https://zapp-5434-volleyball-tv.web.app/jw/playlists/$pid?overrideFeedType=moreinfo&ctx=$ctx'),
        headers: {'Origin': 'https://tv.volleyballworld.com'},
      ).timeout(const Duration(seconds: 10));
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        final videos = (data['entry'] as List? ?? []).map(_itemFromJson).toList();
        // Bridge-Merge: zusätzliche Items aus der Homepage anhängen, die noch
        // nicht in der offiziellen Playlist sind. Typischer Fall: PRE_LIVE-
        // Spiele (morgige Pool-Play), die VBW erst nach Match-Start als VOD
        // in die Playlist legt. Dedup auf Media-ID-Ebene.
        final ci = _vbwPlaylistCi[pid];
        if (ci != null) {
          final bridge = _vbwBridgeItems[ci];
          if (bridge != null && bridge.isNotEmpty) {
            final existing = videos.map((v) => v.id).toSet();
            videos.addAll(bridge.where((v) => !existing.contains(v.id)));
          }
        }
        videos.sort((a, b) {
          if (a.matchDate == null) return 1;
          if (b.matchDate == null) return -1;
          return b.matchDate!.compareTo(a.matchDate!);
        });
        _videosCache[pid] = videos;
        if (_videosLoadEpoch != epoch) return;
        setState(() => _videos = videos);
      } else {
        if (_videosLoadEpoch == epoch) setState(() => _errorMessage = S.httpError(response.statusCode));
      }
    } catch (e) {
      if (!silent && _videosLoadEpoch == epoch) setState(() => _errorMessage = S.connectionError(e.toString()));
    } finally {
      if (!silent && _videosLoadEpoch == epoch) setState(() => _isLoading = false);
    }
  }

  void _openVideo(VideoItem video) {
    if (video.isTwitch) {
      _openTwitchVideo(video);
      return;
    }
    if (video.isLaola) {
      Navigator.push(context, MaterialPageRoute(
        builder: (_) => LaolaStreamExtractor(
          pageUrl: video.linkUrl!,
          title: '${video.tournament} – ${video.teams}'.trim(),
        ),
      ));
      return;
    }
    if (video.isExternal) {
      launchUrl(Uri.parse(video.linkUrl!), mode: LaunchMode.externalApplication);
      return;
    }
    if (video.isLive) {
      _showLiveDialog(video);
      return;
    }
    _launchPlayer(video, seekToLive: false);
  }

  /// Twitch-Videos: PlaybackAccessToken holen, usher.ttvnw.net-Master-URL
  /// bauen und den nativen PlayerScreen oeffnen (video_player kann Twitchs
  /// HLS-Streams direkt abspielen, kein Cookie-Proxy noetig).
  Future<void> _openTwitchVideo(VideoItem video) async {
    final vid = video.twitchVideoId;
    if (vid == null) return;
    // Kurzer nicht-cancelbarer Spinner waehrend der GQL-Roundtrip laeuft
    // (~500ms). Kein separater Screen — wir bleiben visuell auf der
    // Uebersicht bis die Master-URL da ist.
    unawaited(showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => const AlertDialog(
        backgroundColor: Color(0xFF1A1A1A),
        content: SizedBox(
          height: 20,
          child: Center(
            child: CircularProgressIndicator(color: Colors.orange, strokeWidth: 2),
          ),
        ),
      ),
    ));
    final url = await TwitchStream.extractMasterUrl(vid);
    if (mounted && Navigator.canPop(context)) Navigator.pop(context);
    if (!mounted) return;
    if (url == null) {
      await showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          backgroundColor: const Color(0xFF1A1A1A),
          title: Text(S.isEn ? 'Stream unavailable' : 'Stream nicht verfuegbar',
              style: const TextStyle(color: Colors.white)),
          content: Text(
            S.isEn
                ? 'The Twitch playback token could not be fetched. Twitch may have changed their API.'
                : 'Der Twitch-Playback-Token konnte nicht geholt werden. Vielleicht hat Twitch die API umgebaut.',
            style: const TextStyle(color: Colors.white70),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: Text(S.isEn ? 'Back' : 'Zurueck',
                  style: const TextStyle(color: Colors.orange)),
            ),
          ],
        ),
      );
      return;
    }
    if (!mounted) return;
    await Navigator.push(context, MaterialPageRoute(
      builder: (_) => PlayerScreen(
        title: video.teams,
        streamUrl: url,
      ),
    ));
  }

  Future<void> _launchPlayer(VideoItem video, {required bool seekToLive}) async {
    if (!await _ensureLoggedIn()) return;
    if (!mounted) return;
    final ctx = _buildCtx();
    final selfLink = Uri.encodeComponent(
      'https://zapp-5434-volleyball-tv.web.app/jw/media/${video.id}?disablePlayNext=false&withErrors=false&ctx=$ctx',
    );
    final playerUrl = 'https://tv.volleyballworld.com/player?self-link=$selfLink&screen-id=696c5338-8a65-44fb-94c6-41411be52290';
    final result = await Navigator.push<dynamic>(context, MaterialPageRoute(
      builder: (_) => WebViewPlayerScreen(
        title: video.teams,
        playerUrl: playerUrl,
        accessToken: AuthState.token.value,
        useRealDuration: !_twoHourMode,
        seekToLive: seekToLive,
        isLive: video.isLive,
      ),
    ));

    // Player hat erkannt dass die tv.* Session abgelaufen ist und nach
    // signin.* umgeleitet wurde → frisch silent re-loggen und das gleiche
    // Video nochmal versuchen. Wenn silent fehlschlägt: interaktiv.
    if (result == 'needs_login' && mounted) {
      final ok = await _refreshSessionForced();
      if (ok && mounted) {
        _launchPlayer(video, seekToLive: seekToLive);
      }
    }
  }

  /// Erzwingt eine frische Session (Player hat stale-token erkannt).
  /// Delegiert an [_ensureLoggedIn], das den kompletten Flow inklusive
  /// Dialoge fuer keine/falsche Creds und Device-Limit uebernimmt. Kein
  /// interaktiver LoginScreen mehr.
  Future<bool> _refreshSessionForced() async {
    if (!mounted) return false;
    AuthState.token.value = '';
    return _ensureLoggedIn();
  }

  /// Stellt sicher dass eine frische Session verfuegbar ist, bevor der VBW-
  /// Player geoeffnet wird. Neuer Flow (v1.0.128) — der User bekommt NIE
  /// die offizielle Volleyball-World Signin-Seite zu sehen:
  ///
  ///   1. Session laeuft schon → Spinner warten.
  ///   2. Token frisch → true.
  ///   3. Keine gespeicherten Zugangsdaten → Dialog "Zugangsdaten
  ///      hinterlegen" oeffnet unseren eigenen Credentials-Dialog.
  ///   4. Zugangsdaten da → Silent-Login-Versuch mit Spinner. Je nach
  ///      Ergebnis:
  ///        - Erfolg → Player laeuft.
  ///        - Zugangsdaten abgelehnt → Dialog + Button "Zugangsdaten
  ///          korrigieren" (unser eigener Dialog, kein VBW-Login).
  ///        - Device-Limit → Dialog mit Hinweis "Passwort in offizieller
  ///          VBW-App reseten", nur "Zurueck zur Uebersicht" (kein Retry).
  ///        - Netz-/anderer Fehler → generischer Retry-Dialog.
  Future<bool> _ensureLoggedIn() async {
    if (AuthState.isLoggingIn.value) {
      final ok = await _waitForOngoingLogin();
      if (!ok) return false;
    }
    if (AuthState.token.value.isNotEmpty) return true;

    // Background-Silent-Login aus main.dart hat evtl. schon ein Ergebnis
    // hinterlegt — dann direkt den passenden Fehler-Dialog zeigen statt
    // erneut 5-15s im Vordergrund zu warten. networkError faellt raus
    // weil wir da eh einen Retry brauchen; nach dem Retry ist der cached
    // Wert dann fresh.
    final cached = AuthState.lastSilentLoginResult;
    if (cached != null && cached != SilentLoginResult.networkError) {
      switch (cached) {
        case SilentLoginResult.success:
          // Token muesste gesetzt sein, kommen wir hier eigentlich nicht
          // hin. Falls doch: normales Silent-Login als Fallback.
          break;
        case SilentLoginResult.noCredentials:
          return _promptNoCredentials();
        case SilentLoginResult.invalidCredentials:
          return _promptInvalidCredentials();
        case SilentLoginResult.deviceLimit:
          await _promptDeviceLimit();
          return false;
        case SilentLoginResult.networkError:
          break;
      }
    }

    // Erst pruefen ob ueberhaupt Credentials da sind — sonst gar nicht
    // den Silent-Flow anwerfen (der wuerde 18s auf Timeout warten).
    final email = await _storage.read(key: 'saved_email');
    final password = await _storage.read(key: 'saved_password');
    final hasCreds = (email ?? '').isNotEmpty && (password ?? '').isNotEmpty;
    if (!hasCreds) {
      if (!mounted) return false;
      final ok = await _promptNoCredentials();
      if (!ok) return false;
      // Weiter mit dem frisch gespeicherten Login-Versuch.
    }
    return _runSilentLoginWithSpinner();
  }

  /// Waiter fuer den Fall dass schon ein Silent-Login-Versuch parallel
  /// laeuft (z.B. der Background-Refresh aus main.dart). Cancel gibt
  /// false zurueck.
  Future<bool> _waitForOngoingLogin() async {
    bool cancelled = false;
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) {
        void close() {
          try {
            if (Navigator.of(ctx).canPop()) Navigator.of(ctx).pop();
          } catch (_) {}
        }
        void listener() {
          if (!AuthState.isLoggingIn.value) {
            AuthState.isLoggingIn.removeListener(listener);
            close();
          }
        }
        AuthState.isLoggingIn.addListener(listener);
        Timer(const Duration(seconds: 20), () {
          AuthState.isLoggingIn.removeListener(listener);
          close();
        });
        return AlertDialog(
          backgroundColor: const Color(0xFF1A1A1A),
          content: Row(children: [
            const SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(
                  strokeWidth: 2, color: Colors.orange),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Text(
                S.isEn ? 'Signing in...' : 'Anmeldung laeuft...',
                style: const TextStyle(color: Colors.white),
              ),
            ),
          ]),
          actions: [
            TextButton(
              onPressed: () {
                cancelled = true;
                Navigator.pop(ctx);
              },
              child: Text(S.cancel,
                  style: const TextStyle(color: Colors.white54)),
            ),
          ],
        );
      },
    );
    return !cancelled;
  }

  /// Zeigt einen "keine Zugangsdaten gespeichert"-Dialog. Der User wird
  /// zu den normalen Options-Einstellungen weitergeleitet (Fokus auf die
  /// "Gespeicherte Zugangsdaten"-Sektion) — kein separater Eingabedialog
  /// mehr, weniger Fehlerpotential. Nach dem Schliessen der Options ist
  /// der User zurueck auf der Video-Uebersicht.
  Future<bool> _promptNoCredentials() async {
    final go = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1A1A1A),
        title: Text(
          S.isEn ? 'No credentials saved' : 'Keine Zugangsdaten gespeichert',
          style: const TextStyle(color: Colors.white),
        ),
        content: Text(
          S.isEn
              ? 'To watch Volleyball World videos, save your VBW account credentials in the settings.'
              : 'Um Volleyball-World-Videos anzuschauen, hinterlege deine VBW-Zugangsdaten in den Einstellungen.',
          style: const TextStyle(color: Colors.white70),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(S.isEn ? 'Back' : 'Zurueck',
                style: const TextStyle(color: Colors.white54)),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.orange,
              foregroundColor: Colors.black,
            ),
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(S.isEn ? 'Open settings' : 'Einstellungen oeffnen'),
          ),
        ],
      ),
    );
    if (go != true || !mounted) return false;
    _showSettings(focusSavedCredentials: true);
    // Der User bleibt bewusst nach Options-close auf der Video-Uebersicht —
    // wir versuchen NICHT automatisch das Video zu starten. Er klickt neu.
    return false;
  }

  /// Zeigt einen nicht-cancelbaren Spinner an, feuert `tryReloginDetailed`
  /// im Hintergrund und interpretiert das Ergebnis. Bei Bedarf oeffnet
  /// er Folge-Dialoge (falsche Creds → Korrektur-Dialog; Device-Limit →
  /// Reset-Hinweis; Netz-Fehler → generisch).
  ///
  /// [retriesLeft] steuert wie oft nach einem `networkError` automatisch
  /// nachgesetzt wird. Direkt nach einer fehlgeschlagenen Login-Runde
  /// (falsches Passwort) bleiben LoginRadius-Cookies + PKCE-Verifier des
  /// vorherigen Versuchs im HeadlessWebView haengen — der naechste
  /// Token-Exchange scheitert oft mit 400 obwohl Creds jetzt korrekt sind.
  /// Ein einmaliger Retry mit frischem Verifier klaert das zuverlaessig.
  Future<bool> _runSilentLoginWithSpinner({int retriesLeft = 1}) async {
    if (!mounted) return false;
    // Spinner
    unawaited(showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => AlertDialog(
        backgroundColor: const Color(0xFF1A1A1A),
        content: Row(children: [
          const SizedBox(
            width: 20,
            height: 20,
            child: CircularProgressIndicator(
                strokeWidth: 2, color: Colors.orange),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Text(
              S.isEn ? 'Signing in...' : 'Anmeldung laeuft...',
              style: const TextStyle(color: Colors.white),
            ),
          ),
        ]),
      ),
    ));

    AuthState.isLoggingIn.value = true;
    SilentLoginOutcome outcome;
    try {
      outcome = await SilentLoginFlow.tryReloginDetailed();
      AuthState.lastSilentLoginResult = outcome.result;
    } finally {
      AuthState.isLoggingIn.value = false;
    }
    if (mounted && Navigator.canPop(context)) Navigator.pop(context);
    if (!mounted) return false;

    switch (outcome.result) {
      case SilentLoginResult.success:
        final token = outcome.token!;
        AuthState.token.value = token;
        await AuthService.refreshTvCookies(token);
        return true;
      case SilentLoginResult.noCredentials:
        // Sollte hier eigentlich nicht passieren — trotzdem behandeln.
        final ok = await _promptNoCredentials();
        if (!ok) return false;
        return _runSilentLoginWithSpinner();
      case SilentLoginResult.invalidCredentials:
        final ok = await _promptInvalidCredentials();
        if (!ok) return false;
        return _runSilentLoginWithSpinner();
      case SilentLoginResult.deviceLimit:
        await _promptDeviceLimit();
        return false;
      case SilentLoginResult.networkError:
        // Auto-Retry: siehe Doc-Kommentar zu retriesLeft. Erst wenn auch
        // der zweite Versuch mit frischem PKCE-Verifier scheitert, ist
        // wirklich das Netz kaputt und der User bekommt den Dialog.
        if (retriesLeft > 0) {
          debugPrint('[bvctv-login] networkError → auto-retry (${retriesLeft - 1} left)');
          return _runSilentLoginWithSpinner(retriesLeft: retriesLeft - 1);
        }
        await _promptGenericError();
        return false;
    }
  }

  Future<bool> _promptInvalidCredentials() async {
    final go = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1A1A1A),
        title: Text(
          S.isEn ? 'Login failed' : 'Anmeldung fehlgeschlagen',
          style: const TextStyle(color: Colors.white),
        ),
        content: Text(
          S.isEn
              ? 'Volleyball World rejected the stored credentials. Please correct them.'
              : 'Volleyball World hat die gespeicherten Zugangsdaten abgelehnt. Bitte korrigiere sie.',
          style: const TextStyle(color: Colors.white70),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(S.isEn ? 'Back' : 'Zurueck',
                style: const TextStyle(color: Colors.white54)),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.orange,
              foregroundColor: Colors.black,
            ),
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(
                S.isEn ? 'Update credentials' : 'Zugangsdaten korrigieren'),
          ),
        ],
      ),
    );
    if (go != true || !mounted) return false;
    // Wie bei _promptNoCredentials: direkt in die Options mit Fokus auf
    // die Zugangsdaten-Sektion. Kein separater Dialog, kein Auto-Retry —
    // der User klickt das Video neu wenn er fertig ist.
    _showSettings(focusSavedCredentials: true);
    return false;
  }

  Future<void> _promptDeviceLimit() async {
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1A1A1A),
        title: Text(
          S.isEn ? 'Device limit reached' : 'Geraete-Limit erreicht',
          style: const TextStyle(color: Colors.white),
        ),
        content: Text(
          S.isEn
              ? 'Volleyball World allows only 3 signed-in devices. Please open the official Volleyball World app and reset your password there to sign out the other devices. Do NOT try to reset it here.'
              : 'Volleyball World erlaubt nur 3 gleichzeitig angemeldete Geraete. Bitte oeffne die offizielle Volleyball-World-App und setze dort dein Passwort zurueck, um die anderen Geraete auszuloggen. Bitte NICHT hier zuruecksetzen.',
          style: const TextStyle(color: Colors.white70),
        ),
        actions: [
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.orange,
              foregroundColor: Colors.black,
            ),
            onPressed: () => Navigator.pop(ctx),
            child: Text(
                S.isEn ? 'Back to overview' : 'Zurueck zur Uebersicht'),
          ),
        ],
      ),
    );
  }

  Future<void> _promptGenericError() async {
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1A1A1A),
        title: Text(
          S.isEn ? 'Login failed' : 'Anmeldung fehlgeschlagen',
          style: const TextStyle(color: Colors.white),
        ),
        content: Text(
          S.isEn
              ? 'Please check your internet connection and try again.'
              : 'Bitte pruefe deine Internetverbindung und versuche es erneut.',
          style: const TextStyle(color: Colors.white70),
        ),
        actions: [
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.orange,
              foregroundColor: Colors.black,
            ),
            onPressed: () => Navigator.pop(ctx),
            child: Text(S.isEn ? 'Back' : 'Zurueck'),
          ),
        ],
      ),
    );
  }

  void _showLiveDialog(VideoItem video) {
    // Player-WebView schon waehrend der Dialog auf eine Entscheidung wartet
    // warmlaufen lassen — Card-Focus-Preload ist fuer Live-Karten deaktiviert,
    // hier per Direktaufruf an _startPreload nachholen. Beim Klick auf "Vom
    // Anfang an" / "Live einsteigen" startet der Player dann mit warmem
    // Cookie-Jar und gecachten Player-Assets.
    if (Platform.isAndroid) {
      _startPreload(video);
    }
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1A1A1A),
        title: Row(children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
            decoration: BoxDecoration(color: Colors.red, borderRadius: BorderRadius.circular(4)),
            child: const Text('LIVE', style: TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.bold, letterSpacing: 1)),
          ),
          const SizedBox(width: 10),
          Expanded(child: Text(S.liveGame, style: const TextStyle(color: Colors.white))),
        ]),
        content: Text(S.liveDialogText, style: const TextStyle(color: Colors.white70)),
        actions: [
          TextButton(
            autofocus: true,
            onPressed: () { Navigator.pop(ctx); _launchPlayer(video, seekToLive: false); },
            child: Text(S.fromStart, style: const TextStyle(color: Colors.white54)),
          ),
          TextButton(
            onPressed: () { Navigator.pop(ctx); _launchPlayer(video, seekToLive: true); },
            child: Text(S.joinLive, style: const TextStyle(color: Colors.orange)),
          ),
        ],
      ),
    );
  }

  String _formatDate(DateTime? date) {
    if (date == null) return '';
    final d = date.toLocal();
    return '${d.day}. ${S.months[d.month - 1]} ${d.year}, ${d.hour.toString().padLeft(2,'0')}:${d.minute.toString().padLeft(2,'0')}';
  }

  Widget _genderBadge(String gender) {
    if (gender.isEmpty) return const SizedBox.shrink();
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: gender == 'Men' ? const Color(0xFF1565C0) : const Color(0xFFAD1457),
        borderRadius: BorderRadius.circular(3),
      ),
      child: Text(
        S.genderLabel(gender),
        style: const TextStyle(color: Colors.white, fontSize: 9, fontWeight: FontWeight.bold),
      ),
    );
  }

  Widget _statusBadge(VideoItem video) {
    if (video.isYouTube) {
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
        decoration: BoxDecoration(color: const Color(0xFFCC0000), borderRadius: BorderRadius.circular(3)),
        child: const Text('YT', style: TextStyle(color: Colors.white, fontSize: 8, fontWeight: FontWeight.bold, letterSpacing: 1)),
      );
    }
    if (video.isLaola) {
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
        decoration: BoxDecoration(color: const Color(0xFF0066B2), borderRadius: BorderRadius.circular(3)),
        child: const Text('LAOLA', style: TextStyle(color: Colors.white, fontSize: 8, fontWeight: FontWeight.bold, letterSpacing: 1)),
      );
    }
    if (video.isLive) {
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
        decoration: BoxDecoration(color: Colors.red, borderRadius: BorderRadius.circular(3)),
        child: const Text('LIVE', style: TextStyle(color: Colors.white, fontSize: 8, fontWeight: FontWeight.bold, letterSpacing: 1)),
      );
    }
    if (video.isUpcoming) {
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
        decoration: BoxDecoration(color: const Color(0xFFE65100), borderRadius: BorderRadius.circular(3)),
        child: const Text('BALD', style: TextStyle(color: Colors.white, fontSize: 8, fontWeight: FontWeight.bold, letterSpacing: 1)),
      );
    }

    return const SizedBox.shrink();
  }

  Widget _filterChip(String label, String value, {bool autofocus = false}) {
    final selected = _genderFilter == value;
    return _TvFocusButton(
      autofocus: autofocus,
      onPressed: () => setState(() { _genderFilter = value; }),
      borderRadius: 20,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
        decoration: BoxDecoration(
          color: selected ? Colors.orange : const Color(0xFF1A1A1A),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: selected ? Colors.orange : Colors.white24),
        ),
        child: Text(label, style: TextStyle(
          color: selected ? Colors.black : Colors.white70,
          fontSize: 13,
          fontWeight: selected ? FontWeight.bold : FontWeight.normal,
        )),
      ),
    );
  }

  /// Source-Toggle-Chip (VBTV/Laola1/GBT). Optisch identisch zum
  /// _filterChip, aber toggle-basiert statt Radio-Auswahl: aktiv = orange,
  /// inaktiv = ausgegraut.
  Widget _sourceChip(String label, String src) {
    final selected = src == 'vbw'
        ? _sourceVbw
        : src == 'laola'
            ? _sourceLaola
            : src == 'twitch'
                ? _sourceTwitch
                : false;
    return _TvFocusButton(
      onPressed: () => _toggleSource(src),
      borderRadius: 20,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
        decoration: BoxDecoration(
          color: selected ? Colors.orange : const Color(0xFF1A1A1A),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: selected ? Colors.orange : Colors.white24),
        ),
        child: Text(label, style: TextStyle(
          color: selected ? Colors.black : Colors.white38,
          fontSize: 13,
          fontWeight: selected ? FontWeight.bold : FontWeight.normal,
        )),
      ),
    );
  }

  Widget _tournamentDropdown() {
    if (_isLoadingTournaments) {
      return const SizedBox(
        width: 20, height: 20,
        child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white38),
      );
    }
    final visible = _visibleTournaments();
    if (visible.isEmpty) return const SizedBox.shrink();

    final isAll = _currentPlaylistId == _allId;
    final currentTitle = isAll
        ? S.allTournaments
        : visible.firstWhere((t) => t['id'] == _currentPlaylistId,
            orElse: () => {'title': S.tournament})['title']!;

    Future<void> open() async {
      final result = await showModalBottomSheet<String>(
        context: context,
        backgroundColor: const Color(0xFF1A1A1A),
        isScrollControlled: true,
        shape: const RoundedRectangleBorder(
            borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
        builder: (_) => _TournamentSheet(
          tournaments: visible,
          currentId: _currentPlaylistId,
          allId: _allId,
        ),
      );
      if (result == null) return;
      if (result != _currentPlaylistId) _loadVideos(result);
    }

    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 160),
      child: _TvFocusButton(
        onPressed: open,
        borderRadius: 20,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
          decoration: BoxDecoration(
            color: const Color(0xFF1A1A1A),
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: Colors.orange),
          ),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Flexible(child: Text(isAll ? S.all : _shortTitle(currentTitle),
              style: const TextStyle(color: Colors.orange, fontSize: 12, fontWeight: FontWeight.bold),
              overflow: TextOverflow.ellipsis,
            )),
            const SizedBox(width: 4),
            const Icon(Icons.arrow_drop_down, size: 18, color: Colors.orange),
          ]),
        ),
      ),
    );
  }

  Widget _playerDropdown() {
    final players = _availablePlayers;
    if (players.isEmpty) return const SizedBox.shrink();
    final active = _playerFilter != null;
    final label = _playerFilter ?? S.allPlayers;
    Future<void> open() async {
      final result = await showModalBottomSheet<String>(
        context: context,
        backgroundColor: const Color(0xFF1A1A1A),
        isScrollControlled: true,
        shape: const RoundedRectangleBorder(
            borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
        builder: (_) => _PlayerSearchSheet(players: players, selected: _playerFilter),
      );
      if (result == null) return;
      setState(() => _playerFilter = result.isEmpty ? null : result);
    }
    return _TvFocusButton(
      onPressed: open,
      borderRadius: 20,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
        decoration: BoxDecoration(
          color: const Color(0xFF1A1A1A),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: active ? Colors.orange : Colors.white24),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(Icons.person, size: 13, color: active ? Colors.orange : Colors.white38),
          const SizedBox(width: 4),
          Flexible(child: Text(label, style: TextStyle(
            color: active ? Colors.orange : Colors.white70,
            fontSize: 12,
            fontWeight: active ? FontWeight.bold : FontWeight.normal,
          ), overflow: TextOverflow.ellipsis)),
          const SizedBox(width: 4),
          Icon(Icons.arrow_drop_down, size: 18, color: active ? Colors.orange : Colors.white38),
        ]),
      ),
    );
  }

  Widget _countryDropdown() {
    final countries = _availableCountries;
    if (countries.isEmpty) return const SizedBox.shrink();
    final active = _countryFilter != null;
    final label = _countryFilter ?? S.allCountries;
    Future<void> open() async {
      final result = await showModalBottomSheet<String>(
        context: context,
        backgroundColor: const Color(0xFF1A1A1A),
        isScrollControlled: true,
        shape: const RoundedRectangleBorder(
            borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
        builder: (_) => _CountrySearchSheet(countries: countries, selected: _countryFilter),
      );
      if (result == null) return;
      setState(() => _countryFilter = result.isEmpty ? null : result);
    }
    return _TvFocusButton(
      onPressed: open,
      borderRadius: 20,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
        decoration: BoxDecoration(
          color: const Color(0xFF1A1A1A),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: active ? Colors.orange : Colors.white24),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(Icons.flag, size: 13, color: active ? Colors.orange : Colors.white38),
          const SizedBox(width: 4),
          Text(label, style: TextStyle(
            color: active ? Colors.orange : Colors.white70,
            fontSize: 12,
            fontWeight: active ? FontWeight.bold : FontWeight.normal,
          )),
          const SizedBox(width: 4),
          Icon(Icons.arrow_drop_down, size: 18, color: active ? Colors.orange : Colors.white38),
        ]),
      ),
    );
  }

  Widget _buildVideoCard(VideoItem video) {
    return _VideoCard(
      video: video,
      spoiler: _isSpoiler(video.round),
      onPressed: () => _openVideo(video),
      onPreload: (video.isExternal || video.isLive || video.isUpcoming || !Platform.isAndroid)
          ? null
          : () => _startPreload(video),
      genderBadge: _genderBadge(video.gender),
      statusBadge: _statusBadge(video),
      dateStr: _formatDate(video.matchDate),
    );
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        final close = await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            backgroundColor: const Color(0xFF1A1A1A),
            title: Text(S.exitAppTitle, style: const TextStyle(color: Colors.white)),
            contentPadding: const EdgeInsets.fromLTRB(24, 12, 24, 16),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(S.exitAppDesc, style: const TextStyle(color: Colors.white70)),
                const SizedBox(height: 16),
                Row(children: [
                  _TvFocusButton(
                    autofocus: true,
                    borderRadius: 6,
                    onPressed: () => Navigator.pop(ctx, false),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                      child: Text(S.cancel, style: const TextStyle(color: Colors.white54)),
                    ),
                  ),
                  const Spacer(),
                  _TvFocusButton(
                    borderRadius: 6,
                    onPressed: () => Navigator.pop(ctx, true),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                      child: Text(S.exit, style: const TextStyle(color: Colors.orange)),
                    ),
                  ),
                ]),
              ],
            ),
            actions: const [],
          ),
        );
        if (close == true && context.mounted) SystemNavigator.pop();
      },
      child: Scaffold(
      appBar: AppBar(
        // Titel: das echte BVCTV-Logo (Volleyball-Icon + Schriftzug) in
        // einem oranger Kreis — identisch zum Header der Web-App-Variante.
        // 40x40, 4px Padding, Kreis = border-radius 50% via ClipOval.
        title: Container(
          width: 40,
          height: 40,
          decoration: const BoxDecoration(
            color: Colors.orange,
            shape: BoxShape.circle,
          ),
          padding: const EdgeInsets.all(4),
          child: ClipOval(
            child: Image.asset('assets/bvctv_logo.png', fit: BoxFit.contain),
          ),
        ),
        backgroundColor: const Color(0xFF0A0A0A),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: () {
              _loadVideos();
              _scrapeLaolaLivestreams();
            },
          ),
          IconButton(icon: const Icon(Icons.settings), onPressed: _showSettings),
        ],
      ),
      body: Stack(children: [
        _errorMessage != null && _videos.isEmpty
          ? Center(child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
              Text(_errorMessage!, style: const TextStyle(color: Colors.redAccent)),
              const SizedBox(height: 16),
              ElevatedButton(onPressed: _loadVideos, child: Text(S.tryAgain)),
            ]))
          : Column(children: [
                  // Zeile 1: Source-Toggles (VBTV/Laola1/GBT) links —
                  // Gender-Filter (Alle/Herren/Damen) rechts. Beide Gruppen
                  // sind Chip-basiert, gleiche Optik, Spacer trennt sie.
                  Container(
                    color: const Color(0xFF0A0A0A),
                    padding: const EdgeInsets.fromLTRB(12, 10, 12, 4),
                    child: Row(children: [
                      // Neutrale Variante kennt nur VBTV — drei Chips von
                      // denen einer immer an und zwei immer aus waeren sind
                      // sinnlos, also weg. Der Gender-Filter rueckt nach links.
                      if (!AppVariant.vbtvOnly) ...[
                        _sourceChip('VBTV',   'vbw'),
                        const SizedBox(width: 8),
                        _sourceChip('Laola1', 'laola'),
                        const SizedBox(width: 8),
                        _sourceChip('GBT',    'twitch'),
                      ],
                      const Spacer(),
                      _filterChip(S.all, 'all', autofocus: true),
                      const SizedBox(width: 8),
                      _filterChip(S.men, 'men'),
                      const SizedBox(width: 8),
                      _filterChip(S.women, 'women'),
                    ]),
                  ),
                  // Zeile 2: Turnier-Dropdown links — Player + Country
                  // Dropdowns rechts (jeweils nur wenn Daten da sind).
                  Container(
                    color: const Color(0xFF0A0A0A),
                    padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
                    child: Row(children: [
                      _tournamentDropdown(),
                      const Spacer(),
                      if (_availablePlayers.isNotEmpty) _playerDropdown(),
                      if (_availablePlayers.isNotEmpty && _availableCountries.isNotEmpty)
                        const SizedBox(width: 8),
                      if (_availableCountries.isNotEmpty) _countryDropdown(),
                    ]),
                  ),
                  if (_isLoading)
                    const LinearProgressIndicator(color: Colors.orange, backgroundColor: Colors.transparent, minHeight: 2),
                  Expanded(
                    child: (!_sourceVbw && !_sourceLaola && !_sourceTwitch)
                        // Alle drei Sources aus → weder Turniere noch Videos
                        // zeigen (die Dropdown ist schon leer). Hinweis
                        // damit der User weiss was zu tun ist.
                        ? Center(
                            child: Text(
                              S.isEn
                                  ? 'No source active — enable VBTV, Laola1 or GBT above.'
                                  : 'Keine Quelle aktiv — VBTV, Laola1 oder GBT oben einblenden.',
                              style: const TextStyle(color: Colors.white54),
                              textAlign: TextAlign.center,
                            ),
                          )
                        : _isLoading && _videos.isEmpty
                        ? const Center(child: CircularProgressIndicator(color: Colors.orange))
                        : LayoutBuilder(builder: (context, constraints) {
                            final isTV = constraints.maxWidth > 900 || constraints.maxHeight > 900;
                            final crossAxisCount = isTV ? 5 : 2;
                            const spacing = 10.0;
                            const pad = 12.0;

                            SliverGridDelegate gridDelegate;
                            if (isTV) {
                              // Nur top-pad + 1 spacing abziehen (statt 2 spacings).
                              // Zeile 4 startet dann ~20px jenseits constraints.maxHeight und bleibt
                              // auch auf dem Fire Stick (wo ~10-12px extra sichtbar sind) unsichtbar.
                              const nRows = 3;
                              final tileHeight = ((constraints.maxHeight - pad - spacing) / nRows).floorToDouble();
                              gridDelegate = SliverGridDelegateWithFixedCrossAxisCount(
                                crossAxisCount: crossAxisCount,
                                mainAxisExtent: tileHeight,
                                crossAxisSpacing: spacing,
                                mainAxisSpacing: spacing,
                              );
                            } else {
                              gridDelegate = SliverGridDelegateWithFixedCrossAxisCount(
                                crossAxisCount: crossAxisCount,
                                childAspectRatio: 1.4,
                                crossAxisSpacing: spacing,
                                mainAxisSpacing: spacing,
                              );
                            }

                            return ClipRect(
                              child: GridView.builder(
                                padding: const EdgeInsets.all(pad),
                                gridDelegate: gridDelegate,
                                itemCount: _filteredVideos.length,
                                itemBuilder: (_, i) => _buildVideoCard(_filteredVideos[i]),
                              ),
                            );
                          }),
                  ),
                ]),
        if (_preloadController != null)
          Positioned(
            left: 0, top: 0,
            width: 1, height: 1,
            child: WebViewWidget(controller: _preloadController!),
          ),
      ]),
      ),
    );
  }
}

// ── Marquee (scrollender Text bei Fokus) ─────────────────────────────────────

class _MarqueeText extends StatefulWidget {
  final String text;
  final bool focused;
  final TextStyle style;
  const _MarqueeText({required this.text, required this.focused, required this.style});
  @override
  State<_MarqueeText> createState() => _MarqueeTextState();
}

class _MarqueeTextState extends State<_MarqueeText> {
  final _scroll = ScrollController();
  Timer? _timer;

  @override
  void didUpdateWidget(_MarqueeText old) {
    super.didUpdateWidget(old);
    if (widget.focused && !old.focused) { _startScroll(); }
    else if (!widget.focused && old.focused) { _resetScroll(); }
  }

  void _startScroll() {
    _timer?.cancel();
    _timer = Timer(const Duration(milliseconds: 600), () async {
      if (!mounted || !_scroll.hasClients) return;
      final max = _scroll.position.maxScrollExtent;
      if (max <= 0) return;
      await _scroll.animateTo(max,
          duration: Duration(milliseconds: (max * 22).round()),
          curve: Curves.linear);
    });
  }

  void _resetScroll() {
    _timer?.cancel();
    if (_scroll.hasClients) _scroll.jumpTo(0);
  }

  @override
  void dispose() {
    _timer?.cancel();
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => SingleChildScrollView(
        controller: _scroll,
        scrollDirection: Axis.horizontal,
        physics: const NeverScrollableScrollPhysics(),
        child: Text(widget.text, style: widget.style, maxLines: 1),
      );
}

// ── VideoCard ─────────────────────────────────────────────────────────────────

class _VideoCard extends StatefulWidget {
  final VideoItem video;
  final bool spoiler;
  final VoidCallback onPressed;
  final VoidCallback? onPreload;
  final Widget genderBadge;
  final Widget statusBadge;
  final String dateStr;
  const _VideoCard({
    required this.video,
    required this.spoiler,
    required this.onPressed,
    required this.genderBadge,
    required this.statusBadge,
    required this.dateStr,
    this.onPreload,
  });
  @override
  State<_VideoCard> createState() => _VideoCardState();
}

class _VideoCardState extends State<_VideoCard> {
  bool _focused = false;

  static List<String> _splitTeams(String teams) {
    final idx = teams.indexOf(' vs ');
    if (idx < 0) return [teams];
    return [teams.substring(0, idx).trim(), teams.substring(idx + 4).trim()];
  }

  @override
  Widget build(BuildContext context) {
    final video = widget.video;
    final teams = _splitTeams(video.teams);
    const teamStyle = TextStyle(fontSize: 12, fontWeight: FontWeight.bold);

    return _TvFocusButton(
      onPressed: widget.onPressed,
      borderRadius: 8,
      onFocusChanged: (focused) {
        setState(() => _focused = focused);
        if (focused) widget.onPreload?.call();
      },
      child: Container(
        decoration: BoxDecoration(color: const Color(0xFF1A1A1A), borderRadius: BorderRadius.circular(8)),
        padding: const EdgeInsets.all(10),
        child: video.isYouTube
            ? Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Row(children: [
                    widget.statusBadge,
                    const SizedBox(width: 6),
                    const Text('YouTube', style: TextStyle(color: Colors.white38, fontSize: 10)),
                  ]),
                  const SizedBox(height: 6),
                  Expanded(child: Text(video.title,
                    style: teamStyle, maxLines: 3, overflow: TextOverflow.ellipsis)),
                  Text(S.opensYouTube,
                    style: const TextStyle(color: Colors.white38, fontSize: 10)),
                ],
              )
            : Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Row(children: [
                      widget.genderBadge,
                      if (video.gender.isNotEmpty) const SizedBox(width: 6),
                      Expanded(child: Text(S.localizeRound(video.round),
                        style: const TextStyle(color: Colors.white60, fontSize: 10),
                        overflow: TextOverflow.ellipsis)),
                      widget.statusBadge,
                    ]),
                    const SizedBox(height: 6),
                    if (widget.spoiler)
                      Row(children: [
                        const Icon(Icons.lock_outline, size: 12, color: Colors.white30),
                        const SizedBox(width: 4),
                        Expanded(child: Text(S.spoilerActive,
                          style: const TextStyle(fontSize: 11, color: Colors.white30, fontStyle: FontStyle.italic))),
                      ])
                    else ...[
                      _MarqueeText(text: teams[0], focused: _focused, style: teamStyle),
                      if (teams.length > 1) ...[
                        const SizedBox(height: 2),
                        _MarqueeText(text: teams[1], focused: _focused, style: teamStyle),
                      ],
                    ],
                  ]),
                  Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(video.tournament,
                      style: const TextStyle(color: Colors.white38, fontSize: 10),
                      overflow: TextOverflow.ellipsis),
                    Text(widget.dateStr,
                      style: const TextStyle(color: Colors.white38, fontSize: 10)),
                  ]),
                ],
              ),
      ),
    );
  }
}

// ── TvFocusButton ─────────────────────────────────────────────────────────────

class _TvFocusButton extends StatefulWidget {
  final Widget child;
  final VoidCallback onPressed;
  final double borderRadius;
  final bool autofocus;
  final void Function(bool)? onFocusChanged;

  const _TvFocusButton({
    required this.child,
    required this.onPressed,
    this.borderRadius = 8,
    this.autofocus = false,
    this.onFocusChanged,
  });

  @override
  State<_TvFocusButton> createState() => _TvFocusButtonState();
}

class _TvFocusButtonState extends State<_TvFocusButton> {
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    return Focus(
      autofocus: widget.autofocus,
      onFocusChange: (f) { setState(() => _focused = f); widget.onFocusChanged?.call(f); },
      onKeyEvent: (_, event) {
        if (event is KeyDownEvent &&
            (event.logicalKey == LogicalKeyboardKey.select ||
             event.logicalKey == LogicalKeyboardKey.enter)) {
          widget.onPressed();
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      },
      child: GestureDetector(
        onTap: widget.onPressed,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 100),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(widget.borderRadius + 3),
            border: Border.all(
              color: _focused ? Colors.orange : Colors.transparent,
              width: 3,
            ),
            boxShadow: _focused
                ? [BoxShadow(color: Colors.orange.withValues(alpha: 0.2), blurRadius: 6, spreadRadius: 0)]
                : null,
          ),
          child: widget.child,
        ),
      ),
    );
  }
}

class _TvFocusWrapper extends StatefulWidget {
  final Widget child;
  final double borderRadius;

  const _TvFocusWrapper({required this.child, required this.borderRadius});

  @override
  State<_TvFocusWrapper> createState() => _TvFocusWrapperState();
}

class _TvFocusWrapperState extends State<_TvFocusWrapper> {
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    return Focus(
      skipTraversal: true,
      onFocusChange: (f) => setState(() => _focused = f),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 100),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(widget.borderRadius + 3),
          border: Border.all(color: _focused ? Colors.orange : Colors.transparent, width: 3),
          boxShadow: _focused
              ? [BoxShadow(color: Colors.orange.withValues(alpha: 0.6), blurRadius: 10, spreadRadius: 1)]
              : null,
        ),
        child: widget.child,
      ),
    );
  }
}

class _TournamentSheet extends StatefulWidget {
  final List<Map<String, String>> tournaments;
  final String currentId;
  final String allId;

  const _TournamentSheet({required this.tournaments, required this.currentId, required this.allId});

  @override
  State<_TournamentSheet> createState() => _TournamentSheetState();
}

class _TournamentSheetState extends State<_TournamentSheet> {
  final _firstFocus = FocusNode();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _firstFocus.requestFocus();
    });
  }

  @override
  void dispose() {
    _firstFocus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final items = [
      {'id': widget.allId, 'title': S.allTournaments},
      ...widget.tournaments,
    ];
    return Column(mainAxisSize: MainAxisSize.min, children: [
      Container(
        margin: const EdgeInsets.symmetric(vertical: 10),
        width: 40, height: 4,
        decoration: BoxDecoration(color: Colors.white24, borderRadius: BorderRadius.circular(2)),
      ),
      Flexible(
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: List.generate(items.length, (i) {
              final id = items[i]['id']!;
              final title = items[i]['title']!;
              final isActive = id == widget.currentId;
              return Focus(
                onKeyEvent: i == 0 ? (_, event) {
                  if (event is KeyDownEvent && event.logicalKey == LogicalKeyboardKey.arrowUp) {
                    return KeyEventResult.handled;
                  }
                  return KeyEventResult.ignored;
                } : null,
                child: ListTile(
                  focusNode: i == 0 ? _firstFocus : null,
                  title: Text(title, style: TextStyle(
                    color: isActive ? Colors.orange : Colors.white70,
                    fontWeight: isActive ? FontWeight.bold : FontWeight.normal,
                  )),
                  trailing: isActive ? const Icon(Icons.check, color: Colors.orange, size: 18) : null,
                  onTap: () => Navigator.pop(context, id),
                ),
              );
            }),
          ),
        ),
      ),
      const SizedBox(height: 16),
    ]);
  }
}

class _PlayerSearchSheet extends StatefulWidget {
  final List<String> players;
  final String? selected;
  const _PlayerSearchSheet({required this.players, this.selected});

  @override
  State<_PlayerSearchSheet> createState() => _PlayerSearchSheetState();
}

class _PlayerSearchSheetState extends State<_PlayerSearchSheet> {
  final _ctrl = TextEditingController();
  final _firstFocus = FocusNode();
  final _searchFocus = FocusNode();
  bool _searchActive = false;
  bool _searchFocused = false;
  late List<String> _filtered;

  @override
  void initState() {
    super.initState();
    _filtered = widget.players;
    _ctrl.addListener(() {
      final q = _ctrl.text.toLowerCase();
      setState(() {
        _filtered = q.isEmpty
            ? widget.players
            : widget.players.where((p) => p.toLowerCase().contains(q)).toList();
      });
    });
    _searchFocus.addListener(() {
      if (mounted) {
        setState(() {
        _searchFocused = _searchFocus.hasFocus;
        if (!_searchFocus.hasFocus) _searchActive = false;
      });
      }
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _firstFocus.requestFocus();
    });
  }

  @override
  void dispose() {
    _ctrl.dispose();
    _firstFocus.dispose();
    _searchFocus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        Container(
          margin: const EdgeInsets.symmetric(vertical: 10),
          width: 40, height: 4,
          decoration: BoxDecoration(color: Colors.white24, borderRadius: BorderRadius.circular(2)),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
          child: Focus(
            onFocusChange: (hasFocus) {
              if (mounted) {
                setState(() {
                _searchFocused = hasFocus;
                if (!hasFocus && !_searchFocus.hasFocus) _searchActive = false;
              });
              }
            },
            onKeyEvent: (_, event) {
              if (!_searchActive && event is KeyDownEvent &&
                  (event.logicalKey == LogicalKeyboardKey.select ||
                   event.logicalKey == LogicalKeyboardKey.enter)) {
                setState(() => _searchActive = true);
                WidgetsBinding.instance.addPostFrameCallback((_) {
                  if (mounted) _searchFocus.requestFocus();
                });
                return KeyEventResult.handled;
              }
              return KeyEventResult.ignored;
            },
            child: TextField(
            controller: _ctrl,
            focusNode: _searchFocus,
            autofocus: false,
            readOnly: !_searchActive,
            onTap: () { if (!_searchActive) setState(() => _searchActive = true); },
            style: const TextStyle(color: Colors.white),
            decoration: InputDecoration(
              hintText: S.searchPlayers,
              hintStyle: const TextStyle(color: Colors.white38),
              prefixIcon: const Icon(Icons.search, color: Colors.white38),
              suffixIcon: _ctrl.text.isNotEmpty
                  ? IconButton(
                      icon: const Icon(Icons.clear, color: Colors.white38),
                      onPressed: () => _ctrl.clear(),
                    )
                  : null,
              filled: true,
              fillColor: _searchActive || _searchFocused ? const Color(0xFF2A2A2A) : const Color(0xFF161616),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: BorderSide.none,
              ),
            ),
          ),
          ),
        ),
        ConstrainedBox(
          constraints: BoxConstraints(maxHeight: MediaQuery.of(context).size.height * 0.5),
          child: ListView(shrinkWrap: true, children: [
            ListTile(
              focusNode: _firstFocus,
              leading: Icon(Icons.people, size: 20,
                  color: widget.selected == null ? Colors.orange : Colors.white38),
              title: Text(S.allPlayers, style: TextStyle(
                color: widget.selected == null ? Colors.orange : Colors.white70,
                fontWeight: widget.selected == null ? FontWeight.bold : FontWeight.normal,
              )),
              onTap: () => Navigator.pop(context, ''),
            ),
            ..._filtered.map((p) => ListTile(
              leading: Icon(Icons.person, size: 20,
                  color: p == widget.selected ? Colors.orange : Colors.white38),
              title: Text(p, style: TextStyle(
                color: p == widget.selected ? Colors.orange : Colors.white70,
                fontWeight: p == widget.selected ? FontWeight.bold : FontWeight.normal,
              )),
              onTap: () => Navigator.pop(context, p),
            )),
          ]),
        ),
        const SizedBox(height: 16),
      ]),
    );
  }
}

class _CountrySearchSheet extends StatelessWidget {
  final List<String> countries;
  final String? selected;
  const _CountrySearchSheet({required this.countries, this.selected});

  @override
  Widget build(BuildContext context) {
    return Column(mainAxisSize: MainAxisSize.min, children: [
      Container(
        margin: const EdgeInsets.symmetric(vertical: 10),
        width: 40, height: 4,
        decoration: BoxDecoration(color: Colors.white24, borderRadius: BorderRadius.circular(2)),
      ),
      ConstrainedBox(
        constraints: BoxConstraints(maxHeight: MediaQuery.of(context).size.height * 0.6),
        child: ListView(shrinkWrap: true, children: [
          ListTile(
            leading: Icon(Icons.flag_outlined, size: 20,
                color: selected == null ? Colors.orange : Colors.white38),
            title: Text(S.allCountries, style: TextStyle(
              color: selected == null ? Colors.orange : Colors.white70,
              fontWeight: selected == null ? FontWeight.bold : FontWeight.normal,
            )),
            onTap: () => Navigator.pop(context, ''),
          ),
          ...countries.map((c) => ListTile(
            leading: Icon(Icons.flag, size: 20,
                color: c == selected ? Colors.orange : Colors.white38),
            title: Text(c, style: TextStyle(
              color: c == selected ? Colors.orange : Colors.white70,
              fontWeight: c == selected ? FontWeight.bold : FontWeight.normal,
            )),
            onTap: () => Navigator.pop(context, c),
          )),
        ]),
      ),
      const SizedBox(height: 16),
    ]);
  }
}

class WebViewPlayerScreen extends StatefulWidget {
  final String title;
  final String playerUrl;
  final String accessToken;
  final bool useRealDuration;
  final bool seekToLive;
  final bool isLive;
  const WebViewPlayerScreen({super.key, required this.title, required this.playerUrl, required this.accessToken, this.useRealDuration = false, this.seekToLive = false, this.isLive = false});

  @override
  State<WebViewPlayerScreen> createState() => _WebViewPlayerScreenState();
}

class _WebViewPlayerScreenState extends State<WebViewPlayerScreen> {
  WebViewController? _controller;
  InAppWebViewController? _inAppController;

  bool get _useInAppWebView => !kIsWeb && Platform.isWindows;

  void _runJs(String js) {
    if (_useInAppWebView) {
      _inAppController?.evaluateJavascript(source: js);
    } else {
      _controller?.runJavaScript(js);
    }
  }

  void _loadUrl(String url) {
    if (_useInAppWebView) {
      _inAppController?.loadUrl(urlRequest: URLRequest(url: WebUri(url)));
    } else {
      _controller?.loadRequest(Uri.parse(url));
    }
  }

  Duration get _effectiveDuration {
    if (widget.isLive) {
      // Live: max = aktuelle Live-Kante (seekable.end), kein künstliches Limit
      return _liveEdge > 0 ? Duration(seconds: _liveEdge.floor()) : Duration(seconds: _realDuration.floor());
    }
    if (widget.useRealDuration || _realDuration > 7200) {
      return Duration(seconds: _realDuration.floor());
    }
    return const Duration(hours: 2);
  }
  Duration _fakePosition = Duration.zero;
  double _realDuration = 7200; // Default 2h bis JW Player echte Dauer meldet
  double _liveEdge = 0; // Für Live-Streams: aktuellster abspielbarer Zeitpunkt
  bool _isPlaying = false;
  bool _isInBlackScreen = false;
  bool _showControls = true;
  bool _playerReady = false;
  bool _isTV = false;
  String _debugMsg = '';

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _isTV = MediaQuery.of(context).size.shortestSide > 450;
  }

  double _playbackRate = 1.0;
  DateTime? _lastUserToggle;

  int _seekClickCount = 0; // positiv = vorwärts, negativ = rückwärts
  int _pendingSeekSeconds = 0;
  bool _showSeekOverlay = false;
  String _seekOverlayText = '';
  Timer? _seekTimer;
  Timer? _hideControlsTimer;
  Timer? _positionTimer;
  Timer? _blackScreenTimer;

  // 1x=10s 2x=30s 3x=1min 4x=3min 5x=5min 6x=10min 7x=20min 8x=30min, danach +30min
  final List<int> _seekSteps = [10, 30, 60, 180, 300, 600, 1200, 1800];

  // Auto-Retry wenn JW Player nach 15s nicht "ready" gemeldet hat (Netz-Blip etc.)
  Timer? _initRetryTimer;
  bool _initRetryDone = false;

  // Erkennen wenn die tv.* Session abgelaufen ist und der Server uns auf
  // signin.volleyballworld.com (oder eine tv.*/login-Variante) umleitet.
  // Nur einmal feuern, sonst kommt's beim about:blank in dispose() nochmal.
  bool _loginRedirectFired = false;
  void _handleLoginRedirect(String url) {
    if (_loginRedirectFired) return;
    _loginRedirectFired = true;
    debugPrint('[player] session expired, redirected to: $url — closing player');
    if (mounted && Navigator.canPop(context)) {
      Navigator.pop(context, 'needs_login');
    }
  }

  static bool _isLoginRedirect(String url) {
    if (url.isEmpty) return false;
    if (url == 'about:blank') return false;
    if (url.startsWith('https://signin.volleyballworld.com')) return true;
    if (url.startsWith('https://tv.volleyballworld.com/login')) return true;
    return false;
  }

  void _markPlayerReady() {
    _initRetryTimer?.cancel();
    _initRetryTimer = null;
  }

  void _scheduleInitRetry() {
    _initRetryTimer?.cancel();
    _initRetryTimer = Timer(const Duration(seconds: 15), () {
      if (!mounted || _playerReady || _initRetryDone) return;
      _initRetryDone = true;
      debugPrint('[player] initial load timeout — retrying playerUrl');
      _loadUrl(widget.playerUrl);
    });
  }

  bool _handleRemoteKey(KeyEvent event) {
    if (!mounted || !_playerReady) return false;
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) return false;

    final isDown = event is KeyDownEvent;

    // Jede Taste blendet Controls wieder ein
    if (!_showControls) {
      setState(() => _showControls = true);
      _startHideControlsTimer();
      if (event.logicalKey == LogicalKeyboardKey.arrowUp ||
          event.logicalKey == LogicalKeyboardKey.arrowDown) {
        return true;
      }
    }

    switch (event.logicalKey) {
      case LogicalKeyboardKey.arrowLeft:
      case LogicalKeyboardKey.arrowRight:
        _seek(event.logicalKey == LogicalKeyboardKey.arrowRight);
        return true;
      case LogicalKeyboardKey.arrowUp:
      case LogicalKeyboardKey.arrowDown:
        return true;
      case LogicalKeyboardKey.mediaPlayPause:
      case LogicalKeyboardKey.select:
      case LogicalKeyboardKey.enter:
        if (isDown) _togglePlayPause();
        return true;
      case LogicalKeyboardKey.mediaFastForward:
        if (isDown) _changePlaybackRate(true);
        return true;
      case LogicalKeyboardKey.mediaRewind:
        if (isDown) _changePlaybackRate(false);
        return true;
    }
    return false;
  }

  @override
  void initState() {
    super.initState();
    HardwareKeyboard.instance.addHandler(_handleRemoteKey);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    SystemChrome.setPreferredOrientations([DeviceOrientation.landscapeLeft, DeviceOrientation.landscapeRight]);

    if (!_useInAppWebView) {
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..addJavaScriptChannel('FlutterChannel', onMessageReceived: _onJsMessage)
      ..setUserAgent('Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36')
      ..setNavigationDelegate(NavigationDelegate(
        onPageStarted: (_) {
          _runJs(r'''
            (function() {
              if (window._qualityPatched) return;
              window._qualityPatched = true;

              try {
                Object.defineProperty(screen, 'width',  {get: function() { return 1920; }, configurable: true});
                Object.defineProperty(screen, 'height', {get: function() { return 1080; }, configurable: true});
                Object.defineProperty(window, 'innerWidth',  {get: function() { return 1920; }, configurable: true});
                Object.defineProperty(window, 'innerHeight', {get: function() { return 1080; }, configurable: true});
                Object.defineProperty(window, 'devicePixelRatio', {get: function() { return 1; }, configurable: true});
              } catch(e) {}

              function _filterM3u8(t) {
                if (t.indexOf('#EXT-X-STREAM-INF') < 0) return t;
                var lines = t.split('\n'), best = null, bestBw = -1;
                for (var i = 0; i < lines.length; i++) {
                  var ln = lines[i].replace('\r','');
                  if (ln.indexOf('#EXT-X-STREAM-INF') !== 0) continue;
                  var m = ln.match(/BANDWIDTH=(\d+)/);
                  var bw = m ? parseInt(m[1]) : 0, ul = '';
                  for (var j = i+1; j < lines.length; j++) {
                    var jl = lines[j].trim();
                    if (jl && jl[0] !== '#') { ul = jl; break; }
                  }
                  if (bw > bestBw) { bestBw = bw; best = {inf: lines[i], url: ul}; }
                }
                if (!best) return t;
                var hdr = [];
                for (var k = 0; k < lines.length; k++) {
                  if (lines[k].replace('\r','').indexOf('#EXT-X-STREAM-INF') === 0) break;
                  hdr.push(lines[k]);
                }
                return hdr.join('\n') + '\n' + best.inf + '\n' + best.url + '\n';
              }

              var _proto = XMLHttpRequest.prototype;
              var _origOpen = _proto.open;
              var _rtDesc = Object.getOwnPropertyDescriptor(_proto, 'responseText');
              var _rDesc  = Object.getOwnPropertyDescriptor(_proto, 'response');

              _proto.open = function(method, url) {
                this._reqUrl = typeof url === 'string' ? url : '';
                var res = _origOpen.apply(this, arguments);
                if (this._reqUrl.indexOf('.m3u8') >= 0) {
                  var self = this, _filtered = null;
                  var rtGet = _rtDesc && _rtDesc.get;
                  var rGet  = _rDesc  && _rDesc.get;
                  function _get() {
                    if (_filtered) return _filtered;
                    try {
                      var raw = rtGet ? rtGet.call(self) : '';
                      if (raw && raw.indexOf('#EXT-X-STREAM-INF') >= 0) {
                        _filtered = _filterM3u8(raw);
                        return _filtered;
                      }
                      return raw || '';
                    } catch(e) { return ''; }
                  }
                  Object.defineProperty(self, 'responseText', {get: _get, configurable: true});
                  Object.defineProperty(self, 'response', {
                    get: function() {
                      if (_filtered) return _filtered;
                      try {
                        var raw = rGet ? rGet.call(self) : (rtGet ? rtGet.call(self) : '');
                        if (raw && typeof raw === 'string' && raw.indexOf('#EXT-X-STREAM-INF') >= 0) {
                          _filtered = _filterM3u8(raw);
                          return _filtered;
                        }
                        return raw;
                      } catch(e) { return ''; }
                    },
                    configurable: true
                  });
                }
                return res;
              };
            })();
          ''');
        },
        onPageFinished: (url) {
          if (_isLoginRedirect(url)) {
            _handleLoginRedirect(url);
            return;
          }
          _onPageFinished();
          // Fallback: nur wenn ready-Event und play-Event nie kommen
          Future.delayed(const Duration(seconds: 2), () {
            if (mounted && !_playerReady) {
              setState(() { _playerReady = true; _isPlaying = true; });
              _markPlayerReady();
              _startHideControlsTimer();
              _startPositionPolling();
            }
          });
        },
      ));

    // Android: Autoplay VOR loadRequest setzen damit kein Race Condition entsteht
    if (_controller!.platform is AndroidWebViewController) {
      (_controller!.platform as AndroidWebViewController)
          .setMediaPlaybackRequiresUserGesture(false);
    }

    _loadUrl(widget.playerUrl);
    } // end if (!_useInAppWebView)
    _scheduleInitRetry();
  }

  // Findet das <video>-Element im Hauptframe oder in iframes
  static const String _jsGetVideo = '''
    (function() {
      var v = document.querySelector('video');
      if (v) return v;
      var frames = document.querySelectorAll('iframe');
      for (var i = 0; i < frames.length; i++) {
        try { var fv = frames[i].contentDocument.querySelector('video'); if (fv) return fv; } catch(e) {}
      }
      return null;
    })()
  ''';

  void _startPositionPolling() {
    _positionTimer?.cancel();
    _positionTimer = Timer.periodic(const Duration(milliseconds: 500), (_) {
      if (_isInBlackScreen) return;
      _runJs('''
        try {
          var v = $_jsGetVideo;
          if (v) {
            var seekEnd = (v.seekable && v.seekable.length > 0) ? v.seekable.end(v.seekable.length - 1) : (isFinite(v.duration) ? v.duration : 0);
            FlutterChannel.postMessage(JSON.stringify({
              type: 'time',
              pos: v.currentTime,
              dur: isFinite(v.duration) ? v.duration : seekEnd,
              seekEnd: seekEnd,
              state: (window._flutterPaused || v.paused) ? 'paused' : 'playing'
            }));
          }
        } catch(e) {}
      ''');
    });
  }

  void _onPageFinished() {
    _runJs('''
      window._flutterPaused = false;

      // Überschreibt v.play() direkt – kein JW Player API-Call, kein UI-Flash
      function _flutterSetupVideo(v) {
        if (v._flutterSetup) return;
        v._flutterSetup = true;
        var origPlay = v.play.bind(v);
        v.play = function() {
          if (window._flutterPaused) return Promise.resolve();
          return origPlay();
        };
        v.addEventListener('play', function() {
          if (window._flutterPaused) setTimeout(function() { if (window._flutterPaused) v.pause(); }, 0);
        });
      }

      window.flutterPause = function() {
        window._flutterPaused = true;
        try { var v = $_jsGetVideo; if (v) v.pause(); } catch(e) {}
      };

      window.flutterPlay = function(rate) {
        window._flutterPaused = false;
        try { var v = $_jsGetVideo; if (v) { v.playbackRate = rate; v.play(); } } catch(e) {}
      };

      // Cookie-Banner automatisch akzeptieren
      (function() {
        var selectors = [
          '#onetrust-accept-btn-handler',
          '#CybotCookiebotDialogBodyLevelButtonLevelOptinAllowAll',
          '.cookie-accept', '.accept-cookies', '[data-testid="cookie-accept"]',
          'button[class*="accept"]', 'button[class*="Accept"]',
        ];
        var texts = ['accept all', 'akzeptieren', 'alle akzeptieren', 'accept'];
        function tryDismiss() {
          for (var i = 0; i < selectors.length; i++) {
            var el = document.querySelector(selectors[i]);
            if (el) { el.click(); return true; }
          }
          var btns = document.querySelectorAll('button');
          for (var j = 0; j < btns.length; j++) {
            var t = (btns[j].textContent || '').toLowerCase().trim();
            for (var k = 0; k < texts.length; k++) {
              if (t === texts[k] || t.includes(texts[k])) { btns[j].click(); return true; }
            }
          }
          return false;
        }
        var attempts = 0;
        var cookieTimer = setInterval(function() {
          if (tryDismiss() || attempts++ > 20) clearInterval(cookieTimer);
        }, 500);
      })();

      // Autoplay
      var autoPlay = setInterval(function() {
        try {
          var v = $_jsGetVideo;
          if (v) { _flutterSetupVideo(v); v.play(); clearInterval(autoPlay); }
        } catch(e) {}
      }, 100);


      // Hebt <video> über alle JW Player UI-Elemente (Titel, Controlbar, Overlays)
      var _jwCss = [
        'video{position:fixed!important;top:0!important;left:0!important;',
        'width:100%!important;height:100%!important;object-fit:contain!important;',
        'z-index:9999999!important;background:#000!important;pointer-events:none!important;}',
        'body{background:#000!important;overflow:hidden!important;margin:0!important;padding:0!important;}',
        '.jw-wrapper>*:not(.jw-media),.jw-title,.jw-display,.jw-controlbar,',
        '.jw-dock,.jw-logo,.jw-controls,.jw-icon-display,',
        '.jw-display-icon-container,.jw-nextup-container,.jw-overlays,.jw-preview{',
        'display:none!important;visibility:hidden!important;',
        'opacity:0!important;pointer-events:none!important}',
        '.jw-wrapper{cursor:none!important;background:#000!important;}',
        '.jw-media{pointer-events:none!important}',
      ].join('');

      function _suppressDoc(doc) {
        try {
          if (!doc || !doc.body) return;
          if (!doc.head.querySelector('#fl-sup')) {
            var s = doc.createElement('style');
            s.id = 'fl-sup';
            s.textContent = _jwCss;
            doc.head.appendChild(s);
          }
          var sels = ['.jw-title','.jw-display','.jw-controlbar','.jw-dock',
                      '.jw-logo','.jw-controls','.jw-icon-display',
                      '.jw-display-icon-container','.jw-nextup-container'];
          sels.forEach(function(sel) {
            doc.querySelectorAll(sel).forEach(function(el) {
              el.style.setProperty('display','none','important');
              el.style.setProperty('opacity','0','important');
              el.style.setProperty('visibility','hidden','important');
            });
          });
          var w = doc.querySelector('.jw-wrapper');
          if (w) Array.from(w.children).forEach(function(c) {
            if (!c.classList.contains('jw-media')) {
              c.style.setProperty('display','none','important');
              c.style.setProperty('opacity','0','important');
            }
          });
        } catch(e) {}
      }

      function _suppressBodyLevel() {
        try {
          var wrapper = document.querySelector('.jw-wrapper');
          if (!wrapper) return;
          var pc = wrapper;
          while (pc.parentElement && pc.parentElement !== document.body) pc = pc.parentElement;
          Array.from(document.body.children).forEach(function(el) {
            if (el === pc) return;
            var t = el.tagName;
            if (t==='SCRIPT'||t==='STYLE'||t==='LINK'||t==='NOSCRIPT') return;
            if (el.id && el.id.indexOf('fl-') === 0) return;
            el.style.setProperty('display','none','important');
            el.style.setProperty('visibility','hidden','important');
          });
        } catch(e) {}
      }

      // Statt 150ms-Polling: MutationObserver feuert nur bei DOM-Änderungen,
      // requestAnimationFrame batched mehrere Mutations zu einem Suppress-Run.
      var _suppressPending = false;
      function _runSuppress() {
        _suppressPending = false;
        _suppressDoc(document);
        _suppressBodyLevel();
        document.querySelectorAll('iframe').forEach(function(iframe) {
          try {
            var doc = iframe.contentDocument || iframe.contentWindow.document;
            if (doc && doc.readyState !== 'uninitialized') {
              _suppressDoc(doc);
              _attachObserverTo(doc);
            }
          } catch(e) {}
        });
      }
      function _scheduleSuppress() {
        if (_suppressPending) return;
        _suppressPending = true;
        (window.requestAnimationFrame || function(cb){setTimeout(cb,16);})(_runSuppress);
      }
      function _attachObserverTo(doc) {
        if (!doc || doc._flObsAttached) return;
        try {
          doc._flObsAttached = true;
          var o = new MutationObserver(_scheduleSuppress);
          o.observe(doc.documentElement || doc, {
            childList: true, subtree: true,
            attributes: true, attributeFilter: ['style','class']
          });
        } catch(e) {}
      }
      _runSuppress();
      _attachObserverTo(document);
      // Iframes können verzögert reinkommen (Cookie-Banner-iframe, Player-iframe etc.)
      setTimeout(_scheduleSuppress, 500);
      setTimeout(_scheduleSuppress, 2000);
      setTimeout(_scheduleSuppress, 5000);

      var _qualityForced = false;
      function _forceMaxQuality(p) {
        if (_qualityForced) return;
        var levels = [];
        try { levels = p.getQualityLevels(); } catch(e) {}
        if (!levels || levels.length === 0) return;
        _qualityForced = true;
        var bestIdx = 0, bestVal = -1;
        for (var i = 0; i < levels.length; i++) {
          var v = (levels[i].bitrate > 0) ? levels[i].bitrate : (levels[i].height || 0);
          if (v > bestVal) { bestVal = v; bestIdx = i; }
        }
        try { p.setCurrentQuality(bestIdx); } catch(e) {}
      }

      var attempts = 0;
      var init = setInterval(function() {
        attempts++;
        try {
          var p = jwplayer();
          if (p && p.getState) {
            try { var v = $_jsGetVideo; if (v) _flutterSetupVideo(v); } catch(e) {}
            var _readyHandled = false;
            function _onPlayerReady() {
              if (_readyHandled) return;
              _readyHandled = true;
              FlutterChannel.postMessage(JSON.stringify({type:'ready', dur: p.getDuration()}));
              setTimeout(function() {
                _forceMaxQuality(p);
                if(window.flShowControls) window.flShowControls();
                ${widget.seekToLive ? '''
                try {
                  var dur = p.getDuration();
                  if (dur && isFinite(dur) && dur > 10) {
                    p.seek(Math.max(0, dur - 10));
                  } else {
                    var v = $_jsGetVideo;
                    if (v && v.seekable && v.seekable.length > 0) {
                      v.currentTime = Math.max(0, v.seekable.end(0) - 5);
                    }
                  }
                } catch(e) {}
                ''' : widget.isLive ? '''
                // "Vom Anfang an" Strategie:
                //   1. Player SOFORT pausieren — JWPlayer kann nur zum Live-Edge
                //      zurueckschnappen wenn er aktiv buffert. Pause friert
                //      die Position ein.
                //   2. Warten bis seekable.length>0 und Range >= 60s (genug DVR
                //      damit der Seek auch wirklich was bewegt).
                //   3. Drei Seek-APIs versuchen, dann play() resumen.
                //   4. Persistenter Watchdog 30s lang als Sicherheitsnetz.
                function _dbg(m) { try { FlutterChannel.postMessage(JSON.stringify({type:'debug',msg:m})); } catch(e) {} }
                _dbg('FROM-START INIT');
                try { p.pause(); } catch(_) {}
                var _attempts = 0;
                var _userInteracted = false;
                var _seekLanded = false;
                function _doSeek(reason) {
                  try {
                    var v = $_jsGetVideo;
                    if (!v || !v.seekable || v.seekable.length === 0) return false;
                    var s = v.seekable.start(0);
                    var e = v.seekable.end(0);
                    if (e - s < 10) return false;
                    var dur = 0;
                    try { dur = p.getDuration() || 0; } catch(_){}
                    _dbg('SEEK '+reason+' s='+s.toFixed(0)+' e='+e.toFixed(0)+' cur='+v.currentTime.toFixed(0)+' dur='+dur.toFixed(0));
                    try { p.seek(0); } catch(_){}
                    try { p.seek(s); } catch(_){}
                    try { v.currentTime = s; } catch(_){}
                    return true;
                  } catch(_) { return false; }
                }
                // Phase 1: warten bis seekable verwertbar ist, dann seeken + play
                var _initIv = setInterval(function() {
                  _attempts++;
                  var v = $_jsGetVideo;
                  if (!v || !v.seekable || v.seekable.length === 0) {
                    if (_attempts > 80) { clearInterval(_initIv); _dbg('TIMEOUT no seekable after 8s'); try { p.play(); } catch(_){} }
                    return;
                  }
                  var s = v.seekable.start(0);
                  var e = v.seekable.end(0);
                  var range = e - s;
                  if (range < 60) {
                    if (_attempts % 10 === 0) _dbg('waiting range='+range.toFixed(0)+'s');
                    if (_attempts > 80) {
                      clearInterval(_initIv);
                      _dbg('TIMEOUT range stays '+range.toFixed(0)+'s — seeking anyway');
                      _doSeek('timeout');
                      setTimeout(function(){ try { p.play(); } catch(_){} }, 200);
                    }
                    return;
                  }
                  // Seekable jetzt mit echtem DVR-Window — seek + play
                  clearInterval(_initIv);
                  _seekLanded = _doSeek('init');
                  setTimeout(function() {
                    try { p.play(); } catch(_){}
                    _dbg('PLAY resumed cur='+v.currentTime.toFixed(0));
                  }, 200);
                }, 100);
                // Phase 2: 30s Watchdog als Snap-Back-Schutz
                var _watchAttempts = 0;
                var _watchdog = setInterval(function() {
                  _watchAttempts++;
                  if (_userInteracted) { clearInterval(_watchdog); _dbg('watchdog off (user)'); return; }
                  if (_watchAttempts > 60) { clearInterval(_watchdog); return; }
                  try {
                    var v = $_jsGetVideo;
                    if (!v || !v.seekable || v.seekable.length === 0) return;
                    var s = v.seekable.start(0);
                    var e = v.seekable.end(0);
                    if (e - s < 10) return;
                    var cur = v.currentTime;
                    var posInWindow = (cur - s) / (e - s);
                    if (posInWindow > 0.5 || (e - cur) < 30) {
                      _dbg('DRIFT '+(posInWindow*100).toFixed(0)+'% — reseek');
                      _doSeek('drift');
                    }
                  } catch(_) {}
                }, 500);
                // User-Interaktion (Pfeiltasten) deaktiviert den Watchdog
                document.addEventListener('keydown', function(e) {
                  if (e.keyCode >= 37 && e.keyCode <= 40) _userInteracted = true;
                }, true);
                ''' : ''}
              }, 0);
            }
            p.on('ready', _onPlayerReady);
            // Race condition fix: wenn der Player schon ueber 'idle' hinaus
            // ist (z.B. wegen warmem Preload), hat 'ready' bereits gefeuert
            // — der Listener oben verpasst es. Daher Handler hier nochmal
            // direkt anstossen. Vorher wurde nur eine Flutter-Nachricht
            // gepostet, der Seek-Code im setTimeout(0) ist nie gelaufen —
            // genau warum "Vom Anfang an" auf Live-Streams nicht griff.
            try {
              var st = p.getState();
              if (st && st !== 'idle' && st !== 'error') {
                _onPlayerReady();
              }
            } catch(e) {}
            p.on('levels', function() { _forceMaxQuality(p); });
            p.on('play',  function() {
              if (!window._flutterPaused) FlutterChannel.postMessage(JSON.stringify({type:'play'}));
            });
            p.on('pause', function() { FlutterChannel.postMessage(JSON.stringify({type:'pause'})); });
            p.on('time',  function(e) { FlutterChannel.postMessage(JSON.stringify({type:'time', pos: e.position, dur: e.duration})); });
            p.on('complete', function() { FlutterChannel.postMessage(JSON.stringify({type:'complete'})); });
            clearInterval(init);
          }
        } catch(e) {}
        if (attempts > 60) clearInterval(init);
      }, 100);

      // TV-Fernbedienung: D-Pad-Tasten über FlutterChannel weiterleiten
      document.addEventListener('keydown', function(e) {
        var map = {
          37: 'left', 38: 'up', 39: 'right', 40: 'down',
          13: 'select', 32: 'select',
          179: 'playPause', 228: 'fastForward', 227: 'rewind',
          8: 'back', 27: 'back', 166: 'back'
        };
        var key = map[e.keyCode];
        if (key) {
          try { FlutterChannel.postMessage(JSON.stringify({type:'key', key:key})); } catch(err) {}
          e.preventDefault();
          e.stopPropagation();
          return false;
        }
      }, true);
    ''');
  }

  void _handleJsKey(String key) {
    if (!mounted) return;
    // Jede Taste blendet Controls ein
    if (!_showControls) setState(() => _showControls = true);
    _startHideControlsTimer();
    if (!_playerReady && key != 'back') return;
    switch (key) {
      case 'left':  _seek(false); break;
      case 'right': _seek(true);  break;
      case 'up':
      case 'down':  break;
      case 'select':
      case 'playPause': _togglePlayPause(); break;
      case 'fastForward': _changePlaybackRate(true);  break;
      case 'rewind':      _changePlaybackRate(false); break;
      case 'back':
        if (mounted) _closePlayer();
        break;
    }
  }

  void _onJsMessage(JavaScriptMessage msg) {
    try {
      final data = jsonDecode(msg.message);
      final type = data['type'];
      if (type == 'ready') {
        final dur = (data['dur'] ?? 0).toDouble();
        _startPositionPolling();
        if (mounted) {
          setState(() { _playerReady = true; _realDuration = dur; _isPlaying = true; });
          _markPlayerReady();
          _startHideControlsTimer();
          final safeTitle = widget.title.replaceAll("'", "\\'");
          _runJs("if(window.flSetTitle) window.flSetTitle('$safeTitle');");
        }
      } else if (type == 'play') {
        if (!_playerReady) {
          // 'ready' might have been missed — unlock controls on first play
          _startPositionPolling();
          setState(() { _playerReady = true; _isPlaying = true; });
          _markPlayerReady();
          _startHideControlsTimer();
        } else {
          setState(() => _isPlaying = true);
        }
      } else if (type == 'pause') {
        setState(() => _isPlaying = false);
      } else if (type == 'time') {
        if (!_isInBlackScreen) {
          final sinceToggle = _lastUserToggle == null
              ? const Duration(seconds: 99)
              : DateTime.now().difference(_lastUserToggle!);
          setState(() {
            _fakePosition = Duration(milliseconds: ((data['pos'] ?? 0.0) * 1000).toInt());
            _realDuration = (data['dur'] ?? _realDuration).toDouble();
            if (widget.isLive && data['seekEnd'] != null) {
              final se = (data['seekEnd'] as num).toDouble();
              if (se > 0) _liveEdge = se;
            }
            if (sinceToggle.inMilliseconds > 1500) {
              final state = data['state'] as String?;
              if (state != null) _isPlaying = state == 'playing';
            }
          });
        }
      } else if (type == 'key') {
        _handleJsKey(data['key'] as String? ?? '');
      } else if (type == 'complete') {
        if (widget.isLive) {
          // Live-Stream endet nie künstlich
        } else if (widget.useRealDuration || _realDuration > 7200) {
          setState(() => _isPlaying = false);
        } else {
          _startBlackScreen();
        }
      } else if (type == 'debug') {
        final msg = data['msg'] as String? ?? '';
        setState(() => _debugMsg = msg);
        // Bei Live-Streams 30s anzeigen damit Vom-Anfang-an-Diagnose
        // tatsaechlich lesbar bleibt (init + seek + drift-Events).
        final dur = widget.isLive ? const Duration(seconds: 30) : const Duration(seconds: 8);
        Future.delayed(dur, () {
          if (mounted && _debugMsg == msg) setState(() => _debugMsg = '');
        });
      }
    } catch (_) {}
  }

  void _startBlackScreen() {
    if (_isInBlackScreen) return;
    setState(() { _isInBlackScreen = true; _isPlaying = true; });
    _blackScreenTimer?.cancel();
    _blackScreenTimer = Timer.periodic(const Duration(milliseconds: 500), (t) {
      if (!mounted) { t.cancel(); return; }
      if (!_isPlaying) return;
      setState(() {
        _fakePosition += Duration(milliseconds: (500 * _playbackRate).round());
        if (_fakePosition >= _effectiveDuration) { _fakePosition = _effectiveDuration; t.cancel(); }
      });
    });
  }

  void _seekToFakePosition(Duration target) {
    if (target < Duration.zero) target = Duration.zero;
    if (target > _effectiveDuration) target = _effectiveDuration;
    final real = _realDuration;
    final targetSecs = target.inMilliseconds / 1000.0;
    final wasPlaying = _isPlaying;

    _blackScreenTimer?.cancel();

    if (targetSecs <= real) {
      setState(() { _isInBlackScreen = false; _fakePosition = target; _isPlaying = wasPlaying; });
      _runJs('try { var v=$_jsGetVideo; if(v) v.currentTime=$targetSecs; } catch(e) {}');
      if (wasPlaying) {
        _runJs('if(window.flutterPlay) window.flutterPlay($_playbackRate);');
      } else {
        _runJs('if(window.flutterPause) window.flutterPause();');
      }
    } else {
      _runJs('if(window.flutterPause) window.flutterPause();');
      setState(() { _isInBlackScreen = true; _fakePosition = target; _isPlaying = wasPlaying; });
      if (wasPlaying) {
        _blackScreenTimer = Timer.periodic(const Duration(milliseconds: 500), (t) {
          if (!mounted) { t.cancel(); return; }
          if (!_isPlaying) return;
          setState(() {
            _fakePosition += Duration(milliseconds: (500 * _playbackRate).round());
            if (_fakePosition >= _effectiveDuration) { _fakePosition = _effectiveDuration; t.cancel(); }
          });
        });
      }
    }
  }

  void _togglePlayPause() {
    final nowPlaying = !_isPlaying;
    _lastUserToggle = DateTime.now();
    setState(() {
      _isPlaying = nowPlaying;
      if (!nowPlaying && _playbackRate > 1.0) _playbackRate = 1.0;
    });
    if (!_isInBlackScreen) {
      if (nowPlaying) {
        _runJs('if(window.flutterPlay) window.flutterPlay($_playbackRate);');
      } else {
        _runJs('if(window.flutterPause) window.flutterPause();');
      }
    }
    _startHideControlsTimer();
  }

  void _startHideControlsTimer() {
    _hideControlsTimer?.cancel();
    _hideControlsTimer = Timer(const Duration(seconds: 2), () {
      if (mounted) setState(() => _showControls = false);
    });
  }

  int _getSeekSeconds(int clicks) {
    if (clicks <= 0) return 0;
    if (clicks <= _seekSteps.length) return _seekSteps[clicks - 1];
    return _seekSteps.last + (clicks - _seekSteps.length) * 600;
  }

  void _changePlaybackRate(bool faster) {
    const rates = [1.0, 2.0, 4.0, 8.0];
    final idx = rates.indexOf(_playbackRate);
    final nextIdx = (faster ? idx + 1 : idx - 1).clamp(0, rates.length - 1);
    final next = rates[nextIdx];
    if (next == _playbackRate) return;
    setState(() => _playbackRate = next);
    if (!_isInBlackScreen) {
      _runJs('try { var v=$_jsGetVideo; if(v) v.playbackRate=$next; } catch(e) {}');
    }
    _startHideControlsTimer();
  }

  void _seek(bool forward) {
    _seekTimer?.cancel();
    _seekClickCount += forward ? 1 : -1;

    if (_seekClickCount == 0) {
      _pendingSeekSeconds = 0;
      setState(() { _showSeekOverlay = false; });
      return;
    }

    final isForward = _seekClickCount > 0;
    final absCount = _seekClickCount.abs();
    _pendingSeekSeconds = _getSeekSeconds(absCount);
    final seekText = '${isForward ? '+' : '-'}${_formatSeekTime(_pendingSeekSeconds)}';
    setState(() {
      _showSeekOverlay = true;
      _showControls = true;
      _seekOverlayText = seekText;
    });
    _runJs("if(window.flShowSeek) window.flShowSeek('$seekText');");
    _seekTimer = Timer(const Duration(milliseconds: 600), () {
      final target = isForward
          ? _fakePosition + Duration(seconds: _pendingSeekSeconds)
          : _fakePosition - Duration(seconds: _pendingSeekSeconds);
      _seekToFakePosition(target);
      _seekClickCount = 0;
      _pendingSeekSeconds = 0;
      if (mounted) { setState(() => _showSeekOverlay = false); _startHideControlsTimer(); }
    });
  }

  String _formatSeekTime(int s) {
    if (s < 60) return '${s}s';
    if (s < 3600) return '${s ~/ 60}min';
    return '${s ~/ 3600}h ${(s % 3600) ~/ 60}min';
  }

  String _formatDuration(Duration d) {
    final h = d.inHours;
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return h > 0 ? '$h:$m:$s' : '$m:$s';
  }

  void _closePlayer() {
    _runJs(
      'try{jwplayer().stop();}catch(e){}'
      'try{var v=document.querySelector("video");if(v){v.pause();v.src="";v.load();}}catch(e){}'
    );
    _loadUrl('about:blank');
    if (mounted) Navigator.pop(context);
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_handleRemoteKey);
    _seekTimer?.cancel();
    _hideControlsTimer?.cancel();
    _positionTimer?.cancel();
    _blackScreenTimer?.cancel();
    _initRetryTimer?.cancel();
    try {
      _runJs(
        'try{jwplayer().stop();}catch(e){}'
        'try{var v=document.querySelector("video");if(v){v.pause();v.src="";v.load();}}catch(e){}'
      );
      _loadUrl('about:blank');
    } catch (_) {}
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    SystemChrome.setPreferredOrientations([]);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        _closePlayer();
      },
      child: Scaffold(
      backgroundColor: Colors.black,
      body: Stack(children: [
          _buildWebViewWidget(),
          // Schwarzes Overlay im Black-Screen-Modus
          if (_isInBlackScreen)
            Positioned.fill(child: Container(
              color: Colors.black,
              child: Center(child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 28),
                decoration: BoxDecoration(
                  color: Colors.orange,
                  borderRadius: BorderRadius.circular(1000),
                ),
                child: AppVariant.showClubBranding
                  ? Column(mainAxisSize: MainAxisSize.min, children: [
                      const Text('Powered by',
                        style: TextStyle(color: Colors.black54, fontSize: 15, letterSpacing: 2, fontWeight: FontWeight.w500)),
                      const SizedBox(height: 20),
                      GestureDetector(
                        onTap: () => launchUrl(Uri.parse('https://www.instagram.com/bvc_lustenau/'),
                            mode: LaunchMode.externalApplication),
                        child: Image.asset('assets/bvc_logo.png', width: 260),
                      ),
                    ])
                  // Neutrale Variante: kein Vereinsbezug, stattdessen das
                  // App-Logo mit Hinweis darunter. ClipOval wie in der AppBar —
                  // bvctv_logo.png hat KEIN Alpha und schwarze Ecken, die auf
                  // dem orangen Oval sonst als schwarzer Kasten stehen wuerden.
                  : Column(mainAxisSize: MainAxisSize.min, children: [
                      ClipOval(
                        child: Image.asset('assets/bvctv_logo.png',
                            width: 180, height: 180, fit: BoxFit.contain),
                      ),
                      const SizedBox(height: 18),
                      Text(S.blackScreenHint,
                        style: const TextStyle(color: Colors.black54, fontSize: 17, letterSpacing: 1, fontWeight: FontWeight.w500)),
                    ]),
              )),
            )),

          // Schwarze Abdeckung bis Player bereit ist
          if (!_playerReady)
            Positioned.fill(child: Container(
              color: Colors.black,
              child: const Center(child: CircularProgressIndicator(color: Colors.orange)),
            )),

          // Debug-Overlay
          if (_debugMsg.isNotEmpty)
            Positioned(top: 20, left: 10, right: 10, child: Container(
              color: Colors.black87,
              padding: const EdgeInsets.all(8),
              child: Text(_debugMsg, style: const TextStyle(color: Colors.yellow, fontSize: 11), maxLines: 5),
            )),

          // Vollflächige Touch-Overlay: links=zurück, rechts=vor
          // Erster Tap blendet Controls ein, erst weiterer Tap seeked
          if (_playerReady)
            Positioned.fill(child: Row(children: [
              Expanded(child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () {
                  if (!_showControls) {
                    setState(() => _showControls = true);
                    _startHideControlsTimer();
                  } else {
                    _seek(false);
                  }
                },
                child: const SizedBox.expand(),
              )),
              Expanded(child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () {
                  if (!_showControls) {
                    setState(() => _showControls = true);
                    _startHideControlsTimer();
                  } else {
                    _seek(true);
                  }
                },
                child: const SizedBox.expand(),
              )),
            ])),

          // Seek-Overlay
          if (_showSeekOverlay) Center(child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 16),
            decoration: BoxDecoration(color: Colors.black87, borderRadius: BorderRadius.circular(12)),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              Icon(_seekClickCount >= 0 ? Icons.fast_forward : Icons.fast_rewind, color: Colors.orange, size: 48),
              const SizedBox(height: 8),
              Text(_seekOverlayText, style: const TextStyle(color: Colors.white, fontSize: 32, fontWeight: FontWeight.bold)),
              Text(S.tapCount(_seekClickCount.abs()), style: const TextStyle(color: Colors.white54, fontSize: 14)),
            ]),
          )),

          // Controls ein/ausblenden per Tap auf die Mitte (wo keine Seek-Bereiche sind)
          if (_showControls) _buildControls(),
        ]),
      ),
    );
  }

  Widget _buildWebViewWidget() {
    if (_useInAppWebView) {
      final tokenEscaped = widget.accessToken.replaceAll('\\', '\\\\').replaceAll('"', '\\"');
      return InAppWebView(
        initialUrlRequest: URLRequest(url: WebUri(widget.playerUrl)),
        initialUserScripts: UnmodifiableListView([
          UserScript(
            source: '''
              (function() {
                // Token vor jeder Seiten-JS in localStorage setzen — verhindert,
                // dass tv.volleyballworld.com/player seinen eigenen Login zeigt.
                try {
                  localStorage.setItem("quick-bricky-login-flow.access_token", "$tokenEscaped");
                } catch(e) {}
                window.FlutterChannel = {
                  postMessage: function(msg) {
                    try { window.flutter_inappwebview.callHandler('FlutterChannel', msg); } catch(e) {}
                  }
                };
              })();
            ''',
            injectionTime: UserScriptInjectionTime.AT_DOCUMENT_START,
          ),
        ]),
        initialSettings: InAppWebViewSettings(
          mediaPlaybackRequiresUserGesture: false,
          allowsInlineMediaPlayback: true,
          javaScriptEnabled: true,
          userAgent: 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36',
        ),
        onWebViewCreated: (controller) async {
          _inAppController = controller;
          debugPrint('[bvctv-player] created. tokenLen=${widget.accessToken.length} url=${widget.playerUrl}');
          final cm = CookieManager.instance();
          final signinCookies = await cm.getCookies(url: WebUri('https://signin.volleyballworld.com'));
          final tvCookies = await cm.getCookies(url: WebUri('https://tv.volleyballworld.com'));
          debugPrint('[bvctv-player] cookies signin: ${signinCookies.map((c) => c.name).toList()}');
          debugPrint('[bvctv-player] cookies tv: ${tvCookies.map((c) => c.name).toList()}');
          controller.addJavaScriptHandler(
            handlerName: 'FlutterChannel',
            callback: (args) {
              if (args.isNotEmpty) _onJsMessage(JavaScriptMessage(message: args[0].toString()));
            },
          );
        },
        onLoadStart: (_, url) {
          debugPrint('[bvctv-player] onLoadStart: $url');
        },
        onConsoleMessage: (_, msg) {
          debugPrint('[bvctv-player] console.${msg.messageLevel}: ${msg.message}');
        },
        shouldOverrideUrlLoading: (controller, action) async {
          final url = action.request.url?.toString() ?? '';
          debugPrint('[bvctv-player] nav: $url');
          return NavigationActionPolicy.ALLOW;
        },
        onLoadStop: (controller, url) async {
          final urlStr = url?.toString() ?? '';
          debugPrint('[bvctv-player] onLoadStop: $urlStr');
          if (_isLoginRedirect(urlStr)) {
            _handleLoginRedirect(urlStr);
            return;
          }
          final ls = await controller.evaluateJavascript(source: 'JSON.stringify(Object.keys(localStorage))');
          debugPrint('[bvctv-player] localStorage keys: $ls');
          _onPageFinished();
          Future.delayed(const Duration(seconds: 4), () {
            if (mounted && !_playerReady) {
              setState(() { _playerReady = true; _isPlaying = true; });
              _markPlayerReady();
              _startHideControlsTimer();
              _startPositionPolling();
            }
          });
        },
      );
    }
    if (_controller!.platform is AndroidWebViewController) {
      return WebViewWidget.fromPlatformCreationParams(
        params: AndroidWebViewWidgetCreationParams(
          controller: _controller!.platform as AndroidWebViewController,
          displayWithHybridComposition: true,
          gestureRecognizers: {
            Factory<OneSequenceGestureRecognizer>(() => EagerGestureRecognizer()),
          },
        ),
      );
    }
    return WebViewWidget(
      controller: _controller!,
      gestureRecognizers: {
        Factory<OneSequenceGestureRecognizer>(() => EagerGestureRecognizer()),
      },
    );
  }

  Widget _buildLiveTimeDisplay() {
    final edge = _liveEdge > 0 ? _liveEdge : _realDuration;
    final pos = _fakePosition.inSeconds.toDouble();
    final behind = (edge - pos).clamp(0.0, double.infinity);
    final isAtLive = behind < 15;
    if (isAtLive) {
      return Row(mainAxisSize: MainAxisSize.min, children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
          decoration: BoxDecoration(color: Colors.red, borderRadius: BorderRadius.circular(4)),
          child: const Text('● LIVE', style: TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.bold, letterSpacing: 0.5)),
        ),
      ]);
    }
    if (_liveEdge <= 0) return const SizedBox.shrink();
    return Text('−${_formatDuration(Duration(seconds: behind.toInt()))} ${S.behindLive}',
        style: const TextStyle(color: Colors.white70, fontSize: 13));
  }

  Widget _buildControls() {
    final progress = (_fakePosition.inMilliseconds / _effectiveDuration.inMilliseconds).clamp(0.0, 1.0);
    return Stack(children: [
      // Obere Leiste: Gradient + Zurück-Button + Titel
      Positioned(
        top: 0, left: 0, right: 0,
        child: Container(
          decoration: const BoxDecoration(gradient: LinearGradient(
            begin: Alignment.topCenter, end: Alignment.bottomCenter,
            colors: [Colors.black87, Colors.transparent],
          )),
          padding: const EdgeInsets.all(16),
          child: Row(children: [
            IconButton(icon: const Icon(Icons.arrow_back, color: Colors.white), onPressed: () => Navigator.pop(context)),
            const SizedBox(width: 8),
            Expanded(child: Text(widget.title,
                style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold),
                overflow: TextOverflow.ellipsis)),
          ]),
        ),
      ),
      // Untere Leiste: Gradient + Slider + Buttons
      Positioned(
        bottom: 0, left: 0, right: 0,
        child: Container(
          decoration: const BoxDecoration(gradient: LinearGradient(
            begin: Alignment.bottomCenter, end: Alignment.topCenter,
            colors: [Colors.black87, Colors.transparent],
          )),
          padding: const EdgeInsets.fromLTRB(16, 32, 16, 16),
          child: Column(children: [
            SliderTheme(
              data: SliderTheme.of(context).copyWith(
                thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 8),
                overlayShape: const RoundSliderOverlayShape(overlayRadius: 16),
                activeTrackColor: Colors.orange, inactiveTrackColor: Colors.white24, thumbColor: Colors.orange,
              ),
              child: Slider(
                value: progress,
                onChanged: (v) { _seekToFakePosition(_effectiveDuration * v); _startHideControlsTimer(); },
              ),
            ),
            Row(children: [
              if (widget.isLive) _buildLiveTimeDisplay()
              else Text('${_formatDuration(_fakePosition)} / ${_formatDuration(_effectiveDuration)}',
                  style: const TextStyle(color: Colors.white70, fontSize: 13)),
              const Spacer(),
              if (!_isTV) ...[
                if (_playbackRate > 1.0)
                  IconButton(
                    icon: const Icon(Icons.fast_rewind, color: Colors.white, size: 36),
                    onPressed: () => _changePlaybackRate(false),
                  )
                else
                  const SizedBox(width: 48),
              ],
              IconButton(
                icon: Icon(_isPlaying ? Icons.pause_circle : Icons.play_circle, color: Colors.orange, size: 56),
                onPressed: _togglePlayPause,
              ),
              if (!_isTV)
                IconButton(
                  icon: Icon(Icons.fast_forward,
                      color: _playbackRate >= 8.0 ? Colors.white38 : Colors.white, size: 36),
                  onPressed: () => _changePlaybackRate(true),
                ),
              const Spacer(),
              if (_playbackRate > 1.0)
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                  decoration: BoxDecoration(
                    color: Colors.orange,
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Text(
                    '${_playbackRate.toStringAsFixed(0)}×',
                    style: const TextStyle(color: Colors.black, fontSize: 13, fontWeight: FontWeight.bold),
                  ),
                )
              else if (!_isTV)
                const SizedBox(width: 44),
            ]),
          ]),
        ),
      ),
    ]);
  }
}

