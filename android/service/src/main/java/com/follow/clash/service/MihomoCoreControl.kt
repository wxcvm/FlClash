package com.follow.clash.service

import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.ServiceConnection
import android.content.pm.PackageManager
import android.os.Binder
import android.os.IBinder
import android.os.DeadObjectException
import android.os.Looper
import android.os.Parcel
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicReference
import org.json.JSONObject

/** Private production Core client; connection and transactions run off the UI thread. */
class MihomoCoreControl private constructor(
    private val app: Context,
    private val connection: ServiceConnection,
    private val remote: IBinder,
    private val owner: IBinder,
    val pid: Int,
) : AutoCloseable {
    val alive: Boolean get() = remote.isBinderAlive
    private val bound = java.util.concurrent.atomic.AtomicBoolean(true)
    val connected: Boolean get() = bound.get()

    fun invoke(json: String, callback: (Result<ByteArray>) -> Unit) = command(INVOKE, json, callback)
    fun quickSetup(init: String, setup: String, callback: (Result<ByteArray>) -> Unit) =
        command(SETUP, JSONObject().put("init", init).put("setup", setup).toString(), callback)

    private fun command(code: Int, json: String, callback: (Result<ByteArray>) -> Unit) {
        val done = java.util.concurrent.atomic.AtomicBoolean()
        lateinit var death: IBinder.DeathRecipient
        val finish: (Result<ByteArray>) -> Unit = { result ->
            if (done.compareAndSet(false, true)) {
                runCatching { remote.unlinkToDeath(death, 0) }
                callback(result)
            }
        }
        death = IBinder.DeathRecipient { finish(Result.failure(IllegalStateException("Mihomo process died"))) }
        val receiver = CoreProbeCallback.receiver(finish)
        try {
            remote.linkToDeath(death, 0)
            val bytes = json.encodeToByteArray()
            if (CoreProbePayload.inline(bytes)) {
                transact(remote, owner, code, {
                    it.writeStrongBinder(receiver)
                    CoreProbePayload.writeInline(it, bytes)
                }) { Unit }
            } else CoreProbePayload.open(app, bytes).use { fd ->
                transact(remote, owner, code, {
                    it.writeStrongBinder(receiver)
                    CoreProbePayload.writeDescriptor(it, fd)
                }) { Unit }
            }
        } catch (error: Exception) {
            finish(Result.failure(error))
        }
    }

    fun setEvents(callback: ((ByteArray) -> Unit)?) {
        val receiver = callback?.let { handler ->
            CoreProbeCallback.receiver { it.onSuccess(handler) }
        }
        transact(remote, owner, EVENTS, { it.writeStrongBinder(receiver) }) { Unit }
    }

    fun setListener(running: Boolean) =
        transact(remote, owner, LISTENER, { it.writeInt(if (running) 1 else 0) }) { Unit }

    /** Retire only after the real VPN/proxy has stopped; confirm Binder death. */
    fun canSuspend(): Boolean = transact(remote, owner, CAN_SUSPEND) { it.readInt() != 0 }

    fun retire() {
        val dead = CountDownLatch(1)
        val recipient = IBinder.DeathRecipient { dead.countDown() }
        try {
            try {
                remote.linkToDeath(recipient, 0)
                transact(remote, owner, RETIRE) { Unit }
            } catch (_: DeadObjectException) {
                dead.countDown()
            }
            // Drop AUTO_CREATE before process death so Android cannot rebind it.
            close()
            check(dead.await(5, TimeUnit.SECONDS) || !remote.isBinderAlive) {
                "Mihomo process did not exit; native handoff blocked"
            }
        } finally {
            runCatching { remote.unlinkToDeath(recipient, 0) }
        }
    }

    override fun close() {
        if (bound.compareAndSet(true, false)) app.unbindService(connection)
    }

    companion object {
        internal const val TOKEN = "com.follow.clash.service.MihomoCore"
        internal const val ATTACH = IBinder.FIRST_CALL_TRANSACTION
        internal const val INVOKE = ATTACH + 1
        internal const val SETUP = ATTACH + 2
        internal const val EVENTS = ATTACH + 3
        internal const val LISTENER = ATTACH + 4
        internal const val RETIRE = ATTACH + 5
        internal const val CAN_SUSPEND = ATTACH + 6

        @Suppress("DEPRECATION")
        fun enabled(context: Context): Boolean = runCatching {
            context.packageManager.getServiceInfo(
                ComponentName(context, MihomoCoreService::class.java),
                PackageManager.MATCH_DISABLED_COMPONENTS,
            ).enabled
        }.getOrDefault(false)

        fun connect(context: Context): MihomoCoreControl {
            check(Looper.myLooper() != Looper.getMainLooper()) { "Use a background thread" }
            val app = context.applicationContext
            val ready = CountDownLatch(1)
            val binder = AtomicReference<IBinder>()
            val connection = object : ServiceConnection {
                override fun onServiceConnected(name: ComponentName, service: IBinder) {
                    binder.compareAndSet(null, service)
                    ready.countDown()
                }
                override fun onServiceDisconnected(name: ComponentName) { ready.countDown() }
                override fun onNullBinding(name: ComponentName) { ready.countDown() }
                override fun onBindingDied(name: ComponentName) { ready.countDown() }
            }
            check(app.bindService(Intent(app, MihomoCoreService::class.java), connection, Context.BIND_AUTO_CREATE)) {
                "Cannot bind isolated Mihomo Core"
            }
            try {
                check(ready.await(10, TimeUnit.SECONDS)) { "Mihomo Core bind timed out" }
                val remote = requireNotNull(binder.get()) { "Mihomo Core unavailable" }
                val owner = Binder()
                val pid = transact(remote, owner, ATTACH) { it.readInt() }
                check(pid != android.os.Process.myPid()) { "Mihomo Core must be isolated" }
                return MihomoCoreControl(app, connection, remote, owner, pid)
            } catch (error: Throwable) {
                app.unbindService(connection)
                throw error
            }
        }

        private fun <T> transact(
            remote: IBinder, owner: IBinder, code: Int,
            write: (Parcel) -> Unit = {}, read: (Parcel) -> T,
        ): T {
            val data = Parcel.obtain()
            val reply = Parcel.obtain()
            try {
                data.writeInterfaceToken(TOKEN)
                data.writeStrongBinder(owner)
                write(data)
                check(remote.transact(code, data, reply, 0)) { "Mihomo Core command rejected" }
                reply.readException()
                return read(reply)
            } finally {
                reply.recycle()
                data.recycle()
            }
        }
    }
}
