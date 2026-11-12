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
import android.os.Handler
import android.os.Looper
import android.system.Os
import android.system.OsConstants
import java.io.ByteArrayOutputStream
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
    @Volatile private var running = false
    @Volatile private var destroyed = false
    @Volatile private var retiring = false
    private var preparedConfig: String? = null
    private val main = Handler(Looper.getMainLooper())

    private val control = object : Binder() {
        override fun onTransact(code: Int, data: Parcel, reply: Parcel?, flags: Int): Boolean {
            if (code !in SingBoxVpnControl.VALIDATE..SingBoxVpnControl.QUALITY_CANCEL || reply == null) {
                return super.onTransact(code, data, reply, flags)
            }
            data.enforceInterface(SingBoxVpnControl.TOKEN)
            if (Binder.getCallingUid() != Process.myUid()) throw SecurityException("Private VPN control")
            try {
                if (code == SingBoxVpnControl.SNAPSHOT || code == SingBoxVpnControl.QUALITY_STATUS) {
                    val snapshot = synchronized(lifecycle) {
                        check(running && !destroyed) { "sing-box VPN is not running" }
                        if (code == SingBoxVpnControl.SNAPSHOT) requireNotNull(session).snapshot()
                        else requireNotNull(session).qualitySnapshot()
                    }
                    check(snapshot.length <= 220_000) { "Native snapshot exceeds Binder budget" }
                    reply.writeNoException()
                    reply.writeString(snapshot)
                    return true
                }
                val result = synchronized(lifecycle) {
                    if (retiring && code == SingBoxVpnControl.STOP) return@synchronized 0
                    check(!destroyed && !retiring) { "VPN owner is retiring" }
                    when (code) {
                        SingBoxVpnControl.VALIDATE -> {
                            check(!running && session == null) { "Stop the active VPN before preflight" }
                            preparedConfig = null
                            val config = readConfig(data)
                            IsolatedSingBoxRuntime.validate(this@SingBoxVpnService, config)
                            preparedConfig = config
                            0
                        }
                        SingBoxVpnControl.START -> {
                            val config = requireNotNull(preparedConfig) { "Native VPN requires successful preflight" }
                            preparedConfig = null
                            startLocked(config)
                            0
                        }
                        SingBoxVpnControl.STOP -> {
                            retireLocked()
                            0
                        }
                        SingBoxVpnControl.RESET -> {
                            check(running) { "sing-box VPN is not running" }
                            session?.resetNetwork()
                            0
                        }
                        SingBoxVpnControl.SELECT -> {
                            check(running) { "sing-box VPN is not running" }
                            requireNotNull(session).selectOutbound(requireNotNull(data.readString()), requireNotNull(data.readString()), data.readLong())
                            0
                        }
                        SingBoxVpnControl.URL_TEST -> {
                            check(running) { "sing-box VPN is not running" }
                            requireNotNull(session).testOutbound(requireNotNull(data.readString()))
                            0
                        }
                        SingBoxVpnControl.QUALITY_START -> {
                            check(running) { "sing-box VPN is not running" }
                            requireNotNull(session).startQuality(requireNotNull(data.readString()))
                            0
                        }
                        SingBoxVpnControl.QUALITY_CANCEL -> {
                            session?.cancelQuality()
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

    private fun readConfig(data: Parcel): String {
        val descriptor = ParcelFileDescriptor.CREATOR.createFromParcel(data)
        return ParcelFileDescriptor.AutoCloseInputStream(descriptor).use { input ->
            val stat = Os.fstat(descriptor.fileDescriptor)
            require(OsConstants.S_ISREG(stat.st_mode) && stat.st_size in 0..MAX_CONFIG_BYTES.toLong()) {
                "Native config must be a regular file of at most 16 MiB"
            }
            val bytes = ByteArrayOutputStream()
            val buffer = ByteArray(16384)
            while (true) {
                val count = input.read(buffer)
                if (count < 0) break
                require(bytes.size() + count <= MAX_CONFIG_BYTES) { "Native config exceeds 16 MiB" }
                bytes.write(buffer, 0, count)
            }
            bytes.toString(Charsets.UTF_8.name())
        }
    }

    private fun startLocked(config: String) {
        check(Build.VERSION.SDK_INT >= 29 && SingBoxVpnControl.isAvailable(this)) { "sing-box is unavailable" }
        check(prepare(this) == null) { "Android VPN consent required" }
        check(session == null && !running) { "Native VPN already running" }
        try {
            promote("Starting sing-box")
            val next = IsolatedSingBoxRuntime.create(this)
            session = next
            next.start(config)
            running = true
            promote("sing-box VPN is running")
        } catch (error: Throwable) {
            try {
                stopLocked()
            } catch (cleanup: Throwable) {
                if (cleanup !== error) error.addSuppressed(cleanup)
            } finally {
                retireLocked()
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

    // Explicit stop is terminal for this process. Even if native cleanup fails,
    // process death closes every remaining descriptor and reclaims the Go heap.
    // The controller waits for Binder death before permitting another owner.
    private fun retireLocked() {
        if (retiring) return
        retiring = true
        preparedConfig = null
        try {
            stopLocked()
        } catch (error: Throwable) {
            Log.e("FlClashSingBox", "Native cleanup failed; retiring isolated process", error)
        } finally {
            running = false
            stopForeground(STOP_FOREGROUND_REMOVE)
            stopSelf()
            main.postDelayed({ Process.killProcess(Process.myPid()) }, 100)
        }
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
            SingBoxVpnControl.FOREGROUND -> {
                if (!retiring) promote(if (running) "sing-box VPN is running" else "Starting sing-box")
            }
            SingBoxVpnControl.STOP_ACTION -> {
                closeAsync()
                notifyVpnRevoked()
            }
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
                    retireLocked()
                } catch (error: Throwable) {
                    Log.e("FlClashSingBox", "VPN retirement failed", error)
                }
            }
        }
    }

    override fun onDestroy() {
        destroyed = true
        // A preflight-only unbind is explicitly retired by the controller.
        // Unexpected destruction of a live owner must also release its process.
        if (!retiring && (running || session != null)) closeAsync()
        cleanup.shutdown()
        super.onDestroy()
    }

    private val cleanup = Executors.newSingleThreadExecutor()

    private companion object {
        const val MAX_CONFIG_BYTES = 16 * 1024 * 1024
        const val CHANNEL = "flclash_singbox_vpn"
        const val NOTIFICATION_ID = 74
    }
}
