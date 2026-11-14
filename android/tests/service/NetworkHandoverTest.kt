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
    fun `same network path changes reset once`() {
        val tracker = NetworkHandoverTracker<String>()
        val initial = NetworkPath("wlan0", listOf("192.0.2.1/24"), listOf("default"),
            listOf("192.0.2.53:53"), false, null)
        assertFalse(tracker.update("wifi", path = initial))
        assertFalse(tracker.update("wifi", path = initial.copy()))
        val changed = initial.copy(addresses = listOf("192.0.2.2/24"))
        assertTrue(tracker.update("wifi", path = changed))
        assertFalse(tracker.update("wifi", path = changed))
        val privateDns = changed.copy(privateDnsActive = true, privateDnsName = "dns.example")
        assertTrue(tracker.update("wifi", path = privateDns))
        assertFalse(tracker.update("wifi", path = privateDns))
        val routed = privateDns.copy(routes = listOf("new default"))
        assertTrue(tracker.update("wifi", path = routed))
        val dnsChanged = routed.copy(dns = listOf("192.0.2.54:53"))
        assertTrue(tracker.update("wifi", path = dnsChanged))
        assertFalse(tracker.update("wifi", path = dnsChanged))
        val mtuChanged = dnsChanged.copy(mtu = 1400)
        assertTrue(tracker.update("wifi", path = mtuChanged))
        assertFalse(tracker.update("wifi", path = mtuChanged))
    }

    @Test
    fun `dns only changes preserve established data path`() {
        val tracker = NetworkHandoverTracker<String>()
        val initial = NetworkPath("wlan0", listOf("192.0.2.1/24"), listOf("default"),
            listOf("192.0.2.53:53"), false, null, 1500)
        tracker.update("wifi", path = initial)
        val changed = initial.copy(dns = listOf("192.0.2.54:53"))
        assertTrue(tracker.isDnsOnlyChange("wifi", changed))
        assertTrue(tracker.update("wifi", path = changed))
        assertFalse(tracker.isDnsOnlyChange("wifi", changed))
        assertTrue(tracker.isDnsOnlyChange("wifi",
            changed.copy(privateDnsActive = true, privateDnsName = "dns.example")))
        assertFalse(tracker.isDnsOnlyChange("wifi", changed.copy(mtu = 1400)))
        assertFalse(tracker.isDnsOnlyChange("wifi", changed.copy(routes = listOf("new default"))))
        assertFalse(tracker.isDnsOnlyChange("wifi", changed.copy(addresses = listOf("192.0.2.2/24"))))
        assertFalse(tracker.isDnsOnlyChange("cell", changed))
        tracker.markLost("wifi")
        assertFalse(tracker.isDnsOnlyChange("wifi", changed))
        assertTrue(tracker.update("wifi", path = changed))
    }

    @Test
    fun `suspended path resumes on the same network`() {
        val tracker = NetworkHandoverTracker<String>()
        val path = NetworkPath("wlan0", emptyList(), emptyList(), emptyList(), false, null)
        assertFalse(tracker.update("wifi", path = path))
        assertFalse(tracker.update(null))
        assertTrue(tracker.update("wifi", path = path))
        assertFalse(tracker.update("wifi", path = path))
    }

    @Test
    fun `lost current path stays invalid while replacement is incomplete`() {
        val tracker = NetworkHandoverTracker<String>()
        assertFalse(tracker.update("wifi"))
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
