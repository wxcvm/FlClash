package core

import (
	"context"
	"net/netip"
	"net/url"
	"sync"
	"time"

	"github.com/metacubex/mihomo/component/resolver"
	"github.com/metacubex/mihomo/log"
)

const (
	recoveryProbeTimeout = 5 * time.Second
	recoveryDNSDeadline  = 3 * time.Second
	recoveryRetryDelay   = 2 * time.Second
)

type recoveryHealthResult struct {
	state  string
	status int
	delay  int64
}

// The snapshot is only about the configured test endpoint on the current
// route. DNS is marked untested unless an independent lookup actually ran.
type NetworkHealthSnapshot struct {
	State        string `json:"state"`
	Source       string `json:"source,omitempty"`
	Host         string `json:"host,omitempty"`
	Attempt      int    `json:"attempt"`
	Failures     int    `json:"confirmed-failures"`
	HTTPStatus   int    `json:"http-status,omitempty"`
	Delay        int64  `json:"delay,omitempty"`
	DNS          string `json:"dns"`
	Rebuilt      bool   `json:"rebuilt"`
	CheckedAt    int64  `json:"checked-at,omitempty"`
	CoreEpoch    uint64 `json:"core-epoch"`
	RouteVersion uint64 `json:"route-version"`
}

// An inconclusive probe (for example, no available probe slot) is not a
// confirmed failure and must not authorize automatic connection teardown.
func (s *NetworkHealthSnapshot) recordFailure(result recoveryHealthResult) {
	if result.state == "dns-failure" || result.state == "route-unreachable" {
		s.Failures++
	}
}

var (
	recoveryHealthMu     sync.Mutex
	recoveryHealthCancel context.CancelFunc
	recoveryHealth       NetworkHealthSnapshot
	recoveryHealthRun    uint64
)

func cancelRecoveryHealth() {
	recoveryHealthMu.Lock()
	defer recoveryHealthMu.Unlock()
	if recoveryHealthCancel != nil {
		recoveryHealthCancel()
		recoveryHealthCancel = nil
	}
	recoveryHealthRun++
	recoveryHealth = NetworkHealthSnapshot{}
}

func handleNetworkHealth() NetworkHealthSnapshot {
	epoch, version := routeStamp()
	recoveryHealthMu.Lock()
	defer recoveryHealthMu.Unlock()
	if !isRunning.Load() {
		return NetworkHealthSnapshot{State: "stopped", DNS: "untested"}
	}
	if recoveryHealth.State == "" || recoveryHealth.CoreEpoch != epoch ||
		recoveryHealth.RouteVersion != version {
		return NetworkHealthSnapshot{State: "idle", DNS: "untested", CoreEpoch: epoch, RouteVersion: version}
	}
	return recoveryHealth
}

func handleCheckNetworkHealth() {
	if isRunning.Load() {
		startRecoveryHealth("manual", false)
	}
}

func recoveryDNSState(result recoveryHealthResult, host string) string {
	if _, err := netip.ParseAddr(host); err == nil {
		return "not-required"
	}
	switch result.state {
	case "dns-failure":
		return "failed"
	case "route-unreachable":
		return "resolved"
	}
	return "untested"
}

// Probe the configured test address through the actual tunnel route. A
// separate core DNS lookup is diagnostic only: proxy-side DNS, fake-IP, and
// endpoint-specific blocking mean it cannot prove the entire network is down.
func checkRecoveryHealth(ctx context.Context, target string,
	probe func(context.Context, probeRequest) *ProbeResult,
	lookup func(context.Context, string) ([]netip.Addr, error),
) recoveryHealthResult {
	u, err := url.Parse(target)
	if err != nil || u.Hostname() == "" || (u.Scheme != "https" && u.Scheme != "http") {
		return recoveryHealthResult{state: "invalid-test-url"}
	}
	result := probe(ctx, probeRequest{url: target, timeout: recoveryProbeTimeout, noRedirect: true})
	if ctx.Err() != nil || result == nil {
		return recoveryHealthResult{state: "inconclusive"}
	}
	if result.Error == "" && result.StatusCode > 0 {
		if result.StatusCode >= 200 && result.StatusCode < 300 {
			return recoveryHealthResult{state: "reachable", status: result.StatusCode, delay: result.Delay}
		}
		return recoveryHealthResult{state: "http-response", status: result.StatusCode, delay: result.Delay}
	}
	if _, err := netip.ParseAddr(u.Hostname()); err == nil {
		return recoveryHealthResult{state: "route-unreachable"}
	}
	dnsCtx, cancel := context.WithTimeout(ctx, recoveryDNSDeadline)
	defer cancel()
	addresses, err := lookup(dnsCtx, u.Hostname())
	if ctx.Err() != nil {
		return recoveryHealthResult{state: "inconclusive"}
	}
	if err != nil || len(addresses) == 0 {
		return recoveryHealthResult{state: "dns-failure"}
	}
	return recoveryHealthResult{state: "route-unreachable"}
}

