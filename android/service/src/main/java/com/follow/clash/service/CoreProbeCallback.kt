package com.follow.clash.service

import android.content.Context
import android.os.Binder
import android.os.IBinder
import android.os.Parcel
import android.os.Process

/** Same-UID, one-way callback. Small payloads are inline; large ones use descriptors. */
internal object CoreProbeCallback {
    private const val TOKEN = "com.follow.clash.service.MihomoProbeCallback"
    private const val RESULT = IBinder.FIRST_CALL_TRANSACTION

    fun receiver(receive: (Result<ByteArray>) -> Unit): IBinder = object : Binder() {
        override fun onTransact(code: Int, data: Parcel, reply: Parcel?, flags: Int): Boolean {
            if (code != RESULT) return super.onTransact(code, data, reply, flags)
            data.enforceInterface(TOKEN)
            if (Binder.getCallingUid() != Process.myUid()) throw SecurityException("Private Core callback")
            val result = runCatching {
                val error = data.readString()
                check(error == null) { error.orEmpty() }
                CoreProbePayload.readParcel(data)
            }
            receive(result)
            return true
        }
    }

    fun send(context: Context, remote: IBinder, result: Result<ByteArray>) {
        val data = Parcel.obtain()
        try {
            data.writeInterfaceToken(TOKEN)
            val bytes = result.getOrNull()
            if (bytes == null) {
                data.writeString(result.exceptionOrNull()?.message ?: "Core callback failed")
                check(remote.transact(RESULT, data, null, IBinder.FLAG_ONEWAY))
            } else if (CoreProbePayload.inline(bytes)) {
                data.writeString(null)
                CoreProbePayload.writeInline(data, bytes)
                check(remote.transact(RESULT, data, null, IBinder.FLAG_ONEWAY))
            } else {
                // Open before writing the success marker, so a failed payload
                // allocation can still be reported as an explicit error.
                val descriptor = runCatching { CoreProbePayload.open(context, bytes) }
                val fd = descriptor.getOrNull()
                if (fd == null) {
                    data.writeString(descriptor.exceptionOrNull()?.message ?: "Core callback payload failed")
                    check(remote.transact(RESULT, data, null, IBinder.FLAG_ONEWAY))
                } else {
                    fd.use {
                        data.writeString(null)
                        CoreProbePayload.writeDescriptor(data, it)
                        check(remote.transact(RESULT, data, null, IBinder.FLAG_ONEWAY))
                    }
                }
            }
        } finally {
            data.recycle()
        }
    }
}
