#!/usr/bin/env python3
"""Apply the reviewed FlClash URLTest extension to one pinned sing-box revision."""
from pathlib import Path
import shutil
import subprocess
import sys

PIN = "c005f35300ce76427dc285481ec5695f5b179cd2"
root = Path(sys.argv[1]).resolve()
source = root / "protocol/group/urltest.go"
here = Path(__file__).resolve().parent
if subprocess.check_output(["git", "-C", str(root), "rev-parse", "HEAD"], text=True).strip() != PIN:
    raise SystemExit("Refusing to patch an unreviewed sing-box revision")
text = source.read_text()

def replace(old, new):
    global text
    if text.count(old) != 1:
        raise SystemExit("Upstream URLTest changed: " + old[:90])
    text = text.replace(old, new, 1)

replace('\t"slices"\n', '\t"slices"\n\t"strings"\n')
replace('\t\ts.group = group\n', '''		// Only FlClash-generated, explicitly selected recovery groups opt in.
		if strings.HasPrefix(s.Tag(), "FlClash Auto · ") {
			group.recoveryCtx, group.recoveryCancel = context.WithCancel(group.ctx)
		}
		s.group = group
''')
replace('''	if err == nil {
		return s.group.interruptGroup.NewConn(conn, interrupt.IsExternalConnectionFromContext(ctx)), nil
	}
	s.logger.ErrorContext(ctx, err)
	s.group.history.DeleteURLTestHistory(outbound.Tag())
	return nil, err''', '''	if err == nil {
		s.group.observeDial(ctx, N.NetworkName(network), outbound.Tag(), false)
		return s.group.interruptGroup.NewConn(conn, interrupt.IsExternalConnectionFromContext(ctx)), nil
	}
	s.logger.ErrorContext(ctx, err)
	if s.group.recoveryCtx != nil && ctx.Err() != nil {
		return nil, err
	}
	s.group.history.DeleteURLTestHistory(outbound.Tag())
	s.group.observeDial(ctx, N.NetworkName(network), outbound.Tag(), true)
	return nil, err''')
replace('''	if err == nil {
		return s.group.interruptGroup.NewPacketConn(conn, interrupt.IsExternalConnectionFromContext(ctx)), nil
	}
	s.logger.ErrorContext(ctx, err)
	s.group.history.DeleteURLTestHistory(outbound.Tag())
	return nil, err''', '''	if err == nil {
		s.group.observeDial(ctx, N.NetworkUDP, outbound.Tag(), false)
		return s.group.interruptGroup.NewPacketConn(conn, interrupt.IsExternalConnectionFromContext(ctx)), nil
	}
	s.logger.ErrorContext(ctx, err)
	if s.group.recoveryCtx != nil && ctx.Err() != nil {
		return nil, err
	}
	s.group.history.DeleteURLTestHistory(outbound.Tag())
	s.group.observeDial(ctx, N.NetworkUDP, outbound.Tag(), true)
	return nil, err''')
replace('	lastActive                   common.TypedValue[time.Time]\n', '''	lastActive                   common.TypedValue[time.Time]
	recovery                     flclashFailureGate
	recoveryCtx                  context.Context
	recoveryCancel               context.CancelFunc
''')
replace('func (g *URLTestGroup) Close() error {\n', '''func (g *URLTestGroup) Close() error {
	if g.recoveryCancel != nil {
		g.recovery.close()
		g.recoveryCancel()
	}
''')
replace('func (g *URLTestGroup) CheckOutbounds(ctx context.Context, force bool) {', '''// A dial failure is only a hint, never a reason to replay user traffic or
// blindly pick a different node. Reuse the real URLTest and its existing
// selection/tolerance logic, even when the periodic interval has not elapsed.
func (g *URLTestGroup) observeDial(ctx context.Context, network, tag string, failed bool) {
	if g.recoveryCtx == nil || g.recoveryCtx.Err() != nil || ctx.Err() != nil ||
		g.pause.IsDevicePaused() || g.pause.IsNetworkPaused() {
		return
	}
	if !g.recovery.observe(network, tag, failed, time.Now()) {
		return
	}
	go func() {
		defer g.recovery.finish()
		if g.recoveryCtx.Err() != nil || g.pause.IsDevicePaused() || g.pause.IsNetworkPaused() {
			return
		}
		checkCtx, cancel := context.WithTimeout(g.recoveryCtx, 20*time.Second)
		defer cancel()
		g.CheckOutbounds(checkCtx, true)
	}()
}

func (g *URLTestGroup) CheckOutbounds(ctx context.Context, force bool) {''')
source.write_text(text)
for name in ("flclash_failure_gate.go", "flclash_failure_gate_test.go"):
    shutil.copyfile(here / name, source.parent / name)
print("Applied FlClash failure recovery to pinned sing-box")
