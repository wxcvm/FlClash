package com.follow.clash.service

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Intent
import android.net.VpnService
import android.os.Binder
import android.os.Build
import android.os.IBinder
import android.os.Parcel
import android.os.ParcelFileDescriptor
import android.os.Process
import android.util.Log
import androidx.annotation.RequiresApi
import java.util.concurrent.Executors

/**
 * Optional, same-package VPN owner in :singbox. The UI must preflight, stop
 * Mihomo, then start this service; no implicit switch or always-on restoration.
 */
@RequiresApi(29)
class SingBoxVpnService : VpnService() {
    private val lifecycle = Any()
    private var session: IsolatedSingBoxRuntime.Session? = null
    private var running = false
    @Volatile private var destroyed = false

    private val control = object : Binder() {
        override fun onTransact(code: Int, data: Parcel, reply: Parcel?, flags: Int): Boolean {
            if (code !in SingBoxVpnControl.VALIDATE..SingBoxVpnControl.RESET || reply == null) {
                return super.onTransact(code, data, reply, flags)
            }
            data.enforceInterface(SingBoxVpnControl.TOKEN)
            if (getCallingUid() != Process.myUid()) throw SecurityException("Private VPN control")
            try {
                val result = synchronized(lifecycle) {
                    check(!destroyed) { "VPN owner has been destroyed" }
                    when (code) {
                        SingBoxVpnControl.VALIDATE -> {
                            IsolatedSingBoxRuntime.validate(this@SingBoxVpnService, readConfig(data))
                            0
                        }
                        SingBoxVpnControl.START -> {
                            startLocked(readConfig(data))
                            0
                        }
                        SingBoxVpnControl.STOP -> {
                            stopLocked()
                            stopForeground(STOP_FOREGROUND_REMOVE)
                            stopSelf()
                            0
                        }
                        SingBoxVpnControl.RESET -> {
                            check(running) { "sing-box VPN is not running" }
                            session?.resetNetwork()
                            0
                        }
                        else -> if (running) 1 else 0
                    }
                }
                reply.writeNoException()
                reply.writeInt(result)
            } catch (error: Exception) {
                reply.writeException(IllegalStateException(error.message ?: "sing-box VPN command failed"))
            } catch (error: LinkageError) {
                reply.writeException(IllegalStateException(error.message ?: "sing-box JNI load failed"))
            }
            return true
        }
    }

    private fun readConfig(data: Parcel): String =
        ParcelFileDescriptor.AutoCloseInputStream(ParcelFileDescriptor.CREATOR.createFromParcel(data))
            .bufferedReader(Charsets.UTF_8).use { it.readText() }

    private fun startLocked(config: String) {
        check(Build.VERSION.SDK_INT >= 29 && SingBoxVpnControl.isAvailable(this)) { "sing-box is unavailable" }
        check(prepare(this) == null) { "Android VPN consent required" }
        IsolatedSingBoxRuntime.validate(this, config)
        stopLocked()
        promote("Starting sing-box")
        val next = IsolatedSingBoxRuntime.create(this)
        session = next
        try {
            next.start(config)
            running = true
            promote("sing-box VPN is running")
        } catch (error: Throwable) {
            try {
                stopLocked()
            } catch (cleanup: Throwable) {
                if (cleanup !== error) error.addSuppressed(cleanup)
            } finally {
                stopForeground(STOP_FOREGROUND_REMOVE)
                stopSelf()
            }
            throw error
        }
    }

    private fun stopLocked() {
        val active = session ?: return
        active.close()
        session = null
        running = false
    }

    private fun promote(message: String) {
        val manager = getSystemService(NotificationManager::class.java)
        manager.createNotificationChannel(NotificationChannel(CHANNEL, "FlClash sing-box VPN", NotificationManager.IMPORTANCE_LOW))
        val stop = PendingIntent.getService(
            this, 0, Intent(this, SingBoxVpnService::class.java).setAction(SingBoxVpnControl.STOP_ACTION),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
        startForeground(
            NOTIFICATION_ID,
            Notification.Builder(this, CHANNEL)
                .setSmallIcon(R.drawable.ic_service)
                .setContentTitle("FlClash")
                .setContentText(message)
                .setOngoing(true)
                .addAction(Notification.Action.Builder(null, "Stop", stop).build())
                .build(),
        )
    }

    override fun onBind(intent: Intent): IBinder? =
        if (intent.action == SingBoxVpnControl.BIND) control else super.onBind(intent)

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            SingBoxVpnControl.FOREGROUND -> promote("Starting sing-box")
            SingBoxVpnControl.STOP_ACTION -> closeAsync()
            else -> stopSelf(startId)
        }
        return START_NOT_STICKY
    }

    override fun onRevoke() {
        closeAsync()
        notifyVpnRevoked()
    }

    private fun closeAsync() {
        cleanup.execute {
            synchronized(lifecycle) {
                try {
                    stopLocked()
                } catch (error: Throwable) {
                    Log.e("FlClashSingBox", "VPN cleanup failed", error)
                } finally {
                    stopForeground(STOP_FOREGROUND_REMOVE)
                    stopSelf()
                }
            }
        }
    }

    override fun onDestroy() {
        destroyed = true
        closeAsync()
        cleanup.shutdown()
        super.onDestroy()
    }

    private val cleanup = Executors.newSingleThreadExecutor()

    private companion object {
        const val CHANNEL = "flclash_singbox_vpn"
        const val NOTIFICATION_ID = 74
    }
}
