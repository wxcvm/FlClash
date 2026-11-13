package core

import (
	"context"
	"net/http"
	"sync"
	"time"
)

const (
	downloadSpeedURL     = "https://speed.cloudflare.com/__down?bytes=2097152"
	downloadSpeedBytes   = 2 * 1024 * 1024
	minSpeedSampleBytes  = 256 * 1024
	downloadSpeedTimeout = 12 * time.Second
)

type SpeedTestParams struct {
	ProxyName string `json:"proxy-name"`
}

type SpeedTestResult struct {
	Name           string `json:"name"`
	Bytes          int64  `json:"bytes"`
	BytesPerSecond int64  `json:"bytes-per-second"`
	Error          string `json:"error,omitempty"`
}

func downloadBytesPerSecond(bytes, millis int64) int64 {
	if bytes <= 0 {
		return 0
	}
	if millis < 1 {
		millis = 1
	}
	return bytes * 1000 / millis
}

// Calls run on separate goroutines. The dispatch sequence prevents a late
// cancel handler from stopping a newer test or an older test from starting
// after the host has cancelled it.
type speedTestRegistry struct {
	mu      sync.Mutex
	stopped uint64
	active  map[uint64]context.CancelFunc
}

func (r *speedTestRegistry) start(seq uint64) (context.Context, func()) {
	ctx, cancel := context.WithCancel(context.Background())
	r.mu.Lock()
	if seq <= r.stopped {
		cancel()
	} else {
		if r.active == nil {
			r.active = make(map[uint64]context.CancelFunc)
		}
		r.active[seq] = cancel
	}
	r.mu.Unlock()
	return ctx, func() {
		cancel()
		r.mu.Lock()
		delete(r.active, seq)
		r.mu.Unlock()
	}
}

func (r *speedTestRegistry) stop(seq uint64) {
	r.mu.Lock()
	defer r.mu.Unlock()
	if seq > r.stopped {
		r.stopped = seq
	}
	for id, cancel := range r.active {
		if id <= r.stopped {
			cancel()
			delete(r.active, id)
		}
	}
}

var speedTests speedTestRegistry

func handleSpeedTestCall(call *MethodCall) (any, error) {
	params, err := decodeArguments[*SpeedTestParams](call)
	if err != nil {
		return nil, err
	}
	ctx, finish := speedTests.start(call.seq)
	defer finish()
	return handleTestSpeed(ctx, params), nil
}

func handleStopSpeedCall(call *MethodCall) (any, error) {
	speedTests.stop(call.seq)
	return nil, nil
}

func handleTestSpeed(ctx context.Context, params *SpeedTestParams) *SpeedTestResult {
	return testSpeed(ctx, params, runProbe)
}

// A passive network reset invalidates samples without advancing the route epoch.
func speedPathStamp() (epoch, version, generation uint64) {
	configMu.Lock()
	defer configMu.Unlock()
	epoch, version = routeStamp()
	return epoch, version, networkPathGeneration
}

func testSpeed(ctx context.Context, params *SpeedTestParams, run func(context.Context, probeRequest) *ProbeResult) *SpeedTestResult {
	result := &SpeedTestResult{Name: params.ProxyName}
	if params.ProxyName == "" || ctx.Err() != nil {
		result.Error = probeErrorFailed
		return result
	}

	epoch, version, generation := speedPathStamp()
	probe := run(ctx, probeRequest{
		method:        http.MethodGet,
		url:           downloadSpeedURL,
		proxyName:     params.ProxyName,
		timeout:       downloadSpeedTimeout,
		downloadBytes: downloadSpeedBytes,
		noRedirect:    true,
		headers: map[string]string{
			"Accept-Encoding": "identity",
			"Cache-Control":   "no-cache",
		},
	})
	if probe == nil {
		result.Error = probeErrorTimeout
		return result
	}
	afterEpoch, afterVersion, afterGeneration := speedPathStamp()
	if ctx.Err() != nil || afterEpoch != epoch || afterVersion != version ||
		afterGeneration != generation || probe.StatusCode != http.StatusOK {
		result.Error = probeErrorFailed
		return result
	}
	// A slow node can transfer real data without finishing 2 MiB in 12s.
	// Keep a sufficiently large deadline-limited sample, but never count
	// a canceled request, premature EOF, or an HTTP error as throughput.
	complete := probe.Error == "" && probe.DownloadBytes == downloadSpeedBytes
	partial := probe.Error == probeErrorTimeout &&
		probe.DownloadBytes >= minSpeedSampleBytes &&
		probe.DownloadBytes < downloadSpeedBytes &&
		probe.DownloadMillis > 0
	if !complete && !partial {
		result.Error = probe.Error
		if result.Error == "" {
			result.Error = probeErrorFailed
		}
		return result
	}

	result.Bytes = probe.DownloadBytes
	result.BytesPerSecond = downloadBytesPerSecond(result.Bytes, probe.DownloadMillis)
	return result
}
