package org.flclash.singboxprobe;

import android.app.Service;
import android.content.Intent;
import android.os.Binder;
import android.os.IBinder;
import android.os.Parcel;
import android.os.ParcelFileDescriptor;
import android.os.Process;
import dalvik.system.InMemoryDexClassLoader;
import java.io.ByteArrayOutputStream;
import java.io.InputStream;
import java.io.DataInputStream;
import java.io.DataOutputStream;
import java.lang.reflect.InvocationTargetException;
import java.nio.ByteBuffer;

public final class ProbeService extends Service {
    static final int PROBE = IBinder.FIRST_CALL_TRANSACTION;
    static final int TRANSFER_FD = PROBE + 1;
    static final int FD_CHALLENGE = 0x464c434c;
    static final int FD_RESPONSE = 0x53494e47;
    static final String DESCRIPTOR = "org.flclash.singboxprobe.Probe";

    // Keep the JNI-owning loader alive across service instances in this process.
    private static ClassLoader isolatedLoader;

    private Class<?> loadApi() throws Exception {
        synchronized (ProbeService.class) {
            if (isolatedLoader == null) {
                isolatedLoader = createIsolatedLoader();
            }
            Class<?> api = Class.forName("io.nekohasekai.libbox.Libbox", true, isolatedLoader);
            if (api.getClassLoader() != isolatedLoader) {
                throw new IllegalStateException("libbox API escaped its classloader");
            }
            return api;
        }
    }

    private ClassLoader createIsolatedLoader() throws Exception {
        ByteArrayOutputStream bytes = new ByteArrayOutputStream();
        try (InputStream in = getAssets().open("libbox.dex")) {
            byte[] buffer = new byte[16384];
            for (int n; (n = in.read(buffer)) != -1;) {
                bytes.write(buffer, 0, n);
            }
        }
        // Do not delegate to the APK classloader, which owns the host Mihomo go.Seq.
        // The platform parent still exposes android.* and java.*.
        ClassLoader host = getClassLoader();
        ClassLoader isolated = new InMemoryDexClassLoader(
            new ByteBuffer[] { ByteBuffer.wrap(bytes.toByteArray()) },
            getApplicationInfo().nativeLibraryDir,
            host.getParent()
        );
        Class<?> bridge = Class.forName("go.Seq", false, isolated);
        if (bridge == go.Seq.class || bridge.getClassLoader() != isolated) {
            throw new IllegalStateException("libbox resolved the host Mihomo Go bridge");
        }
        return isolated;
    }

    private String probe() throws Exception {
        Class<?> api = loadApi();
        String version = (String) api.getMethod("version").invoke(null);
        if (!"1.14.4".equals(version) && !"v1.14.4".equals(version)) {
            throw new IllegalStateException("Unexpected libbox version: " + version);
        }
        try {
            api.getMethod("checkConfig", String.class).invoke(null, "{");
            throw new IllegalStateException("Invalid JSON was accepted");
        } catch (InvocationTargetException expected) {
            // A JNI/linkage error is a failed probe, not a rejected config.
            if (!(expected.getCause() instanceof Exception)) throw expected;
        }
        return version;
    }

    // Binder duplicates a real file descriptor into this process; an integer
    // fd from the caller is never a valid cross-process handle.
    private void transferFd(Parcel data, Parcel reply) throws Exception {
        try (ParcelFileDescriptor incoming = ParcelFileDescriptor.CREATOR.createFromParcel(data);
             DataInputStream input = new DataInputStream(
                 new ParcelFileDescriptor.AutoCloseInputStream(incoming))) {
            if (input.readInt() != FD_CHALLENGE) {
                throw new IllegalStateException("Invalid descriptor challenge");
            }
        }
        ParcelFileDescriptor[] pipe = ParcelFileDescriptor.createPipe();
        try (ParcelFileDescriptor readEnd = pipe[0];
             DataOutputStream output = new DataOutputStream(
                 new ParcelFileDescriptor.AutoCloseOutputStream(pipe[1]))) {
            output.writeInt(FD_RESPONSE);
            output.flush();
            reply.writeNoException();
            readEnd.writeToParcel(reply, 0);
        }
    }

    private final Binder binder = new Binder() {
        @Override
        protected boolean onTransact(int code, Parcel data, Parcel reply, int flags) {
            if (code != PROBE && code != TRANSFER_FD) return false;
            data.enforceInterface(DESCRIPTOR);
            try {
                if (code == TRANSFER_FD) {
                    transferFd(data, reply);
                    return true;
                }
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
