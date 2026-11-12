package com.follow.clash.service

import android.content.Intent
import android.content.pm.PackageManager
import android.net.ConnectivityManager
import android.net.ProxyInfo
import android.os.Binder
import android.os.Build
import android.os.IBinder
import android.os.Handler
import android.os.Looper
import androidx.core.app.NotificationCompat
import com.follow.clash.common.ensureNotificationChannel
import com.follow.clash.common.startForeground
import com.follow.clash.common.Components
import com.follow.clash.common.toPendingIntent
import androidx.core.content.getSystemService
import com.follow.clash.common.AccessControlMode
import com.follow.clash.common.GlobalState
import com.follow.clash.common.R as CommonR
import com.follow.clash.service.models.CIDR
import com.follow.clash.service.models.VpnOptions
import com.follow.clash.service.models.getIpv4RouteAddress
import com.follow.clash.service.models.getIpv6RouteAddress
import com.follow.clash.service.models.toCIDR
import com.follow.clash.service.models.tunMtu
import com.follow.clash.service.models.tunOptions
import com.follow.clash.service.modules.ServiceModules
import java.net.InetSocketAddress
import java.util.concurrent.ConcurrentHashMap
import android.net.VpnService as SystemVpnService

class VpnService : SystemVpnService(), ManagedService {
    private val modules = ServiceModules(this)
    private val binder = LocalBinder()
    private val control = MihomoServiceControl.binder(this, vpn = true) {
        Build.VERSION.SDK_INT < 29 || (!isAlwaysOn && !isLockdownEnabled)
    }
    private val tunnel = TunnelSession(MihomoTunnelEngine)
    private val main = Handler(Looper.getMainLooper())
    @Volatile private var established = false
    private var startupTimeout: Runnable? = null
    private var startupRetry: Runnable? = null

    override fun onCreate() {
        super.onCreate()
        MihomoProcessLifecycle.register(this)
    }

    override fun onDestroy() {
        startupTimeout?.let(main::removeCallbacks)
        startupRetry?.let(main::removeCallbacks)
        startupTimeout = null
        startupRetry = null
        try {
            MihomoProcessLifecycle.stop(this) { cleanup() }
        } finally {
            MihomoProcessLifecycle.unregister(this)
            super.onDestroy()
        }
    }

    private val connectivity by lazy {
        getSystemService<ConnectivityManager>()
    }
    private val uidPackageNameMap = ConcurrentHashMap<Int, String>()

