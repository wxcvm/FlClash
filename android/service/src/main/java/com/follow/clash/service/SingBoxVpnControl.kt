package com.follow.clash.service

import android.content.Context
import android.content.Intent
import android.os.IBinder
import android.os.Parcel
import android.os.ParcelFileDescriptor
import java.io.File

/** Internal app-to-VPN-process protocol. No native classes cross the Binder boundary. */
object SingBoxVpnControl {
    internal const val TOKEN = "com.follow.clash.service.SingBoxVpn"
    internal const val BIND = "$TOKEN.BIND"
    internal const val FOREGROUND = "$TOKEN.FOREGROUND"
    internal const val STOP_ACTION = "$TOKEN.STOP"
    internal const val VALIDATE = IBinder.FIRST_CALL_TRANSACTION
    internal const val START = VALIDATE + 1
    internal const val STOP = VALIDATE + 2
    internal const val STATUS = VALIDATE + 3
    internal const val RESET = VALIDATE + 4

    fun isAvailable(context: Context): Boolean = IsolatedSingBoxRuntime.isPackaged(context)

    fun bindIntent(context: Context): Intent =
        Intent(context, SingBoxVpnService::class.java).setAction(BIND)

    fun foregroundIntent(context: Context): Intent =
        Intent(context, SingBoxVpnService::class.java).setAction(FOREGROUND)

    /** Invoke on a background dispatcher; configuration is never copied into Binder strings. */
    fun validate(remote: IBinder, profile: File) = configCall(remote, VALIDATE, profile)
    fun start(remote: IBinder, profile: File) = configCall(remote, START, profile)
    fun stop(remote: IBinder) { call(remote, STOP) }
    fun resetNetwork(remote: IBinder) { call(remote, RESET) }
    fun isRunning(remote: IBinder): Boolean = call(remote, STATUS) != 0

    private fun configCall(remote: IBinder, code: Int, profile: File) {
        ParcelFileDescriptor.open(profile, ParcelFileDescriptor.MODE_READ_ONLY).use { descriptor ->
            call(remote, code) { descriptor.writeToParcel(it, 0) }
        }
    }

    private fun call(remote: IBinder, code: Int, write: (Parcel) -> Unit = {}): Int {
        val data = Parcel.obtain()
        val reply = Parcel.obtain()
        try {
            data.writeInterfaceToken(TOKEN)
            write(data)
            check(remote.transact(code, data, reply, 0)) { "sing-box VPN command was rejected" }
            reply.readException()
            return reply.readInt()
        } finally {
            data.recycle()
            reply.recycle()
        }
    }
}
