package tunnel

import (
	"errors"
	"testing"

	C "github.com/metacubex/mihomo/constant"
)

func TestFlClashDialFailureNotifyCallsHost(t *testing.T) {
	previous := DefaultDialFailureNotify
	t.Cleanup(func() { DefaultDialFailureNotify = previous })

	want := errors.New("dial failed")
	called := false
	DefaultDialFailureNotify = func(metadata *C.Metadata, rule C.Rule, proxy C.Proxy, err error) {
		called = true
		if metadata != nil || rule != nil || proxy != nil || !errors.Is(err, want) {
			t.Fatalf("notification = %v %v %v %v", metadata, rule, proxy, err)
		}
	}

	notifyDialFailure(nil, nil, nil, want)
	if !called {
		t.Fatal("host was not notified")
	}
}
