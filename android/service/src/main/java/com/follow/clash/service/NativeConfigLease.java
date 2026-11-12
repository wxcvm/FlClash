package com.follow.clash.service;

/** A single controller owns an immutable, one-use preflight result. */
final class NativeConfigLease<T> {
    interface Source { String read() throws Exception; }
    interface Validator { void validate(String config) throws Exception; }

    private volatile T owner;
    private String prepared;
    private boolean retired;

    T owner() { return owner; }

    synchronized void claim(T token) {
        if (retired || token == null || (owner != null && !owner.equals(token))) {
            throw new IllegalStateException("Native VPN controller is not the owner");
        }
        owner = token;
    }

    synchronized void prepare(T token, Source source, Validator validator) throws Exception {
        requireOwner(token);
        prepared = null;
        String config = source.read();
        validator.validate(config);
        prepared = config;
    }

    synchronized String consume(T token) {
        requireOwner(token);
        if (prepared == null) throw new IllegalStateException("Native VPN requires successful preflight");
        String config = prepared;
        prepared = null;
        return config;
    }

    synchronized boolean canStop(T token) {
        return owner == null || owner.equals(token);
    }

    synchronized T retire() {
        retired = true;
        prepared = null;
        T previous = owner;
        owner = null;
        return previous;
    }

    private void requireOwner(T token) {
        if (retired || owner == null || !owner.equals(token)) {
            throw new IllegalStateException("Native VPN controller is not the owner");
        }
    }
}
