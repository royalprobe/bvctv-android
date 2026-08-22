package at.bvclustenau.bvctvweb

import android.app.Activity
import android.app.AlertDialog
import android.content.Intent
import android.net.Uri
import android.os.Handler
import android.os.Looper
import android.util.Log
import androidx.core.content.FileProvider
import org.json.JSONObject
import java.io.File
import java.net.HttpURLConnection
import java.net.URL

/// Selbstaktualisierung der Fire-TV-Huelle.
///
/// Die App kommt nicht aus einem Store — wer sie sich einmal aufgespielt hat,
/// bliebe sonst fuer immer auf seinem Stand. Deshalb sieht sie selbst nach:
/// unter /tv-version.json steht, welche Fassung veroeffentlicht ist.
///
/// WICHTIG fuer das Startverhalten: das alles laeuft ERST, wenn die Seite
/// fertig geladen ist (siehe Aufruf in MainActivity), und dann in einem
/// eigenen Faden. Der Start der App und der Aufbau der Videouebersicht
/// werden dadurch nicht aufgehalten.
///
/// Installiert wird nichts im Stillen — das kann eine App ohne
/// Geraeteverwaltung auch gar nicht. Sie laedt das Paket herunter und
/// uebergibt es dem System, das dann fragt.
object Aktualisierung {

    private const val TAG = "BVCTVWeb"
    private const val STAND_URL = "https://www.bvc-lustenau.at/bvctv/tv-version.json"

    /// Einmal je App-Start. Ohne das fragt jeder Seitenwechsel erneut nach.
    private var schonGeprueft = false

    fun vielleichtPruefen(activity: Activity, verzoegerungMs: Long = 8_000) {
        if (schonGeprueft) return
        schonGeprueft = true
        Handler(Looper.getMainLooper()).postDelayed({ pruefen(activity) }, verzoegerungMs)
    }

    private fun pruefen(activity: Activity) {
        Thread {
            try {
                val text = holen(STAND_URL)
                val stand = JSONObject(text)
                val neuerCode = stand.optInt("versionCode", 0)
                val neuerName = stand.optString("versionName", "?")
                val eigenerCode = eigeneVersion(activity)
                Log.i(TAG, "Aktualisierung: installiert $eigenerCode, veroeffentlicht $neuerCode")
                if (neuerCode <= eigenerCode) return@Thread

                val datei = herunterladen(activity, stand.optString("url", "tv.apk"))
                Handler(Looper.getMainLooper()).post { anbieten(activity, datei, neuerName) }
            } catch (e: Exception) {
                // Eine fehlgeschlagene Pruefung darf nie stoeren — dann eben
                // beim naechsten Start.
                Log.i(TAG, "Aktualisierung nicht moeglich: ${e.message}")
            }
        }.start()
    }

    private fun eigeneVersion(activity: Activity): Int {
        val info = activity.packageManager.getPackageInfo(activity.packageName, 0)
        @Suppress("DEPRECATION")
        return info.versionCode
    }

    private fun holen(adresse: String): String {
        val verbindung = URL(adresse).openConnection() as HttpURLConnection
        verbindung.connectTimeout = 10_000
        verbindung.readTimeout = 10_000
        try {
            return verbindung.inputStream.bufferedReader().use { it.readText() }
        } finally {
            verbindung.disconnect()
        }
    }

    private fun herunterladen(activity: Activity, pfad: String): File {
        val adresse = if (pfad.startsWith("http")) pfad
        else "https://www.bvc-lustenau.at/bvctv/" + pfad.removePrefix("/")
        // In den Cache: das Paket wird nur einmal gebraucht, und das System
        // raeumt dort selbst auf, falls die Installation nie stattfindet.
        val ziel = File(activity.cacheDir, "bvctv-update.apk")
        val verbindung = URL(adresse).openConnection() as HttpURLConnection
        verbindung.connectTimeout = 15_000
        verbindung.readTimeout = 60_000
        try {
            verbindung.inputStream.use { herein ->
                ziel.outputStream().use { hinaus -> herein.copyTo(hinaus) }
            }
        } finally {
            verbindung.disconnect()
        }
        return ziel
    }

    private fun anbieten(activity: Activity, datei: File, neuerName: String) {
        if (activity.isFinishing) return
        AlertDialog.Builder(activity)
            .setTitle("Neue Fassung $neuerName")
            .setMessage("Jetzt aktualisieren? Die App wird dabei kurz beendet.")
            .setPositiveButton("Aktualisieren") { _, _ -> installieren(activity, datei) }
            // "Spaeter" zuerst und vorausgewaehlt: ein Druck ins Blaue soll
            // nicht mitten im Spiel die Installation starten.
            .setNegativeButton("Später") { d, _ -> d.dismiss() }
            .create()
            .apply { show(); getButton(AlertDialog.BUTTON_NEGATIVE)?.requestFocus() }
    }

    private fun installieren(activity: Activity, datei: File) {
        try {
            val uri: Uri = FileProvider.getUriForFile(
                activity,
                "${activity.packageName}.dateien",
                datei,
            )
            val absicht = Intent(Intent.ACTION_VIEW).apply {
                setDataAndType(uri, "application/vnd.android.package-archive")
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            }
            activity.startActivity(absicht)
        } catch (e: Exception) {
            Log.i(TAG, "Installation nicht moeglich: ${e.message}")
        }
    }
}
