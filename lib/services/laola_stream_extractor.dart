import 'dart:async';
import 'dart:collection' show UnmodifiableListView;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import '../screens/player_screen.dart';

/// Zeigt die Laola1-Player-Seite sichtbar in einem WebView mit Cursor-Support
/// (Pfeiltasten = Cursor bewegen, Enter = Klicken). User akzeptiert Cookies
/// selbst, dann lädt der Spott-Player. Im Hintergrund hört ein JS-Hook auf
/// XHR/fetch-Requests — sobald eine .m3u8 erscheint, wechseln wir in den
/// nativen PlayerScreen. Falls die Extraktion nicht klappt (z.B. DRM),
/// kann der User direkt im WebView weiterschauen.
class LaolaStreamExtractor extends StatefulWidget {
  final String pageUrl;
  final String title;

  const LaolaStreamExtractor({
    super.key,
    required this.pageUrl,
    required this.title,
  });

  @override
  State<LaolaStreamExtractor> createState() => _LaolaStreamExtractorState();
}

class _LaolaStreamExtractorState extends State<LaolaStreamExtractor> {
  InAppWebViewController? _controller;
  bool _completed = false;
  String _hint = 'Cookies akzeptieren um Stream zu laden';

  double _cursorX = 300;
  double _cursorY = 200;
  Size _webViewSize = const Size(1280, 720);
  final Set<LogicalKeyboardKey> _heldKeys = {};
  Timer? _moveTimer;
  double _speed = 5.0;
  static const double _minSpeed = 5.0;
  static const double _maxSpeed = 42.0;

