import 'dart:async';
import 'dart:convert';
import 'dart:math';
import '../l10n/strings.dart';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;

import 'home_screen.dart';

enum _AuthMode { oidc, fulljitflow }

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  bool _isLoading = true;
  String? _errorMessage;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _login());
  }

  static const _clientId = '93d30c71-8a06-46c3-a288-dfb48f082313';
  static const _redirectUri = 'https://tv.volleyballworld.com/api/oauth';
  static const _authEndpoint =
      'https://signin.volleyballworld.com/service/oidc/vbtv-web/authorize';
  static const _tokenEndpoint =
      'https://signin.volleyballworld.com/api/oidc/vbtv-web/token';
  static const _phase2VideoId = 'rqgkYjJX';

  String _generateCodeVerifier() {
    final random = Random.secure();
    final bytes = List<int>.generate(32, (_) => random.nextInt(256));
    return base64UrlEncode(bytes).replaceAll('=', '');
  }

  String _generateCodeChallenge(String verifier) {
    final digest = sha256.convert(utf8.encode(verifier));
    return base64UrlEncode(digest.bytes).replaceAll('=', '');
  }

  Future<void> _login() async {
    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    // ── Phase 1: OIDC login → access_token ──────────────────────────────────
    final codeVerifier = _generateCodeVerifier();
    final authUrl = Uri.parse(_authEndpoint).replace(queryParameters: {
      'response_type': 'code',
      'client_id': _clientId,
      'redirect_uri': _redirectUri,
      'scope': 'openid email profile',
      'code_challenge': _generateCodeChallenge(codeVerifier),
      'code_challenge_method': 'S256',
      'prompt': 'login',
      'workflow': 'fulljitflow_v3_fast',
    });

    final code = await Navigator.push<String>(
      context,
      MaterialPageRoute(
        builder: (_) => _AuthWebViewScreen(
          url: authUrl.toString(),
          redirectUri: _redirectUri,
          mode: _AuthMode.oidc,
        ),
      ),
    );

    if (!mounted) return;

    if (code == null) {
      // Should not normally happen (no back button), but guard defensively.
      setState(() { _isLoading = false; _errorMessage = S.loginCancelled; });
      return;
    }

    // ── Phase 2: fulljitflow → long-lived player session cookies ─────────────
    // Remove short-lived OIDC cookies so the player page triggers fulljitflow.
    try {
      await CookieManager.instance()
          .deleteCookies(url: WebUri('https://tv.volleyballworld.com'));
    } catch (_) {}

    if (!mounted) return;

    final playerUrl =
        'https://tv.volleyballworld.com/player?self-link='
        '${Uri.encodeComponent("https://zapp-5434-volleyball-tv.web.app/jw/media/$_phase2VideoId")}';

    await Navigator.push<bool>(
      context,
      MaterialPageRoute(
        builder: (_) => _AuthWebViewScreen(
          url: playerUrl,
          redirectUri: _redirectUri,
          mode: _AuthMode.fulljitflow,
        ),
      ),
    );

    if (!mounted) return;

    // ── Token exchange with Phase 1 OIDC code ────────────────────────────────
    try {
      final tokenResponse = await http.post(
        Uri.parse(_tokenEndpoint),
        headers: {'Content-Type': 'application/x-www-form-urlencoded'},
        body: {
          'grant_type': 'authorization_code',
          'client_id': _clientId,
          'redirect_uri': _redirectUri,
          'code': code,
          'code_verifier': codeVerifier,
        },
      );

      if (tokenResponse.statusCode == 200) {
        final data = jsonDecode(tokenResponse.body);
        final token = data['access_token'];
        if (token != null && mounted) {
          await const FlutterSecureStorage()
              .write(key: 'access_token', value: token);
          Navigator.pushReplacement(
            context,
            MaterialPageRoute(builder: (_) => HomeScreen(accessToken: token)),
          );
        }
      } else {
        setState(() => _errorMessage = S.tokenError(tokenResponse.statusCode));
      }
    } catch (e) {
      setState(() => _errorMessage = S.errorMsg(e.toString()));
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: _errorMessage != null
          ? Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(
                    _errorMessage!,
                    style: const TextStyle(color: Colors.redAccent, fontSize: 16),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 24),
                  ElevatedButton.icon(
                    autofocus: true,
                    onPressed: _login,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.orange,
                      foregroundColor: Colors.black,
                    ),
                    icon: const Icon(Icons.refresh),
                    label: Text(S.retryLogin),
                  ),
                ],
              ),
            )
          : const SizedBox.shrink(),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────

