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
        ),
      ),
    );

    if (!mounted) return;

    if (code == null) {
      setState(() {
        _isLoading = false;
        _errorMessage = S.loginCancelled;
      });
      return;
    }

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
        setState(() =>
            _errorMessage = S.tokenError(tokenResponse.statusCode));
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
      body: Center(
        child: _errorMessage != null
            ? Column(
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
              )
            : const CircularProgressIndicator(color: Colors.orange),
      ),
    );
  }
}

class _AuthWebViewScreen extends StatefulWidget {
  final String url;
  final String redirectUri;

  const _AuthWebViewScreen({required this.url, required this.redirectUri});

  @override
  State<_AuthWebViewScreen> createState() => _AuthWebViewScreenState();
}

class _AuthWebViewScreenState extends State<_AuthWebViewScreen> {
  bool _loading = true;
  InAppWebViewController? _webController;
  String? _pendingCode;
  final GlobalKey _stackKey = GlobalKey();

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

  // Returns JSON: {isInput, type, value, placeholder}
  static const _checkInputScript = '''
(function(){
  var el = document.activeElement;
  if(!el) return '{"isInput":false}';
  var t = el.tagName;
  if(t==='INPUT'||t==='TEXTAREA'){
    return JSON.stringify({
      isInput:true,
      type: el.type||'text',
      value: el.value||'',
      placeholder: el.placeholder||''
    });
  }
  return '{"isInput":false}';
})()
''';

  bool _handleKeyEvent(KeyEvent event) {
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

    // 1. Erst prüfen was an der Cursor-Position ist — OHNE das Element anzuklicken.
    //    So wird die native Android-Tastatur nicht ausgelöst bevor der Dialog erscheint.
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
        // 2. Dialog öffnen — WebView-Input ist noch NICHT fokussiert
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
          // 3. Fokussieren und Wert setzen — kein Auto-Submit
          //    Der User klickt den Button danach selbst mit dem Cursor
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

    // 4. Kein Eingabefeld: normaler Klick (mousedown/mouseup/click)
    await _webController?.evaluateJavascript(source: _clickAtScript(_cursorX, _cursorY));
  }

  Future<String?> _showTextInputDialog(
      String value, String type, String placeholder) {
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
          keyboardType: isEmail ? TextInputType.emailAddress : TextInputType.text,
          style: const TextStyle(color: Colors.white),
          decoration: InputDecoration(
            hintText: placeholder.isNotEmpty ? placeholder : null,
            hintStyle: const TextStyle(color: Colors.white38),
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
            child: Text(S.cancel, style: const TextStyle(color: Colors.white54)),
          ),
          ElevatedButton(
            autofocus: false,
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.orange,
              foregroundColor: Colors.black,
            ),
            onPressed: () => Navigator.pop(ctx, ctrl.text),
            child: const Text('OK', style: TextStyle(fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    );
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
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_handleKeyEvent);
    _moveTimer?.cancel();
    super.dispose();
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
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              child: Row(
                children: [
                  IconButton(
                    icon: const Icon(Icons.arrow_back, color: Colors.white70),
                    onPressed: () => Navigator.of(context).pop(null),
                  ),
                  Text(
                    S.loginTitle,
                    style: const TextStyle(color: Colors.white70, fontSize: 16),
                  ),
                ],
              ),
            ),
            Expanded(
              child: LayoutBuilder(
                builder: (_, constraints) {
                  _webViewSize = Size(constraints.maxWidth, constraints.maxHeight);
                  if (_cursorX == 300 && _cursorY == 200) {
                    _cursorX = _webViewSize.width / 2;
                    _cursorY = _webViewSize.height / 2;
                  }
                  return Stack(
                    key: _stackKey,
                    children: [
                      InAppWebView(
                        initialUrlRequest: URLRequest(url: WebUri(widget.url)),
                        initialSettings: InAppWebViewSettings(
                          javaScriptEnabled: true,
                          cacheMode: CacheMode.LOAD_NO_CACHE,
                          clearCache: true,
                          userAgent:
                              'Mozilla/5.0 (Linux; Android 12; Mobile) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Mobile Safari/537.36',
                        ),
                        onWebViewCreated: (c) => _webController = c,
                        onLoadStart: (_, __) => setState(() => _loading = true),
                        onLoadStop: (_, __) async {
                          setState(() => _loading = false);
                          await _webController?.evaluateJavascript(source: _initScript);
                          if (_pendingCode != null) {
                            if (!mounted) return;
                            final nav = Navigator.of(context);
                            setState(() => _loading = true);
                            final code = _pendingCode!;
                            _pendingCode = null;
                            await Future.delayed(const Duration(milliseconds: 800));
                            if (mounted) nav.pop(code);
                          }
                        },
                        shouldOverrideUrlLoading: (controller, action) async {
                          final url = action.request.url?.toString() ?? '';
                          if (url.startsWith(widget.redirectUri)) {
                            final code = Uri.parse(url).queryParameters['code'];
                            if (code != null && code.isNotEmpty) {
                              _pendingCode = code;
                              return NavigationActionPolicy.ALLOW;
                            }
                            return NavigationActionPolicy.ALLOW;
                          }
                          return NavigationActionPolicy.ALLOW;
                        },
                      ),
                      if (_loading)
                        const Center(
                          child: CircularProgressIndicator(color: Colors.orange),
                        ),
                      Positioned(
                        left: _cursorX,
                        top: _cursorY,
                        child: const IgnorePointer(child: _CursorWidget()),
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
