// Copyright (c) 2025-2026 Kelvin Lee. Licensed under MIT.

package com.kelvinlee.wearable

import android.Manifest
import android.content.pm.PackageManager
import android.os.Build
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {

    private companion object {
        const val REQ_POST_NOTIFICATIONS = 8801
    }

    // Android 13+ hides the foreground-service notification unless
    // POST_NOTIFICATIONS is granted. The service still runs and still fixes the
    // cached-process kill, so this is not load-bearing for function -- but this
    // device records audio continuously, and a wearer is entitled to a visible
    // indicator that it is doing so. Ask once, at the moment capture starts,
    // which is the point at which the request makes sense to them.
    private fun ensureNotificationPermission() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) return
        if (checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS)
            == PackageManager.PERMISSION_GRANTED
        ) return
        // Fire and forget: the result changes only whether the notification is
        // visible, and the service is started either way, so there is nothing
        // to branch on in the callback.
        requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), REQ_POST_NOTIFICATIONS)
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        // Lets the Dart bridge raise the process out of "cached" for as long as
        // the wearable is attached. See WearableCaptureService for why.
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "wearable/capture_service"
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "start" -> {
                    // A failure here must not take the bridge down with it: the
                    // app still works foregrounded, it is only vulnerable to
                    // the cached-process kill. Report it and carry on.
                    try {
                        ensureNotificationPermission()
                        WearableCaptureService.start(applicationContext)
                        result.success(true)
                    } catch (e: Exception) {
                        result.error("START_FAILED", e.message, null)
                    }
                }
                "stop" -> {
                    try {
                        WearableCaptureService.stop(applicationContext)
                        result.success(true)
                    } catch (e: Exception) {
                        result.error("STOP_FAILED", e.message, null)
                    }
                }
                else -> result.notImplemented()
            }
        }
    }
}
