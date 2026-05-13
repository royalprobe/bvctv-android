import 'package:flutter/material.dart';

import 'package:flutter/services.dart';
import '../l10n/app_language.dart';
import '../l10n/strings.dart';
import 'package:url_launcher/url_launcher.dart';
import 'login_screen.dart';
import 'player_screen.dart';
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
import 'dart:math';
import 'package:crypto/crypto.dart';
import 'package:package_info_plus/package_info_plus.dart';
import '../services/update_checker.dart';

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

  bool get isYouTube => linkUrl != null;
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
  final String accessToken;
  const HomeScreen({super.key, required this.accessToken});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  List<VideoItem> _videos = [];
  List<VideoItem> _liveVideos = [];
  Timer? _liveRefreshTimer;
  Timer? _videoRefreshTimer;
  Timer? _preloadFocusTimer;
  WebViewController? _preloadController;
  String? _preloadedVideoId;
  bool _bgSessionDone = false;
  String? _silentCodeVerifier;
  final Completer<void> _bgSessionCompleter = Completer<void>();
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

  final _storage = const FlutterSecureStorage();
  String _appVersion = '';

  static const _spoilerRounds = {'Final', 'Semifinal', '3rd Place'};
  bool _isSpoiler(String round) => _spoilerFree && _spoilerRounds.contains(round);

  List<VideoItem> get _allVideos {
    final liveIds = _liveVideos.map((v) => v.id).toSet();
    return [..._liveVideos, ..._videos.where((v) => !liveIds.contains(v.id))];
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
    var videos = _allVideos;
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
    _restoreTvCookies();
    // Frühe Retries falls der erste Aufruf scheiterte oder langsam war
    Future.delayed(const Duration(seconds: 4), () {
      if (mounted && _liveVideos.isEmpty) _loadLiveAndUpcoming();
    });
    Future.delayed(const Duration(seconds: 12), () {
      if (mounted && _liveVideos.isEmpty) _loadLiveAndUpcoming();
    });
    _liveRefreshTimer = Timer.periodic(const Duration(seconds: 60), (_) => _loadLiveAndUpcoming());
    _videoRefreshTimer = Timer.periodic(const Duration(minutes: 2), (_) {
      if (!_isLoading) _loadVideos(null, true);
    });
    if (Platform.isAndroid) {
      PackageInfo.fromPlatform().then((i) { if (mounted) setState(() => _appVersion = i.version); });
      Future.delayed(const Duration(seconds: 10), _checkForUpdateOnce);
    }
  }

  Future<void> _checkForUpdateOnce() async {
    final info = await UpdateChecker.checkOncePerSession();
    if (info != null && mounted) _showUpdateDialog(info);
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
    _preloadFocusTimer = Timer(const Duration(milliseconds: 700), () {
      if (!mounted) return;
      final ctx = _buildCtx();
      final selfLink = Uri.encodeComponent('https://zapp-5434-volleyball-tv.web.app/jw/media/${video.id}?ctx=$ctx');
      final playerUrl = 'https://tv.volleyballworld.com/player?self-link=$selfLink';
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
    if (mounted) {
      setState(() {
        _twoHourMode = th != 'false';
        _spoilerFree = sf != 'false';
      });
    }
  }

  Future<void> _loadLiveAndUpcoming() async {
    // 1. Live-Events aus aktuell geladenem View sofort zeigen (kein Netzwerk nötig)
    final liveInView = _videos.where((v) => v.isLive).toList();
    if (liveInView.isNotEmpty && mounted) {
      setState(() => _liveVideos = liveInView);
    }

    // 2. Nur das neueste Turnier auf Live-Events prüfen (API-Reihenfolge: neueste zuerst)
    final toCheck = _availableTournaments
        .where((t) => !t['id']!.startsWith('__'))
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
      } catch (_) {}
    }));

    if (!mounted) return;
    if (liveItems.isNotEmpty) {
      setState(() => _liveVideos = liveItems);
    } else if (successCount > 0 && liveInView.isEmpty) {
      // API confirmed no live games and current view also has none → clear
      setState(() => _liveVideos = []);
    }
    // If network failed (successCount == 0), keep existing _liveVideos intact
  }

  void _showSettings() {
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
              const Divider(color: Colors.white12, height: 24),
              Row(children: [
                _TvFocusButton(
                  autofocus: true,
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
                      await _storage.delete(key: 'access_token');
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

  Future<void> _restoreTvCookies() async {
    try {
      final stored = await _storage.read(key: 'tv_cookies');
      if (stored == null) {
        debugPrint('[BVCTV] restore: no stored TV cookies, trying silent OAuth');
        return;
      }
      final cookieList = jsonDecode(stored) as List;
      final cm = CookieManager.instance();
      for (final c in cookieList) {
        await cm.setCookie(
          url: WebUri('https://tv.volleyballworld.com'),
          name: c['name'] as String,
          value: c['value'] as String,
          domain: c['domain'] as String? ?? '.tv.volleyballworld.com',
          path: c['path'] as String? ?? '/',
          isSecure: true,
          isHttpOnly: true,
          expiresDate: DateTime.now().add(const Duration(days: 30)).millisecondsSinceEpoch,
        );
      }
      debugPrint('[BVCTV] restore: restored ${cookieList.length} TV cookies');
      if (mounted) setState(() => _bgSessionDone = true);
      if (!_bgSessionCompleter.isCompleted) _bgSessionCompleter.complete();
    } catch (e) {
      debugPrint('[BVCTV] restore: error $e');
    }
  }

  String _buildCtx() {
    final payload = jsonEncode({
      'quick-bricky-login-flow.access_token': widget.accessToken,
      'platform': 'web',
    });
    return base64Url.encode(utf8.encode(payload));
  }

  String _generateCodeVerifier() {
    final random = Random.secure();
    final bytes = List<int>.generate(32, (_) => random.nextInt(256));
    return base64UrlEncode(bytes).replaceAll('=', '');
  }

  String _generateCodeChallenge(String verifier) {
    final digest = sha256.convert(utf8.encode(verifier));
    return base64UrlEncode(digest.bytes).replaceAll('=', '');
  }

  String _buildSilentAuthUrl() {
    _silentCodeVerifier = _generateCodeVerifier();
    return Uri.parse('https://signin.volleyballworld.com/service/oidc/vbtv-web/authorize').replace(
      queryParameters: {
        'response_type': 'code',
        'client_id': '93d30c71-8a06-46c3-a288-dfb48f082313',
        'redirect_uri': 'https://tv.volleyballworld.com/api/oauth',
        'scope': 'openid email profile',
        'code_challenge': _generateCodeChallenge(_silentCodeVerifier!),
        'code_challenge_method': 'S256',
        'prompt': 'none',
      },
    ).toString();
  }

  String? _findVideoUrl(dynamic obj) {
    if (obj is String) {
      if ((obj.contains('.m3u8') || obj.contains('manifest')) && obj.startsWith('https')) return obj;
      return null;
    }
    if (obj is Map) {
      for (final key in ['file', 'url', 'src', 'link', 'stream', 'videoUrl']) {
        final val = obj[key];
        if (val is String && val.startsWith('https') && (val.contains('.m3u8') || val.contains('manifest'))) {
          return val;
        }
      }
      for (final val in obj.values) {
        final found = _findVideoUrl(val);
        if (found != null) return found;
      }
    }
    if (obj is List) {
      for (final item in obj) {
        final found = _findVideoUrl(item);
        if (found != null) return found;
      }
    }
    return null;
  }

  Future<String?> _fetchStreamUrl(String videoId) async {
    try {
      final ctx = _buildCtx();
      final res = await http.get(
        Uri.parse('https://zapp-5434-volleyball-tv.web.app/jw/media/$videoId?ctx=$ctx'),
        headers: {'Origin': 'https://tv.volleyballworld.com'},
      ).timeout(const Duration(seconds: 10));
      debugPrint('[BVCTV] media status=${res.statusCode} body100=${res.body.substring(0, res.body.length.clamp(0, 300))}');
      if (res.statusCode != 200) return null;
      final data = jsonDecode(res.body);
      if (data is Map) debugPrint('[BVCTV] top-level keys: ${data.keys.toList()}');
      return _findVideoUrl(data);
    } catch (e) {
      debugPrint('[BVCTV] fetchStreamUrl error: $e');
      return null;
    }
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
      await Future.wait(['aBT42rPR', 'rkwGm18m'].map((cgId) async {
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
      final virtualEntries = _virtualTournamentData
          .map((vt) => {'id': vt['id'] as String, 'title': vt['title'] as String})
          .toList();

      if (cgPlaylistIds.isEmpty) {
        // Kein API-Ergebnis → sofort virtuelle Turniere zeigen
        if (mounted) {
          setState(() {
            _availableTournaments = virtualEntries;
            _currentPlaylistId = virtualEntries.first['id']!;
          });
          _loadVideos(virtualEntries.first['id']!);
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

      // Titel + match_date des neuesten Videos holen – 3072 Bytes reichen sicher
      // (match_date liegt bei ~1900-2000 Bytes; TCP-Burst sendet ~14KB auf einmal,
      //  daher keine Ladezeit-Erhöhung gegenüber 512 Bytes)
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
          return {'id': id, 'title': title, if (dm != null) 'matchDate': dm.group(1)!};
        } catch (_) {
          return null;
        }
      }

      final results = (await Future.wait(cgPlaylistIds.map(fetchTitle)))
          .whereType<Map<String, String>>()
          .toList();

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
        final needsReload = newFirst != _currentPlaylistId;
        setState(() {
          _availableTournaments = results;
          _currentPlaylistId = newFirst;
        });
        if (needsReload) {
          _videosLoadEpoch++;
          _loadVideos(newFirst);
        }
      }
    } catch (_) {} finally {
      if (mounted) setState(() => _isLoadingTournaments = false);
    }
  }

  static const _allId = '__all__';

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

  Future<void> _loadVideos([String? playlistId, bool silent = false]) async {
    final pid = playlistId ?? _currentPlaylistId;
    final epoch = _videosLoadEpoch;
    if (playlistId != null && mounted) setState(() { _currentPlaylistId = pid; });
    if (!silent) setState(() { _isLoading = true; _errorMessage = null; });
    try {
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
          if (mounted) setState(() => _videos = videos);
        }
        return;
      }

      if (pid == _allId) {
        final ctx = _buildCtx();
        final playlistFutures = _availableTournaments
            .where((t) => !t['id']!.startsWith('__'))
            .map((t) async {
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
        });
        final vtFutures = _virtualTournamentData.map(_loadVirtualTournament);
        final allResults = await Future.wait([...playlistFutures, ...vtFutures]);
        final all = allResults.expand((l) => l).toList();
        final seen = <String>{};
        final unique = all.where((v) => seen.add(v.id)).toList()
          ..sort((a, b) {
            if (a.matchDate == null) return 1;
            if (b.matchDate == null) return -1;
            return b.matchDate!.compareTo(a.matchDate!);
          });
        setState(() => _videos = unique);
        return;
      }

      final ctx = _buildCtx();
      final response = await http.get(
        Uri.parse('https://zapp-5434-volleyball-tv.web.app/jw/playlists/$pid?overrideFeedType=moreinfo&ctx=$ctx'),
        headers: {'Origin': 'https://tv.volleyballworld.com'},
      ).timeout(const Duration(seconds: 10));
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        final videos = (data['entry'] as List? ?? []).map(_itemFromJson).toList()
          ..sort((a, b) {
            if (a.matchDate == null) return 1;
            if (b.matchDate == null) return -1;
            return b.matchDate!.compareTo(a.matchDate!);
          });
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
    if (video.isYouTube) {
      launchUrl(Uri.parse(video.linkUrl!), mode: LaunchMode.externalApplication);
      return;
    }
    if (video.isLive) {
      _showLiveDialog(video);
      return;
    }
    _launchPlayer(video, seekToLive: false);
  }

  void _launchPlayer(VideoItem video, {required bool seekToLive}) async {
    // Warten bis Session-Cookies bereit sind (max. 6s)
    if (!_bgSessionDone) {
      await _bgSessionCompleter.future.timeout(
        const Duration(seconds: 6),
        onTimeout: () {},
      );
      if (!mounted) return;
    }
    final streamUrl = await _fetchStreamUrl(video.id);
    if (!mounted) return;

    if (streamUrl != null) {
      Navigator.push(context, MaterialPageRoute(
        builder: (_) => PlayerScreen(title: video.teams, streamUrl: streamUrl),
      ));
    } else {
      final ctx = _buildCtx();
      final selfLink = Uri.encodeComponent('https://zapp-5434-volleyball-tv.web.app/jw/media/${video.id}?ctx=$ctx');
      final playerUrl = 'https://tv.volleyballworld.com/player?self-link=$selfLink';
      Navigator.push(context, MaterialPageRoute(
        builder: (_) => WebViewPlayerScreen(
          title: video.teams,
          playerUrl: playerUrl,
          accessToken: widget.accessToken,
          useRealDuration: !_twoHourMode,
          seekToLive: seekToLive,
          isLive: video.isLive,
        ),
      ));
    }
  }

  void _showLiveDialog(VideoItem video) {
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

  Widget _tournamentDropdown() {
    if (_isLoadingTournaments) {
      return const SizedBox(
        width: 20, height: 20,
        child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white38),
      );
    }
    if (_availableTournaments.isEmpty) return const SizedBox.shrink();

    final isAll = _currentPlaylistId == _allId;
    final currentTitle = isAll
        ? S.allTournaments
        : _availableTournaments
            .firstWhere((t) => t['id'] == _currentPlaylistId, orElse: () => {'title': S.tournament})['title']!;

    Future<void> open() async {
      final result = await showModalBottomSheet<String>(
        context: context,
        backgroundColor: const Color(0xFF1A1A1A),
        isScrollControlled: true,
        shape: const RoundedRectangleBorder(
            borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
        builder: (_) => _TournamentSheet(
          tournaments: _availableTournaments,
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
      onPreload: (video.isYouTube || video.isLive || video.isUpcoming || !Platform.isAndroid)
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
        title: const Text('BVCTV', style: TextStyle(color: Colors.orange, fontWeight: FontWeight.bold, letterSpacing: 4)),
        backgroundColor: const Color(0xFF0A0A0A),
        actions: [
          IconButton(icon: const Icon(Icons.refresh), onPressed: _loadVideos),
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
                  Container(
                    color: const Color(0xFF0A0A0A),
                    padding: const EdgeInsets.fromLTRB(12, 10, 12, 6),
                    child: Row(children: [
                      _filterChip(S.all, 'all', autofocus: true),
                      const SizedBox(width: 8),
                      _filterChip(S.men, 'men'),
                      const SizedBox(width: 8),
                      _filterChip(S.women, 'women'),
                      const Spacer(),
                      _tournamentDropdown(),
                    ]),
                  ),
                  if (_availablePlayers.isNotEmpty || _availableCountries.isNotEmpty)
                    Container(
                      color: const Color(0xFF0A0A0A),
                      padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
                      child: Row(children: [
                        _playerDropdown(),
                        if (_availablePlayers.isNotEmpty && _availableCountries.isNotEmpty)
                          const SizedBox(width: 8),
                        _countryDropdown(),
                      ]),
                    ),
                  if (_isLoading)
                    const LinearProgressIndicator(color: Colors.orange, backgroundColor: Colors.transparent, minHeight: 2),
                  Expanded(
                    child: _isLoading && _videos.isEmpty
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
        // Silent OAuth: etabliert server-side Session-Cookies auf tv.volleyballworld.com
        if (!_bgSessionDone)
          Positioned(
            left: 0, top: 0, width: 1, height: 1,
            child: InAppWebView(
              initialUrlRequest: URLRequest(
                url: WebUri(_buildSilentAuthUrl()),
              ),
              initialSettings: InAppWebViewSettings(
                javaScriptEnabled: true,
                userAgent: 'Mozilla/5.0 (Linux; Android 12; Mobile) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Mobile Safari/537.36',
              ),
              shouldOverrideUrlLoading: (controller, action) async {
                final url = action.request.url?.toString() ?? '';
                debugPrint('[BVCTV] bgSession nav: $url');
                return NavigationActionPolicy.ALLOW;
              },
              onLoadStop: (controller, url) async {
                final urlStr = url?.toString() ?? '';
                debugPrint('[BVCTV] bgSession loaded: $urlStr');
                if (urlStr.contains('tv.volleyballworld.com')) {
                  if (mounted) setState(() => _bgSessionDone = true);
                  if (!_bgSessionCompleter.isCompleted) _bgSessionCompleter.complete();
                }
              },
              onReceivedError: (controller, request, error) {
                debugPrint('[BVCTV] bgSession error: ${error.description} url=${request.url}');
                if (mounted) setState(() => _bgSessionDone = true);
                if (!_bgSessionCompleter.isCompleted) _bgSessionCompleter.complete();
              },
            ),
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

  bool get _useInAppWebView => !kIsWeb && (Platform.isAndroid || Platform.isWindows);

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
  bool _isOnAuthPage = false;
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
        onPageStarted: (url) {
          final isAuth = !url.contains('volleyballworld.com') && !url.contains('zapp-5434');
          if (mounted && _isOnAuthPage != isAuth) {
            setState(() {
              _isOnAuthPage = isAuth;
              if (!isAuth) _playerReady = false;
            });
          }
          // Access-Token in localStorage setzen bevor die Seite ihren Auth-Check macht
          if (!isAuth) {
            final token = widget.accessToken.replaceAll('"', '\\"');
            _runJs('try{localStorage.setItem("quick-bricky-login-flow.access_token","$token");}catch(e){}');
          }
          _runJs(r'''
            (function() {
              if (window._qualityPatched) return;
              window._qualityPatched = true;

              if (window.location.hostname === 'tv.volleyballworld.com' ||
                  window.location.hostname.indexOf('zapp-5434') >= 0) {
                try {
                  Object.defineProperty(screen, 'width',  {get: function() { return 1920; }, configurable: true});
                  Object.defineProperty(screen, 'height', {get: function() { return 1080; }, configurable: true});
                  Object.defineProperty(window, 'innerWidth',  {get: function() { return 1920; }, configurable: true});
                  Object.defineProperty(window, 'innerHeight', {get: function() { return 1080; }, configurable: true});
                  Object.defineProperty(window, 'devicePixelRatio', {get: function() { return 1; }, configurable: true});
                } catch(e) {}
              }

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
        onPageFinished: (_) {
          _onPageFinished();
          // Fallback: nur wenn ready-Event und play-Event nie kommen
          Future.delayed(const Duration(seconds: 2), () {
            if (mounted && !_playerReady && !_isOnAuthPage) {
              setState(() { _playerReady = true; _isPlaying = true; });
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
      (function(){
      if(window.location.href.indexOf('volleyballworld.com')<0&&window.location.href.indexOf('zapp-5434')<0)return;
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

      _suppressDoc(document);
      setInterval(function() {
        _suppressDoc(document);
        _suppressBodyLevel();
        document.querySelectorAll('iframe').forEach(function(iframe) {
          try {
            var doc = iframe.contentDocument || iframe.contentWindow.document;
            if (doc && doc.readyState !== 'uninitialized') _suppressDoc(doc);
          } catch(e) {}
        });
      }, 150);

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
            p.on('ready', function() {
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
                var _seekDone = false;
                var _seekAttempts = 0;
                function _dbg(m) { try { FlutterChannel.postMessage(JSON.stringify({type:'debug',msg:m})); } catch(e) {} }
                function _doSeekToStart() {
                  try {
                    var v = $_jsGetVideo;
                    if (!v) { _dbg('NO VIDEO ELEMENT (attempt '+_seekAttempts+')'); return false; }
                    var sk = v.seekable;
                    if (!sk || sk.length === 0) { _dbg('seekable empty cur='+v.currentTime.toFixed(1)); return false; }
                    var s = sk.start(0);
                    var e = sk.end(0);
                    _dbg('seekable '+s.toFixed(1)+' -> '+e.toFixed(1)+' cur='+v.currentTime.toFixed(1)+' range='+(e-s).toFixed(1));
                    if (e - s > 10) {
                      v.currentTime = s;
                      _dbg('SEEKED to '+s.toFixed(1));
                      setTimeout(function() {
                        try {
                          var v2 = $_jsGetVideo;
                          if (!v2) return;
                          var s2 = (v2.seekable && v2.seekable.length > 0) ? v2.seekable.start(0) : s;
                          var e2 = (v2.seekable && v2.seekable.length > 0) ? v2.seekable.end(0) : e;
                          _dbg('2s after seek: cur='+v2.currentTime.toFixed(1)+' start='+s2.toFixed(1));
                          if (e2 - s2 > 10 && (v2.currentTime - s2) > (e2 - s2) * 0.5) {
                            v2.currentTime = s2;
                            _dbg('RE-SEEK to '+s2.toFixed(1));
                          }
                        } catch(err2) {}
                      }, 2000);
                      return true;
                    }
                    _dbg('range too small: '+(e-s).toFixed(1));
                  } catch(e) { _dbg('ERR: '+e); }
                  return false;
                }
                p.on('firstFrame', function() {
                  _dbg('firstFrame fired');
                  if (!_seekDone) setTimeout(function() {
                    if (!_seekDone && _doSeekToStart()) _seekDone = true;
                  }, 500);
                });
                var _seekInterval = setInterval(function() {
                  _seekAttempts++;
                  if (_seekDone) { clearInterval(_seekInterval); return; }
                  if (_doSeekToStart()) {
                    _seekDone = true;
                    clearInterval(_seekInterval);
                  }
                  if (_seekAttempts > 60) clearInterval(_seekInterval);
                }, 500);
                ''' : ''}
              }, 0);
            });
            // Race condition fix: player might already be past 'idle' when we register
            try {
              var st = p.getState();
              if (st && st !== 'idle' && st !== 'error') {
                FlutterChannel.postMessage(JSON.stringify({type:'ready', dur: p.getDuration()}));
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
      })();
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
          _startHideControlsTimer();
          final safeTitle = widget.title.replaceAll("'", "\\'");
          _runJs("if(window.flSetTitle) window.flSetTitle('$safeTitle');");
        }
      } else if (type == 'play') {
        if (!_playerReady) {
          // 'ready' might have been missed — unlock controls on first play
          _startPositionPolling();
          setState(() { _playerReady = true; _isPlaying = true; });
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
        Future.delayed(const Duration(seconds: 8), () {
          if (mounted) setState(() => _debugMsg = '');
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
                child: Column(mainAxisSize: MainAxisSize.min, children: [
                  const Text('Powered by',
                    style: TextStyle(color: Colors.black54, fontSize: 15, letterSpacing: 2, fontWeight: FontWeight.w500)),
                  const SizedBox(height: 20),
                  GestureDetector(
                    onTap: () => launchUrl(Uri.parse('https://www.instagram.com/bvc_lustenau/'),
                        mode: LaunchMode.externalApplication),
                    child: Image.asset('assets/bvc_logo.png', width: 260),
                  ),
                ]),
              )),
            )),

          // Schwarze Abdeckung bis Player bereit ist (nicht auf Auth-Seiten)
          if (!_playerReady && !_isOnAuthPage)
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
          if (_playerReady && !_isOnAuthPage)
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
          if (_showControls && !_isOnAuthPage) _buildControls(),
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
                // Token vor jeder Seiten-JS setzen – verhindert client-seitige Umleitung
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
        onWebViewCreated: (controller) {
          _inAppController = controller;
          controller.addJavaScriptHandler(
            handlerName: 'FlutterChannel',
            callback: (args) {
              if (args.isNotEmpty) _onJsMessage(JavaScriptMessage(message: args[0].toString()));
            },
          );
        },
        shouldOverrideUrlLoading: (controller, action) async {
          final url = action.request.url?.toString() ?? '';
          debugPrint('[BVCTV] player nav: $url');
          // OAuth-Callback: Session-Cookies werden vom Server gesetzt
          if (url.startsWith('https://tv.volleyballworld.com/api/oauth') && url.contains('code=')) {
            debugPrint('[BVCTV] player: OAuth-Code erhalten, lade Player nach Session-Aufbau neu');
            Future.delayed(const Duration(milliseconds: 2500), () {
              if (mounted) {
                setState(() { _isOnAuthPage = false; _playerReady = false; });
                _loadUrl(widget.playerUrl);
              }
            });
          }
          return NavigationActionPolicy.ALLOW;
        },
        onLoadStart: (controller, url) {
          final urlStr = url?.toString() ?? '';
          final isAuth = urlStr.contains('signin.volleyballworld.com') ||
              (!urlStr.contains('tv.volleyballworld.com') && !urlStr.contains('zapp-5434'));
          if (mounted && _isOnAuthPage != isAuth) {
            setState(() {
              _isOnAuthPage = isAuth;
              if (!isAuth) _playerReady = false;
            });
          }
        },
        onLoadStop: (controller, url) {
          _onPageFinished();
          Future.delayed(const Duration(seconds: 4), () {
            if (mounted && !_playerReady && !_isOnAuthPage) {
              setState(() { _playerReady = true; _isPlaying = true; });
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
