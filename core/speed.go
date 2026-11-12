package core

import (
	"context"
	"net/http"
	"time"
)

const (
	downloadSpeedURL      = "https://speed.cloudflare.com/__down?bytes=3145728"
	downloadSpeedMaxBytes = 2 * 1024 * 1024
	downloadSpeedMinBytes = 256 * 1024
	downloadSpeedTimeout  = 12 * time.Second
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

func handleTestSpeed(params *SpeedTestParams) *SpeedTestResult {
	result := &SpeedTestResult{Name: params.ProxyName}
	if params.ProxyName == "" {
		result.Error = probeErrorFailed
		return result
	}

	epoch, version := routeStamp()
	start := time.Now()
	probe := runProbe(context.Background(), probeRequest{
		method:    http.MethodGet,
		url:       downloadSpeedURL,
		proxyName: params.ProxyName,
		timeout:   downloadSpeedTimeout,
		maxBody:   downloadSpeedMaxBytes,
		headers: map[string]string{
			"Accept-Encoding": "identity",
			"Cache-Control":   "no-cache",
		},
	})
	if probe == nil {
		result.Error = probeErrorTimeout
		return result
	}
	if probe.Error != "" {
		result.Error = probe.Error
		return result
	}
	afterEpoch, afterVersion := routeStamp()
	if afterEpoch != epoch || afterVersion != version ||
		probe.StatusCode != http.StatusOK ||
		len(probe.Body) < downloadSpeedMinBytes {
		result.Error = probeErrorFailed
		return result
	}

	result.Bytes = int64(len(probe.Body))
	result.BytesPerSecond = downloadBytesPerSecond(result.Bytes, time.Since(start).Milliseconds())
	return result
}
