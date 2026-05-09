import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'screens/login_screen.dart';
import 'screens/home_screen.dart';
import 'l10n/app_language.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  const storage = FlutterSecureStorage();
  final results = await Future.wait([
    storage.read(key: 'access_token'),
    storage.read(key: 'language'),
  ]);
  appLanguage.value = results[1] ?? 'de';
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
            ? HomeScreen(accessToken: initialToken!)
            : const LoginScreen(),
      ),
    );
  }
}
