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
# The pinned upstream spells Windows' NCSI probe hosts incorrectly.
# Correct only its built-in defaults; do not rewrite user DNS profiles.
ncsi_config = root / "config/config.go"
ncsi_source = ncsi_config.read_text(encoding="utf-8")
for old, new in (
    ('"dns.msftnsci.com"', '"dns.msftncsi.com"'),
    ('"www.msftnsci.com"', '"www.msftncsi.com"'),
):
    if ncsi_source.count(old) != 1:
        raise SystemExit("Mihomo NCSI default source changed")
    ncsi_source = ncsi_source.replace(old, new, 1)
ncsi_config.write_text(ncsi_source, encoding="utf-8", newline="\n")

# MMDB discovery must not overwrite the protobuf GeoIP.dat filename.
# With both packaged resources present, doing so makes a subsequent GEOIP
# rule try to decode GEOIP.metadb as a protobuf, failing configuration load.
geo_path = root / "constant/path.go"
geo_source = geo_path.read_text(encoding="utf-8")
old = '''strings.EqualFold(fi.Name(), "GEOIP.metadb") {
				GeoipName = fi.Name()
				return P.Join(p.homeDir, fi.Name())
'''
new = '''strings.EqualFold(fi.Name(), "GEOIP.metadb") {
				return P.Join(p.homeDir, fi.Name())
'''
if geo_source.count(old) != 1:
    raise SystemExit("Mihomo MMDB discovery source changed")
geo_path.write_text(geo_source.replace(old, new, 1), encoding="utf-8", newline="\n")
shutil.copyfile(here / "flclash_geo_path_test.go", root / "constant/flclash_geo_path_test.go")

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
# A concurrent sender could enqueue after cancellation and after the final
# drain, retaining packet buffers that never reach UDPPacket.Drop.
udp = root / "tunnel/connection.go"
text = udp.read_text()
old = """func (s *packetSender) Send(packet C.PacketAdapter) {
	select {
	case <-s.ctx.Done():
		packet.Drop() // sender closed before Send()
		return
	default:
	}

	select {
	case s.ch <- packet:
		// put ok, so don't drop packet, will process by other side of chan
	case <-s.ctx.Done():
		packet.Drop() // sender closed when putting data to chan
	default:
		packet.Drop() // chan is full
	}
}

func (s *packetSender) Close() {
	s.cancel()
	s.dropAll()
}"""
new = """func (s *packetSender) Send(packet C.PacketAdapter) {
	// Serialize the nonblocking enqueue with cancellation. A select can
	// otherwise choose a ready send after Close has already drained the queue.
	s.sendMu.Lock()
	if s.ctx.Err() == nil {
		select {
		case s.ch <- packet:
			s.sendMu.Unlock()
			return
		default:
		}
	}
	s.sendMu.Unlock()
	packet.Drop()
}

func (s *packetSender) Close() {
	s.sendMu.Lock()
	s.cancel()
	s.sendMu.Unlock()
	s.dropAll()
}"""
field = "\tch     chan C.PacketAdapter\n"
if text.count(old) != 1 or text.count(field) != 1:
    raise SystemExit("Mihomo UDP sender source changed")
text = text.replace(field, field + "\tsendMu sync.Mutex\n", 1)
udp.write_text(text.replace(old, new, 1))
shutil.copyfile(here / "flclash_udp_sender_test.go", root / "tunnel/flclash_udp_sender_test.go")
print("Applied Mihomo failure recovery, DNS, GeoIP and UDP extensions")
