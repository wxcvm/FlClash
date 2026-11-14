package core

import (
	"context"
	"errors"
	"syscall"
	"testing"
)

func TestLoopbackMixedPort(t *testing.T) {
	if !loopbackMixedPort(7890, false, "") ||
		!loopbackMixedPort(7890, true, "*") ||
		loopbackMixedPort(7890, true, "192.0.2.1") ||
		loopbackMixedPort(0, false, "") {
		t.Fatal("incorrect loopback listener eligibility")
	}
}

func TestConfirmMissingMixedListener(t *testing.T) {
	for _, tc := range []struct {
		name string
		errs []error
		want bool
	}{
		{"refused twice", []error{syscall.ECONNREFUSED, syscall.ECONNREFUSED}, true},
		{"reachable", []error{nil}, false},
		{"recovers on retry", []error{syscall.ECONNREFUSED, nil}, false},
		{"unrelated error", []error{errors.New("unknown")}, false},
	} {
		t.Run(tc.name, func(t *testing.T) {
			i := 0
			got := confirmMissingMixedListener(context.Background(), func(context.Context) error {
				err := tc.errs[i]
				i++
				return err
			}, func() bool { return true })
			if got != tc.want || i != len(tc.errs) {
				t.Fatalf("confirmed=%v calls=%d", got, i)
			}
		})
	}
	ctx, cancel := context.WithCancel(context.Background())
	if confirmMissingMixedListener(ctx, func(context.Context) error {
		cancel()
		return syscall.ECONNREFUSED
	}, func() bool { return true }) {
		t.Fatal("cancelled probe authorized repair")
	}
}
