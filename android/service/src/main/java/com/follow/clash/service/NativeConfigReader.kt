package com.follow.clash.service

import android.os.ParcelFileDescriptor
import java.io.ByteArrayOutputStream

internal object NativeConfigReader {
    private const val MAX_CONFIG_BYTES = 16 * 1024 * 1024

    fun read(config: ParcelFileDescriptor): String =
        ParcelFileDescriptor.AutoCloseInputStream(config).use { input ->
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
