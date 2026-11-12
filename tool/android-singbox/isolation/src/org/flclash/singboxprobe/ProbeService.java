package org.flclash.singboxprobe;

import android.app.Service;
import android.content.Intent;
import android.os.Binder;
import android.os.IBinder;
import android.os.Parcel;
import android.os.Process;
import dalvik.system.InMemoryDexClassLoader;
import java.io.ByteArrayOutputStream;
import java.io.InputStream;
import java.lang.reflect.InvocationTargetException;
import java.nio.ByteBuffer;

public final class ProbeService extends Service {
    static final int PROBE = IBinder.FIRST_CALL_TRANSACTION;
    static final String DESCRIPTOR = "org.flclash.singboxprobe.Probe";

    private String probe() throws Exception {
        ByteArrayOutputStream bytes = new ByteArrayOutputStream();
        try (InputStream in = getAssets().open("libbox.dex")) {
            byte[] buffer = new byte[16384];
            for (int n; (n = in.read(buffer)) != -1;) {
                bytes.write(buffer, 0, n);
            }
        }
        // Do not delegate to the APK classloader, which owns the host go.Seq.
        // The platform parent still exposes android.* and java.*.
        ClassLoader host = getClassLoader();
        ClassLoader isolated = new InMemoryDexClassLoader(
            new ByteBuffer[] { ByteBuffer.wrap(bytes.toByteArray()) },
            getApplicationInfo().nativeLibraryDir,
            host.getParent()
        );
        Class<?> bridge = Class.forName("go.Seq", false, isolated);
        if (bridge == go.Seq.class || bridge.getClassLoader() != isolated) {
            throw new IllegalStateException("libbox resolved the host Go bridge");
        }
        Class<?> api = Class.forName("io.nekohasekai.libbox.Libbox", true, isolated);
        if (api.getClassLoader() != isolated) {
            throw new IllegalStateException("libbox API escaped its classloader");
        }
        String version = (String) api.getMethod("version").invoke(null);
        if (!"1.14.4".equals(version) && !"v1.14.4".equals(version)) {
            throw new IllegalStateException("Unexpected libbox version: " + version);
        }
        try {
            api.getMethod("checkConfig", String.class).invoke(null, "{");
            throw new IllegalStateException("Invalid JSON was accepted");
        } catch (InvocationTargetException expected) {
            if (expected.getCause() == null) throw expected;
        }
        return version;
    }

    private final Binder binder = new Binder() {
        @Override
        protected boolean onTransact(int code, Parcel data, Parcel reply, int flags) {
            if (code != PROBE) return false;
            data.enforceInterface(DESCRIPTOR);
            try {
                String version = probe();
                reply.writeNoException();
                reply.writeInt(Process.myPid());
                reply.writeString(version);
            } catch (Exception | LinkageError error) {
                reply.writeException(new IllegalStateException("libbox probe failed: " + error, error));
            }
            return true;
        }
    };

    @Override
    public IBinder onBind(Intent intent) {
        return binder;
    }
}
