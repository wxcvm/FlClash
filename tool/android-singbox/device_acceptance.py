#!/usr/bin/env python3
"""Run explicit live VPN acceptance on a consented ARM64 debug device."""
import argparse
import json
import pathlib
import re
import statistics
import subprocess
import sys

PACKAGE = "com.follow.clash.dev"
RUNNER = PACKAGE + ".test/com.follow.clash.MihomoProcessProbeInstrumentation"
EXPECTED = ["mihomo-initial", "singbox-1", "mihomo-restored-1",
            "singbox-2", "mihomo-restored-2", "stopped"]
OPTIONAL_PHASES = {"singbox-network-handover", "singbox-soak"}
OUTBOUND_TYPES = {"vless", "vmess", "trojan", "shadowsocks", "hysteria2",
                  "tuic", "socks", "http", "anytls"}
STAGED = "cache/native-acceptance-outbound.json"
GENERATED = "cache/dual-core-acceptance/singbox.json"


def load_outbound(path):
    raw = pathlib.Path(path).read_bytes()
    if not 0 < len(raw) <= 256 * 1024:
        raise ValueError("outbound must be a JSON object no larger than 256 KiB")
    try:
        value = json.loads(raw)
    except (ValueError, UnicodeError):
        raise ValueError("invalid outbound JSON") from None
    if not isinstance(value, dict) or not isinstance(value.get("type"), str) or value["type"] not in OUTBOUND_TYPES:
        raise ValueError("provide a single supported remote outbound, not a subscription or group")
    if not isinstance(value.get("server"), str) or not value["server"].strip():
        raise ValueError("outbound needs a remote server")
    port = value.get("server_port")
    if type(port) is not int or not 1 <= port <= 65535:
        raise ValueError("outbound needs a valid server_port")
    if "detour" in value or "outbounds" in value:
        raise ValueError("chained and group outbounds are not supported")
    return raw


def measured(value):
    return type(value) in (int, float) and 0 <= value < float("inf")


def summarize(report, *, proxy=False, handover=False, soak_seconds=0):
    phases = [p["phase"] for p in report]
    if [p for p in phases if p not in OPTIONAL_PHASES] != EXPECTED:
        raise ValueError("missing or unexpected acceptance phases: " + repr(phases))
    if len(set(phases)) != len(phases):
        raise ValueError("duplicate acceptance phase")
    if ("singbox-network-handover" in phases) != handover:
        raise ValueError("unexpected or missing network handover")
    if ("singbox-soak" in phases) != (soak_seconds > 0):
        raise ValueError("unexpected or missing soak")
    output = []
    for phase in report:
        name = phase["phase"]
        if name in EXPECTED[:-1] and not measured(phase.get("tlsMs")):
            raise ValueError("missing HTTPS measurement")
        if name in ("singbox-1", "singbox-2"):
            if phase.get("egress") != ("proxy" if proxy else "direct"):
                raise ValueError("wrong native egress mode")
            if not measured(phase.get("dnsMs")):
                raise ValueError("missing native DNS measurement")
        if name == "singbox-network-handover":
            if phase.get("beforeGeneration") == phase.get("afterGeneration") or not isinstance(phase.get("dnsMs"), (int, float)) or phase["dnsMs"] < 0:
                raise ValueError("missing DNS or network-generation recovery")
        if name == "singbox-soak":
            checks = phase.get("checks", [])
            if phase.get("durationSeconds") != soak_seconds or len(checks) < 2 or any(
                any(not measured(check.get(key)) for key in ("tlsMs", "dnsMs"))
                for check in checks
            ):
                raise ValueError("incomplete soak measurements")
        samples = phase.get("samples", [])
        totals = [sum(p["pssKiB"] for p in sample) for sample in samples]
        if phase["phase"] in EXPECTED[:-1] and len(samples) != 3:
            raise ValueError("missing PSS samples for " + phase["phase"])
        if samples and any(not sample or any(p["pssKiB"] <= 0 for p in sample) for sample in samples):
            raise ValueError("invalid or unavailable PSS sample in " + phase["phase"])
        output.append({"phase": phase["phase"], "tlsMs": phase.get("tlsMs"),
                       "dnsMs": phase.get("dnsMs"), "egress": phase.get("egress"),
                       "medianTotalPssKiB": statistics.median(totals) if totals else None,
                       "samples": samples})
    return output


