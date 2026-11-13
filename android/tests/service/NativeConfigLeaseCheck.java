package com.follow.clash.service;

public final class NativeConfigLeaseCheck {
    interface Action { void run() throws Exception; }
    static void check(boolean value) {
        if (!value) throw new AssertionError("Assertion failed");
    }
    static void rejects(Action action) throws Exception {
        try { action.run(); }
        catch (IllegalStateException expected) { return; }
        throw new AssertionError("Expected failure");
    }

    public static void main(String[] args) throws Exception {
        NativeConfigLease<String> lease = new NativeConfigLease<>();
        rejects(() -> lease.consume("a"));
        lease.claim("a");
        rejects(() -> lease.claim("b"));
        check(!lease.canStop("b"));
        String[] source = {"checked"};
        lease.prepare("a", () -> source[0], value -> check(value.equals("checked")));
        source[0] = "changed";
        rejects(() -> lease.consume("b"));
        check(lease.consume("a").equals("checked"));
        rejects(() -> lease.consume("a"));
        lease.prepare("a", () -> "previous", value -> {});
        rejects(() -> lease.prepare("a", () -> "invalid", value -> {
            throw new IllegalStateException("invalid");
        }));
        rejects(() -> lease.consume("a"));
        lease.prepare("a", () -> "previous", value -> {});
        rejects(() -> lease.prepare("a", () -> {
            throw new IllegalStateException("read failed");
        }, value -> {}));
        rejects(() -> lease.consume("a"));
        lease.prepare("a", () -> "pending", value -> {});
        check(lease.retire().equals("a"));
        check(lease.owner() == null);
        rejects(() -> lease.claim("a"));
        rejects(() -> lease.consume("a"));
        System.out.println("PASS: native config ownership, immutable snapshot, one-use, failed read/validation, retirement");
    }
}
