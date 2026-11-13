package route

import (
	"context"
	"testing"

	"github.com/sagernet/sing-box/adapter"
)

type flclashTestOutbound struct {
	adapter.Outbound
	tag string
}

func (o *flclashTestOutbound) Tag() string { return o.tag }

type flclashTestObserver struct {
	flclashTestOutbound
	calls []flclashTestOutcome
}

type flclashTestOutcome struct {
	network string
	tag string
	failed bool
}

func (o *flclashTestObserver) ObserveFlClashDial(_ context.Context, network, tag string, failed bool) {
	o.calls = append(o.calls, flclashTestOutcome{network, tag, failed})
}

func TestFlClashRouteObserver(t *testing.T) {
	outer := &flclashTestOutbound{tag: "selector"}
	auto := &flclashTestObserver{flclashTestOutbound: flclashTestOutbound{tag: "auto"}}
	leaf := &flclashTestOutbound{tag: "proxy"}
	chain := []adapter.Outbound{outer, auto, leaf}
	ctx := context.Background()
	observeFlClashRoute(ctx, chain, "tcp", true)
	observeFlClashRoute(ctx, chain, "udp", false)
	if len(auto.calls) != 2 || auto.calls[0] != (flclashTestOutcome{"tcp", "proxy", true}) ||
		auto.calls[1] != (flclashTestOutcome{"udp", "proxy", false}) {
		t.Fatalf("unexpected route outcomes: %+v", auto.calls)
	}
	canceled, cancel := context.WithCancel(ctx)
	cancel()
	observeFlClashRoute(canceled, chain, "tcp", true)
	observeFlClashRoute(ctx, nil, "tcp", true)
	observeFlClashRoute(ctx, []adapter.Outbound{auto}, "tcp", true)
	if len(auto.calls) != 2 { t.Fatal("canceled or incomplete route was observed") }
}
