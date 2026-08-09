package at.bvclustenau.bvctvweb

import android.annotation.SuppressLint
import android.app.Activity
import android.media.session.MediaSession
import android.media.session.PlaybackState
import android.os.Build
import android.os.Bundle
import android.util.Log
import android.view.KeyEvent
import android.view.View
import android.view.WindowInsets
import android.view.WindowInsetsController
import android.webkit.ConsoleMessage
import android.webkit.WebChromeClient
import android.webkit.WebView
import android.webkit.WebViewClient

/// Vollbild-Huelle um die BVCTV-Web-App, damit sie auf dem Fire TV ein
/// eigenes Symbol bekommt.
///
/// Bewusst ohne AppCompat und ohne jede Abhaengigkeit: eine einzige
/// Vollbild-Ansicht braucht davon nichts, und das APK bleibt dadurch bei
/// wenigen hundert Kilobyte statt bei 50 MB wie der Flutter-Build.
///
/// Der Adresszusatz `?tv=1` schaltet in der Web-App die Bedienung per
/// Steuerkreuz frei. Ohne ihn waeren die Kacheln nicht erreichbar: sie sind
/// <div> mit Klick-Handler und damit nicht fokussierbar.
class MainActivity : Activity() {

    private lateinit var web: WebView
    private lateinit var sitzung: MediaSession

