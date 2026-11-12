package com.follow.clash.plugins

import com.follow.clash.ServiceController
import com.follow.clash.MihomoCoreTransport
import com.follow.clash.ServiceState
import com.follow.clash.common.Components
import com.follow.clash.common.GlobalState
import com.follow.clash.core.Core
import com.follow.clash.models.SharedState
import com.follow.clash.service.NetworkObserver
import com.follow.clash.service.SingBoxVpnControl
import java.io.File
import com.google.gson.Gson
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.StandardMethodCodec
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlinx.coroutines.flow.collect

class ServicePlugin : FlutterPlugin, MethodChannel.MethodCallHandler {
    private lateinit var messenger: BinaryMessenger
    private lateinit var channel: MethodChannel
    private lateinit var coreChannel: MethodChannel
    private lateinit var scope: CoroutineScope
    private val gson = Gson()
    private var commandRevision = 0

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
        // The main thread is also Flutter's UI thread, where "init" would load it.
        scope.launch {
            runCatching { if (!MihomoCoreTransport.isolated) Core.load() }
                .onFailure { error -> GlobalState.log("Unable to load the Core: $error") }
        }
        messenger = binding.binaryMessenger
        channel = MethodChannel(messenger, SERVICE_CHANNEL)
        channel.setMethodCallHandler(this)
        scope.launch(Dispatchers.Main) {
            ServiceState.runState.collect {
                channel.invokeMethod("nativeCoreStatusChanged", nativeStatus())
            }
        }
        // Serial: watchRoute keeps the latest intent by the order calls reach the Core.
        coreChannel = MethodChannel(
            messenger,
            CORE_CHANNEL,
            StandardMethodCodec.INSTANCE,
            messenger.makeBackgroundTaskQueue(),
        )
        coreChannel.setMethodCallHandler(::onCoreMethodCall)
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel.setMethodCallHandler(null)
        coreChannel.setMethodCallHandler(null)
        scope.cancel()
        GlobalState.launch(Dispatchers.IO) { ServiceController.setEventListener(null) }
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "init" -> initialize(result)
            "shutdown" -> shutdown(result)
            "getRunTime" -> getRunTime(result)
            "syncState" -> syncState(call, result)
            "start" -> start(call, result)
            "stop" -> stop(call, result)
            "nativeCoreStatus" -> result.success(nativeStatus())
            "startNativeQuality" -> nativeOperation(result) {
                ServiceController.startNativeQuality(requireNotNull(call.argument<String>("tag")))
                true
            }
            "nativeQualitySnapshot" -> nativeOperation(result) { ServiceController.nativeQualitySnapshot() }
            "cancelNativeQuality" -> nativeOperation(result) {
                ServiceController.cancelNativeQuality()
                true
            }
            "nativeSnapshot" -> nativeOperation(result) { ServiceController.nativeSnapshot() }
            "resetNativeNetwork" -> nativeOperation(result) {
                ServiceController.resetNativeNetwork()
                true
            }
            "selectNativeOutbound" -> nativeOperation(result) {
                ServiceController.selectNativeOutbound(requireNotNull(call.argument<String>("group")), requireNotNull(call.argument<String>("tag")), call.argument<Number>("generation")?.toLong() ?: -1L)
                true
            }
            "testNativeOutbound" -> nativeOperation(result) {
                ServiceController.testNativeOutbound(requireNotNull(call.argument<String>("tag")))
                true
            }
            "validateNativeCore" -> validateNativeCore(call, result)
            "startNativeCore" -> startNativeCore(call, result)
            "stopNativeCore" -> stopNativeCore(call, result)
            "startMihomoCore" -> startMihomoCore(call, result)
            else -> result.notImplemented()
        }
    }

    private fun onCoreMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "invokeMethod" -> invokeMethod(call, result)
            else -> result.notImplemented()
        }
    }

    private fun initialize(result: MethodChannel.Result) {
        scope.launch(Dispatchers.IO) {
            if (!MihomoCoreTransport.isolated) NetworkObserver.start()
            ServiceController.setEventListener(::sendEvent)
                .onSuccess { result.success("") }
                .onFailure { error -> result.success(error.message.orEmpty()) }
        }
    }

    private fun shutdown(result: MethodChannel.Result) {
        scope.launch(Dispatchers.IO) {
            ServiceController.setEventListener(null)
                .onSuccess { result.success(true) }
                .onFailure { result.error("CORE_ERROR", it.message, null) }
        }
    }

    private fun invokeMethod(call: MethodCall, result: MethodChannel.Result) {
        val data = call.arguments as? String
        if (data == null) {
            result.error("INVALID_ARGUMENT", "Method call payload must be a string", null)
            return
        }
        ServiceController.invokeMethod(data) { response ->
            response.onSuccess { result.success(it) }
                .onFailure { result.error("CORE_ERROR", it.message, null) }
        }.onFailure { error ->
            result.error("CORE_ERROR", error.message, null)
        }
    }

    private fun getRunTime(result: MethodChannel.Result) {
        scope.launch {
            result.success(ServiceState.awaitRunTime())
        }
    }

    private fun syncState(call: MethodCall, result: MethodChannel.Result) {
        val data = call.arguments as? String
        scope.launch {
            val state = runCatching {
                gson.fromJson(data, SharedState::class.java)
            }.getOrNull()
            if (state == null) {
                result.success("Invalid shared state")
                return@launch
            }
            ServiceState.syncSharedState(state)
            result.success("")
        }
    }

    private fun nativeOperation(result: MethodChannel.Result, operation: suspend () -> Any) {
        scope.launch {
            runCatching { operation() }
                .onSuccess { result.success(it) }
                .onFailure { result.error("NATIVE_COMMAND", it.message, null) }
        }
    }

    private fun nativeStatus(): Map<String, Any> = mapOf(
        "available" to SingBoxVpnControl.isAvailable(GlobalState.application),
        "engine" to (ServiceController.runtime?.let { if (it.nativeConfigPath != null) "sing-box" else "mihomo" } ?: "idle"),
        "nativeOwner" to ServiceController.hasNativeOwner,
        "mihomoSuspended" to ServiceController.mihomoSuspended,
        "startedAt" to (ServiceController.runtime?.startedAtMillis ?: 0L),
        "state" to ServiceState.runState.value.name,
    )

    private fun validateNativeCore(call: MethodCall, result: MethodChannel.Result) {
        val path = call.argument<String>("path")
        if (path.isNullOrBlank()) {
            result.error("INVALID_ARGUMENT", "Select a native JSON config", null)
            return
        }
        scope.launch {
            runCatching { ServiceController.validateNativeProfile(File(path)) }
                .onSuccess { result.success(it) }
                .onFailure { result.error("NATIVE_CONFIG", it.message, null) }
        }
    }

    private fun startNativeCore(call: MethodCall, result: MethodChannel.Result) {
        val path = call.argument<String>("path")
        if (path.isNullOrBlank()) {
            result.error("INVALID_ARGUMENT", "Select a native JSON config", null)
            return
        }
        commandRevision = call.argument<Int>("revision") ?: commandRevision
        val request = ServiceState.requestNativeStart(File(path))
        scope.launch {
            runCatching { request.await() }
                .onSuccess { outcome ->
                    result.success(mapOf(
                        "started" to outcome.started,
                        "restoredMihomo" to outcome.restoredMihomo,
                        "error" to outcome.error,
                        "engine" to (ServiceController.runtime?.let { if (it.nativeConfigPath != null) "sing-box" else "mihomo" } ?: "idle"),
                    ))
                }
                .onFailure { result.error("NATIVE_START", it.message, null) }
        }
    }

    private fun startMihomoCore(call: MethodCall, result: MethodChannel.Result) {
        commandRevision = call.argument<Int>("revision") ?: commandRevision
        val request = ServiceState.requestMihomoStart()
        scope.launch {
            runCatching { request.await() }
                .onSuccess { result.success(it) }
                .onFailure { result.error("MIHOMO_START", it.message, null) }
        }
    }

    private fun stopNativeCore(call: MethodCall, result: MethodChannel.Result) {
        commandRevision = call.argument<Int>("revision") ?: commandRevision
        val request = ServiceState.requestStop()
        scope.launch {
            runCatching { request.await() }
                .onSuccess { result.success(it) }
                .onFailure { result.error("NATIVE_STOP", it.message, null) }
        }
    }

    private fun start(call: MethodCall, result: MethodChannel.Result) {
        commandRevision = call.arguments as? Int ?: commandRevision
        ServiceState.requestStart()
        result.success(true)
    }

    private fun stop(call: MethodCall, result: MethodChannel.Result) {
        commandRevision = call.arguments as? Int ?: commandRevision
        ServiceState.requestStop()
        result.success(true)
    }

    // Read on the platform thread, where start and stop arrive: revision and intent are one instant.
    fun notifyStopped() {
        scope.launch(Dispatchers.Main) {
            if (!ServiceState.isRunRequested) {
                channel.invokeMethod("stopped", commandRevision)
            }
        }
    }

    private fun sendEvent(value: ByteArray) {
        val message = StandardMethodCodec.INSTANCE.encodeMethodCall(MethodCall("event", value))
        scope.launch(Dispatchers.Main) {
            messenger.send(SERVICE_CHANNEL, message)
        }
    }

    private companion object {
        val SERVICE_CHANNEL = "${Components.PACKAGE_NAME}/service"
        val CORE_CHANNEL = "${Components.PACKAGE_NAME}/core"
    }
}
