import 'dart:async';
import 'dart:collection' show UnmodifiableListView;
import 'dart:convert';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:webview_flutter_android/webview_flutter_android.dart';

import '../app_variant.dart';
import '../l10n/strings.dart';

/// WebView-basierter Player fuer VBW-Inhalte (JW Player im eingebetteten
/// Browser). Fuer Laola-/Twitch-Streams gibt es stattdessen den nativen
/// PlayerScreen in player_screen.dart.
///
/// Lag frueher mit ueber 1200 Zeilen in home_screen.dart, obwohl er mit dem
/// Home-Screen nichts teilt ausser den Strings und der Build-Variante.

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
              child: Center(child: AppVariant.showClubBranding
                // Vereins-Build: orange Kapsel mit "Powered by" + BVC-Logo.
                ? Container(
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
                  )
                // Neutrale Variante: echter Kreis (BoxShape.circle, feste
                // Kantenlaenge) statt der Kapsel — die passt sich sonst dem
                // Inhalt an und wird zum Oval. Darin das App-Logo mit dem
                // Hinweis darunter. Bewusst die freigestellte Logo-Fassung:
                // bvctv_logo.png hat KEIN Alpha und wuerde als weisse Flaeche
                // auf dem Orange kleben.
                : Builder(builder: (ctx) {
                    final d = MediaQuery.of(ctx).size.shortestSide * 0.62;
                    return Container(
                      width: d,
                      height: d,
                      decoration: const BoxDecoration(
                        color: Colors.orange,
                        shape: BoxShape.circle,
                      ),
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Image.asset('assets/bvctv_logo_transparent.png',
                              width: d * 0.5, height: d * 0.5, fit: BoxFit.contain),
                          SizedBox(height: d * 0.03),
                          Text(S.blackScreenHint,
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              color: Colors.black.withValues(alpha: 0.55),
                              fontSize: d * 0.062,
                              fontWeight: FontWeight.bold,
                            )),
                        ],
                      ),
                    );
                  }),
              ),
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
