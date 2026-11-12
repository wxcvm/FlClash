package com.follow.clash.service

import android.content.Context
import android.net.VpnService
import android.os.Build
import androidx.annotation.RequiresApi
import dalvik.system.InMemoryDexClassLoader
import java.lang.reflect.InvocationTargetException
import java.nio.ByteBuffer

/** Native runtime is optional, loaded only by an explicitly selected VPN owner. */
internal object IsolatedSingBoxRuntime {
    private const val ASSET = "singbox/libbox.dex"
    private const val VERSION = "1.14.4"
    private const val API = "io.nekohasekai.libbox.Libbox"
    private const val SESSION = "org.flclash.singboxprobe.isolated.LibboxVpnSession"
    private const val RUNTIME = "org.flclash.singboxprobe.isolated.AndroidVpnRuntime"

    private var loader: ClassLoader? = null

    fun isPackaged(context: Context): Boolean =
        Build.VERSION.SDK_INT >= 29 &&
            context.assets.list("singbox")?.contains("libbox.dex") == true

    @RequiresApi(29)
    @Synchronized
    private fun load(context: Context): ClassLoader {
        loader?.let { return it }
        check(isPackaged(context)) { "sing-box runtime is not packaged for this Android build" }
        val bytes = context.assets.open(ASSET).use { it.readBytes() }
        val isolated = InMemoryDexClassLoader(
            arrayOf(ByteBuffer.wrap(bytes)),
            context.applicationInfo.nativeLibraryDir,
            context.classLoader.parent,
        )
        val bridge = Class.forName("go.Seq", false, isolated)
        check(bridge.classLoader === isolated) { "sing-box resolved the host Go bridge" }
        val api = Class.forName(API, true, isolated)
        check(api.classLoader === isolated)
        val version = api.getMethod("version").invoke(null) as String
        check(version == VERSION || version == "v$VERSION") { "Unexpected sing-box version: $version" }
        loader = isolated
        return isolated
    }

    @RequiresApi(29)
    fun validate(context: Context, config: String) {
        val type = Class.forName(SESSION, true, load(context))
        invoke { type.getMethod("validate", Context::class.java, String::class.java).invoke(null, context, config) }
    }

    @RequiresApi(29)
    fun create(service: VpnService): Session {
        val type = Class.forName(RUNTIME, true, load(service))
        val runtime = invoke { type.getConstructor(VpnService::class.java).newInstance(service) }
        return Session(runtime)
    }

    internal class Session(private val runtime: Any) : AutoCloseable {
        fun start(config: String) {
            invoke { runtime.javaClass.getMethod("start", String::class.java).invoke(runtime, config) }
        }

        fun snapshot(): String = invoke {
            runtime.javaClass.getMethod("snapshot").invoke(runtime) as String
        }

        fun selectOutbound(group: String, tag: String) {
            invoke { runtime.javaClass.getMethod("selectOutbound", String::class.java, String::class.java).invoke(runtime, group, tag) }
        }

        fun testOutbound(tag: String) {
            invoke { runtime.javaClass.getMethod("testOutbound", String::class.java).invoke(runtime, tag) }
        }

        fun resetNetwork() {
            invoke { runtime.javaClass.getMethod("resetNetwork").invoke(runtime) }
        }

        override fun close() {
            invoke { runtime.javaClass.getMethod("close").invoke(runtime) }
        }
    }

    private inline fun <T> invoke(block: () -> T): T =
        try {
            block()
        } catch (error: InvocationTargetException) {
            throw error.targetException
        }
}
