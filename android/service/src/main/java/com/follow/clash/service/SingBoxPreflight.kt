package com.follow.clash.service

import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.ServiceConnection
import android.os.IBinder
import android.os.ParcelFileDescriptor
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeout
import java.io.File

/** Preflight without loading libbox in the caller or disrupting an active VPN. */
internal object SingBoxPreflight {
    suspend fun validate(context: Context, config: File): String = withContext(Dispatchers.IO) {
        val app = context.applicationContext
        check(IsolatedLibbox.isAvailable(app)) { "Optional sing-box payload unavailable" }
        val connected = CompletableDeferred<ISingBoxPreflight>()
        val connection = object : ServiceConnection {
            override fun onServiceConnected(name: ComponentName, binder: IBinder) {
                connected.complete(ISingBoxPreflight.Stub.asInterface(binder))
            }

            override fun onServiceDisconnected(name: ComponentName) {
                connected.completeExceptionally(IllegalStateException("Native core disconnected"))
            }

            override fun onBindingDied(name: ComponentName) {
                connected.completeExceptionally(IllegalStateException("Native core binding died"))
            }

            override fun onNullBinding(name: ComponentName) {
                connected.completeExceptionally(IllegalStateException("Native core rejected binding"))
            }
        }
        val intent = Intent(app, SingBoxPreflightService::class.java)
        check(app.bindService(intent, connection, Context.BIND_AUTO_CREATE)) {
            "Cannot bind native core preflight"
        }
        try {
            val remote = withTimeout(10000) { connected.await() }
            ParcelFileDescriptor.open(config, ParcelFileDescriptor.MODE_READ_ONLY).use { fd ->
                remote.validate(fd)
            }
        } finally {
            app.unbindService(connection)
        }
    }
}
