package org.flclash.singboxprobe.isolated;

import android.net.VpnService;
import android.os.ParcelFileDescriptor;
import io.nekohasekai.libbox.RoutePrefix;
import io.nekohasekai.libbox.RoutePrefixIterator;
import io.nekohasekai.libbox.StringIterator;
import io.nekohasekai.libbox.TunOptions;
import java.io.Closeable;
import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;

/**
 * Android side of libbox OpenTun/AutoDetectInterfaceControl.
 * The pinned libbox duplicates the returned fd; this bridge owns the original.
 * The caller must stop the native service before closing this bridge.
 */
public final class AndroidTunBridge implements Closeable {
    private final VpnService service;
    private ParcelFileDescriptor tun;

    public AndroidTunBridge(VpnService service) {
        this.service = service;
    }

    public synchronized int openTun(TunOptions options) throws Exception {
        if (tun != null) throw new IllegalStateException("TUN already established");
        if (options.isHTTPProxyEnabled()) {
            throw new IllegalArgumentException("HTTP proxy not supported by this adapter yet");
        }
        VpnService.Builder builder = service.new Builder();
        builder.setSession("FlClash sing-box");
        builder.setMtu(options.getMTU());
        builder.setBlocking(false);
        builder.setMetered(false);
        addAddresses(builder, options.getInet4Address());
        addAddresses(builder, options.getInet6Address());
        if (options.getAutoRoute()) {
            // Upstream has already subtracted route exclusions in these ranges.
            addRoutes(builder, options.getInet4RouteRange());
            addRoutes(builder, options.getInet6RouteRange());
        }
        StringIterator dns = options.getDNSServerAddress();
        while (dns != null && dns.hasNext()) builder.addDnsServer(dns.next());

        StringIterator include = options.getIncludePackage();
        StringIterator exclude = options.getExcludePackage();
        if (include.hasNext() && exclude.hasNext()) {
            throw new IllegalArgumentException("Cannot combine Android include/exclude packages");
        }
        while (include.hasNext()) builder.addAllowedApplication(include.next());
        while (exclude.hasNext()) builder.addDisallowedApplication(exclude.next());

        ParcelFileDescriptor established = builder.establish();
        if (established == null) throw new IllegalStateException("VPN permission denied or revoked");
        tun = established;
        return tun.getFd(); // borrowed; never detach or close this integer in Java
    }

    public boolean usePlatformAutoDetectInterfaceControl() {
        return true;
    }

    public void autoDetectInterfaceControl(int fd) throws IOException {
        if (!service.protect(fd)) throw new IOException("VPN socket protection failed");
    }

    private static void addAddresses(VpnService.Builder builder, RoutePrefixIterator prefixes) {
        while (prefixes.hasNext()) {
            RoutePrefix prefix = prefixes.next();
            builder.addAddress(prefix.address(), prefix.prefix());
        }
    }

    private static void addRoutes(VpnService.Builder builder, RoutePrefixIterator prefixes) {
        while (prefixes.hasNext()) {
            RoutePrefix prefix = prefixes.next();
            builder.addRoute(prefix.address(), prefix.prefix());
        }
    }

    @Override
    public synchronized void close() throws IOException {
        ParcelFileDescriptor owned = tun;
        tun = null;
        if (owned != null) owned.close();
    }

    /** Real descriptor duplication test; does not request VPN permission or create routes. */
    public static void verifyDescriptorOwnership() throws IOException {
        ParcelFileDescriptor[] pipe = ParcelFileDescriptor.createPipe();
        try (ParcelFileDescriptor original = pipe[0];
             OutputStream out = new ParcelFileDescriptor.AutoCloseOutputStream(pipe[1]);
             ParcelFileDescriptor duplicate = ParcelFileDescriptor.dup(original.getFileDescriptor());
             InputStream in = new ParcelFileDescriptor.AutoCloseInputStream(duplicate)) {
            original.close();
            out.write(0x53);
            out.flush();
            if (in.read() != 0x53) throw new IOException("Duplicated descriptor lost its ownership");
        }
    }
}
