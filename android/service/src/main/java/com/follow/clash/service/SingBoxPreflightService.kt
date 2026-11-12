package com.follow.clash.service

import android.app.Service
import android.content.Intent
import android.os.Binder
import android.os.IBinder
import android.os.ParcelFileDescriptor
import android.os.Process

/** Bound-only, process-isolated native configuration preflight. No VPN routes. */
class SingBoxPreflightService : Service() {
    private val binder = object : ISingBoxPreflight.Stub() {
        override fun validate(config: ParcelFileDescriptor): String {
            check(Binder.getCallingUid() == Process.myUid()) { "Foreign UID" }
            try {
                val content = NativeConfigReader.read(config)
                return IsolatedLibbox.validateVpnConfig(this@SingBoxPreflightService, content)
            } catch (error: Exception) {
                // Binder can marshal IllegalArgumentException, not arbitrary JNI exceptions.
                throw IllegalArgumentException(error.message ?: error.javaClass.simpleName)
            } catch (error: LinkageError) {
                throw IllegalStateException("Native libbox loading failed: ${error.message}")
            }
        }
    }

    override fun onBind(intent: Intent): IBinder = binder

}
