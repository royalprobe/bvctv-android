package com.yourpackage.update

import android.app.AlertDialog
import android.content.Context
import android.view.LayoutInflater
import android.widget.ProgressBar
import android.widget.TextView

object UpdateDialog {

    /**
     * Dialog mit Changelog für manuellen Check in den Einstellungen.
     * onDownload wird aufgerufen wenn der User "Jetzt aktualisieren" klickt.
     */
    fun show(context: Context, info: UpdateInfo, onDownload: (UpdateInfo) -> Unit) {
        val scrollView  = android.widget.ScrollView(context)
        val textView = TextView(context).apply {
            text    = info.changelog.ifBlank { "Keine Changelog-Informationen verfügbar." }
            setPadding(48, 24, 48, 16)
            setTextColor(0xFF333333.toInt())
            textSize = 14f
        }
        scrollView.addView(textView)

        AlertDialog.Builder(context)
            .setTitle("Update verfügbar  ·  v${info.versionName}")
            .setView(scrollView)
            .setPositiveButton("Jetzt aktualisieren") { _, _ -> onDownload(info) }
            .setNegativeButton("Abbrechen", null)
            .show()
    }

    /**
     * Fortschrittsdialog während des Downloads.
     * Gibt das Dialog-Objekt zurück damit der Aufrufer es schließen kann.
     */
    fun showProgress(context: Context): AlertDialog {
        val layout = android.widget.LinearLayout(context).apply {
            orientation = android.widget.LinearLayout.VERTICAL
            setPadding(48, 32, 48, 8)
        }
        val progressBar = ProgressBar(context, null, android.R.attr.progressBarStyleHorizontal).apply {
            max = 100
            isIndeterminate = false
            id = android.R.id.progress
        }
        val label = TextView(context).apply {
            text = "0 %"
            setPadding(0, 12, 0, 0)
            textSize = 13f
            id = android.R.id.text1
        }
        layout.addView(progressBar)
        layout.addView(label)

        return AlertDialog.Builder(context)
            .setTitle("APK wird heruntergeladen…")
            .setView(layout)
            .setCancelable(false)
            .show()
    }

    /** Aktualisiert Fortschrittsanzeige im Dialog. */
    fun updateProgress(dialog: AlertDialog, percent: Int) {
        dialog.findViewById<ProgressBar>(android.R.id.progress)?.progress = percent
        dialog.findViewById<TextView>(android.R.id.text1)?.text = "$percent %"
    }
}
