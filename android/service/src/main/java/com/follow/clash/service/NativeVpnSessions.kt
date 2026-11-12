package com.follow.clash.service

import android.content.Context
import java.io.File

/** A single prepared native VPN lease. All calls except availability are off-UI. */
interface NativeVpnSession {
    val version: String
    fun validate()
    fun start()
    fun stop()
}

object NativeVpnSessions {
    fun isAvailable(context: Context): Boolean = IsolatedLibbox.isAvailable(context)

    suspend fun prepare(
        context: Context,
        config: File,
        onUnexpectedStop: (String) -> Unit,
    ): NativeVpnSession = RemoteSingBoxEngine.prepare(context, config, onUnexpectedStop)
}
