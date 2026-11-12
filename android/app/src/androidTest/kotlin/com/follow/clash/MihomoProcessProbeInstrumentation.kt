package com.follow.clash

import android.app.Activity
import android.app.Instrumentation
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.ServiceConnection
import android.os.IBinder
import android.os.Bundle
import android.os.Process
import com.follow.clash.service.MihomoProcessProbeControl
import com.follow.clash.service.MihomoCoreControl
import com.follow.clash.service.VpnService
import com.follow.clash.service.MihomoServiceControl
import com.follow.clash.service.ProxyService
import com.follow.clash.service.models.NotificationParams
import com.follow.clash.service.models.VpnOptions
import com.follow.clash.service.models.AccessControlProps
import com.follow.clash.common.AccessControlMode
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicReference
import org.json.JSONObject
import java.io.File

/** ARM64 device test. Does not start a VPN or load Mihomo in the test process. */
class MihomoProcessProbeInstrumentation : Instrumentation() {
    private var live = false
    private var handover = false
    override fun onCreate(arguments: Bundle?) {
        live = arguments?.getString("liveVpn") == "true"
        handover = arguments?.getString("handover") == "true"
        super.onCreate(arguments)
        start()
    }

    private fun verifyProductionLifecycleBinder(expectedPid: Int, serviceClass: Class<*>) {
        val ready = CountDownLatch(1)
        val binder = AtomicReference<IBinder>()
        val context = targetContext
        val connection = object : ServiceConnection {
            override fun onServiceConnected(name: ComponentName, service: IBinder) {
                binder.set(service)
                ready.countDown()
            }
            override fun onServiceDisconnected(name: ComponentName) { ready.countDown() }
        }
        val intent = Intent(context, serviceClass).apply {
            action = MihomoServiceControl.ACTION
        }
        check(context.bindService(intent, connection, Context.BIND_AUTO_CREATE))
        var original: NotificationParams? = null
        try {
            check(ready.await(10, TimeUnit.SECONDS))
            val remote = requireNotNull(binder.get())
            check(MihomoServiceControl.pid(remote) == expectedPid) { "VPN/Proxy and Core must share the same PID" }
            original = MihomoServiceControl.notification(remote)
            check(MihomoServiceControl.canHandoff(remote))
            val changed = NotificationParams(title = "Mihomo IPC test", showStopAction = false)
            MihomoServiceControl.updateNotification(remote, changed)
            check(MihomoServiceControl.notification(remote) == changed)
            // The proxy binder must reject VPN mode before any native start.
            val wrongMode = VpnOptions(
                enable = serviceClass != VpnService::class.java, port = 0, ipv6 = false, dnsHijacking = false,
                accessControlProps = AccessControlProps(false, AccessControlMode.ACCEPT_SELECTED, emptyList(), emptyList()),
                allowBypass = false, systemProxy = false, bypassDomain = emptyList(),
                stack = "system", routeAddress = emptyList(),
            )
            check(runCatching {
                MihomoServiceControl.start(context, remote, wrongMode, changed)
            }.exceptionOrNull()?.message?.contains("mode does not match") == true)
            MihomoServiceControl.stop(remote)
        } finally {
            try {
                original?.let { value -> binder.get()?.let { MihomoServiceControl.updateNotification(it, value) } }
            } finally {
                context.unbindService(connection)
            }
        }
    }

    private fun awaitCore(start: ((Result<ByteArray>) -> Unit) -> Unit): ByteArray {
        val done = CountDownLatch(1)
        val value = AtomicReference<Result<ByteArray>>()
        start { value.set(it); done.countDown() }
        check(done.await(30, TimeUnit.SECONDS)) { "Production Core response timed out" }
        return requireNotNull(value.get()).getOrThrow()
    }

