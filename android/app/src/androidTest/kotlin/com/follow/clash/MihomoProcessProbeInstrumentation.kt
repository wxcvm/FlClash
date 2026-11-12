package com.follow.clash

import android.app.Activity
import android.app.Instrumentation
import android.os.Bundle
import android.os.Process
import com.follow.clash.service.MihomoProcessProbeControl
import org.json.JSONObject

/** ARM64 device test. Does not start a VPN or load Mihomo in the test process. */
class MihomoProcessProbeInstrumentation : Instrumentation() {
    override fun onCreate(arguments: Bundle?) {
        super.onCreate(arguments)
        start()
    }

    override fun onStart() {
        val result = Bundle()
        try {
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
            result.putString("stream", "PASS: actual Mihomo JNI RPC, quickSetup, event subscription, separate PIDs and process restart\n")
            finish(Activity.RESULT_OK, result)
        } catch (error: Throwable) {
            result.putString("stream", "FAIL: ${error.stackTraceToString()}\n")
            finish(Activity.RESULT_CANCELED, result)
        }
    }
}
