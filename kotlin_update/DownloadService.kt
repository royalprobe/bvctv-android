package com.yourpackage.update

import android.app.Activity
import android.app.DownloadManager
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.provider.Settings
import androidx.core.content.FileProvider
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.io.File

object DownloadService {

    private const val APK_FILENAME = "update.apk"
    const val REQUEST_INSTALL_PERMISSION = 1001

    /**
     * Lädt die APK per DownloadManager herunter und startet danach den Installer.
     *
     * @param onProgress  Fortschritt 0–100
     * @param onComplete  Wird aufgerufen direkt bevor der Installer startet
     * @param onError     Fehlermeldung als String
     */
    fun downloadAndInstall(
        activity: Activity,
        info: UpdateInfo,
        scope: CoroutineScope,
        onProgress: (Int) -> Unit,
        onComplete: () -> Unit,
        onError: (String) -> Unit
    ) {
        // Android 8+: Erlaubnis für Installation aus unbekannten Quellen prüfen
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            if (!activity.packageManager.canRequestPackageInstalls()) {
                activity.startActivityForResult(
                    Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES).apply {
                        data = Uri.parse("package:${activity.packageName}")
                    },
                    REQUEST_INSTALL_PERMISSION
                )
                onError("Bitte 'Installation aus unbekannten Quellen' erlauben und erneut versuchen.")
                return
            }
        }

        val downloadDir = activity.getExternalFilesDir(Environment.DIRECTORY_DOWNLOADS)
            ?: run { onError("Kein externer Speicher verfügbar."); return }
        val apkFile = File(downloadDir, APK_FILENAME).also { if (it.exists()) it.delete() }

        val dm = activity.getSystemService(Context.DOWNLOAD_SERVICE) as DownloadManager
        val downloadId = dm.enqueue(
            DownloadManager.Request(Uri.parse(info.downloadUrl)).apply {
                setTitle("Update v${info.versionName}")
                setDescription("APK wird heruntergeladen…")
                setNotificationVisibility(DownloadManager.Request.VISIBILITY_VISIBLE)
                setDestinationUri(Uri.fromFile(apkFile))
                setMimeType("application/vnd.android.package-archive")
                allowScanningByMediaScanner()
            }
        )

        // BroadcastReceiver: feuert wenn Download abgeschlossen (oder fehlgeschlagen)
        val receiver = object : BroadcastReceiver() {
            override fun onReceive(ctx: Context, intent: Intent) {
                val id = intent.getLongExtra(DownloadManager.EXTRA_DOWNLOAD_ID, -1L)
                if (id != downloadId) return
                activity.unregisterReceiver(this)

                val cursor = dm.query(DownloadManager.Query().setFilterById(id))
                if (cursor.moveToFirst()) {
                    val statusCol = cursor.getColumnIndex(DownloadManager.COLUMN_STATUS)
                    val success   = statusCol >= 0 &&
                        cursor.getInt(statusCol) == DownloadManager.STATUS_SUCCESSFUL
                    cursor.close()
                    if (success) {
                        onComplete()
                        installApk(activity, apkFile)
                    } else {
                        onError("Download fehlgeschlagen.")
                    }
                } else {
                    cursor.close()
                    onError("Download-Status unbekannt.")
                }
            }
        }
        activity.registerReceiver(receiver, IntentFilter(DownloadManager.ACTION_DOWNLOAD_COMPLETE))

        // Fortschritts-Polling im Hintergrund (alle 500 ms)
        scope.launch(Dispatchers.IO) {
            var running = true
            while (running) {
                delay(500)
                val cursor = dm.query(DownloadManager.Query().setFilterById(downloadId))
                if (!cursor.moveToFirst()) { cursor.close(); continue }

                val statusCol     = cursor.getColumnIndex(DownloadManager.COLUMN_STATUS)
                val downloadedCol = cursor.getColumnIndex(DownloadManager.COLUMN_BYTES_DOWNLOADED_SO_FAR)
                val totalCol      = cursor.getColumnIndex(DownloadManager.COLUMN_TOTAL_SIZE_BYTES)

                if (statusCol >= 0 && downloadedCol >= 0 && totalCol >= 0) {
                    val status     = cursor.getInt(statusCol)
                    val downloaded = cursor.getLong(downloadedCol)
                    val total      = cursor.getLong(totalCol)
                    if (total > 0) {
                        val pct = ((downloaded * 100L) / total).toInt()
                        withContext(Dispatchers.Main) { onProgress(pct) }
                    }
                    running = status == DownloadManager.STATUS_RUNNING ||
                              status == DownloadManager.STATUS_PENDING  ||
                              status == DownloadManager.STATUS_PAUSED
                }
                cursor.close()
            }
        }
    }

    private fun installApk(context: Context, apkFile: File) {
        val uri = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
            FileProvider.getUriForFile(
                context,
                "${context.packageName}.fileprovider",
                apkFile
            )
        } else {
            Uri.fromFile(apkFile)
        }
        context.startActivity(
            Intent(Intent.ACTION_VIEW).apply {
                setDataAndType(uri, "application/vnd.android.package-archive")
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            }
        )
    }
}
