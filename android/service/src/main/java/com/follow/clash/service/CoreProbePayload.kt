package com.follow.clash.service

import android.content.Context
import android.os.Parcel
import android.os.ParcelFileDescriptor
import android.system.Os
import android.system.OsConstants
import java.io.ByteArrayOutputStream
import java.io.File

/** File descriptors keep large Core payloads out of Binder's shared transaction buffer. */
internal object CoreProbePayload {
    private const val INLINE_LIMIT = 32 * 1024
    private const val MAX_BYTES = 16 * 1024 * 1024

    // A small command/result needs no file or extra descriptor. Larger payloads
    // retain the bounded regular-file transport.
    fun inline(bytes: ByteArray): Boolean = bytes.size <= INLINE_LIMIT

    fun writeInline(parcel: Parcel, bytes: ByteArray) {
        require(inline(bytes))
        parcel.writeInt(0)
        parcel.writeByteArray(bytes)
    }

    fun writeDescriptor(parcel: Parcel, descriptor: ParcelFileDescriptor) {
        parcel.writeInt(1)
        descriptor.writeToParcel(parcel, 0)
    }

    fun readParcel(parcel: Parcel): ByteArray = when (parcel.readInt()) {
        0 -> requireNotNull(parcel.createByteArray()).also { require(inline(it)) }
        1 -> read(ParcelFileDescriptor.CREATOR.createFromParcel(parcel))
        else -> error("Invalid Core payload kind")
    }

    fun open(context: Context, bytes: ByteArray): ParcelFileDescriptor {
        require(bytes.size <= MAX_BYTES) { "Core probe payload exceeds 16 MiB" }
        val file = File.createTempFile("mihomo-ipc-", ".tmp", context.cacheDir)
        try {
            file.writeBytes(bytes)
            return ParcelFileDescriptor.open(file, ParcelFileDescriptor.MODE_READ_ONLY)
        } finally {
            file.delete()
        }
    }

    fun read(descriptor: ParcelFileDescriptor): ByteArray =
        ParcelFileDescriptor.AutoCloseInputStream(descriptor).use { input ->
            val stat = Os.fstat(descriptor.fileDescriptor)
            require(OsConstants.S_ISREG(stat.st_mode) && stat.st_size in 0..MAX_BYTES.toLong()) {
                "Core probe requires a bounded regular file"
            }
            val bytes = ByteArrayOutputStream()
            val buffer = ByteArray(16384)
            while (true) {
                val count = input.read(buffer)
                if (count < 0) break
                require(bytes.size() + count <= MAX_BYTES) { "Core probe payload exceeds 16 MiB" }
                bytes.write(buffer, 0, count)
            }
            bytes.toByteArray()
        }
}
