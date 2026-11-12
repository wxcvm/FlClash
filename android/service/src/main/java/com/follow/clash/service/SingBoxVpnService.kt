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

/**
 * Optional, same-package VPN owner in :singbox. The UI must preflight, stop
 * Mihomo, then start this service; no implicit switch or always-on restoration.
 */
@RequiresApi(29)
class SingBoxVpnService : VpnService() {
    private val lifecycle = Any()
    @Volatile private var session: IsolatedSingBoxRuntime.Session? = null
    @Volatile private var running = false
    @Volatile private var destroyed = false
    @Volatile private var retiring = false
    private val lease = NativeConfigLease<IBinder>()
    private var ownerDeath: IBinder.DeathRecipient? = null
    private val main = Handler(Looper.getMainLooper())

    private val control = object : Binder() {
        override fun onTransact(code: Int, data: Parcel, reply: Parcel?, flags: Int): Boolean {
            if (code !in SingBoxVpnControl.VALIDATE..SingBoxVpnControl.STATUS_SNAPSHOT || reply == null) {
                return super.onTransact(code, data, reply, flags)
            }
            data.enforceInterface(SingBoxVpnControl.TOKEN)
            if (Binder.getCallingUid() != Process.myUid()) throw SecurityException("Private VPN control")
            try {
                if (code == SingBoxVpnControl.SNAPSHOT || code == SingBoxVpnControl.QUALITY_STATUS ||
                    code == SingBoxVpnControl.STATUS_SNAPSHOT) {
                    val snapshot = synchronized(lifecycle) {
                        check(running && !destroyed) { "sing-box VPN is not running" }
                        when (code) {
                            SingBoxVpnControl.SNAPSHOT -> requireNotNull(session).snapshot()
                            SingBoxVpnControl.STATUS_SNAPSHOT -> requireNotNull(session).statusSnapshot()
                            else -> requireNotNull(session).qualitySnapshot()
                        }
                    }
                    check(snapshot.length <= 220_000) { "Native snapshot exceeds Binder budget" }
                    reply.writeNoException()
                    reply.writeString(snapshot)
                    return true
                }
                val result = synchronized(lifecycle) {
                    if (retiring && code == SingBoxVpnControl.STOP) return@synchronized 0
                    check(!destroyed && !retiring && !processRetiring) { "VPN owner is retiring" }
                    when (code) {
                        SingBoxVpnControl.VALIDATE -> {
                            check(!running && session == null) { "Stop the active VPN before preflight" }
                            val token = requireNotNull(data.readStrongBinder())
                            if (lease.owner() == null) {
                                val recipient = IBinder.DeathRecipient { closeAsync() }
                                token.linkToDeath(recipient, 0)
                                ownerDeath = recipient
                            }
                            lease.claim(token)
                            lease.prepare(token, { readConfig(data) }) { config ->
                                IsolatedSingBoxRuntime.validate(this@SingBoxVpnService, config)
                            }
                            0
                        }
                        SingBoxVpnControl.START -> {
                            val config = lease.consume(requireNotNull(data.readStrongBinder()))
                            startLocked(config)
                            0
                        }
                        SingBoxVpnControl.STOP -> {
                            val token = data.readStrongBinder()
                            check(lease.canStop(token)) { "Invalid native VPN controller" }
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
            // Arm the process-exit watchdog before any potentially blocking JNI close.
            try {
                retireLocked()
            } catch (cleanup: Throwable) {
                if (cleanup !== error) error.addSuppressed(cleanup)
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
        check(android.app.Application.getProcessName() == "$packageName:singbox") { "Refusing to retire non-native process" }
        retiring = true
        processRetiring = true
        val token = lease.retire()
        val death = ownerDeath
        ownerDeath = null
        if (token != null && death != null) runCatching { token.unlinkToDeath(death, 0) }
        // Bound native cleanup: if JNI close stalls, the OS still releases its descriptors.
        main.postDelayed({ Process.killProcess(Process.myPid()) }, 3000)
        try {
            stopLocked()
        } catch (error: Throwable) {
            Log.e("FlClashSingBox", "Native cleanup failed; retiring isolated process", error)
        } finally {
            running = false
            main.postDelayed({ Process.killProcess(Process.myPid()) }, 100)
            stopForeground(STOP_FOREGROUND_REMOVE)
            stopSelf()
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
                if (!retiring && !processRetiring) promote(if (running) "sing-box VPN is running" else "Starting sing-box")
            }
            SingBoxVpnControl.STOP_ACTION -> {
                closeAsync()
            }
            else -> stopSelf(startId)
        }
        return START_NOT_STICKY
    }

    override fun onRevoke() {
        closeAsync()
    }

    private fun closeAsync() {
        if (cleanup.isShutdown) return
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
        if (!retiring && (running || session != null || lease.owner() != null)) closeAsync()
        cleanup.shutdown()
        super.onDestroy()
    }

    private val cleanup = java.util.concurrent.ThreadPoolExecutor(
        0, 1, 10, java.util.concurrent.TimeUnit.SECONDS,
        java.util.concurrent.LinkedBlockingQueue(),
    )

    private companion object {
        @Volatile private var processRetiring = false
        const val MAX_CONFIG_BYTES = 16 * 1024 * 1024
        const val CHANNEL = "flclash_singbox_vpn"
        const val NOTIFICATION_ID = 74
    }
}
