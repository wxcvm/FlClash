# Optional Android sing-box payload

The production app still runs Mihomo. This opt-in development build packages
the pinned official sing-box v1.14.4 ARM64 AAR as an isolated DEX asset and
native library, not as a dependency in the main app classpath.

Requires Android SDK platform 35, build-tools 35.0.0, JDK 17, the normal
Flutter/Go/NDK project toolchain and the verified official libbox artifact.

From the Android directory:

    ./gradlew :app:assembleDebug -Ptarget-platform=android-arm64 \
      -PflclashSingBoxAar=/absolute/path/libbox.aar \
      -PflclashSingBoxSha256=<sha256-from-verified-build>

On Windows use gradlew.bat and quote absolute paths. The SHA-256 must match
the AAR; the caller supplies the digest from the official build result.
Without the opt-in property, normal Android builds contain no libbox
payload. Other ABIs are intentionally not supported by this option.

The APK has assets/libbox.dex and lib/arm64-v8a/libbox.so alongside Mihomo.
The DEX includes the same Android platform/TUN/session adapter sources as
the diagnostic APK. The shared IsolatedLibbox loader checks availability
without initializing Go, then isolates the Go bridge and verifies the
version before native config preflight. Do not load it in the UI process:
the bound-only SingBoxPreflightService in :singbox now owns config validation.
The preflight client transfers a file descriptor instead of a large Binder string,
waits for binding off the UI thread and unbinds after validation. The service is
non-exported, rejects foreign UIDs and never creates a VPN. No production
selection, VPN startup, automatic fallback, or guaranteed process exit is enabled by
this packaging change. The debug APK uses the existing .dev application ID;
it is not a release or an update for the signed production app.

CI builds the opt-in development APK and checks the ZIP entries. Device
tests are still required for JNI loading, startup and forwarding.