    override fun onStart() {
        val result = Bundle()
        try {
            if (live) {
                DualCoreVpnAcceptance(this, handover).run(result)
                result.putString("stream", "PASS: live dual-core VPN acceptance\\n")
                finish(Activity.RESULT_OK, result)
                return
            }
            val hostPid = Process.myPid()
            if (MihomoCoreControl.enabled(targetContext)) {
                MihomoCoreControl.connect(targetContext).use { core ->
                    check(core.pid != hostPid)
                    verifyProductionLifecycleBinder(core.pid, ProxyService::class.java)
                    verifyProductionLifecycleBinder(core.pid, VpnService::class.java)
                    val response = awaitCore { callback ->
                        core.invoke("""{"id":"production","method":"core.initialized"}""", callback)
                    }
                    check(JSONObject(response.decodeToString()).getString("id") == "production")
                    // Same actual command, with padding to exercise descriptor fallback.
                    val largeRequest = JSONObject().put("id", "large").put("method", "core.initialized")
                        .put("arguments", JSONObject().put("padding", "x".repeat(64 * 1024)))
                    val largeResponse = awaitCore { core.invoke(largeRequest.toString(), it) }
                    check(JSONObject(largeResponse.decodeToString()).getString("id") == "large")
                    val home = File(targetContext.cacheDir, "mihomo-production-test").apply { mkdirs() }
                    val profile = File(home, "probe.yaml").apply {
                        writeText("mixed-port: 0\nport: 0\nsocks-port: 0\nmode: rule\ndns:\n  enable: false\ntun:\n  enable: false\nproxies: []\nproxy-groups: []\nrules:\n  - MATCH,DIRECT\n")
                    }
                    val init = JSONObject().put("home-dir", home.path).put("version", 1)
                    val setup = JSONObject().put("base", JSONObject().put("path", profile.path).put("overlay", ""))
                        .put("selected-map", JSONObject()).put("options", JSONObject())
                    check(awaitCore { core.quickSetup(init.toString(), setup.toString(), it) }.decodeToString().isEmpty())
                    val initialized = awaitCore { core.invoke("""{"id":"ready","method":"core.initialized"}""", it) }
                    check(JSONObject(initialized.decodeToString()).getBoolean("result"))
                    core.setEvents { }
                    core.setListener(false)
                    core.setEvents(null)
                    result.putInt("productionMihomoPid", core.pid)
                    core.retire()
                    check(!core.alive) { "Mihomo retirement did not close the original Binder" }
                }
                MihomoCoreControl.connect(targetContext).use { next ->
                    check(next.pid != result.getInt("productionMihomoPid"))
                    val reply = awaitCore { next.invoke("""{"id":"restart","method":"core.initialized"}""", it) }
                    check(JSONObject(reply.decodeToString()).getString("id") == "restart")
                    next.retire()
                }
            } else verifyProductionLifecycleBinder(hostPid, ProxyService::class.java)
            var firstPid = 0
            repeat(2) { attempt ->
                MihomoProcessProbeControl.connect(targetContext).use { core ->
                    check(core.pid != hostPid) { "Mihomo loaded in host process" }
                    if (attempt == 0) firstPid = core.pid
                    else check(core.pid != firstPid) { "Old native process was reused" }
                    val request = JSONObject().put("id", "probe-$attempt")
                        .put("method", "core.initialized").put("arguments", JSONObject())
                    val response = JSONObject(core.invoke(request.toString()).decodeToString())
                    check(response.getString("id") == "probe-$attempt" && response.isNull("error"))
                    check(response.get("result") is Boolean)
                    core.setEventListener { /* callbacks arrive through private Binder */ }
                    val logStart = JSONObject(core.invoke("""{"id":"log","method":"log.start"}""").decodeToString())
                    check(logStart.isNull("error"))
                    check(core.quickSetup().isEmpty()) { "Mihomo quickSetup failed" }
                    val initialized = JSONObject(core.invoke("""{"id":"init","method":"core.initialized"}""").decodeToString())
                    check(initialized.getBoolean("result"))
                    core.setEventListener(null)
                    val memory = JSONObject(core.invoke(
                        """{"id":"memory","method":"core.memory"}""",
                    ).decodeToString())
                    check(memory.getString("id") == "memory" && memory.isNull("error"))
                    check(memory.has("result"))
                    result.putInt("nativePid$attempt", core.pid)
                }
            }
            result.putString("stream", "PASS: production lifecycle Binder, actual Mihomo JNI RPC, quickSetup, event subscription, separate PIDs and process restart\n")
            finish(Activity.RESULT_OK, result)
        } catch (error: Throwable) {
            result.putString("stream", "FAIL: ${error.stackTraceToString()}\n")
            finish(Activity.RESULT_CANCELED, result)
        }
    }
}
