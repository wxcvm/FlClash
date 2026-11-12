package com.follow.clash

import com.follow.clash.common.GlobalState
import com.follow.clash.service.MihomoCoreControl

/** One connection for all Flutter and background setup operations. */
internal object MihomoCoreTransport {
    val isolated: Boolean by lazy { MihomoCoreControl.enabled(GlobalState.application) }
    private var client: MihomoCoreControl? = null
    private var events: ((ByteArray) -> Unit)? = null
    private var suspendedForNative = false

    @Synchronized
    fun get(): MihomoCoreControl {
        check(!suspendedForNative) { "Mihomo is suspended while sing-box owns the VPN" }
        client?.takeIf { it.alive && it.connected }?.let { return it }
        check(client?.alive != true) { "Previous Mihomo process has not exited" }
        client?.close()
        client = null
        return MihomoCoreControl.connect(GlobalState.application).also {
            try {
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
        old.retire()
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

    @Synchronized
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
