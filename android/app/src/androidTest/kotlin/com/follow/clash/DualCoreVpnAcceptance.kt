package com.follow.clash

import android.app.ActivityManager
import android.app.Instrumentation
import android.content.Context
import android.content.Intent
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.net.VpnService
import android.os.Build
import android.os.Bundle
import android.os.Process
import android.os.SystemClock
import com.follow.clash.common.AccessControlMode
import com.follow.clash.models.SharedState
import com.follow.clash.service.MihomoCoreControl
import com.follow.clash.service.SingBoxVpnControl
import com.follow.clash.service.models.AccessControlProps
import com.follow.clash.service.models.VpnOptions
import com.google.gson.JsonParser
import java.io.File
import java.net.InetSocketAddress
import java.net.DatagramSocket
import java.net.DatagramPacket
import java.net.InetAddress
import java.util.concurrent.ThreadLocalRandom
import javax.net.ssl.SSLSocket
import javax.net.ssl.SSLSocketFactory
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlin.coroutines.resumeWithException
import org.json.JSONArray
import org.json.JSONObject

/** Explicitly opt-in, app-only, real forwarding test of the production controller. */
internal class DualCoreVpnAcceptance(private val runner: Instrumentation, private val handover: Boolean,
    private val nativeProxy: Boolean, private val soakSeconds: Int) {
    private val context = runner.targetContext
    private val cm = context.getSystemService(ConnectivityManager::class.java)
    private val am = context.getSystemService(ActivityManager::class.java)
    private val packageName = context.packageName
    private val reports = JSONArray()

    fun run(result: Bundle) {
        check(packageName.endsWith(".dev")) { "Use the separate debug application" }
        check(MihomoCoreControl.enabled(context) && SingBoxVpnControl.isAvailable(context)) {
            "Install the isolated dual-core APK"
        }
        check(VpnService.prepare(context) == null) { "Grant VPN consent to FlClash Debug first, then stop its VPN" }
        check(cm.allNetworks.none { cm.getNetworkCapabilities(it)?.hasTransport(NetworkCapabilities.TRANSPORT_VPN) == true }) {
            "Stop every existing VPN first"
        }
        require(soakSeconds in 0..120)
        val outbound = if (nativeProxy) readNativeOutbound() else JSONObject().put("type", "direct").put("tag", "acceptance-egress")
        val activity = runner.startActivitySync(Intent().setClassName(context, "com.follow.clash.VpnAcceptanceActivity")
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
        runner.waitForIdleSync()
        val home = File(context.cacheDir, "dual-core-acceptance").apply { mkdirs() }
        val profile = File(home, "mihomo.yaml").apply {
            writeText("""
                mixed-port: 0
                port: 0
                socks-port: 0
                mode: rule
                log-level: warning
                dns:
                  enable: false
                tun:
                  enable: false
                proxies: []
                proxy-groups: []
                rules:
                  - MATCH,DIRECT
            """.trimIndent())
        }
        val native = File(home, "singbox.json").apply {
            writeText(JSONObject("""
                {"log":{"level":"warn"},"inbounds":[{"type":"tun","tag":"acceptance",
                "address":["172.19.0.1/30"],"auto_route":true,"dns_mode":"hijack","dns_address":["172.19.0.2"],
                "route_address":["1.1.1.1/32","172.19.0.2/32"],"stack":"system"}],
                "dns":{"servers":[{"type":"local","tag":"android"}],"final":"android","disable_cache":true},
                "outbounds":[],
                "route":{"auto_detect_interface":true,"default_domain_resolver":"android",
                "rules":[{"port":53,"action":"hijack-dns"}],"final":"acceptance-egress"}}
            """.trimIndent()).apply {
                getJSONArray("inbounds").getJSONObject(0).put("include_package", JSONArray(listOf(packageName)))
                put("outbounds", JSONArray().put(outbound))
            }.toString())
        }
        val options = VpnOptions(
            enable = true, port = 0, ipv6 = false, dnsHijacking = false,
            accessControlProps = AccessControlProps(true, AccessControlMode.ACCEPT_SELECTED, listOf(packageName), emptyList()),
            allowBypass = false, systemProxy = false, bypassDomain = emptyList(),
            stack = "gvisor", routeAddress = listOf("1.1.1.1/32"),
        )
        val setup = JSONObject().put("base", JSONObject().put("path", profile.path).put("overlay", ""))
            .put("selected-map", JSONObject()).put("options", JSONObject())
        try {
            runBlocking {
                withTimeout(480_000) {
                    val state = SharedState(vpnOptions = options, setupParams = JsonParser.parseString(setup.toString()).asJsonObject)
                    ServiceState.syncSharedState(state)
                    check(ServiceController.quickSetup(
                        ServiceStateMachine.initParams(context.filesDir.path, Build.VERSION.SDK_INT), setup.toString(),
                    ).getOrThrow().isEmpty()) { "Initial Mihomo setup failed" }
                    check(ServiceState.requestStart().await()) { "Initial Mihomo VPN failed" }
                    phase("mihomo-initial", "198.18.0.1", ":mihomo", ":singbox")
                    repeat(2) { round ->
                        val started = ServiceState.requestNativeStart(native).await()
                        check(started.started) { if (nativeProxy) "Native proxy handoff failed; check local device diagnostics" else "Native handoff failed: ${started.error}" }
                        check(ServiceController.mihomoSuspended)
                        val blocked = JSONObject(rpc("""{"id":"blocked","method":"core.initialized"}"""))
                        check(blocked.getJSONObject("error").getString("code") == "core_unavailable")
                        phase("singbox-${round + 1}", "172.19.0.1", ":singbox", ":mihomo")
                        if (handover && round == 0) verifyHandover()
                        if (soakSeconds > 0 && round == 0) verifySoak()
                        check(ServiceState.requestMihomoStart().await()) { "Mihomo restore failed" }
                        phase("mihomo-restored-${round + 1}", "198.18.0.1", ":mihomo", ":singbox")
                    }
                    check(ServiceState.requestStop().await()) { "Final VPN stop failed" }
                    waitFor("VPN removal") { vpn("198.18.0.1") == null && vpn("172.19.0.1") == null }
                    reports.put(JSONObject().put("phase", "stopped").put("pss", pss()))
                }
            }
        } finally {
            try {
                runBlocking { withTimeout(15_000) { ServiceState.requestStop().await() } }
            } finally {
                runner.runOnMainSync { activity.finish() }
                result.putString("acceptanceJson", reports.toString())
                // Keep only test measurements, never the user's profile.
                File(context.cacheDir, "dual-core-acceptance.json").writeText(reports.toString(2))
                home.deleteRecursively()
            }
        }
    }

    // A single outbound, not a whole subscription: no selector or direct fallback.
    private fun readNativeOutbound(): JSONObject {
        val file = File(context.cacheDir, "native-acceptance-outbound.json")
        try {
            require(file.isFile && file.length() in 1..(256 * 1024L)) { "Missing or oversized outbound fixture" }
            val value = JSONObject(file.readText())
            val type = value.getString("type")
            require(type in setOf("vless", "vmess", "trojan", "shadowsocks", "hysteria2", "tuic", "socks", "http", "anytls")) {
                "Unsupported single outbound type"
            }
            require(value.optString("server").isNotBlank() && value.optInt("server_port") in 1..65535)
            require(!value.has("detour") && !value.has("outbounds")) { "Chained or group outbounds are not accepted" }
            value.put("tag", "acceptance-egress")
            value.put("domain_resolver", "android")
            return value
        } finally {
            file.delete()
        }
    }

    private fun dns(network: Network): Long {
        val id = ThreadLocalRandom.current().nextInt(65536)
        val query = ProbeDnsMessage.query(id)
        val started = SystemClock.elapsedRealtime()
        DatagramSocket(null).use { socket ->
            network.bindSocket(socket)
            socket.bind(InetSocketAddress(0))
            socket.connect(InetAddress.getByName("172.19.0.2"), 53)
            check(socket.localAddress.hostAddress == "172.19.0.1") { "DNS bypassed native TUN" }
            socket.soTimeout = 8000
            socket.send(DatagramPacket(query, query.size))
            val bytes = ByteArray(4096)
            val answer = DatagramPacket(bytes, bytes.size)
            socket.receive(answer)
            ProbeDnsMessage.verify(bytes, answer.length, id)
        }
        return SystemClock.elapsedRealtime() - started
    }

    private suspend fun verifySoak() {
        val deadline = SystemClock.elapsedRealtime() + soakSeconds * 1000L
        val samples = JSONArray()
        do {
            val network = requireNotNull(vpn("172.19.0.1"))
            samples.put(JSONObject().put("tlsMs", https(network, "172.19.0.1"))
                .put("dnsMs", dns(network)))
            val remaining = deadline - SystemClock.elapsedRealtime()
            if (remaining > 0) kotlinx.coroutines.delay(minOf(10_000L, remaining))
        } while (SystemClock.elapsedRealtime() < deadline)
        val report = JSONObject().put("phase", "singbox-soak").put("durationSeconds", soakSeconds)
            .put("checks", samples)
        reports.put(report)
        runner.sendStatus(0, Bundle().apply { putString("phase", report.toString()) })
    }

    private suspend fun verifyHandover() {
        val before = JSONObject(ServiceController.nativeStatusSnapshot()).getLong("networkGeneration")
        runner.sendStatus(1, Bundle().apply {
            putString("checkpoint", "Switch Wi-Fi to mobile data (or vice versa) now. Restore internet within 60 seconds.")
        })
        val deadline = SystemClock.elapsedRealtime() + 60_000
        var generation = before
        var latency: Long? = null
        var dnsLatency: Long? = null
        while (SystemClock.elapsedRealtime() < deadline && latency == null) {
            try {
                generation = JSONObject(ServiceController.nativeStatusSnapshot()).getLong("networkGeneration")
                if (generation != before) {
                    val network = requireNotNull(vpn("172.19.0.1"))
                    val tls = https(network, "172.19.0.1")
                    dnsLatency = dns(network)
                    latency = tls
                }
            } catch (error: kotlinx.coroutines.CancellationException) {
                throw error
            } catch (_: Exception) {
                // The transition can temporarily have no underlying network.
            }
            if (latency == null) kotlinx.coroutines.delay(1000)
        }
        check(latency != null && generation != before) { "No successful native network handover within 60 seconds" }
        check(ServiceController.mihomoSuspended)
        val report = JSONObject().put("phase", "singbox-network-handover")
            .put("beforeGeneration", before).put("afterGeneration", generation).put("tlsMs", latency).put("dnsMs", dnsLatency)
        reports.put(report)
        runner.sendStatus(0, Bundle().apply { putString("phase", report.toString()) })
    }

    private suspend fun rpc(request: String): String = withTimeout(10_000) {
        suspendCancellableCoroutine { continuation ->
            ServiceController.invokeMethod(request) { response ->
                continuation.resumeWith(response.map { it.decodeToString() })
            }.onFailure { continuation.resumeWithException(it) }
        }
    }

    private fun phase(name: String, address: String, active: String, inactive: String) {
        waitFor("$name process topology") {
            val names = processes().map { it.processName }
            "$packageName$active" in names && "$packageName$inactive" !in names
        }
        waitFor("$name TUN") { vpn(address) != null }
        val network = requireNotNull(vpn(address))
        val latency = https(network, address)
        val dnsLatency = if (active == ":singbox") dns(network) else null
        val samples = JSONArray()
        repeat(3) {
            samples.put(pss())
            SystemClock.sleep(1000)
        }
        val report = JSONObject().put("phase", name).put("tlsMs", latency).put("samples", samples)
        if (dnsLatency != null) report.put("dnsMs", dnsLatency).put("egress", if (nativeProxy) "proxy" else "direct")
        reports.put(report)
        runner.sendStatus(0, Bundle().apply { putString("phase", report.toString()) })
    }

    private fun processes() = am.runningAppProcesses.orEmpty().filter {
        it.uid == Process.myUid() && (it.processName == packageName || it.processName.startsWith("$packageName:"))
    }

    private fun pss(): JSONArray {
        val processes = processes()
        val info = am.getProcessMemoryInfo(processes.map { it.pid }.toIntArray())
        return JSONArray().apply {
            processes.forEachIndexed { index, process ->
                put(JSONObject().put("name", process.processName).put("pid", process.pid)
                    .put("pssKiB", info[index].totalPss))
            }
        }
    }

    private fun waitFor(label: String, ready: () -> Boolean) {
        val deadline = SystemClock.elapsedRealtime() + 10_000
        while (!ready()) {
            check(SystemClock.elapsedRealtime() < deadline) { "Timed out: $label" }
            SystemClock.sleep(100)
        }
    }

    private fun vpn(address: String): Network? = cm.allNetworks.firstOrNull { network ->
        cm.getNetworkCapabilities(network)?.hasTransport(NetworkCapabilities.TRANSPORT_VPN) == true &&
            cm.getLinkProperties(network)?.linkAddresses?.any { it.address.hostAddress == address } == true
    }

    private fun https(network: Network, address: String): Long {
        val started = SystemClock.elapsedRealtime()
        network.socketFactory.createSocket().use { raw ->
            raw.connect(InetSocketAddress("1.1.1.1", 443), 5000)
            check(raw.localAddress.hostAddress == address) { "HTTPS bypassed expected TUN" }
            raw.soTimeout = 5000
            val factory = SSLSocketFactory.getDefault() as SSLSocketFactory
            (factory.createSocket(raw, "cloudflare-dns.com", 443, true) as SSLSocket).use { tls ->
                tls.sslParameters = tls.sslParameters.apply { endpointIdentificationAlgorithm = "HTTPS" }
                tls.soTimeout = 5000
                tls.startHandshake()
                tls.outputStream.write("HEAD / HTTP/1.1\r\nHost: cloudflare-dns.com\r\nConnection: close\r\n\r\n".toByteArray())
                tls.outputStream.flush()
                val line = tls.inputStream.bufferedReader().readLine()
                check(line != null && Regex("HTTP/1\\.[01] [1-5][0-9]{2}.*").matches(line)) { "Invalid HTTPS response" }
            }
        }
        return SystemClock.elapsedRealtime() - started
    }
}
