import 'app_language.dart';

class S {
  static bool get isEn => appLanguage.value == 'en';

  // Settings
  static String get settings => isEn ? 'Settings' : 'Einstellungen';
  static String get twoHourMode => isEn ? '2-Hour Mode' : '2-Stunden-Modus';
  static String get twoHourModeOnDesc => isEn
      ? 'Progress bar extends to 2h (for delayed streams)'
      : 'Fortschrittsbalken geht bis 2h (für zeitversetzte Streams)';
  static String get twoHourModeOffDesc => isEn
      ? 'Progress bar ends with the video'
      : 'Fortschrittsbalken endet mit dem Video';
  static String get spoilerProtection => isEn ? 'Spoiler Protection' : 'Spoiler-Schutz';
  static String get spoilerOnDesc => isEn
      ? 'Team names hidden in semifinals/finals/bronze'
      : 'Teamnamen in Halbfinale/Finale/Bronze verborgen';
  static String get spoilerOffDesc =>
      isEn ? 'All team names visible' : 'Alle Teamnamen sichtbar';
  static String get language => isEn ? 'Language' : 'Sprache';
  static String get languageGerman => isEn ? 'German' : 'Deutsch';
  static String get languageEnglish => 'English';

  // Account
  static String get logoutTitle => isEn ? 'Log out?' : 'Abmelden?';
  static String get logoutDesc => isEn
      ? 'You will be logged out and must sign in again.'
      : 'Du wirst ausgeloggt und musst dich erneut anmelden.';
  static String get cancel => isEn ? 'Cancel' : 'Abbrechen';
  static String get logout => isEn ? 'Log out' : 'Abmelden';
  static String get done => isEn ? 'Done' : 'Fertig';
  static String get alreadyUpToDate => isEn ? 'Already up to date.' : 'Bereits die neueste Version.';
  static String get checkForUpdates => isEn ? 'Check for updates' : 'Auf Updates prüfen';

  // App exit
  static String get exitAppTitle => isEn ? 'Exit app?' : 'App beenden?';
  static String get exitAppDesc =>
      isEn ? 'Do you really want to close the app?' : 'Willst du die App wirklich schließen?';
  static String get exit => isEn ? 'Exit' : 'Beenden';

  // Filter
  static String get all => isEn ? 'All' : 'Alle';
  static String get men => isEn ? 'Men' : 'Herren';
  static String get women => isEn ? 'Women' : 'Damen';
  static String get allTournaments => isEn ? 'All tournaments' : 'Alle Turniere';
  static String get tournament => isEn ? 'Tournament' : 'Turnier';
  static String get allPlayers => isEn ? 'All players' : 'Alle Spieler';
  static String get searchPlayers => isEn ? 'Search players...' : 'Spieler suchen...';
  static String get allCountries => isEn ? 'All countries' : 'Alle Länder';

  // Video list
  static String get tryAgain => isEn ? 'Try again' : 'Nochmal versuchen';
  static String get liveGame => isEn ? 'Live game' : 'Live-Spiel';
  static String get liveDialogText => isEn
      ? 'This game is live.\nWatch from the beginning or join live?'
      : 'Dieses Spiel läuft gerade live.\nMöchtest du von Anfang an schauen oder direkt einsteigen?';
  static String get fromStart => isEn ? 'From start' : 'Von Anfang an';
  static String get joinLive => isEn ? 'Join live' : 'Live einsteigen';
  static String get opensYouTube => isEn ? 'Opens YouTube app' : 'Öffnet YouTube-App';
  static String get spoilerActive =>
      isEn ? 'Spoiler protection active' : 'Spoiler-Schutz aktiv';

  // Update dialog
  static String downloadProgress(int pct) => isEn ? '$pct% downloaded…' : '$pct% heruntergeladen…';
  static String get later => isEn ? 'Later' : 'Später';
  static String get installNow => isEn ? 'Install now' : 'Jetzt installieren';
  static String errorMsg(String e) => isEn ? 'Error: $e' : 'Fehler: $e';
  static String connectionError(String e) =>
      isEn ? 'Connection error: $e' : 'Verbindungsfehler: $e';
  static String httpError(int code) => isEn ? 'Error $code' : 'Fehler $code';

  // Login screen
  static String get loginTitle => isEn ? 'BVCTV Login' : 'BVCTV Anmeldung';
  static String get loginCancelled => isEn ? 'Login cancelled.' : 'Login abgebrochen.';
  static String tokenError(int code) => isEn ? 'Token error: $code' : 'Token-Fehler: $code';
  static String get retryLogin => isEn ? 'Try again' : 'Erneut versuchen';
  static String get emailAddress => isEn ? 'Email address' : 'E-Mail-Adresse';
  static String get password => isEn ? 'Password' : 'Passwort';
  static String get input => isEn ? 'Input' : 'Eingabe';

  // Saved credentials
  static String get savedCredentials =>
      isEn ? 'Saved login' : 'Gespeicherte Anmeldedaten';
  static String get savedCredentialsHint => isEn
      ? 'Auto-fill the login form when you need to sign in again'
      : 'Login-Formular automatisch ausfüllen wenn du dich neu anmelden musst';
  static String get credentialsNotSet => isEn ? 'Not set' : 'Nicht hinterlegt';
  static String get credentialsSet => isEn ? 'Stored' : 'Hinterlegt';
  static String get save => isEn ? 'Save' : 'Speichern';
  static String get clear => isEn ? 'Clear' : 'Löschen';
  static String get autoFillNotice => isEn
      ? 'Stored securely on this device (Keystore). Used to auto-fill the official login page.'
      : 'Wird verschlüsselt am Gerät gespeichert (Keystore). Wird zum automatischen Ausfüllen der offiziellen Login-Seite verwendet.';

  // Player
  static String tapCount(int n) => isEn ? 'Tap $n' : 'Klick $n';
  static String get behindLive => isEn ? 'behind live' : 'hinter Live';

  // Months
  static List<String> get months => isEn
      ? ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec']
      : ['Jan', 'Feb', 'Mär', 'Apr', 'Mai', 'Jun', 'Jul', 'Aug', 'Sep', 'Okt', 'Nov', 'Dez'];

  // Rounds — canonical stored value is always English; localize for display
  static Set<String> get spoilerRounds => const {'Final', 'Semifinal', '3rd Place'};

  static String localizeRound(String r) {
    if (isEn) return r;
    switch (r) {
      case 'Final': return 'Finale';
      case '3rd Place': return '3. Platz';
      case 'Semifinal': return 'Halbfinale';
      case 'Quarterfinal': return 'Viertelfinale';
      case 'Round of 16': return 'Achtelfinale';
      case 'Pool Play': return 'Vorrunde';
      default: return r;
    }
  }

  // Gender badge
  static String genderLabel(String gender) {
    if (gender == 'Men') return isEn ? 'Men' : 'Herren';
    if (gender == 'Women') return isEn ? 'Women' : 'Damen';
    return gender;
  }
}
