package com.follow.clash

import com.follow.clash.common.GlobalState
import com.follow.clash.service.MihomoCoreControl

/** One connection for all Flutter and background setup operations. */
internal object MihomoCoreTransport {
    val isolated: Boolean by lazy { MihomoCoreControl.enabled(GlobalState.application) }
    private var client: MihomoCoreControl? = null
    private var events: ((ByteArray) -> Unit)? = null

    @Synchronized
    fun get(): MihomoCoreControl {
        client?.takeIf { it.alive }?.let { return it }
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

    @Synchronized
    fun setEvents(callback: ((ByteArray) -> Unit)?) {
        events = callback
        if (callback != null) get().setEvents(callback)
        else client?.takeIf { it.alive }?.setEvents(null)
    }

    @Synchronized
    fun stopListener() {
        client?.takeIf { it.alive }?.setListener(false)
    }
}
