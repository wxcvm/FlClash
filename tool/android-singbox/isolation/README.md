# Android libbox isolation experiment

This is a standalone ARM64 diagnostic APK, not FlClash, and not a VPN.
It deliberately packages a host go.Seq sentinel and keeps the official libbox
Java classes in a separate in-memory DEX. A private :singbox process loads
the DEX with the platform classloader as parent and the APK native library
directory as search path. A Binder transaction checks the actual upstream JNI
version and rejects malformed JSON, with the caller verifying a different PID.

Build using the official libbox.aar from the previous library probe:

    bash tool/android-singbox/isolation/build.sh libbox.aar out

Run on an Android 10+ ARM64 device:

    adb install -r out/singbox-isolation-probe.apk
    adb shell am instrument -w org.flclash.singboxprobe/.ProbeInstrumentation

PASS means the child classloader and libbox JNI initialization worked and the
Binder round-trip reached a separate process. It does not verify simultaneous
real Mihomo and sing-box JNI libraries, VPN traffic, DNS, or engine switching.
The host sentinel is intentionally not a Mihomo substitute for that test.
The probe has its own package ID and does not replace or modify FlClash.

Next, validate with real Mihomo in the host, then bind actual libbox platform
callbacks and VPN ownership to the engine service. A stopped Go runtime may
retain memory while its process is cached; process termination must be managed
explicitly in the production lifecycle.