  @override
  void initState() {
    super.initState();
    HardwareKeyboard.instance.addHandler(_handleKey);
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_handleKey);
    _moveTimer?.cancel();
    super.dispose();
  }

  static const String _captureScript = r'''
(function() {
  if (window.__bvctvLaolaInjected) return;
  window.__bvctvLaolaInjected = true;
  function callFlutter(name, payload) {
    try { window.flutter_inappwebview.callHandler(name, payload); } catch(e) {}
  }
  function report(url) {
    if (!url || typeof url !== 'string') return;
    callFlutter('LaolaTrace', url);
    if (url.indexOf('.m3u8') >= 0) callFlutter('LaolaStream', url);
  }
  try {
    var origOpen = XMLHttpRequest.prototype.open;
    XMLHttpRequest.prototype.open = function(method, url) {
      try { report(typeof url === 'string' ? url : (url && url.toString())); } catch(e) {}
      return origOpen.apply(this, arguments);
    };
  } catch(e) {}
  try {
    var origFetch = window.fetch;
    if (origFetch) {
      window.fetch = function(input, init) {
        try {
          var u = typeof input === 'string' ? input : (input && input.url);
          report(u);
        } catch(e) {}
        return origFetch.apply(this, arguments);
      };
    }
  } catch(e) {}
  // Sichtbarer Fokus-Ring für TV-Cursor / Spatial Navigation
  var s = document.createElement('style');
  s.textContent = '*:focus{outline:3px solid #FF6600!important;outline-offset:2px!important;}';
  document.head.appendChild(s);
  // Periodisches Polling auf <video src>
  var polls = 0;
  var poller = setInterval(function() {
    polls++;
    var v = document.querySelector('video');
    if (v && v.src && v.src.indexOf('blob:') !== 0) report(v.src);
    if (polls > 120) clearInterval(poller);
  }, 500);
})();
''';

  static String _clickAtScript(double x, double y) {
    final xs = x.toStringAsFixed(1);
    final ys = y.toStringAsFixed(1);
    return '''
(function(){
  var x=$xs, y=$ys;
  var el = document.elementFromPoint(x,y);
  if(!el) return;
  var target = el.closest('input,button,a,select,textarea,[role="button"],[tabindex]') || el;
  try { target.focus(); } catch(e) {}
  ['mousedown','mouseup','click'].forEach(function(ev){
    target.dispatchEvent(new MouseEvent(ev,{bubbles:true,cancelable:true,view:window,clientX:x,clientY:y}));
  });
})();
''';
  }

  bool _handleKey(KeyEvent event) {
    final key = event.logicalKey;
    final isDpad = key == LogicalKeyboardKey.arrowUp ||
        key == LogicalKeyboardKey.arrowDown ||
        key == LogicalKeyboardKey.arrowLeft ||
        key == LogicalKeyboardKey.arrowRight;
    final isSelect = key == LogicalKeyboardKey.select ||
        key == LogicalKeyboardKey.enter ||
        key == LogicalKeyboardKey.numpadEnter;
    if (!isDpad && !isSelect) return false;
    if (event is KeyDownEvent) {
      if (isSelect) {
        _controller?.evaluateJavascript(
            source: _clickAtScript(_cursorX, _cursorY));
        return true;
      }
      _heldKeys.add(key);
      _ensureTimer();
      return true;
    }
    if (event is KeyUpEvent) {
      _heldKeys.remove(key);
      if (_heldKeys.isEmpty) _stopTimer();
      return true;
    }
    if (event is KeyRepeatEvent) return isDpad || isSelect;
    return false;
  }

  void _ensureTimer() {
    if (_moveTimer != null) return;
    _speed = _minSpeed;
    _moveTimer = Timer.periodic(const Duration(milliseconds: 16), (_) {
      if (!mounted || _heldKeys.isEmpty) return;
      double dx = 0, dy = 0;
      if (_heldKeys.contains(LogicalKeyboardKey.arrowLeft)) dx -= _speed;
      if (_heldKeys.contains(LogicalKeyboardKey.arrowRight)) dx += _speed;
      if (_heldKeys.contains(LogicalKeyboardKey.arrowUp)) dy -= _speed;
      if (_heldKeys.contains(LogicalKeyboardKey.arrowDown)) dy += _speed;
      setState(() {
        _cursorX = (_cursorX + dx).clamp(0, _webViewSize.width - 4);
        _cursorY = (_cursorY + dy).clamp(0, _webViewSize.height - 4);
      });
      _speed = (_speed * 1.07).clamp(_minSpeed, _maxSpeed);
    });
  }

  void _stopTimer() {
    _moveTimer?.cancel();
    _moveTimer = null;
    _speed = _minSpeed;
  }

  void _finishWithStream(String streamUrl) {
    if (_completed) return;
    _completed = true;
    if (!mounted) return;
    Navigator.pushReplacement(
      context,
      MaterialPageRoute(
        builder: (_) =>
            PlayerScreen(title: widget.title, streamUrl: streamUrl),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Column(
          children: [
            Container(
              color: const Color(0xFF1A1A1A),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              child: Row(
                children: [
                  IconButton(
                    icon: const Icon(Icons.arrow_back, color: Colors.white),
                    onPressed: () => Navigator.pop(context),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(widget.title,
                            style: const TextStyle(
                                color: Colors.white, fontSize: 14)),
                        Text(_hint,
                            style: const TextStyle(
                                color: Colors.orange, fontSize: 11)),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            Expanded(
              child: LayoutBuilder(
                builder: (_, c) {
                  _webViewSize = Size(c.maxWidth, c.maxHeight);
                  return Stack(
                    children: [
                      InAppWebView(
                        initialUrlRequest:
                            URLRequest(url: WebUri(widget.pageUrl)),
                        initialSettings: InAppWebViewSettings(
                          javaScriptEnabled: true,
                          mediaPlaybackRequiresUserGesture: false,
                          allowsInlineMediaPlayback: true,
                          userAgent:
                              'Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36',
                        ),
                        initialUserScripts: UnmodifiableListView([
                          UserScript(
                            source: _captureScript,
                            injectionTime:
                                UserScriptInjectionTime.AT_DOCUMENT_START,
                          ),
                        ]),
                        onWebViewCreated: (controller) {
                          _controller = controller;
                          controller.addJavaScriptHandler(
                            handlerName: 'LaolaStream',
                            callback: (args) {
                              if (args.isEmpty || _completed) return;
                              final url = args[0].toString();
                              debugPrint(
                                  '[laola-extract] STREAM captured: $url');
                              _finishWithStream(url);
                            },
                          );
                          controller.addJavaScriptHandler(
                            handlerName: 'LaolaTrace',
                            callback: (args) {
                              if (args.isEmpty) return;
                              final s = args[0].toString();
                              final short = s.length > 200
                                  ? '${s.substring(0, 200)}…'
                                  : s;
                              debugPrint('[laola-extract] trace: $short');
                            },
                          );
                        },
                        onConsoleMessage: (controller, msg) {
                          debugPrint(
                              '[laola-extract] console.${msg.messageLevel}: ${msg.message}');
                        },
                        onLoadStop: (controller, url) {
                          debugPrint('[laola-extract] page loaded: $url');
                          if (mounted) {
                            setState(() => _hint =
                                'Pfeiltasten → Cursor, Enter = Klicken');
                          }
                        },
                        onReceivedError: (controller, request, error) {
                          debugPrint(
                              '[laola-extract] webview error: ${error.description} url=${request.url}');
                        },
                      ),
                      Positioned(
                        left: _cursorX,
                        top: _cursorY,
                        child: const IgnorePointer(child: _Cursor()),
                      ),
                    ],
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Cursor extends StatelessWidget {
  const _Cursor();
  @override
  Widget build(BuildContext context) =>
      CustomPaint(size: const Size(22, 26), painter: _CursorPainter());
}

class _CursorPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final path = Path()
      ..moveTo(0, 0)
      ..lineTo(0, 20)
      ..lineTo(4.5, 15)
      ..lineTo(8, 22)
      ..lineTo(10.5, 21)
      ..lineTo(7, 14)
      ..lineTo(13, 14)
      ..close();
    canvas.drawPath(
        path,
        Paint()
          ..color = Colors.black
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2.5
          ..strokeJoin = StrokeJoin.round);
    canvas.drawPath(
        path, Paint()..color = Colors.white..style = PaintingStyle.fill);
  }

  @override
  bool shouldRepaint(covariant CustomPainter old) => false;
}
