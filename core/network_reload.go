package core

import (
	"github.com/metacubex/mihomo/constant"
	"github.com/metacubex/mihomo/hub"
	"github.com/metacubex/mihomo/tunnel"
)

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

// Some long-lived outbounds (notably WireGuard) retain sockets bound to the
// previous Android network. Clearing tracked connections and DNS alone does
// not make those outbounds reconnect after cellular -> Wi-Fi handover.
func reloadOutboundsOnNetworkChange() {
	configMu.Lock()
	defer configMu.Unlock()

	if !isRunning.Load() || currentConfig == nil {
		return
	}
	cfg, err := loadConfig(runningConfigPath())
	if err != nil {
		logError("network change: cannot rebuild outbounds: %v", err)
		return
	}

	selected := manualSelectionsOnNetworkChange()
	currentConfig = cfg
	hub.ApplyConfig(cfg)
	patchSelectGroup(selected)
	bumpRouteEpoch()
	updateListeners(cfg)
}
