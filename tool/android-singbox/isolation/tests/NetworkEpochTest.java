package org.flclash.singboxprobe.isolated;

public final class NetworkEpochTest {
    private static void check(boolean value, String reason) {
        if (!value) throw new AssertionError(reason);
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
        epoch.clear();
        check(!epoch.select(first, "old"), "closed callback cannot restore path");
        Object second = new Object();
        epoch.begin(second);
        check(!epoch.select(second, "new"), "new listener starts offline");
        check(!epoch.publish(first, "new", "stale"), "old listener cannot publish");
        check(epoch.publish(second, "new", "wlan0/3/dns1"), "new listener publishes");
        check(!epoch.lose(first, "new"), "old listener cannot remove new network");
        System.out.println("PASS: network identity, duplicate callbacks, stale DNS, offline recovery, listener ownership");
    }
}