def parse_result(output):
    if not re.search(r"(?m)^INSTRUMENTATION_CODE: -1\s*$", output):
        raise ValueError("instrumentation did not report success")
    if "PASS: live dual-core VPN acceptance" not in output:
        raise ValueError("missing live acceptance success marker")
    matches = re.findall(r"(?m)^INSTRUMENTATION_RESULT: acceptanceJson=(.+)$", output)
    if len(matches) != 1:
        raise ValueError("missing acceptance JSON")
    return json.loads(matches[0])


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--serial", help="ADB device serial")
    parser.add_argument("--adb", default="adb")
    parser.add_argument("--handover", action="store_true",
                        help="manually change Wi-Fi/mobile data at the checkpoint")
    parser.add_argument("--native-outbound", metavar="JSON_FILE",
                        help="local single sing-box remote outbound; never passed as a command argument")
    parser.add_argument("--soak-seconds", type=int, default=0, metavar="0..120",
                        help="repeat HTTPS and DNS during the first native phase")
    parser.add_argument("--output", default="dual-core-acceptance.json")
    parser.add_argument("--confirm-debug", action="store_true",
                        help="confirm Debug app is consented, stopped, and other VPNs are off")
    args = parser.parse_args()
    if not args.confirm_debug:
        parser.error("read the device guide, then pass --confirm-debug")
    if not 0 <= args.soak_seconds <= 120:
        parser.error("--soak-seconds must be between 0 and 120")
    try:
        outbound = load_outbound(args.native_outbound) if args.native_outbound else None
    except (OSError, ValueError) as exc:
        parser.error(str(exc))
    adb = [args.adb] + (["-s", args.serial] if args.serial else [])
    def shell(*cmd):
        return subprocess.check_output(adb + ["shell", *cmd], text=True).strip()
    if "arm64-v8a" not in shell("getprop", "ro.product.cpu.abilist").split(","):
        parser.error("ARM64 Android device required")
    if not shell("pm", "path", PACKAGE).startswith("package:") or not shell("pm", "path", PACKAGE + ".test").startswith("package:"):
        parser.error("install the matching Debug app.apk and test.apk")
    always_on = shell("settings", "get", "secure", "always_on_vpn_app")
    lockdown = shell("settings", "get", "secure", "always_on_vpn_lockdown")
    if always_on not in ("", "null") or lockdown == "1":
        parser.error("always-on/lockdown VPN is configured; disable manually before this test")
    cmd = adb + ["shell", "am", "instrument", "-w", "-e", "liveVpn", "true"]
    if args.handover:
        cmd += ["-e", "handover", "true"]
    if outbound is not None:
        cmd += ["-e", "nativeProxy", "true"]
    if args.soak_seconds:
        cmd += ["-e", "soakSeconds", str(args.soak_seconds)]
    cmd += [RUNNER]
    lines = []
    try:
        if outbound is not None:
            # stdin only; no secret in the command line or public /sdcard.
            # tee's echoed bytes must not reach the console or test log.
            subprocess.run(adb + ["shell", "-T", "run-as", PACKAGE, "tee", STAGED],
                           input=outbound, stdout=subprocess.DEVNULL,
                           stderr=subprocess.DEVNULL, check=True)
        with subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                              text=True, bufsize=1) as proc:
            for line in proc.stdout:
                lines.append(line)
                print(line, end="", flush=True)
            code = proc.wait()
    finally:
        if outbound is not None:
            subprocess.run(adb + ["shell", "run-as", PACKAGE, "rm", "-f", STAGED, GENERATED],
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=False)
    log = "".join(lines)
    output = pathlib.Path(args.output)
    output.parent.mkdir(parents=True, exist_ok=True)
    output.with_suffix(".log").write_text(log, encoding="utf-8")
    try:
        if code:
            raise ValueError("ADB failed with exit code " + str(code))
        report = parse_result(log)
        summary = summarize(report, proxy=outbound is not None,
                            handover=args.handover, soak_seconds=args.soak_seconds)
    except (ValueError, KeyError, TypeError) as exc:
        print("FAIL:", exc, file=sys.stderr)
        return 1
    output.write_text(json.dumps({"device": shell("getprop", "ro.product.model"),
                                 "android": shell("getprop", "ro.build.version.release"),
                                 "phases": report, "summary": summary},
                                 indent=2, ensure_ascii=False), encoding="utf-8")
    print("PASS: report saved to", output)
    return 0


if __name__ == "__main__":
    sys.exit(main())
