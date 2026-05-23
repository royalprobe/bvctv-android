import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'screens/login_screen.dart';
import 'screens/home_screen.dart';
import 'services/auth_service.dart';
import 'l10n/app_language.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  const storage = FlutterSecureStorage();
  final results = await Future.wait([
    storage.read(key: 'access_token'),
    storage.read(key: 'language'),
  ]);
  appLanguage.value = results[1] ?? 'en';
  runApp(BVCTVApp(initialToken: results[0]));
}

class BVCTVApp extends StatelessWidget {
  final String? initialToken;
  const BVCTVApp({super.key, this.initialToken});

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
        home: initialToken != null && initialToken!.isNotEmpty
            ? _SessionGate(initialToken: initialToken!)
            : const LoginScreen(),
      ),
    );
  }
}

/// Beim App-Start mit gespeichertem Token: Token-Alter prüfen.
/// — Frisch (< 6h): direkt zu HomeScreen, kein Refresh nötig.
/// — Älter: refresh_token-Grant ausführen, tv-Cookies warmpingen,
///   dann HomeScreen mit neuem Token. Bei needsLogin: LoginScreen.
class _SessionGate extends StatefulWidget {
  final String initialToken;
  const _SessionGate({required this.initialToken});

  @override
  State<_SessionGate> createState() => _SessionGateState();
}

class _SessionGateState extends State<_SessionGate> {
  Widget? _next;

  @override
  void initState() {
    super.initState();
    _run();
  }

  Future<void> _run() async {
    const storage = FlutterSecureStorage();

    // Hinweis: signin.volleyballworld.com unterstützt offline_access nicht
    // (siehe Kommentar in login_screen.dart), also haben wir nie einen
    // refresh_token. Falls doch einer gespeichert ist (z.B. Server-Update
    // in der Zukunft), versuchen wir den Refresh-Flow.
    final refreshToken = await storage.read(key: 'refresh_token');
    if (refreshToken == null || refreshToken.isEmpty) {
      if (mounted) {
        setState(() => _next = HomeScreen(accessToken: widget.initialToken));
      }
      return;
    }

    final savedAtStr = await storage.read(key: 'token_saved_at');
    final savedAt = int.tryParse(savedAtStr ?? '0') ?? 0;
    final ageMs = DateTime.now().millisecondsSinceEpoch - savedAt;
    final isFresh = savedAt > 0 && ageMs < const Duration(hours: 6).inMilliseconds;

    if (isFresh) {
      if (mounted) {
        setState(() => _next = HomeScreen(accessToken: widget.initialToken));
      }
      return;
    }

    // Token ist älter — refresh versuchen.
    final result = await AuthService.refresh();

    if (result == AuthRefreshResult.needsLogin) {
      if (mounted) setState(() => _next = const LoginScreen());
      return;
    }

    String token = widget.initialToken;
    if (result == AuthRefreshResult.success) {
      final newToken = await storage.read(key: 'access_token');
      if (newToken != null && newToken.isNotEmpty) token = newToken;
      await AuthService.refreshTvCookies(token);
    }
    if (mounted) setState(() => _next = HomeScreen(accessToken: token));
  }

  @override
  Widget build(BuildContext context) {
    if (_next != null) return _next!;
    return const Scaffold(
      backgroundColor: Color(0xFF0A0A0A),
      body: Center(
        child: CircularProgressIndicator(color: Colors.orange),
      ),
    );
  }
}
