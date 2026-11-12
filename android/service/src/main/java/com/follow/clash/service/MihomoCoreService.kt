package com.follow.clash.service

import android.app.Service
import android.content.Intent
import android.os.Binder
import android.os.IBinder
import android.os.Parcel
import android.os.ParcelFileDescriptor
import android.os.Process
import com.follow.clash.core.Core
import org.json.JSONObject

/** The actual Mihomo Core, shared by VPN, proxy and RPC in the opt-in :mihomo process. */
class MihomoCoreService : Service() {
    private val lock = Any()
    private var owner: IBinder? = null
    private var death: IBinder.DeathRecipient? = null
    @Volatile private var events: IBinder? = null

    private val binder = object : Binder() {
        override fun onTransact(code: Int, data: Parcel, reply: Parcel?, flags: Int): Boolean {
            if (code !in MihomoCoreControl.ATTACH..MihomoCoreControl.LISTENER || reply == null) {
                return super.onTransact(code, data, reply, flags)
            }
            data.enforceInterface(MihomoCoreControl.TOKEN)
            check(Binder.getCallingUid() == Process.myUid()) { "Private Mihomo Core" }
            try {
                val token = requireNotNull(data.readStrongBinder())
                synchronized(lock) {
                    if (code == MihomoCoreControl.ATTACH) {
                        check(owner == null || owner == token) { "Mihomo Core already owned" }
                        if (owner == null) {
                            val recipient = IBinder.DeathRecipient { detach(token) }
                            token.linkToDeath(recipient, 0)
                            owner = token
                            death = recipient
                        }
                        Core.load()
                        NetworkObserver.start()
                        reply.writeNoException()
                        reply.writeInt(Process.myPid())
                        return true
                    }
                    check(owner == token) { "Invalid Mihomo Core owner" }
                    when (code) {
                        MihomoCoreControl.INVOKE, MihomoCoreControl.SETUP -> {
                            val callback = requireNotNull(data.readStrongBinder())
                            val request = CoreProbePayload.read(
                                ParcelFileDescriptor.CREATOR.createFromParcel(data),
                            ).decodeToString()
                            val deliver: (ByteArray) -> Unit = { bytes ->
                                runCatching { CoreProbeCallback.send(this@MihomoCoreService, callback, Result.success(bytes)) }
                            }
                            if (code == MihomoCoreControl.INVOKE) {
                                Core.invokeMethod(request) { deliver(it ?: ByteArray(0)) }
                            } else {
                                val json = JSONObject(request)
                                Core.quickSetup(json.getString("init"), json.getString("setup")) {
                                    deliver(it.orEmpty().encodeToByteArray())
                                }
                            }
                        }
                        MihomoCoreControl.EVENTS -> {
                            val next = data.readStrongBinder()
                            events = next
                            Core.updateEventListener(next?.let { receiver ->
                                { bytes ->
                                    if (events == receiver) runCatching {
                                        CoreProbeCallback.send(this@MihomoCoreService, receiver, Result.success(bytes))
                                    }
                                }
                            })
                        }
                        MihomoCoreControl.LISTENER -> {
                            if (data.readInt() != 0) Core.startListener() else Core.stopListener()
                        }
                    }
                    reply.writeNoException()
                }
            } catch (error: Exception) {
                reply.writeException(IllegalStateException(error.message ?: "Mihomo RPC failed"))
            } catch (error: LinkageError) {
                reply.writeException(IllegalStateException("Mihomo JNI: ${error.message}"))
            }
            return true
        }
    }

    private fun detach(token: IBinder?) = synchronized(lock) {
        if (owner != token || token == null) return@synchronized
        events = null
        Core.updateEventListener(null)
        death?.let { runCatching { token.unlinkToDeath(it, 0) } }
        owner = null
        death = null
    }

    override fun onBind(intent: Intent): IBinder = binder
    override fun onDestroy() {
        detach(owner)
        super.onDestroy()
    }
}
