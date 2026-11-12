#!/usr/bin/env bash
set -euo pipefail
PACKAGE=org.flclash.singboxprobe
mkdir -p probe-results
cleanup() {
  adb logcat -d > probe-results/logcat.txt || true
  adb shell am force-stop "$PACKAGE" || true
}
trap cleanup EXIT
adb install "${1:?diagnostic APK required}"
# This is a disposable emulator only, not a permission bypass on a user device.
adb shell cmd appops set "$PACKAGE" ACTIVATE_VPN allow
run_probe() {
  local klass="$1" expected="$2"
  timeout 120 adb shell am instrument -w -r "$PACKAGE/.$klass" | tee "probe-results/$klass.txt"
  grep -F "$expected" "probe-results/$klass.txt"
  grep -F 'INSTRUMENTATION_CODE: -1' "probe-results/$klass.txt"
}
run_probe ProbeInstrumentation 'PASS: real Mihomo + isolated libbox'
run_probe VpnProbeInstrumentation 'PASS: real sing-box TUN, local TCP echo'
# A second full start/stop catches stale descriptors and cached JNI state.
run_probe VpnProbeInstrumentation 'PASS: real sing-box TUN, local TCP echo'
