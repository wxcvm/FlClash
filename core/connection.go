package core

import (
	"sync"
	"sync/atomic"

	"github.com/metacubex/mihomo/component/resolver"
	"github.com/metacubex/mihomo/dns"
	"github.com/metacubex/mihomo/tunnel/statistic"
)

func handleGetTraffic(params TrafficParams) Traffic {
	up, down := statistic.DefaultManager.NowTraffic(params.OnlyProxy)
	return Traffic{Up: up, Down: down}
}

func handleGetTotalTraffic(params TrafficParams) Traffic {
	up, down := statistic.DefaultManager.TotalTraffic(params.OnlyProxy)
	return Traffic{Up: up, Down: down}
}

func handleResetTraffic() {
	statistic.DefaultManager.ResetStatistic()
}

func handleGetConnections() *statistic.Snapshot {
	return statistic.DefaultManager.Snapshot()
}

func handleGetConnectionCount() int {
	count := 0
	statistic.DefaultManager.Range(func(statistic.Tracker) bool {
		count++
		return true
	})
	return count
}

func handleCloseConnections() {
	statistic.DefaultManager.Range(func(c statistic.Tracker) bool {
		_ = c.Close()
		return true
	})
}

func handleResetConnections() {
	resolver.ResetConnection()
}

// A network change clears rather than waits out the TTLs: mihomo serves an
// expired entry once more before it refreshes it.
func handleClearDnsCache() {
	configMu.Lock()
	defer configMu.Unlock()
	dns.ClearAll()
}

// The pinned Mihomo ClearAll synchronously clears caches and resets each
// resolver transport once, including policy-only and bootstrap clients.
// Do not follow it with resolver.ResetConnection: that launches asynchronous
// duplicate resets and may close sockets opened on the new network.
var resetNetworkResolver = dns.ClearAll

// Guarded by configMu. Passive network changes leave the route epoch intact,
// but invalidate network-dependent selection checks already in flight.
var networkPathGeneration uint64

// handleNetworkChanged is how the desktop host reports a new network, which
// Android's NetworkObserver reports through handleResetNetwork.
func handleNetworkChanged() {
	networkResetMu.Lock()
	defer networkResetMu.Unlock()
	resetNetworkPath()
}

// Caller holds networkResetMu so passive notifications cannot interrupt an
// outbound rebuild or invalidate its health check before it is published.
func resetNetworkPath() {
	cancelRecoveryHealth()
	configMu.Lock()
	defer configMu.Unlock()
	networkPathGeneration++
	resetNetworkResolver()
	// The host already invalidates its probe cache on connectivity changes.
}

// A connection that went out over a network the device has left hangs until
// TCP gives up on it, and so do the DNS clients' pooled connections.
var networkResetMu sync.Mutex

// Android dispatches recovery asynchronously. An older queued handover must
// not close connections again after a newer handover has superseded it.
var mobileNetworkResetSequence atomic.Uint64

func runNetworkReset(sequence uint64, reset func()) {
	networkResetMu.Lock()
	defer networkResetMu.Unlock()
	// Zero denotes an explicit host recovery, not a mobile notification.
	if sequence != 0 && sequence != mobileNetworkResetSequence.Load() {
		return
	}
	reset()
}

func handleResetNetwork() {
	runNetworkReset(0, resetNetworkAndOutbounds)
}

func resetNetworkAndOutbounds() {
	handleCloseConnections()
	resetNetworkPath()
	rebuilt := reloadOutboundsOnNetworkChange()
	if isRunning.Load() {
		scheduleRecoveryHealth(rebuilt)
	}
}

// A connection that is already gone is closed as far as the host is concerned.
func handleCloseConnection(params IDParams) error {
	if c := statistic.DefaultManager.Get(params.ID); c != nil {
		_ = c.Close()
	}
	return nil
}
