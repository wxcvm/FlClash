#!/usr/bin/env bash
set -euo pipefail
# Build a standalone, debug-signed ARM64 instrumentation APK. No production APK changes.
ROOT="$(cd "$(dirname "$0")" && pwd)"
AAR="$(realpath "${1:?usage: build.sh libbox.aar output-directory patched-mihomo.jar mihomo.aar}")"
mkdir -p "${2:?output directory required}"
OUT="$(realpath "$2")"
MIHOMO_JAR="$(realpath "${3:?patched Mihomo classes.jar required}")"
MIHOMO_AAR="$(realpath "${4:?Mihomo core.aar required}")"
SDK="${ANDROID_HOME:?ANDROID_HOME required}"
TOOLS="$(find "$SDK/build-tools" -mindepth 1 -maxdepth 1 -type d | sort -V | tail -1)"
PLATFORM="$SDK/platforms/android-35/android.jar"
test -f "$PLATFORM"
for tool in aapt2 d8 zipalign apksigner; do test -x "$TOOLS/$tool"; done
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/dns-test"
javac --release 8 -d "$WORK/dns-test" "$ROOT/src/org/flclash/singboxprobe/ProbeDnsMessage.java" "$ROOT/tests/ProbeDnsMessageTest.java"
java -cp "$WORK/dns-test" org.flclash.singboxprobe.ProbeDnsMessageTest
mkdir -p "$WORK/host" "$WORK/dex" "$WORK/libbox" "$WORK/libbox-adapter"
unzip -p "$AAR" classes.jar > "$WORK/libbox.jar"
unzip -p "$AAR" jni/arm64-v8a/libbox.so > "$WORK/libbox.so"
unzip -p "$MIHOMO_AAR" jni/arm64-v8a/libgojni.so > "$WORK/libclash.so"
test -s "$WORK/libclash.so"
javac --release 8 -cp "$PLATFORM:$MIHOMO_JAR" -d "$WORK/host" $(find "$ROOT/src" -name '*.java')
jar cf "$WORK/host.jar" -C "$WORK/host" .
"$TOOLS/d8" --min-api 29 --lib "$PLATFORM" --output "$WORK/dex" "$WORK/host.jar" "$MIHOMO_JAR"
javac --release 8 -cp "$PLATFORM:$WORK/libbox.jar" -d "$WORK/libbox-adapter" $(find "$ROOT/libbox-src" -name '*.java')
jar cf "$WORK/libbox-adapter.jar" -C "$WORK/libbox-adapter" .
"$TOOLS/d8" --min-api 29 --lib "$PLATFORM" --output "$WORK/libbox" "$WORK/libbox.jar" "$WORK/libbox-adapter.jar"
test "$(find "$WORK/dex" -name 'classes*.dex' | wc -l)" -eq 1
test "$(find "$WORK/libbox" -name 'classes*.dex' | wc -l)" -eq 1
"$TOOLS/aapt2" link -I "$PLATFORM" --manifest "$ROOT/AndroidManifest.xml" -o "$WORK/base.apk"
python3 - "$WORK" <<'PY'
import pathlib, sys, zipfile
w = pathlib.Path(sys.argv[1])
with zipfile.ZipFile(w / 'base.apk', 'a', compression=zipfile.ZIP_DEFLATED) as apk:
    apk.write(w / 'dex/classes.dex', 'classes.dex')
    apk.write(w / 'libbox/classes.dex', 'assets/libbox.dex')
    apk.write(w / 'libbox.so', 'lib/arm64-v8a/libbox.so')
    apk.write(w / 'libclash.so', 'lib/arm64-v8a/libclash.so')
PY
"$TOOLS/zipalign" -P 16 -f 4 "$WORK/base.apk" "$WORK/aligned.apk"
keytool -genkeypair -keystore "$WORK/probe.jks" -storepass android -keypass android \
    -alias probe -keyalg RSA -keysize 2048 -validity 30 -dname 'CN=Local probe' >/dev/null 2>&1
"$TOOLS/apksigner" sign --ks "$WORK/probe.jks" --ks-pass pass:android \
    --key-pass pass:android --out "$OUT/singbox-isolation-probe.apk" "$WORK/aligned.apk"
"$TOOLS/apksigner" verify "$OUT/singbox-isolation-probe.apk"
