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
import java.io.File
import java.util.concurrent.atomic.AtomicBoolean

/**
 * Debug-only real JNI IPC transport. No VPN or proxy listeners are started.
 * Setup is restricted to the probe's own private home; production stays unchanged.
 */
class MihomoProcessProbeService : Service() {
    private val lock = Any()
    private val main = Handler(Looper.getMainLooper())
    private var owner: IBinder? = null
    private var ownerDeath: IBinder.DeathRecipient? = null
    @Volatile private var eventReceiver: IBinder? = null
    private val commandActive = AtomicBoolean()
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
                            val callback = requireNotNull(data.readStrongBinder())
                            val request = readPayload(data)
                            val method = JSONObject(request).getString("method")
                            require(method in setOf("core.initialized", "core.memory", "log.start", "log.stop")) {
                                "Probe only accepts diagnostics and log subscription commands"
                            }
                            submit(callback) { deliver ->
                                Core.invokeMethod(request) { bytes -> deliver(bytes ?: ByteArray(0)) }
                            }
                            reply.writeNoException()
                        }
                        MihomoProcessProbeControl.QUICK_SETUP -> {
                            check(owner == token) { "Invalid probe owner" }
                            val callback = requireNotNull(data.readStrongBinder())
                            val payload = JSONObject(readPayload(data))
                            val init = payload.getJSONObject("init")
                            val setup = payload.getJSONObject("setup")
                            // Restrict the test home and profile to a generated private fixture.
                            val home = File(cacheDir, "mihomo-probe-home").canonicalFile
                            require(File(init.getString("home-dir")).canonicalFile == home)
                            val base = setup.getJSONObject("base")
                            require(File(base.getString("path")).canonicalFile == File(home, "probe.yaml"))
                            require(base.optString("overlay") == "")
                            require(File(home, "probe.yaml").readText() == PROBE_CONFIG)
                            submit(callback) { deliver ->
                                Core.quickSetup(init.toString(), setup.toString()) {
                                    deliver(it.orEmpty().encodeToByteArray())
                                }
                            }
                            reply.writeNoException()
                        }
                        MihomoProcessProbeControl.EVENTS -> {
                            check(owner == token) { "Invalid probe owner" }
                            val next = data.readStrongBinder()
                            eventReceiver = next
                            Core.updateEventListener(next?.let { receiver ->
                                { bytes: ByteArray ->
                                    if (!retiring && eventReceiver == receiver) {
                                        runCatching {
                                            CoreProbeCallback.send(this@MihomoProcessProbeService, receiver, Result.success(bytes))
                                        }
                                    }
                                }
                            })
                            reply.writeNoException()
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

    private fun readPayload(data: Parcel): String =
        CoreProbePayload.read(ParcelFileDescriptor.CREATOR.createFromParcel(data)).decodeToString()

    private fun submit(callback: IBinder, start: ((ByteArray) -> Unit) -> Unit) {
        check(commandActive.compareAndSet(false, true)) { "Core probe command already in flight" }
        val completed = AtomicBoolean()
        try {
            start { bytes ->
                if (completed.compareAndSet(false, true)) {
                    // Release before notifying the caller: it may immediately issue
                    // the next command when the one-way callback arrives.
                    commandActive.set(false)
                    if (!retiring) runCatching {
                        CoreProbeCallback.send(this, callback, Result.success(bytes))
                    }
                }
            }
        } catch (error: Throwable) {
            commandActive.set(false)
            throw error
        }
    }

    private fun retire() {
        // No native tunnel/listener is opened by this probe. The OS reclaims Go.
        if (Build.VERSION.SDK_INT < 28 || Application.getProcessName() != "$packageName:mihomo_probe") return
        synchronized(lock) {
            if (retiring) return
            retiring = true
            eventReceiver = null
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

    companion object {
        internal const val PROBE_CONFIG = "mixed-port: 0\\nport: 0\\nsocks-port: 0\\nmode: rule\\nlog-level: info\\ndns:\\n  enable: false\\ntun:\\n  enable: false\\nproxies: []\\nproxy-groups: []\\nrules:\\n  - MATCH,DIRECT\\n"
    }
    override fun onUnbind(intent: Intent): Boolean {
        retire()
        return false
    }

    override fun onDestroy() {
        retire()
        super.onDestroy()
    }
}
