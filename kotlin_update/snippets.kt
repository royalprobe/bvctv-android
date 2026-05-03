// ══════════════════════════════════════════════════════════════════════════════
//  SNIPPET 1 – Video-Übersichts-Fragment/Activity
//  Automatischer Update-Check NACH erfolgreichem Video-Laden
// ══════════════════════════════════════════════════════════════════════════════

/*
Füge diese Methoden in dein VideoListFragment (oder Activity) ein.
Voraussetzungen:
  - ViewBinding (binding.root)
  - lifecycleScope (aus androidx.lifecycle:lifecycle-runtime-ktx)
  - Material Components (com.google.android.material:material)
*/

import androidx.lifecycle.lifecycleScope
import com.google.android.material.snackbar.Snackbar
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

// ── In deiner loadVideos()-Methode, nach erfolgreichem Laden: ─────────────────

private fun loadVideos() {
    lifecycleScope.launch {
        try {
            val videos = videoRepository.fetchVideos()   // dein bestehender Code
            adapter.submitList(videos)

            // Erst wenn die Videos da sind → Update-Check im Hintergrund starten
            checkForUpdateOnce()
        } catch (e: Exception) {
            // Fehler-Handling wie bisher
        }
    }
}

// ── Update-Methoden: ──────────────────────────────────────────────────────────

private var updateSnackbarShown = false  // Snackbar nur einmal pro Session

private fun checkForUpdateOnce() {
    if (updateSnackbarShown) return
    lifecycleScope.launch(Dispatchers.IO) {
        val info = UpdateChecker.checkOncePerSession(requireContext()) ?: return@launch
        withContext(Dispatchers.Main) {
            if (!updateSnackbarShown) {
                updateSnackbarShown = true
                showUpdateSnackbar(info)
            }
        }
    }
}

private fun showUpdateSnackbar(info: UpdateInfo) {
    Snackbar.make(binding.root, "Update verfügbar – v${info.versionName}", Snackbar.LENGTH_INDEFINITE)
        .setAction("Jetzt installieren") {
            UpdateDialog.show(requireContext(), info) { confirmed ->
                startDownload(confirmed)
            }
        }
        .show()
}

private fun startDownload(info: UpdateInfo) {
    val progressDialog = UpdateDialog.showProgress(requireContext())
    DownloadService.downloadAndInstall(
        activity      = requireActivity(),
        info          = info,
        scope         = lifecycleScope,
        onProgress    = { pct ->
            UpdateDialog.updateProgress(progressDialog, pct)
        },
        onComplete    = {
            progressDialog.dismiss()
            // Installer startet automatisch danach
        },
        onError       = { msg ->
            progressDialog.dismiss()
            Snackbar.make(binding.root, msg, Snackbar.LENGTH_LONG).show()
        }
    )
}

// ── REQUEST_INSTALL_PACKAGES Result behandeln (in der Activity): ──────────────

override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
    super.onActivityResult(requestCode, resultCode, data)
    if (requestCode == DownloadService.REQUEST_INSTALL_PERMISSION) {
        // User hat (oder hat nicht) die Erlaubnis erteilt → erneut versuchen
        // Hole updateInfo aus einem gespeicherten State oder zeige Dialog nochmal
    }
}




// ══════════════════════════════════════════════════════════════════════════════
//  SNIPPET 2 – Einstellungs-Activity/Fragment
//  Manueller "Nach Updates suchen"-Button
// ══════════════════════════════════════════════════════════════════════════════

/*
Füge dies in deine SettingsActivity oder dein SettingsFragment ein.
binding.btnCheckUpdate → dein Button in der Layout-XML
*/

private fun setupUpdateButton() {
    binding.btnCheckUpdate.setOnClickListener {
        binding.btnCheckUpdate.isEnabled = false
        binding.btnCheckUpdate.text = "Suche…"

        lifecycleScope.launch {
            val info = withContext(Dispatchers.IO) {
                UpdateChecker.check(requireContext())   // kein Session-Guard
            }

            binding.btnCheckUpdate.isEnabled = true
            binding.btnCheckUpdate.text = "Nach Updates suchen"

            if (info != null) {
                UpdateDialog.show(requireContext(), info) { confirmed ->
                    startDownload(confirmed)
                }
            } else {
                Snackbar.make(
                    binding.root,
                    "Du verwendest bereits die neueste Version.",
                    Snackbar.LENGTH_SHORT
                ).show()
            }
        }
    }
}

private fun startDownload(info: UpdateInfo) {
    val progressDialog = UpdateDialog.showProgress(requireContext())
    DownloadService.downloadAndInstall(
        activity   = requireActivity(),
        info       = info,
        scope      = lifecycleScope,
        onProgress = { pct -> UpdateDialog.updateProgress(progressDialog, pct) },
        onComplete = { progressDialog.dismiss() },
        onError    = { msg ->
            progressDialog.dismiss()
            Snackbar.make(binding.root, msg, Snackbar.LENGTH_LONG).show()
        }
    )
}
