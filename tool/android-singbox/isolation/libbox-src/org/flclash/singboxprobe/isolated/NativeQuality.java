package org.flclash.singboxprobe.isolated;

import io.nekohasekai.libbox.*;
import org.json.JSONObject;

/** One explicit, cancellable measurement per VPN session. No selector changes. */
final class NativeQuality {
    private CommandClient client;
    private NetworkQualityTestSession session;
    private volatile Sample current;

    synchronized void start(String tag) throws Exception {
        if (current != null && current.running()) throw new IllegalStateException("A speed test is already running");
        cancel();
        if (tag == null || tag.trim().isEmpty() || tag.length() > 256) {
            throw new IllegalArgumentException("Select a specific outbound");
        }
        Sample sample = new Sample(tag);
        current = sample;
        client = Libbox.newStandaloneCommandClient();
        try {
            session = client.startNetworkQualityTest(
                Libbox.NetworkQualityDefaultConfigURL, tag, true, 30, false, sample);
        } catch (Exception error) {
            sample.onError(error.toString());
            cancel();
            throw error;
        }
    }

    String snapshot() throws Exception {
        Sample sample = current;
        return sample == null ? new JSONObject().put("state", "idle").toString() : sample.json();
    }

    synchronized void cancel() throws Exception {
        Sample sample = current;
        if (sample != null) sample.cancel();
        NetworkQualityTestSession active = session;
        CommandClient owner = client;
        session = null;
        client = null;
        try {
            if (active != null) active.close();
        } finally {
            if (owner != null) owner.disconnect();
        }
    }

    private static final class Sample implements NetworkQualityTestHandler {
        private final String tag;
        private String state = "running", error = "";
        private long download, upload, elapsed;
        private int latency, downloadRpm, uploadRpm, accuracy;
        private final long started = System.currentTimeMillis();

        Sample(String tag) { this.tag = tag; }
        synchronized boolean running() { return "running".equals(state); }
        synchronized void cancel() { if (running()) state = "canceled"; }

        @Override public synchronized void onProgress(NetworkQualityProgress p) {
            if (!running() || p == null) return;
            download = p.getDownloadCapacity();
            upload = p.getUploadCapacity();
            latency = p.getIdleLatencyMs();
            downloadRpm = p.getDownloadRPM();
            uploadRpm = p.getUploadRPM();
            accuracy = p.getDownloadCapacityAccuracy();
            elapsed = p.getElapsedMs();
        }

        @Override public synchronized void onResult(NetworkQualityResult r) {
            if (!running()) return;
            if (r == null) { onError("No measurement result"); return; }
            download = r.getDownloadCapacity();
            upload = r.getUploadCapacity();
            latency = r.getIdleLatencyMs();
            downloadRpm = r.getDownloadRPM();
            uploadRpm = r.getUploadRPM();
            accuracy = r.getDownloadCapacityAccuracy();
            state = download > 0 ? "done" : "failed";
            if (download <= 0) error = "No valid download measurement";
        }

        @Override public synchronized void onError(String message) {
            if (!running()) return;
            error = message == null ? "Network quality test failed" : message;
            state = "failed";
        }

        synchronized String json() throws Exception {
            return new JSONObject().put("tag", tag).put("state", state)
                .put("downloadBps", download).put("uploadBps", upload)
                .put("latencyMs", latency).put("downloadRpm", downloadRpm)
                .put("uploadRpm", uploadRpm).put("accuracy", accuracy)
                .put("elapsedMs", elapsed).put("startedAt", started)
                .put("error", error).toString();
        }
    }
}
