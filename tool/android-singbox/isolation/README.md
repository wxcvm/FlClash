# Android dual-runtime isolation experiment

Standalone diagnostic APK, not production FlClash. The ARM64 build includes
isolation checks and an explicitly consented, app-only HTTPS/DNS VPN test.
The x86_64 Android emulator build additionally tests local TUN/TCP traffic.
The host loads the real FlClash Mihomo bridge and libclash.so before and after
two Binder calls to official sing-box in a separate :singbox process and
classloader. Both calls verify the same remote PID, version and invalid JSON rejection.

Build the project's existing ARM64 core with its Flutter/Go/NDK/Gradle setup:

    cd android
    ./gradlew :core:bindCore -Ptarget-platform=android-arm64
    cd ..
    bash tool/android-singbox/isolation/build.sh libbox.aar out build/core/gomobile/classes.jar build/core/gomobile/core.aar

Use the patched classes.jar (not the raw AAR jar). The existing Gradle build
renames the JNI library to libclash.so; this diagnostic preserves that name.

    adb install out/singbox-isolation-probe.apk
    adb shell am force-stop org.flclash.singboxprobe
    adb shell am instrument -w org.flclash.singboxprobe/.ProbeInstrumentation

Android 10+ ARM64 required for the manual diagnostic. CI uses an Android 35
x86_64 emulator. Each build uses a fresh diagnostic signing key.
Uninstall only org.flclash.singboxprobe before installing a newer diagnostic APK.
Never uninstall production FlClash.

PASS requires actual Mihomo JNI calls before and after two successful libbox
calls in the same separate process. A bidirectional Binder pipe descriptor
transfer additionally checks real OS handle duplication and closure semantics,
not just integer serialization. This *coexistence-only* instrumentation does
not test VPN traffic, TUN ownership, socket protection, DNS, engine switching
or memory release. The separate VPN tests exercise some of these paths.
The diagnostic has its own package ID and does not modify production FlClash.
The isolated DEX now includes AndroidTunBridge, compiled against the actual
pinned libbox API. It maps TUN addresses, computed routes, MTU, DNS and package
filters to VpnService.Builder, retains the original descriptor (libbox duplicates
it), and rejects a failed socket protect call. Its descriptor duplication smoke
check runs through the isolated loader. The explicitly consented VPN service
and emulator instrumentation now exercise real OpenTun/protect callbacks.
Close the bridge only after native service stop; HTTP proxy options are
explicitly rejected until supported.
LibboxVpnSession adds the typed command server setup/start/reset/stop path,
using a private Unix socket and app-private directories. It validates the
native config before starting and closes the command server before releasing
Java's TUN descriptor. The coexistence-only instrumentation checks the loader;
the separate VPN tests start the native session after Android consent.
Production core handoff, device network recovery and memory release still
require their own acceptance tests.

AndroidPlatform implements the pinned libbox platform callbacks: TUN/protect,
Android UID/package ownership, non-VPN network selection and change callbacks,
interface metadata, and raw Android DNS queries bound to the underlying network.
The coexistence-only smoke test enumerates real interfaces without creating a
VPN; the separate consented app-only runtime tests HTTPS and UDP DNS.
Optional root/SSH/bridge/neighbor features are unsupported.

Manual VPN experiment: open the diagnostic launcher, stop any existing VPN,
and press Authorize and start. The foreground service uses the isolated
AndroidVpnRuntime with the real platform callbacks and command server. Its
fixed config allows only the diagnostic package and routes HTTPS to
1.1.1.1/32 and DNS to 172.19.0.2/32 through TUN, with direct outbound and
local DNS hijacking. Stop from the launcher or foreground notification.
Inspect adb logcat -s FlClashVpnProbe for startup/cleanup. The manual HTTPS
and DNS probes still need physical-device acceptance; they do not test node
protocols. Android allows one active VPN per user, so consent can replace an
existing VPN.

Traffic validation: after startup, locate the Android VPN network with the
expected TUN address, bind a socket to that network, require the TUN source
address, and connect to 1.1.1.1:443. Verify the TLS hostname cloudflare-dns.com
with the platform trust store and require a valid HTTP response. No physical
network fallback is allowed. The launcher displays the result and logs retain
it; failure stops the diagnostic. On stop, check that the diagnostic VPN
network disappears. These are bounded one-shot checks, not periodic polling.
HTTPS alone establishes direct forwarding; the separate UDP DNS check must
also succeed. Neither proves node protocols, handover or production integration.

For handover validation, leave the diagnostic running, switch Wi-Fi/mobile data,
then press Retest traffic after network change. Retest uses the same VPN and
native session, not a restart or a physical-network fallback. A failed retest
leaves the VPN running so recovery can be tested. Repeated taps are coalesced;
pressing Retest when stopped never starts the VPN. The endpoint may be blocked
on some networks: an HTTPS failure alone is not a diagnosis of a core bug.

DNS validation now uses a local DNS server with caching disabled and an explicit
TUN DNS address 172.19.0.2. The probe binds UDP to the VPN, verifies the source
address, sends an example.com A query and checks transaction ID, question, DNS
status and an IPv4 answer. This exercises the local Android resolver through
libbox, not a fallback to a physical socket. HTTPS and DNS must both succeed.
Stop also checks that the Java TUN owner, command server and monitor references
are released; it does not prove that Go heap memory has been reclaimed or that
the process has exited. The service still runs only with explicit consent.

## Offline emulator TCP smoke test

The separate LocalVpnProbeService uses the typed AndroidVpnRuntime and routes
only this diagnostic package and a synthetic /32 through libbox to a local TCP
echo server. It requires VPN consent and verifies socket-protection callbacks.
The CI emulator grants consent in its disposable instance, runs isolation
instrumentation, and performs two complete VPN start/stop cycles. No internet
endpoint is required by this local test. This is not a production FlClash VPN
handover test or a replacement for physical-device checks.
