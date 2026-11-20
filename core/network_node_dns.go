package core

import (
	"context"
	"net"
	"net/netip"
	"strings"
	"time"

	"github.com/metacubex/mihomo/component/resolver"
)

// NodeDNSResult intentionally excludes server hostnames, resolved IPs and raw
// DNS errors. This is a manual, read-only diagnostic, not a protocol handshake.
type NodeDNSResult struct {
	State     string `json:"state"`
	CheckedAt int64  `json:"checked-at"`
}

func checkNodeDNSAddress(
	ctx context.Context,
	address string,
	lookup func(context.Context, string) ([]netip.Addr, error),
) string {
	host, _, err := net.SplitHostPort(address)
	if err != nil || strings.TrimSpace(host) == "" {
		return "no-endpoint"
	}
	if _, err := netip.ParseAddr(host); err == nil {
		return "ip-address"
	}

	answers, err := lookup(ctx, host)
	if ctx.Err() != nil {
		return "inconclusive"
	}
	if err != nil || len(answers) == 0 {
		return "failed"
	}
	// A resolver response may be a synthetic Fake-IP. This only proves
	// Mihomo's resolver returned an answer, not upstream reachability.
	return "answered"
}

func handleNodeDNS(params NameParams) NodeDNSResult {
	result := NodeDNSResult{State: "unavailable"}
	defer func() { result.CheckedAt = time.Now().UnixMilli() }()
	if !isRunning.Load() {
		result.State = "stopped"
		return result
	}
	if params.Name == "" {
		result.State = "no-selection"
		return result
	}
	epoch, version := routeStamp()
	proxy := lookupProxy(params.Name)
	if proxy == nil {
		result.State = "missing-node"
		return result
	}
	if isProxyGroupType(proxy.Type()) {
		result.State = "group"
		return result
	}

	ctx, cancel := context.WithTimeout(context.Background(), 4*time.Second)
	defer cancel()
	result.State = checkNodeDNSAddress(ctx, proxy.Addr(), resolver.LookupIP)
	endEpoch, endVersion := routeStamp()
	if !isRunning.Load() || epoch != endEpoch || version != endVersion {
		result.State = "stale"
	}
	return result
}