class _AuthWebViewScreen extends StatefulWidget {
  final String url;
  final String redirectUri;
  final _AuthMode mode;

  const _AuthWebViewScreen({
    required this.url,
    required this.redirectUri,
    required this.mode,
  });

  @override
  State<_AuthWebViewScreen> createState() => _AuthWebViewScreenState();
}

class _AuthWebViewScreenState extends State<_AuthWebViewScreen> {
  bool _loading = true;
  InAppWebViewController? _webController;
  bool _dialogShowing = false;
  final GlobalKey _stackKey = GlobalKey();

  // OIDC mode: captures the authorisation code
  String? _oidcCode;
  bool _oidcPopped = false;

  // Fulljitflow mode: waits for session cookies to be set
  bool _jitPlayerLoaded = false; // skip first onLoadStop (player page itself)
  bool _jitDone = false;
  Timer? _jitTimer;

  double _cursorX = 300;
  double _cursorY = 200;
  Size _webViewSize = const Size(1280, 720);

  final Set<LogicalKeyboardKey> _heldKeys = {};
  Timer? _moveTimer;
  double _speed = 5.0;
  static const double _minSpeed = 5.0;
  static const double _maxSpeed = 42.0;

  static const _touchChannel = MethodChannel('bvctv/touch');

  static const _initScript = r'''
(function () {
  if (window.__bvctv_init) return;
  window.__bvctv_init = true;
  var s = document.createElement('style');
  s.textContent =
    '*:focus{outline:3px solid #FF6600!important;' +
    'outline-offset:3px!important;' +
    'box-shadow:0 0 0 6px rgba(255,102,0,.35)!important;' +
    'border-radius:3px!important;}';
  document.head.appendChild(s);
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
  target.focus();
  ['mousedown','mouseup','click'].forEach(function(ev){
    target.dispatchEvent(new MouseEvent(ev,{bubbles:true,cancelable:true,view:window,clientX:x,clientY:y}));
  });
})();
''';
  }

  bool _handleKeyEvent(KeyEvent event) {
    if (_dialogShowing) return false;
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
        _performSelect();
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

  Future<void> _performSelect() async {
    final xs = _cursorX.toStringAsFixed(1);
    final ys = _cursorY.toStringAsFixed(1);

    final raw = await _webController?.evaluateJavascript(source: '''
(function(){
  var el = document.elementFromPoint($xs,$ys);
  if(!el) return '{"isInput":false}';
  var inp = el.closest('input,textarea');
  if(inp) return JSON.stringify({
    isInput:true, type:inp.type||'text',
    value:inp.value||'', placeholder:inp.placeholder||''
  });
  return '{"isInput":false}';
})()
''');
    if (!mounted) return;

    try {
      final data = jsonDecode(raw?.toString() ?? '{}');
      if (data['isInput'] == true) {
        final text = await _showTextInputDialog(
          data['value'] as String? ?? '',
          data['type'] as String? ?? 'text',
          data['placeholder'] as String? ?? '',
        );
        if (text != null && mounted) {
          final escaped = text
              .replaceAll('\\', '\\\\')
              .replaceAll("'", "\\'")
              .replaceAll('\n', '\\n');
          await _webController?.evaluateJavascript(source: '''
(function(){
  var el = document.elementFromPoint($xs,$ys);
  if(!el) return;
  var inp = el.closest('input,textarea') || el;
  inp.focus();
  try{
    var s=Object.getOwnPropertyDescriptor(window.HTMLInputElement.prototype,'value').set;
    s.call(inp,'$escaped');
  }catch(e){ inp.value='$escaped'; }
  inp.dispatchEvent(new Event('input',{bubbles:true}));
  inp.dispatchEvent(new Event('change',{bubbles:true}));
})()
''');
        }
        return;
      }
    } catch (_) {}

    await _webController?.evaluateJavascript(
        source: _clickAtScript(_cursorX, _cursorY));
  }

  Future<String?> _showTextInputDialog(
      String value, String type, String placeholder) {
    _dialogShowing = true;
    final ctrl = TextEditingController(text: value);
    final isPassword = type == 'password';
    final isEmail = type == 'email';
    return showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1A1A1A),
        title: Text(
          isEmail ? S.emailAddress : isPassword ? S.password : S.input,
          style: const TextStyle(color: Colors.white),
        ),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          obscureText: isPassword,
          keyboardType:
              isEmail ? TextInputType.emailAddress : TextInputType.text,
          style: const TextStyle(color: Colors.white),
          decoration: InputDecoration(
            hintText: placeholder.isNotEmpty ? placeholder : null,
            hintStyle: const TextStyle(color: Colors.white38),
            filled: true,
            fillColor: const Color(0xFF2A2A2A),
            border:
                OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
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
            child:
                Text(S.cancel, style: const TextStyle(color: Colors.white54)),
          ),
          ElevatedButton(
            autofocus: false,
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.orange,
              foregroundColor: Colors.black,
            ),
            onPressed: () => Navigator.pop(ctx, ctrl.text),
            child:
                const Text('OK', style: TextStyle(fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    ).whenComplete(() => _dialogShowing = false);
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

  Future<void> _injectNativeTouch() async {
    final box = _stackKey.currentContext?.findRenderObject() as RenderBox?;
    if (box == null) return;
    final stackOffset = box.localToGlobal(Offset.zero);
    final absX = stackOffset.dx + _cursorX;
    final absY = stackOffset.dy + _cursorY;
    try {
      await _touchChannel.invokeMethod('tap', {'x': absX, 'y': absY});
    } catch (_) {}
  }

  @override
  void initState() {
    super.initState();
    HardwareKeyboard.instance.addHandler(_handleKeyEvent);

    if (widget.mode == _AuthMode.fulljitflow) {
      // Fallback: close Phase 2 screen after 45 s even if cookies never appear.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        final nav = Navigator.of(context);
        _jitTimer = Timer(const Duration(seconds: 45), () {
          if (!_jitDone && mounted) {
            _jitDone = true;
            debugPrint('[BVCTV] phase2: timeout');
            nav.pop(false);
          }
        });
      });
    }
  }

  Future<void> _saveTvCookies(String tag) async {
    try {
      final cm = CookieManager.instance();
      final cookies =
          await cm.getCookies(url: WebUri('https://tv.volleyballworld.com'));
      if (cookies.isNotEmpty) {
        final json = jsonEncode(cookies
            .map((c) => {
                  'name': c.name,
                  'value': c.value,
                  'domain': c.domain ?? '.tv.volleyballworld.com',
                  'path': c.path ?? '/',
                })
            .toList());
        await const FlutterSecureStorage()
            .write(key: 'tv_cookies', value: json);
        debugPrint('$tag: saved ${cookies.length} TV cookies');
      } else {
        debugPrint('$tag: no TV cookies to save');
      }
    } catch (e) {
      debugPrint('$tag: cookie error $e');
    }
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_handleKeyEvent);
    _moveTimer?.cancel();
    _jitTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isTV = MediaQuery.of(context).size.shortestSide > 450;
    return PopScope(
      canPop: false,
      child: Scaffold(
        backgroundColor: Colors.black,
        body: SafeArea(
          child: Column(
            children: [
              Container(
                color: const Color(0xFF1A1A1A),
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    widget.mode == _AuthMode.fulljitflow
                        ? S.loginTitle
                        : S.loginTitle,
                    style: const TextStyle(color: Colors.white70, fontSize: 16),
                  ),
                ),
              ),
              Expanded(
                child: LayoutBuilder(
                  builder: (_, constraints) {
                    _webViewSize =
                        Size(constraints.maxWidth, constraints.maxHeight);
                    if (_cursorX == 300 && _cursorY == 200) {
                      _cursorX = _webViewSize.width / 2;
                      _cursorY = _webViewSize.height / 2;
                    }
                    return Stack(
                      key: _stackKey,
                      children: [
                        InAppWebView(
                          initialUrlRequest:
                              URLRequest(url: WebUri(widget.url)),
                          initialSettings: InAppWebViewSettings(
                            javaScriptEnabled: true,
                            cacheMode: CacheMode.LOAD_NO_CACHE,
                            clearCache: true,
                            userAgent:
                                'Mozilla/5.0 (Linux; Android 12; Mobile) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Mobile Safari/537.36',
                          ),
                          onWebViewCreated: (c) => _webController = c,
                          onLoadStart: (_, __) =>
                              setState(() => _loading = true),
                          onLoadStop: (_, url) async {
                            setState(() => _loading = false);
                            await _webController?.evaluateJavascript(
                                source: _initScript);
                            if (!mounted) return;

                            if (widget.mode == _AuthMode.oidc) {
                              // Pop as soon as the OIDC code has been captured
                              // and api/oauth has finished setting its cookies.
                              if (_oidcCode != null && !_oidcPopped) {
                                _oidcPopped = true;
                                final nav = Navigator.of(context);
                                if (mounted) nav.pop(_oidcCode);
                              }
                            } else {
                              // fulljitflow mode: skip the first page load (the
                              // player page we loaded), then watch for the
                              // api/oauth redirect landing back on
                              // tv.volleyballworld.com with cookies set.
                              if (!_jitPlayerLoaded) {
                                _jitPlayerLoaded = true;
                              } else if ((url?.toString() ?? '')
                                  .contains('tv.volleyballworld.com')) {
                                final cookies = await CookieManager.instance()
                                    .getCookies(
                                        url: WebUri(
                                            'https://tv.volleyballworld.com'));
                                if (cookies.isNotEmpty && !_jitDone) {
                                  _jitDone = true;
                                  _jitTimer?.cancel();
                                  final nav = Navigator.of(context);
                                  await _saveTvCookies('[BVCTV] phase2');
                                  if (mounted) nav.pop(true);
                                }
                              }
                            }
                          },
                          shouldOverrideUrlLoading:
                              (controller, action) async {
                            if (widget.mode == _AuthMode.oidc) {
                              final url =
                                  action.request.url?.toString() ?? '';
                              if (url.startsWith(widget.redirectUri) &&
                                  _oidcCode == null) {
                                final code =
                                    Uri.parse(url).queryParameters['code'];
                                if (code != null && code.isNotEmpty) {
                                  _oidcCode = code;
                                }
                              }
                            }
                            return NavigationActionPolicy.ALLOW;
                          },
                        ),
                        if (_loading)
                          const Center(
                            child: CircularProgressIndicator(
                                color: Colors.orange),
                          ),
                        if (isTV)
                          Positioned(
                            left: _cursorX,
                            top: _cursorY,
                            child: const IgnorePointer(
                                child: _CursorWidget()),
                          ),
                      ],
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _CursorWidget extends StatelessWidget {
  const _CursorWidget();

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      size: const Size(22, 26),
      painter: _CursorPainter(),
    );
  }
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
        ..strokeJoin = StrokeJoin.round,
    );
    canvas.drawPath(
      path,
      Paint()..color = Colors.white..style = PaintingStyle.fill,
    );
  }

  @override
  bool shouldRepaint(covariant CustomPainter old) => false;
}
