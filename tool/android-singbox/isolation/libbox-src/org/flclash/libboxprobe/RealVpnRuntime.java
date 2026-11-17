package org.flclash.libboxprobe;

import android.net.VpnService;
import org.flclash.singboxprobe.isolated.AndroidVpnRuntime;

/** Local TCP echo diagnostic, using the same typed platform as the manual VPN. */
public final class RealVpnRuntime {
    private final VpnService service;
    private final AndroidVpnRuntime runtime;

    public RealVpnRuntime(VpnService service) {
        this.service = service;
        runtime = new AndroidVpnRuntime(service);
    }

    public void start(int port) throws Exception {
        if (port < 1 || port > 65535) throw new IllegalArgumentException("Invalid echo port");
        String config = "{\"inbounds\":[{\"type\":\"tun\",\"tag\":\"tun\","
            + "\"address\":[\"198.18.0.1/30\"],\"auto_route\":true,\"stack\":\"gvisor\","
            + "\"dns_mode\":\"disabled\",\"route_address\":[\"198.18.0.9/32\"],"
            + "\"include_package\":[\"" + service.getPackageName() + "\"],\"mtu\":1500}],"
            + "\"outbounds\":[{\"type\":\"direct\",\"tag\":\"direct\"}],"
            + "\"route\":{\"auto_detect_interface\":true,\"rules\":[{\"ip_cidr\":[\"198.18.0.9/32\"],"
            + "\"action\":\"route\",\"outbound\":\"direct\",\"override_address\":\"127.0.0.1\","
            + "\"override_port\":" + port + "}],\"final\":\"direct\"}}";
        runtime.start(config);
    }

    public int protectCount() { return runtime.protectCount(); }
    public void stop() throws Exception { runtime.close(); }
}
