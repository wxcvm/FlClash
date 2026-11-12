package org.flclash.singboxprobe.isolated;

import android.net.VpnService;
import io.nekohasekai.libbox.CommandServerHandler;
import io.nekohasekai.libbox.SystemProxyStatus;
import java.io.IOException;

/** Owns the platform, TUN and native command server for one consented diagnostic VPN. */
public final class AndroidVpnRuntime implements AutoCloseable, CommandServerHandler {
    private final VpnService service;
    private final AndroidPlatform platform;
    private final LibboxVpnSession session;
    private final Runnable requestStop;

    public AndroidVpnRuntime(VpnService service) {
        this(service, service::stopSelf);
    }

    public AndroidVpnRuntime(VpnService service, Runnable requestStop) {
        this.service = service;
        this.requestStop = requestStop;
        AndroidTunBridge bridge = new AndroidTunBridge(service);
        platform = new AndroidPlatform(service, bridge);
        session = new LibboxVpnSession(bridge, platform, this);
    }

    public void start(String config) throws Exception {
        session.start(service, config);
    }

    public void resetNetwork() { session.resetNetwork(); }

    @Override public void close() throws Exception {
        try {
            session.close();
        } finally {
            platform.close();
        }
    }

    @Override public void serviceStop() { requestStop.run(); }
    @Override public void serviceReload() throws Exception {
        throw new IOException("Stop and restart the native VPN to reload");
    }
    @Override public SystemProxyStatus getSystemProxyStatus() { return new SystemProxyStatus(); }
    @Override public void setSystemProxyEnabled(boolean enabled) throws Exception {
        if (enabled) throw new IOException("Diagnostic VPN does not expose an HTTP proxy");
    }
    @Override public void triggerNativeCrash() throws Exception {
        throw new IOException("Native crash command disabled");
    }
    @Override public void writeDebugMessage(String message) { }
    @Override public int connectSSHAgent() throws Exception {
        throw new IOException("SSH agent is not available in diagnostic VPN");
    }
}
