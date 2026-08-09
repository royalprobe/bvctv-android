package at.bvclustenau.bvctvweb

import android.annotation.SuppressLint
import android.app.Activity
import android.os.Build
import android.os.Bundle
import android.view.KeyEvent
import android.view.View
import android.view.WindowInsets
import android.view.WindowInsetsController
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
        // Fortschrittsanzeige an die Seite.
        web.webChromeClient = WebChromeClient()

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

    /// Zurueck-Taste blaettert im Verlauf der Web-App (Player -> Uebersicht),
    /// statt die App sofort zu schliessen. Erst am Anfang des Verlaufs
    /// beendet sie.
    override fun onKeyDown(keyCode: Int, event: KeyEvent): Boolean {
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
        web.destroy()
        super.onDestroy()
    }

    companion object {
        private const val START_URL =
            "https://bvctv-web-production.up.railway.app/?tv=1"
    }
}
