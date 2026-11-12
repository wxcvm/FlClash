package com.follow.clash.service.modules

import org.junit.Assert.assertEquals
import org.junit.Test

class MemoryPressureModuleTest {
    @Test
    fun `healthy memory uses a slower poll`() {
        assertEquals(30_000L, memoryPressurePollInterval(false, 300L, 100L))
        assertEquals(30_000L, memoryPressurePollInterval(false, 200L, 100L))
    }

    @Test
    fun `pressure retains the faster poll`() {
        assertEquals(15_000L, memoryPressurePollInterval(false, 199L, 100L))
        assertEquals(15_000L, memoryPressurePollInterval(true, 300L, 100L))
    }
}
