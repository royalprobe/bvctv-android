# BVCTV Web – Fire-TV-Huelle

Winzige Android-App (rund 700 KB), die nur die BVCTV-Web-App im Vollbild
laedt, damit sie auf dem Fire TV ein eigenes Symbol bekommt.

Bewusst **ohne Flutter und ohne jede Abhaengigkeit** — eine einzige
Vollbild-Ansicht braucht kein AppCompat, und der Flutter-Build waere mit
50 MB rund siebzigmal so gross.

## Bauen

    ./gradlew :app:assembleRelease
    # -> app/build/outputs/apk/release/app-release.apk

`local.properties` mit `sdk.dir=` anlegen (kommt nicht ins Repo). Gradle
braucht ausserdem ein 64-Bit-JDK; `gradle.properties` zeigt deshalb fest auf
das JDK von Android Studio, sonst greift es die alte 32-Bit-Laufzeit aus dem
PATH und scheitert beim Reservieren des Speichers.

## Installieren

    adb connect <ip>:5555
    adb -s <ip>:5555 install -r app/build/outputs/apk/release/app-release.apk

## Wissenswertes

- Eigene Paket-Kennung `at.bvclustenau.bvctvweb` — kollidiert **nicht** mit
  der nativen App (`com.example.vbtv_app`), beide koennen nebeneinander
  installiert sein.
- Geladen wird `…/?tv=1`. Der Zusatz schaltet in der Web-App die Bedienung
  per Steuerkreuz frei: ohne ihn sind die Kacheln nicht fokussierbar (sie
  sind `<div>` mit Klick-Handler) und mit der Fernbedienung unerreichbar.
- `LEANBACK_LAUNCHER` im Manifest, sonst taucht die App auf dem
  Fernseh-Startbildschirm nicht auf. Dazu `touchscreen required="false"`,
  sonst verweigert Fire OS die Installation.
- `mediaPlaybackRequiresUserGesture = false`, sonst startet kein Video: die
  WebView verlangt sonst eine Nutzergeste, und auf dem Fernseher gibt es
  keinen Zeiger, der als solche zaehlt.
- Zurueck-Taste blaettert im Verlauf der Web-App zurueck, statt die App
  sofort zu schliessen.
- **Eigene Mediensitzung (MediaSession)** — ohne sie bleiben Anhalten/Weiter
  und der Vorlauf wirkungslos. Fire OS liefert Medientasten nicht an die
  Vordergrund-App, sondern an die aktive Mediensitzung; ohne eigene landeten
  sie bei Amazons External-Media-Player-Dienst. Nachweis:
  `adb shell dumpsys media_session` zeigt jetzt
  `Media button session is at.bvclustenau.bvctvweb/BVCTV`.
  Die eigentliche Arbeit macht danach die WebView selbst — der Draht
  `window.bvctvFernbedienung` in player.js ist ein Rueckhalt, der derzeit
  nicht gebraucht wird.

- **Vor-/Ruecklauftaste steuern die Geschwindigkeit** (1x, 2x, 4x, 8x), nicht
  den Zeitsprung — Zeitspruenge macht das Steuerkreuz. Abgefangen wird in
  `dispatchKeyEvent`, nicht in `onKeyDown`: dort waere es zu spaet, die
  WebView hat die Tasten dann schon als Sprung verbraucht.
- Der Sitzungs-Rueckruf ist **absichtlich leer**. Ausgefuellt kam derselbe
  Druck ueber zwei Wege an — gemessen drei Zustellungen fuer EINEN Druck
  innerhalb von 700 ms, die Geschwindigkeit waere von 8x in einem Rutsch auf
  1x gefallen.

## Pruefen ohne Bildschirmfoto

`adb shell screencap` liefert bei laufendem Video ein **weisses** Bild — die
Videoflaeche laesst sich nicht abfotografieren (die WebView hat dafuer sogar
einen eigenen Schalter namens `awv-chrome-inspect-fix-white-video`). Ob
etwas laeuft, verraet stattdessen das Protokoll:

    adb shell dumpsys audio | grep "u/pid:<uid>/"      # state:started
    adb logcat -d | grep "resume detected\|seek found" # Pause / Sprung
    adb logcat -d -s BVCTVWeb:I                        # eigene Meldungen

Den echten Zustand der Seite liest man ueber die DevTools-Bruecke — dafuer
ist `WebView.setWebContentsDebuggingEnabled(true)` gesetzt:

    adb shell cat /proc/net/unix | grep -o webview_devtools_remote_[0-9]*
    adb forward tcp:9222 localabstract:webview_devtools_remote_<pid>
    curl -s http://localhost:9222/json      # WebSocket-Adresse der Seite

Danach per WebSocket `Runtime.evaluate` schicken, z. B. auf
`document.getElementById('video').playbackRate`. So wurde die Tempo-Leiter
nachgemessen (1 -> 2 -> 4 -> 8, Ruecklauf wieder hinunter, an beiden Enden
sauber begrenzt).

**Fuer den Alltag auf dem Fernseher bleibt die native App die bessere
Wahl** — nativer Player, feste 1080p, echte Fokussteuerung. Diese Huelle ist
zum Testen der Web-App am grossen Bildschirm gedacht.
