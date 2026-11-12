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


def summarize(report):
    phases = [p["phase"] for p in report]
    if [p for p in phases if p != "singbox-network-handover"] != EXPECTED:
        raise ValueError("missing or unexpected acceptance phases: " + repr(phases))
    output = []
    for phase in report:
        samples = phase.get("samples", [])
        totals = [sum(p["pssKiB"] for p in sample) for sample in samples]
        if phase["phase"] in EXPECTED[:-1] and len(samples) != 3:
            raise ValueError("missing PSS samples for " + phase["phase"])
        if samples and any(not sample or any(p["pssKiB"] <= 0 for p in sample) for sample in samples):
            raise ValueError("invalid or unavailable PSS sample in " + phase["phase"])
        output.append({"phase": phase["phase"], "tlsMs": phase.get("tlsMs"),
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
    parser.add_argument("--output", default="dual-core-acceptance.json")
    parser.add_argument("--confirm-debug", action="store_true",
                        help="confirm Debug app is consented, stopped, and other VPNs are off")
    args = parser.parse_args()
    if not args.confirm_debug:
        parser.error("read the device guide, then pass --confirm-debug")
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
    cmd += [RUNNER]
    lines = []
    with subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                          text=True, bufsize=1) as proc:
        for line in proc.stdout:
            lines.append(line)
            print(line, end="", flush=True)
        code = proc.wait()
    log = "".join(lines)
    output = pathlib.Path(args.output)
    output.parent.mkdir(parents=True, exist_ok=True)
    output.with_suffix(".log").write_text(log, encoding="utf-8")
    try:
        if code:
            raise ValueError("ADB failed with exit code " + str(code))
        report = parse_result(log)
        if args.handover and not any(p["phase"] == "singbox-network-handover" for p in report):
            raise ValueError("missing handover checkpoint result")
        summary = summarize(report)
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
