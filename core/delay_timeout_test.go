package core

import (
	"testing"
	"time"
)

func TestEffectiveDelayTestTimeout(t *testing.T) {
	tests := []struct {
		name       string
		requested  int64
		configured time.Duration
		want       time.Duration
	}{
		{"manual exceeds provider", 8000, 3 * time.Second, 8 * time.Second},
		{"provider exceeds manual", 2000, 5 * time.Second, 5 * time.Second},
		{"manual only", 2000, 0, 2 * time.Second},
		{"provider only", 0, 3 * time.Second, 3 * time.Second},
		{"default", 0, 0, defaultDelayTestTimeout},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			if got := effectiveDelayTestTimeout(tt.requested, tt.configured); got != tt.want {
				t.Fatalf("timeout = %v, want %v", got, tt.want)
			}
		})
	}
}
