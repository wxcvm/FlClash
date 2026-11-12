package org.flclash.singboxprobe.isolated;

import android.content.Context;
import android.net.ConnectivityManager;
import android.net.DnsResolver;
import android.net.LinkProperties;
import android.net.Network;
import android.net.NetworkCapabilities;
import android.net.NetworkRequest;
import android.net.RouteInfo;
import android.net.VpnService;
import android.os.Build;
import android.os.CancellationSignal;
import android.os.Handler;
import android.os.HandlerThread;
import android.system.OsConstants;
import io.nekohasekai.libbox.*;
import java.io.IOException;
import java.net.InetAddress;
import java.net.InetSocketAddress;
import java.net.InterfaceAddress;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.Collections;
import java.util.List;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.TimeUnit;

/** Platform callbacks for the isolated Android VPN. No polling; a callback thread exists only during monitoring. */
public final class AndroidPlatform implements PlatformInterface, AutoCloseable {
    private final VpnService service;
    private final AndroidTunBridge tun;
    private final ConnectivityManager connectivity;
    private volatile Network underlying;
    private volatile ConnectivityManager.NetworkCallback callback;
    private HandlerThread monitorThread;

    public AndroidPlatform(VpnService service, AndroidTunBridge tun) {
        this.service = service;
        this.tun = tun;
        this.connectivity = service.getSystemService(ConnectivityManager.class);
    }

    @Override public int openTun(TunOptions options) throws Exception {
        return tun.openTun(options);
    }
    @Override public boolean usePlatformAutoDetectInterfaceControl() { return true; }
    @Override public void autoDetectInterfaceControl(int fd) throws Exception {
        tun.autoDetectInterfaceControl(fd);
    }

    @Override public ConnectionOwner findConnectionOwner(int protocol, String source,
            int sourcePort, String destination, int destinationPort) throws Exception {
        int uid = connectivity.getConnectionOwnerUid(protocol,
            new InetSocketAddress(source, sourcePort),
            new InetSocketAddress(destination, destinationPort));
        if (uid < 0) throw new IOException("Android connection owner not found");
        String[] packages = service.getPackageManager().getPackagesForUid(uid);
        ConnectionOwner owner = new ConnectionOwner();
        owner.setUserId(uid);
        owner.setUserName(packages == null || packages.length == 0 ? "" : packages[0]);
        owner.setAndroidPackageNames(strings(packages == null
            ? Collections.emptyList() : Arrays.asList(packages)));
        return owner;
    }

