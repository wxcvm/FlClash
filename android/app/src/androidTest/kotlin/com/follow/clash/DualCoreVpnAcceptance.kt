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
import javax.net.ssl.SSLSocket
import javax.net.ssl.SSLSocketFactory
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlin.coroutines.resumeWithException
import kotlin.coroutines.resume
import org.json.JSONArray
import org.json.JSONObject

/** Explicitly opt-in, app-only, real forwarding test of the production controller. */
internal class DualCoreVpnAcceptance(private val runner: Instrumentation) {
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
                "address":["172.19.0.1/30"],"auto_route":true,"dns_mode":"disabled",
                "route_address":["1.1.1.1/32"],"stack":"system"}],
                "outbounds":[{"type":"direct","tag":"direct"}],
                "route":{"auto_detect_interface":true,"final":"direct"}}
            """.trimIndent()).apply {
                getJSONArray("inbounds").getJSONObject(0).put("include_package", JSONArray(listOf(packageName)))
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
                withTimeout(180_000) {
                    val state = SharedState(vpnOptions = options, setupParams = JsonParser.parseString(setup.toString()).asJsonObject)
                    ServiceState.syncSharedState(state)
                    check(ServiceController.quickSetup(
                        ServiceStateMachine.initParams(home.path, Build.VERSION.SDK_INT), setup.toString(),
                    ).getOrThrow().isEmpty()) { "Initial Mihomo setup failed" }
                    check(ServiceState.requestStart().await()) { "Initial Mihomo VPN failed" }
                    phase("mihomo-initial", "198.18.0.1", ":mihomo", ":singbox")
                    repeat(2) { round ->
                        val started = ServiceState.requestNativeStart(native).await()
                        check(started.started) { "Native handoff failed: ${started.error}" }
                        check(ServiceController.mihomoSuspended)
                        val blocked = JSONObject(rpc("""{"id":"blocked","method":"core.initialized"}"""))
                        check(blocked.getJSONObject("error").getString("code") == "core_unavailable")
                        phase("singbox-${round + 1}", "172.19.0.1", ":singbox", ":mihomo")
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
        val latency = https(requireNotNull(vpn(address)), address)
        val samples = JSONArray()
        repeat(3) {
            samples.put(pss())
            SystemClock.sleep(1000)
        }
        val report = JSONObject().put("phase", name).put("tlsMs", latency).put("samples", samples)
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
                tls.outputStream.write("HEAD / HTTP/1.1\\r\\nHost: cloudflare-dns.com\\r\\nConnection: close\\r\\n\\r\\n".toByteArray())
                tls.outputStream.flush()
                val line = tls.inputStream.bufferedReader().readLine()
                check(line != null && Regex("HTTP/1\\.[01] [1-5][0-9]{2}.*").matches(line)) { "Invalid HTTPS response" }
            }
        }
        return SystemClock.elapsedRealtime() - started
    }
}
