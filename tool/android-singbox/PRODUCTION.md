# Optional production Android runtime packaging

This change is stacked on the Android platform adapter PR (#53). The ordinary
FlClash build stays unchanged. To include the official pinned libbox AAR in the
production service module, supply an absolute AAR path and matching Flutter ABI:

    cd android
    ./gradlew :service:assembleDebug -Ptarget-platform=android-arm64 -PflclashSingBoxAar=/absolute/path/libbox.aar

For a full APK, export ORG_GRADLE_PROJECT_flclashSingBoxAar with the absolute
path and use Flutter's normal APK build and ABI option. Every requested ABI
must exist in the AAR. The generated libbox DEX is an asset, never a Gradle
Java dependency; the native library is a generated JNI source. The app's
existing package ID and signing settings are not changed.

The Android 10+ IsolatedSingBoxRuntime provides validated config preflight,
typed runtime creation, start/reset/close through the isolated loader.
It does not initialize the runtime just to display availability. It must be
called by the future dedicated VPN owner, not by the Flutter UI process.
No user-visible selector, automatic VPN handoff or production service is wired
by this packaging change. The diagnostic and emulator tests must still pass
before enabling production selection. Older Android versions retain Mihomo.

CI checks the real service AAR contains the expected isolated asset and native
library, that libbox classes do not enter the host classpath, and that a default
build does not include either runtime file.
