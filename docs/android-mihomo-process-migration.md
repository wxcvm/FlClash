# Android Mihomo process migration — stage 1

The production VPN, Flutter core channel and quick settings remain unchanged.
Mihomo currently also handles stopped-state profile parsing, DNS observation,
provider updates and delay tests; moving the VPN service alone would create two
independent Go states. This opt-in debug probe establishes a real isolated JNI
boundary first, using the existing libclash.so and Core API in :mihomo_probe.

Build from android with the normal Flutter/Go/NDK toolchain:

    ./gradlew :app:assembleDebug :app:assembleDebugAndroidTest \
      -Ptarget-platform=android-arm64 -PflclashMihomoProcessProbe=true

Install the matching debug app and test APK, then:

    adb shell am instrument -w com.follow.clash.dev.test/com.follow.clash.MihomoProcessProbeInstrumentation

The runner checks actual core.initialized and core.memory RPC responses, two
separate native PIDs, and Binder death on close. The service is non-exported,
same-UID, bound-only, debug opt-in; only diagnostic commands, log subscription and the fixed private setup fixture
are allowed. Requests and responses use bounded regular-file descriptors, not
large Binder payloads. The probe never starts a tunnel or proxy listener; quickSetup uses a generated
configuration with all listener ports disabled.
Run only when the production app is stopped to avoid extra Go memory.

Next: move the real core command/event transport and quickSetup to a shared
Mihomo process, then relocate VPN/Proxy service ownership and ServiceConfig,
network observation, notification/pressure handling and always-on startup.
Only after those paths are verified can the UI stop loading JNI. This probe
does not yet reduce normal app memory or switch production ownership.

Stage 2 adds one-way descriptor-backed callbacks for actual Core RPC responses,
quickSetup and native events. Only diagnostics, log subscription and a fixed
listener-free private fixture are exposed in the debug probe. The device test
now initializes the isolated Go state and checks core.initialized after setup.
Production Flutter and VPN callers are still not switched to this transport.

Stage 3 moves the production VPN and Proxy lifecycle to an explicit private
MihomoServiceControl Binder action (start/stop, mode guard, handoff permission,
notification settings and PID). Start options use the same bounded descriptor
transport, and live notification changes are forwarded under the service lock.
The existing Android VPN system bind is unchanged. The device test also binds
the real ProxyService and checks mode rejection and notification transfer without
starting native listeners. Production services still run in the app process;
Core RPC, network observer, listener ownership and services must move together
before enabling a dedicated production process.
