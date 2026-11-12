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

/** Serializes tunnel starts and teardown, including a rejected or throwing start. */
internal class TunnelSession(private val engine: TunnelEngine) {
    private var running = false

    @Synchronized
    fun start(request: TunnelRequest) {
        // Mihomo replaces its own previous listener on start. Preserve that
        // behavior until an engine switch is implemented at the service level.
        running = true
        try {
            check(engine.start(request)) { "Core rejected the tun file descriptor" }
        } catch (error: Exception) {
            stop()
            throw error
        }
    }

    @Synchronized
    fun stop() {
        if (running) {
            engine.stop()
            running = false
        }
    }
}
