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
import java.util.concurrent.atomic.AtomicBoolean;
import java.lang.reflect.InvocationTargetException;

/** Explicitly consented, app-only VPN in the same isolated process as libbox. */
public final class ProbeVpnService extends VpnService {
    private static final String TAG = "FlClashVpnProbe";
    static final String STATUS = "org.flclash.singboxprobe.VPN_STATUS";
    static final String STATUS_PERMISSION = "org.flclash.singboxprobe.permission.VPN_STATUS";
    static final String RETEST = "org.flclash.singboxprobe.RETEST_VPN";
    static final String STOP = "org.flclash.singboxprobe.STOP_VPN";
    // Serialize even across rapid stop/start and let the worker expire while idle.
    private static final ThreadPoolExecutor WORKER = new ThreadPoolExecutor(
        0, 1, 10, TimeUnit.SECONDS, new LinkedBlockingQueue<>());
    private static final String CONFIG = "{"
        + "\"log\":{\"level\":\"warn\"},"
        + "\"dns\":{\"servers\":[{\"type\":\"local\",\"tag\":\"android\"}],\"final\":\"android\",\"disable_cache\":true},"
        + "\"inbounds\":[{\"type\":\"tun\",\"tag\":\"probe\","
        + "\"address\":[\"172.19.0.1/30\"],\"auto_route\":true,"
        + "\"dns_mode\":\"hijack\",\"dns_address\":[\"172.19.0.2\"],\"route_address\":[\"1.1.1.1/32\",\"172.19.0.2/32\"],"
        + "\"include_package\":[\"org.flclash.singboxprobe\"],\"stack\":\"system\"}],"
        + "\"outbounds\":[{\"type\":\"direct\",\"tag\":\"direct\"}],"
        + "\"route\":{\"auto_detect_interface\":true,\"rules\":[{\"port\":53,\"action\":\"hijack-dns\"}],\"final\":\"direct\"}}";

    private boolean started;
    private final AtomicBoolean retestQueued = new AtomicBoolean();
    private volatile String status = "Starting diagnostic VPN";

    private void report(String message) {
        status = message;
        Log.i(TAG, message);
        sendBroadcast(new Intent(STATUS).setPackage(getPackageName())
            .putExtra("message", message), STATUS_PERMISSION);
    }
    private volatile boolean destroyed;
    // Accessed only by WORKER.
    private AutoCloseable runtime;

    @Override public int onStartCommand(Intent intent, int flags, int startId) {
        if (intent != null && STOP.equals(intent.getAction())) {
            stopSelf();
            return START_NOT_STICKY;
        }
        if (intent != null && RETEST.equals(intent.getAction())) {
            if (!started) {
                report("VPN is not running. Authorize and start first.");
                stopSelf();
            } else {
                enqueueRetest();
            }
            return START_NOT_STICKY;
        }
        if (started) {
            report(status);
            return START_NOT_STICKY;
        }
        started = true;
        if (prepare(this) != null) {
            report("FAIL: VPN consent is missing");
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
            .setContentText("Only diagnostic app: HTTPS and DNS")
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
                if (destroyed) return;
                report("VPN started; verifying actual HTTPS and DNS traffic...");
                String result = ProbeVpnTraffic.verify(this, () -> destroyed);
                if (!destroyed) report(result);
            } catch (Exception | LinkageError error) {
                Log.e(TAG, "VPN runtime or traffic test failed", error);
                if (!destroyed) report("FAIL: " + failureMessage(error));
                closeRuntime();
                stopSelf();
            }
        });
        return START_NOT_STICKY;
    }

    private static String failureMessage(Throwable error) {
        if (error instanceof InvocationTargetException && error.getCause() != null) {
            error = error.getCause();
        }
        return error.getMessage() == null ? error.toString() : error.getMessage();
    }

    private void enqueueRetest() {
        if (!retestQueued.compareAndSet(false, true)) return;
        WORKER.execute(() -> {
            try {
                if (destroyed || runtime == null) return;
                report("Rechecking VPN HTTPS and DNS without restarting the core...");
                String result = ProbeVpnTraffic.verify(this, () -> destroyed);
                if (!destroyed) report(result);
            } catch (Exception | LinkageError error) {
                // Leave the VPN running so a network handover can recover.
                if (!destroyed) report("RETEST FAIL: " + failureMessage(error));
            } finally {
                retestQueued.set(false);
            }
        });
    }

    private void closeRuntime() {
        AutoCloseable active = runtime;
        runtime = null;
        if (active == null) return;
        try {
            active.close();
            active.getClass().getMethod("verifyStopped").invoke(active);
            ProbeVpnTraffic.verifyRemoved(this);
            report(status + "\nSTOP PASS: VPN removed; TUN, command server and network monitor released");
        } catch (Exception | LinkageError error) {
            Log.e(TAG, "VPN runtime cleanup failed", error);
            report(status + "\nSTOP FAIL: " + failureMessage(error));
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
