package com.follow.clash

import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.ServiceConnection
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.Build
import com.follow.clash.common.GlobalState
import com.follow.clash.common.intent
import com.follow.clash.core.Core
import com.follow.clash.service.ManagedService
import com.follow.clash.service.NetworkObserver
import com.follow.clash.service.ProxyService
import com.follow.clash.service.ServiceConfig
import com.follow.clash.service.SingBoxVpnControl
import java.io.File
import com.follow.clash.service.VpnService
import com.follow.clash.service.models.VpnOptions
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.filterNotNull
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.launch
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeout
import kotlin.coroutines.resume

object ServiceController {
    private val lock = Mutex()
    private var binding: ManagedServiceBinding? = null
    @Volatile private var nativeCleanupPending = false
    internal val hasNativeOwner: Boolean get() = runtime?.nativeConfigPath != null || nativeCleanupPending

    @Volatile
    internal var runtime: ServiceRuntime? = null
        private set

    private fun clearBinding() {
        binding?.unbind()
        binding = null
    }

    // The Core listens exactly while a run exists, so every path that ends one closes it.
    private fun release() {
        clearBinding()
        runtime = null
        nativeCleanupPending = false
        Core.stopListener()
    }

    fun invokeMethod(data: String, callback: (ByteArray) -> Unit): Result<Unit> = runCatching {
        Core.invokeMethod(data) { result ->
            callback(result ?: ByteArray(0))
        }
    }

    suspend fun quickSetup(
        initParams: String,
        setupParams: String,
    ): Result<String> = runCatching {
        NetworkObserver.start()
        suspendCancellableCoroutine { continuation ->
            Core.quickSetup(initParams, setupParams) { result ->
                continuation.resume(result.orEmpty())
            }
        }
    }

    fun setEventListener(callback: ((ByteArray) -> Unit)?): Result<Unit> = runCatching {
        Core.updateEventListener(callback)
    }

    suspend fun start(options: VpnOptions): Boolean = lock.withLock {
        if (options.nativeConfigPath != null) return@withLock startNative(options).started
        if (hasNativeOwner) {
            if (!stopForHandoff()) return@withLock false
        }
        startMihomoLocked(options)
    }

    private suspend fun startMihomoLocked(options: VpnOptions): Boolean {
        ServiceConfig.updateVpnOptions(options)
        val nextIntent = if (options.enable) {
            VpnService::class.intent
        } else {
            ProxyService::class.intent
        }

        if (binding?.component != nextIntent.component) {
            if (binding != null) {
                tearDownServices()
            }
            lateinit var nextBinding: ManagedServiceBinding
            nextBinding = ManagedServiceBinding(nextIntent, { message ->
                handleServiceDisconnected(nextBinding, message)
            })
            binding = nextBinding
            nextBinding.bind().onFailure { error ->
                GlobalState.log("Unable to bind background service: $error")
                release()
                return false
            }
        }

        val currentBinding = binding ?: return false
        val result = currentBinding.useService { service -> service.start() }
        if (result.isFailure) {
            GlobalState.log("Unable to start background service: ${result.exceptionOrNull()}")
            currentBinding.stopIfConnected()
                .onFailure { error ->
                    GlobalState.log("Unable to clean up failed background service start: $error")
                }
            release()
            return false
        }

        Core.startListener()
        runtime = ServiceRuntime(
            vpn = options.enable,
            startedAtMillis = runtime?.startedAtMillis ?: System.currentTimeMillis(),
        )
        return true
    }

    internal suspend fun startNativeForUi(options: VpnOptions): NativeStartResult = lock.withLock {
        startNative(options)
    }

    private suspend fun <T> nativeCommand(block: (NativeManagedService) -> T): T = lock.withLock {
        check(runtime?.nativeConfigPath != null) { "sing-box VPN is not running" }
        requireNotNull(binding).useService { block(it as NativeManagedService) }.getOrThrow()
    }

    internal suspend fun startNativeQuality(tag: String) = nativeCommand { it.startQuality(tag) }
    internal suspend fun nativeQualitySnapshot(): String = nativeCommand { it.qualitySnapshot() }
    internal suspend fun cancelNativeQuality() = nativeCommand { it.cancelQuality() }

    internal suspend fun nativeSnapshot(): String = nativeCommand { it.snapshot() }
    internal suspend fun selectNativeOutbound(group: String, tag: String) =
        nativeCommand { it.selectOutbound(group, tag) }
    internal suspend fun testNativeOutbound(tag: String) = nativeCommand { it.testOutbound(tag) }

