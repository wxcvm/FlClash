package core

import (
	"context"
	"net"
	"runtime"
	"strings"
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

// A failed or empty enumeration is inconclusive. Match the actual adapter
// name reported by Mihomo, not the potentially empty requested device name.
func tunAdapterMissing(name string, interfaces []net.Interface, err error) bool {
	if name == "" || err != nil || len(interfaces) == 0 {
		return false
	}
	for _, iface := range interfaces {
		if strings.EqualFold(iface.Name, name) {
			return false
		}
	}
	return true
}

func windowsTunAdapterMissing(name string) bool {
	interfaces, err := net.Interfaces()
	return tunAdapterMissing(name, interfaces, err)
}

// Protected by configMu, like the applied configuration and listener changes.
var lastTunRepair time.Time

func recoverWindowsTunListener(ctx context.Context, valid func() bool) {
	if runtime.GOOS != "windows" {
		return
	}
	configMu.Lock()
	if ctx.Err() != nil || !valid() || !isRunning.Load() ||
		currentConfig == nil || appliedConfigDigest == nil {
		configMu.Unlock()
		return
	}
	cfg := currentConfig
	general := cfg.General
	actual := listener.GetTunConf()
	observedDevice := actual.Device
	now := time.Now()
	missing := general.Tun.Enable && actual.Enable &&
		now.Sub(lastTunRepair) >= 2*time.Minute &&
		windowsTunAdapterMissing(actual.Device)
	if missing {
		// Do not hold the configuration lock while waiting for Windows to
		// finish a transient adapter update.
		configMu.Unlock()
		timer := time.NewTimer(500 * time.Millisecond)
		defer timer.Stop()
		select {
		case <-ctx.Done():
			return
		case <-timer.C:
		}
		configMu.Lock()
	}
	defer configMu.Unlock()
	if ctx.Err() != nil || !valid() || !isRunning.Load() ||
		currentConfig != cfg || appliedConfigDigest == nil {
		return
	}
	actual = listener.GetTunConf()
	now = time.Now()
	// Re-read the active state under the lock. A concurrent setup may have
	// restored the adapter while the first observation was pending.
	if !shouldRetryTun(general.Tun.Enable, actual.Enable, lastTunRepair, now) {
		if !missing || !general.Tun.Enable || !actual.Enable || actual.Device != observedDevice ||
			now.Sub(lastTunRepair) < 2*time.Minute ||
			!windowsTunAdapterMissing(actual.Device) {
			return
		}
		// ReCreateTun otherwise only calls OnReload for identical options.
		// Close the missing adapter's stale listener before recreating it.
		disabled := general.Tun
		disabled.Enable = false
		listener.ReCreateTun(disabled, tunnel.Tunnel)
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
	// Once a missing adapter has been closed, finish this repair under the
	// config lock even if the probe expires; the next stop/apply can follow.
	lastTunRepair = now
	listener.ReCreateTun(general.Tun, tunnel.Tunnel)
	if listener.GetTunConf().Enable {
		log.Infoln("[Network recovery] TUN listener restored; verifying internal route")
	} else {
		log.Warnln("[Network recovery] TUN listener still disabled after repair")
	}
}
