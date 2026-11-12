# Android sing-box integration probe

This is an opt-in build experiment, not an Android release or a second selectable
VPN engine. The existing APK and default Mihomo build remain unchanged.

## Upstream

- SagerNet/sing-box v1.14.4, commit c005f35300ce76427dc285481ec5695f5b179cd2.
- Official Android libbox builder, upstream Go 1.26.10 / Java 17 / NDK r28.
- ARM64 first, to avoid repeating the full multi-ABI release build.
- Builds from upstream source; no third-party AAR mirrors.

The dedicated workflow builds and checks the AAR, verifies the arm64 native
library and Java bridge, and compiles a small API contract covering native
configuration validation, command server lifecycle and network reset. It never
loads JNI on the CI host. The artifact is not copied into the production APK.

## Integration gates

Both the current Mihomo binding and libbox expose the gomobile go.Seq Java
bridge. A different native library filename alone is not enough to combine them.
Resolve Java/JNI binding ownership (and native runtime isolation) before adding
both to one APK; do not delete one bridge or rely on duplicate class exclusion.

The next runtime adapter must implement the upstream PlatformInterface:
OpenTun with one descriptor owner, socket protection via Android VpnService,
network interface monitoring and DNS, and process/package lookup. The command
server must have a private endpoint and be closed on failure/stop. The existing
VPN service must not start Mihomo listeners while another engine owns traffic.
Flutter RPC, profile, traffic and restart state must follow the selected engine.
Check native config before interrupting an active VPN, then test failed startup
and rollback on a real Android device. No selectable UI until these gates pass.

Upstream uses its own native JSON schema, not a Clash YAML subscription.
Preserve the existing default for ordinary Clash profiles.
