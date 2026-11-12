package com.follow.clash

import com.follow.clash.common.GlobalState
import com.follow.clash.service.MihomoCoreControl
import org.json.JSONObject
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicReference

/** One connection for all Flutter and background setup operations. */
internal object MihomoCoreTransport {
    val isolated: Boolean by lazy { MihomoCoreControl.enabled(GlobalState.application) }
    private var client: MihomoCoreControl? = null
    private var events: ((ByteArray) -> Unit)? = null
    @Volatile private var suspendedForNative = false
    private var needsInit = false

    @Synchronized
    fun get(): MihomoCoreControl {
        check(!suspendedForNative) { "Mihomo is suspended while sing-box owns the VPN" }
        client?.takeIf { it.alive && it.connected }?.let { return it }
        check(client?.alive != true) { "Previous Mihomo process has not exited" }
        if (client != null) needsInit = true // Unexpected process loss also invalidates Go initialization.
        client?.close()
        client = null
        return MihomoCoreControl.connect(GlobalState.application).also {
            try {
                if (needsInit) {
                    // Reopen stopped-state profile operations without opening proxy listeners.
                    val done = CountDownLatch(1)
                    val response = AtomicReference<Result<ByteArray>>()
                    val args = JSONObject(ServiceStateMachine.initParams(
                        GlobalState.application.filesDir.path, android.os.Build.VERSION.SDK_INT,
                    ))
                    it.invoke(JSONObject().put("id", "android-reinit").put("method", "core.init")
                        .put("arguments", args).toString()) { value ->
                        response.set(value)
                        done.countDown()
                    }
                    check(done.await(20, TimeUnit.SECONDS)) { "Mihomo initialization timed out" }
                    val reply = JSONObject(requireNotNull(response.get()).getOrThrow().decodeToString())
                    check(reply.isNull("error")) { "Mihomo initialization failed: ${reply.opt("error")}" }
                    needsInit = false
                }
                it.setEvents(events)
                client = it
            } catch (error: Exception) {
                it.close()
                throw error
            }
        }
    }

    // Holding this monitor prevents a background RPC from opening another
    // connection between gate closure and death of the old Core.
    @Synchronized
    fun canSuspend(): Boolean = get().canSuspend()

    @Synchronized
    fun suspendForNative() {
        val old = get()
        suspendedForNative = true
        try {
            old.retire()
        } finally {
            if (!old.connected || !old.alive) needsInit = true
        }
        client = null
    }

    @Synchronized
    fun resumeAfterNative(): Boolean {
        // A failed retirement can leave an unbound but alive old owner.
        // Never reuse it for a new run until the process has exited.
        val old = client
        if (old != null && old.alive && !old.connected) return false
        if (suspendedForNative && old != null && !old.alive) {
            old.close()
            client = null
        }
        suspendedForNative = false
        return true
    }

    // UI status must not wait for the monitor held during process retirement.
    fun isSuspended(): Boolean = suspendedForNative

    @Synchronized
    fun invoke(data: String, callback: (Result<ByteArray>) -> Unit): Boolean {
        if (suspendedForNative) return false
        get().invoke(data, callback)
        return true
    }

    @Synchronized
    fun setEvents(callback: ((ByteArray) -> Unit)?) {
        events = callback
        if (suspendedForNative) return
        if (callback != null) get().setEvents(callback)
        else client?.takeIf { it.alive }?.setEvents(null)
    }

    @Synchronized
    fun stopListener() {
        client?.takeIf { it.alive }?.setListener(false)
    }
}
