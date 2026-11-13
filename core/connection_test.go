package core

import (
	"io"
	"net"
	"testing"
	"time"

	"github.com/metacubex/mihomo/adapter"
	"github.com/metacubex/mihomo/adapter/outbound"
	"github.com/metacubex/mihomo/constant"
	"github.com/metacubex/mihomo/tunnel"
	"github.com/metacubex/mihomo/tunnel/statistic"
)

func TestProxyOnlyTrafficLeavesOutADirectProxyOfAnyName(t *testing.T) {
	direct := outbound.NewDirectWithOption(outbound.DirectOption{Name: "直连"})
	reject := outbound.NewRejectWithOption(outbound.RejectOption{Name: "HK"})
	tunnel.UpdateProxies(map[string]constant.Proxy{
		"直连": adapter.NewProxy(direct),
		"HK": adapter.NewProxy(reject),
	}, nil)
	t.Cleanup(func() { tunnel.UpdateProxies(nil, nil) })

	for _, test := range []struct {
		outbound constant.ProxyAdapter
		proxied  int64
	}{
		{direct, 0},
		{reject, 5},
	} {
		statistic.DefaultManager.ResetStatistic()
		local, remote := net.Pipe()
		go func() { _, _ = io.Copy(io.Discard, remote) }()
		tracker := statistic.NewTCPTracker(
			outbound.NewConn(local, test.outbound),
			statistic.DefaultManager,
			&constant.Metadata{},
			nil,
			0,
			0,
			true,
		)

		if _, err := tracker.Write([]byte("hello")); err != nil {
			t.Fatalf("write through %s: %v", test.outbound.Name(), err)
		}
		_ = tracker.Close()
		_ = remote.Close()

		all, _ := statistic.DefaultManager.TotalTraffic(false)
		proxied, _ := statistic.DefaultManager.TotalTraffic(true)
		if all != 5 || proxied != test.proxied {
			t.Errorf("%s: total %d, proxied %d; want 5 and %d", test.outbound.Name(), all, proxied, test.proxied)
		}
	}
	statistic.DefaultManager.ResetStatistic()
}

// Desktop connectivity events already bump the host's probe epoch; the Core
// only needs to release resolver connections tied to the previous interface.
func TestNetworkChangeResetsResolverWithoutMovingRoute(t *testing.T) {
	previous := resetNetworkResolver
	called := 0
	resetNetworkResolver = func() { called++ }
	t.Cleanup(func() { resetNetworkResolver = previous })
	beforeEpoch, beforeVersion := routeStamp()

	handleNetworkChanged()

	if called != 1 {
		t.Errorf("resolver resets = %d, want 1", called)
	}
	afterEpoch, afterVersion := routeStamp()
	if afterEpoch != beforeEpoch || afterVersion != beforeVersion {
		t.Errorf("network change moved route from (%d, %d) to (%d, %d)", beforeEpoch, beforeVersion, afterEpoch, afterVersion)
	}
}

func TestPassiveNetworkChangeWaitsForRecovery(t *testing.T) {
	previous := resetNetworkResolver
	reset := make(chan struct{})
	done := make(chan struct{})
	resetNetworkResolver = func() { close(reset) }
	t.Cleanup(func() { resetNetworkResolver = previous })

	networkResetMu.Lock()
	go func() {
		handleNetworkChanged()
		close(done)
	}()
	select {
	case <-reset:
		networkResetMu.Unlock()
		<-done
		t.Fatal("passive DNS reset interrupted recovery")
	case <-time.After(50 * time.Millisecond):
		networkResetMu.Unlock()
	}
	select {
	case <-done:
	case <-time.After(5 * time.Second):
		t.Fatal("passive DNS reset did not resume")
	}
	select {
	case <-reset:
	default:
		t.Fatal("resolver was not reset")
	}
}

func TestNetworkChangeInvalidatesRecoveryHealth(t *testing.T) {
	previousRunning := isRunning.Load()
	previousReset := resetNetworkResolver
	t.Cleanup(func() {
		cancelRecoveryHealth()
		setRunning(previousRunning)
		resetNetworkResolver = previousReset
	})
	setRunning(true)
	resetNetworkResolver = func() {}
	epoch, version := routeStamp()
	recoveryHealthMu.Lock()
	recoveryHealth = NetworkHealthSnapshot{
		State: "reachable", CoreEpoch: epoch, RouteVersion: version,
	}
	recoveryHealthMu.Unlock()
	handleNetworkChanged()
	if got := handleNetworkHealth(); got.State != "idle" {
		t.Fatalf("previous network health survived network change: %+v", got)
	}
}

func TestStopListenerClosesTrackedConnections(t *testing.T) {
	previous := isRunning.Load()
	t.Cleanup(func() { isRunning.Store(previous) })
	setRunning(true)
	tracker := newPipeTracker(t)
	if statistic.DefaultManager.Get(tracker.ID()) == nil {
		t.Fatal("test connection was not tracked")
	}
	handleStopListener()
	if isRunning.Load() {
		t.Fatal("listener still running after stop")
	}
	if statistic.DefaultManager.Get(tracker.ID()) != nil {
		t.Fatal("stopped listener retained a live connection")
	}
	if _, err := tracker.Write([]byte("closed")); err == nil {
		t.Fatal("stopped listener left the tracked socket open")
	}
}
