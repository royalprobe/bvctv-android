package com.example.vbtv_app

import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.SystemClock
import android.view.MotionEvent
import androidx.core.content.FileProvider
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "bvctv/touch")
            .setMethodCallHandler { call, result ->
                if (call.method == "tap") {
                    val lx = (call.argument<Double>("x") ?: 0.0).toFloat()
                    val ly = (call.argument<Double>("y") ?: 0.0).toFloat()
                    runOnUiThread {
                        val density = resources.displayMetrics.density
                        val px = lx * density
                        val py = ly * density
                        val t = SystemClock.uptimeMillis()
                        val down = MotionEvent.obtain(t, t,      MotionEvent.ACTION_DOWN, px, py, 0)
                        val up   = MotionEvent.obtain(t, t + 80, MotionEvent.ACTION_UP,   px, py, 0)
                        window.decorView.dispatchTouchEvent(down)
                        window.decorView.dispatchTouchEvent(up)
                        down.recycle()
                        up.recycle()
                    }
                    result.success(null)
                } else {
                    result.notImplemented()
                }
            }

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "bvctv/update")
            .setMethodCallHandler { call, result ->
                if (call.method == "installApk") {
                    val path = call.argument<String>("path")
                    if (path == null) { result.error("INVALID", "path required", null); return@setMethodCallHandler }
                    try {
                        val file = File(path)
                        val uri = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
                            FileProvider.getUriForFile(this, "${packageName}.fileprovider", file)
                        } else {
                            Uri.fromFile(file)
                        }
                        startActivity(
                            Intent(Intent.ACTION_VIEW).apply {
                                setDataAndType(uri, "application/vnd.android.package-archive")
                                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                            }
                        )
                        result.success(null)
                    } catch (e: Exception) {
                        result.error("INSTALL_ERROR", e.message, null)
                    }
                } else {
                    result.notImplemented()
                }
            }
    }
}
