# Android dual-core live acceptance (ARM64 Debug)

Use the matching `app.apk` and `test.apk` from the **mihomo-process-device-test**
artifact. The separate package is `com.follow.clash.dev`. This is a real VPN
test, not an emulator or a dry run. Do not run it while depending on a VPN.

1. Install both APKs using `adb install -r app.apk` and `adb install -r test.apk`.
   Open FlClash Debug, grant Android VPN permission and notification permission,
   then stop its VPN. Stop any other VPN. Disable always-on/lockdown manually
   for this test (the script will refuse to change it).
2. Enable USB debugging and check `adb devices`. Run:
   
       python tool/android-singbox/device_acceptance.py --confirm-debug

   Add `--serial SERIAL` when multiple devices are connected.
3. Optional network recovery test:
   
       python tool/android-singbox/device_acceptance.py --confirm-debug --handover

   At the printed checkpoint, change Wi-Fi to mobile data or vice versa yourself.
   Internet must return within 60 seconds. The test checks the actual native
   network generation and HTTPS; it does not toggle radios or reset the VPN.
4. Inspect `dual-core-acceptance.json` and its companion log. The runner fails
   unless the instrumentation explicitly passes, all phases are present, and
   the requested handover is recorded. Each phase reports PID and PSS (KiB).
   Android can cache same-UID PSS samples; compare medians cautiously.
   The test does not measure battery drain or compare against a matched
   non-isolated APK. Use a separate controlled test for that.

The fixture routes only the debug package's traffic to 1.1.1.1 through DIRECT
and verifies TLS for cloudflare-dns.com; it does not test a subscription,
proxy protocol, DNS, or every destination. No root or production subscription
is needed. Do not use the production app package. If the debug app fails
mid-test, stop it manually and verify Android VPN settings before reconnecting.

## Always-on separate acceptance

With the debug app stopped, select FlClash Debug as always-on (lockdown off),
reboot, and check that Mihomo initializes from saved real profile and forwards
traffic before opening Flutter. Try switching to sing-box: it must refuse
without taking down Mihomo. Repeat with lockdown enabled only on a spare test
device; confirm no bypass. Disable always-on afterwards. This manual check is
not part of the live fixture; the isolated layout stays opt-in until it passes.

The system start broadcast now uses a dedicated saved-profile recovery path:
no quick-settings tile or Flutter permission dialog, Mihomo VPN mode even if
saved options describe proxy-only mode, early foreground notification, and a
bounded startup timeout. Native handoff queries the actual Android VPN service
for always-on/lockdown even when the UI has no active runtime. The new tests
cover state-machine logic only; reboot and lockdown forwarding still require
the manual device checks above.
