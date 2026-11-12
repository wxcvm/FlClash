package org.flclash.singboxprobe.isolated;

import android.content.Context;
import io.nekohasekai.libbox.CommandServer;
import io.nekohasekai.libbox.CommandServerHandler;
import io.nekohasekai.libbox.Libbox;
import io.nekohasekai.libbox.OverrideOptions;
import io.nekohasekai.libbox.PlatformInterface;
import io.nekohasekai.libbox.SetupOptions;
import java.io.File;
import java.io.IOException;

/**
 * One native session in the isolated process. The platform implementation
 * must delegate OpenTun and socket protection to the supplied AndroidTunBridge.
 * The caller owns VPN consent, service lifetime and network callbacks.
 */
public final class LibboxVpnSession implements AutoCloseable {
    private static boolean initialized;
    private final AndroidTunBridge bridge;
    private final PlatformInterface platform;
    private final CommandServerHandler handler;
    private CommandServer server;

    public LibboxVpnSession(AndroidTunBridge bridge, PlatformInterface platform,
                            CommandServerHandler handler) {
        this.bridge = bridge;
        this.platform = platform;
        this.handler = handler;
    }

    private static synchronized void setup(Context context) throws Exception {
        if (initialized) return;
        File base = new File(context.getFilesDir(), "singbox");
        File working = new File(base, "working");
        File temp = new File(context.getCacheDir(), "singbox");
        for (File directory : new File[] {base, working, temp}) {
            if (!directory.isDirectory() && !directory.mkdirs()) {
                throw new IOException("Cannot create sing-box private directory: " + directory);
            }
        }
        SetupOptions options = new SetupOptions();
        options.setBasePath(base.getAbsolutePath());
        options.setWorkingPath(working.getAbsolutePath());
        options.setTempPath(temp.getAbsolutePath());
        options.setCommandServerListenPort(0); // private Unix socket, never a TCP listener
        options.setLogMaxLines(100);
        options.setFixAndroidStack(true);
        go.Seq.setContext(context.getApplicationContext());
        Libbox.setup(options);
        initialized = true;
    }

    public static void validate(Context context, String config) throws Exception {
        setup(context);
        // Reject incompatible profiles before invoking OpenTun or creating routes.
        Libbox.checkConfig(config);
        if (!Libbox.hasTunInbound(config)) {
            throw new IllegalArgumentException("Android VPN requires a TUN inbound");
        }
    }

    public synchronized void start(Context context, String config) throws Exception {
        if (server != null) throw new IllegalStateException("libbox session already started");
        validate(context, config);
        try {
            server = Libbox.newCommandServer(handler, platform);
            server.start();
            server.startOrReloadService(config, new OverrideOptions());
        } catch (Exception | LinkageError failure) {
            try {
                close();
            } catch (Exception | LinkageError cleanup) {
                if (cleanup != failure) failure.addSuppressed(cleanup);
            }
            throw failure;
        }
    }

    public synchronized void resetNetwork() {
        if (server != null) server.resetNetwork();
    }

    @Override
    public synchronized void close() throws Exception {
        CommandServer active = server;
        server = null;
        // Keep Java's original TUN descriptor until libbox closes its own copy.
        // Always close the command server and bridge even if native stop fails.
        Exception failure = null;
        if (active != null) {
            try {
                active.closeService();
            } catch (Exception error) {
                failure = error;
            } finally {
                try {
                    active.close();
                } finally {
                    try {
                        bridge.close();
                    } catch (IOException error) {
                        if (failure == null) throw error;
                        failure.addSuppressed(error);
                    }
                }
            }
        } else {
            bridge.close();
        }
        if (failure != null) throw failure;
    }
}
