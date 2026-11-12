package com.follow.clash.service

import android.app.Service
import android.content.Intent
import android.os.Binder
import android.os.IBinder
import android.os.ParcelFileDescriptor
import android.os.Process
import java.io.ByteArrayOutputStream

/** Bound-only, process-isolated native configuration preflight. No VPN routes. */
class SingBoxPreflightService : Service() {
    private val binder = object : ISingBoxPreflight.Stub() {
        override fun validate(config: ParcelFileDescriptor): String {
            check(Binder.getCallingUid() == Process.myUid()) { "Foreign UID" }
            try {
                val content = ParcelFileDescriptor.AutoCloseInputStream(config).use { input ->
                    val bytes = ByteArrayOutputStream()
                    val buffer = ByteArray(16384)
                    while (true) {
                        val count = input.read(buffer)
                        if (count < 0) break
                        require(bytes.size() + count <= MAX_CONFIG_BYTES) {
                            "Native config exceeds 16 MiB"
                        }
                        bytes.write(buffer, 0, count)
                    }
                    bytes.toString(Charsets.UTF_8.name())
                }
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

    companion object {
        private const val MAX_CONFIG_BYTES = 16 * 1024 * 1024
    }
}
