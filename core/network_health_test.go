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
