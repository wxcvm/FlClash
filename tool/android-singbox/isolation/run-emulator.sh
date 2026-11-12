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

run_probe() {
  local klass="$1" expected="$2"
  timeout 120 adb shell am instrument -w -r "$PACKAGE/.$klass" | tee "probe-results/$klass.txt"
  grep -F "$expected" "probe-results/$klass.txt"
  grep -F 'INSTRUMENTATION_CODE: -1' "probe-results/$klass.txt"
}
run_probe ProbeInstrumentation 'PASS: real Mihomo + isolated libbox'
# Grant consent via the actual Android system dialog on this disposable emulator.
adb shell am start -W -n "$PACKAGE/.VpnConsentActivity"
adb shell uiautomator dump /sdcard/vpn-consent.xml >/dev/null
adb pull /sdcard/vpn-consent.xml probe-results/vpn-consent.xml >/dev/null
python3 - probe-results/vpn-consent.xml <<'PY'
import re, sys, subprocess, xml.etree.ElementTree as ET
root = ET.parse(sys.argv[1])
for node in root.iter('node'):
    if node.get('resource-id') in ('android:id/button1', 'com.android.vpndialogs:id/button1'):
        bounds = list(map(int, re.findall(r'\d+', node.get('bounds', ''))))
        if len(bounds) == 4:
            subprocess.run(['adb', 'shell', 'input', 'tap', str((bounds[0]+bounds[2])//2), str((bounds[1]+bounds[3])//2)], check=True)
            break
else:
    print('No consent button visible; instrumentation will verify permission')
PY
adb shell am wait-for-broadcast-idle
run_probe VpnProbeInstrumentation 'PASS: real sing-box TUN, local TCP echo'
# A second full start/stop catches stale descriptors and cached JNI state.
run_probe VpnProbeInstrumentation 'PASS: real sing-box TUN, local TCP echo'
