package core

import (
	"errors"
	"testing"
)

func TestProtectOutboundSocket(t *testing.T) {
	control := func(f func(uintptr)) error {
		f(42)
		return nil
	}
	if err := protectOutboundSocket(control, func(fd int) bool { return fd == 42 }); err != nil {
		t.Fatal(err)
	}
	if err := protectOutboundSocket(control, func(int) bool { return false }); !errors.Is(err, errVPNProtect) {
		t.Fatalf("refused protection: %v", err)
	}
	controlErr := errors.New("descriptor closed")
	if err := protectOutboundSocket(func(func(uintptr)) error { return controlErr }, func(int) bool {
		t.Fatal("callback must not run for a closed descriptor")
		return true
	}); !errors.Is(err, controlErr) {
		t.Fatalf("descriptor failure: %v", err)
	}
}
