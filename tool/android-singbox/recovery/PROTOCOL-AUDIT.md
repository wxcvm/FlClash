# Pinned Android protocol compatibility audit

These are source pins, not a claim about the latest upstream release:
- Mihomo: `chen08209/Clash.Meta@024245dc72bc92f48237f865119afe0cd53ac9e6`
  (the app's gitlink, not the fallback string in constant/version.go).
- sing-box: `SagerNet/sing-box@c005f35300ce76427dc285481ec5695f5b179cd2`
  (v1.14.4). The official Android libbox build includes with_quic and with_utls.

Both pinned trees have VLESS/REALITY, Vision, Hysteria2 and TUIC outbound
implementations. Their schemas are not interchangeable. In particular Mihomo
RealityOptions has `support-x25519mlkem768`, while sing-box
OutboundRealityOptions has enabled/public_key/short_id; sing-box separately
defines X25519MLKEM768 in TLS curve_preferences. This is not evidence of
equivalent REALITY handshake behavior or a lossless conversion. Do not copy
or silently drop an unknown security option.

The checked-in protocol fixture uses documentation-only TEST-NET IPs, fake
UUIDs/passwords and a synthetic public key. The recovery source CI invokes
the real sing-box CLI check with QUIC/uTLS tags and this fixture before the
Android AAR build. It constructs the configured outbounds; it does not
connect to those addresses or validate a real peer. It also checks the
generated URLTest/selector topology without making the auto group default.

Use the existing private ADB single-outbound acceptance for actual remote
TLS/HTTP, DNS and handover. No real credentials belong in this fixture.
Mihomo YAML parsing, protocol-specific handshakes, UDP forwarding and
cross-core translation remain separate tests. No version upgrade in this PR.
