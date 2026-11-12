package com.follow.clash.service

import android.content.Context
import android.content.Intent
import android.os.IBinder
import android.os.DeadObjectException
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
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
    internal const val SNAPSHOT = VALIDATE + 5
    internal const val SELECT = VALIDATE + 6
    internal const val URL_TEST = VALIDATE + 7
    internal const val QUALITY_START = VALIDATE + 8
    internal const val QUALITY_STATUS = VALIDATE + 9
    internal const val QUALITY_CANCEL = VALIDATE + 10

    fun isAvailable(context: Context): Boolean = IsolatedSingBoxRuntime.isPackaged(context)

    fun bindIntent(context: Context): Intent =
        Intent(context, SingBoxVpnService::class.java).setAction(BIND)

    fun foregroundIntent(context: Context): Intent =
        Intent(context, SingBoxVpnService::class.java).setAction(FOREGROUND)

    /** Invoke on a background dispatcher; configuration is never copied into Binder strings. */
    fun validate(remote: IBinder, profile: File) = configCall(remote, VALIDATE, profile)
    fun start(remote: IBinder) { call(remote, START) }

    /** A successful stop means the old process is dead, not just unbound. */
    fun stop(remote: IBinder) {
        val dead = CountDownLatch(1)
        val recipient = IBinder.DeathRecipient { dead.countDown() }
        try {
            remote.linkToDeath(recipient, 0)
        } catch (_: DeadObjectException) {
            return
        }
        try {
            try {
                call(remote, STOP)
            } catch (_: DeadObjectException) {
                return
            }
            check(dead.await(5, TimeUnit.SECONDS) || !remote.isBinderAlive) {
                "Native VPN process did not exit; retry stop before switching"
            }
        } finally {
            remote.unlinkToDeath(recipient, 0)
        }
    }
    fun resetNetwork(remote: IBinder) { call(remote, RESET) }
    fun isRunning(remote: IBinder): Boolean = call(remote, STATUS) != 0

    fun startQuality(remote: IBinder, tag: String) { call(remote, QUALITY_START) { it.writeString(tag) } }
    fun qualitySnapshot(remote: IBinder): String = transact(remote, QUALITY_STATUS) { it.readString().orEmpty() }
    fun cancelQuality(remote: IBinder) { call(remote, QUALITY_CANCEL) }

    fun snapshot(remote: IBinder): String = transact(remote, SNAPSHOT) { it.readString().orEmpty() }
    fun selectOutbound(remote: IBinder, group: String, tag: String, expectedGeneration: Long) {
        call(remote, SELECT) { it.writeString(group); it.writeString(tag); it.writeLong(expectedGeneration) }
    }
    fun testOutbound(remote: IBinder, tag: String) {
        call(remote, URL_TEST) { it.writeString(tag) }
    }

    private fun configCall(remote: IBinder, code: Int, profile: File) {
        ParcelFileDescriptor.open(profile, ParcelFileDescriptor.MODE_READ_ONLY).use { descriptor ->
            call(remote, code) { descriptor.writeToParcel(it, 0) }
        }
    }

    private fun call(remote: IBinder, code: Int, write: (Parcel) -> Unit = {}): Int =
        transact(remote, code, write) { it.readInt() }

    private fun <T> transact(remote: IBinder, code: Int, write: (Parcel) -> Unit = {}, read: (Parcel) -> T): T {
        val data = Parcel.obtain()
        val reply = Parcel.obtain()
        try {
            data.writeInterfaceToken(TOKEN)
            write(data)
            check(remote.transact(code, data, reply, 0)) { "sing-box VPN command was rejected" }
            reply.readException()
            return read(reply)
        } finally {
            data.recycle()
            reply.recycle()
        }
    }
}
