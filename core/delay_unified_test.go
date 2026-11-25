package core

import (
	"net/http"
	"net/http/httptest"
	"sync/atomic"
	"testing"

	"github.com/metacubex/mihomo/adapter"
	"github.com/metacubex/mihomo/constant"
	"github.com/metacubex/mihomo/tunnel"
)

func TestUnifiedDelayPreservesFirstSuccessfulMeasurement(t *testing.T) {
	previous := adapter.UnifiedDelay.Load()
	adapter.UnifiedDelay.Store(true)
	t.Cleanup(func() { adapter.UnifiedDelay.Store(previous) })
	var calls atomic.Int32
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, req *http.Request) {
		if calls.Add(1) == 1 {
			w.WriteHeader(http.StatusNoContent)
			return
		}
		<-req.Context().Done()
	}))
	t.Cleanup(server.Close)
	tunnel.UpdateProxies(map[string]constant.Proxy{"node": namedProxy("node")}, nil)
	t.Cleanup(func() { tunnel.UpdateProxies(nil, nil) })

	result := handleTestDelay(&TestDelayParams{
		ProxyName: "node", TestUrl: server.URL, Timeout: 2000,
	})
	if calls.Load() != 2 {
		t.Fatalf("expected both HEAD attempts, got %d", calls.Load())
	}
	if result == nil || result.Value <= 0 || result.Value >= 1500 {
		t.Fatalf("expected first successful latency, got %+v", result)
	}
}
