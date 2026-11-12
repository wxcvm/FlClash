package com.follow.clash.service

import android.app.Application
import android.os.Build

/** Shared by the actual Core/VPN/Proxy in the isolated process. */
internal object MihomoProcessLifecycle {
    private val lock = Any()
    private val running = mutableSetOf<Any>()
    private var retiring = false
    private var vpn: VpnService? = null

    fun register(service: VpnService) = synchronized(lock) { vpn = service }
    fun unregister(service: VpnService) = synchronized(lock) {
        if (vpn === service) vpn = null
    }

    fun start(service: Any, action: () -> Unit) = synchronized(lock) {
        check(!retiring) { "Mihomo process is retiring" }
        action()
        running.add(service)
        Unit
    }

    fun stop(service: Any, action: () -> Unit) = synchronized(lock) {
        action()
        running.remove(service)
        Unit
    }

    fun retire(packageName: String) = synchronized(lock) {
        check(Build.VERSION.SDK_INT >= 28 && Application.getProcessName() == "$packageName:mihomo") {
            "Refusing to retire non-Mihomo process"
        }
        check(running.isEmpty()) { "Mihomo service is still running" }
        check(Build.VERSION.SDK_INT < 29 || vpn?.let { !it.isAlwaysOn && !it.isLockdownEnabled } != false) {
            "Disable always-on/lockdown VPN before switching cores"
        }
        retiring = true
    }

    fun checkAvailable() = synchronized(lock) { check(!retiring) { "Mihomo process is retiring" } }
}
