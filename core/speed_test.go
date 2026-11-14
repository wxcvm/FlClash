package core

import (
	"context"
	"net/http"
	"strconv"
	"strings"
	"testing"
	"time"
)

func TestDownloadSpeedRate(t *testing.T) {
	tests := []struct {
		bytes  int64
		millis int64
		want   int64
	}{
		{0, 1000, 0},
		{1024 * 1024, 1000, 1024 * 1024},
		{1024 * 1024, 2000, 512 * 1024},
		{1024, 0, 1024 * 1000},
	}
	for _, test := range tests {
		got := downloadBytesPerSecond(test.bytes, test.millis)
		if got != test.want {
			t.Errorf("rate(%d, %d) = %d, want %d",
				test.bytes, test.millis, got, test.want)
		}
	}
}

func TestDownloadProbeRequiresCompleteSample(t *testing.T) {
	withProbeProxies(t, "speed-node")
	server := probeServer(t, func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/partial":
			_, _ = w.Write([]byte("short"))
		case "/error":
			w.WriteHeader(http.StatusForbidden)
		default:
			_, _ = w.Write([]byte(strings.Repeat("x", 1024)))
		}
	})

	probe := func(path string) *ProbeResult {
		return runProbe(context.Background(), probeRequest{
			url:           server.URL + path,
			proxyName:     "speed-node",
			timeout:       2 * time.Second,
			downloadBytes: 1024,
		})
	}
	full := probe("/full")
	if full == nil || full.Error != "" || full.DownloadBytes != 1024 ||
		full.DownloadMillis < 1 || full.Body != "" {
		t.Fatalf("full sample = %+v", full)
	}
	partial := probe("/partial")
	if partial == nil || partial.Error == "" || partial.DownloadBytes != 0 {
		t.Fatalf("partial download was accepted: %+v", partial)
	}
	rejected := probe("/error")
	if rejected == nil || rejected.StatusCode != http.StatusForbidden ||
		rejected.DownloadBytes != 0 {
		t.Fatalf("HTTP error counted as a download: %+v", rejected)
	}
}

func TestSpeedUsesLargerSampleOnlyForSustainedTest(t *testing.T) {
	for _, sustained := range []bool{false, true} {
		want := int64(downloadSpeedBytes)
		if sustained {
			want = sustainedSpeedBytes
		}
		result := testSpeed(context.Background(), &SpeedTestParams{ProxyName: "node", Sustained: sustained},
			func(_ context.Context, req probeRequest) *ProbeResult {
				if req.downloadBytes != want || req.timeout != downloadSpeedTimeout ||
					!strings.HasSuffix(req.url, strconv.FormatInt(want, 10)) {
					t.Fatalf("unexpected speed request: %+v", req)
				}
				return &ProbeResult{StatusCode: http.StatusOK, DownloadBytes: want, DownloadMillis: 1000}
			})
		if result.Error != "" || result.BytesPerSecond != want {
			t.Fatalf("unexpected speed result: %+v", result)
		}
	}
}

func TestSustainedSpeedAcceptsPartialDeadlineButNotShortEOF(t *testing.T) {
	for _, err := range []string{probeErrorTimeout, probeErrorFailed, ""} {
		result := testSpeed(context.Background(), &SpeedTestParams{ProxyName: "node", Sustained: true},
			func(context.Context, probeRequest) *ProbeResult {
				return &ProbeResult{StatusCode: http.StatusOK, Error: err,
					DownloadBytes: downloadSpeedBytes, DownloadMillis: 10000}
			})
		if (result.Error == "") != (err == probeErrorTimeout) {
			t.Fatalf("unexpected sustained sample for %q: %+v", err, result)
		}
	}
}

func TestSpeedAcceptsDeadlineLimitedSample(t *testing.T) {
	result := testSpeed(context.Background(), &SpeedTestParams{ProxyName: "node"},
		func(context.Context, probeRequest) *ProbeResult {
			return &ProbeResult{StatusCode: http.StatusOK, Error: probeErrorTimeout,
				DownloadBytes: minSpeedSampleBytes, DownloadMillis: 10000}
		})
	if result.Error != "" || result.Bytes != minSpeedSampleBytes ||
		result.BytesPerSecond != minSpeedSampleBytes/10 {
		t.Fatalf("deadline-limited sample = %+v", result)
	}
}

func TestSpeedRejectsInvalidPartialSamples(t *testing.T) {
	for _, sample := range []ProbeResult{
		{StatusCode: http.StatusOK, Error: probeErrorTimeout, DownloadBytes: minSpeedSampleBytes - 1, DownloadMillis: 10000},
		{StatusCode: http.StatusOK, Error: probeErrorFailed, DownloadBytes: minSpeedSampleBytes, DownloadMillis: 10000},
		{StatusCode: http.StatusForbidden, Error: probeErrorTimeout, DownloadBytes: minSpeedSampleBytes, DownloadMillis: 10000},
	} {
		result := testSpeed(context.Background(), &SpeedTestParams{ProxyName: "node"},
			func(context.Context, probeRequest) *ProbeResult { return &sample })
		if result.Error == "" || result.BytesPerSecond != 0 {
			t.Fatalf("accepted invalid partial sample: %+v", result)
		}
	}
}

func TestSpeedRejectsCompletedSampleAfterPassiveNetworkChange(t *testing.T) {
	recordRoutes(t)
	previousReset := resetNetworkResolver
	resetNetworkResolver = func() {}
	t.Cleanup(func() { resetNetworkResolver = previousReset })
	result := testSpeed(context.Background(), &SpeedTestParams{ProxyName: "node"},
		func(context.Context, probeRequest) *ProbeResult {
			handleNetworkChanged()
			return &ProbeResult{StatusCode: http.StatusOK, DownloadBytes: downloadSpeedBytes, DownloadMillis: 1000}
		})
	if result.Error == "" || result.BytesPerSecond != 0 {
		t.Fatalf("accepted old network sample: %+v", result)
	}
}

func TestSpeedRejectsCompletedSampleAfterCancellation(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	result := testSpeed(ctx, &SpeedTestParams{ProxyName: "node"},
		func(context.Context, probeRequest) *ProbeResult {
			cancel()
			return &ProbeResult{StatusCode: http.StatusOK, DownloadBytes: downloadSpeedBytes, DownloadMillis: 1000}
		})
	if result.Error == "" || result.BytesPerSecond != 0 {
		t.Fatalf("accepted canceled sample: %+v", result)
	}
}

func TestSpeedCancellationRespectsDispatchOrder(t *testing.T) {
	var registry speedTestRegistry
	old, finishOld := registry.start(1)
	defer finishOld()
	newer, finishNew := registry.start(3)
	defer finishNew()

	registry.stop(2)
	if old.Err() != context.Canceled {
		t.Fatal("active old test was not cancelled")
	}
	if newer.Err() != nil {
		t.Fatal("newer test was cancelled by a stale stop")
	}

	late, finishLate := registry.start(2)
	defer finishLate()
	if late.Err() != context.Canceled {
		t.Fatal("late old handler was allowed to start")
	}
	registry.stop(4)
	if newer.Err() != context.Canceled {
		t.Fatal("newer test was not cancelled by the next stop")
	}
}
