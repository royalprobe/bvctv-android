import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;

/// Grund fuers Scheitern eines Silent-Login-Versuchs. Wird an das UI
/// weitergegeben damit dem User pro Fall eine sinnvolle Aktion angeboten
/// werden kann (Creds korrigieren vs. Passwort extern reseten).
enum SilentLoginResult {
  success,
  noCredentials, // saved_email/password fehlt in FlutterSecureStorage
  invalidCredentials, // signin.* akzeptiert die Creds nicht (Timeout ohne Redirect)
  deviceLimit, // VBW-3-Geraete-Limit — "Device Limit Reached"-Page
  networkError, // http-Fehler / WebView-Exception
}

class SilentLoginOutcome {
  final SilentLoginResult result;
  final String? token;
  const SilentLoginOutcome._(this.result, {this.token});
  static const noCredentials = SilentLoginOutcome._(SilentLoginResult.noCredentials);
  static const invalidCredentials = SilentLoginOutcome._(SilentLoginResult.invalidCredentials);
  static const deviceLimit = SilentLoginOutcome._(SilentLoginResult.deviceLimit);
  static const networkError = SilentLoginOutcome._(SilentLoginResult.networkError);
  factory SilentLoginOutcome.success(String token) =>
      SilentLoginOutcome._(SilentLoginResult.success, token: token);
  bool get isSuccess => result == SilentLoginResult.success;
}

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

  /// Legacy-Wrapper — gibt bei Erfolg den Token zurueck, sonst null.
  /// Wird von main.dart:_refreshSessionInBackground genutzt wo nur
  /// success/fail interessiert.
  static Future<String?> tryRelogin() async {
    final outcome = await tryReloginDetailed();
    return outcome.token;
  }

  /// Wie [tryRelogin], aber mit detailliertem Fehler-Grund (fuer die UI im
  /// home_screen, damit der User bei falschen Creds und Device-Limit die
  /// jeweils passende Aktion angeboten bekommt).
  static Future<SilentLoginOutcome> tryReloginDetailed() async {
    final email = await _storage.read(key: 'saved_email');
    final password = await _storage.read(key: 'saved_password');
    if (email == null || email.isEmpty || password == null || password.isEmpty) {
      debugPrint('[bvctv-silent] no credentials, skip');
      return SilentLoginOutcome.noCredentials;
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
      // prompt=login bewusst weggelassen: zwingt den Server sonst jedesmal
      // eine neue Session aufzumachen → zählt aufs 3-Geräte-Limit. Ohne den
      // Parameter darf der Server vorhandene signin.* Cookies wiederverwenden
      // (Cookie-Jar wird zwischen WebViews geteilt) und es entsteht kein
      // neuer Device-Eintrag. Fällt sowieso auf das Login-Formular zurück,
      // wenn keine gültige Session existiert — Autofill greift dann.
      'workflow': 'fulljitflow_v3_fast',
    }).toString();

    final completer = Completer<SilentLoginOutcome>();
    HeadlessInAppWebView? headless;
    Timer? timeoutTimer;
    Timer? deviceLimitPoll;
    String? pendingCode;
    final autofillJs = _buildAutofillScript(email, password);

    void finish(SilentLoginOutcome outcome) {
      timeoutTimer?.cancel();
      deviceLimitPoll?.cancel();
      try {
        headless?.dispose();
      } catch (_) {}
      if (!completer.isCompleted) completer.complete(outcome);
    }

    // Timeout ohne erfolgreichen Redirect zu tv.* interpretieren wir als
    // "Credentials passen nicht" — sonst waeren wir laengst durch. Falls
    // sich zwischenzeitlich die Device-Limit-Page gemeldet hat, hat der
    // Poll-Handler unten die Result-Variante bereits ueberschrieben.
    timeoutTimer = Timer(const Duration(seconds: 18), () {
      debugPrint('[bvctv-silent] timeout — assuming invalid credentials');
      finish(SilentLoginOutcome.invalidCredentials);
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
            finish(SilentLoginOutcome.invalidCredentials);
            return NavigationActionPolicy.CANCEL;
          }
        }
        return NavigationActionPolicy.ALLOW;
      },
      onLoadStop: (controller, url) async {
        final u = url?.toString() ?? '';
        debugPrint('[bvctv-silent] loaded: $u');
        if (u.startsWith('https://signin.volleyballworld.com')) {
          // Device-Limit-Page erkennen bevor der Autofill den "Verify"-
          // Button druecken kann (der Password-Reset-Flow ausloest). Wenn
          // das Body-Text "Device Limit Reached" / "signed in on 3 devices"
          // enthaelt, brechen wir ab.
          try {
            final txt = await controller.evaluateJavascript(source:
              "(document.body && (document.body.innerText || '')).toLowerCase()")
              as String?;
            if (txt != null &&
                (txt.contains('device limit') ||
                 txt.contains('signed in on 3 devices'))) {
              debugPrint('[bvctv-silent] device-limit detected — abort');
              finish(SilentLoginOutcome.deviceLimit);
              return;
            }
          } catch (_) {}
          await controller.evaluateJavascript(source: autofillJs);

          // Nach dem Autofill-Submit kann der Device-Limit-Bildschirm mit
          // leichter Verzoegerung nachrutschen. Alle 500ms nachschauen bis
          // wir entweder erfolgreich weitergeleitet werden oder der
          // Overall-Timeout schlaegt.
          deviceLimitPoll ??= Timer.periodic(const Duration(milliseconds: 500),
              (t) async {
            if (completer.isCompleted) { t.cancel(); return; }
            try {
              final txt2 = await controller.evaluateJavascript(source:
                "(document.body && (document.body.innerText || '')).toLowerCase()")
                as String?;
              if (txt2 != null &&
                  (txt2.contains('device limit') ||
                   txt2.contains('signed in on 3 devices'))) {
                debugPrint('[bvctv-silent] device-limit detected mid-flow');
                finish(SilentLoginOutcome.deviceLimit);
              }
            } catch (_) {}
          });
        }
        if (pendingCode != null &&
            u.startsWith('https://tv.volleyballworld.com') &&
            !u.contains('/api/oauth') &&
            !u.contains('/login') &&
            !u.contains('/oauth?')) {
          final code = pendingCode!;
          pendingCode = null;
          final token = await _exchangeCode(code, codeVerifier);
          if (token != null && token.isNotEmpty) {
            finish(SilentLoginOutcome.success(token));
          } else {
            finish(SilentLoginOutcome.networkError);
          }
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
      finish(SilentLoginOutcome.networkError);
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
    if (attempts > 60) { clearInterval(timer); window.__bvctv_autofill_running = false; return; }
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
  }, 100);
})();
''';
  }
}
