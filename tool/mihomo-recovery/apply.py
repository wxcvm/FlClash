#!/usr/bin/env python3
"""Apply reviewed changes to FlClash's pinned Mihomo submodule."""
import json
from pathlib import Path
import shutil
import subprocess
import sys

root = Path(sys.argv[1]).resolve()
here = Path(__file__).resolve().parent
if subprocess.check_output(["git", "-C", str(root), "rev-parse", "HEAD"], text=True).strip() != "024245dc72bc92f48237f865119afe0cd53ac9e6":
    raise SystemExit("Unreviewed Mihomo revision")
group = root / "adapter/outboundgroup"
changes = json.loads((here / "changes.json").read_text())
updated = {}
for name, replacements in changes.items():
    path = group / name
    text = path.read_text()
    for old, new in replacements:
        if text.count(old) != 1:
            raise SystemExit("Mihomo source changed: " + name)
        text = text.replace(old, new, 1)
    updated[path] = text
for path, text in updated.items():
    path.write_text(text)
for name in ("flclash_failure_gate.go", "flclash_failure_gate_test.go"):
    shutil.copyfile(here / name, group / name)
# Android publishes the system resolver list while DNS workers read it.
# Publish immutable snapshots; a reader may finish using the previous list.
android_dns = root / "dns/patch_android.go"
text = android_dns.read_text()
for old, new in [
    ('import (\n', 'import (\n\t"sync/atomic"\n\n'),
    ('var systemResolver []dnsClient', 'var systemResolver atomic.Pointer[[]dnsClient]'),
    ('\tif len(addr) == 0 {\n\t\tsystemResolver = nil\n\t}\n\n', ''),
    ('\tsystemResolver = transform(ns, nil)', '\tclients := transform(ns, nil)\n\tsystemResolver.Store(&clients)'),
    ('\treturn systemResolver, nil', '\tif clients := systemResolver.Load(); clients != nil {\n\t\treturn *clients, nil\n\t}\n\treturn nil, nil'),
    ('\tfor _, r := range systemResolver {', '\tclients, _ := c.getDnsClients()\n\tfor _, r := range clients {'),
]:
    if text.count(old) != 1:
        raise SystemExit("Mihomo Android DNS source changed")
    text = text.replace(old, new, 1)
android_dns.write_text(text)

# The upstream SystemResolver is a plain *Resolver, not a Resolvers wrapper.
# ClearAll must reach it as well as the profile DNS and its bootstrap clients.
clear = root / "dns/patch_clear.go"
text = clear.read_text()
old = """\t\tif rs, ok := r.(Resolvers); ok {
\t\t\tpending = append(pending, rs.Resolver, rs.ProxyResolver, rs.DirectResolver)
\t\t}"""
new = """\t\tswitch rs := r.(type) {
\t\tcase Resolvers:
\t\t\tpending = append(pending, rs.Resolver, rs.ProxyResolver, rs.DirectResolver)
\t\tcase *Resolver:
\t\t\tpending = append(pending, rs)
\t\t}"""
if text.count(old) != 1:
    raise SystemExit("Mihomo DNS clear source changed")
clear.write_text(text.replace(old, new, 1))
shutil.copyfile(here / "flclash_system_dns_test.go", root / "dns/flclash_system_dns_test.go")
print("Applied Mihomo failure recovery and DNS extensions")