    @Override public synchronized void startDefaultInterfaceMonitor(InterfaceUpdateListener listener)
            throws Exception {
        if (callback != null) throw new IllegalStateException("Network monitor already started");
        NetworkRequest request = new NetworkRequest.Builder()
            .addCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)
            .addCapability(NetworkCapabilities.NET_CAPABILITY_NOT_VPN).build();
        ConnectivityManager.NetworkCallback next = new ConnectivityManager.NetworkCallback() {
            @Override public void onAvailable(Network network) {
                if (callback != this) return;
                underlying = network;
            }
            @Override public void onLinkPropertiesChanged(Network network, LinkProperties link) {
                if (callback != this || !network.equals(underlying)) return;
                publish(listener, network, link, connectivity.getNetworkCapabilities(network));
            }
            @Override public void onCapabilitiesChanged(Network network, NetworkCapabilities caps) {
                if (callback != this || !network.equals(underlying)) return;
                publish(listener, network, connectivity.getLinkProperties(network), caps);
            }
            @Override public void onLost(Network network) {
                if (callback != this || !network.equals(underlying)) return;
                underlying = null;
                listener.updateDefaultInterface("", -1, false, false);
            }
        };
        callback = next;
        monitorThread = new HandlerThread("flclash-libbox-network");
        monitorThread.start();
        Handler handler = new Handler(monitorThread.getLooper());
        try {
            if (Build.VERSION.SDK_INT >= 31) {
                connectivity.registerBestMatchingNetworkCallback(request, next,
                    handler);
            } else {
                connectivity.requestNetwork(request, next, handler);
            }
        } catch (RuntimeException error) {
            callback = null;
            underlying = null;
            monitorThread.quitSafely();
            monitorThread = null;
            throw error;
        }
    }

    private void publish(InterfaceUpdateListener listener, Network network,
            LinkProperties link, NetworkCapabilities caps) {
        if (link == null || caps == null || link.getInterfaceName() == null) return;
        try {
            java.net.NetworkInterface nic = java.net.NetworkInterface.getByName(link.getInterfaceName());
            if (nic == null) return;
            listener.updateDefaultInterface(nic.getName(), nic.getIndex(),
                !caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_NOT_METERED), false);
        } catch (java.net.SocketException error) {
            android.util.Log.w("FlClashLibbox", "Cannot read underlying network interface", error);
        }
    }

    @Override public void closeDefaultInterfaceMonitor(InterfaceUpdateListener listener) {
        close();
    }

    @Override public synchronized void close() {
        ConnectivityManager.NetworkCallback active = callback;
        callback = null;
        underlying = null;
        try {
            if (active != null) connectivity.unregisterNetworkCallback(active);
        } finally {
            if (monitorThread != null) monitorThread.quitSafely();
            monitorThread = null;
        }
    }

    @Override public NetworkInterfaceIterator getInterfaces() throws Exception {
        return interfaces(connectivity);
    }

    private static NetworkInterfaceIterator interfaces(ConnectivityManager manager) throws Exception {
        List<io.nekohasekai.libbox.NetworkInterface> result = new ArrayList<>();
        for (Network network : manager.getAllNetworks()) {
            LinkProperties link = manager.getLinkProperties(network);
            NetworkCapabilities caps = manager.getNetworkCapabilities(network);
            if (link == null || caps == null || link.getInterfaceName() == null
                || !caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_NOT_VPN)) continue;
            java.net.NetworkInterface nic = java.net.NetworkInterface.getByName(link.getInterfaceName());
            if (nic == null) continue;
            io.nekohasekai.libbox.NetworkInterface item = new io.nekohasekai.libbox.NetworkInterface();
            item.setName(nic.getName());
            item.setIndex(nic.getIndex());
            item.setMTU(nic.getMTU());
            int flags = 0;
            if (nic.isUp()) flags |= OsConstants.IFF_UP | OsConstants.IFF_RUNNING;
            if (nic.isLoopback()) flags |= OsConstants.IFF_LOOPBACK;
            if (nic.isPointToPoint()) flags |= OsConstants.IFF_POINTOPOINT;
            if (nic.supportsMulticast()) flags |= OsConstants.IFF_MULTICAST;
            item.setFlags(flags);
            item.setMetered(!caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_NOT_METERED));
            item.setType(caps.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) ? Libbox.InterfaceTypeWIFI
                : caps.hasTransport(NetworkCapabilities.TRANSPORT_CELLULAR) ? Libbox.InterfaceTypeCellular
                : caps.hasTransport(NetworkCapabilities.TRANSPORT_ETHERNET) ? Libbox.InterfaceTypeEthernet
                : Libbox.InterfaceTypeOther);
            List<String> addresses = new ArrayList<>();
            for (InterfaceAddress address : nic.getInterfaceAddresses()) {
                // Recreate the address without an IPv6 scope suffix for netip.ParsePrefix.
                addresses.add(InetAddress.getByAddress(address.getAddress().getAddress()).getHostAddress()
                    + "/" + address.getNetworkPrefixLength());
            }
            List<String> dns = new ArrayList<>();
            for (InetAddress address : link.getDnsServers()) dns.add(address.getHostAddress());
            List<String> gateways = new ArrayList<>();
            for (RouteInfo route : link.getRoutes()) {
                if (route.isDefaultRoute() && route.getGateway() != null
                    && !route.getGateway().isAnyLocalAddress()) gateways.add(route.getGateway().getHostAddress());
            }
            item.setAddresses(strings(addresses));
            item.setDNSServer(strings(dns));
            item.setGateway(strings(gateways));
            result.add(item);
        }
        return new NetworkInterfaceIterator() {
            private int index;
            public boolean hasNext() { return index < result.size(); }
            public io.nekohasekai.libbox.NetworkInterface next() { return result.get(index++); }
        };
    }

    private static StringIterator strings(List<String> values) {
        return new StringIterator() {
            private int index;
            public int len() { return values.size() - index; }
            public boolean hasNext() { return index < values.size(); }
            public String next() { return values.get(index++); }
        };
    }

    /** Raw system DNS on the underlying network, never the VPN default network. */
    @Override public LocalDNSTransport localDNSTransport() {
        return new LocalDNSTransport() {
            public boolean raw() { return true; }
            public void lookup(ExchangeContext ctx, String network, String domain) throws Exception {
                throw unsupported("non-raw local DNS");
            }
            public void exchange(ExchangeContext ctx, byte[] message) throws Exception {
                Network network = underlying;
                if (network == null) throw new IOException("No underlying network for local DNS");
                CancellationSignal signal = new CancellationSignal();
                CountDownLatch done = new CountDownLatch(1);
                byte[][] answer = new byte[1][];
                Exception[] failure = new Exception[1];
                ctx.onCancel(() -> { signal.cancel(); done.countDown(); });
                DnsResolver.getInstance().rawQuery(network, message, 0, Runnable::run, signal,
                    new DnsResolver.Callback<byte[]>() {
                        public void onAnswer(byte[] response, int rcode) {
                            answer[0] = response;
                            done.countDown();
                        }
                        public void onError(DnsResolver.DnsException error) {
                            failure[0] = error;
                            done.countDown();
                        }
                    });
                try {
                    if (!done.await(10, TimeUnit.SECONDS)) throw new IOException("Local DNS timed out");
                    if (signal.isCanceled()) throw new IOException("Local DNS canceled");
                    if (failure[0] != null) throw failure[0];
                    if (answer[0] == null) throw new IOException("Local DNS returned no response");
                    ctx.rawSuccess(answer[0]);
                } finally {
                    signal.cancel();
                }
            }
        };
    }

    // Optional facilities are not exposed by this non-root VPN diagnostic.
    private static IOException unsupported(String feature) {
        return new IOException("Unsupported Android diagnostic feature: " + feature);
    }
    @Override public boolean underNetworkExtension() { return false; }
    @Override public boolean includeAllNetworks() { return false; }
    @Override public WIFIState readWIFIState() { return null; }
    @Override public void clearDNSCache() { }
    @Override public void registerMyInterface(String name) { }
    @Override public void sendNotification(Notification notification) throws Exception { throw unsupported("notification"); }
    @Override public void cancelNotification(String identifier, int typeID) throws Exception { throw unsupported("notification"); }
    @Override public void startNeighborMonitor(NeighborUpdateListener listener) throws Exception { throw unsupported("neighbor monitor"); }
    @Override public void closeNeighborMonitor(NeighborUpdateListener listener) { }
    @Override public boolean usePlatformShell() { return false; }
    @Override public void checkPlatformShell() throws Exception { throw unsupported("shell"); }
    @Override public ShellSession openShellSession(PlatformUser user, String command, StringIterator environ,
            String term, int rows, int cols) throws Exception { throw unsupported("shell"); }
    @Override public PlatformUser lookupUser(String username) throws Exception { throw unsupported("user lookup"); }
    @Override public String lookupSFTPServer() throws Exception { throw unsupported("SFTP"); }
    @Override public String readSystemSSHHostKey() throws Exception { throw unsupported("SSH"); }
    @Override public String tailscaleHostname() { return "flclash-android"; }
    @Override public boolean usePlatformBridge() { return false; }
    @Override public BridgeSession createBridge(BridgeOptions options) throws Exception { throw unsupported("bridge"); }

    /** Enumerate real Android interfaces and exercise the generated iterator API without VPN consent. */
    public static void verifyNetworkSnapshot(Context context) throws Exception {
        NetworkInterfaceIterator iterator = interfaces(context.getSystemService(ConnectivityManager.class));
        while (iterator.hasNext()) {
            io.nekohasekai.libbox.NetworkInterface nic = iterator.next();
            if (nic.getIndex() <= 0 || nic.getName().isEmpty()) throw new IOException("Invalid interface identity");
            StringIterator addresses = nic.getAddresses();
            while (addresses.hasNext()) {
                if (!addresses.next().contains("/")) throw new IOException("Invalid interface prefix");
            }
        }
    }
}
