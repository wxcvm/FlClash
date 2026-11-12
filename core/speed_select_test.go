package core

import (
	"net/http"
	"testing"

	"github.com/metacubex/mihomo/adapter"
	"github.com/metacubex/mihomo/adapter/outboundgroup"
	"github.com/metacubex/mihomo/adapter/provider"
	"github.com/metacubex/mihomo/constant"
	cp "github.com/metacubex/mihomo/constant/provider"
	"github.com/metacubex/mihomo/tunnel"
)

func TestVerifiedSpeedSelector(t *testing.T) {
	recordRoutes(t)
	group := selectorGroup(t, "group", "node-a", "node-b")
	tunnel.UpdateProxies(map[string]constant.Proxy{"group": group}, nil)
	t.Cleanup(func() { tunnel.UpdateProxies(nil, nil) })
	result := handleSelectSpeedProxy(&ChangeProxyParams{GroupName: "group", ProxyName: "node-b"})
	if result.Message != "" || !result.Changed {
		t.Fatalf("selection = %+v", result)
	}
	result = handleSelectSpeedProxy(&ChangeProxyParams{GroupName: "group", ProxyName: "missing"})
	if result.Message == "" {
		t.Fatal("accepted missing member")
	}
	if group.Adapter().(pickableGroup).Now() != "node-b" {
		t.Fatal("rejected choice changed the selected node")
	}
}

func TestVerifiedSpeedURLTestHealth(t *testing.T) {
	recordRoutes(t)
	status := http.StatusForbidden
	server := probeServer(t, func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(status)
	})
	a, b := namedProxy("node-a"), namedProxy("node-b")
	members := []constant.Proxy{a, b}
	health := provider.NewHealthCheck(members, "", 0, 0, true, nil)
	pd, err := provider.NewCompatibleProvider("auto-provider", members, health)
	if err != nil {
		t.Fatal(err)
	}
	group, err := outboundgroup.NewURLTest(
		outboundgroup.GroupCommonOption{Name: "auto", URL: server.URL, ExpectedStatus: "204"},
		outboundgroup.URLTestOption{},
		namedProxy("COMPATIBLE"),
		[]cp.ProxyProvider{pd},
	)
	if err != nil {
		t.Fatal(err)
	}
	wrapped := adapter.NewProxy(group)
	tunnel.UpdateProxies(map[string]constant.Proxy{"auto": wrapped, "node-a": a, "node-b": b}, nil)
	t.Cleanup(func() { tunnel.UpdateProxies(nil, nil) })
	group.ForceSet("node-a")

	params := &ChangeProxyParams{GroupName: "auto", ProxyName: "node-b"}
	if result := handleSelectSpeedProxy(params); result.Message == "" {
		t.Fatal("accepted HTTP 403 for an expected 204 health check")
	}
	if state, err := speedSelectionState(wrapped); err != nil || state.Fixed != "node-a" {
		t.Fatalf("rejected candidate changed fixed selection: %+v, %v", state, err)
	}
	status = http.StatusNoContent
	if result := handleSelectSpeedProxy(params); result.Message != "" {
		t.Fatalf("healthy candidate rejected: %+v", result)
	}
	if group.Now() != "node-b" {
		t.Fatalf("actual choice = %s, want node-b", group.Now())
	}
}
