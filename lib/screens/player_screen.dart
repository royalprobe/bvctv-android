import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:video_player/video_player.dart';
import 'dart:async';
import 'dart:io';
import '../l10n/strings.dart';
import '../widgets/end_splash.dart';

class _BestVariant {
  final String url;
  final int height;
  final int bandwidth;
  final String cookieHeader;
  const _BestVariant(this.url, this.height, this.bandwidth, this.cookieHeader);
}

class PlayerScreen extends StatefulWidget {
  final String title;
  final String streamUrl;

  /// Kuenstliche 2h-Timeline fuer VBW-Highlights, deren echte Datei kuerzer
  /// ist als das Match. Die komplette Mechanik dahinter (schwarzer Bereich
  /// nach dem Dateiende, virtuelle Position, Rueckseek ins echte Video) war
  /// hier schon vorhanden — sie wurde nur nie eingeschaltet, weil dieser
  /// Player bisher ausschliesslich Laola/GBT-Streams mit echter Dauer
  /// bekommen hat. Fuer VBW lief die 2h-Ansicht im WebView-Player.
  final bool twoHourMode;

  /// Bei Livestreams an den Anfang des verfuegbaren Fensters springen statt
  /// an der Live-Kante einzusteigen ("Vom Anfang an" im Live-Dialog).
  ///
  /// Wie weit das zurueckreicht, bestimmt das DVR-Fenster des Streams — bis
  /// zum tatsaechlichen Matchbeginn muss es nicht reichen. Ohne das Flag
  /// startet ExoPlayer bei Live von selbst an der Live-Kante, was "Live
  /// einsteigen" entspricht.
  final bool startAtBeginning;

  const PlayerScreen({
    super.key,
    required this.title,
    required this.streamUrl,
    this.twoHourMode = false,
    this.startAtBeginning = false,
  });

  @override
  State<PlayerScreen> createState() => _PlayerScreenState();
}

class _PlayerScreenState extends State<PlayerScreen> {
  late VideoPlayerController _controller;
  bool _isInitialized = false;
  bool _showControls = true;
  bool _isPlaying = false;
  Timer? _hideControlsTimer;
  Timer? _seekTimer;
  Timer? _uiTimer;

  // Anzeigedauer der Timeline. Fuer Laola-Streams (Live wie VOD) liefert
  // VideoPlayerController die echte Dauer bzw. das DVR-Fenster — beides
  // wollen wir 1:1 in der UI sehen, keine kuenstliche 2h-Kappe wie sie
  // bei VBW-Highlights noetig ist. Fallback nur waehrend der ersten
  // Millisekunden vor `initialize()` abgeschlossen ist.
  Duration get _displayDuration {
    final d = _controller.value.duration;
    // 2h-Modus: Timeline auf zwei Stunden aufziehen, ABER eine laengere
    // Datei nie abschneiden. Exakt dieselbe Regel wie im WebView-Player
    // (webview_player_screen.dart::_effectiveDuration, dort als
    // `useRealDuration || _realDuration > 7200`), damit sich der Modus in
    // beiden Playern gleich anfuehlt.
    if (widget.twoHourMode) {
      return d > const Duration(hours: 2) ? d : const Duration(hours: 2);
    }
    return d > Duration.zero ? d : const Duration(hours: 2);
  }
  Duration _fakePosition = Duration.zero;
  bool _isInBlackScreen = false;
  Timer? _blackScreenTimer;

  // Kodi-style accumulated seeking
  int _pendingSeekSeconds = 0;
  int _seekClickCount = 0;
  bool _seekingForward = true;
  String _seekOverlayText = '';
  bool _showSeekOverlay = false;

  final List<int> _seekSteps = [10, 30, 60, 180, 300, 600, 1200, 1800];
  final FocusNode _rootFocusNode = FocusNode(debugLabel: 'LaolaPlayerRoot');

  // Playback-Rate (1x/2x/4x/8x) — identisch zum VBW-Player, gesteuert
  // ueber die Fast-Forward-/Rewind-Buttons auf der FireStick-Fernbedienung
  // (mediaFastForward / mediaRewind). Auf Pause wird auf 1x zurueckgesetzt.
  double _playbackRate = 1.0;
  static const List<double> _kRates = [1.0, 2.0, 4.0, 8.0];

