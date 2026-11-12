package org.flclash.libboxprobe;

import android.net.ConnectivityManager;
import android.net.LinkProperties;
import android.net.Network;
import android.net.NetworkCapabilities;
import android.net.VpnService;
import android.os.ParcelFileDescriptor;
import android.system.OsConstants;
import go.Seq;
import io.nekohasekai.libbox.*;
import java.io.File;
import java.lang.reflect.Proxy;
import java.net.InetAddress;
import java.net.InterfaceAddress;
import java.util.ArrayList;
import java.util.Collections;
import java.util.Iterator;
import java.util.List;
import java.util.concurrent.atomic.AtomicInteger;

/** Test-only local TCP route. No production settings or arbitrary profiles. */
public final class RealVpnRuntime {
    private final VpnService service;
    private final AtomicInteger protectedSockets = new AtomicInteger();
    private CommandServer server;
    private ParcelFileDescriptor tun;

    public RealVpnRuntime(VpnService service) { this.service = service; }

    public void start(int port) throws Exception {
        if (port < 1 || port > 65535) throw new IllegalArgumentException("Invalid echo port");
        Seq.setContext(service.getApplicationContext());
        File base = new File(service.getFilesDir(), "libbox-vpn-probe");
        if (!base.isDirectory() && !base.mkdirs()) throw new IllegalStateException("Cannot create probe directory");
        SetupOptions setup = new SetupOptions();
        setup.setBasePath(base.getAbsolutePath());
        setup.setWorkingPath(base.getAbsolutePath());
        setup.setTempPath(service.getCacheDir().getAbsolutePath());
        setup.setLogMaxLines(100);
        Libbox.setup(setup);
        String config = "{\"inbounds\":[{\"type\":\"tun\",\"tag\":\"tun\","
            + "\"address\":[\"198.18.0.1/30\"],\"auto_route\":true,\"stack\":\"gvisor\","
            + "\"dns_mode\":\"disabled\",\"route_address\":[\"198.18.0.9/32\"],\"mtu\":1500}],"
            + "\"outbounds\":[{\"type\":\"direct\",\"tag\":\"direct\"}],"
            + "\"route\":{\"auto_detect_interface\":true,\"rules\":[{\"ip_cidr\":[\"198.18.0.9/32\"],"
            + "\"action\":\"route\",\"outbound\":\"direct\",\"override_address\":\"127.0.0.1\","
            + "\"override_port\":" + port + "}],\"final\":\"direct\"}}";
        Libbox.checkConfig(config);
        PlatformInterface platform = (PlatformInterface) Proxy.newProxyInstance(
            PlatformInterface.class.getClassLoader(), new Class<?>[]{PlatformInterface.class},
            (proxy, method, args) -> {
                switch (method.getName()) {
                    case "usePlatformAutoDetectInterfaceControl": return true;
                    case "autoDetectInterfaceControl":
                        if (!service.protect((Integer) args[0])) throw new IllegalStateException("Socket protect rejected");
                        protectedSockets.incrementAndGet(); return null;
                    case "openTun": return openTun((TunOptions) args[0]);
                    case "getInterfaces": return interfaces();
                    case "startDefaultInterfaceMonitor":
                        publishDefault((InterfaceUpdateListener) args[0]); return null;
                    case "closeDefaultInterfaceMonitor":
                    case "clearDNSCache":
                    case "registerMyInterface":
                    case "sendNotification":
                    case "cancelNotification":
                    case "startNeighborMonitor":
                    case "closeNeighborMonitor": return null;
                    case "underNetworkExtension":
                    case "includeAllNetworks":
                    case "usePlatformShell":
                    case "usePlatformBridge": return false;
                    case "localDNSTransport":
                    case "readWIFIState": return null;
                    case "tailscaleHostname": return "flclash-probe";
                    case "findConnectionOwner": return new ConnectionOwner();
                    default: throw new UnsupportedOperationException("Probe platform: " + method.getName());
                }
            });
        CommandServerHandler handler = (CommandServerHandler) Proxy.newProxyInstance(
            CommandServerHandler.class.getClassLoader(), new Class<?>[]{CommandServerHandler.class},
            (proxy, method, args) -> {
                switch (method.getName()) {
                    case "writeDebugMessage": return null;
                    case "getSystemProxyStatus": return new SystemProxyStatus();
                    default: throw new UnsupportedOperationException("Probe handler: " + method.getName());
                }
            });
        server = Libbox.newCommandServer(handler, platform);
        try {
            server.start();
            server.startOrReloadService(config, new OverrideOptions());
            if (tun == null) throw new IllegalStateException("libbox did not establish TUN");
        } catch (Exception error) {
            try { stop(); } catch (Exception cleanup) { error.addSuppressed(cleanup); }
            throw error;
        }
    }

