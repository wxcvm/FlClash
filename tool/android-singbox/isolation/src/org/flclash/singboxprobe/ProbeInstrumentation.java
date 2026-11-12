package org.flclash.singboxprobe;

import android.app.Activity;
import android.app.Instrumentation;
import android.content.ComponentName;
import android.content.Context;
import android.content.Intent;
import android.content.ServiceConnection;
import android.os.Bundle;
import android.os.IBinder;
import android.os.Parcel;
import android.os.Process;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.TimeUnit;

public final class ProbeInstrumentation extends Instrumentation {
    @Override
    public void onCreate(Bundle arguments) {
        super.onCreate(arguments);
        start();
    }

    @Override
    public void onStart() {
        Bundle result = new Bundle();
        Context context = getTargetContext();
        CountDownLatch connected = new CountDownLatch(1);
        IBinder[] remote = new IBinder[1];
        ServiceConnection connection = new ServiceConnection() {
            @Override
            public void onServiceConnected(ComponentName name, IBinder service) {
                remote[0] = service;
                connected.countDown();
            }
            @Override
            public void onServiceDisconnected(ComponentName name) {}
        };
        boolean bound = false;
        try {
            bound = context.bindService(
                new Intent(context, ProbeService.class), connection, Context.BIND_AUTO_CREATE);
            if (!bound || !connected.await(15, TimeUnit.SECONDS)) {
                throw new IllegalStateException("Probe service did not connect");
            }
            int firstPid = -1;
            String firstVersion = null;
            for (int attempt = 0; attempt < 2; attempt++) {
                Parcel data = Parcel.obtain();
                Parcel reply = Parcel.obtain();
                try {
                    data.writeInterfaceToken(ProbeService.DESCRIPTOR);
                    if (!remote[0].transact(ProbeService.PROBE, data, reply, 0)) {
                        throw new IllegalStateException("Probe transaction was rejected");
                    }
                    reply.readException();
                    int pid = reply.readInt();
                    String version = reply.readString();
                    if (pid <= 0 || pid == Process.myPid()) {
                        throw new IllegalStateException("Probe did not run in a separate process");
                    }
                    if (attempt == 0) {
                        firstPid = pid;
                        firstVersion = version;
                    } else if (pid != firstPid || !firstVersion.equals(version)) {
                        throw new IllegalStateException("Probe runtime changed between calls");
                    }
                } finally {
                    data.recycle();
                    reply.recycle();
                }
            }
            result.putString("stream", "PASS: isolated libbox " + firstVersion
                + ", remote PID " + firstPid + ", 2/2 Binder calls\\n");
            finish(Activity.RESULT_OK, result);
        } catch (Exception | LinkageError error) {
            result.putString("stream", "FAIL: " + error + "\n");
            finish(Activity.RESULT_CANCELED, result);
        } finally {
            if (bound) context.unbindService(connection);
        }
    }
}
