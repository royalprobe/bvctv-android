// Anzeige im schwarzen Bereich des 2h-Modus.
//
// VBW-Highlights sind kuerzer als das Match, die Timeline laeuft aber bis
// zwei Stunden. Ist die echte Datei durch, bleibt die Restzeit als
// schwarzer Bereich — und statt ins Leere zu starren sieht man hier das
// Branding.
//
// Bewusst als gemeinsames Widget: dieselbe Ansicht wird von BEIDEN Playern
// gebraucht (webview_player_screen fuer VBW-Live und Laola, player_screen
// fuer den schnellen VBW-Weg und Laola). Zwei Abschriften waeren genau die
// Art Duplikat, das sich mit der Zeit auseinanderentwickelt.

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../app_variant.dart';
import '../l10n/strings.dart';

class EndSplash extends StatelessWidget {
  const EndSplash({super.key});

  @override
  Widget build(BuildContext context) {
    return Positioned.fill(
      child: Container(
        color: Colors.black,
        child: Center(
          child: AppVariant.showClubBranding
              // Vereins-Build: orange Kapsel mit "Powered by" + BVC-Logo.
              ? Container(
                  padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 28),
                  decoration: BoxDecoration(
                    color: Colors.orange,
                    borderRadius: BorderRadius.circular(1000),
                  ),
                  child: Column(mainAxisSize: MainAxisSize.min, children: [
                    const Text('Powered by',
                        style: TextStyle(
                            color: Colors.black54,
                            fontSize: 15,
                            letterSpacing: 2,
                            fontWeight: FontWeight.w500)),
                    const SizedBox(height: 20),
                    GestureDetector(
                      onTap: () => launchUrl(
                          Uri.parse('https://www.instagram.com/bvc_lustenau/'),
                          mode: LaunchMode.externalApplication),
                      child: Image.asset('assets/bvc_logo.png', width: 260),
                    ),
                  ]),
                )
              // Neutrale Variante: echter Kreis (BoxShape.circle, feste
              // Kantenlaenge) statt der Kapsel — die passt sich sonst dem
              // Inhalt an und wird zum Oval. Darin das App-Logo mit dem
              // Hinweis darunter. Bewusst die freigestellte Logo-Fassung:
              // bvctv_logo.png hat KEIN Alpha und wuerde als weisse Flaeche
              // auf dem Orange kleben.
              : Builder(builder: (ctx) {
                  final d = MediaQuery.of(ctx).size.shortestSide * 0.62;
                  return Container(
                    width: d,
                    height: d,
                    decoration: const BoxDecoration(
                      color: Colors.orange,
                      shape: BoxShape.circle,
                    ),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Image.asset('assets/bvctv_logo_transparent.png',
                            width: d * 0.5, height: d * 0.5, fit: BoxFit.contain),
                        SizedBox(height: d * 0.03),
                        Text(S.blackScreenHint,
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              color: Colors.black.withValues(alpha: 0.55),
                              fontSize: d * 0.062,
                              fontWeight: FontWeight.bold,
                            )),
                      ],
                    ),
                  );
                }),
        ),
      ),
    );
  }
}
