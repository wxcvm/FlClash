# Android dual-runtime isolation experiment

Standalone ARM64 diagnostic APK, not FlClash and not a VPN.
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
Next: full platform callbacks, single VPN owner, rollback and device memory tests.
