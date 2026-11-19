package dev.marquart.aos.terminal

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
import androidx.core.app.ServiceCompat
import androidx.core.content.ContextCompat
import dev.marquart.aos.MainActivity
import dev.marquart.aos.R

/**
 * Keeps aOS running while a terminal on the Mac is open (Android/README.md, "The terminal in the background"): a
 * foreground service of type specialUse with a quiet notification, "Terminal on <Mac>", connected or reconnecting,
 * kept on the Mac, with End Session and a tap that opens the terminal. While it runs, AppModel keeps the connection
 * when the app is in the background, so the terminal stays attached (the iPhone's Live Activity and location trick in
 * one; Android allows it). It never shows the terminal's content (the lock screen is for anyone).
 *
 * TerminalController starts it when a terminal opens (in the foreground, as Android requires) and stops it when the
 * terminals close or "Keep connected in the background" is switched off.
 */
class TerminalKeepAliveService : Service() {
    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val controller = TerminalController.get(this)
        when (intent?.action) {
            ACTION_END -> {
                intent.getStringExtra(TerminalController.EXTRA_MAC)?.let(controller::endTerminal)
                return START_NOT_STICKY
            }
            ACTION_STOP -> {
                stopNow()
                return START_NOT_STICKY
            }
        }
        val open = controller.openTerminals()
        if (open.isEmpty()) {
            stopNow()
            return START_NOT_STICKY
        }
        try {
            ServiceCompat.startForeground(this, NOTIFICATION_ID, notification(this, open),
                if (Build.VERSION.SDK_INT >= 34) ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE else 0)
            running = true
        } catch (_: Exception) {
            // Not allowed now (the app went to the background before the service came up): the 25 s grace applies.
            running = false
            controller.serviceStopped()
            stopSelf()
        }
        // Killed by the system: nothing to bring back by itself (the terminal attaches again when the app returns).
        return START_NOT_STICKY
    }

    private fun stopNow() {
        running = false
        TerminalController.get(this).serviceStopped()
        ServiceCompat.stopForeground(this, ServiceCompat.STOP_FOREGROUND_REMOVE)
        stopSelf()
    }

    override fun onDestroy() {
        running = false
        TerminalController.get(this).serviceStopped()
        super.onDestroy()
    }

    companion object {
        const val CHANNEL = "terminal"
        const val NOTIFICATION_ID = 7730
        const val ACTION_END = "dev.marquart.aos.terminal.END"
        const val ACTION_STOP = "dev.marquart.aos.terminal.STOP"

        @Volatile var running = false
            private set

        /** Starts the service (from the foreground); false if Android didn't let it. */
        fun start(context: Context, open: List<MacTerminal>): Boolean {
            ensureChannel(context)
            return try {
                ContextCompat.startForegroundService(context, Intent(context, TerminalKeepAliveService::class.java))
                running = true
                true
            } catch (_: Exception) {
                false
            }
        }

        /** A terminal's state or name changed: the notification follows. */
        fun update(context: Context, open: List<MacTerminal>) {
            if (!running) return
            val manager = context.getSystemService(NotificationManager::class.java) ?: return
            try {
                manager.notify(NOTIFICATION_ID, notification(context, open))
            } catch (_: SecurityException) {
            }
        }

        fun stop(context: Context) {
            if (!running) return
            running = false
            context.stopService(Intent(context, TerminalKeepAliveService::class.java))
        }

        private fun ensureChannel(context: Context) {
            val manager = context.getSystemService(NotificationManager::class.java) ?: return
            if (manager.getNotificationChannel(CHANNEL) != null) return
            manager.createNotificationChannel(NotificationChannel(CHANNEL, context.getString(R.string.term_channel_name),
                NotificationManager.IMPORTANCE_LOW).apply {
                description = context.getString(R.string.term_channel_description)
                setShowBadge(false)
                lockscreenVisibility = Notification.VISIBILITY_PUBLIC
            })
        }

        /** "Terminal on Max's MacBook", connected or reconnecting, kept on the Mac; End Session; a tap opens it. */
        fun notification(context: Context, open: List<MacTerminal>): Notification {
            ensureChannel(context)
            val terminal = open.firstOrNull { it.phase.value == MacTerminal.Phase.Connected } ?: open.first()
            val state = when (terminal.phase.value) {
                MacTerminal.Phase.Connected -> R.string.term_notification_connected
                MacTerminal.Phase.Reconnecting -> R.string.term_notification_reconnecting
                else -> R.string.term_notification_connecting
            }
            val flags = PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
            val tap = PendingIntent.getActivity(context, terminal.macId.hashCode(),
                Intent(context, MainActivity::class.java).setAction(TerminalController.ACTION_OPEN)
                    .putExtra(TerminalController.EXTRA_MAC, terminal.macId)
                    .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP), flags)
            val end = PendingIntent.getService(context, terminal.macId.hashCode() + 1,
                Intent(context, TerminalKeepAliveService::class.java).setAction(ACTION_END)
                    .putExtra(TerminalController.EXTRA_MAC, terminal.macId), flags)
            return NotificationCompat.Builder(context, CHANNEL)
                .setSmallIcon(android.R.drawable.ic_menu_manage)
                .setContentTitle(context.getString(R.string.term_notification_title, terminal.title.value))
                .setContentText(context.getString(state))
                .setOngoing(true)
                .setOnlyAlertOnce(true)
                .setSilent(true)
                .setCategory(NotificationCompat.CATEGORY_SERVICE)
                .setVisibility(NotificationCompat.VISIBILITY_PUBLIC)
                .setForegroundServiceBehavior(NotificationCompat.FOREGROUND_SERVICE_IMMEDIATE)
                .setContentIntent(tap)
                .setUsesChronometer(terminal.connectedSince.value != null)
                .apply { terminal.connectedSince.value?.let { setWhen(it).setShowWhen(true) } }
                .addAction(0, context.getString(R.string.term_notification_end), end)
                .build()
        }
    }
}
