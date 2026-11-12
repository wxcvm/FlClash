package com.follow.clash.service

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.content.Intent
import android.net.VpnService as SystemVpnService
import android.os.Binder
import android.os.IBinder
import android.os.ParcelFileDescriptor
import android.os.Process
import android.util.Log
import java.lang.reflect.InvocationTargetException
import java.util.concurrent.Callable
import java.util.concurrent.ExecutionException
import java.util.concurrent.LinkedBlockingQueue
import java.util.concurrent.ThreadPoolExecutor
import java.util.concurrent.TimeUnit

/**
 * Explicitly bound native VPN owner in :singbox. All lifecycle calls are
 * serialized off the main thread; no automatic system/always-on start.
 */
class SingBoxVpnService : SystemVpnService() {
    private var config: String? = null
    private var runtime: AutoCloseable? = null
    private var listener: ISingBoxVpnEvents? = null
    @Volatile private var owner: IBinder? = null
    private var death: IBinder.DeathRecipient? = null
    private var state = "idle"
    @Volatile private var destroyed = false

    private fun <T> serialized(block: () -> T): T {
        check(Binder.getCallingUid() == Process.myUid()) { "Foreign UID" }
        try {
            return worker.submit(Callable { block() }).get()
        } catch (failure: ExecutionException) {
            val error = failure.cause ?: failure
            val cause = if (error is InvocationTargetException) error.cause ?: error else error
            throw IllegalStateException(cause.message ?: cause.javaClass.simpleName)
        }
    }

    private val binder = object : ISingBoxVpn.Stub() {
        override fun prepare(config: ParcelFileDescriptor, events: ISingBoxVpnEvents): String =
            serialized {
                // Always consume and close the received descriptor, even when busy.
                val content = NativeConfigReader.read(config)
                check(!destroyed && state == "idle") { "Native VPN already owned" }
                val version = IsolatedLibbox.validateVpnConfig(this@SingBoxVpnService, content)
                val token = events.asBinder()
                val recipient = IBinder.DeathRecipient { requestStop("VPN controller disconnected", token) }
                token.linkToDeath(recipient, 0)
                owner = token
                listener = events
                death = recipient
                this@SingBoxVpnService.config = content
                state = "prepared"
                version
            }

        override fun state(owner: IBinder): String = serialized {
            if (this@SingBoxVpnService.owner == owner) state else "idle"
        }

        override fun startVpn(owner: IBinder): Unit = serialized {
            check(this@SingBoxVpnService.owner == owner) { "Native VPN lease is not owned" }
            check(!destroyed && state == "prepared") { "Native VPN is not prepared" }
            check(SystemVpnService.prepare(this@SingBoxVpnService) == null) { "Android VPN consent is required" }
            val content = requireNotNull(config)
            state = "starting"
            try {
                promote()
                val api = IsolatedLibbox.loadApi(this@SingBoxVpnService)
                val type = Class.forName(
                    "org.flclash.singboxprobe.isolated.AndroidVpnRuntime",
                    true,
                    api.classLoader,
                )
                val active = type.getConstructor(SystemVpnService::class.java, Runnable::class.java)
                    .newInstance(this@SingBoxVpnService, Runnable { requestStop("Native core requested stop", owner) })
                    as AutoCloseable
                runtime = active
                type.getMethod("start", String::class.java).invoke(active, content)
                config = null
                state = "running"
            } catch (error: Exception) {
                try {
                    stopOwned()
                } catch (cleanup: Exception) {
                    error.addSuppressed(cleanup)
                }
                throw error
            } catch (error: LinkageError) {
                try {
                    stopOwned()
                } catch (cleanup: Exception) {
                    error.addSuppressed(cleanup)
                }
                throw error
            }
        }

        override fun stopVpn(owner: IBinder): Unit = serialized {
            // A stale controller must never stop a replacement session.
            if (this@SingBoxVpnService.owner == owner) stopOwned()
        }
    }

    private fun promote() {
        val manager = getSystemService(NotificationManager::class.java)
        manager.createNotificationChannel(
            NotificationChannel(CHANNEL, "FlClash native VPN", NotificationManager.IMPORTANCE_LOW),
        )
        val notification = Notification.Builder(this, CHANNEL)
            .setContentTitle("FlClash · sing-box")
            .setContentText("Native VPN active")
            .setSmallIcon(android.R.drawable.ic_lock_lock)
            .setOngoing(true)
            .build()
        startForeground(NOTIFICATION_ID, notification)
    }

    private fun stopOwned() {
        val active = runtime
        if (active != null) {
            state = "stopping"
            try {
                active.close()
                runtime = null
            } catch (error: Exception) {
                state = "failed"
                throw error
            } catch (error: LinkageError) {
                state = "failed"
                throw error
            }
        }
        config = null
        val callback = listener
        val recipient = death
        listener = null
        death = null
        owner = null
        if (callback != null && recipient != null) {
            callback.asBinder().unlinkToDeath(recipient, 0)
        }
        state = "idle"
        stopForeground(STOP_FOREGROUND_REMOVE)
    }

    private fun requestStop(reason: String, token: IBinder? = owner) {
        worker.execute {
            if (token == null || owner != token) return@execute
            val callback = listener
            try {
                stopOwned()
                callback?.onStopped(reason)
            } catch (error: Exception) {
                Log.e(TAG, "Native VPN cleanup failed", error)
                callback?.let { runCatching { it.onStopped("Cleanup failed: ${error.message}") } }
            } catch (error: LinkageError) {
                Log.e(TAG, "Native VPN cleanup failed", error)
                callback?.let { runCatching { it.onStopped("Cleanup failed: ${error.message}") } }
            }
        }
    }

    override fun onBind(intent: Intent): IBinder? =
        if (intent.action == SystemVpnService.SERVICE_INTERFACE) super.onBind(intent) else binder

    override fun onUnbind(intent: Intent): Boolean {
        if (intent.action != SystemVpnService.SERVICE_INTERFACE) requestStop("VPN controller unbound")
        return false
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int = START_NOT_STICKY

    override fun onRevoke() {
        requestStop("Android VPN permission revoked")
    }

    override fun onDestroy() {
        destroyed = true
        requestStop("Native VPN service destroyed")
        super.onDestroy()
    }

    companion object {
        private const val TAG = "FlClashSingBox"
        private const val CHANNEL = "flclash-native-vpn"
        private const val NOTIFICATION_ID = 2
        private val worker = ThreadPoolExecutor(0, 1, 10, TimeUnit.SECONDS, LinkedBlockingQueue())
    }
}
