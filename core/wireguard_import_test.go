package core

import (
	"strings"
	"testing"
)

// The Dart wg-quick adapter emits Mihomo YAML rather than creating a second
// VPN implementation. Validate representative adapter output against the
// exact Mihomo submodule pinned by FlClash, not only a generic YAML decoder.
func TestWireGuardQuickImportAcceptedByPinnedMihomo(t *testing.T) {
	const base = `proxies:
  - name: "Home"
    type: "wireguard"
    server: "wg.example.com"
    port: 51820
    ip: "10.0.0.2/32"
    private-key: "AQIDBAUGBwgJCgsMDQ4PEBESExQVFhcYGRobHB0eHyA="
    public-key: "ICEiIyQlJicoKSorLC0uLzAxMjM0NTY3ODk6Ozw9Pj8="
    mtu: 1280
    persistent-keepalive: 25
    udp: true
`
	const dualStack = `proxies:
  - name: "DualStack"
    type: "wireguard"
    server: "2001:db8::1"
    port: 51820
    ip: "10.0.0.2/32"
    ipv6: "2001:db8::2/128"
    private-key: "AQIDBAUGBwgJCgsMDQ4PEBESExQVFhcYGRobHB0eHyA="
    public-key: "ICEiIyQlJicoKSorLC0uLzAxMjM0NTY3ODk6Ozw9Pj8="
    dns: ["1.1.1.1", "2606:4700:4700::1111"]
    remote-dns-resolve: true
    udp: true
`
	for _, tc := range []struct {
		name, input, proxyName string
	}{
		{"ipv4", base, "Home"},
		{"dual-stack-and-dns", dualStack, "DualStack"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			cfg, err := parseConfigBytes([]byte(tc.input))
			if err != nil {
				t.Fatalf("the pinned Mihomo parser rejected converted WireGuard config: %v", err)
			}
			if cfg.Proxies[tc.proxyName] == nil {
				t.Fatalf("the pinned Mihomo parser omitted WireGuard outbound %q", tc.proxyName)
			}
		})
	}
}

func TestWireGuardQuickInvalidKeyRejectedByPinnedMihomo(t *testing.T) {
	const valid = `proxies:
  - name: "BadKey"
    type: "wireguard"
    server: "wg.example.com"
    port: 51820
    ip: "10.0.0.2/32"
    private-key: "AQIDBAUGBwgJCgsMDQ4PEBESExQVFhcYGRobHB0eHyA="
    public-key: "ICEiIyQlJicoKSorLC0uLzAxMjM0NTY3ODk6Ozw9Pj8="
`
	input := strings.Replace(valid, "AQIDBAUGBwgJCgsMDQ4PEBESExQVFhcYGRobHB0eHyA=", "not-valid-base64", 1)
	if _, err := parseConfigBytes([]byte(input)); err == nil {
		t.Fatal("pinned Mihomo accepted an invalid WireGuard private key")
	}
}
