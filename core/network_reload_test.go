package core

import (
	"testing"

	"github.com/metacubex/mihomo/component/auth"
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

func TestNetworkReloadPreservesLiveSettings(t *testing.T) {
	live := &config.Config{
		General:    &config.General{},
		Controller: &config.Controller{Secret: "live-secret"},
		Users:      []auth.AuthUser{{User: "live", Pass: "password"}},
	}
	live.General.MixedPort = 7891
	live.General.Tun.Enable = true
	live.General.Tun.Device = "live-tun"
	next := &config.Config{
		General:    &config.General{},
		Controller: &config.Controller{Secret: "old"},
	}
	preserveNetworkRuntimeConfig(next, live)
	if next.General.MixedPort != 7891 || !next.General.Tun.Enable || next.General.Tun.Device != "live-tun" {
		t.Fatal("network reload lost runtime port or TUN settings")
	}
	if next.Controller.Secret != "live-secret" || len(next.Users) != 1 || next.Users[0].User != "live" {
		t.Fatal("network reload lost live authentication")
	}
	if next.General == live.General || next.Controller == live.Controller {
		t.Fatal("network reload should not alias live settings")
	}
}
