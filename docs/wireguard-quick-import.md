# WireGuard wg-quick .conf import (single peer)

FlClash can import a wg-quick client `.conf` file through its existing
**Profiles → Add → File** flow. The host converts the file into a Mihomo YAML
profile containing one `wireguard` outbound, then uses the same
`Profile.saveFile` + core validation path as any other file import. No
separate Karing screen, node manager, VPN shim, or setting store is involved.

## Supported

- One `[Interface]` and one `[Peer]`, with valid base64 32-byte
  `PrivateKey` and `PublicKey`.
- IPv4 and/or IPv6 client CIDR addresses, host or bracketed-IPv6 endpoints,
  optional `PresharedKey`, `MTU`, `PersistentKeepalive` and literal-IP
  `DNS` entries.
- Full-tunnel `AllowedIPs` matching the client address families:
  `0.0.0.0/0`, `::/0`, or both.
- Comments, CRLF, BOM and repeated address/AllowedIPs lines.

The adapter is intentionally **not** a wg-quick runner. WireGuard is exposed
as a selectable proxy inside FlClash/Mihomo; it does not take over the OS VPN,
system routes, firewall, or global DNS. `DNS` entries, when provided, become
Mihomo outbound DNS settings (`remote-dns-resolve`), not OS DNS changes.

## Rejected on purpose

- Multiple peers; split or policy-routed `AllowedIPs`.
- Interface hooks (`PreUp`, `PostUp`, `PreDown`, `PostDown`), `Table`,
  `ListenPort`, `FwMark`, `SaveConfig` or unknown keys.
- Unsupported DNS hostnames, duplicate scalar entries, malformed
  keys/addresses/endpoints.

Rejection happens before writing a profile; secrets are not echoed in errors.
Unrelated YAML/files are passed through unchanged. Real VPN or OS routing
semantics cannot be represented by a single proxy and must not be silently
flattened into one.

Source comparison: vendored
`packages/karing/lib/app/utils/wireguard_conf_utils.dart`; pinned
`core/Clash.Meta` adapter `adapter/outbound/wireguard.go`. This adapter is
implemented independently in FlClash and does not introduce Karing runtime
dependencies.
