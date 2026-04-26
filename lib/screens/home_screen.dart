import 'package:flutter/material.dart';

import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';
import 'login_screen.dart';
import 'package:http/http.dart' as http;
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:webview_flutter_android/webview_flutter_android.dart';
import 'dart:async';
import 'dart:convert';

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
  });
}

class HomeScreen extends StatefulWidget {
  final String accessToken;
  const HomeScreen({super.key, required this.accessToken});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  List<VideoItem> _videos = [];
  bool _isLoading = true;
  String? _errorMessage;
  String _genderFilter = 'all';
  String _currentPlaylistId = 'QN15YAsv';
  List<Map<String, String>> _availableTournaments = [];
  bool _isLoadingTournaments = true;
  String? _playerFilter;
  String? _countryFilter;
  bool _twoHourMode = true;
  bool _spoilerFree = true;

  final _storage = const FlutterSecureStorage();

  static const _spoilerRounds = {'Finale', 'Halbfinale', '3. Platz'};
  bool _isSpoiler(String round) => _spoilerFree && _spoilerRounds.contains(round);

  List<String> get _availableCountries {
    final countries = <String>{};
    final source = _genderFilter == 'men'
        ? _videos.where((v) => v.gender == 'Men')
        : _genderFilter == 'women'
            ? _videos.where((v) => v.gender == 'Women')
            : _videos;
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
        ? _videos.where((v) => v.gender == 'Men')
        : _genderFilter == 'women'
            ? _videos.where((v) => v.gender == 'Women')
            : _videos;
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
    var videos = _videos;
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
    return videos;
  }

  @override
  void initState() {
    super.initState();
    _loadSettings();
    _loadTournamentList();
  }

  Future<void> _loadSettings() async {
    final th = await _storage.read(key: 'two_hour_mode');
    final sf = await _storage.read(key: 'spoiler_free');
    if (mounted) setState(() {
      _twoHourMode = th != 'false'; // default true wenn noch nicht gespeichert
      _spoilerFree = sf != 'false'; // default true wenn noch nicht gespeichert
    });
  }

