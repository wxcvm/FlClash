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
    private Object owner;
    private Snapshot<T> current = new Snapshot<>(null, null, 0);

    synchronized void begin(Object token) { clear(); owner = token; }

    /** Select a new candidate; return whether a previously published path was lost. */
    synchronized boolean select(Object token, T next) {
        if (owner != token || next.equals(candidate)) return false;
        candidate = next;
        boolean lost = current.network != null;
        current = new Snapshot<>(null, null, current.generation + 1);
        return lost;
    }

    synchronized boolean publish(Object token, T network, String fingerprint) {
        if (owner != token || !network.equals(candidate)) return false;
        if (network.equals(current.network) && fingerprint.equals(current.fingerprint)) return false;
        current = new Snapshot<>(network, fingerprint, current.generation + 1);
        return true;
    }

    synchronized boolean lose(Object token, T network) {
        if (owner != token || !network.equals(candidate)) return false;
        boolean lost = current.network != null;
        candidate = null;
        current = new Snapshot<>(null, null, current.generation + 1);
        return lost;
    }

    synchronized void clear() {
        owner = null;
        candidate = null;
        current = new Snapshot<>(null, null, current.generation + 1);
    }

    synchronized Snapshot<T> snapshot() { return current; }
    synchronized boolean isCurrent(Snapshot<T> snapshot) {
        return snapshot.network != null && current.generation == snapshot.generation;
    }
}
