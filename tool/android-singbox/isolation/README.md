# Android dual-runtime isolation experiment

Standalone ARM64 diagnostic APK, not production FlClash. It includes an
isolation instrumentation test and an opt-in, app-only VPN traffic test.
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

Android 10+ ARM64 required. Each build uses a fresh diagnostic signing key.
Uninstall only org.flclash.singboxprobe before installing a newer diagnostic APK.
Never uninstall production FlClash.

PASS requires actual Mihomo JNI calls before and after two successful libbox
calls in the same separate process. A bidirectional Binder pipe descriptor
transfer additionally checks real OS handle duplication and closure semantics,
not just integer serialization. This verifies runtime coexistence and
classloader isolation, not VPN traffic, actual TUN descriptor ownership, VpnService.protect, DNS,
engine switching or memory release.
The diagnostic has its own package ID and does not modify production FlClash.
The isolated DEX now includes AndroidTunBridge, compiled against the actual
pinned libbox API. It maps TUN addresses, computed routes, MTU, DNS and package
filters to VpnService.Builder, retains the original descriptor (libbox duplicates
it), and rejects a failed socket protect call. Its descriptor duplication smoke
check runs through the isolated loader. OpenTun/protect are not yet invoked by a
real VPN: the full PlatformInterface, consent and command-server lifecycle must
be connected before testing traffic. Close the bridge only after native service
stop; HTTP proxy options are explicitly rejected until supported.
LibboxVpnSession adds the typed command server setup/start/reset/stop path,
using a private Unix socket and app-private directories. It validates the
native config before starting and closes the command server before releasing
Java's TUN descriptor. It is compiled and classloader-checked by this probe,
not started by the current instrumentation. A complete PlatformInterface
implementation and VPN consent are still required.
Next: full platform callbacks, single VPN owner, rollback and device memory tests.

AndroidPlatform implements the pinned libbox platform callbacks: TUN/protect,
Android UID/package ownership, non-VPN network selection and change callbacks,
interface metadata, and raw Android DNS queries bound to the underlying network.
The smoke test enumerates real interfaces; it does not create a VPN or test
DNS traffic. Optional root/SSH/bridge/neighbor features are unsupported.

Manual VPN experiment: open the diagnostic launcher, stop any existing VPN,
and press Authorize and start. The foreground service uses the isolated
AndroidVpnRuntime with the real platform callbacks and command server. Its
fixed config allows only the diagnostic package and a single IPv4 test route
(1.1.1.1/32), with direct outbound and DNS takeover disabled. Stop from the
launcher or foreground notification. Inspect adb logcat -s FlClashVpnProbe
for startup/cleanup. The diagnostic now checks real HTTPS through the VPN, but has not yet been
executed on a device. It does not verify proxy protocols or DNS yet. Android allows
one active VPN per user, so consent can replace an existing VPN.

Traffic validation: after startup, locate the Android VPN network with the
expected TUN address, bind a socket to that network, require the TUN source
address, and connect to 1.1.1.1:443. Verify the TLS hostname cloudflare-dns.com
with the platform trust store and require a valid HTTP response. No physical
network fallback is allowed. The launcher displays the result and logs retain
it; failure stops the diagnostic. On stop, check that the diagnostic VPN
network disappears. These are bounded one-shot checks, not periodic polling.
A successful HTTPS result is evidence of direct forwarding, not DNS, node
protocols, handover or production integration.

For handover validation, leave the diagnostic running, switch Wi-Fi/mobile data,
then press Retest traffic after network change. Retest uses the same VPN and
native session, not a restart or a physical-network fallback. A failed retest
leaves the VPN running so recovery can be tested. Repeated taps are coalesced;
pressing Retest when stopped never starts the VPN. The endpoint may be blocked
on some networks: an HTTPS failure alone is not a diagnosis of a core bug.
