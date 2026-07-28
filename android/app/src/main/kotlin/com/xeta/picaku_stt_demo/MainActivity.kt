package com.xeta.picaku_stt_demo

import android.app.ActivityManager
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.os.BatteryManager
import android.os.Build
import android.os.PowerManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * Diagnostics bridge for the resource monitor.
 *
 * Only reports what Android will not hand an app through the filesystem:
 * thermal throttle state, battery draw, and the system's own memory view.
 * RAM/CPU/thread numbers come from /proc on the Dart side, no channel needed.
 *
 * Every value is optional: on an OS too old to provide one, the key is simply
 * absent and the Dart layer shows "Unavailable" rather than a wrong number.
 */
class MainActivity : FlutterActivity() {

    private companion object {
        const val CHANNEL = "picaku/diag"
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "read" -> result.success(readMetrics())
                    else -> result.notImplemented()
                }
            }
    }

    private fun readMetrics(): Map<String, Any?> {
        val out = HashMap<String, Any?>()

        // System memory view - more authoritative than parsing /proc/meminfo,
        // and lowMemory is Android's own "about to start killing things" flag.
        runCatching {
            val am = getSystemService(Context.ACTIVITY_SERVICE) as ActivityManager
            val info = ActivityManager.MemoryInfo()
            am.getMemoryInfo(info)
            out["totalMemMb"] = (info.totalMem / (1024 * 1024)).toInt()
            out["availMemMb"] = (info.availMem / (1024 * 1024)).toInt()
            out["lowMemory"] = info.lowMemory
        }

        // Thermal throttling: the metric that actually bounds session length.
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            runCatching {
                val pm = getSystemService(Context.POWER_SERVICE) as PowerManager
                out["thermalStatus"] = pm.currentThermalStatus
            }
        }

        runCatching {
            val bm = getSystemService(Context.BATTERY_SERVICE) as BatteryManager
            out["batteryPercent"] =
                bm.getIntProperty(BatteryManager.BATTERY_PROPERTY_CAPACITY)
            // Vendors disagree on sign; magnitude is the trustworthy part.
            out["batteryCurrentUa"] =
                bm.getLongProperty(BatteryManager.BATTERY_PROPERTY_CURRENT_NOW)
        }

        runCatching {
            val status = registerReceiver(
                null,
                IntentFilter(Intent.ACTION_BATTERY_CHANGED),
            )
            val tenths = status?.getIntExtra(BatteryManager.EXTRA_TEMPERATURE, -1) ?: -1
            if (tenths > 0) out["batteryTempC"] = tenths / 10.0
        }

        return out
    }
}
