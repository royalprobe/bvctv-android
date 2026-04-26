import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'screens/login_screen.dart';
import 'screens/home_screen.dart';

void main() {
  runApp(const BVCTVApp());
}

class BVCTVApp extends StatelessWidget {
  const BVCTVApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'BVCTV',
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark().copyWith(
        colorScheme: ColorScheme.dark(
          primary: Colors.orange,
          secondary: Colors.orangeAccent,
        ),
        scaffoldBackgroundColor: const Color(0xFF0A0A0A),
      ),
      home: FutureBuilder<String?>(
        future: const FlutterSecureStorage().read(key: 'access_token'),
        builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done) {
            return const Scaffold(
              backgroundColor: Color(0xFF0A0A0A),
              body: Center(child: CircularProgressIndicator(color: Colors.orange)),
            );
          }
          final token = snapshot.data;
          if (token != null && token.isNotEmpty) {
            return HomeScreen(accessToken: token);
          }
          return const LoginScreen();
        },
      ),
    );
  }
}
