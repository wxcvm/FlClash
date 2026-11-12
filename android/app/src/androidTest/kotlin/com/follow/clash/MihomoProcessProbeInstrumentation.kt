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
import com.follow.clash.service.MihomoServiceControl
import com.follow.clash.service.ProxyService
import com.follow.clash.service.ServiceConfig
import com.follow.clash.service.models.NotificationParams
import com.follow.clash.service.models.VpnOptions
import com.follow.clash.service.models.AccessControlProps
import com.follow.clash.common.AccessControlMode
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicReference
import org.json.JSONObject

/** ARM64 device test. Does not start a VPN or load Mihomo in the test process. */
class MihomoProcessProbeInstrumentation : Instrumentation() {
    override fun onCreate(arguments: Bundle?) {
        super.onCreate(arguments)
        start()
    }

    private fun verifyProductionLifecycleBinder() {
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
        val intent = Intent(context, ProxyService::class.java).apply {
            action = MihomoServiceControl.ACTION
        }
        check(context.bindService(intent, connection, Context.BIND_AUTO_CREATE))
        val original = ServiceConfig.notificationParams.value
        try {
            check(ready.await(10, TimeUnit.SECONDS))
            val remote = requireNotNull(binder.get())
            check(MihomoServiceControl.pid(remote) == Process.myPid())
            check(MihomoServiceControl.canHandoff(remote))
            val changed = NotificationParams(title = "Mihomo IPC test", showStopAction = false)
            MihomoServiceControl.updateNotification(remote, changed)
            check(ServiceConfig.notificationParams.value == changed)
            // The proxy binder must reject VPN mode before any native start.
            val wrongMode = VpnOptions(
                enable = true, port = 0, ipv6 = false, dnsHijacking = false,
                accessControlProps = AccessControlProps(false, AccessControlMode.ACCEPT_SELECTED, emptyList(), emptyList()),
                allowBypass = false, systemProxy = false, bypassDomain = emptyList(),
                stack = "system", routeAddress = emptyList(),
            )
            check(runCatching {
                MihomoServiceControl.start(context, remote, wrongMode, changed)
            }.exceptionOrNull()?.message?.contains("mode does not match") == true)
            MihomoServiceControl.stop(remote)
        } finally {
            ServiceConfig.updateNotificationParams(original)
            context.unbindService(connection)
        }
    }

    override fun onStart() {
        val result = Bundle()
        try {
            verifyProductionLifecycleBinder()
            val hostPid = Process.myPid()
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
