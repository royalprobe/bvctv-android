package com.example.vbtv_app

import android.os.SystemClock
import android.view.MotionEvent
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

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
    }
}