    private fun resolveUid(
        protocol: Int,
        source: InetSocketAddress,
        target: InetSocketAddress,
    ): Int {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) {
            return -1
        }
        return connectivity?.getConnectionOwnerUid(protocol, source, target) ?: -1
    }

    private fun resolvePackage(uid: Int): String {
        val cached = uidPackageNameMap[uid]
        if (cached != null) return cached
        val packageName = packageManager
            .getPackagesForUid(uid)
            ?.firstOrNull()
            ?.takeIf { it.isNotEmpty() }
            .orEmpty()
        return uidPackageNameMap.putIfAbsent(uid, packageName) ?: packageName
    }

    private val VpnOptions.tunAddress
        get(): String = buildString {
            append(IPV4_ADDRESS)
            if (ipv6) {
                append(",")
                append(IPV6_ADDRESS)
            }
        }

    private val VpnOptions.tunDns
        get(): String {
            if (dnsHijacking) {
                return NET_ANY
            }
            return buildString {
                append(DNS)
                if (ipv6) {
                    append(",")
                    append(DNS6)
                }
            }
        }

    override fun onLowMemory() {
        lowCoreMemory()
        super.onLowMemory()
    }

    override fun onTrimMemory(level: Int) {
        trimCoreMemory(level)
        super.onTrimMemory(level)
    }

    inner class LocalBinder : Binder() {
        val service: VpnService
            get() = this@VpnService
    }

    override fun onBind(intent: Intent): IBinder? =
        if (intent.action == SystemVpnService.SERVICE_INTERFACE) {
            super.onBind(intent)
        } else if (intent.action == MihomoServiceControl.ACTION) {
            control
        } else {
            binder
        }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        // Android starts always-on VPN through this callback instead of FlClash's bound-service
        // path. Notify the app layer so it can restore Core and fully initialize the VPN service.
        if (!established) {
            // The system may start this process before Flutter exists. Promote
            // immediately; the normal notification module replaces this on start.
            ensureNotificationChannel()
            startForeground(NotificationCompat.Builder(this, GlobalState.NOTIFICATION_CHANNEL)
                .setSmallIcon(com.follow.clash.service.R.drawable.ic_service)
                .setContentTitle("FlClash")
                .setContentText("Restoring VPN configuration…")
                .setContentIntent(Intent().setComponent(Components.mainActivity).toPendingIntent)
                .setOngoing(true)
                .setOnlyAlertOnce(true)
                .build())
            startupTimeout?.let(main::removeCallbacks)
            startupTimeout = Runnable {
                if (!established) {
                    GlobalState.log("System VPN restore timed out")
                    stopSelf(startId)
                }
            }.also { main.postDelayed(it, 90_000L) }
            notifyVpnStartRequested()
            // A replacement service may report before the controller has
            // processed old Binder death. One delayed notification closes
            // that window; the state machine deduplicates pending starts.
            startupRetry?.let(main::removeCallbacks)
            startupRetry = Runnable {
                if (!established && Build.VERSION.SDK_INT >= 29 && isAlwaysOn) {
                    notifyVpnStartRequested()
                }
            }.also { main.postDelayed(it, 5_000L) }
        }
        return super.onStartCommand(intent, flags, startId)
    }

    override fun onRevoke() {
        stop()
        notifyVpnRevoked()
    }

    private fun handleStart(options: VpnOptions) {
        val stack = options.stack
        val address = options.tunAddress
        val dns = options.tunDns
        val tunOptions = options.tunOptions
        tunnel.start {
            val fd = with(Builder()) {
                addAddressAndRoutes(options)
                addDnsServers(options)
                setMtu(options.tunMtu)
                configureAccessControl(options)
                setSession(getString(CommonR.string.app_name))
                setBlocking(false)
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                    setMetered(false)
                }
                if (options.allowBypass) {
                    allowBypass()
                }
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q && options.systemProxy) {
                    GlobalState.log("Enable VPN HTTP proxy")
                    setHttpProxy(
                        ProxyInfo.buildDirectProxy(
                            LOCAL_HOST,
                            options.port,
                            options.bypassDomain,
                        ),
                    )
                }
                establish()?.detachFd()
                    ?: error("VPN establishment was rejected by the system")
            }
            // The selected engine takes ownership of the detached descriptor.
            TunnelRequest(
                fd = fd,
                protect = this::protect,
                resolveUid = this::resolveUid,
                resolvePackage = this::resolvePackage,
                stack = stack,
                address = address,
                dns = dns,
                options = tunOptions,
            )
        }
    }

    private fun Builder.addAddressAndRoutes(options: VpnOptions) {
        val ipv4Address = IPV4_ADDRESS.toCIDR()
        addAddress(ipv4Address.address, ipv4Address.prefixLength)
        addRoutes(
            routes = options::getIpv4RouteAddress,
            fallbackAddress = NET_ANY,
            routeAll = options.routeAddress.isEmpty(),
        )

        if (options.ipv6) {
            try {
                val ipv6Address = IPV6_ADDRESS.toCIDR()
                addAddress(ipv6Address.address, ipv6Address.prefixLength)
            } catch (_: Exception) {
                GlobalState.log("IPv6 VPN address is not supported")
            }
            addRoutes(
                routes = options::getIpv6RouteAddress,
                fallbackAddress = NET_ANY6,
                routeAll = options.routeAddress.isEmpty(),
            )
        }
    }

    // Flutter lists every family it routes, so a family missing from a
    // non-empty list is one whose routes were all excluded.
    private fun Builder.addRoutes(
        routes: () -> List<CIDR>,
        fallbackAddress: String,
        routeAll: Boolean,
    ) {
        val routeList = runCatching(routes).getOrNull()
        if (routeAll || routeList == null) {
            addRoute(fallbackAddress, 0)
            return
        }
        try {
            routeList.forEach { route ->
                addRoute(route.address, route.prefixLength)
            }
        } catch (_: Exception) {
            addRoute(fallbackAddress, 0)
        }
    }

    private fun Builder.addDnsServers(options: VpnOptions) {
        addDnsServer(DNS)
        if (options.ipv6) {
            addDnsServer(DNS6)
        }
    }

    private fun Builder.configureAccessControl(options: VpnOptions) {
        val accessControl = options.accessControlProps
        if (!accessControl.enable) return
        when (accessControl.mode) {
            AccessControlMode.ACCEPT_SELECTED -> {
                (accessControl.acceptList + packageName).forEach { name ->
                    addApplication(name, ::addAllowedApplication)
                }
            }

            AccessControlMode.REJECT_SELECTED -> {
                (accessControl.rejectList - packageName).forEach { name ->
                    addApplication(name, ::addDisallowedApplication)
                }
            }
        }
    }

    // A selected package that was uninstalled since must not veto the whole tunnel.
    private fun addApplication(name: String, add: (String) -> Builder) {
        try {
            add(name)
        } catch (_: PackageManager.NameNotFoundException) {
            GlobalState.log("Access control skipped an uninstalled package: $name")
        }
    }

    override fun start() = MihomoProcessLifecycle.start(this) {
        try {
            modules.start()
            handleStart(requireNotNull(ServiceConfig.vpnOptions) { "VPN options are missing" })
            established = true
            startupRetry?.let(main::removeCallbacks)
            startupTimeout?.let(main::removeCallbacks)
        } catch (error: Exception) {
            stop()
            throw error
        }
    }

    override fun stop() {
        try {
            MihomoProcessLifecycle.stop(this) { cleanup() }
        } finally {
            stopSelf()
        }
    }

    private fun cleanup() {
        established = false
        try {
            modules.stop()
        } finally {
            stopTun()
        }
    }

    private fun stopTun() = tunnel.stop()

    companion object {
        // mihomo's own TUN default: 198.18.0.0/15 is benchmarking space no LAN
        // uses, and its fake-ip pool starts at .4, past this /30.
        private const val IPV4_ADDRESS = "198.18.0.1/30"
        private const val IPV6_ADDRESS = "fdfe:dcba:9876::1/126"
        private const val DNS = "198.18.0.2"
        private const val DNS6 = "fdfe:dcba:9876::2"
        private const val NET_ANY = "0.0.0.0"
        private const val NET_ANY6 = "::"
        private const val LOCAL_HOST = "127.0.0.1"
    }
}