    internal suspend fun validateNativeProfile(profile: File): String = lock.withLock {
        check(!hasNativeOwner) { "Stop the native VPN before checking another profile" }
        val app = GlobalState.application
        check(SingBoxVpnControl.isAvailable(app)) { "Native sing-box VPN is unavailable" }
        check(profile.isFile) { "Native profile is missing" }
        val candidate = ManagedServiceBinding(SingBoxVpnControl.bindIntent(app), {}, profile)
        try {
            candidate.bind().getOrThrow()
            candidate.useService { (it as NativeManagedService).validate() }.getOrThrow()
            "1.14.4"
        } finally {
            candidate.unbind()
        }
    }

    private suspend fun startNative(options: VpnOptions): NativeStartResult {
        val app = GlobalState.application
        val path = options.nativeConfigPath ?: return NativeStartResult(false, false, "Native profile is missing")
        if (!options.enable || !SingBoxVpnControl.isAvailable(app)) {
            return NativeStartResult(false, false, "Native sing-box VPN is unavailable")
        }
        if (hasNativeOwner) {
            return NativeStartResult(false, false, "Stop the current native session first")
        }
        val profile = File(path)
        if (!profile.isFile) return NativeStartResult(false, false, "Native profile is missing")
        val previous = runtime
        val previousOptions = ServiceConfig.vpnOptions
        lateinit var candidate: ManagedServiceBinding
        candidate = ManagedServiceBinding(
            SingBoxVpnControl.bindIntent(app),
            onDisconnected = { message -> handleServiceDisconnected(candidate, message) },
            nativeProfile = profile,
        )
        val preflight = candidate.bind().mapCatching {
            candidate.useService { service -> (service as NativeManagedService).validate() }.getOrThrow()
        }
        if (preflight.isFailure) {
            candidate.unbind()
            return NativeStartResult(false, false, preflight.exceptionOrNull()?.message.orEmpty())
        }
        if (!stopForHandoff()) {
            candidate.unbind()
            return NativeStartResult(false, false, "Existing VPN could not be stopped")
        }
        binding = candidate
        val result = candidate.useService { service -> service.start() }
        if (result.isFailure) {
            val cleanup = candidate.stopIfConnected()
            if (cleanup.isFailure) {
                nativeCleanupPending = true
                return NativeStartResult(false, false, "Native startup and cleanup failed: ${result.exceptionOrNull()?.message}")
            }
            release()
            val restored = previous != null && previousOptions != null &&
                startMihomoLocked(previousOptions.copy(nativeConfigPath = null))
            return NativeStartResult(false, restored, result.exceptionOrNull()?.message.orEmpty())
        }
        ServiceConfig.updateVpnOptions(options)
        runtime = ServiceRuntime(
            vpn = true,
            startedAtMillis = System.currentTimeMillis(),
            nativeConfigPath = path,
        )
        return NativeStartResult(true, false, "")
    }

    // Unlike general shutdown, handoff must not ignore an old owner's stop error.
    private suspend fun stopForHandoff(): Boolean {
        val current = binding
        if (current != null) {
            val stopped = current.useService { service ->
                if (service is VpnService && Build.VERSION.SDK_INT >= 29) {
                    check(!service.isAlwaysOn && !service.isLockdownEnabled) {
                        "Disable always-on/lockdown VPN before switching cores"
                    }
                }
                service.stop()
            }
            if (stopped.isFailure) {
                GlobalState.log("VPN handoff blocked: ${stopped.exceptionOrNull()}")
                return false
            }
        }
        release()
        stopServices()
        return true
    }

    suspend fun stop() = lock.withLock {
        if (hasNativeOwner) {
            check(stopForHandoff()) { "Native VPN cleanup failed" }
            return@withLock
        }
        tearDownServices()
        runCatching { GlobalState.application.stopService(SingBoxVpnControl.foregroundIntent(GlobalState.application)) }
        release()
    }

    private suspend fun tearDownServices() {
        binding?.useService { service -> service.stop() }
            ?.onFailure { error ->
                GlobalState.log("Unable to stop background service: $error")
            }
        clearBinding()
        stopServices()
    }

    // A service the system started itself — always-on VPN, or the sticky restart
    // after the process was killed — outlives every binding this process holds, so
    // unbinding alone leaves the tunnel up while the app reports it stopped.
    private fun stopServices() {
        listOf(VpnService::class.intent, ProxyService::class.intent).forEach { intent ->
            runCatching { GlobalState.application.stopService(intent) }
                .onFailure { error ->
                    GlobalState.log("Unable to stop ${intent.component?.className}: $error")
                }
        }
    }

