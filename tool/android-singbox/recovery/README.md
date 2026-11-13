# FlClash URLTest failure recovery (experimental)

The Android recovery build uses sing-box v1.14.4 at the pinned upstream commit
`c005f35300ce76427dc285481ec5695f5b179cd2`, with a narrow reviewed source
extension. It builds libbox from source rather than claiming that the stock
AAR contains the change. Existing builds and profiles remain unchanged.

Only URLTest groups with the reserved name prefix `FlClash Auto · ` opt in
(the app's generated recovery groups). Three consecutive completed dial or
packet-listen failures for the same outbound and transport admit a forced
native URLTest. Successful calls reset the streak; TCP and UDP are tracked
separately. One check per group at a time, at least 10 seconds between
admissions, 20-second context deadline. Existing URLTest selection, tolerance
and connection interruption settings remain authoritative. No retry/replay
of failed application traffic; no new direct fallback. Canceled requests,
paused network/device and a closed group do not trigger checks.

A dial success does not prove all application-layer handshakes work; a probe
failure does not prove every destination is unavailable. The enhancement is
a prompt health recheck, not guaranteed instantaneous failover. If a native
periodic check is already running, its existing single-flight guard wins.
The actual device forwarding and node recovery still need testing.

Candidate and signed Android ARM64 preview builds share `build-libbox.sh`.
Candidate CI runs the Go race, group, route and protocol-fixture checks;
the signed preview builds the same pinned source instead of downloading a
previous CI artifact. The preview passes the AAR to Gradle via
`ORG_GRADLE_PROJECT_flclashSingBoxAar` and checks both native libraries and
the isolated DEX in the final APK. Mihomo remains the default VPN owner.
The release-check APK uses the existing development signing fallback, not
the production certificate. The upstream license remains
applicable; the patch and its source are distributed here.

The 1.14.4 router resolves groups to the leaf before dialing. The patch also
observes the original OutboundChain in ConnectionManager after TCP dial or
initial remote write handshake, UDP connect/listen, and successful setup.
This preserves the real leaf's optional interfaces and existing routing logic.
Ordinary post-establishment copy errors, application responses and arbitrary
connection closes are not treated as node failures. Network interface changes
clear the old failure streak, and canceled recovery cannot update selection.
A route observer test verifies chain attribution and cancellation separately.