    private int openTun(TunOptions options) throws Exception {
        if (tun != null) throw new IllegalStateException("Duplicate TUN open");
        if (VpnService.prepare(service) != null) throw new IllegalStateException("VPN consent lost");
        VpnService.Builder builder = service.new Builder()
            .setSession("FlClash local TUN diagnostic")
            .setMtu(options.getMTU()).setBlocking(false).setMetered(false)
            .addAddress("198.18.0.1", 30).addRoute("198.18.0.9", 32)
            .addAllowedApplication(service.getPackageName());
        tun = builder.establish();
        if (tun == null) throw new IllegalStateException("Android rejected TUN");
        // libbox duplicates this descriptor; retain and close the original.
        return tun.getFd();
    }

    private ConnectivityManager connectivity() {
        return service.getSystemService(ConnectivityManager.class);
    }

    private List<NetworkInterface> snapshot() throws Exception {
        List<NetworkInterface> values = new ArrayList<>();
        ConnectivityManager cm = connectivity();
        for (Network network : cm.getAllNetworks()) {
            NetworkCapabilities caps = cm.getNetworkCapabilities(network);
            LinkProperties link = cm.getLinkProperties(network);
            if (caps == null || link == null || link.getInterfaceName() == null
                || caps.hasTransport(NetworkCapabilities.TRANSPORT_VPN)) continue;
            java.net.NetworkInterface nic = java.net.NetworkInterface.getByName(link.getInterfaceName());
            if (nic == null) continue;
            NetworkInterface value = new NetworkInterface();
            value.setName(nic.getName());
            value.setIndex(nic.getIndex());
            value.setMTU(nic.getMTU());
            value.setFlags(OsConstants.IFF_UP | OsConstants.IFF_RUNNING);
            value.setType(caps.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) ? Libbox.InterfaceTypeWIFI
                : caps.hasTransport(NetworkCapabilities.TRANSPORT_CELLULAR) ? Libbox.InterfaceTypeCellular
                : caps.hasTransport(NetworkCapabilities.TRANSPORT_ETHERNET) ? Libbox.InterfaceTypeEthernet
                : Libbox.InterfaceTypeOther);
            value.setMetered(!caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_NOT_METERED));
            List<String> addresses = new ArrayList<>(), dns = new ArrayList<>();
            for (InterfaceAddress address : nic.getInterfaceAddresses()) {
                String host = address.getAddress().getHostAddress().split("%")[0];
                addresses.add(host + "/" + address.getNetworkPrefixLength());
            }
            for (InetAddress address : link.getDnsServers()) dns.add(address.getHostAddress().split("%")[0]);
            value.setAddresses(strings(addresses));
            value.setDNSServer(strings(dns));
            value.setGateway(strings(Collections.emptyList()));
            values.add(value);
        }
        return values;
    }

    private static StringIterator strings(List<String> values) {
        return new StringIterator() {
            int index;
            public int len() { return values.size() - index; }
            public boolean hasNext() { return index < values.size(); }
            public String next() { return hasNext() ? values.get(index++) : ""; }
        };
    }

    private NetworkInterfaceIterator interfaces() throws Exception {
        Iterator<NetworkInterface> iterator = snapshot().iterator();
        return new NetworkInterfaceIterator() {
            public boolean hasNext() { return iterator.hasNext(); }
            public NetworkInterface next() { return iterator.hasNext() ? iterator.next() : null; }
        };
    }

    private void publishDefault(InterfaceUpdateListener listener) throws Exception {
        List<NetworkInterface> values = snapshot();
        if (values.isEmpty()) listener.updateDefaultInterface("", -1, false, false);
        else {
            NetworkInterface value = values.get(0);
            listener.updateDefaultInterface(value.getName(), value.getIndex(), value.getMetered(), false);
        }
    }

    public int protectCount() { return protectedSockets.get(); }

    public void stop() throws Exception {
        try {
            if (server != null) {
                try { server.closeService(); } finally { server.close(); server = null; }
            }
        } finally {
            if (tun != null) { try { tun.close(); } finally { tun = null; } }
        }
    }
}
