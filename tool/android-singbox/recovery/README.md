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

The package CI applies the patch only on the dedicated recovery branch,
runs the Go gate tests with the race detector and compiles the real group
package before building an ARM64 AAR and APK. The upstream license remains
applicable; the patch and its source are distributed here.
