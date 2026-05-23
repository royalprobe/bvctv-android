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

import '../services/auth_state.dart';
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
      // offline_access wird von signin.volleyballworld.com NICHT unterstützt —
      // Server returnt error=invalid_request beim /authorize. Daher zurück auf
      // standard scope ohne refresh_token. Stattdessen: gespeicherte Credentials
      // füllen das Login-Formular automatisch aus.
      'scope': 'openid email profile',
      'code_challenge': _generateCodeChallenge(codeVerifier),
      'code_challenge_method': 'S256',
      // prompt=login bewusst weggelassen — siehe SilentLoginFlow für Hintergrund
      // (zwingt sonst eine neue Session pro Aufruf → 3-Geräte-Limit voll).
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

    String? token;
    String? refreshToken;
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
      debugPrint('[bvctv-login] token exchange status=${tokenResponse.statusCode}');
      if (tokenResponse.statusCode == 200) {
        final data = jsonDecode(tokenResponse.body);
        token = data['access_token'] as String?;
        refreshToken = data['refresh_token'] as String?;
        debugPrint('[bvctv-login] tokens: access=${token != null} refresh=${refreshToken != null}');
      } else {
        // Body kürzen damit der Log nicht explodiert
        final body = tokenResponse.body.length > 400
            ? '${tokenResponse.body.substring(0, 400)}...'
            : tokenResponse.body;
        debugPrint('[bvctv-login] token exchange body: $body');
      }
    } catch (e) {
      debugPrint('[bvctv-login] token exchange error: $e');
    }

    if (!mounted) return;
    // Auch ohne Token weitermachen: Cookies auf tv.volleyballworld.com sind gesetzt,
    // Player funktioniert via Session. Home-API nutzt ctx mit Token (kann fehlschlagen).
    const storage = FlutterSecureStorage();
    final finalToken = token ?? '';
    await storage.write(key: 'access_token', value: finalToken);
    if (refreshToken != null && refreshToken.isNotEmpty) {
      await storage.write(key: 'refresh_token', value: refreshToken);
    }
    await storage.write(
      key: 'token_saved_at',
      value: DateTime.now().millisecondsSinceEpoch.toString(),
    );
    AuthState.token.value = finalToken;
    if (mounted) {
      // Mid-App-Login (z.B. nach Logout oder Video-Klick ohne Token): nur poppen.
      // Erster App-Start (LoginScreen ist Stack-Wurzel): zur HomeScreen wechseln.
      if (Navigator.canPop(context)) {
        Navigator.pop(context, true);
      } else {
        Navigator.pushReplacement(
          context,
          MaterialPageRoute(builder: (_) => const HomeScreen()),
        );
      }
    }
    if (mounted) setState(() => _isLoading = false);
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
  final GlobalKey _stackKey = GlobalKey();
  String? _pendingCode;
  String? _savedEmail;
  String? _savedPassword;

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

  // Captures a newly-set password on the "Set your password" page so the
  // saved credentials stay in sync after VBW forces a reset (e.g. wegen
  // 3-Geräte-Limit). Only fires when the page actually looks like a
  // password-reset prompt, to avoid grabbing the regular login password.
  static const _passwordCaptureScript = r'''
(function() {
  if (window.__bvctv_pw_hook_installed) return;
  function bodyTextMatches(needles) {
    var t = (document.body && document.body.textContent || '').toLowerCase();
    for (var i = 0; i < needles.length; i++) {
      if (t.indexOf(needles[i]) >= 0) return true;
    }
    return false;
  }
  function tryInstall() {
    var pwInputs = document.querySelectorAll('input[type="password"]');
    if (pwInputs.length === 0) return false;
    if (!bodyTextMatches([
      'set your password',
      'set password',
      'neues passwort',
      'passwort festlegen',
    ])) return false;

    function readAndSend() {
      try {
        var pw = pwInputs[0].value || '';
        if (pw.length > 0) {
          window.flutter_inappwebview.callHandler('BvctvNewPassword', pw);
        }
      } catch (e) {}
    }

    document.querySelectorAll('button, input[type="submit"]').forEach(function(btn) {
      if (btn.__bvctvHooked) return;
      btn.__bvctvHooked = true;
      btn.addEventListener('click', readAndSend, true);
    });
    document.querySelectorAll('form').forEach(function(f) {
      if (f.__bvctvHooked) return;
      f.__bvctvHooked = true;
      f.addEventListener('submit', readAndSend, true);
    });
    return true;
  }

  if (tryInstall()) {
    window.__bvctv_pw_hook_installed = true;
    return;
  }
  // SPA-Rendering: spät nachfragen, ob die Seite jetzt das Reset-Formular zeigt.
  var attempts = 0;
  var iv = setInterval(function() {
    if (window.__bvctv_pw_hook_installed || attempts++ > 30) {
      clearInterval(iv);
      return;
    }
    if (tryInstall()) {
      window.__bvctv_pw_hook_installed = true;
      clearInterval(iv);
    }
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
    _loadSavedCredentials();
  }

  Future<void> _loadSavedCredentials() async {
    const storage = FlutterSecureStorage();
    final email = await storage.read(key: 'saved_email');
    final pw = await storage.read(key: 'saved_password');
    if (mounted) {
      setState(() {
        _savedEmail = email;
        _savedPassword = pw;
      });
    }
  }

  /// Escape für Einbettung in einen einfach-quotierten JS-String.
  static String _jsEscape(String s) => s
      .replaceAll('\\', '\\\\')
      .replaceAll("'", "\\'")
      .replaceAll('\n', '\\n')
      .replaceAll('\r', '\\r')
      .replaceAll('<', '\\x3c')
      .replaceAll('>', '\\x3e');

  /// Findet E-Mail/Password-Inputs auf der signin-Seite, füllt sie mit
  /// den gespeicherten Daten, und klickt den Weiter-/Anmelden-Button.
  /// Läuft mehrfach (kleine Polls) weil React-Apps die Inputs verzögert mounten.
  String _autofillScript() {
    final email = _savedEmail;
    final pw = _savedPassword;
    if ((email == null || email.isEmpty) && (pw == null || pw.isEmpty)) {
      return '';
    }
    final emailJs = email != null && email.isNotEmpty ? "'${_jsEscape(email)}'" : 'null';
    final pwJs = pw != null && pw.isNotEmpty ? "'${_jsEscape(pw)}'" : 'null';

    // Setter über das Native HTMLInputElement.prototype.value — sonst sieht
    // React den Wert nicht. dispatchEvent('input') feuert state-update.
    return '''
