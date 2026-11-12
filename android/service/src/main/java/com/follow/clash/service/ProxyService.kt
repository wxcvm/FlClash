package com.follow.clash.service

import android.app.Service
import android.content.Intent
import android.os.Binder
import android.os.IBinder
import com.follow.clash.service.modules.ServiceModules

class ProxyService : Service(), ManagedService {
    private val modules = ServiceModules(this)
    private val binder = LocalBinder()
    private val control = MihomoServiceControl.binder(this, vpn = false) { true }

    override fun onDestroy() {
        try {
            MihomoProcessLifecycle.stop(this) { cleanup() }
        } finally {
            super.onDestroy()
        }
    }

    override fun onLowMemory() {
        lowCoreMemory()
        super.onLowMemory()
    }

    override fun onTrimMemory(level: Int) {
        trimCoreMemory(level)
        super.onTrimMemory(level)
    }

    inner class LocalBinder : Binder() {
        val service: ProxyService
            get() = this@ProxyService
    }

    override fun onBind(intent: Intent): IBinder =
        if (intent.action == MihomoServiceControl.ACTION) control else binder

    override fun start() = MihomoProcessLifecycle.start(this) {
        try {
            modules.start()
        } catch (error: Exception) {
            stop()
            throw error
        }
    }

    override fun stop() {
        try {
            MihomoProcessLifecycle.stop(this) { cleanup() }
        } finally {
            stopSelf()
        }
    }

    private fun cleanup() = modules.stop()
}
