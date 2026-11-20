package core

import (
	"context"
	"time"

	"github.com/metacubex/http"
)

// A single header-only request through the selected proxy, not a speed test.
// The result contains no URL, selected node address, IP or raw dial error.
const nodeHTTPSProbeURL = "https://www.cloudflare.com/cdn-cgi/trace"

type NodeHTTPSResult struct {
	State      string `json:"state"`
	HTTPStatus int    `json:"http-status,omitempty"`
	Delay      int64  `json:"delay,omitempty"`
	CheckedAt  int64  `json:"checked-at"`
}

func probeNodeHTTPS(
	ctx context.Context,
	name string,
	probe func(context.Context, probeRequest) *ProbeResult,
) NodeHTTPSResult {
	answer := probe(ctx, probeRequest{
		method:    http.MethodHead,
		url:       nodeHTTPSProbeURL,
		proxyName: name,
		timeout:   6 * time.Second,
		noRedirect: true,
	})
	switch {
	case answer == nil:
		return NodeHTTPSResult{State: "busy"}
	case ctx.Err() != nil:
		return NodeHTTPSResult{State: "inconclusive"}
	case answer.Error == probeErrorTimeout:
		return NodeHTTPSResult{State: "timeout"}
	case answer.Error != "":
		return NodeHTTPSResult{State: "failed"}
	case answer.StatusCode >= 200 && answer.StatusCode < 400:
		return NodeHTTPSResult{State: "reachable", HTTPStatus: answer.StatusCode, Delay: answer.Delay}
	case answer.StatusCode > 0:
		// Even a 403/405/5xx proves that an HTTPS response arrived. It says
		// nothing about the availability of other websites or protocols.
		return NodeHTTPSResult{State: "http-response", HTTPStatus: answer.StatusCode, Delay: answer.Delay}
	default:
		return NodeHTTPSResult{State: "inconclusive"}
	}
}

func handleNodeHTTPS(params NameParams) (result NodeHTTPSResult) {
	result = NodeHTTPSResult{State: "unavailable"}
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
	ctx, cancel := context.WithTimeout(context.Background(), 8*time.Second)
	defer cancel()
	result = probeNodeHTTPS(ctx, params.Name, runProbe)
	afterEpoch, afterVersion := routeStamp()
	if !isRunning.Load() || epoch != afterEpoch || version != afterVersion ||
		lookupProxy(params.Name) != proxy {
		result = NodeHTTPSResult{State: "stale"}
	}
	return result
}
