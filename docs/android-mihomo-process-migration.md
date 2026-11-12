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

Stage 4: the debug-only `-PflclashMihomoIsolated=true` manifest overlay moves
MihomoCoreService, VpnService and ProxyService into :mihomo. The actual Flutter
Core channel and ServiceController QuickSetup/listener calls use MihomoCoreControl;
NetworkObserver starts in the Core owner process. Default/release manifests
retain the original process placement. CI builds both the normal optional APK
and an isolated dual-core debug APK plus instrumentation, checking the merged
manifest. Device instrumentation checks real Core RPC/setup and equal Core/VPN/
Proxy PIDs (different from the UI PID), without establishing a VPN. The shared
Core process remains connected for stopped-state profile operations; full exit
on switching to sing-box, always-on recovery, traffic and measured PSS still
require runtime validation and additional lifecycle work.

Stage 5: explicit sing-box handoff closes Mihomo admission, stops the old service,
retires the isolated :mihomo owner and waits for Binder death before native start.
Mihomo RPCs return core_unavailable during native ownership; event subscription
is retained without starting Core. Switching back reloads the latest synchronized
SetupParams (including selected-map) and reattaches events; stopped-state access
reinitializes Core without opening listeners. The core management screen exposes
an explicit switch-back action. Device instrumentation now checks production Core
retirement and a new PID on restart. Actual traffic, Android always-on, background
polling UX, and memory/power measurement are still acceptance items.

Stage 6: Android home selects the native dashboard when sing-box owns the VPN or
retirement/cleanup is pending. The old Mihomo page tree is unmounted. Core RPCs
are short-circuited before Flutter sends them, and the Mihomo traffic ticker,
auto-speed tests and scheduled setup jobs pause. The native home samples only
libbox CommandStatus after each four-second foreground interval, disconnecting
the command client after every bounded read; background/covered pages do not
poll, and full node/log snapshots remain on demand. Stale status and session
responses are discarded. Explicit stop/switch-back restores the ordinary home;
no automatic change of the original dashboard customization is saved. Flutter
service tests cover ownership, concurrent replies and the status-only command.
