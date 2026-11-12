package core

import (
	"crypto/sha256"
	"errors"
	"io"
	"os"

	"github.com/metacubex/mihomo/config"
	"github.com/metacubex/mihomo/constant"
	"github.com/metacubex/mihomo/hub"
	"github.com/metacubex/mihomo/tunnel"
)

type configDigest [sha256.Size]byte

func digestConfigBytes(buf []byte) configDigest {
	return sha256.Sum256(buf)
}

func digestConfigFile(path string) (configDigest, error) {
	file, err := os.Open(path)
	if err != nil {
		return configDigest{}, err
	}
	defer file.Close()
	hash := sha256.New()
	if _, err := io.Copy(hash, file); err != nil {
		return configDigest{}, err
	}
	var digest configDigest
	copy(digest[:], hash.Sum(nil))
	return digest, nil
}

// Preserve manually selected nodes across an outbound rebuild. Auto-testing
// groups must remain free to select a different exit on the new network.
func manualSelectionsOnNetworkChange() map[string]string {
	selectMu.Lock()
	defer selectMu.Unlock()

	selected := make(map[string]string)
	for name, proxy := range tunnel.AllProxies() {
		if proxy == nil || proxy.Type() != constant.Selector {
			continue
		}
		if group, ok := adapterAs[pickableGroup](proxy); ok {
			selected[name] = group.Now()
		}
	}
	return selected
}

// Reparse the exact applied profile to obtain fresh outbound instances. The
// host may have written a new profile since the last successful apply; that
// is not permission to activate it during a network handover.
func loadNetworkReloadConfig(path string, digest configDigest, active *config.Config) (*config.Config, error) {
	buf, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	if digestConfigBytes(buf) != digest {
		return nil, errors.New("config.yaml changed since the last successful apply")
	}
	fresh, err := parseConfigBytes(buf)
	if err != nil {
		return nil, err
	}
	// These sections are patched in place by updateConfig. Keep the live
	// values instead of rolling back ports, TUN, mode, IPv6 or credentials.
	// Fresh rules, DNS and providers still come from the same applied profile
	// so their internal references remain consistent.
	fresh.General = active.General
	fresh.Controller = active.Controller
	fresh.Users = active.Users
	return fresh, nil
}

// Some long-lived outbounds (notably WireGuard) retain sockets bound to the
// previous Android network. Clearing tracked connections and DNS alone does
// not make those outbounds reconnect after cellular -> Wi-Fi handover.
func reloadOutboundsOnNetworkChange() bool {
	configMu.Lock()
	defer configMu.Unlock()

	if !isRunning.Load() || currentConfig == nil || appliedConfigDigest == nil {
		return false
	}
	cfg, err := loadNetworkReloadConfig(runningConfigPath(), *appliedConfigDigest, currentConfig)
	if err != nil {
		logError("network change: cannot rebuild outbounds: %v", err)
		return false
	}

	selected := manualSelectionsOnNetworkChange()
	currentConfig = cfg
	hub.ApplyConfig(prepareEgress(cfg))
	patchSelectGroup(selected)
	bumpRouteEpoch()
	updateListeners(cfg)
	reconcileGeoUpdater()
	return true
}
