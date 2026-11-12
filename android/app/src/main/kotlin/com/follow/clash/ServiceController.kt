package com.follow.clash

import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.ServiceConnection
import android.os.Handler
import android.os.IBinder
import android.os.Binder
import android.os.Looper
import android.os.Build
import com.follow.clash.common.GlobalState
import com.follow.clash.common.intent
import com.follow.clash.core.Core
import com.follow.clash.service.ManagedService
import com.follow.clash.service.MihomoServiceControl
import com.follow.clash.service.NetworkObserver
import com.follow.clash.service.ProxyService
import com.follow.clash.service.ServiceConfig
import com.follow.clash.service.SingBoxVpnControl
import java.io.File
import org.json.JSONObject
import com.follow.clash.models.SharedState
import com.follow.clash.service.VpnService
import com.follow.clash.service.models.VpnOptions
import com.follow.clash.service.models.NotificationParams
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.CancellationException
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
    @Volatile internal var desiredNotification = ServiceConfig.notificationParams.value
        private set
    @Volatile private var nativeCleanupPending = false
    @Volatile private var latestSharedState: SharedState? = null
    @Volatile private var restoreMihomoConfig = false

    internal fun rememberSharedState(state: SharedState) { latestSharedState = state }
    internal val mihomoSuspended: Boolean
        get() = MihomoCoreTransport.isolated && MihomoCoreTransport.isSuspended()
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
        if (MihomoCoreTransport.isolated) {
            runCatching { MihomoCoreTransport.stopListener() }.onFailure { GlobalState.log("Mihomo stop listener: $it") }
        } else Core.stopListener()
    }

    fun invokeMethod(data: String, callback: (Result<ByteArray>) -> Unit): Result<Unit> = runCatching {
        if (MihomoCoreTransport.isolated) {
            if (!MihomoCoreTransport.invoke(data, callback)) {
                val call = JSONObject(data)
                val response = JSONObject().put("id", call.optString("id"))
                    .put("error", JSONObject().put("code", "core_unavailable")
                        .put("message", "Mihomo is suspended while sing-box owns the VPN"))
                callback(Result.success(response.toString().encodeToByteArray()))
            }
        }
        else Core.invokeMethod(data) { result -> callback(Result.success(result ?: ByteArray(0))) }
    }

    suspend fun quickSetup(
        initParams: String,
        setupParams: String,
    ): Result<String> = runCatching {
        if (MihomoCoreTransport.isolated) withContext(Dispatchers.IO) {
            withTimeout(60_000) {
                suspendCancellableCoroutine<String> { continuation ->
                    MihomoCoreTransport.get().quickSetup(initParams, setupParams) { result ->
                        continuation.resumeWith(result.map { it.decodeToString() })
                    }
                }
            }
        } else {
            NetworkObserver.start()
            suspendCancellableCoroutine { continuation ->
                Core.quickSetup(initParams, setupParams) { result -> continuation.resume(result.orEmpty()) }
            }
        }
    }

    fun updateNotificationParams(params: NotificationParams) {
        desiredNotification = params
        ServiceConfig.updateNotificationParams(params)
        GlobalState.launch {
            lock.withLock {
                // A local start can have applied its older serialized snapshot.
                // Keep the desired value separate from service-side state.
                val latest = desiredNotification
                ServiceConfig.updateNotificationParams(latest)
                if (runtime?.nativeConfigPath != null) return@withLock
                binding?.useService { service ->
                    // Read the latest value after acquiring the lock, so a delayed
                    // update cannot overwrite a newer notification setting.
                    if (service is MihomoManagedService) {
                        service.updateNotification(desiredNotification)
                    }
                }?.onFailure { GlobalState.log("Unable to update Mihomo notification: $it") }
            }
        }
    }

    fun setEventListener(callback: ((ByteArray) -> Unit)?): Result<Unit> = runCatching {
        if (MihomoCoreTransport.isolated) MihomoCoreTransport.setEvents(callback)
        else Core.updateEventListener(callback)
    }

    suspend fun start(options: VpnOptions): Boolean = lock.withLock {
        if (options.nativeConfigPath != null) return@withLock startNative(options).started
        if (hasNativeOwner) {
            if (MihomoCoreTransport.isolated && (latestSharedState ?: GlobalState.application.sharedState).setupParams == null) {
                return@withLock false
            }
            if (!stopForHandoff()) return@withLock false
        }
        startMihomoLocked(options)
    }

    private suspend fun startMihomoLocked(options: VpnOptions): Boolean {
        if (MihomoCoreTransport.isolated && !MihomoCoreTransport.resumeAfterNative()) return false
        if (MihomoCoreTransport.isolated && restoreMihomoConfig) {
            val state = latestSharedState ?: GlobalState.application.sharedState
            val setup = state.setupParams ?: return false
            val result = quickSetup(
                ServiceStateMachine.initParams(GlobalState.application.filesDir.path, Build.VERSION.SDK_INT),
                setup.toString(),
            )
            if (result.getOrNull() != "") {
                GlobalState.log("Unable to restore Mihomo configuration: $result")
                return false
            }
            restoreMihomoConfig = false
        }
        ServiceConfig.updateVpnOptions(options)
        val nextIntent = (if (options.enable) {
            VpnService::class.intent
        } else {
            ProxyService::class.intent
        }).apply { action = MihomoServiceControl.ACTION }

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

        if (MihomoCoreTransport.isolated) {
            val listener = runCatching { withContext(Dispatchers.IO) { MihomoCoreTransport.get().setListener(true) } }
            if (listener.isFailure) {
                currentBinding.stopIfConnected()
                release()
                return false
            }
        } else Core.startListener()
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

    internal suspend fun nativeStatusSnapshot(): String = nativeCommand { it.statusSnapshot() }
    internal suspend fun nativeSnapshot(): String = nativeCommand { it.snapshot() }
    internal suspend fun selectNativeOutbound(group: String, tag: String, expectedGeneration: Long) =
        nativeCommand { it.selectOutbound(group, tag, expectedGeneration) }
    internal suspend fun resetNativeNetwork() = nativeCommand { it.resetNetwork() }
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
            withContext(NonCancellable) {
                candidate.stopIfConnected()
                candidate.unbind()
            }
        }
    }

    // Always-on is a property of the system VPN service, not the Core binder.
    // Even when the UI thinks it is idle (or is running only a proxy), ask
    // the actual Android VpnService before preflight can touch either owner.
    private suspend fun canSwitchToNative(): Boolean {
        if (Build.VERSION.SDK_INT < 29) return true
        val intent = VpnService::class.intent.apply { action = MihomoServiceControl.ACTION }
        val current = binding
        if (current?.component == intent.component) {
            return current.useService { (it as MihomoManagedService).canHandoff() }.getOrDefault(false)
        }
        val probe = ManagedServiceBinding(intent, {})
        return try {
            probe.bind().getOrThrow()
            probe.useService { (it as MihomoManagedService).canHandoff() }.getOrThrow()
        } catch (error: CancellationException) {
            throw error
        } catch (error: Exception) {
            GlobalState.log("Unable to check Android VPN handoff: $error")
            false
        } finally {
            withContext(NonCancellable) {
                probe.unbind()
                withContext(Dispatchers.Main) { }
            }
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
        if (!canSwitchToNative()) {
            return NativeStartResult(false, false, "Disable always-on/lockdown VPN before switching to sing-box")
        }
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
            withContext(NonCancellable) {
                candidate.stopIfConnected()
                candidate.unbind()
            }
            preflight.exceptionOrNull()?.let { if (it is CancellationException) throw it }
            return NativeStartResult(false, false, preflight.exceptionOrNull()?.message.orEmpty())
        }
        return withContext(NonCancellable) {
            if (MihomoCoreTransport.isolated && !runCatching {
                    withContext(Dispatchers.IO) {
                        MihomoCoreTransport.resumeAfterNative() && MihomoCoreTransport.canSuspend()
                    }
                }.getOrDefault(false)) {
                candidate.stopIfConnected()
                candidate.unbind()
                return@withContext NativeStartResult(false, false, "Mihomo cannot hand off; check always-on/lockdown VPN")
            }
            if (!stopForHandoff()) {
                candidate.stopIfConnected()
                candidate.unbind()
                return@withContext NativeStartResult(false, false, "Existing VPN could not be stopped")
            }
            if (MihomoCoreTransport.isolated) {
                val retired = runCatching { withContext(Dispatchers.IO) { MihomoCoreTransport.suspendForNative() } }
                if (retired.isFailure) {
                    candidate.stopIfConnected()
                    candidate.unbind()
                    val resumed = MihomoCoreTransport.resumeAfterNative()
                    restoreMihomoConfig = true
                    val restored = resumed && previous != null && previousOptions != null &&
                        startMihomoLocked(previousOptions.copy(nativeConfigPath = null))
                    return@withContext NativeStartResult(false, restored, retired.exceptionOrNull()?.message.orEmpty())
                }
                restoreMihomoConfig = true
            }
            binding = candidate
            val result = candidate.useService { service -> service.start() }
            if (result.isFailure) {
                val cleanup = candidate.stopIfConnected()
                if (cleanup.isFailure) {
                    nativeCleanupPending = true
                    return@withContext NativeStartResult(false, false, "Native startup and cleanup failed: ${result.exceptionOrNull()?.message}")
                }
                release()
                if (MihomoCoreTransport.isolated) MihomoCoreTransport.resumeAfterNative()
                val restored = previous != null && previousOptions != null &&
                    startMihomoLocked(previousOptions.copy(nativeConfigPath = null))
                return@withContext NativeStartResult(false, restored, result.exceptionOrNull()?.message.orEmpty())
            }
            ServiceConfig.updateVpnOptions(options)
            runtime = ServiceRuntime(
                vpn = true,
                startedAtMillis = System.currentTimeMillis(),
                nativeConfigPath = path,
            )
            NativeStartResult(true, false, "")
        }
    }

    // Unlike general shutdown, handoff must not ignore an old owner's stop error.
    private suspend fun stopForHandoff(): Boolean {
        val current = binding
        if (current == null && (runtime != null || hasNativeOwner)) {
            GlobalState.log("VPN handoff blocked: active owner has no binding")
            return false
        }
        if (current != null) {
            val stopped = if (hasNativeOwner) current.stopIfConnected() else current.useService { service ->
                if (service is MihomoManagedService) {
                    check(service.canHandoff()) {
                        "Disable always-on/lockdown VPN before switching cores"
                    }
                } else if (service is VpnService && Build.VERSION.SDK_INT >= 29) {
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
        val wasNative = hasNativeOwner
        release()
        stopServices()
        // clearBinding posts its unbind to main. Drain it before retiring Core.
        withContext(Dispatchers.Main) { }
        if (wasNative && MihomoCoreTransport.isolated) MihomoCoreTransport.resumeAfterNative()
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
                if (hasNativeOwner && disconnectedBinding.stopIfConnected().isFailure) {
                    nativeCleanupPending = true
                    return@withLock false
                }
                val wasNative = hasNativeOwner
                release()
                if (wasNative && MihomoCoreTransport.isolated) MihomoCoreTransport.resumeAfterNative()
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
    // Android may rebind a BIND_AUTO_CREATE connection after process death.
    // Retain the original native owner, never adopt a replacement binder implicitly.
    @Volatile private var nativeOwner: NativeManagedService? = null

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
        val service = nativeOwner ?: serviceState.value?.getOrNull() ?: return@runCatching
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
                check(nativeOwner == null) { "Native process was replaced; request a new session" }
                NativeManagedService(requireNotNull(binder), nativeProfile).also { nativeOwner = it }
            } else if (intent.action == MihomoServiceControl.ACTION) {
                MihomoManagedService(requireNotNull(binder))
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

/** The same lifecycle calls work with a local Binder or a remote BinderProxy. */
private class MihomoManagedService(private val remote: IBinder) : ManagedService {
    override fun start() {
        MihomoServiceControl.start(
            GlobalState.application,
            remote,
            requireNotNull(ServiceConfig.vpnOptions),
            ServiceController.desiredNotification,
        )
    }

    override fun stop() = MihomoServiceControl.stop(remote)
    fun canHandoff(): Boolean = MihomoServiceControl.canHandoff(remote)
    private val remotePid by lazy { MihomoServiceControl.pid(remote) }
    fun updateNotification(params: NotificationParams) {
        // Local mode already shares ServiceConfig; no redundant Binder writes.
        if (remotePid != android.os.Process.myPid()) {
            MihomoServiceControl.updateNotification(remote, params)
        }
    }
}

/** Adapter for the existing binding/controller contract; native RPCs run off the UI thread. */
private class NativeManagedService(
    private val remote: IBinder,
    private val profile: File,
) : ManagedService {
    private val owner = Binder()
    fun startQuality(tag: String) = SingBoxVpnControl.startQuality(remote, tag)
    fun qualitySnapshot(): String = SingBoxVpnControl.qualitySnapshot(remote)
    fun cancelQuality() = SingBoxVpnControl.cancelQuality(remote)
    fun statusSnapshot(): String = SingBoxVpnControl.statusSnapshot(remote)
    fun snapshot(): String = SingBoxVpnControl.snapshot(remote)
    fun selectOutbound(group: String, tag: String, expectedGeneration: Long) = SingBoxVpnControl.selectOutbound(remote, group, tag, expectedGeneration)
    fun resetNetwork() = SingBoxVpnControl.resetNetwork(remote)
    fun testOutbound(tag: String) = SingBoxVpnControl.testOutbound(remote, tag)

    fun validate() {
        SingBoxVpnControl.validate(remote, profile, owner)
    }

    override fun start() {
        val app = GlobalState.application
        app.startForegroundService(SingBoxVpnControl.foregroundIntent(app))
        SingBoxVpnControl.start(remote, owner)
        check(SingBoxVpnControl.isRunning(remote)) { "Native VPN did not start" }
    }

    override fun stop() {
        SingBoxVpnControl.stop(remote, owner)
    }
}
