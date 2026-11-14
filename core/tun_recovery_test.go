package core

import (
	"errors"
	"net"
	"testing"
	"time"
)

func TestShouldRetryTun(t *testing.T) {
	now := time.Now()
	for _, tc := range []struct {
		name    string
		desired bool
		actual  bool
		last    time.Time
		want    bool
	}{
		{"failed creation", true, false, time.Time{}, true},
		{"healthy listener", true, true, time.Time{}, false},
		{"user disabled", false, false, time.Time{}, false},
		{"cooldown", true, false, now.Add(-time.Minute), false},
		{"retry after cooldown", true, false, now.Add(-2 * time.Minute), true},
	} {
		t.Run(tc.name, func(t *testing.T) {
			if got := shouldRetryTun(tc.desired, tc.actual, tc.last, now); got != tc.want {
				t.Fatalf("shouldRetryTun=%v, want %v", got, tc.want)
			}
		})
	}
}

func TestTunAdapterMissing(t *testing.T) {
	interfaces := []net.Interface{{Name: "Ethernet"}, {Name: "Meta"}}
	if tunAdapterMissing("meta", interfaces, nil) {
		t.Fatal("existing adapter was classified as missing")
	}
	if !tunAdapterMissing("Meta", interfaces[:1], nil) {
		t.Fatal("absent adapter was not detected")
	}
	if tunAdapterMissing("", interfaces, nil) ||
		tunAdapterMissing("Meta", nil, nil) ||
		tunAdapterMissing("Meta", interfaces[:1], errors.New("enumeration failed")) {
		t.Fatal("inconclusive enumeration authorized repair")
	}
}