  // Aktuelle Auflösung von ExoPlayer. Für 10s nach Stream-Start sichtbar,
  // updated live bei ABR-Switches (falls Master-Fetch fehlschlug und auf ABR
  // zurückgefallen wurde).
  Size? _videoSize;
  bool _showQualityIndicator = true;
  Timer? _qualityIndicatorTimer;

  @override
  void initState() {
    super.initState();
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    SystemChrome.setPreferredOrientations([
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ]);
    _initPlayer();
  }

  KeyEventResult _onKeyEvent(FocusNode node, KeyEvent event) {
    // Sonst landet DPad-Left/Right auf dem Slider (5 % = 6 min Sprung) statt
    // bei _seek mit unseren 10s/30s/1m/3m/5m/10m/20m/30m-Stufen.
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final key = event.logicalKey;
    // DPad-Pfeile → akkumulierter Skip (10s → 30s → 1m → …). Media-
    // FastForward/Rewind auf der FireStick-Fernbedienung → Playback-Rate
    // wechseln (1x/2x/4x/8x). Genau wie beim VBW-Player.
    if (key == LogicalKeyboardKey.arrowLeft) {
      _seek(false);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowRight) {
      _seek(true);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.mediaRewind ||
        key == LogicalKeyboardKey.mediaStepBackward ||
        key == LogicalKeyboardKey.mediaSkipBackward) {
      _changePlaybackRate(false);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.mediaFastForward ||
        key == LogicalKeyboardKey.mediaStepForward ||
        key == LogicalKeyboardKey.mediaSkipForward) {
      _changePlaybackRate(true);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.select ||
        key == LogicalKeyboardKey.enter ||
        key == LogicalKeyboardKey.numpadEnter ||
        key == LogicalKeyboardKey.mediaPlayPause ||
        key == LogicalKeyboardKey.space) {
      _togglePlayPause();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowUp ||
        key == LogicalKeyboardKey.arrowDown) {
      setState(() => _showControls = true);
      _startHideControlsTimer();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  /// Twitch (usher.ttvnw.net) verlangt KEIN Referer/Origin von laola1.at —
  /// im Gegenteil, ein falscher Referer kann von Twitchs Edge-CDN als
  /// verdaechtig eingestuft und mit 403 abgelehnt werden. Nur echte Laola-
  /// Streams (Akamai) brauchen den Referer explizit, sonst 403 auf Master
  /// UND Variants/Segmente.
  bool get _isTwitchStream => widget.streamUrl.contains('ttvnw.net');

  /// VBW liefert ueber JW Player aus. Ein laola1-Referer hat dort nichts
  /// verloren — er ist bestenfalls nutzlos und kann wie bei Twitch als
  /// verdaechtig gelten.
  bool get _isVbwStream =>
      widget.streamUrl.contains('jwplayer.com') ||
      widget.streamUrl.contains('jwplive.com') ||
      widget.streamUrl.contains('jwpsrv.com');

  /// Nur echte Laola-Streams (Akamai) brauchen den laola1-Referer.
  bool get _needsLaolaHeaders => !_isTwitchStream && !_isVbwStream;

  /// Fetcht das Master-m3u8 selbst (über dart:io HttpClient damit wir Set-
  /// Cookie-Header lesen können), parsed die Variants, und gibt die beste
  /// (höchste Auflösung, sonst höchste Bitrate) zurück. Cookies aus der
  /// Master-Response werden gesammelt und müssen anschließend an ExoPlayer
  /// gegeben werden — sonst antwortet Akamai mit 403 auf die Variant-/Segment-
  /// Requests. Liefert null wenn was schiefgeht (Caller fällt auf Master+ABR
  /// zurück).
  /// Antwortet diese Variante ueberhaupt? Kurzer Abruf mit knapper Frist —
  /// eine tote Variante soll den Start nicht ausbremsen.
  Future<bool> _variantErreichbar(String url, String cookieHeader) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 3);
    try {
      final req = await client.getUrl(Uri.parse(url));
      if (_needsLaolaHeaders) {
        req.headers.set('Referer', 'https://www.laola1.at/');
        req.headers.set('Origin', 'https://www.laola1.at');
      }
      if (cookieHeader.isNotEmpty) req.headers.set('Cookie', cookieHeader);
      req.headers.set('User-Agent',
          'Mozilla/5.0 (Linux; Android 12) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Mobile Safari/537.36');
      final res = await req.close().timeout(const Duration(seconds: 3));
      await res.drain();
      return res.statusCode == 200;
    } catch (e) {
      debugPrint('[laola-player] Variant-Pruefung fehlgeschlagen: $e');
      return false;
    } finally {
      client.close(force: true);
    }
  }

