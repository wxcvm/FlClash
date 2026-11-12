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

The isolated adapter compiles against Android 35 (minimum runtime API 29),
independently of the production app compile SDK. Install platform android-35
alongside the normal app SDK before an optional build.

## Production service boundary

An optional manifest-enabled SingBoxVpnService now runs in :singbox, with a
private same-UID Binder protocol (SingBoxVpnControl). Configuration crosses as
a read-only file descriptor. Preflight, start, stop, reset and real running
state are serialized. The service never starts from system always-on intent;
existing Mihomo remains the default. The caller must bind, validate the profile,
stop the previous VPN, start the foreground service, and invoke start on a
background dispatcher. The notification can stop the remote owner. This is the
service endpoint, not yet a Flutter selector or integrated ServiceController
handoff; the UI must not advertise a working sing-box option until that wiring
and traffic validation are done. The Android process is eligible for OS reclaim
after stop/unbind; native Go heap unload is not asserted.
