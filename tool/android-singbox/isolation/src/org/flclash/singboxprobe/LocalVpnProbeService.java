package org.flclash.singboxprobe;

import android.content.Intent;
import android.net.VpnService;
import android.os.Binder;
import android.os.IBinder;
import android.os.Parcel;

public final class LocalVpnProbeService extends VpnService {
    static final String TOKEN = "org.flclash.singboxprobe.Vpn";
    static final String ACTION = TOKEN + ".TEST";
    static final int START = IBinder.FIRST_CALL_TRANSACTION;
    static final int STOP = START + 1;
    static final int PROTECT_COUNT = START + 2;
    private Object runtime;

    private synchronized void startProbe(int port) throws Exception {
        stopProbe();
        if (prepare(this) != null) throw new IllegalStateException("VPN consent required");
        ClassLoader loader = ProbeService.loadApi(this).getClassLoader();
        Class<?> type = Class.forName("org.flclash.libboxprobe.RealVpnRuntime", true, loader);
        runtime = type.getConstructor(VpnService.class).newInstance(this);
        try {
            type.getMethod("start", int.class).invoke(runtime, port);
        } catch (Exception failure) {
            try { stopProbe(); } catch (Exception cleanup) { failure.addSuppressed(cleanup); }
            throw failure;
        }
    }

    private synchronized void stopProbe() throws Exception {
        if (runtime == null) return;
        runtime.getClass().getMethod("stop").invoke(runtime);
        runtime = null;
    }

    private final Binder binder = new Binder() {
        @Override protected boolean onTransact(int code, Parcel data, Parcel reply, int flags) {
            if (code < START || code > PROTECT_COUNT) return false;
            data.enforceInterface(TOKEN);
            try {
                if (code == START) startProbe(data.readInt());
                if (code == STOP) stopProbe();
                int count = code == PROTECT_COUNT
                    ? (Integer) runtime.getClass().getMethod("protectCount").invoke(runtime) : 0;
                reply.writeNoException();
                reply.writeInt(count);
            } catch (Exception | LinkageError error) {
                Throwable cause = error.getCause() == null ? error : error.getCause();
                reply.writeException(new IllegalStateException("VPN probe: " + cause, error));
            }
            return true;
        }
    };

    @Override public IBinder onBind(Intent intent) {
        return ACTION.equals(intent.getAction()) ? binder : super.onBind(intent);
    }

    @Override public void onRevoke() {
        try { stopProbe(); } catch (Exception error) { android.util.Log.e("VpnProbe", "stop", error); }
        super.onRevoke();
    }

    @Override public void onDestroy() {
        try { stopProbe(); } catch (Exception error) { android.util.Log.e("VpnProbe", "stop", error); }
        super.onDestroy();
    }
}