  Future<_BestVariant?> _pickBestVariantWithCookies(String masterUrl) async {
    try {
      final client = HttpClient()..connectionTimeout = const Duration(seconds: 4);
      try {
        final req = await client.getUrl(Uri.parse(masterUrl));
        if (_needsLaolaHeaders) {
          req.headers.set('Referer', 'https://www.laola1.at/');
          req.headers.set('Origin', 'https://www.laola1.at');
        }
        req.headers.set('User-Agent',
            'Mozilla/5.0 (Linux; Android 12) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Mobile Safari/537.36');
        final res = await req.close().timeout(const Duration(seconds: 4));
        if (res.statusCode != 200) {
          debugPrint('[laola-player] master fetch HTTP ${res.statusCode}');
          return null;
        }
        final cookiePairs = res.cookies
            .map((c) => '${c.name}=${c.value}')
            .toList();
        final cookieHeader = cookiePairs.join('; ');
        final body = await res.transform(const SystemEncoding().decoder).join();

        // Getrennte Tonspur? Dann NICHT auf eine Variante festnageln.
        //
        // Bei VBW enthalten die Varianten nur Video, der Ton liegt in einer
        // eigenen Spur (#EXT-X-MEDIA:TYPE=AUDIO). Wer hier eine Variante
        // pinnt, spielt Bild OHNE Ton — genau das Tonproblem, an dem der
        // schnelle VBTV-Weg gescheitert ist. Laola ist nicht betroffen, dort
        // steckt der Ton in der Variante selbst.
        //
        // ExoPlayer setzt Video- und Tonspur selbst zusammen, wenn man ihm
        // den Master gibt; die Qualitaetswahl uebernimmt dann dessen ABR.
        if (body.contains('EXT-X-MEDIA:TYPE=AUDIO')) {
          debugPrint('[player] getrennte Tonspur erkannt -> Master + ABR '
              'statt gepinnter Variante (sonst Bild ohne Ton)');
          return null;
        }

        final lines = body.split('\n');
        final base = Uri.parse(masterUrl);
        // (Hoehe, Bandbreite, Adresse) je Variante.
        final kandidaten = <(int, int, String)>[];
        for (var i = 0; i < lines.length - 1; i++) {
          final l = lines[i].trim();
          if (!l.startsWith('#EXT-X-STREAM-INF')) continue;
          final next = lines[i + 1].trim();
          if (next.isEmpty || next.startsWith('#')) continue;
          final bw = int.tryParse(
                  RegExp(r'BANDWIDTH=(\d+)').firstMatch(l)?.group(1) ?? '0') ??
              0;
          final resm = RegExp(r'RESOLUTION=\d+x(\d+)').firstMatch(l);
          final height = resm != null ? int.parse(resm.group(1)!) : 0;
          kandidaten.add((height, bw, base.resolve(next).toString()));
        }
        if (kandidaten.isEmpty) return null;

        // Nach Qualitaet sortieren und die erste nehmen, die tatsaechlich
        // ANTWORTET.
        //
        // Grund: laola1 listet Stufen teils doppelt, und einzelne dieser
        // Eintraege sind toter Link. Beim Wolfurt-Center-Court war der erste
        // 720p-Eintrag ein 404, der zweite lief — die App nagelte die kaputte
        // fest und spielte nichts, waehrend laola1s eigener Player
        // weiterprobierte. Gemessen: von zehn Varianten waren zwei tot.
        kandidaten.sort((a, b) {
          final h = b.$1.compareTo(a.$1);
          return h != 0 ? h : b.$2.compareTo(a.$2);
        });

        for (final (height, bw, url) in kandidaten) {
          if (!await _variantErreichbar(url, cookieHeader)) {
            debugPrint('[laola-player] Variante ${height}p ($bw bps) '
                'antwortet nicht — naechste');
            continue;
          }
          debugPrint('[laola-player] picked variant ${height}p ($bw bps), '
              'cookies=${cookiePairs.length}');
          return _BestVariant(url, height, bw, cookieHeader);
        }
        debugPrint('[laola-player] keine Variante erreichbar -> Master + ABR');
        return null;
      } finally {
        client.close(force: true);
      }
    } catch (e) {
      debugPrint('[laola-player] variant-pick failed: $e — fallback to master');
      return null;
    }
  }