  void _showSettings() {
    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialog) => AlertDialog(
          backgroundColor: const Color(0xFF1A1A1A),
          title: const Text('Einstellungen', style: TextStyle(color: Colors.white)),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('2-Stunden-Modus', style: TextStyle(color: Colors.white70)),
                subtitle: Text(
                  _twoHourMode
                      ? 'Fortschrittsbalken geht bis 2h (für zeitversetzte Streams)'
                      : 'Fortschrittsbalken endet mit dem Video',
                  style: const TextStyle(color: Colors.white38, fontSize: 12),
                ),
                value: _twoHourMode,
                activeColor: Colors.orange,
                onChanged: (val) {
                  setDialog(() {});
                  setState(() => _twoHourMode = val);
                  _storage.write(key: 'two_hour_mode', value: val.toString());
                },
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Spoiler-Schutz', style: TextStyle(color: Colors.white70)),
                subtitle: Text(
                  _spoilerFree
                      ? 'Teamnamen in Halbfinale/Finale/Bronze verborgen'
                      : 'Alle Teamnamen sichtbar',
                  style: const TextStyle(color: Colors.white38, fontSize: 12),
                ),
                value: _spoilerFree,
                activeColor: Colors.orange,
                onChanged: (val) {
                  setDialog(() {});
                  setState(() => _spoilerFree = val);
                  _storage.write(key: 'spoiler_free', value: val.toString());
                },
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () async {
                Navigator.pop(ctx);
                final confirm = await showDialog<bool>(
                  context: context,
                  builder: (c) => AlertDialog(
                    backgroundColor: const Color(0xFF1A1A1A),
                    title: const Text('Abmelden?', style: TextStyle(color: Colors.white)),
                    content: const Text('Du wirst ausgeloggt und musst dich erneut anmelden.',
                        style: TextStyle(color: Colors.white70)),
                    actions: [
                      TextButton(onPressed: () => Navigator.pop(c, false),
                          child: const Text('Abbrechen', style: TextStyle(color: Colors.white54))),
                      TextButton(onPressed: () => Navigator.pop(c, true),
                          child: const Text('Abmelden', style: TextStyle(color: Colors.redAccent))),
                    ],
                  ),
                );
                if (confirm == true && context.mounted) {
                  await _storage.delete(key: 'access_token');
                  Navigator.pushReplacement(context,
                      MaterialPageRoute(builder: (_) => const LoginScreen()));
                }
              },
              child: const Text('Abmelden', style: TextStyle(color: Colors.redAccent)),
            ),
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Fertig', style: TextStyle(color: Colors.orange)),
            ),
          ],
        ),
      ),
    );
  }

  String _buildCtx() {
    final payload = jsonEncode({
      'quick-bricky-login-flow.access_token': widget.accessToken,
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
    if (l.contains('1st') || l.contains('gold')) return 'Finale';
    if (l.contains('3rd') || l.contains('bronze')) return '3. Platz';
    if (l.contains('semi')) return 'Halbfinale';
    if (l.contains('quarter')) return 'Viertelfinale';
    if (l.contains('round of 16')) return 'Achtelfinale';
    if (l.contains('pool')) return 'Vorrunde';
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

  String _extractPlaylistTitle(String body) {
    try {
      final m = RegExp(r'"title":"((?:[^"\\]|\\.)*)"').firstMatch(body);
      if (m != null) return jsonDecode('"${m.group(1)}"') as String;
    } catch (_) {}
    return '';
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
      final cgRes = await http.get(
        Uri.parse('https://zapp-5434-volleyball-tv.web.app/jw/media/aBT42rPR'),
        headers: {'Origin': 'https://tv.volleyballworld.com'},
      );
      if (cgRes.statusCode != 200) return;
      final cgData = jsonDecode(cgRes.body);
      final playlistsStr = cgData['entry']?[0]?['extensions']?['playlists'] as String? ?? '';
      final ids = playlistsStr.split(',').map((s) => s.trim()).where((s) => s.isNotEmpty).toList();

      final futures = ids.map((id) async {
        try {
          final res = await http.get(
            Uri.parse('https://zapp-5434-volleyball-tv.web.app/jw/playlists/$id?overrideFeedType=moreinfo'),
            headers: {'Origin': 'https://tv.volleyballworld.com'},
          );
          if (res.statusCode == 200) {
            final data = jsonDecode(res.body);
            final entries = data['entry'] as List? ?? [];
            if (entries.length < 5) return null; // Container-Playlist überspringen
            final title = _extractPlaylistTitle(res.body);
            return {'id': id, 'title': title.isNotEmpty ? title : id};
          }
        } catch (_) {}
        return null;
      });

      final results = (await Future.wait(futures))
          .whereType<Map<String, String>>()
          .toList();
      final firstId = results.isNotEmpty ? results.first['id']! : _currentPlaylistId;

      if (mounted) {
        setState(() {
          _availableTournaments = results;
          _currentPlaylistId = firstId;
        });
        _loadVideos(firstId);
      }
    } catch (_) {} finally {
      if (mounted) setState(() => _isLoadingTournaments = false);
    }
  }

  static const _allId = '__all__';

  VideoItem _itemFromJson(dynamic item) {
    final title = item['title'] as String? ?? '';
    final dateStr = item['extensions']?['match_date'] as String?;
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
    );
  }

  Future<void> _loadVideos([String? playlistId]) async {
    final pid = playlistId ?? _currentPlaylistId;
    if (playlistId != null && mounted) setState(() { _currentPlaylistId = pid; });
    setState(() { _isLoading = true; _errorMessage = null; });
    try {
      if (pid == _allId) {
        final ctx = _buildCtx();
        final futures = _availableTournaments.map((t) async {
          try {
            final res = await http.get(
              Uri.parse('https://zapp-5434-volleyball-tv.web.app/jw/playlists/${t['id']}?overrideFeedType=moreinfo&ctx=$ctx'),
              headers: {'Origin': 'https://tv.volleyballworld.com'},
            );
            if (res.statusCode == 200) {
              final data = jsonDecode(res.body);
              return (data['entry'] as List? ?? []).map(_itemFromJson).toList();
            }
          } catch (_) {}
          return <VideoItem>[];
        });
        final all = (await Future.wait(futures)).expand((l) => l).toList();
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
      );
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        final videos = (data['entry'] as List? ?? []).map(_itemFromJson).toList()
          ..sort((a, b) {
            if (a.matchDate == null) return 1;
            if (b.matchDate == null) return -1;
            return b.matchDate!.compareTo(a.matchDate!);
          });
        setState(() => _videos = videos);
      } else {
        setState(() => _errorMessage = 'Fehler ${response.statusCode}');
      }
    } catch (e) {
      setState(() => _errorMessage = 'Verbindungsfehler: $e');
    } finally {
      setState(() => _isLoading = false);
    }
  }

  void _openVideo(VideoItem video) {
    final selfLink = Uri.encodeComponent(
      'https://zapp-5434-volleyball-tv.web.app/jw/media/${video.id}?disablePlayNext=false&withErrors=false',
    );
    final playerUrl = 'https://tv.volleyballworld.com/player?self-link=$selfLink&screen-id=696c5338-8a65-44fb-94c6-41411be52290';
    Navigator.push(context, MaterialPageRoute(
      builder: (_) => WebViewPlayerScreen(title: video.teams, playerUrl: playerUrl, useRealDuration: !_twoHourMode),
    ));
  }

  String _formatDate(DateTime? date) {
    if (date == null) return '';
    const months = ['Jan','Feb','Mär','Apr','Mai','Jun','Jul','Aug','Sep','Okt','Nov','Dez'];
    final d = date.toLocal();
    return '${d.day}. ${months[d.month - 1]} ${d.year}, ${d.hour.toString().padLeft(2,'0')}:${d.minute.toString().padLeft(2,'0')}';
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
        gender == 'Men' ? 'Herren' : 'Damen',
        style: const TextStyle(color: Colors.white, fontSize: 9, fontWeight: FontWeight.bold),
      ),
    );
  }

  Widget _filterChip(String label, String value, {bool autofocus = false}) {
    final selected = _genderFilter == value;
    return _TvFocusButton(
      autofocus: autofocus,
      onPressed: () => setState(() { _genderFilter = value; _playerFilter = null; _countryFilter = null; }),
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
        ? 'Alle Turniere'
        : _availableTournaments
            .firstWhere((t) => t['id'] == _currentPlaylistId, orElse: () => {'title': 'Turnier'})['title']!;

    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 160),
      child: _TvFocusWrapper(
        borderRadius: 20,
        child: PopupMenuButton<String>(
          onSelected: (id) {
            if (id == _currentPlaylistId) return;
            _loadVideos(id);
          },
          color: const Color(0xFF2A2A2A),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
          constraints: const BoxConstraints(minWidth: 220),
          itemBuilder: (_) => [
            PopupMenuItem<String>(
              value: _allId,
              child: Text('Alle Turniere', style: TextStyle(
                color: isAll ? Colors.orange : Colors.white70,
                fontWeight: isAll ? FontWeight.bold : FontWeight.normal,
                fontSize: 13,
              )),
            ),
            ..._availableTournaments.map((t) => PopupMenuItem<String>(
              value: t['id']!,
              child: Text(t['title']!,
                style: TextStyle(
                  color: t['id'] == _currentPlaylistId ? Colors.orange : Colors.white70,
                  fontWeight: t['id'] == _currentPlaylistId ? FontWeight.bold : FontWeight.normal,
                  fontSize: 13,
                )),
            )),
          ],
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
            decoration: BoxDecoration(
              color: const Color(0xFF1A1A1A),
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: Colors.orange),
            ),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              Flexible(child: Text(isAll ? 'Alle' : _shortTitle(currentTitle),
                style: const TextStyle(color: Colors.orange, fontSize: 12, fontWeight: FontWeight.bold),
                overflow: TextOverflow.ellipsis,
              )),
              const SizedBox(width: 4),
              const Icon(Icons.arrow_drop_down, size: 18, color: Colors.orange),
            ]),
          ),
        ),
      ),
    );
  }

  Widget _playerDropdown() {
    final players = _availablePlayers;
    if (players.isEmpty) return const SizedBox.shrink();
    final active = _playerFilter != null;
    final label = _playerFilter ?? 'Alle Spieler';
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
    final label = _countryFilter ?? 'Alle Länder';
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
    final spoiler = _isSpoiler(video.round);
    return _TvFocusButton(
      onPressed: () => _openVideo(video),
      borderRadius: 8,
      child: Container(
        decoration: BoxDecoration(color: const Color(0xFF1A1A1A), borderRadius: BorderRadius.circular(8)),
        padding: const EdgeInsets.all(10),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            _genderBadge(video.gender),
            if (video.gender.isNotEmpty) const SizedBox(width: 6),
            Expanded(child: Text(video.round,
              style: const TextStyle(color: Colors.white60, fontSize: 10),
              overflow: TextOverflow.ellipsis)),
          ]),
          const SizedBox(height: 6),
          if (spoiler)
            Row(children: [
              const Icon(Icons.lock_outline, size: 12, color: Colors.white30),
              const SizedBox(width: 4),
              const Expanded(child: Text('Spoiler-Schutz aktiv',
                style: TextStyle(fontSize: 11, color: Colors.white30, fontStyle: FontStyle.italic))),
            ])
          else
            Text(video.teams,
              style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold),
              maxLines: 2, overflow: TextOverflow.ellipsis),
          const Spacer(),
          Text(video.tournament,
            style: const TextStyle(color: Colors.white38, fontSize: 10),
            overflow: TextOverflow.ellipsis),
          Text(_formatDate(video.matchDate),
            style: const TextStyle(color: Colors.white38, fontSize: 10)),
        ]),
      ),
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
            title: const Text('App beenden?', style: TextStyle(color: Colors.white)),
            content: const Text('Willst du die App wirklich schließen?',
                style: TextStyle(color: Colors.white70)),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('Abbrechen', style: TextStyle(color: Colors.white54)),
              ),
              TextButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('Beenden', style: TextStyle(color: Colors.orange)),
              ),
            ],
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
      body: _errorMessage != null && _videos.isEmpty
          ? Center(child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
              Text(_errorMessage!, style: const TextStyle(color: Colors.redAccent)),
              const SizedBox(height: 16),
              ElevatedButton(onPressed: _loadVideos, child: const Text('Nochmal versuchen')),
            ]))
          : Column(children: [
                  Container(
                    color: const Color(0xFF0A0A0A),
                    padding: const EdgeInsets.fromLTRB(12, 10, 12, 6),
                    child: Row(children: [
                      _filterChip('Alle', 'all', autofocus: true),
                      const SizedBox(width: 8),
                      _filterChip('Herren', 'men'),
                      const SizedBox(width: 8),
                      _filterChip('Damen', 'women'),
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
                            return GridView.builder(
                              padding: const EdgeInsets.all(12),
                              gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                                crossAxisCount: isTV ? 5 : 2,
                                childAspectRatio: isTV ? 2.0 : 1.55,
                                crossAxisSpacing: 10,
                                mainAxisSpacing: 10,
                              ),
                              itemCount: _filteredVideos.length,
                              itemBuilder: (_, i) => _buildVideoCard(_filteredVideos[i]),
                            );
                          }),
                  ),
                ]),
      ),
    );
  }
}

