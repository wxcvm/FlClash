package core

import (
	"testing"

	"github.com/metacubex/mihomo/config"
)

func TestNetworkHandoverDoesNotReloadWhenCoreIsStopped(t *testing.T) {
	previous := isRunning.Load()
	t.Cleanup(func() { isRunning.Store(previous) })

	cfg := &config.Config{}
	withCurrentConfig(t, cfg)
	isRunning.Store(false)
	reloadOutboundsOnNetworkChange()
	if currentConfig != cfg {
		t.Fatal("stopped core unexpectedly changed its config")
	}

	currentConfig = nil
	isRunning.Store(true)
	reloadOutboundsOnNetworkChange()
	if currentConfig != nil {
		t.Fatal("core without an applied profile unexpectedly reloaded")
	}
}
