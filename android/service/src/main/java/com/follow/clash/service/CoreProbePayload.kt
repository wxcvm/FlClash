package com.follow.clash.service

import android.content.Context
import android.os.ParcelFileDescriptor
import android.system.Os
import android.system.OsConstants
import java.io.ByteArrayOutputStream
import java.io.File

/** File descriptors keep large Core payloads out of Binder's shared transaction buffer. */
internal object CoreProbePayload {
    private const val MAX_BYTES = 16 * 1024 * 1024

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
