import 'dart:async';
import 'package:flutter/foundation.dart';
import 'silent_login_flow.dart';

/// Globaler Auth-Zustand. Wird von main.dart beim Start gesetzt und vom
/// Background-Refresh / Silent-Login während der Sitzung aktualisiert.
/// HomeScreen liest das Token bei jedem API-Call frisch aus, statt es per
/// Konstruktor reinzureichen — so kann der Silent-Login die Session
/// updaten ohne dass die UI neu gebaut werden muss.
class AuthState {
  static final ValueNotifier<String> token = ValueNotifier<String>('');
  static final ValueNotifier<bool> isLoggingIn = ValueNotifier<bool>(false);

  /// Ergebnis des letzten (Background-)Silent-Login-Versuchs. Wird von
  /// main.dart::_refreshSessionInBackground gesetzt und vom home_screen
  /// bei Video-Click ausgewertet — damit der User bei einem Fehler direkt
  /// die passende Meldung sieht ohne dass der Silent-Login ein zweites Mal
  /// im Vordergrund laufen muss.
  ///
  /// Wird auf null gesetzt sobald der User die Zugangsdaten aendert (dann
  /// ist das alte Ergebnis stale).
  static SilentLoginResult? lastSilentLoginResult;

  /// Wartet bis ein nicht-leerer Token gesetzt ist ODER der laufende Silent-
  /// Login fertig (erfolglos) ist. Liefert `null` bei Timeout oder wenn gar
  /// kein Login läuft.
  static Future<String?> waitForToken({
    Duration timeout = const Duration(seconds: 8),
  }) {
    if (token.value.isNotEmpty) return Future.value(token.value);
    if (!isLoggingIn.value) return Future.value(null);
    final completer = Completer<String?>();
    void check() {
      if (completer.isCompleted) return;
      if (token.value.isNotEmpty) {
        completer.complete(token.value);
      } else if (!isLoggingIn.value) {
        completer.complete(null);
      }
    }
    token.addListener(check);
    isLoggingIn.addListener(check);
    Timer(timeout, () {
      if (!completer.isCompleted) completer.complete(null);
    });
    return completer.future.whenComplete(() {
      token.removeListener(check);
      isLoggingIn.removeListener(check);
    });
  }
}
