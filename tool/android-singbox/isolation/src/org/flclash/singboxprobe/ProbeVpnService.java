package org.flclash.singboxprobe;

import android.app.Notification;
import android.app.NotificationChannel;
import android.app.NotificationManager;
import android.app.PendingIntent;
import android.content.Intent;
import android.net.VpnService;
import android.util.Log;
import java.util.concurrent.LinkedBlockingQueue;
import java.util.concurrent.ThreadPoolExecutor;
import java.util.concurrent.TimeUnit;

/** Explicitly consented, app-only VPN in the same isolated process as libbox. */
public final class ProbeVpnService extends VpnService {
    private static final String TAG = "FlClashVpnProbe";
    static final String STOP = "org.flclash.singboxprobe.STOP_VPN";
    // Serialize even across rapid stop/start and let the worker expire while idle.
    private static final ThreadPoolExecutor WORKER = new ThreadPoolExecutor(
        0, 1, 10, TimeUnit.SECONDS, new LinkedBlockingQueue<>());
    private static final String CONFIG = "{"
        + "\"log\":{\"level\":\"warn\"},"
        + "\"inbounds\":[{\"type\":\"tun\",\"tag\":\"probe\","
        + "\"address\":[\"172.19.0.1/30\"],\"auto_route\":true,"
        + "\"dns_mode\":\"disabled\",\"route_address\":[\"1.1.1.1/32\"],"
        + "\"include_package\":[\"org.flclash.singboxprobe\"],\"stack\":\"system\"}],"
        + "\"outbounds\":[{\"type\":\"direct\",\"tag\":\"direct\"}],"
        + "\"route\":{\"auto_detect_interface\":true,\"final\":\"direct\"}}";

    private boolean started;
    private volatile boolean destroyed;
    // Accessed only by WORKER.
    private AutoCloseable runtime;

    @Override public int onStartCommand(Intent intent, int flags, int startId) {
        if (intent != null && STOP.equals(intent.getAction())) {
            stopSelf();
            return START_NOT_STICKY;
        }
        if (started) return START_NOT_STICKY;
        started = true;
        if (prepare(this) != null) {
            Log.e(TAG, "VPN consent is missing");
            stopSelf();
            return START_NOT_STICKY;
        }
        NotificationManager manager = getSystemService(NotificationManager.class);
        manager.createNotificationChannel(new NotificationChannel(
            "probe-vpn", "FlClash VPN diagnostic", NotificationManager.IMPORTANCE_LOW));
        PendingIntent stop = PendingIntent.getService(this, 1,
            new Intent(this, ProbeVpnService.class).setAction(STOP),
            PendingIntent.FLAG_IMMUTABLE | PendingIntent.FLAG_UPDATE_CURRENT);
        Notification notification = new Notification.Builder(this, "probe-vpn")
            .setContentTitle("FlClash diagnostic VPN")
            .setContentText("Only the diagnostic app is routed to 1.1.1.1")
            .setSmallIcon(android.R.drawable.ic_lock_lock)
            .setOngoing(true)
            .addAction(new Notification.Action.Builder(null, "Stop", stop).build())
            .build();
        startForeground(1, notification);

        WORKER.execute(() -> {
            if (destroyed) return;
            try {
                Class<?> api = ProbeService.loadApi(this);
                Class<?> type = Class.forName(
                    "org.flclash.singboxprobe.isolated.AndroidVpnRuntime", true, api.getClassLoader());
                runtime = (AutoCloseable) type.getConstructor(VpnService.class).newInstance(this);
                type.getMethod("start", String.class).invoke(runtime, CONFIG);
                Log.i(TAG, "VPN runtime started");
            } catch (Exception | LinkageError error) {
                Log.e(TAG, "VPN runtime failed", error);
                closeRuntime();
                stopSelf();
            }
        });
        return START_NOT_STICKY;
    }

    private void closeRuntime() {
        AutoCloseable active = runtime;
        runtime = null;
        if (active == null) return;
        try {
            active.close();
            Log.i(TAG, "VPN runtime stopped");
        } catch (Exception | LinkageError error) {
            Log.e(TAG, "VPN runtime cleanup failed", error);
        }
    }

    @Override public void onRevoke() { stopSelf(); }

    @Override public void onDestroy() {
        destroyed = true;
        WORKER.execute(this::closeRuntime);
        stopForeground(STOP_FOREGROUND_REMOVE);
        super.onDestroy();
    }
}
