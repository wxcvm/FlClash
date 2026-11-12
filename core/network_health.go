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
}

var (
	recoveryHealthMu     sync.Mutex
	recoveryHealthCancel context.CancelFunc
)

func cancelRecoveryHealth() {
	recoveryHealthMu.Lock()
	defer recoveryHealthMu.Unlock()
	if recoveryHealthCancel != nil {
		recoveryHealthCancel()
		recoveryHealthCancel = nil
	}
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
			return recoveryHealthResult{state: "reachable", status: result.StatusCode}
		}
		return recoveryHealthResult{state: "http-response", status: result.StatusCode}
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
	recoveryHealthMu.Lock()
	if recoveryHealthCancel != nil {
		recoveryHealthCancel()
	}
	ctx, cancel := context.WithTimeout(context.Background(), 25*time.Second)
	recoveryHealthCancel = cancel
	recoveryHealthMu.Unlock()

	epoch, version := routeStamp()
	target := currentTestURL()
	safeGo("networkRecoveryHealth", func() {
		defer cancel()
		valid := func() bool {
			e, v := routeStamp()
			return ctx.Err() == nil && isRunning.Load() && e == epoch && v == version
		}
		for attempt := 1; attempt <= 2; attempt++ {
			if !valid() {
				return
			}
			result := checkRecoveryHealth(ctx, target, runProbe, resolver.LookupIP)
			if !valid() {
				return
			}
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
