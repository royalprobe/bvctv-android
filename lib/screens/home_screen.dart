import 'package:flutter/material.dart';

import 'package:flutter/services.dart';
import '../l10n/app_language.dart';
import '../app_variant.dart';
import '../data/tournament_sources.dart';
import '../models/video_item.dart';
import '../widgets/pickers.dart';
import '../widgets/tv_widgets.dart';
import '../l10n/strings.dart';
import 'package:url_launcher/url_launcher.dart';
import 'login_screen.dart';
import 'package:http/http.dart' as http;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform;
import 'package:package_info_plus/package_info_plus.dart';
import '../services/update_checker.dart';
import '../services/vbw_titles.dart';
import '../services/auth_service.dart';
import '../services/auth_state.dart';
import '../services/silent_login_flow.dart';
import '../services/laola_stream_extractor.dart';
import '../services/laola_livestream_scraper.dart';
import '../services/twitch_api.dart';
import 'player_screen.dart';
import 'webview_player_screen.dart';

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
  Timer? _laolaScrapeTimer;
  /// Abstand der Laola-Livestream-Scrapes. Ein Turnier kann mitten in der
  /// Session live gehen; 12 Minuten sind frueh genug und kosten nur einen
  /// HTML-Abruf.
  static const _laolaScrapeInterval = Duration(minutes: 12);
  /// Wie oft "Alle Turniere" im Hintergrund neu gebaut werden darf. Bewusst
  /// deutlich seltener als der 90s-Tick des _videoRefreshTimer — siehe die
  /// Begruendung dort.
  static const _aggregateRefreshInterval = Duration(minutes: 10);
  /// Zeitpunkt des letzten Aggregat-Aufbaus (in _loadVideos gesetzt).
  DateTime? _lastAggregateRefresh;
  // Dynamisch aus https://www.laola1.at/de/tvthek/livestreams/ gescrapte
  // Beach-Turniere — die EINZIGE Laola-Quelle. Es gab hier frueher zusaetzlich
  // eine hartcodierte Turnier-Tabelle; die veraltete zwangslaeufig und kostete
  // bei jedem Start Verfuegbarkeits-Requests fuer laengst gelaufene Turniere.
  List<Map<String, Object>> _scrapedLaolaTournaments = const [];
  WebViewController? _preloadController;
  String? _preloadedVideoId;
  bool _isLoading = true;
  String? _errorMessage;
  int _videosLoadEpoch = 0;
  String _genderFilter = 'all';
  /// Leer bis _loadTournamentList das neueste Turnier ermittelt hat. Bewusst
  /// KEINE echte Playlist-ID als Default: die wuerde hier sonst mit dem
  /// ermittelten Turnier zusammenfallen koennen, needsReload waere false und
  /// der erste Ladevorgang wuerde nie ausgeloest — Ladescreen ohne Ende.
  /// _videoRefreshTimer prueft auf isEmpty und laeuft solange nicht.
  String _currentPlaylistId = '';
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

  // ── Abgeleitete Listen, memoisiert ──────────────────────────────────────
  // Diese vier Getter liefen bei JEDEM build() komplett neu. In "Alle
  // Turniere" stecken ueber 2000 Videos, und _filteredVideos wurde von
  // GridView.builder sogar pro Kachel aufgerufen (einmal fuer itemCount,
  // einmal je itemBuilder) — jedes Mal inklusive Sortierung der ganzen Liste.
  // _availablePlayers und _availableCountries laufen zusaetzlich pro Video
  // durch mehrere Regex-Operationen und werden dreimal je build abgefragt.
  // Zusammen mit dem setState aus _startPreload (300ms nach jedem Fokus)
  // war die Kachel-Navigation auf dem Fire Stick dadurch spuerbar stockend.
  //
  // Die Quelllisten werden nie mutiert, sondern immer komplett ersetzt —
  // Identitaet genuegt daher als Cache-Schluessel. Der Minutenbucket haelt die
  // zeitabhaengigen Anteile (isLive/isUpcoming) frisch.
  List<VideoItem>? _allVideosCache;
  Object? _allVideosKey;
  List<VideoItem>? _filteredCache;
  Object? _filteredKey;
  List<String>? _playersCache;
  Object? _playersKey;
  List<String>? _countriesCache;
  Object? _countriesKey;

  int get _minuteBucket =>
      DateTime.now().millisecondsSinceEpoch ~/ Duration.millisecondsPerMinute;

  List<VideoItem> get _allVideos {
    final key = (_videos, _liveVideos, _sourceVbw, _sourceLaola, _sourceTwitch);
    final cached = _allVideosCache;
    if (cached != null && _allVideosKey == key) return cached;
    final result = _computeAllVideos();
    _allVideosKey = key;
    return _allVideosCache = result;
  }

  List<VideoItem> _computeAllVideos() {
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
    final all = _allVideos;
    final key = (all, _genderFilter);
    final cached = _countriesCache;
    if (cached != null && _countriesKey == key) return cached;
    final result = _computeCountries(all);
    _countriesKey = key;
    return _countriesCache = result;
  }

  /// Die Regexes hier waren vorher pro Video neu kompiliert — bei ueber 2000
  /// Videos macht das einen messbaren Unterschied.
  static final RegExp _countryRe = RegExp(r'\(([A-Z]{2,3})\)');
  static final RegExp _teamSplitRe = RegExp(r'\s+v(?:s)?\s+');
  static final RegExp _trailingCountryRe = RegExp(r'\s*\([A-Z]{2,3}\)\s*$');

  List<String> _computeCountries(List<VideoItem> allVideos) {
    final countries = <String>{};
    for (final v in _byGender(allVideos)) {
      for (final m in _countryRe.allMatches(v.teams)) {
        countries.add(m.group(1)!);
      }
    }
    return countries.toList()..sort();
  }

  /// Gender-Filter als eine Stelle statt dreimal derselben Verschachtelung.
  Iterable<VideoItem> _byGender(List<VideoItem> videos) {
    switch (_genderFilter) {
      case 'men':
        return videos.where((v) => v.gender == 'Men');
      case 'women':
        return videos.where((v) => v.gender == 'Women');
      default:
        return videos;
    }
  }

  List<String> get _availablePlayers {
    final all = _allVideos;
    final key = (all, _genderFilter);
    final cached = _playersCache;
    if (cached != null && _playersKey == key) return cached;
    final result = _computePlayers(all);
    _playersKey = key;
    return _playersCache = result;
  }

  List<String> _computePlayers(List<VideoItem> allVideos) {
    final players = <String>{};
    for (final v in _byGender(allVideos)) {
      final teamParts = v.teams.split(_teamSplitRe);
      for (final team in teamParts) {
        final cleaned = team.replaceAll(_trailingCountryRe, '').trim();
        for (final player in cleaned.split('/')) {
          final p = player.trim();
          if (p.isNotEmpty && p.length > 1) players.add(p);
        }
      }
    }
    return players.toList()..sort();
  }

  List<VideoItem> get _filteredVideos {
    final all = _allVideos;
    // Der Minutenbucket ist hier drin, weil isLive/isUpcoming von der Uhrzeit
    // abhaengen: ein angesetztes Match muss auftauchen sobald es laeuft, auch
    // wenn sich sonst nichts geaendert hat.
    final key = (all, _genderFilter, _playerFilter, _countryFilter, _minuteBucket);
    final cached = _filteredCache;
    if (cached != null && _filteredKey == key) return cached;
    final result = _computeFilteredVideos(all);
    _filteredKey = key;
    return _filteredCache = result;
  }

  List<VideoItem> _computeFilteredVideos(List<VideoItem> allVideos) {
    // Ein Durchlauf statt bis zu vier Zwischenlisten. Bei ueber 2000 Videos
    // waren das vorher vier volle Kopien pro Aufruf.
    final pf = _playerFilter;
    final cf = _countryFilter != null ? '($_countryFilter)' : null;
    final videos = _byGender(allVideos)
        .where((v) => v.isLive || !v.isUpcoming)
        .where((v) => pf == null || v.teams.contains(pf))
        .where((v) => cf == null || v.teams.contains(cf))
        .toList();
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
      // "Alle Turniere" nur selten refreshen: die Aggregation holt JEDE
      // VBW-Playlist neu, gemessen ~4 MB pro Durchlauf. Im 90s-Takt waeren
      // das ~170 MB/Stunde plus das Parsen von ueber 2000 JSON-Eintraegen,
      // und das auf einem Fire Stick. Der eigentliche Zweck — frische
      // Live-Zustaende — wird von _loadLiveAndUpcoming im 60s-Takt gezielt
      // und mit einem Bruchteil der Daten erledigt.
      if (pid == _allId) {
        final last = _lastAggregateRefresh;
        if (last != null &&
            DateTime.now().difference(last) < _aggregateRefreshInterval) {
          return;
        }
      }
      _loadVideos(null, true, true);
    });
    if (Platform.isAndroid) {
      PackageInfo.fromPlatform().then((i) { if (mounted) setState(() => _appVersion = i.version); });
      Future.delayed(const Duration(seconds: 10), _checkForUpdateOnce);
    }
    // Laola1-Livestream-Scraper laeuft erst NACH dem App-Start, damit VBW-
    // Playlists und Update-Check nicht durch einen externen Fetch verzoegert
    // werden. Danach periodisch: die Court-IDs sind zwar den Tag ueber stabil,
    // aber ein Turnier das WAEHREND der Session live geht wuerde sonst nie
    // auftauchen — auf einem Fire Stick der tagelang laeuft heisst das: den
    // ganzen Tag nichts Neues. Ein HTML-Abruf ist billig genug dafuer.
    Future.delayed(const Duration(seconds: 8), _scrapeLaolaLivestreams);
    _laolaScrapeTimer = Timer.periodic(
        _laolaScrapeInterval, (_) => _scrapeLaolaLivestreams());
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

    _scrapedLaolaTournaments = validated;
    if (validated.isEmpty) return;

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
    final newEntries = validated
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
    _laolaScrapeTimer?.cancel();
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
            return TvFocusButton(
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
              TvFocusButton(
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
                  return TvFocusButton(
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
                TvFocusButton(
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
                TvFocusButton(
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
                    TvFocusButton(
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

      // Virtuelle Turniere immer anhängen
      final virtualEntries = virtualTournamentData
          .map((vt) => {'id': vt['id'] as String, 'title': vt['title'] as String})
          .toList();

      if (cgPlaylistIds.isEmpty) {
        // Kein API-Ergebnis → wenigstens die virtuellen Turniere zeigen.
        // Laola-Turniere stehen hier bewusst NICHT mehr: die kamen frueher aus
        // einer hartcodierten Tabelle, die zwangslaeufig veraltete. Sie liefert
        // der Scraper jetzt zur Laufzeit (_scrapeLaolaLivestreams).
        final fallback = virtualEntries;
        if (mounted) {
          setState(() {
            _availableTournaments = fallback;
            _currentPlaylistId = fallback.first['id']!;
          });
          _loadVideos(fallback.first['id']!);
        }
        return;
      }

      // BEWUSST kein Vorab-Laden der ersten Playlist. Das gab es hier mal
      // ("erste Playlist SOFORT laden, ohne auf die Titel aller anderen zu
      // warten"), war aber irrefuehrend: cgPlaylistIds.first ist
      // "Challenge I 2026" — eine Playlist aus reinen YouTube-Links. Beim
      // Start standen also erst die Challenge-Turniere da und wurden Sekunden
      // spaeter vom tatsaechlich neuesten Turnier ersetzt. Welches das ist,
      // weiss man erst nach dem Sortieren (das Datum steckt in den Titel-
      // Requests, und das aktuellste Turnier kommt sogar aus der Bridge).
      // Bis dahin bleibt _isLoading true und der Ladescreen stehen.

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
      final youtubeTournamentsF = Future.wait(youtubePlaylistIds.map((pid) async {
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
          : Future.wait(laolaDynamicPlaylists.map((config) async {
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

      final realTournaments = await realTournamentsF;
      final youtubeTournaments = await youtubeTournamentsF;
      final laolaDynamicTournaments = await laolaDynamicF;
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
        // "Alle Turniere" kann berechnet und gecached worden sein, bevor der
        // Bridge-Scrape fertig war — dann fehlen ihr genau die Videos des
        // laufenden Turniers. Cache verwerfen, damit sie beim naechsten
        // Oeffnen frisch gebaut wird.
        if (_vbwBridgeItems.isNotEmpty) _videosCache.remove(_allId);
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
          'title': normalizeBridgeTournamentTitle(title),
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

    for (final lt in _scrapedLaolaTournaments) {
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

    for (final config in laolaDynamicPlaylists) {
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
    // Vor dem ersten _loadTournamentList steht noch kein Turnier fest, es gibt
    // also nichts zu laden. Erreichbar ueber den Aktualisieren-Button, der
    // waehrend des Starts schon da ist. _isLoading bleibt auf seinem
    // Startwert true, der Ladescreen also stehen.
    if (pid.isEmpty) return;
    // Jeder explizite Ladevorgang macht die noch laufenden ungueltig. Ohne das
    // hier wurde die Epoche NUR in _loadTournamentList erhoeht, ein
    // Turnierwechsel also nie: ein langsamer Ladevorgang (die Aggregation holt
    // ueber 20 Playlists) lief nach dem Wechsel weiter und schrieb am Ende
    // seine Videos in die Liste — der User sah die Videos des Turniers, das er
    // gerade verlassen hatte. Stille Hintergrund-Refreshes zaehlen NICHT hoch,
    // sie duerfen eine Nutzer-Auswahl nicht verdraengen (und werden umgekehrt
    // von ihr verdraengt, weil ihre Epoche dann veraltet ist).
    if (!silent) _videosLoadEpoch++;
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

    if (!silent) {
      setState(() {
        _isLoading = true;
        _errorMessage = null;
        // Alte Liste verwerfen. Sonst stehen bis zum Eintreffen der neuen
        // Daten die Videos des VORHERIGEN Turniers da — mitsamt Spieler- und
        // Land-Dropdowns, die dann nicht zur sichtbaren Auswahl passen. Ein
        // Ladescreen ist ehrlicher als ein falscher Inhalt.
        _videos = const [];
      });
    }
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
        final dynConfig = laolaDynamicPlaylists
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

        // Lookup gegen die zur Laufzeit gescrapten Laola-Eintraege.
        final ltData = _scrapedLaolaTournaments
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
        final vtData = virtualTournamentData.cast<Map<String, Object>>()
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
            ? virtualTournamentData.map(_loadVirtualTournament)
            : const <Future<List<VideoItem>>>[];
        // VBW-Bridge-Items mitnehmen. Die playlistFutures oben ueberspringen
        // ALLE '__'-IDs, also auch die Bridge-Turniere — dadurch fehlte ein
        // laufendes Turnier hier komplett, obwohl es im Dropdown auswaehlbar
        // war (Rio 2026: neuestes Video in "Alle Turniere" war Gstaad von
        // Anfang Juli). Kein Netzwerk noetig, die Items liegen seit dem
        // Bridge-Scrape im Cache; Duplikate faengt die Dedupe unten ab.
        final bridgeFuture = _sourceVbw
            ? Future.value(
                _vbwBridgeItems.values.expand((l) => l).toList(growable: false))
            : Future.value(const <VideoItem>[]);
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
          bridgeFuture,
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
        _lastAggregateRefresh = DateTime.now();
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
    return TvFocusButton(
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
    return TvFocusButton(
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
        builder: (_) => TournamentSheet(
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
      child: TvFocusButton(
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
        builder: (_) => PlayerSearchSheet(players: players, selected: _playerFilter),
      );
      if (result == null) return;
      setState(() => _playerFilter = result.isEmpty ? null : result);
    }
    return TvFocusButton(
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
        builder: (_) => CountrySearchSheet(countries: countries, selected: _countryFilter),
      );
      if (result == null) return;
      setState(() => _countryFilter = result.isEmpty ? null : result);
    }
    return TvFocusButton(
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
    return VideoCard(
      // Ohne Key recycelt GridView.builder den State nach POSITION statt nach
      // Video: ein aufgedecktes Finale hat dadurch das Finale jedes anderen
      // Turniers gleich mit aufgedeckt, weil beide auf demselben Grid-Platz
      // landen. Der Aufdeck-Zustand muss am Video haengen.
      key: ValueKey(video.id),
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
                  TvFocusButton(
                    autofocus: true,
                    borderRadius: 6,
                    onPressed: () => Navigator.pop(ctx, false),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                      child: Text(S.cancel, style: const TextStyle(color: Colors.white54)),
                    ),
                  ),
                  const Spacer(),
                  TvFocusButton(
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
                        // Waehrend eines nicht-stillen Ladevorgangs NUR den
                        // Spinner. Frueher stand hier "_isLoading &&
                        // _videos.isEmpty" — beim Turnierwechsel blieb damit
                        // die alte Liste sichtbar und sah aus wie das Ergebnis
                        // der neuen Auswahl. Hintergrund-Refreshes laufen
                        // silent und setzen _isLoading gar nicht erst.
                        : _isLoading
                        ? const Center(child: CircularProgressIndicator(color: Colors.orange))
                        : LayoutBuilder(builder: (context, constraints) {
                            // Einmal pro Layout holen, nicht pro Kachel. Der
                            // Getter ist inzwischen memoisiert, aber so ist es
                            // auch ohne Cache O(1) je Kachel.
                            final videos = _filteredVideos;
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
                                itemCount: videos.length,
                                itemBuilder: (_, i) => _buildVideoCard(videos[i]),
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
