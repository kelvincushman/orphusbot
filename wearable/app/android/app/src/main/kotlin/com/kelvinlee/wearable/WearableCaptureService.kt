// Copyright (c) 2025-2026 Kelvin Lee. Licensed under MIT.
//
// WearableCaptureService — keeps the app out of Android's "cached" process
// state while the wearable is streaming.
//
// Why this exists, precisely. With the app backgrounded, ActivityManager killed
// the process with:
//
//     Killing 3713:com.kelvinlee.wearable.dev (adj 850):
//     excessive binder traffic during cached
//
// The wearable delivers BLE notifications at 100/sec and every one of them is
// binder traffic from the Bluetooth stack. Once the process drops to cached
// (oom_score_adj 850) that stream is itself the kill trigger — the harder the
// device works, the sooner it dies. The firmware then shows amber/blue
// alternating (habitat_ble_searching), which is what a wearer sees as
// "flashing". A foreground service is not cached, so the policy does not apply.
//
// Deliberately minimal: this runs in the app's own process and holds no state.
// It exists to change the process's importance, nothing else. The BLE work
// stays in the Dart isolate, which was already proven to survive backgrounding
// (11 minutes backgrounded and 8 minutes in Doze with frames unbroken at
// 102 fps) — the process was being killed, not suspended.
//
// Not flutter_foreground_task: that package exists to run a SEPARATE Dart
// isolate that outlives the app, which is a different problem and would mean
// refactoring a working bridge into its task-handler lifecycle.

package com.kelvinlee.wearable

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import androidx.core.app.NotificationCompat

class WearableCaptureService : Service() {

    companion object {
        const val ACTION_START = "com.kelvinlee.wearable.CAPTURE_START"
        const val ACTION_STOP = "com.kelvinlee.wearable.CAPTURE_STOP"

        private const val CHANNEL_ID = "wearable_capture"
        private const val NOTIFICATION_ID = 4711

        fun start(context: Context) {
            val intent = Intent(context, WearableCaptureService::class.java)
                .setAction(ACTION_START)
            // startForegroundService requires startForeground() within ~5s;
            // onStartCommand does it synchronously below.
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                context.startForegroundService(intent)
            } else {
                context.startService(intent)
            }
        }

        fun stop(context: Context) {
            context.startService(
                Intent(context, WearableCaptureService::class.java).setAction(ACTION_STOP)
            )
        }
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == ACTION_STOP) {
            stopForegroundCompat()
            stopSelf()
            return START_NOT_STICKY
        }

        createChannel()
        val notification = buildNotification()

        // API 29+ wants the type at startForeground too, and on API 34 it must
        // match the manifest's foregroundServiceType or the call throws.
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            startForeground(
                NOTIFICATION_ID,
                notification,
                ServiceInfo.FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE
            )
        } else {
            startForeground(NOTIFICATION_ID, notification)
        }

        // Not sticky: the Dart side owns the lifecycle and starts this when the
        // bridge attaches. A self-restarting service with no bridge behind it
        // would be a notification the wearer cannot explain or dismiss.
        return START_NOT_STICKY
    }

    private fun stopForegroundCompat() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
            stopForeground(STOP_FOREGROUND_REMOVE)
        } else {
            @Suppress("DEPRECATION")
            stopForeground(true)
        }
    }

    private fun createChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val channel = NotificationChannel(
            CHANNEL_ID,
            "Wearable capture",
            // LOW: visible and dismissible from the shade, but silent and with
            // no heads-up. The wearer needs to know capture is live, not to be
            // interrupted by it.
            NotificationManager.IMPORTANCE_LOW
        ).apply {
            description = "Shown while the wearable is connected and streaming audio."
            setShowBadge(false)
        }
        getSystemService(NotificationManager::class.java)
            ?.createNotificationChannel(channel)
    }

    private fun buildNotification(): Notification {
        val open = packageManager.getLaunchIntentForPackage(packageName)?.let {
            PendingIntent.getActivity(
                this,
                0,
                it,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
            )
        }

        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setContentTitle("Wearable connected")
            .setContentText("Listening — audio stays on this phone.")
            .setSmallIcon(android.R.drawable.stat_sys_data_bluetooth)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .setOngoing(true)
            .setShowWhen(false)
            .setContentIntent(open)
            .build()
    }
}
