package org.flclash.singboxprobe;

import android.content.Context;
import android.net.ConnectivityManager;
import android.net.LinkAddress;
import android.net.LinkProperties;
import android.net.Network;
import android.net.NetworkCapabilities;
import android.os.SystemClock;
import java.io.BufferedReader;
import java.net.DatagramPacket;
import java.net.DatagramSocket;
import java.util.concurrent.ThreadLocalRandom;
import java.io.IOException;
import java.io.InputStreamReader;
import java.net.InetAddress;
import java.net.InetSocketAddress;
import java.net.Socket;
import java.nio.charset.StandardCharsets;
import java.util.function.BooleanSupplier;
import javax.net.ssl.SSLParameters;
import javax.net.ssl.SSLSocket;
import javax.net.ssl.SSLSocketFactory;

/** A bounded, real HTTPS test on the diagnostic VPN, never on the physical network. */
final class ProbeVpnTraffic {
    static final String TUN_ADDRESS = "172.19.0.1";
    private static final String TARGET = "1.1.1.1";
    private static final String HOST = "cloudflare-dns.com";

    private static Network findVpn(Context context) {
        ConnectivityManager manager = context.getSystemService(ConnectivityManager.class);
        for (Network network : manager.getAllNetworks()) {
            NetworkCapabilities caps = manager.getNetworkCapabilities(network);
            LinkProperties link = manager.getLinkProperties(network);
            if (caps == null || link == null || !caps.hasTransport(NetworkCapabilities.TRANSPORT_VPN)) continue;
            for (LinkAddress address : link.getLinkAddresses()) {
                if (TUN_ADDRESS.equals(address.getAddress().getHostAddress())) return network;
            }
        }
        return null;
    }

    static String verify(Context context, BooleanSupplier canceled) throws Exception {
        long deadline = SystemClock.elapsedRealtime() + 5000;
        Network vpn;
        while ((vpn = findVpn(context)) == null) {
            if (canceled.getAsBoolean()) throw new IOException("VPN test canceled");
            if (SystemClock.elapsedRealtime() >= deadline) throw new IOException("Diagnostic VPN not visible");
            Thread.sleep(100);
        }
        if (canceled.getAsBoolean()) throw new IOException("VPN test canceled");
        String dnsResult = verifyDns(vpn, canceled);
        long started = SystemClock.elapsedRealtime();
        try (Socket raw = vpn.getSocketFactory().createSocket()) {
            raw.connect(new InetSocketAddress(InetAddress.getByName(TARGET), 443), 4000);
            if (!TUN_ADDRESS.equals(raw.getLocalAddress().getHostAddress())) {
                throw new IOException("Traffic did not use the diagnostic TUN source address");
            }
            raw.setSoTimeout(4000);
            SSLSocketFactory factory = (SSLSocketFactory) SSLSocketFactory.getDefault();
            try (SSLSocket tls = (SSLSocket) factory.createSocket(raw, HOST, 443, true)) {
                SSLParameters parameters = tls.getSSLParameters();
                parameters.setEndpointIdentificationAlgorithm("HTTPS");
                tls.setSSLParameters(parameters);
                tls.setSoTimeout(4000);
                tls.startHandshake();
                tls.getOutputStream().write(("HEAD / HTTP/1.1\r\nHost: " + HOST
                    + "\r\nConnection: close\r\n\r\n").getBytes(StandardCharsets.US_ASCII));
                tls.getOutputStream().flush();
                BufferedReader reader = new BufferedReader(new InputStreamReader(
                    tls.getInputStream(), StandardCharsets.US_ASCII));
                String response = reader.readLine();
                if (response == null || !response.matches("HTTP/1\\.[01] [1-5][0-9]{2}( .*)?")) {
                    throw new IOException("No valid HTTPS response through TUN");
                }
                return "PASS: VPN source " + TUN_ADDRESS + " -> " + TARGET
                    + ":443, verified TLS, " + response.substring(0, 12)
                    + ", " + (SystemClock.elapsedRealtime() - started) + " ms\n" + dnsResult;
            }
        }
    }

    private static String verifyDns(Network vpn, BooleanSupplier canceled) throws Exception {
        int id = ThreadLocalRandom.current().nextInt(65536);
        byte[] query = ProbeDnsMessage.query(id);
        long started = SystemClock.elapsedRealtime();
        try (DatagramSocket socket = new DatagramSocket(null)) {
            vpn.bindSocket(socket);
            socket.bind(new InetSocketAddress(0));
            socket.connect(InetAddress.getByName("172.19.0.2"), 53);
            if (!TUN_ADDRESS.equals(socket.getLocalAddress().getHostAddress())) {
                throw new IOException("DNS socket did not use the diagnostic TUN");
            }
            socket.setSoTimeout(8000);
            if (canceled.getAsBoolean()) throw new IOException("DNS test canceled");
            socket.send(new DatagramPacket(query, query.length));
            byte[] bytes = new byte[4096];
            DatagramPacket response = new DatagramPacket(bytes, bytes.length);
            socket.receive(response);
            if (canceled.getAsBoolean()) throw new IOException("DNS test canceled");
            ProbeDnsMessage.verify(bytes, response.getLength(), id);
            return "DNS PASS: example.com A via VPN DNS 172.19.0.2, "
                + (SystemClock.elapsedRealtime() - started) + " ms";
        }
    }

    static void verifyRemoved(Context context) throws Exception {
        long deadline = SystemClock.elapsedRealtime() + 5000;
        while (findVpn(context) != null) {
            if (SystemClock.elapsedRealtime() >= deadline) {
                throw new IOException("Diagnostic VPN still visible after native stop");
            }
            Thread.sleep(100);
        }
    }
}
