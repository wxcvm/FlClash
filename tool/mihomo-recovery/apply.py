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

# Unified latency optionally sends a second HEAD. A failed optional sample
# must not inflate the first successful sample by its entire timeout.
adapter_path = root / "adapter/adapter.go"
adapter_source = adapter_path.read_text(encoding="utf-8")
for old, new in (
    ("\t_ = resp.Body.Close()\n\n\tif unifiedDelay {", "\t_ = resp.Body.Close()\n\telapsed := time.Since(start)\n\n\tif unifiedDelay {"),
    ("\t\t\tstart = second", "\t\t\telapsed = time.Since(second)"),
    ("t = uint16(time.Since(start) / time.Millisecond)", "t = uint16(elapsed / time.Millisecond)"),
):
    if adapter_source.count(old) != 1:
        raise SystemExit("Mihomo unified delay source changed")
    adapter_source = adapter_source.replace(old, new, 1)
adapter_path.write_text(adapter_source, encoding="utf-8", newline="\n")

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

# Report a TCP/UDP dial failure after the tunnel exhausts its retries. The
# pinned submodule predates this host hook, so extend it through the same
# reviewed source-patch path as the other downstream Mihomo fixes.
tunnel_patch = root / "tunnel/patch.go"
text = tunnel_patch.read_text()
if "type DialFailureNotify" in text or "func notifyDialFailure" in text:
    raise SystemExit("Mihomo dial-failure hook already exists")
text += """

// DialFailureNotify hears of a connection the tunnel gave up dialing, after
// its last retry. The connection never reaches the statistic Manager.
type DialFailureNotify func(metadata *C.Metadata, rule C.Rule, proxy C.Proxy, err error)

var DefaultDialFailureNotify DialFailureNotify

func notifyDialFailure(metadata *C.Metadata, rule C.Rule, proxy C.Proxy, err error) {
    if DefaultDialFailureNotify != nil {
        DefaultDialFailureNotify(metadata, rule, proxy, err)
    }
}
"""
tunnel_patch.write_text(text, encoding="utf-8", newline="\\n")

tunnel_file = root / "tunnel/tunnel.go"
text = tunnel_file.read_text()
for old, new in [
    (
        """\\t\\t\\tif err != nil {
\\t\\t\\t\\treturn nil, nil, err
\\t\\t\\t}
\\t\\t\\tlogMetadata(metadata, rule, rawPc)""",
        """\\t\\t\\tif err != nil {
\\t\\t\\t\\tnotifyDialFailure(metadata, rule, proxy, err)
\\t\\t\\t\\treturn nil, nil, err
\\t\\t\\t}
\\t\\t\\tlogMetadata(metadata, rule, rawPc)""",
    ),
    (
        """\\tif err != nil {
\\t\\treturn
\\t}
\\tlogMetadata(metadata, rule, remoteConn)""",
        """\\tif err != nil {
\\t\\tnotifyDialFailure(metadata, rule, proxy, err)
\\t\\treturn
\\t}
\\tlogMetadata(metadata, rule, remoteConn)""",
    ),
]:
    if text.count(old) != 1:
        raise SystemExit("Mihomo dial-failure source changed")
    text = text.replace(old, new, 1)
tunnel_file.write_text(text, encoding="utf-8", newline="\\n")

shutil.copyfile(here / "flclash_dial_failure_test.go", root / "tunnel/flclash_dial_failure_test.go")

print("Applied Mihomo failure recovery, DNS, GeoIP, UDP and dial-failure extensions")