    @SuppressLint("SetJavaScriptEnabled")
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)

        web = WebView(this)
        setContentView(web)

        with(web.settings) {
            javaScriptEnabled = true
            // Die Web-App legt Filter und Einstellungen im localStorage ab.
            domStorageEnabled = true
            // Ohne das startet kein Video von selbst — die WebView verlangt
            // sonst eine Nutzergeste, und auf dem Fernseher gibt es keinen
            // Zeiger, der als solche zaehlt.
            mediaPlaybackRequiresUserGesture = false
            loadWithOverviewMode = true
            useWideViewPort = true
        }

        // Alles in der eigenen Ansicht halten statt an einen Browser
        // abzugeben — auf dem Fire Stick ist gar keiner installiert, ein
        // externer Aufruf liefe also ins Leere.
        web.webViewClient = WebViewClient()
        // Ohne WebChromeClient meldet die WebView kein Vollbild und keine
        // Fortschrittsanzeige an die Seite. Die Konsolenausgabe der Seite
        // landet zusaetzlich im Logcat — ohne das ist beim Suchen auf dem
        // Fernseher voellig blind, was die Seite gerade tut.
        web.webChromeClient = object : WebChromeClient() {
            override fun onConsoleMessage(m: ConsoleMessage): Boolean {
                Log.i(TAG, "seite: ${m.message()}")
                return true
            }
        }

        // Beim Suchen per adb hilfreich, sonst wirkungslos: erreichbar ist
        // das nur ueber ein USB-/Netzwerk-Debugging desselben Rechners.
        WebView.setWebContentsDebuggingEnabled(true)

        mediensitzungAnlegen()

        web.isFocusable = true
        web.isFocusableInTouchMode = true
        web.requestFocus()

        if (savedInstanceState == null) web.loadUrl(START_URL)
    }

    override fun onResume() {
        super.onResume()
        vollbild()
    }

    /// Systemleisten ausblenden. Auf dem Fernseher stoert jede Leiste, und
    /// bedienen liesse sie sich mit der Fernbedienung ohnehin nicht.
    private fun vollbild() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            window.setDecorFitsSystemWindows(false)
            window.insetsController?.let {
                it.hide(WindowInsets.Type.systemBars())
                it.systemBarsBehavior =
                    WindowInsetsController.BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE
            }
        } else {
            @Suppress("DEPRECATION")
            window.decorView.systemUiVisibility =
                View.SYSTEM_UI_FLAG_IMMERSIVE_STICKY or
                    View.SYSTEM_UI_FLAG_FULLSCREEN or
                    View.SYSTEM_UI_FLAG_HIDE_NAVIGATION or
                    View.SYSTEM_UI_FLAG_LAYOUT_STABLE or
                    View.SYSTEM_UI_FLAG_LAYOUT_FULLSCREEN or
                    View.SYSTEM_UI_FLAG_LAYOUT_HIDE_NAVIGATION
        }
    }

    /// Eigene Mediensitzung anmelden.
    ///
    /// DAS ist der Grund, warum die Medientasten vorher wirkungslos blieben:
    /// Fire OS liefert sie nicht an die Vordergrund-App, sondern an die
    /// aktive Mediensitzung. Ohne eigene Sitzung landeten Anhalten/Weiter und
    /// der Vorlauf bei Amazons External-Media-Player-Dienst — nachgemessen:
    /// onKeyDown wurde nie gerufen, die Tonausgabe blieb unveraendert auf
    /// "started".
    ///
    /// Die angemeldeten Aktionen sind Pflicht: was nicht in setActions steht,
    /// stellt das System gar nicht erst zu.
    private fun mediensitzungAnlegen() {
        sitzung = MediaSession(this, "BVCTV").apply {
            setCallback(object : MediaSession.Callback() {
                override fun onPlay() = anDieSeite("playpause")
                override fun onPause() = anDieSeite("playpause")
                override fun onFastForward() = anDieSeite("vor")
                override fun onRewind() = anDieSeite("zurueck")
                override fun onSkipToNext() = anDieSeite("vor")
                override fun onSkipToPrevious() = anDieSeite("zurueck")
                override fun onStop() = anDieSeite("stop")
            })
            setPlaybackState(
                PlaybackState.Builder()
                    .setActions(
                        PlaybackState.ACTION_PLAY or
                            PlaybackState.ACTION_PAUSE or
                            PlaybackState.ACTION_PLAY_PAUSE or
                            PlaybackState.ACTION_FAST_FORWARD or
                            PlaybackState.ACTION_REWIND or
                            PlaybackState.ACTION_SKIP_TO_NEXT or
                            PlaybackState.ACTION_SKIP_TO_PREVIOUS or
                            PlaybackState.ACTION_STOP,
                    )
                    // Dauerhaft "spielt" — der echte Zustand liegt in der
                    // Seite, und fuer die Zustellung der Tasten zaehlt nur,
                    // dass die Sitzung aktiv ist.
                    .setState(PlaybackState.STATE_PLAYING, 0L, 1f)
                    .build(),
            )
            isActive = true
        }
    }

    /// Befehl in die Seite reichen. Auf der Uebersicht gibt es die Funktion
    /// nicht — der Aufruf ist dort ein wirkungsloser Leerlauf.
    private fun anDieSeite(befehl: String) {
        Log.i(TAG, "fernbedienung: $befehl")
        web.evaluateJavascript(
            "window.bvctvFernbedienung && window.bvctvFernbedienung('$befehl')",
            null,
        )
    }

    override fun onKeyDown(keyCode: Int, event: KeyEvent): Boolean {
        // Medientasten selbst abfangen und der Seite durchreichen.
        //
        // Noetig, weil die WebView KEYCODE_MEDIA_* NICHT als KeyboardEvent an
        // die Seite weitergibt — Anhalten/Weiter und der Vorlauf blieben
        // dadurch wirkungslos. Die Pfeiltasten und OK kommen dagegen normal
        // an, die braucht es hier nicht.
        val befehl = when (keyCode) {
            KeyEvent.KEYCODE_MEDIA_PLAY_PAUSE,
            KeyEvent.KEYCODE_MEDIA_PLAY,
            KeyEvent.KEYCODE_MEDIA_PAUSE -> "playpause"

            KeyEvent.KEYCODE_MEDIA_FAST_FORWARD,
            KeyEvent.KEYCODE_MEDIA_NEXT -> "vor"

            KeyEvent.KEYCODE_MEDIA_REWIND,
            KeyEvent.KEYCODE_MEDIA_PREVIOUS -> "zurueck"

            KeyEvent.KEYCODE_MEDIA_STOP -> "stop"

            else -> null
        }
        if (befehl != null) {
            anDieSeite(befehl)
            return true
        }
        // Zurueck-Taste blaettert im Verlauf der Web-App (Player ->
        // Uebersicht), statt die App sofort zu schliessen. Erst am Anfang
        // des Verlaufs beendet sie.
        if (keyCode == KeyEvent.KEYCODE_BACK && web.canGoBack()) {
            web.goBack()
            return true
        }
        return super.onKeyDown(keyCode, event)
    }

    override fun onSaveInstanceState(outState: Bundle) {
        super.onSaveInstanceState(outState)
        web.saveState(outState)
    }

    override fun onRestoreInstanceState(savedInstanceState: Bundle) {
        super.onRestoreInstanceState(savedInstanceState)
        web.restoreState(savedInstanceState)
    }

    override fun onDestroy() {
        sitzung.isActive = false
        sitzung.release()
        web.destroy()
        super.onDestroy()
    }

    companion object {
        private const val TAG = "BVCTVWeb"
        private const val START_URL =
            "https://bvctv-web-production.up.railway.app/?tv=1"
    }
}