    private fun handleServiceDisconnected(
        disconnectedBinding: ManagedServiceBinding,
        message: String,
    ) {
        val token = ServiceState.captureRequestToken()
        GlobalState.launch {
            val wasCurrent = lock.withLock {
                if (binding !== disconnectedBinding) {
                    return@withLock false
                }
                GlobalState.log("Background service disconnected: $message")
                release()
                true
            }
            if (wasCurrent) {
                ServiceState.handleServiceLost(token)
            }
        }
    }
}

internal data class NativeStartResult(
    val started: Boolean,
    val restoredMihomo: Boolean,
    val error: String,
)

private class ManagedServiceBinding(
    private val intent: Intent,
    private val onDisconnected: (String) -> Unit,
    private val nativeProfile: File? = null,
) : ServiceConnection {
    val component: ComponentName?
        get() = intent.component

    private val serviceState = MutableStateFlow<Result<ManagedService>?>(null)

    @Volatile
    private var isBound = false

    suspend fun bind(): Result<Unit> = runCatching {
        withContext(Dispatchers.Main.immediate) {
            serviceState.value = null
            isBound = GlobalState.application.bindService(
                intent,
                this@ManagedServiceBinding,
                Context.BIND_AUTO_CREATE,
            )
            check(isBound) { "bindService() failed" }
        }
    }

    suspend fun <R> useService(
        connectionTimeoutMillis: Long = 5_000,
        block: suspend (ManagedService) -> R,
    ): Result<R> = runCatching {
        val service = withTimeout(connectionTimeoutMillis) {
            serviceState.filterNotNull().first().getOrThrow()
        }
        withContext(Dispatchers.Default) {
            block(service)
        }
    }

    suspend fun stopIfConnected(): Result<Unit> = runCatching {
        val service = serviceState.value?.getOrNull() ?: return@runCatching
        withContext(Dispatchers.Default) {
            service.stop()
        }
    }

    fun unbind() {
        serviceState.value = null
        if (!isBound) return
        isBound = false
        Handler(Looper.getMainLooper()).post {
            runCatching {
                GlobalState.application.unbindService(this)
            }.onFailure { error ->
                GlobalState.log("Unable to unbind background service: $error")
            }
        }
    }

    override fun onServiceConnected(name: ComponentName?, binder: IBinder?) {
        runCatching {
            if (nativeProfile != null) {
                NativeManagedService(requireNotNull(binder), nativeProfile)
            } else when (binder) {
                is VpnService.LocalBinder -> binder.service
                is ProxyService.LocalBinder -> binder.service
                null -> error("Binder is empty")
                else -> error("Unsupported service binder: ${binder.javaClass.name}")
            }
        }.onSuccess { service ->
            serviceState.value = Result.success(service)
        }.onFailure { error ->
            disconnect(error.message.orEmpty())
        }
    }

    override fun onServiceDisconnected(name: ComponentName?) {
        disconnect("Service disconnected")
    }

    override fun onBindingDied(name: ComponentName?) {
        disconnect("Service binding died")
    }

    override fun onNullBinding(name: ComponentName?) {
        disconnect("Service returned an empty binder")
    }

    private fun disconnect(message: String) {
        serviceState.value = Result.failure(IllegalStateException(message))
        onDisconnected(message)
    }
}

/** Adapter for the existing binding/controller contract; native RPCs run off the UI thread. */
private class NativeManagedService(
    private val remote: IBinder,
    private val profile: File,
) : ManagedService {
    fun startQuality(tag: String) = SingBoxVpnControl.startQuality(remote, tag)
    fun qualitySnapshot(): String = SingBoxVpnControl.qualitySnapshot(remote)
    fun cancelQuality() = SingBoxVpnControl.cancelQuality(remote)
    fun snapshot(): String = SingBoxVpnControl.snapshot(remote)
    fun selectOutbound(group: String, tag: String) = SingBoxVpnControl.selectOutbound(remote, group, tag)
    fun testOutbound(tag: String) = SingBoxVpnControl.testOutbound(remote, tag)

    fun validate() {
        SingBoxVpnControl.validate(remote, profile)
    }

    override fun start() {
        val app = GlobalState.application
        app.startForegroundService(SingBoxVpnControl.foregroundIntent(app))
        SingBoxVpnControl.start(remote, profile)
        check(SingBoxVpnControl.isRunning(remote)) { "Native VPN did not start" }
    }

    override fun stop() {
        SingBoxVpnControl.stop(remote)
    }
}
