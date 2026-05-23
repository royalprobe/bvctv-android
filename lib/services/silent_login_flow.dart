import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;

/// Versucht einen kompletten OAuth-Flow ohne sichtbares UI:
/// HeadlessInAppWebView lädt die /authorize-URL → wenn das signin-Formular
/// rendert, füllt unser Autofill-JS die gespeicherten Credentials ein und
/// klickt den Anmelden-Button → Server redirected zurück auf tv.* → wir
/// fangen den Code in shouldOverrideUrlLoading ab → Token-Exchange via http
/// → token + cookies frisch.
///
/// Returns: neuer access_token bei Erfolg, sonst null (Timeout/Error).
class SilentLoginFlow {
  static const _clientId = '93d30c71-8a06-46c3-a288-dfb48f082313';
  static const _redirectUri = 'https://tv.volleyballworld.com/api/oauth';
  static const _authEndpoint =
      'https://signin.volleyballworld.com/service/oidc/vbtv-web/authorize';
  static const _tokenEndpoint =
      'https://signin.volleyballworld.com/api/oidc/vbtv-web/token';

  static const _storage = FlutterSecureStorage();

  static Future<String?> tryRelogin() async {
    final email = await _storage.read(key: 'saved_email');
    final password = await _storage.read(key: 'saved_password');
    if (email == null || email.isEmpty || password == null || password.isEmpty) {
      debugPrint('[bvctv-silent] no credentials, skip');
      return null;
    }

    final codeVerifier = _generateCodeVerifier();
    final challenge = _generateCodeChallenge(codeVerifier);
    final authUrl = Uri.parse(_authEndpoint).replace(queryParameters: {
      'response_type': 'code',
      'client_id': _clientId,
      'redirect_uri': _redirectUri,
      'scope': 'openid email profile',
      'code_challenge': challenge,
      'code_challenge_method': 'S256',
      'prompt': 'login',
      'workflow': 'fulljitflow_v3_fast',
    }).toString();

    final completer = Completer<String?>();
    HeadlessInAppWebView? headless;
    Timer? timeout;
    String? pendingCode;
    final autofillJs = _buildAutofillScript(email, password);

    void finish(String? token) {
      timeout?.cancel();
      try {
        headless?.dispose();
      } catch (_) {}
      if (!completer.isCompleted) completer.complete(token);
    }

    timeout = Timer(const Duration(seconds: 18), () {
      debugPrint('[bvctv-silent] timeout');
      finish(null);
    });

    headless = HeadlessInAppWebView(
      initialUrlRequest: URLRequest(url: WebUri(authUrl)),
      initialSettings: InAppWebViewSettings(
        javaScriptEnabled: true,
        userAgent:
            'Mozilla/5.0 (Linux; Android 12; Mobile) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Mobile Safari/537.36',
      ),
      shouldOverrideUrlLoading: (controller, action) async {
        final url = action.request.url?.toString() ?? '';
        debugPrint('[bvctv-silent] nav: $url');
        if (url.startsWith(_redirectUri)) {
          final params = Uri.parse(url).queryParameters;
          if (params.containsKey('code')) {
            pendingCode = params['code'];
            return NavigationActionPolicy.ALLOW;
          } else if (params.containsKey('error')) {
            debugPrint('[bvctv-silent] error: ${params['error']}');
            finish(null);
            return NavigationActionPolicy.CANCEL;
          }
        }
        return NavigationActionPolicy.ALLOW;
      },
      onLoadStop: (controller, url) async {
        final u = url?.toString() ?? '';
        debugPrint('[bvctv-silent] loaded: $u');
        if (u.startsWith('https://signin.volleyballworld.com')) {
          await controller.evaluateJavascript(source: autofillJs);
        }
        if (pendingCode != null &&
            u.startsWith('https://tv.volleyballworld.com') &&
            !u.contains('/api/oauth') &&
            !u.contains('/login') &&
            !u.contains('/oauth?')) {
          final code = pendingCode!;
          pendingCode = null;
          final token = await _exchangeCode(code, codeVerifier);
          finish(token);
        }
      },
      onReceivedError: (controller, request, error) {
        debugPrint('[bvctv-silent] webview error: ${error.description}');
      },
    );

    try {
      await headless.run();
    } catch (e) {
      debugPrint('[bvctv-silent] run exception: $e');
      finish(null);
    }

    return completer.future;
  }

  static Future<String?> _exchangeCode(String code, String verifier) async {
    try {
      final res = await http.post(
        Uri.parse(_tokenEndpoint),
        headers: {'Content-Type': 'application/x-www-form-urlencoded'},
        body: {
          'grant_type': 'authorization_code',
          'client_id': _clientId,
          'redirect_uri': _redirectUri,
          'code': code,
          'code_verifier': verifier,
        },
      ).timeout(const Duration(seconds: 10));
      debugPrint('[bvctv-silent] token exchange status=${res.statusCode}');
      if (res.statusCode == 200) {
        final data = jsonDecode(res.body);
        final token = data['access_token'] as String?;
        if (token != null && token.isNotEmpty) {
          await _storage.write(key: 'access_token', value: token);
          await _storage.write(
            key: 'token_saved_at',
            value: DateTime.now().millisecondsSinceEpoch.toString(),
          );
        }
        return token;
      }
    } catch (e) {
      debugPrint('[bvctv-silent] token exchange err: $e');
    }
    return null;
  }

  static String _generateCodeVerifier() {
    final random = Random.secure();
    final bytes = List<int>.generate(32, (_) => random.nextInt(256));
    return base64UrlEncode(bytes).replaceAll('=', '');
  }

  static String _generateCodeChallenge(String verifier) {
    return base64UrlEncode(sha256.convert(utf8.encode(verifier)).bytes)
        .replaceAll('=', '');
  }

  static String _jsEscape(String s) => s
      .replaceAll('\\', '\\\\')
      .replaceAll("'", "\\'")
      .replaceAll('\n', '\\n')
      .replaceAll('\r', '\\r')
      .replaceAll('<', '\\x3c')
      .replaceAll('>', '\\x3e');

  /// Identisch zu _autofillScript in login_screen.dart — füllt
  /// E-Mail/Passwort und klickt den Submit-Button. Läuft mit Polling
  /// weil React-Apps die Inputs verzögert mounten.
  static String _buildAutofillScript(String email, String password) {
    final emailJs = "'${_jsEscape(email)}'";
    final pwJs = "'${_jsEscape(password)}'";
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
    var btns = Array.prototype.slice.call(document.querySelectorAll(
      'button[type="submit"], button:not([type]), input[type="submit"]'
    ));
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
    if (passInp && pw) {
      if (lastFilled !== 'p') {
        if (!passInp.value) setVal(passInp, pw);
        lastFilled = 'p';
        setTimeout(function(){ var b = findSubmit(); if (b) b.click(); }, 200);
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
        setTimeout(function(){ var b = findSubmit(); if (b) b.click(); }, 200);
      }
      return;
    }
  }, 250);
})();
''';
  }
}
