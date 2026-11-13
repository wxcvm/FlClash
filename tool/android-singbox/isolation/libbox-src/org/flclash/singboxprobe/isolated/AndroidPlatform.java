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
import java.util.concurrent.ConcurrentHashMap;
import java.util.concurrent.TimeUnit;

/** Platform callbacks for the isolated Android VPN. No polling; a callback thread exists only during monitoring. */
public final class AndroidPlatform implements PlatformInterface, AutoCloseable {
    private final VpnService service;
    private final AndroidTunBridge tun;
    private final ConnectivityManager connectivity;
    private final NetworkEpoch<Network> networks = new NetworkEpoch<>();
    private final ConcurrentHashMap<CancellationSignal, DnsQuery> dnsQueries = new ConcurrentHashMap<>();

    private static final class DnsQuery {
        final NetworkEpoch.Snapshot<Network> path;
        final CountDownLatch done = new CountDownLatch(1);
        DnsQuery(NetworkEpoch.Snapshot<Network> path) { this.path = path; }
    }

    NetworkEpoch.Snapshot<Network> networkPath() { return networks.snapshot(); }
    long networkGeneration() { return networkPath().generation; }
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
        HandlerThread thread = new HandlerThread("flclash-libbox-network");
        thread.start();
        Handler handler = new Handler(thread.getLooper());
        ConnectivityManager.NetworkCallback next = new ConnectivityManager.NetworkCallback() {
            private Network candidate;
            private LinkProperties link;
            private NetworkCapabilities caps;
            private int retries;
            private boolean lastMetered;
            private final Runnable retry = () -> refresh();

            @Override public void onAvailable(Network network) {
                if (callback != this) return;
                if (network.equals(candidate)) return;
                candidate = network;
                link = null;
                caps = null;
                retries = 0;
                handler.removeCallbacks(retry);
                // A new Android Network handle can reuse the same interface/index.
                // Invalidate the old path before publishing the replacement.
                if (networks.select(this, network)) {
                    cancelStaleDns();
                    if (callback == this) listener.updateDefaultInterface("", -1, false, false);
                }
            }

            @Override public void onLinkPropertiesChanged(Network network, LinkProperties value) {
                if (callback != this || !network.equals(candidate)) return;
                link = value;
                retries = 0;
                refresh();
            }

            @Override public void onCapabilitiesChanged(Network network, NetworkCapabilities value) {
                if (callback != this || !network.equals(candidate)) return;
                caps = value;
                retries = 0;
                refresh();
            }

            @Override public void onLost(Network network) {
                if (callback != this || !network.equals(candidate)) return;
                candidate = null;
                link = null;
                caps = null;
                handler.removeCallbacks(retry);
                if (networks.lose(this, network)) {
                    cancelStaleDns();
                    listener.updateDefaultInterface("", -1, false, false);
                }
            }

            private void refresh() {
                if (callback != this || candidate == null) return;
                handler.removeCallbacks(retry);
                // Prefer callback-delivered properties, not synchronous queries from onAvailable.
                if (link == null || caps == null) return;
                if (!caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_NOT_VPN)
                    || (Build.VERSION.SDK_INT >= 28
                        && !caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_NOT_SUSPENDED))) {
                    invalidatePath();
                    return;
                }
                String name = link.getInterfaceName();
                if (name != null && caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_NOT_VPN)) {
                    try {
                        java.net.NetworkInterface nic = java.net.NetworkInterface.getByName(name);
                        if (nic != null && nic.getIndex() > 0) {
                            boolean metered = !caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_NOT_METERED);
                            String fingerprint = NetworkPathFingerprint.of(name, nic.getIndex(),
                                link.getDnsServers(), link.getLinkAddresses(), link.getRoutes(),
                                Build.VERSION.SDK_INT >= 28 && link.isPrivateDnsActive(),
                                Build.VERSION.SDK_INT >= 28 ? link.getPrivateDnsServerName() : null,
                                link.getDomains());
                            NetworkEpoch.Snapshot<Network> previous = networks.snapshot();
                            if (networks.publish(this, candidate, fingerprint)) {
                                cancelStaleDns();
                                // Same handle, new address/route: libbox deduplicates name/index/DNS.
                                // Force a loss/wake pair so cached transports are actually reset.
                                if (previous.network != null && previous.network.equals(candidate)
                                    && previous.fingerprint != null
                                    && !previous.fingerprint.equals(fingerprint)) {
                                    if (callback == this) listener.updateDefaultInterface("", -1, false, false);
                                }
                                if (callback == this) {
                                    listener.updateDefaultInterface(name, nic.getIndex(), metered, false);
                                }
                            } else if (callback == this && lastMetered != metered) {
                                // Metered-only changes update metadata, not the connection epoch.
                                listener.updateDefaultInterface(name, nic.getIndex(), metered, false);
                            }
                            lastMetered = metered;
                            retries = 0;
                            return;
                        }
                    } catch (java.net.SocketException error) {
                        android.util.Log.w("FlClashLibbox", "Cannot read underlying interface", error);
                    }
                }
                // An unavailable NIC must not keep the previous DNS path usable.
                invalidatePath();
                // A bounded retry handles Android creating the NIC after the callback.
                if (++retries <= 10 && callback == this) handler.postDelayed(retry, 100);
            }

            private void invalidatePath() {
                if (candidate != null && networks.invalidate(this, candidate)) {
                    cancelStaleDns();
                    if (callback == this) listener.updateDefaultInterface("", -1, false, false);
                }
            }
        };
        networks.begin(next);
        callback = next;
        monitorThread = thread;
        try {
            if (Build.VERSION.SDK_INT >= 31) {
                connectivity.registerBestMatchingNetworkCallback(request, next, handler);
            } else {
                connectivity.requestNetwork(request, next, handler);
            }
        } catch (RuntimeException error) {
            callback = null;
            networks.clear();
            cancelStaleDns();
            thread.quit();
            monitorThread = null;
            throw error;
        }
    }

    private void cancelStaleDns() {
        for (java.util.Map.Entry<CancellationSignal, DnsQuery> entry : dnsQueries.entrySet()) {
            if (!networks.isCurrent(entry.getValue().path)) {
                entry.getKey().cancel();
                entry.getValue().done.countDown();
            }
        }
    }

    @Override public void closeDefaultInterfaceMonitor(InterfaceUpdateListener listener) {
        close();
    }

    @Override public synchronized void close() {
        ConnectivityManager.NetworkCallback active = callback;
        callback = null;
        networks.clear();
        cancelStaleDns();
        try {
            if (active != null) connectivity.unregisterNetworkCallback(active);
        } finally {
            if (monitorThread != null) monitorThread.quit();
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
            try {
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
            } catch (java.net.SocketException disappearing) {
                // One interface can vanish while Wi-Fi/cellular handover is in flight.
                // Keep the remaining valid interfaces available to libbox.
                android.util.Log.d("FlClashLibbox", "Skipping disappearing network interface", disappearing);
            }
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
                NetworkEpoch.Snapshot<Network> path = networks.snapshot();
                Network network = path.network;
                if (network == null) throw new IOException("No underlying network for local DNS");
                CancellationSignal signal = new CancellationSignal();
                DnsQuery query = new DnsQuery(path);
                CountDownLatch done = query.done;
                byte[][] answer = new byte[1][];
                Exception[] failure = new Exception[1];
                ctx.onCancel(() -> { signal.cancel(); done.countDown(); });
                dnsQueries.put(signal, query);
                try {
                    if (signal.isCanceled() || !networks.isCurrent(path)) throw new IOException("Underlying network changed before DNS query");
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
                    if (!done.await(10, TimeUnit.SECONDS)) throw new IOException("Local DNS timed out");
                    if (signal.isCanceled() || !networks.isCurrent(path)) throw new IOException("Local DNS canceled or network changed");
                    if (failure[0] != null) throw failure[0];
                    if (answer[0] == null) throw new IOException("Local DNS returned no response");
                    ctx.rawSuccess(answer[0]);
                } finally {
                    dnsQueries.remove(signal);
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
