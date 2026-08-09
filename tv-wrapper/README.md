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

**Fuer den Alltag auf dem Fernseher bleibt die native App die bessere
Wahl** — nativer Player, feste 1080p, echte Fokussteuerung. Diese Huelle ist
zum Testen der Web-App am grossen Bildschirm gedacht.
