package com.follow.clash.service

import android.net.ConnectivityManager
import android.net.LinkProperties
import android.net.Network
import android.net.NetworkCapabilities
import android.net.NetworkCapabilities.TRANSPORT_SATELLITE
import android.net.NetworkCapabilities.TRANSPORT_USB
import android.net.NetworkRequest
import android.os.Build
import android.os.Handler
import android.os.HandlerThread
import android.os.SystemClock
import androidx.core.content.getSystemService
import com.follow.clash.common.GlobalState
import com.follow.clash.core.Core
import java.net.Inet4Address
import java.net.Inet6Address
import java.net.InetAddress
import java.util.concurrent.ConcurrentHashMap

private data class NetworkInfo(
    @Volatile var losingUntilMillis: Long = 0,
    @Volatile var dnsList: List<InetAddress>? = null,
    @Volatile var capabilities: NetworkCapabilities? = null,
)

// Outlives every service run: the Core also tests delays and updates providers
// while stopped, and a `system` nameserver has no upstream until DNS arrives here.
object NetworkObserver {

    private val networkInfos = ConcurrentHashMap<Network, NetworkInfo>()
    private val connectivity by lazy {
        GlobalState.application.getSystemService<ConnectivityManager>()
    }
    private val handler by lazy {
        Handler(HandlerThread("NetworkObserve").apply { start() }.looper)
    }
    private var currentDnsList = listOf<String>()
    private val handover = NetworkHandoverTracker<Network>()
    private var started = false

    private val request = NetworkRequest.Builder().apply {
        addCapability(NetworkCapabilities.NET_CAPABILITY_NOT_VPN)
        addCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            addCapability(NetworkCapabilities.NET_CAPABILITY_FOREGROUND)
        }
        addCapability(NetworkCapabilities.NET_CAPABILITY_NOT_RESTRICTED)
    }.build()

    private val callback = object : ConnectivityManager.NetworkCallback() {
        override fun onAvailable(network: Network) {
            networkInfos.putIfAbsent(network, NetworkInfo())
            scheduleUpdateDns()
        }

        override fun onLosing(network: Network, maxMsToLive: Int) {
            val info = networkInfos[network] ?: return
            info.losingUntilMillis = SystemClock.elapsedRealtime() + maxMsToLive
            scheduleUpdateDns()
            if (maxMsToLive > 0) {
                handler.postDelayed({
                    if (networkInfos.containsKey(network)) {
                        updateDns()
                    }
                }, maxMsToLive.toLong() + 50)
            }
        }

        override fun onLost(network: Network) {
            networkInfos.remove(network)
            handler.post { handover.markLost(network) }
            scheduleUpdateDns()
        }

        override fun onCapabilitiesChanged(network: Network, capabilities: NetworkCapabilities) {
            networkInfos[network]?.capabilities = capabilities
            scheduleUpdateDns()
        }

        override fun onLinkPropertiesChanged(network: Network, linkProperties: LinkProperties) {
            networkInfos[network]?.dnsList = linkProperties.dnsServers
            scheduleUpdateDns()
        }
    }

    private val updateDnsTask = Runnable(::updateDns)

    // A switch arrives as a burst, and a network that just came up has no DNS
    // until its link properties follow; the Core flushes its cache per list.
    private fun scheduleUpdateDns() {
        handler.removeCallbacks(updateDnsTask)
        handler.postDelayed(updateDnsTask, DNS_UPDATE_DELAY_MILLIS)
    }

    @Synchronized
    fun start() {
        if (started) return
        runCatching { requireNotNull(connectivity).registerNetworkCallback(request, callback) }
            .onSuccess { started = true }
            .onFailure { error -> GlobalState.log("Unable to observe networks: $error") }
    }

    private fun networkPriority(entry: Map.Entry<Network, NetworkInfo>): Int? {
        val info = entry.value
        val capabilities = info.capabilities ?: connectivity?.getNetworkCapabilities(entry.key)
            ?: return null
        if (capabilities.hasTransport(NetworkCapabilities.TRANSPORT_VPN)) return null
        val transport = when {
            capabilities.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) -> 0
            capabilities.hasTransport(NetworkCapabilities.TRANSPORT_ETHERNET) -> 1
            Build.VERSION.SDK_INT >= Build.VERSION_CODES.S &&
                capabilities.hasTransport(TRANSPORT_USB) -> 2

            capabilities.hasTransport(NetworkCapabilities.TRANSPORT_BLUETOOTH) -> 3
            capabilities.hasTransport(NetworkCapabilities.TRANSPORT_CELLULAR) -> 4
            Build.VERSION.SDK_INT >= Build.VERSION_CODES.VANILLA_ICE_CREAM &&
                capabilities.hasTransport(TRANSPORT_SATELLITE) -> 5

            else -> 20
        }
        return networkSelectionPriority(
            transportPriority = transport,
            validated = capabilities.hasCapability(NetworkCapabilities.NET_CAPABILITY_VALIDATED),
            hasDns = info.dnsList?.isNotEmpty() == true,
            losing = info.losingUntilMillis > SystemClock.elapsedRealtime(),
        )
    }

    @Synchronized
    private fun updateDns() {
        val preferred = networkInfos.entries.mapNotNull { entry ->
            networkPriority(entry)?.let { priority -> entry to priority }
        }.minWithOrNull(compareBy(
            { it.second },
            { if (it.first.key == handover.current) 0 else 1 },
            { it.first.key.networkHandle },
        ))?.first
        // onAvailable can precede onLinkPropertiesChanged by more than the
        // debounce interval. Unknown DNS is not an explicitly empty DNS list.
        val servers = preferred?.let { entry ->
            entry.value.dnsList ?: connectivity?.getLinkProperties(entry.key)?.dnsServers
        }
        if (preferred != null && servers == null) {
            // Keep waiting for the new network's link properties. If the old
            // network was lost, do not keep using its system DNS addresses.
            handover.update(preferred.key, dnsReady = false)
            if (handover.current == null) publishDns(emptyList())
            return
        }

        publishDns(servers.orEmpty().map { it.asSocketAddressText(DNS_PORT) }.distinct())
        // updateDNS is synchronous, so the new servers are installed before
        // the Core releases old sockets and rebuilds the active outbounds.
        if (handover.update(preferred?.key)) {
            Core.resetNetwork()
        }
    }

    private fun publishDns(servers: List<String>) {
        if (servers == currentDnsList) return
        Core.updateDNS(servers.joinToString(","))
        currentDnsList = servers
    }
}

private const val DNS_PORT = 53
private const val DNS_UPDATE_DELAY_MILLIS = 200L

private fun InetAddress.asSocketAddressText(port: Int): String = when (this) {
    is Inet6Address -> "[$hostAddress]:$port"
    is Inet4Address -> "$hostAddress:$port"
    else -> error("Unsupported address type: ${javaClass.name}")
}
