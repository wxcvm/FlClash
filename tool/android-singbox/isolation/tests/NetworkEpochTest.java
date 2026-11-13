package org.flclash.singboxprobe.isolated;

public final class NetworkEpochTest {
    private static void check(boolean value, String reason) {
        if (!value) throw new AssertionError(reason);
    }
    private static void testFingerprint() {
        java.util.List<String> dns = java.util.Arrays.asList("1.1.1.1", "8.8.8.8");
        java.util.List<String> addresses = java.util.Arrays.asList("a", "b");
        java.util.List<String> routes = java.util.Arrays.asList("x", "y");
        String base = NetworkPathFingerprint.of("wlan0", 3, dns, addresses, routes, false, null, null);
        check(base.equals(NetworkPathFingerprint.of("wlan0", 3, dns,
            java.util.Arrays.asList("b", "a"), java.util.Arrays.asList("y", "x"),
            false, null, null)), "reordered addresses/routes must not reset tunnel");
        check(!base.equals(NetworkPathFingerprint.of("wlan0", 3,
            java.util.Arrays.asList("8.8.8.8", "1.1.1.1"), addresses, routes,
            false, null, null)), "DNS order remains meaningful");
        String privateDns = NetworkPathFingerprint.of("wlan0", 3, dns, addresses, routes,
            true, "dns.example", null);
        check(!base.equals(privateDns), "private DNS activation invalidates path");
        check(!privateDns.equals(NetworkPathFingerprint.of("wlan0", 3, dns, addresses, routes,
            true, "other.example", null)), "private DNS hostname change invalidates path");
        check(!base.equals(NetworkPathFingerprint.of("wlan0", 3, dns, addresses, routes,
            false, null, "example")), "search domains change invalidates path");
    }

    public static void main(String[] args) {
        NetworkEpoch<String> epoch = new NetworkEpoch<>();
        Object first = new Object();
        epoch.begin(first);
        check(!epoch.select(first, "wifi"), "first candidate is not a loss");
        check(epoch.publish(first, "wifi", "wlan0/3/dns1"), "publish initial Wi-Fi");
        NetworkEpoch.Snapshot<String> wifi = epoch.snapshot();
        check(!epoch.publish(first, "wifi", "wlan0/3/dns1"), "duplicate callback");
        check(epoch.isCurrent(wifi), "duplicate does not invalidate DNS");
        check(epoch.select(first, "cell"), "handover invalidates old path");
        check(!epoch.isCurrent(wifi), "old DNS response rejected");
        check(!epoch.lose(first, "wifi"), "late old network loss ignored");
        check(epoch.publish(first, "cell", "rmnet0/5/dns2"), "cellular publishes");
        NetworkEpoch.Snapshot<String> cell = epoch.snapshot();
        check(epoch.publish(first, "cell", "rmnet0/5/dns3"), "DNS change publishes");
        check(!epoch.isCurrent(cell), "same interface new DNS invalidates");
        check(epoch.lose(first, "cell"), "physical network loss");
        check(epoch.snapshot().network == null, "no DNS path while offline");
        check(!epoch.select(first, "wifi2"), "new network after offline");
        check(epoch.publish(first, "wifi2", "wlan0/3/dns1"), "same NIC new network");
        NetworkEpoch.Snapshot<String> beforeSuspend = epoch.snapshot();
        check(epoch.invalidate(first, "wifi2"), "suspended network invalidates");
        check(!epoch.isCurrent(beforeSuspend), "suspension rejects pending DNS");
        check(!epoch.invalidate(first, "wifi2"), "repeated suspension is a no-op");
        check(epoch.publish(first, "wifi2", "wlan0/3/dns1"), "same handle resumes");
        check(!epoch.invalidate(first, "cell"), "old handle cannot suspend current network");
        epoch.clear();
        check(!epoch.select(first, "old"), "closed callback cannot restore path");
        Object second = new Object();
        epoch.begin(second);
        check(!epoch.select(second, "new"), "new listener starts offline");
        check(!epoch.publish(first, "new", "stale"), "old listener cannot publish");
        check(epoch.publish(second, "new", "wlan0/3/dns1"), "new listener publishes");
        check(!epoch.lose(first, "new"), "old listener cannot remove new network");
        check(!epoch.invalidate(first, "new"), "old listener cannot invalidate new path");
        testFingerprint();
        System.out.println("PASS: network identity, duplicate callbacks, stale DNS, offline recovery, listener ownership");
    }
}
