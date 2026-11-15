package core

import (
	"github.com/metacubex/mihomo/config"
	"github.com/metacubex/mihomo/constant"
	"github.com/metacubex/mihomo/dns"
)

// Android's VPN always advertises its virtual DNS and relays those queries
// through Mihomo, even when the optional HTTP system proxy is disabled.
// With dns.enable=false Mihomo clears DefaultService and every relayed query
// returns SERVFAIL. Supply an internal system-DNS resolver in that case only.
// Do not change the saved profile, open a DNS listening port, or replace an
// enabled DNS configuration (including Fake-IP, DoH, and nameserver policies).
func withAndroidVpnDNS(cfg *config.Config, android bool) *config.Config {
	if !android || cfg == nil || cfg.DNS == nil || cfg.DNS.Enable {
		return cfg
	}
	system := []dns.NameServer{{Net: "system"}}
	effective := *cfg
	effective.DNS = &config.DNS{
		Enable:            true,
		IPv6:              cfg.General != nil && cfg.General.IPv6,
		IPv6Timeout:       100,
		UseHosts:          true,
		UseSystemHosts:    true,
		EnhancedMode:      constant.DNSMapping,
		NameServer:        system,
		DefaultNameserver: system,
	}
	return &effective
}
