package core

import (
	"context"
	"runtime"
	"time"

	"github.com/metacubex/mihomo/component/dialer"
	"github.com/metacubex/mihomo/listener"
	"github.com/metacubex/mihomo/log"
	"github.com/metacubex/mihomo/tunnel"
)

// Retry a known failed TUN creation, not a remote endpoint failure.
// An enabled listener is not proof of usable routes, but is not permission
// to tear it down either.
func shouldRetryTun(desired, actual bool, last, now time.Time) bool {
	return desired && !actual && now.Sub(last) >= 2*time.Minute
}

// Protected by configMu, like the applied configuration and listener changes.
var lastTunRepair time.Time

func recoverWindowsTunListener(ctx context.Context, valid func() bool) {
	if runtime.GOOS != "windows" {
		return
	}
	configMu.Lock()
	defer configMu.Unlock()
	if ctx.Err() != nil || !valid() || !isRunning.Load() ||
		currentConfig == nil || appliedConfigDigest == nil {
		return
	}
	general := currentConfig.General
	now := time.Now()
	if !shouldRetryTun(general.Tun.Enable, listener.GetTunConf().Enable, lastTunRepair, now) {
		return
	}

	// Reuse the original startup bootstrap idea: pin physical egress until
	// TUN auto-detection is ready. Never override an explicit interface or
	// an existing finder. Only release the temporary pin we installed.
	if general.Interface == "" && general.Tun.AutoRoute &&
		general.Tun.AutoDetectInterface && dialer.DefaultInterfaceFinder.Load() == nil {
		name := detectEgress()
		if name != "" && name != general.Tun.Device &&
			dialer.DefaultInterface.CompareAndSwap("", name) {
			defer dialer.DefaultInterface.CompareAndSwap(name, "")
		}
	}
	if ctx.Err() != nil || !valid() {
		return
	}
	lastTunRepair = now
	listener.ReCreateTun(general.Tun, tunnel.Tunnel)
	if listener.GetTunConf().Enable {
		log.Infoln("[Network recovery] TUN listener restored; verifying internal route")
	} else {
		log.Warnln("[Network recovery] TUN listener still disabled after repair")
	}
}