  Future<void> _initPlayer() async {
    // Versuche zuerst die höchste Variante zu pinnen (mit Cookies aus dem
    // Master-Response). Wenn das schiefgeht, fällt's auf Master+ABR zurück.
    final best = await _pickBestVariantWithCookies(widget.streamUrl);
    final playUrl = best?.url ?? widget.streamUrl;
    final headers = <String, String>{
      if (_needsLaolaHeaders) ...{
        'Referer': 'https://www.laola1.at/',
        'Origin': 'https://www.laola1.at',
      },
      'User-Agent':
          'Mozilla/5.0 (Linux; Android 12) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Mobile Safari/537.36',
      if (best != null && best.cookieHeader.isNotEmpty)
        'Cookie': best.cookieHeader,
    };
    _controller = VideoPlayerController.networkUrl(
      Uri.parse(playUrl),
      httpHeaders: headers,
    );
    await _controller.initialize();
    // "Vom Anfang an" bei Livestreams: an den Anfang des DVR-Fensters
    // springen. ExoPlayer startet bei Live sonst an der Live-Kante.
    if (widget.startAtBeginning) {
      await _controller.seekTo(Duration.zero).catchError((e) {
        debugPrint('[player] Sprung an den Anfang nicht moeglich: $e');
      });
      // WARTEN bis der Sprung tatsaechlich gegriffen hat.
      //
      // initialize() legt den ersten Frame — den von der Live-Kante —
      // bereits auf die Oberflaeche. Geben wir den Player sofort frei,
      // sieht man diesen Frame als Standbild, bis nach dem Sprung ein
      // neues Bild ankommt. Genau das war sichtbar.
      //
      // Solange bleibt der Ladekreis stehen. Mit Frist, damit ein Stream
      // ohne brauchbares Rueckspul-Fenster nicht ewig haengt — dann geht
      // es eben an der Live-Kante los, so wie ohne die Option.
      final frist = DateTime.now().add(const Duration(seconds: 4));
      while (DateTime.now().isBefore(frist) &&
          _controller.value.position > const Duration(seconds: 10)) {
        await Future.delayed(const Duration(milliseconds: 100));
      }
      debugPrint('[player] Sprung an den Anfang: Position jetzt '
          '${_controller.value.position.inSeconds}s');
    }
    setState(() {
      _isInitialized = true;
      _isPlaying = true;
      _videoSize = _controller.value.size;
    });
    _controller.play();
    _startHideControlsTimer();
    _qualityIndicatorTimer = Timer(const Duration(seconds: 10), () {
      if (mounted) setState(() => _showQualityIndicator = false);
    });

    // UI-Tick alle 500ms: Position synchronisieren und Video-Ende erkennen
    _uiTimer = Timer.periodic(const Duration(milliseconds: 500), (_) {
      if (!mounted || _isInBlackScreen) return;
      // Waehrend Click-Akkumulation den setState aussetzen — sonst rebuilden
      // Slider + Overlay alle 500ms mitten in der Klick-Sequenz und das
      // Tippen fuehlt sich hakelig an. Nach dem Seek lebt der Timer normal
      // weiter.
      if (_seekTimer != null) return;
      final value = _controller.value;
      setState(() {
        _fakePosition = value.position;
        _isPlaying = value.isPlaying;
        _videoSize = value.size;
      });
      // Video zu Ende → auf schwarzen Bildschirm wechseln
      if (value.duration > Duration.zero &&
          value.position >= value.duration - const Duration(milliseconds: 600) &&
          !value.isPlaying &&
          !value.isBuffering) {
        _startBlackScreen();
      }
    });
  }

  void _startBlackScreen() {
    if (_isInBlackScreen) return;
    setState(() {
      _isInBlackScreen = true;
      _isPlaying = true;
      _fakePosition = _controller.value.duration;
    });
    _runBlackScreenTimer();
  }

  void _runBlackScreenTimer() {
    _blackScreenTimer?.cancel();
    _blackScreenTimer = Timer.periodic(const Duration(milliseconds: 500), (t) {
      if (!mounted) {
        t.cancel();
        return;
      }
      if (!_isPlaying) return;
      setState(() {
        _fakePosition += const Duration(milliseconds: 500);
        if (_fakePosition >= _displayDuration) {
          _fakePosition = _displayDuration;
          t.cancel();
        }
      });
    });
  }

