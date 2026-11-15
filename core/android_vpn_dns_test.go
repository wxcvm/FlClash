package core

import (
	"testing"

	"github.com/metacubex/mihomo/config"
	"github.com/metacubex/mihomo/constant"
)

func TestAndroidVpnDNSWhenProfileDisablesDNS(t *testing.T) {
	cfg, err := parseConfigBytes([]byte("dns:\n  enable: false\n"))
	if err != nil {
		t.Fatal(err)
	}
	// parseConfigBytes itself follows the host platform; build a disabled
	// fixture explicitly so the test checks the same path on every host.
	cfg.DNS = &config.DNS{Enable: false, Listen: "0.0.0.0:53", EnhancedMode: constant.DNSFakeIP}
	original := cfg.DNS
	effective := withAndroidVpnDNS(cfg, true)
	if !effective.DNS.Enable || effective.DNS.Listen != "" || effective.DNS.EnhancedMode != constant.DNSMapping {
		t.Fatalf("unexpected effective DNS: %+v", effective.DNS)
	}
	if len(effective.DNS.NameServer) != 1 || effective.DNS.NameServer[0].Net != "system" ||
		len(effective.DNS.DefaultNameserver) != 1 || effective.DNS.DefaultNameserver[0].Net != "system" {
		t.Fatalf("fallback must use only underlying system DNS: %+v", effective.DNS)
	}
	if cfg.DNS != original || cfg.DNS.Enable || effective.General != cfg.General {
		t.Fatal("fallback changed the original profile or unrelated settings")
	}
	if withAndroidVpnDNS(cfg, false) != cfg {
		t.Fatal("desktop DNS must be unchanged")
	}
}

func TestAndroidVpnDNSPreservesConfiguredResolver(t *testing.T) {
	cfg := &config.Config{DNS: &config.DNS{Enable: true, EnhancedMode: constant.DNSFakeIP}}
	if withAndroidVpnDNS(cfg, true) != cfg {
		t.Fatal("configured DNS must be preserved")
	}
}
