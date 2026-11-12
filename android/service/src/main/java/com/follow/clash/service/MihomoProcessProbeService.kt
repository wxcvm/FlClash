package com.follow.clash.service

import android.app.Application
import android.app.Service
import android.content.Intent
import android.os.Binder
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.Parcel
import android.os.ParcelFileDescriptor
import android.os.Process
import com.follow.clash.core.Core
import org.json.JSONObject
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicReference

/**
 * Debug-only real JNI IPC probe. No VPN, listeners, config initialization or
 * arbitrary commands: production remains in the existing process for now.
 */
class MihomoProcessProbeService : Service() {
    private val lock = Any()
    private val main = Handler(Looper.getMainLooper())
    private var owner: IBinder? = null
    private var ownerDeath: IBinder.DeathRecipient? = null
    @Volatile private var retiring = false

    private val control = object : Binder() {
        override fun onTransact(code: Int, data: Parcel, reply: Parcel?, flags: Int): Boolean {
            if (code !in MihomoProcessProbeControl.ATTACH..MihomoProcessProbeControl.STOP || reply == null) {
                return super.onTransact(code, data, reply, flags)
            }
            data.enforceInterface(MihomoProcessProbeControl.TOKEN)
            if (Binder.getCallingUid() != Process.myUid()) throw SecurityException("Private core probe")
            try {
                val token = requireNotNull(data.readStrongBinder())
                synchronized(lock) {
                    check(!retiring) { "Core probe is retiring" }
                    when (code) {
                        MihomoProcessProbeControl.ATTACH -> {
                            check(Build.VERSION.SDK_INT >= 28 &&
                                Application.getProcessName() == "$packageName:mihomo_probe") {
                                "Core probe must run in its dedicated process"
                            }
                            check(owner == null || owner == token) { "Another probe owns the core" }
                            if (owner == null) {
                                val death = IBinder.DeathRecipient { retire() }
                                token.linkToDeath(death, 0)
                                owner = token
                                ownerDeath = death
                            }
                            Core.load()
                            reply.writeNoException()
                            reply.writeInt(Process.myPid())
                        }
                        MihomoProcessProbeControl.INVOKE -> {
                            check(owner == token) { "Invalid probe owner" }
                            val request = CoreProbePayload.read(
                                ParcelFileDescriptor.CREATOR.createFromParcel(data),
                            ).decodeToString()
                            // A real read-only Core response proves Go executed in this process.
                            val method = JSONObject(request).getString("method")
                            require(method in setOf("core.initialized", "core.memory")) {
                                "Probe only accepts read-only Core diagnostics"
                            }
                            val done = CountDownLatch(1)
                            val response = AtomicReference<ByteArray>()
                            Core.invokeMethod(request) { bytes ->
                                response.set(bytes ?: ByteArray(0))
                                done.countDown()
                            }
                            check(done.await(10, TimeUnit.SECONDS)) { "Core did not answer" }
                            CoreProbePayload.open(this@MihomoProcessProbeService, requireNotNull(response.get())).use {
                                reply.writeNoException()
                                it.writeToParcel(reply, 0)
                            }
                        }
                        MihomoProcessProbeControl.STOP -> {
                            check(owner == token) { "Invalid probe owner" }
                            retire()
                            reply.writeNoException()
                        }
                    }
                }
            } catch (error: Exception) {
                reply.writeException(IllegalStateException(error.message ?: "Core probe failed"))
            } catch (error: LinkageError) {
                reply.writeException(IllegalStateException("Mihomo JNI: ${error.message}"))
            }
            return true
        }
    }

    private fun retire() {
        // No native tunnel/listener is opened by this probe. The OS reclaims Go.
        if (Build.VERSION.SDK_INT < 28 || Application.getProcessName() != "$packageName:mihomo_probe") return
        synchronized(lock) {
            if (retiring) return
            retiring = true
            val token = owner
            val death = ownerDeath
            owner = null
            ownerDeath = null
            if (token != null && death != null) runCatching { token.unlinkToDeath(death, 0) }
            main.postDelayed({ Process.killProcess(Process.myPid()) }, 100)
            stopSelf()
        }
    }

    override fun onBind(intent: Intent): IBinder = control
    override fun onUnbind(intent: Intent): Boolean {
        retire()
        return false
    }

    override fun onDestroy() {
        retire()
        super.onDestroy()
    }
}