  void _seekToFakePosition(Duration target) {
    if (target < Duration.zero) target = Duration.zero;
    if (target > _displayDuration) target = _displayDuration;

    final actualDuration = _controller.value.duration;

    if (target <= actualDuration) {
      // Zurück ins echte Video
      _blackScreenTimer?.cancel();
      _controller.seekTo(target);
      _controller.play();
      setState(() {
        _isInBlackScreen = false;
        _fakePosition = target;
        _isPlaying = true;
      });
    } else {
      // In den schwarzen Bereich vorspulen
      _blackScreenTimer?.cancel();
      setState(() {
        _isInBlackScreen = true;
        _fakePosition = target;
        _isPlaying = true;
      });
      _runBlackScreenTimer();
    }
  }

  void _togglePlayPause() {
    if (_isInBlackScreen) {
      setState(() => _isPlaying = !_isPlaying);
    } else {
      final playing = !_isPlaying;
      setState(() => _isPlaying = playing);
      if (playing) {
        _controller.play();
      } else {
        _controller.pause();
        // Beim Pausieren zurueck auf Normal-Geschwindigkeit — analog VBW.
        if (_playbackRate != 1.0) {
          _playbackRate = 1.0;
          _controller.setPlaybackSpeed(1.0);
        }
      }
    }
    _startHideControlsTimer();
  }

  /// Cyclt durch 1x/2x/4x/8x. Identisch zum VBW-Player. Bei Rate=1x wird
  /// die Badge im OSD ausgeblendet.
  void _changePlaybackRate(bool faster) {
    final idx = _kRates.indexOf(_playbackRate);
    final nextIdx = (faster ? idx + 1 : idx - 1).clamp(0, _kRates.length - 1);
    final next = _kRates[nextIdx];
    if (next == _playbackRate) return;
    setState(() => _playbackRate = next);
    // Wenn wir auf Rate-Change gehen wollen, muss auch gespielt werden —
    // sonst passiert visuell nichts.
    if (!_isPlaying) {
      _controller.play();
      setState(() => _isPlaying = true);
    }
    _controller.setPlaybackSpeed(next);
    _startHideControlsTimer();
  }

  void _startHideControlsTimer() {
    _hideControlsTimer?.cancel();
    // 2s wie bei VBW-Videos — vorher 4s war zu lang, das Seek-Overlay blieb
    // unnoetig lange nach dem Skip stehen.
    _hideControlsTimer = Timer(const Duration(seconds: 2), () {
      if (mounted) setState(() => _showControls = false);
    });
  }

  void _onTap() {
    // KEIN Toggle — das war der OSD-Blink waehrend rapide Seek-Taps. Die
    // Seek-Zonen (innere GestureDetectors) fuehrten _seek aus und _seek
    // setzte _showControls=true, danach toggelte _onTap dieses wieder weg.
    // Jetzt: Tap blendet die Controls IMMER ein, das Wegblenden uebernimmt
    // ausschliesslich der Auto-Hide-Timer nach 4s.
    if (!_showControls) setState(() => _showControls = true);
    _startHideControlsTimer();
  }

  int _getSeekSeconds(int clickCount) {
    if (clickCount <= 0) return 0;
    if (clickCount <= _seekSteps.length) return _seekSteps[clickCount - 1];
    return _seekSteps.last + (clickCount - _seekSteps.length) * 600;
  }

