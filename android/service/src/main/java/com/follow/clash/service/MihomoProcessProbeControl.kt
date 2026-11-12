package com.follow.clash.service

import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.ServiceConnection
import android.os.Binder
import android.os.DeadObjectException
import android.os.IBinder
import android.os.Looper
import android.os.Parcel
import android.os.ParcelFileDescriptor
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicReference
import java.io.File
import org.json.JSONObject

/** Blocking diagnostic client: call only off the Android main thread. */
class MihomoProcessProbeControl private constructor(
    private val context: Context,
    private val connection: ServiceConnection,
    private val remote: IBinder,
    private val owner: IBinder,
    val pid: Int,
) : AutoCloseable {
    private var closed = false

    fun invoke(json: String): ByteArray = command(INVOKE, json)

    /** Uses the real QuickSetup bridge, with an isolated, listener-free fixture. */
    fun quickSetup(): String {
        val home = File(context.cacheDir, "mihomo-probe-home").apply { mkdirs() }
        val profile = File(home, "probe.yaml").apply { writeText(MihomoProcessProbeService.PROBE_CONFIG) }
        val init = JSONObject().put("home-dir", home.path).put("version", 1)
        val setup = JSONObject()
            .put("base", JSONObject().put("path", profile.path).put("overlay", ""))
            .put("selected-map", JSONObject())
            .put("options", JSONObject())
        return command(QUICK_SETUP, JSONObject().put("init", init).put("setup", setup).toString()).decodeToString()
    }

    fun setEventListener(listener: ((ByteArray) -> Unit)?) {
        check(!closed)
        val receiver = listener?.let { callback ->
            CoreProbeCallback.receiver { result -> result.onSuccess(callback) }
        }
        transact(remote, owner, EVENTS, { it.writeStrongBinder(receiver) }) { Unit }
    }

    private fun command(code: Int, json: String): ByteArray {
        check(!closed)
        val done = CountDownLatch(1)
        val result = AtomicReference<Result<ByteArray>>()
        val callback = CoreProbeCallback.receiver {
            if (result.compareAndSet(null, it)) done.countDown()
        }
        val death = IBinder.DeathRecipient {
            if (result.compareAndSet(null, Result.failure(IllegalStateException("Core process died")))) done.countDown()
        }
        remote.linkToDeath(death, 0)
        try {
            CoreProbePayload.open(context, json.encodeToByteArray()).use { input ->
                transact(remote, owner, code, {
                    it.writeStrongBinder(callback)
                    input.writeToParcel(it, 0)
                }) { Unit }
            }
            check(done.await(20, TimeUnit.SECONDS)) { "Core did not answer" }
            return requireNotNull(result.get()).getOrThrow()
        } finally {
            runCatching { remote.unlinkToDeath(death, 0) }
        }
    }

    override fun close() {
        if (closed) return
        closed = true
        val dead = CountDownLatch(1)
        val recipient = IBinder.DeathRecipient { dead.countDown() }
        try {
            try {
                remote.linkToDeath(recipient, 0)
                transact(remote, owner, STOP) { Unit }
            } catch (_: DeadObjectException) {
                dead.countDown()
            }
            check(dead.await(5, TimeUnit.SECONDS) || !remote.isBinderAlive) {
                "Mihomo probe process did not exit"
            }
        } finally {
            runCatching { remote.unlinkToDeath(recipient, 0) }
            context.unbindService(connection)
        }
    }

    companion object {
        internal const val TOKEN = "com.follow.clash.service.MihomoProcessProbe"
        internal const val ATTACH = IBinder.FIRST_CALL_TRANSACTION
        internal const val INVOKE = ATTACH + 1
        internal const val QUICK_SETUP = ATTACH + 2
        internal const val EVENTS = ATTACH + 3
        internal const val STOP = ATTACH + 4

        fun connect(context: Context): MihomoProcessProbeControl {
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
            check(app.bindService(Intent(app, MihomoProcessProbeService::class.java), connection, Context.BIND_AUTO_CREATE)) {
                "Enable the debug Mihomo process probe first"
            }
            try {
                check(ready.await(10, TimeUnit.SECONDS)) { "Mihomo process bind timed out" }
                val remote = requireNotNull(binder.get()) { "Mihomo process unavailable" }
                val owner = Binder()
                val pid = transact(remote, owner, ATTACH) { it.readInt() }
                return MihomoProcessProbeControl(app, connection, remote, owner, pid)
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
                check(remote.transact(code, data, reply, 0)) { "Mihomo probe command rejected" }
                reply.readException()
                return read(reply)
            } finally {
                reply.recycle()
                data.recycle()
            }
        }
    }
}
