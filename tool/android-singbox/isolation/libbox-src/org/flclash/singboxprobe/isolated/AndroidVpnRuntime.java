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

    public AndroidVpnRuntime(VpnService service) {
        this.service = service;
        AndroidTunBridge bridge = new AndroidTunBridge(service);
        platform = new AndroidPlatform(service, bridge);
        session = new LibboxVpnSession(bridge, platform, this);
    }

    public void start(String config) throws Exception {
        session.start(service, config);
    }

    public String snapshot() throws Exception { return NativeTelemetry.snapshot(); }
    public void selectOutbound(String group, String tag) throws Exception { NativeTelemetry.select(group, tag); }
    public void testOutbound(String tag) throws Exception { NativeTelemetry.test(tag); }

    public void resetNetwork() { session.resetNetwork(); }

    @Override public void close() throws Exception {
        try {
            session.close();
        } finally {
            platform.close();
        }
    }

    @Override public void serviceStop() { service.stopSelf(); }
    @Override public void serviceReload() throws Exception {
        throw new IOException("Stop and restart the diagnostic VPN to reload");
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
