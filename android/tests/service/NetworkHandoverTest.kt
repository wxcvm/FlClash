package com.follow.clash.service

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class NetworkHandoverTest {
    @Test
    fun `validated cellular beats unvalidated wifi but validated wifi wins`() {
        val cell = networkSelectionPriority(4, true, true, false)
        assertTrue(cell < networkSelectionPriority(0, false, true, false))
        assertTrue(networkSelectionPriority(0, true, true, false) < cell)
    }

    @Test
    fun `losing wifi and dnsless wifi yield to a usable alternative`() {
        val cell = networkSelectionPriority(4, true, true, false)
        assertTrue(cell < networkSelectionPriority(0, true, true, true))
        assertTrue(cell < networkSelectionPriority(0, true, false, false))
        assertTrue(networkSelectionPriority(0, false, true, false) < networkSelectionPriority(4, false, true, false))
    }

    @Test
    fun `initial connect and repeated callbacks do not reset`() {
        val tracker = NetworkHandoverTracker<String>()
        assertFalse(tracker.update(null))
        assertFalse(tracker.update("wifi"))
        assertFalse(tracker.update("wifi"))
        assertTrue(tracker.update("cell"))
        assertFalse(tracker.update("cell"))
    }

    @Test
    fun `outage resets once when the same network returns`() {
        val tracker = NetworkHandoverTracker<String>()
        assertFalse(tracker.update("wifi"))
        tracker.markLost("wifi")
        assertFalse(tracker.update(null))
        assertTrue(tracker.update("wifi"))
        assertFalse(tracker.update("wifi"))
    }

    @Test
    fun `handover waits for DNS then resets exactly once`() {
        val tracker = NetworkHandoverTracker<String>()
        assertFalse(tracker.update("wifi"))
        assertFalse(tracker.update("cell", dnsReady = false))
        assertTrue(tracker.current == "wifi")
        tracker.markLost("wifi")
        assertFalse(tracker.update("cell", dnsReady = false))
        assertTrue(tracker.current == null)
        assertTrue(tracker.update("cell"))
        assertFalse(tracker.update("cell"))
    }

    @Test
    fun `late loss of old network does not reset the new one`() {
        val tracker = NetworkHandoverTracker<String>()
        assertFalse(tracker.update("wifi"))
        assertTrue(tracker.update("cell"))
        tracker.markLost("wifi")
        assertFalse(tracker.update("cell"))
    }
}
