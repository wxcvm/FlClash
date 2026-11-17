#!/usr/bin/env python3
"""Adapt only the CI checkout to sing-box 1.15's added platform callbacks.

The stable 1.14.4 AndroidPlatform is left unchanged; alpha-only interface
types are absent from 1.14.4 and must not leak into the production adapter.
"""
from pathlib import Path

source = Path(
    "tool/android-singbox/isolation/libbox-src/org/flclash/"
    "singboxprobe/isolated/AndroidPlatform.java"
)
content = source.read_text()
anchor = "    /** Enumerate real Android interfaces and exercise the generated iterator API without VPN consent. */"
if content.count(anchor) != 1 or "usePlatformAutoRedirect()" in content:
    raise SystemExit("Unexpected Android adapter source; inspect API before updating")

# Android's VpnService already owns the TUN. sing-box auto_redirect is a
# separate Linux-only policy-routing path; never claim it is implemented.
extension = """    @Override public boolean usePlatformAutoRedirect() { return false; }
    @Override public AutoRedirectSession createAutoRedirect(
            byte[] options, AutoRedirectHandler handler) throws Exception {
        throw unsupported("platform auto redirect");
    }

"""
source.write_text(content.replace(anchor, extension + anchor, 1))
print("Applied 1.15-only Android PlatformInterface extension in CI checkout")
