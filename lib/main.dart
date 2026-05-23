import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'screens/login_screen.dart';
import 'screens/home_screen.dart';
import 'services/auth_service.dart';
import 'services/auth_state.dart';
import 'services/silent_login_flow.dart';
import 'l10n/app_language.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  const storage = FlutterSecureStorage();
  final results = await Future.wait([
    storage.read(key: 'access_token'),
    storage.read(key: 'language'),
    storage.read(key: 'saved_email'),
  ]);
  appLanguage.value = results[1] ?? 'en';
  final initialToken = results[0] ?? '';
  final hasSavedCreds = (results[2] ?? '').isNotEmpty;
  AuthState.token.value = initialToken;

  // Wenn entweder ein Token (egal wie alt) oder gespeicherte Credentials
  // vorhanden sind, geht's direkt zur HomeScreen. Listen-APIs laufen auch
  // ohne Token; ein eventuell nötiger Refresh läuft im Hintergrund.
  runApp(BVCTVApp(showHomeInitially: initialToken.isNotEmpty || hasSavedCreds));

  if (initialToken.isNotEmpty || hasSavedCreds) {
    unawaited(_refreshSessionInBackground(initialToken));
  }
}

/// Token-Erneuerung im Hintergrund: blockiert den App-Start nicht. Wenn der
/// gespeicherte Token frisch genug ist, no-op. Sonst refresh_token-Grant
/// (falls verfügbar) und als letzten Ausweg Silent-Re-Login per
/// HeadlessInAppWebView. Erfolg → [AuthState.token] wird gepushed.
Future<void> _refreshSessionInBackground(String initialToken) async {
  const storage = FlutterSecureStorage();
  final savedAtStr = await storage.read(key: 'token_saved_at');
  final savedAt = int.tryParse(savedAtStr ?? '0') ?? 0;
  final ageMs = DateTime.now().millisecondsSinceEpoch - savedAt;
  // Konservativer Threshold um das VBW-3-Geräte-Limit nicht zuzuspammen: jeder
  // Silent-Re-Login kann eine neue Session am Server anlegen. 12h ist
  // pragmatischer Mittelweg (Cookies meist noch warm, max einmal pro App-
  // Session). Bei stale Cookies springt die Player-Side Recovery sowieso ein.
  final isFresh =
      savedAt > 0 && ageMs < const Duration(hours: 12).inMilliseconds;
  if (isFresh && initialToken.isNotEmpty) return;

  AuthState.isLoggingIn.value = true;
  try {
    final refreshToken = await storage.read(key: 'refresh_token');
    if (refreshToken != null && refreshToken.isNotEmpty) {
      final result = await AuthService.refresh();
      if (result == AuthRefreshResult.success) {
        final newToken = await storage.read(key: 'access_token');
        if (newToken != null && newToken.isNotEmpty) {
          await AuthService.refreshTvCookies(newToken);
          AuthState.token.value = newToken;
          return;
        }
      }
    }
    final savedEmail = await storage.read(key: 'saved_email');
    if (savedEmail != null && savedEmail.isNotEmpty) {
      final newToken = await SilentLoginFlow.tryRelogin();
      if (newToken != null && newToken.isNotEmpty) {
        // SilentLoginFlow folgt selbst dem OAuth-Redirect auf tv.*, aber wir
        // pingen die Homepage nochmal explizit damit der Player garantiert
        // mit gesetzten Session-Cookies startet.
        await AuthService.refreshTvCookies(newToken);
        AuthState.token.value = newToken;
      }
    }
  } finally {
    AuthState.isLoggingIn.value = false;
  }
}

class BVCTVApp extends StatelessWidget {
  final bool showHomeInitially;
  const BVCTVApp({super.key, required this.showHomeInitially});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<String>(
      valueListenable: appLanguage,
      builder: (context, lang, child) => MaterialApp(
        title: 'BVCTV',
        debugShowCheckedModeBanner: false,
        theme: ThemeData.dark().copyWith(
          colorScheme: ColorScheme.dark(
            primary: Colors.orange,
            secondary: Colors.orangeAccent,
          ),
          scaffoldBackgroundColor: const Color(0xFF0A0A0A),
        ),
        home: showHomeInitially ? const HomeScreen() : const LoginScreen(),
      ),
    );
  }
}
