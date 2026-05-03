package com.yourpackage.update

import android.content.Context
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import org.json.JSONObject
import java.net.HttpURLConnection
import java.net.URL

data class UpdateInfo(
    val versionName: String,
    val changelog: String,
    val downloadUrl: String
)

object UpdateChecker {

    // ── Anpassen ──────────────────────────────────────────────────────────────
    private const val GITHUB_USERNAME = "royalprobe"
    private const val GITHUB_REPO     = "bvctv-android"
    // ──────────────────────────────────────────────────────────────────────────

    private const val API_URL =
        "https://api.github.com/repos/$GITHUB_USERNAME/$GITHUB_REPO/releases/latest"

    @Volatile private var sessionChecked = false

    /**
     * Nur einmal pro Session prüfen (für automatischen Hintergrund-Check).
     * Gibt UpdateInfo zurück wenn eine neuere Version verfügbar ist, sonst null.
     */
    suspend fun checkOncePerSession(context: Context): UpdateInfo? {
        if (sessionChecked) return null
        sessionChecked = true
        return check(context)
    }

    /** Voller Check ohne Session-Guard – für den manuellen Button in den Einstellungen. */
    suspend fun check(context: Context): UpdateInfo? = withContext(Dispatchers.IO) {
        try {
            val conn = (URL(API_URL).openConnection() as HttpURLConnection).apply {
                requestMethod = "GET"
                setRequestProperty("Accept", "application/vnd.github.v3+json")
                setRequestProperty("User-Agent", context.packageName)
                connectTimeout = 10_000
                readTimeout    = 10_000
            }

            if (conn.responseCode != 200) return@withContext null

            val json = JSONObject(conn.inputStream.bufferedReader().readText())
            conn.disconnect()

            val tagName        = json.getString("tag_name")        // z.B. "v1.2.3"
            val changelog      = json.optString("body", "")
            val remoteVersion  = tagName.trimStart('v')             // "1.2.3"

            val currentVersion = context.packageManager
                .getPackageInfo(context.packageName, 0)
                .versionName ?: return@withContext null

            if (!isNewer(remoteVersion, currentVersion)) return@withContext null

            // APK-Asset-URL suchen
            val assets      = json.optJSONArray("assets") ?: return@withContext null
            val downloadUrl = (0 until assets.length())
                .map { assets.getJSONObject(it) }
                .firstOrNull { it.getString("name").endsWith(".apk") }
                ?.getString("browser_download_url")
                ?: return@withContext null

            UpdateInfo(remoteVersion, changelog, downloadUrl)
        } catch (_: Exception) {
            null
        }
    }

    fun resetSessionFlag() { sessionChecked = false }

    /** Semantischer Versionsvergleich: "1.2.10" > "1.2.9" */
    private fun isNewer(remote: String, current: String): Boolean {
        fun parts(v: String) = v.split(".").map { it.toIntOrNull() ?: 0 }
        val r = parts(remote)
        val c = parts(current)
        for (i in 0 until maxOf(r.size, c.size)) {
            val diff = (r.getOrElse(i) { 0 }) - (c.getOrElse(i) { 0 })
            if (diff != 0) return diff > 0
        }
        return false
    }
}
