/// Build-Varianten derselben App — EIN Codestand, zwei APKs.
///
/// Gesteuert per `--dart-define=VARIANT=neutral` beim Build:
///   flutter build apk --release                             → 'bvc'     (Standard)
///   flutter build apk --release --dart-define=VARIANT=neutral → 'neutral'
///
/// Bewusst KEIN Fork und KEIN eigener Branch: jede Funktionsaenderung soll
/// automatisch in beiden Builds landen. Der Laola1- und GBT-Code bleibt
/// deshalb vollstaendig im Build, die neutrale Variante schaltet ihn nur ab.
///
/// Die neutrale Variante ist fuer Tester ausserhalb des Vereins gedacht:
///   • nur VBTV-Inhalte, keine Source-Umschalter
///   • kein Vereins-Branding im Player-Overlay
/// App-Name und Icon (BVCTV) bleiben in beiden Varianten gleich.
class AppVariant {
  static const String _variant =
      String.fromEnvironment('VARIANT', defaultValue: 'bvc');

  /// Neutrale Test-Variante ohne Vereinsbezug.
  static bool get isNeutral => _variant == 'neutral';

  /// Nur VBTV als Quelle. Laola1/GBT werden nie geladen und die drei
  /// Source-Chips verschwinden aus der UI (es gaebe nichts zu schalten).
  static bool get vbtvOnly => isNeutral;

  /// Vereins-Logo + "Powered by" im Schwarzbild-Overlay der 2h-Videos.
  static bool get showClubBranding => !isNeutral;

  /// Dateiname-Praefix des Release-Assets, das der In-App-Updater ziehen
  /// darf. Beide Varianten haengen am selben GitHub-Release, duerfen sich
  /// aber NICHT gegenseitig ueberschreiben — sonst wuerde sich die neutrale
  /// Variante beim ersten Update in die gebrandete verwandeln.
  static String get updateAssetPrefix =>
      isNeutral ? 'bvctv-neutral-v' : 'bvctv-v';
}
