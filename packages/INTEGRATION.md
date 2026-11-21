# Karing backend source boundary for FlClash

## Runtime contract

FlClash uses its own UI and runtime. The root application **does not depend on** `package:karing` or `package:vpn_service`; the Karing vendor tree is retained only as an upstream source reference for selective capability extraction. It is not initialized, registered as a Flutter plugin, or included in FlClash's runtime dependency graph.

FlClash remains the single source of truth:

- **Core lifecycle and proxy state:** FlClash `CoreManager`, `CoreController`, and existing Riverpod providers.
- **Profiles and persisted configuration:** FlClash config/profile providers and its existing storage layer.
- **DNS, connections, requests and traffic:** FlClash core events and existing providers/pages.
- **VPN/TUN lifecycle:** FlClash `AndroidManager` and its native Android service; desktop lifecycle remains in FlClash's existing core/service implementation.
- **UI and localization:** FlClash navigation, views, settings and localization.

Do not reintroduce Karing screens, `KaringScope`, `KaringModule`, `SettingManager`, `ServerManager`, or the Karing `VPNService` shim into the host runtime. Those pieces own a second application lifecycle, storage model and state graph.

## Existing FlClash capabilities checked

Several Karing managers duplicate capabilities already owned by FlClash and should not be imported:

- Share-link imports already go through `ProfilesAction.addProfileFromLink` and `CoreController.decodeShareLinks`; custom Clash YAML imports go through `readCustomProfileImport`. This is already the correct host integration point for proxy URI decoding and profile import.
- Proxy group state, delay tests, automatic selection and recovery are owned by `ProxiesAction`, FlClash's route tracker and the core controller.
- DNS queries, connection requests and traffic are consumed by `CoreManager` core events and written into FlClash providers.
- Profile/subscription persistence belongs to FlClash `Profile` / `ProfilesAction` and its database; Karing's `ServerManager` is not an alternate store.

Therefore, do not port Karing's full `V2RayTxtUtils` or `ServerManager` just because they exist upstream. First compare a concrete unsupported URI/protocol against FlClash's `decodeShareLinks` test vectors and the shipped Mihomo version. Only a demonstrated gap should become a small parser adapter with fixture tests.

## Selective backend parity: Hysteria shorthand (2026-11-21)

The vendored Karing `v2ray_txt_utils.dart` recognizes `hy://` as an alias
for Hysteria v1. In contrast, FlClash's pinned Mihomo
`common/convert/converter.go` accepts `hysteria://` and the Hysteria v2
`hy2://` alias but does **not** accept `hy://`. FlClash's
`shareLinkSchemes` set also excluded it. This is a concrete, narrow gap.

The host app now accepts `hy://` in link fields and QR codes; its Go share-link
boundary expands only the **line-leading** `hy://` prefix to
`hysteria://` before passing the content to the *unchanged* pinned Mihomo
converter. It also handles that alias inside a base64-encoded subscription.
Mihomo still owns proxy parsing, validation, config generation and connection
lifecycles. No Karing runtime dependency, screens, state or VPN bridge is
introduced.

Regression coverage: `test/common/link_test.dart` (URL and QR validation),
`core/share_link_test.go` (plain, uppercase, base64 and mixed-line input,
plus preservation of unrelated schemes and embedded URL text).

**Non-goals:** WireGuard INI imports and special Karing `/karing/*` endpoints
remain unimplemented; do not imply those features work without targeted
host-core integration tests. The upstream's `hy2://` support was already
present; it is not duplicated here.

## What may be extracted

Karing can be used as a reference when a concrete FlClash feature gap is identified. Prefer small, deterministic, independently testable functions over importing whole application modules. Potential audit areas include:

- subscription and proxy URI parsing/conversion (for example `proxy_conf_utils.dart`, `v2ray_txt_utils.dart`, and `wireguard_conf_utils.dart`);
- Clash/Sing-box configuration conversion and validation (for example `clash_to_singbox.dart`, `singbox_config_builder.dart`, and `conf_parser.dart`);
- ruleset/diversion normalization (for example `ruleset_codes_utils.dart` and `diversion_custom_utils.dart`);
- chain ordering and version comparison helpers.

These are **candidates for review, not integrations already present**. Before porting any function:
1. Identify a concrete FlClash feature gap and its existing owner/provider.
2. Check the upstream license and preserve required attribution.
3. Extract only the pure logic needed; remove hidden global state, Karing storage, app lifecycle, telemetry, and platform service dependencies.
4. Adapt inputs/outputs to FlClash models and existing providers. Do not create a second profile/server/settings database.
5. Add golden/fixture tests for valid inputs, malformed inputs, backwards compatibility and output equivalence.
6. Verify the generated configuration is accepted by the exact Mihomo/Sing-box core version shipped by FlClash.

## Core API and VPN boundaries

Karing's `ClashApi` contains Karing-specific `/karing/*` endpoints. Do not assume the FlClash Mihomo build implements them. Use FlClash's existing `CoreController` API first; an optional endpoint must be capability-detected and covered by a core integration test before use.

Do not reuse Karing's `ServerManager` or `SettingManager` for node selection, profile persistence or DNS. Do not reuse its `vpn_service` shim for VPN authorization, service state or lifecycle. FlClash's `AndroidManager` and native service remain authoritative.

## Feature mapping

| Capability | FlClash owner |
| --- | --- |
| DNS configuration and query history | Existing FlClash DNS config/provider and DNS page |
| Diversion/routing rules | Existing FlClash Config → Rules and custom-profile Rules views |
| Proxy selection, groups and URL tests | Existing FlClash CoreController, route tracker, proxy providers and Proxies page |
| Connections and traffic | Existing CoreManager events, Requests provider and Requests page |
| Profiles and subscriptions | Existing FlClash profile/config providers |
| Backup/export/import | Existing FlClash Tools and profile/config storage |
| Per-app proxy | Existing Android access-control and VPN service |
| VPN/TUN and system proxy | Existing AndroidManager/native service and desktop proxy manager |

No Karing page should be added to the navigation or More menu. Legacy `PageLabel.karing` is retained only as a persisted-value compatibility sentinel so an older saved tab falls back to the FlClash dashboard; it is not a live destination.