  void _seek(bool forward) {
    _seekTimer?.cancel();
    // Netto-Akkumulation wie beim VBW-Player: +1 vorwaerts, -1 rueckwaerts.
    // 3x rechts + 1x links = +2 (nicht neuer 1x-Sprung nach links). Bei 0
    // wird der Sprung komplett abgebrochen — der User kann so einen zu
    // grossen Sprung wieder auf 0 zurueckklicken ohne Auto-Trigger.
    _seekClickCount += forward ? 1 : -1;

    if (_seekClickCount == 0) {
      _pendingSeekSeconds = 0;
      setState(() {
        _showSeekOverlay = false;
      });
      _startHideControlsTimer();
      return;
    }

    final isForward = _seekClickCount > 0;
    final absCount = _seekClickCount.abs();
    _pendingSeekSeconds = _getSeekSeconds(absCount);
    _seekingForward = isForward; // Overlay-Icon

    setState(() {
      _showSeekOverlay = true;
      _seekOverlayText =
          '${isForward ? '+' : '-'}${_formatSeekTime(_pendingSeekSeconds)}';
      _showControls = true;
    });

    // 800ms Akkumulationsfenster: gibt langsameren Klick-Sequenzen Zeit
    // ge-bundled zu werden, bevor der Seek ausgeloest wird und der Player
    // buffert.
    _seekTimer = Timer(const Duration(milliseconds: 800), () {
      final target = isForward
          ? _fakePosition + Duration(seconds: _pendingSeekSeconds)
          : _fakePosition - Duration(seconds: _pendingSeekSeconds);
      _seekToFakePosition(target);

      _seekClickCount = 0;
      _pendingSeekSeconds = 0;
      _seekTimer = null;
      if (mounted) {
        setState(() => _showSeekOverlay = false);
        _startHideControlsTimer();
      }
    });
  }

  String _formatSeekTime(int seconds) {
    if (seconds < 60) return '${seconds}s';
    if (seconds < 3600) return '${seconds ~/ 60}min';
    return '${seconds ~/ 3600}h ${(seconds % 3600) ~/ 60}min';
  }

  String _formatDuration(Duration d) {
    final h = d.inHours;
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return h > 0 ? '$h:$m:$s' : '$m:$s';
  }

  @override
  void dispose() {
    _hideControlsTimer?.cancel();
    _seekTimer?.cancel();
    _uiTimer?.cancel();
    _blackScreenTimer?.cancel();
    _qualityIndicatorTimer?.cancel();
    _rootFocusNode.dispose();
    _controller.dispose();
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    // Auf Fire Stick (landscape-only) zerlegt setPreferredOrientations
    // ([portraitUp]) das Layout der Übersicht — leere Liste lässt die
    // System-Default wirken, gleich wie in WebViewPlayerScreen.
    SystemChrome.setPreferredOrientations([]);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Focus(
        focusNode: _rootFocusNode,
        autofocus: true,
        onKeyEvent: _onKeyEvent,
        child: !_isInitialized
          ? const Center(child: CircularProgressIndicator(color: Colors.orange))
          : GestureDetector(
              onTap: _onTap,
              child: Stack(
                children: [
                  // Video oder schwarzer Bildschirm
                  if (!_isInBlackScreen)
                    Center(
                      child: AspectRatio(
                        aspectRatio: _controller.value.aspectRatio,
                        child: VideoPlayer(_controller),
                      ),
                    ),

                  // Im 2h-Modus laeuft die Timeline nach dem Dateiende weiter.
                  // Dieselbe Ansicht wie im WebView-Player, damit sich der
                  // Modus in beiden gleich anfuehlt (vorher blieb hier nur
                  // ein leerer schwarzer Bildschirm — der Zweig war bis jetzt
                  // gar nicht erreichbar, weil _displayDuration nie laenger
                  // als die Datei war).
                  if (_isInBlackScreen) const EndSplash(),

                  // Links = zurück, rechts = vor
                  Row(
                    children: [
                      Expanded(
                        child: GestureDetector(
                          onTap: () => _seek(false),
                          child: Container(color: Colors.transparent),
                        ),
                      ),
                      Expanded(
                        child: GestureDetector(
                          onTap: () => _seek(true),
                          child: Container(color: Colors.transparent),
                        ),
                      ),
                    ],
                  ),

                  // Seek-Overlay (Kodi-Style)
                  if (_showSeekOverlay)
                    Center(
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 16),
                        decoration: BoxDecoration(
                          color: Colors.black87,
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              _seekingForward ? Icons.fast_forward : Icons.fast_rewind,
                              color: Colors.orange,
                              size: 48,
                            ),
                            const SizedBox(height: 8),
                            Text(
                              _seekOverlayText,
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 32,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                            Text(
                              S.tapCount(_seekClickCount),
                              style: const TextStyle(color: Colors.white54, fontSize: 14),
                            ),
                          ],
                        ),
                      ),
                    ),

                  // Qualitäts-Indikator (oben rechts, erste 30s sichtbar,
                  // updated live wenn ABR die Variante wechselt).
                  if (_showQualityIndicator &&
                      _videoSize != null &&
                      _videoSize!.height > 0)
                    Positioned(
                      top: 16,
                      right: 16,
                      child: IgnorePointer(
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 10, vertical: 5),
                          decoration: BoxDecoration(
                            color: Colors.black.withValues(alpha: 0.7),
                            borderRadius: BorderRadius.circular(4),
                            border: Border.all(
                                color: Colors.orange.withValues(alpha: 0.7),
                                width: 1),
                          ),
                          child: Text(
                            '${_videoSize!.height.round()}p',
                            style: const TextStyle(
                              color: Colors.orange,
                              fontWeight: FontWeight.bold,
                              fontSize: 14,
                            ),
                          ),
                        ),
                      ),
                    ),

