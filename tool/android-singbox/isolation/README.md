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
Next: libbox platform callbacks, single VPN owner, rollback and device memory tests.

## Optional real VPN smoke test

This requires Android VPN consent and temporarily replaces any existing VPN on
the test device (including FlClash or AdGuard). Use a spare device/emulator or
stop the other VPN first. The diagnostic VPN routes only this APK and only
198.18.0.9/32; no internet server or user proxy configuration is used.

    adb shell am start -n org.flclash.singboxprobe/.VpnConsentActivity
    # Confirm the Android VPN prompt, then:
    adb shell am instrument -w org.flclash.singboxprobe/.VpnProbeInstrumentation

The host opens a local echo server and connects to the synthetic destination.
The isolated libbox runtime opens a real Android TUN, rewrites the destination
to the loopback server, and must return the challenge response. The test also
requires a successful native socket-protection callback and stops the tunnel
on exit. A successful build alone does not establish that the test passes.
This narrow IPv4 probe does not validate arbitrary profiles, DNS, IPv6,
physical network changes, production VPN handoff or memory/power behavior.
