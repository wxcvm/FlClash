#!/usr/bin/env python3
"""Measure a real, full HTTP download through an explicitly chosen route."""
import argparse
import json
import os
import statistics
import subprocess
import sys
import time


def measure(url, proxy, timeout, expected_bytes):
    # Explicit proxy settings avoid silently inheriting a stale environment proxy.
    cmd = ["curl", "--disable", "--silent", "--fail", "--output", os.devnull,
           "--max-time", str(timeout), "--connect-timeout", "10",
           "--proxy", proxy or "", "--noproxy", "" if proxy else "*",
           "--header", "Accept-Encoding: identity", "--header", "Cache-Control: no-cache",
           "--write-out", "%{http_code} %{size_download} %{time_connect} %{time_starttransfer} %{time_total}",
           "--url", url]
    try:
        proc = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout + 5)
        status, size, connect, first, total = proc.stdout.strip().split()
        status, size = int(status), int(float(size))
        connect, first, total = map(float, (connect, first, total))
        ok = proc.returncode == 0 and status == 200 and size == expected_bytes and total > 0
        return {"ok": ok, "curl_exit": proc.returncode, "http_status": status,
                "bytes": size, "connect_s": connect, "first_byte_s": first,
                "total_s": total, "bytes_per_second": size / total if ok else None,
                "body_bytes_per_second": size / (total - first) if ok and total > first else None}
    except subprocess.TimeoutExpired:
        return {"ok": False, "error": "process timeout"}
    except (ValueError, OSError):
        return {"ok": False, "error": "curl unavailable or invalid measurement"}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--url", required=True, help="HTTP(S) URL of the same fixed test file")
    parser.add_argument("--bytes", required=True, type=int, help="exact expected file size in bytes")
    parser.add_argument("--label", required=True, help="client/core/path label; do not include credentials")
    route = parser.add_mutually_exclusive_group(required=True)
    route.add_argument("--proxy", help="explicit HTTP or SOCKS proxy URL")
    route.add_argument("--os-route", action="store_true", help="use the OS route, including an active VPN/TUN")
    parser.add_argument("--runs", type=int, default=3)
    parser.add_argument("--timeout", type=int, default=90)
    args = parser.parse_args()
    if args.bytes <= 0 or args.runs <= 0 or args.timeout <= 0:
        parser.error("bytes, runs and timeout must be positive")
    samples = []
    for index in range(args.runs):
        samples.append(measure(args.url, args.proxy, args.timeout, args.bytes))
        if index + 1 < args.runs:
            time.sleep(1)
    rates = [s["bytes_per_second"] for s in samples if s["ok"]]
    print(json.dumps({"label": args.label, "route": "explicit-proxy" if args.proxy else "os-route",
                      "expected_bytes": args.bytes, "runs": len(samples), "successes": len(rates),
                      "failures": len(samples) - len(rates),
                      "median_bytes_per_second": statistics.median(rates) if rates else None,
                      "min_bytes_per_second": min(rates) if rates else None, "samples": samples}, indent=2))
    return 0 if len(rates) == len(samples) else 1


if __name__ == "__main__":
    sys.exit(main())
