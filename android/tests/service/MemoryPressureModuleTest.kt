package com.follow.clash.service.modules

import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.test.advanceTimeBy
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Test

class MemoryPressureModuleTest {
    @Test
    fun `healthy memory uses a slower poll`() {
        assertEquals(30_000L, memoryPressurePollInterval(false, 300L, 100L))
        assertEquals(30_000L, memoryPressurePollInterval(false, 200L, 100L))
    }

    @Test
    fun `memory polling runs only while MITM is enabled`() = runTest {
        val enabled = MutableStateFlow(false)
        var polls = 0
        backgroundScope.launch {
            pollWhile(enabled) {
                polls++
                1_000L
            }
        }

        runCurrent()
        assertEquals(0, polls)
        enabled.value = true
        runCurrent()
        assertEquals(1, polls)
        advanceTimeBy(1_000)
        runCurrent()
        assertEquals(2, polls)
        enabled.value = false
        runCurrent()
        advanceTimeBy(5_000)
        runCurrent()
        assertEquals(2, polls)
    }

    @Test
    fun `pressure retains the faster poll`() {
        assertEquals(15_000L, memoryPressurePollInterval(false, 199L, 100L))
        assertEquals(15_000L, memoryPressurePollInterval(true, 300L, 100L))
    }
}
