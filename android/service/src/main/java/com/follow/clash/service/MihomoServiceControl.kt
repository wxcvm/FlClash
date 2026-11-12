package com.follow.clash.service

import android.content.Context
import android.os.Binder
import android.os.IBinder
import android.os.Parcel
import android.os.ParcelFileDescriptor
import android.os.Process
import com.follow.clash.service.models.NotificationParams
import com.follow.clash.service.models.VpnOptions
import com.google.gson.Gson
import org.json.JSONObject

/**
 * Process-neutral private lifecycle protocol. The actual VPN and Core still
 * share their current process until the Core command transport is migrated.
 */
object MihomoServiceControl {
    const val ACTION = "com.follow.clash.service.MIHOMO_CONTROL"
    private const val TOKEN = "com.follow.clash.service.MihomoControl"
    private const val START = IBinder.FIRST_CALL_TRANSACTION
    private const val STOP = START + 1
    private const val CAN_HANDOFF = START + 2
    private const val NOTIFICATION = START + 3
    private const val PID = START + 4
    private val gson = Gson()

    fun start(context: Context, remote: IBinder, options: VpnOptions, notification: NotificationParams) {
        require(options.nativeConfigPath == null) { "Mihomo cannot consume a native profile" }
        val payload = JSONObject().put("options", JSONObject(gson.toJson(options)))
            .put("notification", JSONObject(gson.toJson(notification)))
        CoreProbePayload.open(context, payload.toString().encodeToByteArray()).use { fd ->
            transact(remote, START, { fd.writeToParcel(it, 0) }) { Unit }
        }
    }

    fun stop(remote: IBinder) = transact(remote, STOP) { Unit }
    fun canHandoff(remote: IBinder): Boolean = transact(remote, CAN_HANDOFF) { it.readInt() != 0 }
    fun pid(remote: IBinder): Int = transact(remote, PID) { it.readInt() }
    fun updateNotification(remote: IBinder, params: NotificationParams) =
        transact(remote, NOTIFICATION, { it.writeString(gson.toJson(params)) }) { Unit }

    private fun <T> transact(
        remote: IBinder, code: Int, write: (Parcel) -> Unit = {}, read: (Parcel) -> T,
    ): T {
        val data = Parcel.obtain()
        val reply = Parcel.obtain()
        try {
            data.writeInterfaceToken(TOKEN)
            write(data)
            check(remote.transact(code, data, reply, 0)) { "Mihomo service command rejected" }
            reply.readException()
            return read(reply)
        } finally {
            reply.recycle()
            data.recycle()
        }
    }

    internal fun binder(
        service: ManagedService,
        vpn: Boolean,
        canHandoff: () -> Boolean,
    ): IBinder = object : Binder() {
        private val lifecycle = Any()

        override fun onTransact(code: Int, data: Parcel, reply: Parcel?, flags: Int): Boolean {
            if (code !in START..PID || reply == null) return super.onTransact(code, data, reply, flags)
            data.enforceInterface(TOKEN)
            if (Binder.getCallingUid() != Process.myUid()) throw SecurityException("Private Mihomo service")
            try {
                synchronized(lifecycle) {
                    when (code) {
                        START -> {
                            val payload = JSONObject(CoreProbePayload.read(
                                ParcelFileDescriptor.CREATOR.createFromParcel(data),
                            ).decodeToString())
                            val options = gson.fromJson(payload.getJSONObject("options").toString(), VpnOptions::class.java)
                            val notification = gson.fromJson(payload.getJSONObject("notification").toString(), NotificationParams::class.java)
                            require(options.enable == vpn && options.nativeConfigPath == null) {
                                "Mihomo service mode does not match the requested options"
                            }
                            ServiceConfig.updateVpnOptions(options)
                            ServiceConfig.updateNotificationParams(notification)
                            service.start()
                            reply.writeNoException()
                        }
                        STOP -> {
                            service.stop()
                            reply.writeNoException()
                        }
                        CAN_HANDOFF -> {
                            val permitted = canHandoff()
                            reply.writeNoException()
                            reply.writeInt(if (permitted) 1 else 0)
                        }
                        NOTIFICATION -> {
                            ServiceConfig.updateNotificationParams(
                                gson.fromJson(requireNotNull(data.readString()), NotificationParams::class.java),
                            )
                            reply.writeNoException()
                        }
                        PID -> {
                            reply.writeNoException()
                            reply.writeInt(Process.myPid())
                        }
                    }
                }
            } catch (error: Exception) {
                reply.writeException(IllegalStateException(error.message ?: "Mihomo service failed"))
            }
            return true
        }
    }
}
