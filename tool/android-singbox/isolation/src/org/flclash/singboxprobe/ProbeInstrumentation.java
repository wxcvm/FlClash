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
import android.os.ParcelFileDescriptor;
import android.os.Process;
import com.follow.clash.core.mobile.Mobile;
import java.io.DataInputStream;
import java.io.DataOutputStream;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.TimeUnit;

public final class ProbeInstrumentation extends Instrumentation {
    @Override
    public void onCreate(Bundle arguments) {
        super.onCreate(arguments);
        start();
    }

    private static void verifyDescriptorTransfer(IBinder remote) throws Exception {
        ParcelFileDescriptor[] pipe = ParcelFileDescriptor.createPipe();
        Parcel data = Parcel.obtain();
        Parcel reply = Parcel.obtain();
        try (ParcelFileDescriptor readEnd = pipe[0];
             DataOutputStream output = new DataOutputStream(
                 new ParcelFileDescriptor.AutoCloseOutputStream(pipe[1]))) {
            output.writeInt(ProbeService.FD_CHALLENGE);
            output.flush();
            data.writeInterfaceToken(ProbeService.DESCRIPTOR);
            readEnd.writeToParcel(data, 0);
            if (!remote.transact(ProbeService.TRANSFER_FD, data, reply, 0)) {
                throw new IllegalStateException("Descriptor transaction was rejected");
            }
            reply.readException();
            try (ParcelFileDescriptor returned = ParcelFileDescriptor.CREATOR.createFromParcel(reply);
                 DataInputStream input = new DataInputStream(
                     new ParcelFileDescriptor.AutoCloseInputStream(returned))) {
                if (input.readInt() != ProbeService.FD_RESPONSE) {
                    throw new IllegalStateException("Invalid returned descriptor response");
                }
            }
        } finally {
            data.recycle();
            reply.recycle();
        }
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
            Mobile.touch();
            Mobile.forceGC();
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
            verifyDescriptorTransfer(remote[0]);
            Mobile.forceGC();
            result.putString("stream", "PASS: real Mihomo + isolated libbox " + firstVersion
                + ", remote PID " + firstPid + ", 2/2 Binder calls\n");
            finish(Activity.RESULT_OK, result);
        } catch (Exception | LinkageError error) {
            result.putString("stream", "FAIL: " + error + "\n");
            finish(Activity.RESULT_CANCELED, result);
        } finally {
            if (bound) context.unbindService(connection);
        }
    }
}
