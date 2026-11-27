package com.follow.clash.service.modules

import android.app.ActivityManager
import android.app.Service
import androidx.core.content.getSystemService
import com.follow.clash.service.MitmPressure
import com.follow.clash.service.ServiceConfig
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.collectLatest
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

internal suspend fun pollWhile(enabled: Flow<Boolean>, poll: () -> Long) =
    enabled.collectLatest { on ->
        while (on) delay(poll())
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
            pollWhile(ServiceConfig.mitm) {
                activityManager.getMemoryInfo(info)
                MitmPressure.onMemoryInfo(info)
                memoryPressurePollInterval(info.lowMemory, info.availMem, info.threshold)
            }
        }
    }

    override fun stop() = Unit
}