                  // Controls
                  if (_showControls) _buildControls(),
                ],
              ),
            ),
      ),
    );
  }

  Widget _buildControls() {
    final progress = (_fakePosition.inMilliseconds / _displayDuration.inMilliseconds).clamp(0.0, 1.0);

    // Slider + IconButtons sind sonst fokussierbar und fangen DPad-Tasten ab.
    // Statt einem vollflaechigen Container mit Gradient (der den gesamten
    // Mittelbereich tap-tot machte und damit die Seek-Zonen blockierte)
    // werden Top-Gradient und Bottom-Gradient als zwei getrennte Container
    // gerendert, der Mittelbereich ist eine Spacer ohne Hittest.
    return ExcludeFocus(child: Column(
      children: [
        // Top-Gradient + Titel/Back
        Container(
          decoration: const BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [Colors.black87, Colors.transparent],
            ),
          ),
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              IconButton(
                icon: const Icon(Icons.arrow_back, color: Colors.white),
                onPressed: () => Navigator.pop(context),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  widget.title,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
        ),

        // Mittelbereich: leerer Expanded der KEINE Taps absorbiert, damit
        // die darunterliegenden Seek-Zonen weiterhin auf Klicks reagieren
        // (vorher schluckte der Container mit Decoration alle Taps).
        const Expanded(child: IgnorePointer(child: SizedBox.expand())),

        // Progressbar + Buttons mit Bottom-Gradient als Hintergrund
          Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              children: [
                SliderTheme(
                  data: SliderTheme.of(context).copyWith(
                    thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 8),
                    overlayShape: const RoundSliderOverlayShape(overlayRadius: 16),
                    activeTrackColor: Colors.orange,
                    inactiveTrackColor: Colors.white24,
                    thumbColor: Colors.orange,
                  ),
                  child: Slider(
                    value: progress,
                    onChanged: (v) {
                      _seekToFakePosition(_displayDuration * v);
                      _startHideControlsTimer();
                    },
                  ),
                ),
                Row(
                  children: [
                    Text(
                      '${_formatDuration(_fakePosition)} / ${_formatDuration(_displayDuration)}',
                      style: const TextStyle(color: Colors.white70, fontSize: 13),
                    ),
                    const Spacer(),
                    // Kein Icons.replay_10 / Icons.forward_30 mehr — die
                    // haben Zahlen ("10"/"30") am Icon, das war irrefuehrend
                    // weil die accumulated-seek-Sprungweite variabel ist
                    // (10s → 30s → 1m → 3m → ...). Jetzt genau wie beim
                    // VBW-Player: reine Pfeile ohne Beschriftung.
                    IconButton(
                      icon: const Icon(Icons.fast_rewind, color: Colors.white, size: 36),
                      onPressed: () => _seek(false),
                    ),
                    IconButton(
                      icon: Icon(
                        _isPlaying ? Icons.pause_circle : Icons.play_circle,
                        color: Colors.orange,
                        size: 56,
                      ),
                      onPressed: _togglePlayPause,
                    ),
                    IconButton(
                      icon: const Icon(Icons.fast_forward, color: Colors.white, size: 36),
                      onPressed: () => _seek(true),
                    ),
                    const Spacer(),
                    // Rate-Badge (2x/4x/8x) analog zum VBW-Player. Bei 1x
                    // ausgeblendet damit der Play-Button in der Mitte bleibt.
                    if (_playbackRate > 1.0)
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                        decoration: BoxDecoration(
                          color: Colors.orange,
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: Text(
                          '${_playbackRate.toStringAsFixed(0)}×',
                          style: const TextStyle(
                              color: Colors.black,
                              fontSize: 13,
                              fontWeight: FontWeight.bold),
                        ),
                      )
                    else
                      const SizedBox(width: 80),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
