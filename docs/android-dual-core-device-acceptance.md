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

The default fixture routes only the debug package's traffic to 1.1.1.1 through
DIRECT and verifies TLS for cloudflare-dns.com. Native DNS queries go through
the TUN to 172.19.0.2 and are resolved by the Android local transport; a DNS A
response and transaction ID are checked. It does not test a subscription,
Mihomo DNS, or every destination. No root or production subscription
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

## Remote outbound and sustained connectivity

Optional: export **one** sing-box outbound JSON object (not a full profile),
with its type, server, server_port and protocol-specific settings. For VLESS
REALITY use the actual UUID, flow, TLS/reality and uTLS settings from your node.
Do not send credentials to GitHub or put them in command-line arguments.

    python tool/android-singbox/device_acceptance.py --confirm-debug --native-outbound ./node.json --handover --soak-seconds 120

The script streams the file into the debug app's private cache using adb run-as,
not /sdcard. The generated native fixture replaces the sole outbound and makes
it the final route; no direct fallback or selector is present. The local Android
DNS transport is explicitly selected for bootstrap and the DNS test, **not**
proxy DNS. The host and test remove their temporary files on completion; after
an interrupted test, check the debug app's private cache and stop its VPN.
Local Android logs may contain endpoint details; review before sharing.
The Mihomo phases remain DIRECT baseline checks. Proxy success requires real
TLS/HTTP through the specified native outbound; this is not proof of all
protocol variants, all destinations, or the remote public egress IP. The optional
soak checks actual DNS and HTTPS repeatedly for up to 120 seconds, not a battery
or long-duration reliability benchmark.

### Long-lived Mihomo VPN (system HTTP proxy disabled)

With the same consented debug setup, run:

    python tool/android-singbox/device_acceptance.py --confirm-debug --mihomo-soak-seconds 1800

The optional Mihomo phase supports up to 3600 seconds without restarting the VPN
or switching cores. Every 30 seconds it records virtual DNS, fixed-IP TLS,
domain-resolved TLS, elapsed time and process memory samples. It reports each
sample immediately, so the log retains earlier measurements if a later probe
fails. This uses a DIRECT baseline, not the user's subscription or a throughput
benchmark; repeat on a stable Wi-Fi or mobile connection and compare with the
normal app when diagnosing a specific proxy node. Stop the production VPN
before the debug acceptance run; see the existing device preparation above.
