package core

import (
	"context"
	"errors"
	"net/netip"
	"testing"
)

func TestNodeDNSAddressClassification(t *testing.T) {
	for _, tc := range []struct {
		name   string
		addr   string
		result []netip.Addr
		err    error
		want   string
		calls  int
	}{
		{name: "domain answered", addr: "node.example:443", result: []netip.Addr{netip.MustParseAddr("192.0.2.1")}, want: "answered", calls: 1},
		{name: "domain error", addr: "node.example:443", err: errors.New("secret upstream error"), want: "failed", calls: 1},
		{name: "no answers", addr: "node.example:443", want: "failed", calls: 1},
		{name: "ipv4 skips DNS", addr: "192.0.2.2:443", want: "ip-address"},
		{name: "ipv6 skips DNS", addr: "[2001:db8::1]:443", want: "ip-address"},
		{name: "empty endpoint", addr: "", want: "no-endpoint"},
		{name: "invalid endpoint", addr: "not-a-host-port", want: "no-endpoint"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			calls := 0
			got := checkNodeDNSAddress(context.Background(), tc.addr,
				func(_ context.Context, host string) ([]netip.Addr, error) {
					calls++
					if host != "node.example" {
						t.Errorf("looked up unexpected name %q", host)
					}
					return tc.result, tc.err
				})
			if got != tc.want || calls != tc.calls {
				t.Fatalf("state = %q, calls = %d; want %q and %d", got, calls, tc.want, tc.calls)
			}
		})
	}
}

func TestNodeDNSCanceledIsInconclusive(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	got := checkNodeDNSAddress(ctx, "node.example:443",
		func(_ context.Context, _ string) ([]netip.Addr, error) {
			cancel()
			return nil, errors.New("stale request")
		})
	if got != "inconclusive" {
		t.Fatalf("canceled DNS = %q, want inconclusive", got)
	}
}

func TestNodeDNSStoppedCannotQueryOrReturnEndpoint(t *testing.T) {
	wasRunning := isRunning.Load()
	isRunning.Store(false)
	t.Cleanup(func() { isRunning.Store(wasRunning) })
	result := handleNodeDNS(NameParams{Name: "not-a-public-node"})
	if result.State != "stopped" || result.CheckedAt <= 0 {
		t.Fatalf("unexpected stopped result: %+v", result)
	}
}
