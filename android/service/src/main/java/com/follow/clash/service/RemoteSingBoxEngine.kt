package com.follow.clash.service

import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.ServiceConnection
import android.os.DeadObjectException
import android.os.IBinder
import android.os.ParcelFileDescriptor
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeout
import java.io.File
import java.util.concurrent.atomic.AtomicBoolean

/** A prepared, bound native engine for TunnelSession's callback-owned handoff. */
internal class RemoteSingBoxEngine private constructor(
    private val app: Context,
    private val connection: ServiceConnection,
    private val remote: ISingBoxVpn,
    private val owner: IBinder,
    override val version: String,
    private val disconnected: AtomicBoolean,
) : CallbackTunnelEngine, NativeVpnSession {
    private val released = AtomicBoolean()

    override fun validate() {
        check(!released.get() && !disconnected.get() && remote.state(owner) == "prepared") {
            "Native VPN preflight is no longer valid"
        }
    }

    override fun start() {
        check(!released.get() && !disconnected.get()) { "Native VPN disconnected" }
        remote.startVpn(owner)
        check(remote.state() == "running") { "Native VPN failed to start" }
    }

    override fun stop() {
        if (released.get()) return
        try {
            remote.stopVpn(owner)
        } catch (_: DeadObjectException) {
            // Process death closes its native descriptors; no old owner remains.
        }
        if (released.compareAndSet(false, true)) app.unbindService(connection)
    }

    companion object {
        /** Call from a user-initiated flow; keep the lease until stop or failed handoff. */
        suspend fun prepare(
            context: Context,
            config: File,
            onUnexpectedStop: (String) -> Unit,
        ): RemoteSingBoxEngine = withContext(Dispatchers.IO) {
            val app = context.applicationContext
            check(IsolatedLibbox.isAvailable(app)) { "Optional sing-box payload unavailable" }
            val connected = CompletableDeferred<ISingBoxVpn>()
            val disconnected = AtomicBoolean()
            val events = object : ISingBoxVpnEvents.Stub() {
                override fun onStopped(reason: String) {
                    if (disconnected.compareAndSet(false, true)) onUnexpectedStop(reason)
                }
            }
            val connection = object : ServiceConnection {
                override fun onServiceConnected(name: ComponentName, binder: IBinder) {
                    connected.complete(ISingBoxVpn.Stub.asInterface(binder))
                }

                private fun lost(reason: String) {
                    connected.completeExceptionally(IllegalStateException(reason))
                    if (disconnected.compareAndSet(false, true)) onUnexpectedStop(reason)
                }

                override fun onServiceDisconnected(name: ComponentName) = lost("Native VPN process disconnected")
                override fun onBindingDied(name: ComponentName) = lost("Native VPN binding died")
                override fun onNullBinding(name: ComponentName) = lost("Native VPN rejected binding")
            }
            check(app.bindService(Intent(app, SingBoxVpnService::class.java), connection, Context.BIND_AUTO_CREATE)) {
                "Cannot bind native VPN service"
            }
            try {
                val remote = withTimeout(10000) { connected.await() }
                val version = ParcelFileDescriptor.open(config, ParcelFileDescriptor.MODE_READ_ONLY).use {
                    remote.prepare(it, events)
                }
                RemoteSingBoxEngine(app, connection, remote, events.asBinder(), version, disconnected)
            } catch (error: Throwable) {
                app.unbindService(connection)
                throw error
            }
        }
    }
}
