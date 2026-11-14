package com.follow.clash.service

// Prefer a usable network over a faster transport. Keep an unvalidated network
// as a fallback when validation is blocked or no validated network exists.
internal fun networkSelectionPriority(
    transportPriority: Int,
    validated: Boolean,
    hasDns: Boolean,
    losing: Boolean,
): Int = transportPriority +
    (if (validated) 0 else 40) +
    (if (hasDns) 0 else 25) +
    (if (losing) 100 else 0)

internal data class NetworkPath(
    val interfaceName: String?,
    val addresses: List<String>,
    val routes: List<String>,
    val dns: List<String>,
    val privateDnsActive: Boolean,
    val privateDnsName: String?,
    val mtu: Int = 0,
)

// Runs on the NetworkObserver handler. Do not reset the core on initial
// availability or repeatedly while offline; reset once when service returns.
internal class NetworkHandoverTracker<T : Any> {
    var current: T? = null
        private set
    private var seenNetwork = false
    private var currentPath: NetworkPath? = null

    // DNS policy/server changes on an unchanged data path must not close
    // established TCP transfers. A returning or different network still needs
    // full recovery, even if its interface name and addresses are identical.
    fun isDnsOnlyChange(next: T?, path: NetworkPath?): Boolean {
        val previous = currentPath ?: return false
        if (next == null || current != next || path == null || path == previous) return false
        return path.copy(
            dns = previous.dns,
            privateDnsActive = previous.privateDnsActive,
            privateDnsName = previous.privateDnsName,
        ) == previous
    }

    fun markLost(network: T) {
        if (current == network) {
            current = null
            currentPath = null
        }
    }

    fun update(next: T?, dnsReady: Boolean = true, path: NetworkPath? = null): Boolean {
        // Do not commit to a network before its link properties are known.
        // In particular, a later DNS callback must still trigger recovery.
        if (next != null && !dnsReady) return false
        if (next == null) {
            current = null
            currentPath = null
            return false
        }
        val reset = seenNetwork && (current != next || currentPath != path)
        current = next
        currentPath = path
        seenNetwork = true
        return reset
    }
}
