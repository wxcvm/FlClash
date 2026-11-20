package core

import (
	"context"
	"testing"

	"github.com/metacubex/http"
)

func TestNodeHTTPSProbeUsesNamedProxyWithoutSpeedTestOrBody(t *testing.T) {
	called := false
	result := probeNodeHTTPS(context.Background(), "selected-leaf",
		func(_ context.Context, req probeRequest) *ProbeResult {
			called = true
			if req.method != http.MethodHead || req.url != nodeHTTPSProbeURL ||
				req.proxyName != "selected-leaf" || !req.noRedirect ||
				req.maxBody != 0 || req.downloadBytes != 0 {
				t.Fatalf("unexpected request: %+v", req)
			}
			return &ProbeResult{StatusCode: 204, Delay: 13}
		})
	if !called || result.State != "reachable" || result.HTTPStatus != 204 || result.Delay != 13 {
		t.Fatalf("result = %+v, called = %t", result, called)
	}
}

func TestNodeHTTPSProbeClassifiesFailuresWithoutLeakingDetail(t *testing.T) {
	for _, tc := range []struct {
		name   string
		answer *ProbeResult
		want   string
		code   int
	}{
		{name: "busy", want: "busy"},
		{name: "timeout", answer: &ProbeResult{Error: probeErrorTimeout, Message: "sensitive endpoint"}, want: "timeout"},
		{name: "connection error", answer: &ProbeResult{Error: probeErrorFailed, Message: "sensitive endpoint"}, want: "failed"},
		{name: "forbidden response", answer: &ProbeResult{StatusCode: 403, Delay: 9}, want: "http-response", code: 403},
		{name: "method not allowed", answer: &ProbeResult{StatusCode: 405, Delay: 11}, want: "http-response", code: 405},
		{name: "no status", answer: &ProbeResult{}, want: "inconclusive"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			got := probeNodeHTTPS(context.Background(), "selected-leaf",
				func(context.Context, probeRequest) *ProbeResult {
					return tc.answer
				})
			if got.State != tc.want || got.HTTPStatus != tc.code {
				t.Fatalf("result = %+v, want state %q HTTP %d", got, tc.want, tc.code)
			}
		})
	}
}

func TestNodeHTTPSCancelledIsInconclusive(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	result := probeNodeHTTPS(ctx, "selected-leaf", func(context.Context, probeRequest) *ProbeResult {
		cancel()
		return &ProbeResult{Error: probeErrorTimeout}
	})
	if result.State != "inconclusive" {
		t.Fatalf("result = %+v, want inconclusive", result)
	}
}

func TestNodeHTTPSStoppedSkipsProbe(t *testing.T) {
	wasRunning := isRunning.Load()
	isRunning.Store(false)
	t.Cleanup(func() { isRunning.Store(wasRunning) })
	result := handleNodeHTTPS(NameParams{Name: "unavailable-node"})
	if result.State != "stopped" || result.CheckedAt == 0 || result.HTTPStatus != 0 {
		t.Fatalf("unexpected stopped result: %+v", result)
	}
}
