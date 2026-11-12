package com.follow.clash.service

import com.follow.clash.core.Core
import java.net.InetSocketAddress

/** The VPN service owns routes; a single engine consumes its detached TUN descriptor. */
internal interface TunnelEngine {
    /** Takes ownership of fd, including on rejected startup. */
    fun start(request: TunnelRequest): Boolean
    fun stop()
}

internal data class TunnelRequest(
    val fd: Int,
    val protect: (Int) -> Boolean,
    val resolveUid: (Int, InetSocketAddress, InetSocketAddress) -> Int,
    val resolvePackage: (Int) -> String,
    val stack: String,
    val address: String,
    val dns: String,
    val options: String,
)

/** Keeps the existing embedded core and JNI calls as the default implementation. */
internal object MihomoTunnelEngine : TunnelEngine {
    override fun start(request: TunnelRequest): Boolean = Core.startTun(
        fd = request.fd,
        protect = request.protect,
        resolveUid = request.resolveUid,
        resolvePackage = request.resolvePackage,
        stack = request.stack,
        address = request.address,
        dns = request.dns,
        options = request.options,
    )

    override fun stop() = Core.stopTun()
}

/** Serializes route establishment, engine handoff and teardown. */
internal class TunnelSession(private val defaultEngine: TunnelEngine) {
    private var activeEngine: TunnelEngine? = null

    @Synchronized
    fun start(engine: TunnelEngine = defaultEngine, request: () -> TunnelRequest) {
        // Do not establish a replacement VPN until the previous engine has
        // released its tunnel. A same-engine restart retains its existing behavior.
        if (activeEngine != null && activeEngine !== engine) {
            stop()
        }
        // Establish inside the lock, before transferring descriptor ownership.
        val next = request()
        activeEngine = engine
        try {
            check(engine.start(next)) { "Core rejected the tun file descriptor" }
        } catch (error: Throwable) {
            try {
                stop()
            } catch (cleanup: Throwable) {
                if (cleanup !== error) error.addSuppressed(cleanup)
            }
            throw error
        }
    }

    @Synchronized
    fun stop() {
        val engine = activeEngine ?: return
        // Keep the owner recorded if stopping fails, so a later stop can retry
        // and another engine cannot take over an unclosed tunnel.
        engine.stop()
        activeEngine = null
    }
}
