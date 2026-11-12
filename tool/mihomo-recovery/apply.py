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
print("Applied Mihomo failure recovery extension")
