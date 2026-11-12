package org.flclash.singboxprobe.isolated;

import io.nekohasekai.libbox.*;
import org.json.JSONArray;
import org.json.JSONObject;
import java.util.ArrayDeque;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.TimeUnit;

/** On-demand native snapshots. No idle subscriptions, no extra Go runtime. */
public final class NativeTelemetry implements CommandClientHandler {
    private final CountDownLatch ready;
    private final boolean statusOnly;
    private NativeTelemetry(boolean statusOnly) {
        this.statusOnly = statusOnly;
        ready = new CountDownLatch(statusOnly ? 1 : 3);
    }
    private final ArrayDeque<String> logs = new ArrayDeque<>();
    private JSONArray groups, outbounds;
    private JSONObject status;
    private int samples;
    private String failure;
    private boolean truncated;

    public static String snapshot() throws Exception {
        return snapshot(false);
    }

    public static String statusSnapshot() throws Exception { return snapshot(true); }

    private static String snapshot(boolean statusOnly) throws Exception {
        NativeTelemetry observer = new NativeTelemetry(statusOnly);
        CommandClientOptions options = new CommandClientOptions();
        options.setStatusInterval(1000000000L);
        options.addCommand(Libbox.CommandStatus);
        if (!statusOnly) {
            options.addCommand(Libbox.CommandGroup);
            options.addCommand(Libbox.CommandOutbounds);
            options.addCommand(Libbox.CommandLog);
        }
        CommandClient client = new CommandClient(observer, options);
        try {
            client.connect();
            observer.ready.await(3, TimeUnit.SECONDS);
            return observer.result();
        } finally {
            client.disconnect();
        }
    }

    public static void select(String group, String tag) throws Exception {
        CommandClient client = Libbox.newStandaloneCommandClient();
        try { client.selectOutbound(group, tag); }
        finally { client.disconnect(); }
    }

    public static void test(String tag) throws Exception {
        CommandClient client = Libbox.newStandaloneCommandClient();
        try { client.urlTest(tag); }
        finally { client.disconnect(); }
    }

    private synchronized String result() throws Exception {
        if (status == null || (!statusOnly && (groups == null || outbounds == null))) {
            throw new java.io.IOException(failure == null ? "Native telemetry incomplete; retry" : failure);
        }
        JSONObject result = new JSONObject();
        result.put("status", status);
        if (!statusOnly) {
            result.put("groups", groups);
            result.put("outbounds", outbounds);
            result.put("logs", new JSONArray(logs));
            result.put("truncated", truncated);
        }
        result.put("rateAvailable", samples >= 2);
        if (failure != null) result.put("warning", failure);
        return result.toString();
    }

    private static JSONObject item(OutboundGroupItem item) throws Exception {
        return new JSONObject().put("tag", item.getTag()).put("type", item.getType())
            .put("delay", item.getURLTestDelay()).put("testedAt", item.getURLTestTime());
    }

    @Override public synchronized void writeStatus(StatusMessage value) {
        try {
            status = new JSONObject().put("memory", value.getMemory())
                .put("goroutines", value.getGoroutines())
                .put("connections", value.getConnectionsIn())
                .put("trafficAvailable", value.getTrafficAvailable())
                .put("upload", value.getUplink()).put("download", value.getDownlink())
                .put("uploadTotal", value.getUplinkTotal()).put("downloadTotal", value.getDownlinkTotal());
            if (++samples == 2) ready.countDown();
        } catch (Exception e) { disconnected(e.toString()); }
    }

    @Override public synchronized void writeGroups(OutboundGroupIterator iterator) {
        try {
            JSONArray next = new JSONArray();
            int budget = 300;
            while (iterator.hasNext()) {
                OutboundGroup group = iterator.next();
                if (next.length() >= 50 || group.getTag().length() > 256) { truncated = true; continue; }
                JSONArray items = new JSONArray();
                OutboundGroupItemIterator children = group.getItems();
                while (children.hasNext()) {
                    OutboundGroupItem child = children.next();
                    if (budget <= 0 || child.getTag().length() > 256) { truncated = true; continue; }
                    items.put(item(child));
                    budget--;
                }
                next.put(new JSONObject().put("tag", group.getTag()).put("type", group.getType())
                    .put("selected", group.getSelected()).put("selectable", group.getSelectable())
                    .put("items", items));
            }
            if (groups == null) ready.countDown();
            groups = next;
        } catch (Exception e) { disconnected(e.toString()); }
    }

    @Override public synchronized void writeOutbounds(OutboundGroupItemIterator iterator) {
        try {
            JSONArray next = new JSONArray();
            while (iterator.hasNext()) {
                OutboundGroupItem child = iterator.next();
                if (next.length() >= 300 || child.getTag().length() > 256) { truncated = true; continue; }
                next.put(item(child));
            }
            if (outbounds == null) ready.countDown();
            outbounds = next;
        } catch (Exception e) { disconnected(e.toString()); }
    }

    @Override public synchronized void writeLogs(LogIterator iterator) {
        while (iterator.hasNext()) {
            String message = iterator.next().getMessage();
            if (message.length() > 512) message = message.substring(0, 512);
            if (logs.size() == 40) logs.removeFirst();
            logs.addLast(message);
        }
    }
    @Override public synchronized void clearLogs() { logs.clear(); }
    @Override public synchronized void disconnected(String message) {
        failure = message;
    }
    @Override public void connected() {}
    @Override public void setDefaultLogLevel(int level) {}
    @Override public void initializeClashMode(StringIterator modes, String current) {}
    @Override public void updateClashMode(String mode) {}
    @Override public void writeConnectionEvents(ConnectionEvents events) {}
}
