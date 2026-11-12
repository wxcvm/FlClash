package com.follow.clash.service

import org.junit.Assert.assertEquals
import org.junit.Assert.assertSame
import org.junit.Assert.assertThrows
import org.junit.Test

class TunnelSessionTest {
    private fun request(fd: Int = 7) = TunnelRequest(
        fd = fd,
        protect = { true },
        resolveUid = { _, _, _ -> -1 },
        resolvePackage = { "" },
        stack = "system",
        address = "198.18.0.1/30",
        dns = "198.18.0.2",
        options = "{}",
    )

    private class FakeEngine : TunnelEngine {
        val events = mutableListOf<String>()
        var accepted = true
        var failure: IllegalStateException? = null
        var lastRequest: TunnelRequest? = null

        override fun start(request: TunnelRequest): Boolean {
            lastRequest = request
            events.add("start:${request.fd}")
            failure?.let { throw it }
            return accepted
        }

        override fun stop() {
            events.add("stop")
        }
    }

    @Test
    fun startPassesDescriptorAndCallbacksAndStopIsIdempotent() {
        val engine = FakeEngine()
        val session = TunnelSession(engine)
        val request = request()
        session.start(request)
        assertSame(request, engine.lastRequest)
        session.stop()
        session.stop()
        assertEquals(listOf("start:7", "stop"), engine.events)
    }

    @Test
    fun rejectedStartCleansUpAndAllowsRetry() {
        val engine = FakeEngine().apply { accepted = false }
        val session = TunnelSession(engine)
        assertThrows(IllegalStateException::class.java) { session.start(request()) }
        session.stop()
        engine.accepted = true
        session.start(request(8))
        session.stop()
        assertEquals(listOf("start:7", "stop", "start:8", "stop"), engine.events)
    }

    @Test
    fun throwingStartAlsoCleansUp() {
        val failure = IllegalStateException("start failed")
        val engine = FakeEngine().apply { this.failure = failure }
        val session = TunnelSession(engine)
        assertSame(failure, assertThrows(IllegalStateException::class.java) {
            session.start(request())
        })
        session.stop()
        assertEquals(listOf("start:7", "stop"), engine.events)
    }

    @Test
    fun sameEngineReplacementPreservesExistingStartSemantics() {
        val engine = FakeEngine()
        val session = TunnelSession(engine)
        session.start(request())
        session.start(request(8))
        session.stop()
        assertEquals(listOf("start:7", "start:8", "stop"), engine.events)
    }
}
