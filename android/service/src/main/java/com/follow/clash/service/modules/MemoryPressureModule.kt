package com.follow.clash.service.modules

import android.app.ActivityManager
import android.app.Service
import androidx.core.content.getSystemService
import com.follow.clash.service.MitmPressure
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch

private const val PRESSURE_POLL_INTERVAL_MS = 15_000L
private const val HEALTHY_POLL_INTERVAL_MS = 30_000L

internal fun memoryPressurePollInterval(
    lowMemory: Boolean,
    availableBytes: Long,
    thresholdBytes: Long,
): Long = if (lowMemory || availableBytes < thresholdBytes * 2) {
    PRESSURE_POLL_INTERVAL_MS
} else {
    HEALTHY_POLL_INTERVAL_MS
}

// Stands in for the running trim levels Android 14 stopped delivering.
internal class MemoryPressureModule(
    private val service: Service,
    private val scope: CoroutineScope,
) : ServiceModule {
    override fun start() {
        val activityManager = service.getSystemService<ActivityManager>() ?: return
        scope.launch {
            val info = ActivityManager.MemoryInfo()
            while (isActive) {
                activityManager.getMemoryInfo(info)
                MitmPressure.onMemoryInfo(info)
                delay(memoryPressurePollInterval(info.lowMemory, info.availMem, info.threshold))
            }
        }
    }

    override fun stop() = Unit
}
