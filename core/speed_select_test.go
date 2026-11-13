package core

import (
	"net/http"
	"sync/atomic"
	"testing"
	"time"

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
	var status atomic.Int32
	status.Store(http.StatusForbidden)
	server := probeServer(t, func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(int(status.Load()))
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
	status.Store(http.StatusNoContent)
	if result := handleSelectSpeedProxy(params); result.Message != "" {
		t.Fatalf("healthy candidate rejected: %+v", result)
	}
	if group.Now() != "node-b" {
		t.Fatalf("actual choice = %s, want node-b", group.Now())
	}
}

func TestVerifiedSpeedRejectsNetworkChangeDuringCheck(t *testing.T) {
	recordRoutes(t)
	previousReset := resetNetworkResolver
	resetNetworkResolver = func() {}
	t.Cleanup(func() { resetNetworkResolver = previousReset })

	started := make(chan struct{}, 1)
	release := make(chan struct{})
	server := probeServer(t, func(w http.ResponseWriter, r *http.Request) {
		select {
		case started <- struct{}{}:
		default:
		}
		<-release
		w.WriteHeader(http.StatusNoContent)
	})
	defer func() {
		select {
		case <-release:
		default:
			close(release)
		}
	}()

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

	done := make(chan *ChangeProxyResult, 1)
	go func() {
		done <- handleSelectSpeedProxy(&ChangeProxyParams{GroupName: "auto", ProxyName: "node-b"})
	}()
	select {
	case <-started:
	case <-time.After(5 * time.Second):
		t.Fatal("candidate health check did not start")
	}
	handleNetworkChanged()
	// Allow the health check to finish after the passive resolver reset.
	close(release)
	select {
	case result := <-done:
		if result.Message != "speed selection changed during health check" {
			t.Fatalf("stale selection result = %+v", result)
		}
	case <-time.After(10 * time.Second):
		t.Fatal("candidate health check did not finish")
	}
	if state, err := speedSelectionState(wrapped); err != nil || state.Fixed != "node-a" {
		t.Fatalf("stale candidate changed fixed selection: %+v, %v", state, err)
	}
}
