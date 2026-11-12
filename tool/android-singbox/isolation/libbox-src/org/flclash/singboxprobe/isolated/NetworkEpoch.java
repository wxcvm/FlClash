package org.flclash.singboxprobe.isolated;

/** Tracks Android network identity independently from an interface name/index. */
final class NetworkEpoch<T> {
    static final class Snapshot<T> {
        final T network;
        final String fingerprint;
        final long generation;
        Snapshot(T network, String fingerprint, long generation) {
            this.network = network;
            this.fingerprint = fingerprint;
            this.generation = generation;
        }
    }

    private T candidate;
    private Snapshot<T> current = new Snapshot<>(null, null, 0);

    /** Select a new candidate; return whether a previously published path was lost. */
    synchronized boolean select(T next) {
        if (next.equals(candidate)) return false;
        candidate = next;
        boolean lost = current.network != null;
        current = new Snapshot<>(null, null, current.generation + 1);
        return lost;
    }

    synchronized boolean publish(T network, String fingerprint) {
        if (!network.equals(candidate)) return false;
        if (network.equals(current.network) && fingerprint.equals(current.fingerprint)) return false;
        current = new Snapshot<>(network, fingerprint, current.generation + 1);
        return true;
    }

    synchronized boolean lose(T network) {
        if (!network.equals(candidate)) return false;
        boolean lost = current.network != null;
        clear();
        return lost;
    }

    synchronized void clear() {
        candidate = null;
        current = new Snapshot<>(null, null, current.generation + 1);
    }

    synchronized Snapshot<T> snapshot() { return current; }
    synchronized boolean isCurrent(Snapshot<T> snapshot) {
        return snapshot.network != null && current.generation == snapshot.generation;
    }
}
