import 'dart:async';
import 'dart:collection' show UnmodifiableListView;
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;

/// Result of a refresh attempt:
/// - [success]: neuer access_token + (ggf.) neuer refresh_token gespeichert
/// - [needsLogin]: refresh_token ist ungültig/abgelaufen — interaktiver Login nötig
/// - [error]: Netzwerk- oder Server-Fehler — alter Token bleibt, später nochmal versuchen
enum AuthRefreshResult { success, needsLogin, error }

class AuthService {
  static const _clientId = '93d30c71-8a06-46c3-a288-dfb48f082313';
  static const _tokenEndpoint =
      'https://signin.volleyballworld.com/api/oidc/vbtv-web/token';

  static const _storage = FlutterSecureStorage();

  /// Versucht den access_token via refresh_token zu erneuern.
  /// Setzt nebenbei frische Session-Cookies auf tv.volleyballworld.com,
  /// indem nach erfolgreichem Refresh ein InAppWebView die /api/oauth-Seite lädt.
  /// — Wir können die Cookie-Setzung über den OAuth-Code-Flow nicht direkt
  ///   ohne neuen Code triggern; refresh_token allein erneuert nur den
  ///   API-Token. Für die tv-Domain Cookies hilft ein simples Pageview
  ///   mit dem neuen Token im localStorage (gleicher Mechanismus wie im Player).
  static Future<AuthRefreshResult> refresh() async {
    final refreshToken = await _storage.read(key: 'refresh_token');
    if (refreshToken == null || refreshToken.isEmpty) {
      debugPrint('[bvctv-auth] no refresh_token → needsLogin');
      return AuthRefreshResult.needsLogin;
    }

    try {
      final res = await http.post(
        Uri.parse(_tokenEndpoint),
        headers: {'Content-Type': 'application/x-www-form-urlencoded'},
        body: {
          'grant_type': 'refresh_token',
          'client_id': _clientId,
          'refresh_token': refreshToken,
        },
      ).timeout(const Duration(seconds: 10));

      debugPrint('[bvctv-auth] refresh status=${res.statusCode}');

      if (res.statusCode == 200) {
        final data = jsonDecode(res.body);
        final newAccess = data['access_token'] as String?;
        final newRefresh = data['refresh_token'] as String?;
        if (newAccess == null || newAccess.isEmpty) {
          debugPrint('[bvctv-auth] refresh ok but no access_token in body');
          return AuthRefreshResult.error;
        }
        await _storage.write(key: 'access_token', value: newAccess);
        // Rotating refresh tokens: viele OIDC-Server liefern einen neuen
        // refresh_token mit. Den alten ungültig markieren wäre Server-Sache.
        if (newRefresh != null && newRefresh.isNotEmpty) {
          await _storage.write(key: 'refresh_token', value: newRefresh);
        }
        await _storage.write(
          key: 'token_saved_at',
          value: DateTime.now().millisecondsSinceEpoch.toString(),
        );
        debugPrint('[bvctv-auth] refresh success, new refresh_token=${newRefresh != null}');
        return AuthRefreshResult.success;
      }

      // 400/401 mit invalid_grant → refresh_token ist tot
      if (res.statusCode == 400 || res.statusCode == 401) {
        try {
          final body = jsonDecode(res.body);
          final err = body['error'] as String?;
          debugPrint('[bvctv-auth] refresh rejected: $err');
          if (err == 'invalid_grant' ||
              err == 'invalid_token' ||
              err == 'unauthorized_client') {
            // refresh_token unbrauchbar — löschen damit wir nicht nochmal probieren
            await _storage.delete(key: 'refresh_token');
            return AuthRefreshResult.needsLogin;
          }
        } catch (_) {}
        return AuthRefreshResult.needsLogin;
      }

      // 5xx oder andere Fehler → später nochmal probieren
      return AuthRefreshResult.error;
    } catch (e) {
      debugPrint('[bvctv-auth] refresh exception: $e');
      return AuthRefreshResult.error;
    }
  }

  /// Lädt tv.volleyballworld.com im Hintergrund-WebView damit der Server
  /// frische Session-Cookies setzt. Das ist nötig weil refresh_token nur
  /// den API-Access-Token erneuert, nicht die tv.*-Cookies — und der Player
  /// braucht die Cookies um nicht seine eigene Login-UI zu zeigen.
  static Future<void> refreshTvCookies(String accessToken) async {
    final completer = Completer<void>();
    HeadlessInAppWebView? headless;
    Timer? timeout;

    void finish() {
      timeout?.cancel();
      try {
        headless?.dispose();
      } catch (_) {}
      if (!completer.isCompleted) completer.complete();
    }

    timeout = Timer(const Duration(seconds: 8), () {
      debugPrint('[bvctv-auth] tv cookie warmup timeout');
      finish();
    });

    final tokenEscaped =
        accessToken.replaceAll('\\', '\\\\').replaceAll('"', '\\"');

    headless = HeadlessInAppWebView(
      initialUrlRequest: URLRequest(
        url: WebUri('https://tv.volleyballworld.com/'),
      ),
      initialUserScripts: UnmodifiableListView([
        UserScript(
          source: '''
            try {
              localStorage.setItem("quick-bricky-login-flow.access_token", "$tokenEscaped");
            } catch(e) {}
          ''',
          injectionTime: UserScriptInjectionTime.AT_DOCUMENT_START,
        ),
      ]),
      initialSettings: InAppWebViewSettings(
        javaScriptEnabled: true,
        userAgent:
            'Mozilla/5.0 (Linux; Android 12; Mobile) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Mobile Safari/537.36',
      ),
      onLoadStop: (controller, url) async {
        debugPrint('[bvctv-auth] tv cookie warmup loaded: $url');
        // Cookies sind jetzt vom Server gesetzt
        await Future.delayed(const Duration(milliseconds: 500));
        finish();
      },
      onReceivedError: (controller, request, error) {
        debugPrint('[bvctv-auth] tv cookie warmup error: ${error.description}');
        finish();
      },
    );

    try {
      await headless.run();
    } catch (e) {
      debugPrint('[bvctv-auth] tv cookie warmup run exception: $e');
      finish();
    }

    return completer.future;
  }

  /// Komplettes Logout: alle gespeicherten Tokens löschen.
  static Future<void> logout() async {
    await _storage.delete(key: 'access_token');
    await _storage.delete(key: 'refresh_token');
    await _storage.delete(key: 'token_saved_at');
  }
}