(function(){
  if (window.__bvctv_autofill_running) return;
  window.__bvctv_autofill_running = true;
  var email = $emailJs;
  var pw = $pwJs;
  var setter = Object.getOwnPropertyDescriptor(window.HTMLInputElement.prototype, 'value').set;
  function setVal(el, val){
    setter.call(el, val);
    el.dispatchEvent(new Event('input', {bubbles:true}));
    el.dispatchEvent(new Event('change', {bubbles:true}));
  }
  function findEmail(){
    return document.querySelector('input[type="email"]')
      || document.querySelector('input[name*="email" i]')
      || document.querySelector('input[autocomplete="username"]')
      || document.querySelector('input[autocomplete="email"]')
      || document.querySelector('input[name*="user" i]');
  }
  function findPass(){
    return document.querySelector('input[type="password"]');
  }
  function findSubmit(){
    // 1. Sichtbarer enabled submit-button in der Nähe des fokussierten/gefüllten Inputs
    var btns = Array.prototype.slice.call(document.querySelectorAll(
      'button[type="submit"], button:not([type]), input[type="submit"]'
    ));
    // Filter: sichtbar + nicht disabled
    btns = btns.filter(function(b){
      if (b.disabled) return false;
      var r = b.getBoundingClientRect();
      return r.width > 0 && r.height > 0;
    });
    return btns[0] || null;
  }
  var attempts = 0;
  var lastFilled = '';
  var timer = setInterval(function(){
    attempts++;
    if (attempts > 30) { clearInterval(timer); window.__bvctv_autofill_running = false; return; }
    var emailInp = findEmail();
    var passInp = findPass();
    var key = (emailInp ? 'e' : '') + (passInp ? 'p' : '');
    // Phase 1: nur E-Mail sichtbar
    if (passInp && pw) {
      if (lastFilled !== 'p') {
        if (!passInp.value) setVal(passInp, pw);
        lastFilled = 'p';
        setTimeout(function(){
          var b = findSubmit();
          if (b) b.click();
        }, 200);
        // Nach Submit Phase warten kurz, dann Polling beenden
        setTimeout(function(){
          clearInterval(timer);
          window.__bvctv_autofill_running = false;
        }, 800);
      }
      return;
    }
    if (emailInp && email) {
      if (lastFilled !== 'e') {
        if (!emailInp.value) setVal(emailInp, email);
        lastFilled = 'e';
        setTimeout(function(){
          var b = findSubmit();
          if (b) b.click();
        }, 200);
      }
      return;
    }
  }, 250);
})();
''';
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_handleKeyEvent);
    _moveTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      child: Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Column(
          children: [
            Container(
              color: const Color(0xFF1A1A1A),
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              child: Row(
                children: [
                  const SizedBox(width: 12),
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
                          userAgent:
                              'Mozilla/5.0 (Linux; Android 12; Mobile) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Mobile Safari/537.36',
                        ),
                        onWebViewCreated: (c) {
                          _webController = c;
                          c.addJavaScriptHandler(
                            handlerName: 'BvctvNewPassword',
                            callback: (args) async {
                              if (args.isEmpty) return;
                              final pw = args[0]?.toString() ?? '';
                              if (pw.isEmpty) return;
                              debugPrint(
                                  '[bvctv-login] captured new password (len=${pw.length}) — updating saved_password');
                              await const FlutterSecureStorage().write(
                                  key: 'saved_password', value: pw);
                            },
                          );
                        },
                        onLoadStart: (_, url) {
                          debugPrint('[bvctv-login] onLoadStart: $url');
                          setState(() => _loading = true);
                        },
                        onLoadStop: (_, url) async {
                          debugPrint('[bvctv-login] onLoadStop: $url');
                          setState(() => _loading = false);
                          await _webController?.evaluateJavascript(source: _initScript);
                          await _webController?.evaluateJavascript(
                              source: _passwordCaptureScript);
                          // Hinterlegte Anmeldedaten auf signin.* automatisch eintragen.
                          final urlStr = url?.toString() ?? '';
                          if (urlStr.startsWith('https://signin.volleyballworld.com')) {
                            final js = _autofillScript();
                            if (js.isNotEmpty) {
                              await _webController?.evaluateJavascript(source: js);
                            }
                          }
                          // OAuth-Callback erfolgreich = Server redirected nach Cookie-Setzung
                          // auf tv.volleyballworld.com/ (oder andere nicht-Auth-Seite).
                          // Auf /login oder /oauth bleiben heißt Auth ist fehlgeschlagen — WebView offen lassen.
                          final isTvDomain = urlStr.startsWith('https://tv.volleyballworld.com');
                          final isAuthPath = urlStr.contains('/api/oauth') ||
                              urlStr.contains('/login') ||
                              urlStr.contains('/oauth?');
                          if (_pendingCode != null && isTvDomain && !isAuthPath) {
                            debugPrint('[bvctv-login] auth landed on tv homepage, popping (codeLen=${_pendingCode!.length})');
                            final code = _pendingCode!;
                            _pendingCode = null;
                            if (mounted) Navigator.of(context).pop(code);
                          }
                        },
                        // Fire Stick / Amazon WebView crasht den Renderer beim
                        // OIDC-Submit. Statt Route fallen zu lassen (→ "Login
                        // Cancelled"), URL neu laden — Session-Cookies bleiben.
                        onRenderProcessGone: (controller, detail) async {
                          debugPrint('[bvctv-login] onRenderProcessGone didCrash=${detail.didCrash} priority=${detail.rendererPriorityAtExit}');
                          if (!mounted) return;
                          setState(() => _loading = true);
                          await controller.loadUrl(
                            urlRequest: URLRequest(url: WebUri(widget.url)),
                          );
                        },
                        shouldOverrideUrlLoading: (controller, action) async {
                          final url = action.request.url?.toString() ?? '';
                          debugPrint('[bvctv-login] shouldOverrideUrlLoading: $url');
                          if (url.startsWith(widget.redirectUri)) {
                            final params = Uri.parse(url).queryParameters;
                            final code = params['code'];
                            final error = params['error'];
                            if (code != null && code.isNotEmpty) {
                              // ALLOW statt CANCEL: Server-Callback muss laufen damit
                              // Session-Cookies auf tv.volleyballworld.com gesetzt werden
                              // (sonst zeigt der Player später seinen eigenen Login).
                              // Pop passiert in onLoadStop nachdem die Seite geladen hat.
                              _pendingCode = code;
                              debugPrint('[bvctv-login] code received, letting redirect complete (len=${code.length})');
                            } else if (error != null && error.isNotEmpty) {
                              // OIDC-Fehler (z.B. invalid_request, access_denied) — sonst landet
                              // der WebView auf tv.volleyballworld.com/ und der User strandet
                              // auf der Homepage ohne Login-UI.
                              debugPrint('[bvctv-login] OIDC error: $error desc=${params['error_description']}');
                              if (mounted) Navigator.of(context).pop(null);
                              return NavigationActionPolicy.CANCEL;
                            }
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
