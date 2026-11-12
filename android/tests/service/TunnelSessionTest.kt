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
        var stopFailure: IllegalStateException? = null
        var lastRequest: TunnelRequest? = null

        override fun start(request: TunnelRequest): Boolean {
            lastRequest = request
            events.add("start:${request.fd}")
            failure?.let { throw it }
            return accepted
        }

        override fun stop() {
            events.add("stop")
            stopFailure?.let { throw it }
        }
    }

    @Test
    fun startPassesDescriptorAndCallbacksAndStopIsIdempotent() {
        val engine = FakeEngine()
        val session = TunnelSession(engine)
        val request = request()
        session.start { request }
        assertSame(request, engine.lastRequest)
        session.stop()
        session.stop()
        assertEquals(listOf("start:7", "stop"), engine.events)
    }

    @Test
    fun rejectedStartCleansUpAndAllowsRetry() {
        val engine = FakeEngine().apply { accepted = false }
        val session = TunnelSession(engine)
        assertThrows(IllegalStateException::class.java) { session.start { request() } }
        session.stop()
        engine.accepted = true
        session.start { request(8) }
        session.stop()
        assertEquals(listOf("start:7", "stop", "start:8", "stop"), engine.events)
    }

    @Test
    fun throwingStartAlsoCleansUp() {
        val failure = IllegalStateException("start failed")
        val engine = FakeEngine().apply { this.failure = failure }
        val session = TunnelSession(engine)
        assertSame(failure, assertThrows(IllegalStateException::class.java) {
            session.start { request() }
        })
        session.stop()
        assertEquals(listOf("start:7", "stop"), engine.events)
    }

    @Test
    fun sameEngineReplacementPreservesExistingStartSemantics() {
        val engine = FakeEngine()
        val session = TunnelSession(engine)
        session.start { request() }
        session.start { request(8) }
        session.stop()
        assertEquals(listOf("start:7", "start:8", "stop"), engine.events)
    }

    @Test
    fun switchingStopsOldEngineBeforeEstablishingNewTunnel() {
        val old = FakeEngine()
        val next = FakeEngine()
        val session = TunnelSession(old)
        session.start { request() }
        session.start(next) {
            assertEquals(listOf("start:7", "stop"), old.events)
            request(8)
        }
        session.stop()
        assertEquals(listOf("start:7", "stop"), old.events)
        assertEquals(listOf("start:8", "stop"), next.events)
    }

    @Test
    fun failedOldEngineStopPreventsNewDescriptorAllocation() {
        val old = FakeEngine()
        val next = FakeEngine()
        val session = TunnelSession(old)
        session.start { request() }
        val failure = IllegalStateException("stop failed")
        old.stopFailure = failure
        assertSame(failure, assertThrows(IllegalStateException::class.java) {
            session.start(next) { error("must not establish a new tunnel") }
        })
        assertEquals(emptyList<String>(), next.events)
        old.stopFailure = null
        session.stop()
        assertEquals(listOf("start:7", "stop", "stop"), old.events)
    }

    @Test
    fun failedNewEngineStartCleansUpAndAllowsDefaultRestart() {
        val old = FakeEngine()
        val next = FakeEngine().apply { accepted = false }
        val session = TunnelSession(old)
        session.start { request() }
        assertThrows(IllegalStateException::class.java) {
            session.start(next) { request(8) }
        }
        session.start { request(9) }
        session.stop()
        assertEquals(listOf("start:7", "stop", "start:9", "stop"), old.events)
        assertEquals(listOf("start:8", "stop"), next.events)
    }

    @Test
    fun failedEstablishDoesNotStartNewEngine() {
        val old = FakeEngine()
        val next = FakeEngine()
        val session = TunnelSession(old)
        session.start { request() }
        val failure = IllegalStateException("establish failed")
        assertSame(failure, assertThrows(IllegalStateException::class.java) {
            session.start(next) { throw failure }
        })
        session.stop()
        assertEquals(listOf("start:7", "stop"), old.events)
        assertEquals(emptyList<String>(), next.events)
    }

    @Test
    fun startFailureIsPreservedWhenCleanupAlsoFails() {
        val startFailure = IllegalStateException("start failed")
        val cleanupFailure = IllegalStateException("cleanup failed")
        val engine = FakeEngine().apply {
            failure = startFailure
            stopFailure = cleanupFailure
        }
        val session = TunnelSession(engine)
        val thrown = assertThrows(IllegalStateException::class.java) {
            session.start { request() }
        }
        assertSame(startFailure, thrown)
        assertSame(cleanupFailure, thrown.suppressed.single())
        engine.stopFailure = null
        session.stop()
        assertEquals(listOf("start:7", "stop", "stop"), engine.events)
    }

    private class CallbackEngine(
        private val events: MutableList<String>,
    ) : CallbackTunnelEngine {
        var validationFailure: IllegalStateException? = null
        var startFailure: IllegalStateException? = null
        var stopFailure: IllegalStateException? = null

        override fun validate() {
            events.add("validate")
            validationFailure?.let { throw it }
        }

        override fun start() {
            events.add("native-start")
            startFailure?.let { throw it }
        }

        override fun stop() {
            events.add("native-stop")
            stopFailure?.let { throw it }
        }
    }

    @Test
    fun callbackValidationFailurePreservesActiveMihomo() {
        val mihomo = FakeEngine()
        val session = TunnelSession(mihomo)
        session.start { request() }
        val events = mutableListOf<String>()
        val native = CallbackEngine(events).apply {
            validationFailure = IllegalStateException("invalid config")
        }
        assertThrows(IllegalStateException::class.java) { session.start(native) }
        assertEquals(listOf("start:7"), mihomo.events)
        assertEquals(listOf("validate"), events)
        session.stop()
        assertEquals(listOf("start:7", "stop"), mihomo.events)
    }

    @Test
    fun callbackEngineStartsAfterOldOwnerStopsAndMihomoCanReturn() {
        val events = mutableListOf<String>()
        val mihomo = object : TunnelEngine {
            override fun start(request: TunnelRequest): Boolean {
                events.add("mihomo-start")
                return true
            }

            override fun stop() {
                events.add("mihomo-stop")
            }
        }
        val session = TunnelSession(mihomo)
        val native = CallbackEngine(events)
        session.start { request() }
        session.start(native)
        session.start {
            events.add("establish")
            request(8)
        }
        session.stop()
        assertEquals(
            listOf("mihomo-start", "validate", "mihomo-stop", "native-start",
                "native-stop", "establish", "mihomo-start", "mihomo-stop"),
            events,
        )
    }

    @Test
    fun callbackRestartStopsPreviousNativeSession() {
        val events = mutableListOf<String>()
        val native = CallbackEngine(events)
        val session = TunnelSession(FakeEngine())
        session.start(native)
        session.start(native)
        session.stop()
        assertEquals(
            listOf("validate", "native-start", "validate", "native-stop", "native-start", "native-stop"),
            events,
        )
    }

    @Test
    fun callbackStartupFailureCleansUpBeforeMihomoRetry() {
        val events = mutableListOf<String>()
        val failure = IllegalStateException("native TUN failed")
        val native = CallbackEngine(events).apply { startFailure = failure }
        val mihomo = FakeEngine()
        val session = TunnelSession(mihomo)
        assertSame(failure, assertThrows(IllegalStateException::class.java) { session.start(native) })
        session.start { request() }
        session.stop()
        assertEquals(listOf("validate", "native-start", "native-stop"), events)
        assertEquals(listOf("start:7", "stop"), mihomo.events)
    }

    @Test
    fun callbackStopFailurePreventsMihomoRouteEstablishment() {
        val events = mutableListOf<String>()
        val failure = IllegalStateException("native still owns TUN")
        val native = CallbackEngine(events).apply { stopFailure = failure }
        val session = TunnelSession(FakeEngine())
        session.start(native)
        assertSame(failure, assertThrows(IllegalStateException::class.java) {
            session.start { error("must not establish routes") }
        })
        native.stopFailure = null
        session.stop()
        assertEquals(listOf("validate", "native-start", "native-stop", "native-stop"), events)
    }
}
