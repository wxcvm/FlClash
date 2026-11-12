package com.follow.clash.service;

import android.content.Context;
import android.os.Build;
import android.os.Process;
import dalvik.system.InMemoryDexClassLoader;
import java.io.ByteArrayOutputStream;
import java.io.File;
import java.io.IOException;
import java.io.InputStream;
import java.lang.reflect.InvocationTargetException;
import java.nio.ByteBuffer;

/** Shared production/diagnostic loader. Initialize only inside the native core process. */
public final class IsolatedLibbox {
    private static ClassLoader isolatedLoader;

    private IsolatedLibbox() {}

    /** Does not load JNI, so capability checks do not allocate a Go runtime. */
    public static boolean isAvailable(Context context) {
        if (Build.VERSION.SDK_INT < 29 || !Process.is64Bit()) return false;
        if (!new File(context.getApplicationInfo().nativeLibraryDir, "libbox.so").isFile()) return false;
        try (InputStream input = context.getAssets().open("libbox.dex")) {
            return input.read() != -1;
        } catch (IOException unavailable) {
            return false;
        }
    }

    public static synchronized Class<?> loadApi(Context context) throws Exception {
        if (!isAvailable(context)) throw new IllegalStateException("Isolated libbox payload unavailable");
        if (isolatedLoader == null) {
            ByteArrayOutputStream bytes = new ByteArrayOutputStream();
            try (InputStream input = context.getAssets().open("libbox.dex")) {
                byte[] buffer = new byte[16384];
                for (int n; (n = input.read(buffer)) != -1;) bytes.write(buffer, 0, n);
            }
            // Bypass the app loader which owns Mihomo's go.Seq, while retaining Android APIs.
            ClassLoader host = context.getClassLoader();
            ClassLoader candidate = new InMemoryDexClassLoader(
                new ByteBuffer[] {ByteBuffer.wrap(bytes.toByteArray())},
                context.getApplicationInfo().nativeLibraryDir, host.getParent());
            Class<?> bridge = Class.forName("go.Seq", false, candidate);
            if (bridge.getClassLoader() != candidate) {
                throw new IllegalStateException("libbox resolved a foreign Go bridge");
            }
            isolatedLoader = candidate;
        }
        Class<?> api = Class.forName("io.nekohasekai.libbox.Libbox", true, isolatedLoader);
        if (api.getClassLoader() != isolatedLoader) {
            throw new IllegalStateException("libbox API escaped its isolated classloader");
        }
        String version = (String) api.getMethod("version").invoke(null);
        if (!"1.14.4".equals(version) && !"v1.14.4".equals(version)) {
            throw new IllegalStateException("Unexpected libbox version: " + version);
        }
        return api;
    }

    /** Native config preflight; no VPN establishment or route changes. */
    public static void validateVpnConfig(Context context, String config) throws Exception {
        Class<?> api = loadApi(context);
        try {
            api.getMethod("checkConfig", String.class).invoke(null, config);
            if (!Boolean.TRUE.equals(api.getMethod("hasTunInbound", String.class).invoke(null, config))) {
                throw new IllegalArgumentException("Native Android VPN requires a TUN inbound");
            }
        } catch (InvocationTargetException failure) {
            Throwable cause = failure.getCause();
            if (cause instanceof Exception) throw (Exception) cause;
            if (cause instanceof Error) throw (Error) cause;
            throw failure;
        }
    }
}
