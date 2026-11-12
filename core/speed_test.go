package core

import (
	"context"
	"net/http"
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