class _TvFocusButton extends StatefulWidget {
  final Widget child;
  final VoidCallback onPressed;
  final double borderRadius;
  final bool autofocus;

  const _TvFocusButton({
    required this.child,
    required this.onPressed,
    this.borderRadius = 8,
    this.autofocus = false,
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
      onFocusChange: (f) => setState(() => _focused = f),
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
            border: _focused ? Border.all(color: Colors.orange, width: 3) : null,
            boxShadow: _focused
                ? [BoxShadow(color: Colors.orange.withValues(alpha: 0.6), blurRadius: 10, spreadRadius: 1)]
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

  const _TvFocusWrapper({required this.child, this.borderRadius = 8});

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
          border: _focused ? Border.all(color: Colors.orange, width: 3) : null,
          boxShadow: _focused
              ? [BoxShadow(color: Colors.orange.withValues(alpha: 0.6), blurRadius: 10, spreadRadius: 1)]
              : null,
        ),
        child: widget.child,
      ),
    );
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
  }

  @override
  void dispose() {
    _ctrl.dispose();
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
          child: TextField(
            controller: _ctrl,
            autofocus: true,
            style: const TextStyle(color: Colors.white),
            decoration: InputDecoration(
              hintText: 'Spieler suchen...',
              hintStyle: const TextStyle(color: Colors.white38),
              prefixIcon: const Icon(Icons.search, color: Colors.white38),
              suffixIcon: _ctrl.text.isNotEmpty
                  ? IconButton(
                      icon: const Icon(Icons.clear, color: Colors.white38),
                      onPressed: () => _ctrl.clear(),
                    )
                  : null,
              filled: true,
              fillColor: const Color(0xFF2A2A2A),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: BorderSide.none,
              ),
            ),
          ),
        ),
        ConstrainedBox(
          constraints: BoxConstraints(maxHeight: MediaQuery.of(context).size.height * 0.5),
          child: ListView(shrinkWrap: true, children: [
            ListTile(
              leading: Icon(Icons.people, size: 20,
                  color: widget.selected == null ? Colors.orange : Colors.white38),
              title: Text('Alle Spieler', style: TextStyle(
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
            title: Text('Alle Länder', style: TextStyle(
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
  final bool useRealDuration;
  const WebViewPlayerScreen({super.key, required this.title, required this.playerUrl, this.useRealDuration = false});

  @override
  State<WebViewPlayerScreen> createState() => _WebViewPlayerScreenState();
}

class _WebViewPlayerScreenState extends State<WebViewPlayerScreen> {
  late final WebViewController _controller;

  Duration get _effectiveDuration {
    if (widget.useRealDuration || _realDuration > 7200) {
      return Duration(seconds: _realDuration.floor());
    }
    return const Duration(hours: 2);
  }
  Duration _fakePosition = Duration.zero;
  double _realDuration = 7200; // Default 2h bis JW Player echte Dauer meldet
  bool _isPlaying = false;
  bool _isInBlackScreen = false;
  bool _showControls = true;
  bool _playerReady = false;
  bool _isTV = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _isTV = MediaQuery.of(context).size.shortestSide > 450;
  }

  double _playbackRate = 1.0;
  DateTime? _lastUserToggle;

  List<Map<String, dynamic>> _qualityLevels = [];
  int _currentQualityIndex = -1; // -1 = Auto

  int _seekClickCount = 0;
  int _pendingSeekSeconds = 0;
  bool _seekingForward = true;
  bool _showSeekOverlay = false;
  String _seekOverlayText = '';
  Timer? _seekTimer;
  Timer? _hideControlsTimer;
  Timer? _positionTimer;
  Timer? _blackScreenTimer;

  // 1x=5s 2x=10s 3x=30s 4x=1min 5x=3min 6x=5min 7x=10min 8x=20min, danach +10min
  final List<int> _seekSteps = [5, 10, 30, 60, 180, 300, 600, 1200];

  bool _handleRemoteKey(KeyEvent event) {
    if (!mounted || !_playerReady) return false;
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) return false;

    final isDown = event is KeyDownEvent;

    // Jede Taste blendet Controls wieder ein
    if (!_showControls) {
      setState(() => _showControls = true);
      _startHideControlsTimer();
      if (event.logicalKey == LogicalKeyboardKey.arrowUp ||
          event.logicalKey == LogicalKeyboardKey.arrowDown) return true;
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

    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..addJavaScriptChannel('FlutterChannel', onMessageReceived: _onJsMessage)
      ..setNavigationDelegate(NavigationDelegate(
        onPageFinished: (_) {
          _onPageFinished();
          // Fallback: nur wenn ready-Event nie kommt
          Future.delayed(const Duration(seconds: 4), () {
            if (mounted && !_playerReady) {
              setState(() { _playerReady = true; _isPlaying = true; });
              _startHideControlsTimer();
              _startPositionPolling();
            }
            // Quality-Levels nachholen falls ready-Event verpasst
            if (mounted) {
              _controller.runJavaScript('''
                try {
                  var p = jwplayer();
                  if (p && p.getQualityLevels) {
                    var lv = p.getQualityLevels();
                    if (lv && lv.length > 0) {
                      FlutterChannel.postMessage(JSON.stringify({
                        type: 'qualities', levels: lv,
                        currentQuality: p.getCurrentQuality ? (p.getCurrentQuality() || 0) : 0
                      }));
                    }
                  }
                } catch(e) {}
              ''');
            }
          });
        },
      ))
      ..loadRequest(Uri.parse(widget.playerUrl));

    // Android: Autoplay ohne User-Gesture erlauben
    if (_controller.platform is AndroidWebViewController) {
      (_controller.platform as AndroidWebViewController)
          .setMediaPlaybackRequiresUserGesture(false);
    }
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
      _controller.runJavaScript('''
        try {
          var v = $_jsGetVideo;
          if (v) {
            FlutterChannel.postMessage(JSON.stringify({
              type: 'time',
              pos: v.currentTime,
              dur: v.duration || 0,
              state: (window._flutterPaused || v.paused) ? 'paused' : 'playing'
            }));
          }
        } catch(e) {}
      ''');
    });
  }

  void _onPageFinished() {
    _controller.runJavaScript('''
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
      }, 500);

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

      function _sendQualities(p) {
        try {
          var levels = []; try { levels = p.getQualityLevels(); } catch(e) {}
          FlutterChannel.postMessage(JSON.stringify({type:'ready', dur: p.getDuration(), qualities: levels, currentQuality: p.getCurrentQuality()}));
        } catch(e) {}
      }

      var attempts = 0;
      var init = setInterval(function() {
        attempts++;
        try {
          var p = jwplayer();
          if (p && p.getState) {
            try { var v = $_jsGetVideo; if (v) _flutterSetupVideo(v); } catch(e) {}

            // Player bereits bereit? Sofort Quality-Daten senden
            var st = p.getState();
            if (st && st !== 'idle' && st !== '') {
              _sendQualities(p);
              // Nochmal nach 1s (HLS-Level laden ggf. nach)
              setTimeout(function() { _sendQualities(p); }, 1000);
            }

            p.on('ready', function() {
              _sendQualities(p);
              setTimeout(function() {
                _sendQualities(p); // Nochmal nach 1s für HLS
                if(window.flShowControls) window.flShowControls();
              }, 1000);
            });
            p.on('play',  function() {
              if (!window._flutterPaused) FlutterChannel.postMessage(JSON.stringify({type:'play'}));
            });
            p.on('pause', function() { FlutterChannel.postMessage(JSON.stringify({type:'pause'})); });
            p.on('time',  function(e) { FlutterChannel.postMessage(JSON.stringify({type:'time', pos: e.position, dur: e.duration})); });
            p.on('complete', function() { FlutterChannel.postMessage(JSON.stringify({type:'complete'})); });
            p.on('levels', function(e) {
              FlutterChannel.postMessage(JSON.stringify({type:'qualities', levels: e.levels, currentQuality: e.currentQuality}));
            });
            p.on('levelsChanged', function(e) {
              FlutterChannel.postMessage(JSON.stringify({type:'qualityChange', currentQuality: e.currentQuality}));
            });
            clearInterval(init);
          }
        } catch(e) {}
        if (attempts > 60) clearInterval(init);
      }, 500);

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
        if (mounted) Navigator.pop(context);
        break;
    }
  }

  void _onJsMessage(JavaScriptMessage msg) {
    try {
      final data = jsonDecode(msg.message);
      final type = data['type'];
      if (type == 'ready') {
        final dur = (data['dur'] ?? 0).toDouble();
        final levels = (data['qualities'] as List? ?? [])
            .map((l) => Map<String, dynamic>.from(l as Map))
            .toList();
        final curQ = (data['currentQuality'] ?? -1) as int;
        _startPositionPolling();
        Future.delayed(const Duration(milliseconds: 300), () {
          if (mounted) {
            setState(() {
              _playerReady = true;
              _realDuration = dur;
              _isPlaying = true;
              _qualityLevels = levels;
              _currentQualityIndex = curQ;
            });
            _startHideControlsTimer();
            final safeTitle = widget.title.replaceAll("'", "\\'");
            _controller.runJavaScript("if(window.flSetTitle) window.flSetTitle('$safeTitle');");
          }
        });
      } else if (type == 'play') {
        setState(() => _isPlaying = true);
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
            // State-Sync nur wenn kein User-Toggle in den letzten 1,5s
            if (sinceToggle.inMilliseconds > 1500) {
              final state = data['state'] as String?;
              if (state != null) _isPlaying = state == 'playing';
            }
          });
        }
      } else if (type == 'qualities') {
        final levels = (data['levels'] as List? ?? [])
            .map((l) => Map<String, dynamic>.from(l as Map))
            .toList();
        if (mounted) setState(() {
          _qualityLevels = levels;
          _currentQualityIndex = (data['currentQuality'] ?? -1) as int;
        });
      } else if (type == 'qualityChange') {
        if (mounted) setState(() => _currentQualityIndex = (data['currentQuality'] ?? -1) as int);
      } else if (type == 'key') {
        _handleJsKey(data['key'] as String? ?? '');
      } else if (type == 'complete') {
        if (widget.useRealDuration || _realDuration > 7200) {
          setState(() => _isPlaying = false);
        } else {
          _startBlackScreen();
        }
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
      _controller.runJavaScript('try { var v=$_jsGetVideo; if(v) v.currentTime=$targetSecs; } catch(e) {}');
      if (wasPlaying) {
        _controller.runJavaScript('if(window.flutterPlay) window.flutterPlay($_playbackRate);');
      } else {
        _controller.runJavaScript('if(window.flutterPause) window.flutterPause();');
      }
    } else {
      _controller.runJavaScript('try { var v=$_jsGetVideo; if(v) v.pause(); } catch(e) {}');
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
        _controller.runJavaScript('if(window.flutterPlay) window.flutterPlay($_playbackRate);');
      } else {
        _controller.runJavaScript('if(window.flutterPause) window.flutterPause();');
      }
    }
    if (nowPlaying) {
      _startHideControlsTimer(); // beim Abspielen nach 2s ausblenden
    } else {
      _hideControlsTimer?.cancel(); // beim Pausieren dauerhaft sichtbar lassen
    }
  }

  void _startHideControlsTimer() {
    _hideControlsTimer?.cancel();
    _hideControlsTimer = Timer(Duration(seconds: _isTV ? 2 : 5), () {
      if (mounted && _isPlaying) setState(() => _showControls = false);
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
      _controller.runJavaScript('try { var v=$_jsGetVideo; if(v) v.playbackRate=$next; } catch(e) {}');
    }
    _startHideControlsTimer();
  }

  void _seek(bool forward) {
    if (_seekingForward != forward) { _seekClickCount = 0; _pendingSeekSeconds = 0; }
    _seekingForward = forward;
    _seekClickCount++;
    _pendingSeekSeconds = _getSeekSeconds(_seekClickCount);
    final seekText = '${forward ? '+' : '-'}${_formatSeekTime(_pendingSeekSeconds)}';
    setState(() {
      _showSeekOverlay = true;
      _showControls = true;
      _seekOverlayText = seekText;
    });
    _controller.runJavaScript("if(window.flShowSeek) window.flShowSeek('$seekText');");
    _seekTimer?.cancel();
    _seekTimer = Timer(const Duration(milliseconds: 600), () {
      final target = forward
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

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_handleRemoteKey);
    _seekTimer?.cancel();
    _hideControlsTimer?.cancel();
    _positionTimer?.cancel();
    _blackScreenTimer?.cancel();
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
        Navigator.pop(context);
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

          // Schwarze Abdeckung bis Player bereit ist
          if (!_playerReady)
            Positioned.fill(child: Container(
              color: Colors.black,
              child: const Center(child: CircularProgressIndicator(color: Colors.orange)),
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
              Icon(_seekingForward ? Icons.fast_forward : Icons.fast_rewind, color: Colors.orange, size: 48),
              const SizedBox(height: 8),
              Text(_seekOverlayText, style: const TextStyle(color: Colors.white, fontSize: 32, fontWeight: FontWeight.bold)),
              Text('Klick $_seekClickCount', style: const TextStyle(color: Colors.white54, fontSize: 14)),
            ]),
          )),

          // Controls ein/ausblenden per Tap auf die Mitte (wo keine Seek-Bereiche sind)
          if (_showControls) _buildControls(),

          // Dauerhaftes Qualitäts-Overlay oben rechts (immer sichtbar)
          Positioned(
            top: 16,
            right: 16,
            child: _buildQualityOverlay(),
          ),
        ]),
      ),
    );
  }

  Widget _buildWebViewWidget() {
    if (_controller.platform is AndroidWebViewController) {
      return WebViewWidget.fromPlatformCreationParams(
        params: AndroidWebViewWidgetCreationParams(
          controller: _controller.platform as AndroidWebViewController,
          displayWithHybridComposition: true,
          gestureRecognizers: {
            Factory<OneSequenceGestureRecognizer>(() => EagerGestureRecognizer()),
          },
        ),
      );
    }
    return WebViewWidget(
      controller: _controller,
      gestureRecognizers: {
        Factory<OneSequenceGestureRecognizer>(() => EagerGestureRecognizer()),
      },
    );
  }

  void _setQuality(int index) {
    setState(() => _currentQualityIndex = index);
    _controller.runJavaScript('try { jwplayer().setCurrentQuality($index); } catch(e) {}');
    _startHideControlsTimer();
  }

  Widget _buildQualityOverlay() {
    final hasLevels = _qualityLevels.isNotEmpty;
    final label = hasLevels
        ? (_currentQualityIndex >= 0 && _currentQualityIndex < _qualityLevels.length
            ? (_qualityLevels[_currentQualityIndex]['label'] as String? ??
               '${_qualityLevels[_currentQualityIndex]['height']}p')
            : 'AUTO')
        : 'Qualität lädt...';
    if (!hasLevels) {
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: Colors.black54,
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: Colors.white24),
        ),
        child: Text(label, style: const TextStyle(color: Colors.white38, fontSize: 12)),
      );
    }
    return PopupMenuButton<int>(
      onSelected: _setQuality,
      color: const Color(0xFF2A2A2A),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      itemBuilder: (_) => [
        PopupMenuItem<int>(
          value: -1,
          child: Text('Auto', style: TextStyle(
            color: _currentQualityIndex == -1 ? Colors.orange : Colors.white70,
            fontWeight: _currentQualityIndex == -1 ? FontWeight.bold : FontWeight.normal,
          )),
        ),
        ..._qualityLevels.asMap().entries.map((e) {
          final lbl = e.value['label'] as String? ?? '${e.value['height']}p';
          final bitrate = e.value['bitrate'] as int? ?? 0;
          final sub = bitrate > 0 ? '${(bitrate / 1000000).toStringAsFixed(1)} Mbit/s' : '';
          return PopupMenuItem<int>(
            value: e.key,
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
              Text(lbl, style: TextStyle(
                color: e.key == _currentQualityIndex ? Colors.orange : Colors.white70,
                fontWeight: e.key == _currentQualityIndex ? FontWeight.bold : FontWeight.normal,
              )),
              if (sub.isNotEmpty)
                Text(sub, style: const TextStyle(color: Colors.white38, fontSize: 11)),
            ]),
          );
        }),
      ],
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: Colors.black54,
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: Colors.orange),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          const Icon(Icons.hd, color: Colors.orange, size: 16),
          const SizedBox(width: 5),
          Text(label, style: const TextStyle(color: Colors.orange, fontSize: 12, fontWeight: FontWeight.bold)),
          const SizedBox(width: 3),
          const Icon(Icons.arrow_drop_down, color: Colors.orange, size: 16),
        ]),
      ),
    );
  }

  Widget _buildQualityButton() {
    final label = _currentQualityIndex >= 0 && _currentQualityIndex < _qualityLevels.length
        ? (_qualityLevels[_currentQualityIndex]['label'] as String? ??
           '${_qualityLevels[_currentQualityIndex]['height']}p')
        : 'AUTO';
    return PopupMenuButton<int>(
      onSelected: _setQuality,
      color: const Color(0xFF2A2A2A),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      itemBuilder: (_) => [
        PopupMenuItem<int>(
          value: -1,
          child: Text('Auto', style: TextStyle(
            color: _currentQualityIndex == -1 ? Colors.orange : Colors.white70,
            fontWeight: _currentQualityIndex == -1 ? FontWeight.bold : FontWeight.normal,
          )),
        ),
        ..._qualityLevels.asMap().entries.map((e) {
          final lbl = e.value['label'] as String? ?? '${e.value['height']}p';
          final bitrate = e.value['bitrate'] as int? ?? 0;
          final sub = bitrate > 0 ? '${(bitrate / 1000000).toStringAsFixed(1)} Mbit/s' : '';
          return PopupMenuItem<int>(
            value: e.key,
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
              Text(lbl, style: TextStyle(
                color: e.key == _currentQualityIndex ? Colors.orange : Colors.white70,
                fontWeight: e.key == _currentQualityIndex ? FontWeight.bold : FontWeight.normal,
              )),
              if (sub.isNotEmpty)
                Text(sub, style: const TextStyle(color: Colors.white38, fontSize: 11)),
            ]),
          );
        }),
      ],
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          border: Border.all(color: Colors.white38),
          borderRadius: BorderRadius.circular(5),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          const Icon(Icons.hd, color: Colors.white70, size: 16),
          const SizedBox(width: 5),
          Text(label, style: const TextStyle(color: Colors.white70, fontSize: 12, fontWeight: FontWeight.bold)),
          const SizedBox(width: 3),
          const Icon(Icons.arrow_drop_down, color: Colors.white38, size: 16),
        ]),
      ),
    );
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
            if (_qualityLevels.isNotEmpty) _buildQualityButton(),
            const SizedBox(width: 8),
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
              Text('${_formatDuration(_fakePosition)} / ${_formatDuration(_effectiveDuration)}',
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