// One bounded retry verifies recovery without repeatedly closing existing
// connections or restarting the core. A newer handover or route change
// invalidates the result.
func scheduleRecoveryHealth(rebuilt bool) {
	startRecoveryHealth("handover", rebuilt)
}

func startRecoveryHealth(source string, rebuilt bool) {
	epoch, version := routeStamp()
	target := currentTestURL()
	host := ""
	if u, err := url.Parse(target); err == nil {
		host = u.Hostname()
	}
	recoveryHealthMu.Lock()
	// A manual tap must not replace an active handover verification.
	if source == "manual" && recoveryHealth.State == "checking" &&
		recoveryHealth.CoreEpoch == epoch && recoveryHealth.RouteVersion == version {
		recoveryHealthMu.Unlock()
		return
	}
	if recoveryHealthCancel != nil {
		recoveryHealthCancel()
	}
	ctx, cancel := context.WithTimeout(context.Background(), 25*time.Second)
	recoveryHealthCancel = cancel
	recoveryHealthRun++
	run := recoveryHealthRun
	snapshot := NetworkHealthSnapshot{
		State: "checking", Source: source, Host: host, DNS: "untested",
		Rebuilt: rebuilt, CoreEpoch: epoch, RouteVersion: version,
	}
	recoveryHealth = snapshot
	recoveryHealthMu.Unlock()

	publish := func(attempt int, result recoveryHealthResult, final bool) {
		recoveryHealthMu.Lock()
		defer recoveryHealthMu.Unlock()
		if ctx.Err() != nil || recoveryHealthRun != run {
			return
		}
		snapshot.Attempt = attempt
		snapshot.recordFailure(result)
		snapshot.DNS = recoveryDNSState(result, host)
		snapshot.HTTPStatus = result.status
		snapshot.Delay = result.delay
		snapshot.CheckedAt = time.Now().UnixMilli()
		if final {
			snapshot.State = result.state
		}
		recoveryHealth = snapshot
	}
	safeGo("networkRecoveryHealth", func() {
		defer func() {
			cancel()
			recoveryHealthMu.Lock()
			defer recoveryHealthMu.Unlock()
			if recoveryHealthRun != run {
				return
			}
			recoveryHealthCancel = nil
			if recoveryHealth.State == "checking" {
				recoveryHealth.State = "inconclusive"
				recoveryHealth.CheckedAt = time.Now().UnixMilli()
			}
		}()
		valid := func() bool {
			e, v := routeStamp()
			return ctx.Err() == nil && isRunning.Load() && e == epoch && v == version
		}
		// Repair only a confirmed missing local listener, not a remote
		// endpoint failure. The internal route probe cannot detect this.
		if source == "manual" && valid() {
			recoverWindowsMixedListener(ctx, valid)
		}
		for attempt := 1; attempt <= 2; attempt++ {
			if !valid() {
				return
			}
			result := checkRecoveryHealth(ctx, target, runProbe, resolver.LookupIP)
			if !valid() {
				return
			}
			done := result.state == "reachable" || result.state == "http-response" ||
				result.state == "invalid-test-url" || attempt == 2
			publish(attempt, result, done)
			if result.state == "reachable" || result.state == "http-response" {
				log.Infoln("[Network recovery] %s HTTP %d (attempt %d, rebuilt=%t)", result.state, result.status, attempt, rebuilt)
				return
			}
			if result.state == "invalid-test-url" || attempt == 2 {
				log.Warnln("[Network recovery] verification not confirmed: %s (attempt %d, rebuilt=%t); preserving current configuration", result.state, attempt, rebuilt)
				return
			}
			log.Infoln("[Network recovery] %s; retrying verification once", result.state)
			timer := time.NewTimer(recoveryRetryDelay)
			select {
			case <-ctx.Done():
				timer.Stop()
				return
			case <-timer.C:
			}
		}
	})
}
