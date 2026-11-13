package core

import (
	"context"
	"errors"
	"net/netip"
	"testing"
)

func TestRecoveryHealthDistinguishesDNSAndRouteFailures(t *testing.T) {
	for _, tc := range []struct {
		name       string
		probe      *ProbeResult
		addresses  []netip.Addr
		dnsErr     error
		want       string
		wantLookup bool
	}{
		{name: "success", probe: &ProbeResult{StatusCode: 204}, want: "reachable"},
		{name: "http error", probe: &ProbeResult{StatusCode: 403}, want: "http-response"},
		{name: "busy", want: "inconclusive"},
		{name: "dns failure", probe: &ProbeResult{Error: "failed"}, dnsErr: errors.New("DNS timeout"), want: "dns-failure", wantLookup: true},
		{name: "no DNS answers", probe: &ProbeResult{Error: "failed"}, want: "dns-failure", wantLookup: true},
		{name: "route failure", probe: &ProbeResult{Error: "timeout"}, addresses: []netip.Addr{netip.MustParseAddr("192.0.2.1")}, want: "route-unreachable", wantLookup: true},
	} {
		t.Run(tc.name, func(t *testing.T) {
			lookedUp := false
			result := checkRecoveryHealth(context.Background(), "https://example.test/generate_204",
				func(_ context.Context, req probeRequest) *ProbeResult {
					if req.proxyName != "" || !req.noRedirect || req.maxBody != 0 {
						t.Fatal("recovery must use actual route without redirects or download")
					}
					return tc.probe
				},
				func(_ context.Context, host string) ([]netip.Addr, error) {
					lookedUp = true
					if host != "example.test" {
						t.Fatalf("unexpected DNS host %q", host)
					}
					return tc.addresses, tc.dnsErr
				},
			)
			if result.state != tc.want || lookedUp != tc.wantLookup {
				t.Fatalf("result=%+v, lookup=%t; want %s, lookup=%t", result, lookedUp, tc.want, tc.wantLookup)
			}
		})
	}
}

func TestRecoveryHealthInvalidURL(t *testing.T) {
	result := checkRecoveryHealth(context.Background(), "not-a-url", nil, nil)
	if result.state != "invalid-test-url" {
		t.Fatalf("unexpected result: %+v", result)
	}
}

func TestRecoveryHealthIPDoesNotRequireDNS(t *testing.T) {
	result := checkRecoveryHealth(context.Background(), "https://192.0.2.1/",
		func(context.Context, probeRequest) *ProbeResult { return &ProbeResult{Error: "timeout"} },
		nil,
	)
	if result.state != "route-unreachable" {
		t.Fatalf("unexpected result: %+v", result)
	}
}

func TestNetworkHealthDoesNotReuseOldRoute(t *testing.T) {
	previous := isRunning.Load()
	isRunning.Store(true)
	t.Cleanup(func() {
		cancelRecoveryHealth()
		isRunning.Store(previous)
	})
	epoch, version := routeStamp()
	recoveryHealthMu.Lock()
	recoveryHealth = NetworkHealthSnapshot{
		State: "reachable", DNS: "untested",
		CoreEpoch: epoch, RouteVersion: version,
	}
	recoveryHealthMu.Unlock()
	if got := handleNetworkHealth(); got.State != "reachable" {
		t.Fatalf("current result not returned: %+v", got)
	}
	recoveryHealthMu.Lock()
	recoveryHealth.RouteVersion = version + 1
	recoveryHealthMu.Unlock()
	if got := handleNetworkHealth(); got.State != "idle" {
		t.Fatalf("stale result presented as current: %+v", got)
	}
	cancelRecoveryHealth()
	if got := handleNetworkHealth(); got.State != "idle" {
		t.Fatalf("cancelled result not cleared: %+v", got)
	}
	isRunning.Store(false)
	if got := handleNetworkHealth(); got.State != "stopped" {
		t.Fatalf("stopped core presented as active: %+v", got)
	}
}

func TestRecoveryHealthDNSRequiresSeparateLookup(t *testing.T) {
	for _, tc := range []struct {
		state string
		host  string
		want  string
	}{
		{"reachable", "example.test", "untested"},
		{"http-response", "example.test", "untested"},
		{"route-unreachable", "192.0.2.1", "not-required"},
		{"reachable", "2001:db8::1", "not-required"},
		{"route-unreachable", "2001:db8::1", "not-required"},
		{"route-unreachable", "example.test", "resolved"},
		{"dns-failure", "example.test", "failed"},
	} {
		if got := recoveryDNSState(recoveryHealthResult{state: tc.state}, tc.host); got != tc.want {
			t.Errorf("%s/%s: DNS %q, want %q", tc.state, tc.host, got, tc.want)
		}
	}
}

func TestRecoveryHealthCountsOnlyConfirmedFailures(t *testing.T) {
	for _, tc := range []struct {
		name   string
		states []string
		want   int
	}{
		{"busy then failed", []string{"inconclusive", "dns-failure"}, 1},
		{"failed then busy", []string{"route-unreachable", "inconclusive"}, 1},
		{"two failures", []string{"dns-failure", "route-unreachable"}, 2},
		{"busy twice", []string{"inconclusive", "inconclusive"}, 0},
		{"recovered", []string{"dns-failure", "reachable"}, 1},
	} {
		t.Run(tc.name, func(t *testing.T) {
			var snapshot NetworkHealthSnapshot
			for _, state := range tc.states {
				snapshot.recordFailure(recoveryHealthResult{state: state})
			}
			if snapshot.Failures != tc.want {
				t.Fatalf("confirmed failures = %d, want %d", snapshot.Failures, tc.want)
			}
		})
	}
}
