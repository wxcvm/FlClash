package org.flclash.singboxprobe;

import android.app.Activity;
import android.app.Instrumentation;
import android.content.ComponentName;
import android.content.Context;
import android.content.Intent;
import android.content.ServiceConnection;
import android.net.VpnService;
import android.os.Bundle;
import android.os.IBinder;
import android.os.Parcel;
import java.io.DataInputStream;
import java.io.DataOutputStream;
import java.net.InetAddress;
import java.net.InetSocketAddress;
import java.net.ServerSocket;
import java.net.Socket;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.FutureTask;
import java.util.concurrent.TimeUnit;

public final class VpnProbeInstrumentation extends Instrumentation {
    private static final int CHALLENGE = 0x1234abcd;
    private static final int RESPONSE = 0x4321dcba;

    @Override public void onCreate(Bundle args) { super.onCreate(args); start(); }

    private static int call(IBinder remote, int code, int arg) throws Exception {
        Parcel data = Parcel.obtain(), reply = Parcel.obtain();
        try {
            data.writeInterfaceToken(LocalVpnProbeService.TOKEN);
            data.writeInt(arg);
            if (!remote.transact(code, data, reply, 0)) throw new IllegalStateException("Rejected RPC");
            reply.readException();
            return reply.readInt();
        } finally { data.recycle(); reply.recycle(); }
    }

    @Override public void onStart() {
        Context context = getTargetContext();
        Bundle result = new Bundle();
        CountDownLatch connected = new CountDownLatch(1);
        IBinder[] remote = new IBinder[1];
        ServiceConnection connection = new ServiceConnection() {
            @Override public void onServiceConnected(ComponentName name, IBinder service) {
                remote[0] = service; connected.countDown();
            }
            @Override public void onServiceDisconnected(ComponentName name) {}
        };
        boolean bound = false;
        int code = Activity.RESULT_CANCELED;
        try (ServerSocket echo = new ServerSocket(0, 1, InetAddress.getByName("127.0.0.1"))) {
            if (VpnService.prepare(context) != null) throw new IllegalStateException("Grant VPN consent first");
            echo.setSoTimeout(12000);
            FutureTask<Void> server = new FutureTask<>(() -> {
                try (Socket socket = echo.accept()) {
                    socket.setSoTimeout(8000);
                    if (new DataInputStream(socket.getInputStream()).readInt() != CHALLENGE)
                        throw new IllegalStateException("Wrong challenge");
                    DataOutputStream output = new DataOutputStream(socket.getOutputStream());
                    output.writeInt(RESPONSE); output.flush();
                }
                return null;
            });
            Thread thread = new Thread(server, "local-echo");
            thread.setDaemon(true);
            thread.start();
            Intent intent = new Intent(context, LocalVpnProbeService.class).setAction(LocalVpnProbeService.ACTION);
            bound = context.bindService(intent, connection, Context.BIND_AUTO_CREATE);
            if (!bound || !connected.await(15, TimeUnit.SECONDS))
                throw new IllegalStateException("VPN service connection failed");
            call(remote[0], LocalVpnProbeService.START, echo.getLocalPort());
            try (Socket client = new Socket()) {
                client.connect(new InetSocketAddress("198.18.0.9", 23456), 8000);
                client.setSoTimeout(8000);
                DataOutputStream output = new DataOutputStream(client.getOutputStream());
                output.writeInt(CHALLENGE); output.flush();
                if (new DataInputStream(client.getInputStream()).readInt() != RESPONSE)
                    throw new IllegalStateException("Wrong response from TUN");
            }
            server.get(10, TimeUnit.SECONDS);
            int protectedSockets = call(remote[0], LocalVpnProbeService.PROTECT_COUNT, 0);
            if (protectedSockets < 1) throw new IllegalStateException("No native protect callback");
            call(remote[0], LocalVpnProbeService.STOP, 0);
            result.putString("stream", "PASS: real sing-box TUN, local TCP echo, protected sockets="
                + protectedSockets + "\n");
            code = Activity.RESULT_OK;
        } catch (Exception | LinkageError error) {
            result.putString("stream", "FAIL: " + error + "\n");
        } finally {
            if (remote[0] != null) {
                try { call(remote[0], LocalVpnProbeService.STOP, 0); }
                catch (Exception error) {
                    result.putString("stream", "FAIL: VPN cleanup: " + error + "\n");
                    code = Activity.RESULT_CANCELED;
                }
            }
            if (bound) context.unbindService(connection);
        }
        finish(code, result);
    }
}
