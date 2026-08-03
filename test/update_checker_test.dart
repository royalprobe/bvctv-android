import 'package:flutter_test/flutter_test.dart';
import 'package:vbtv_app/app_variant.dart';
import 'package:vbtv_app/services/update_checker.dart';

void main() {
  group('Versionsvergleich', () {
    test('erkennt neuere Patch-Versionen', () {
      expect(UpdateChecker.isNewer('1.0.147', '1.0.146'), isTrue);
      expect(UpdateChecker.isNewer('1.0.146', '1.0.147'), isFalse);
    });

    test('gleiche Version ist kein Update', () {
      expect(UpdateChecker.isNewer('1.0.146', '1.0.146'), isFalse);
    });

    /// Der Klassiker: als String verglichen waere "1.0.9" groesser als
    /// "1.0.10" und das Update wuerde nie angeboten.
    test('vergleicht numerisch, nicht alphabetisch', () {
      expect(UpdateChecker.isNewer('1.0.10', '1.0.9'), isTrue);
      expect(UpdateChecker.isNewer('1.0.9', '1.0.10'), isFalse);
      expect(UpdateChecker.isNewer('1.10.0', '1.9.0'), isTrue);
    });

    test('hoehere Stelle schlaegt niedrigere', () {
      expect(UpdateChecker.isNewer('2.0.0', '1.99.99'), isTrue);
      expect(UpdateChecker.isNewer('1.99.99', '2.0.0'), isFalse);
    });

    test('kommt mit unterschiedlich vielen Stellen klar', () {
      expect(UpdateChecker.isNewer('1.1', '1.0.5'), isTrue);
      expect(UpdateChecker.isNewer('1.0', '1.0.0'), isFalse);
      expect(UpdateChecker.isNewer('1.0.0.1', '1.0.0'), isTrue);
    });

    test('unlesbare Teile zaehlen als 0 statt zu werfen', () {
      expect(() => UpdateChecker.isNewer('1.0.x', '1.0.0'), returnsNormally);
      expect(UpdateChecker.isNewer('1.0.x', '1.0.1'), isFalse);
    });
  });

  /// Am GitHub-Release haengen die APKs BEIDER Varianten. Greift eine
  /// Variante zum falschen Asset, verwandelt sie sich beim Update in die
  /// andere — beim Tester also ploetzlich mit Vereins-Branding.
  group('Update-Asset pro Build-Variante', () {
    test('Praefixe ueberschneiden sich nicht', () {
      const branded = 'bvctv-v';
      const neutral = 'bvctv-neutral-v';
      expect('bvctv-neutral-v1.0.146.apk'.startsWith(branded), isFalse,
          reason: 'die gebrandete Variante darf das neutrale APK nicht ziehen');
      expect('bvctv-v1.0.146.apk'.startsWith(neutral), isFalse);
      expect('bvctv-v1.0.146.apk'.startsWith(branded), isTrue);
      expect('bvctv-neutral-v1.0.146.apk'.startsWith(neutral), isTrue);
    });

    test('der Default-Build zieht das gebrandete Asset', () {
      // Tests laufen ohne --dart-define, also in der bvc-Variante.
      expect(AppVariant.isNeutral, isFalse);
      expect(AppVariant.updateAssetPrefix, 'bvctv-v');
      expect(AppVariant.showClubBranding, isTrue);
      expect(AppVariant.vbtvOnly, isFalse);
    });
  });
}
