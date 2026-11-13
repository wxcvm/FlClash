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
replace('''	if group == nil {
		return
	}
	if group.pause.IsDevicePaused()''', '''	if group == nil {
		return
	}
	// Never combine failures collected on different underlying networks.
	group.recovery.reset()
	if group.pause.IsDevicePaused()''')
replace('func (g *URLTestGroup) observeDial(ctx context.Context, network, tag string, failed bool) {', '''// The actual router unwraps groups before dialing. Its connection manager
// calls this hook on the original chain, rather than changing routing.
func (s *URLTest) ObserveFlClashDial(ctx context.Context, network, tag string, failed bool) {
	s.group.observeDial(ctx, network, tag, failed)
}

func (g *URLTestGroup) observeDial(ctx context.Context, network, tag string, failed bool) {''')
replace('''	result := URLTestOutbounds(ctx, g.outbound, g.history, g.logger, g.outbounds, g.link, g.interval, force)
	g.performUpdateCheck()''', '''	result := URLTestOutbounds(ctx, g.outbound, g.history, g.logger, g.outbounds, g.link, g.interval, force)
	if g.recoveryCtx == nil || (g.recoveryCtx.Err() == nil && ctx.Err() == nil) {
		g.performUpdateCheck()
	}''')
source.write_text(text)
for name in ("flclash_failure_gate.go", "flclash_failure_gate_test.go"):
    shutil.copyfile(here / name, source.parent / name)
# In 1.14.4, route.resolveOutbound unwraps groups before the real dial.
# Observe completed attempts in ConnectionManager without wrapping the leaf,
# which would change optional dialer interfaces and the routing fast path.
source = root / "route/conn.go"
text = source.read_text()
replace('''		m.deleteURLTestHistory(metadata.OutboundChain)
		N.CloseOnHandshakeFailure(conn, onClose, err)''', '''		m.deleteURLTestHistory(metadata.OutboundChain)
		observeFlClashRoute(ctx, metadata.OutboundChain, N.NetworkTCP, true)
		N.CloseOnHandshakeFailure(conn, onClose, err)''')
replace('''			err = E.Cause(err, "open packet connection to ", remoteString, dialerString)
			m.deleteURLTestHistory(metadata.OutboundChain)''', '''			err = E.Cause(err, "open packet connection to ", remoteString, dialerString)
			m.deleteURLTestHistory(metadata.OutboundChain)
			observeFlClashRoute(ctx, metadata.OutboundChain, N.NetworkUDP, true)''')
replace('''			err = E.Cause(err, "listen packet connection using ", dialerString)
			m.deleteURLTestHistory(metadata.OutboundChain)''', '''			err = E.Cause(err, "listen packet connection using ", dialerString)
			m.deleteURLTestHistory(metadata.OutboundChain)
			observeFlClashRoute(ctx, metadata.OutboundChain, N.NetworkUDP, true)''')
replace('''	if m.kickWriteHandshake(ctx, conn, remoteConn, serverFirst, false, &done, onClose) {
		return
	}''', '''	if m.kickWriteHandshake(ctx, conn, remoteConn, serverFirst, false, &done, onClose) {
		observeFlClashRoute(ctx, metadata.OutboundChain, N.NetworkTCP, true)
		return
	}''')
replace('''	go m.connectionCopy(ctx, conn, remoteConn, false, &done, onClose)''', '''	observeFlClashRoute(ctx, metadata.OutboundChain, N.NetworkTCP, false)
	go m.connectionCopy(ctx, conn, remoteConn, false, &done, onClose)''')
replace('''	if destinationAddress.IsValid() {
		var originDestination M.Socksaddr''', '''	observeFlClashRoute(ctx, metadata.OutboundChain, N.NetworkUDP, false)
	if destinationAddress.IsValid() {
		var originDestination M.Socksaddr''')
replace('func (m *ConnectionManager) deleteURLTestHistory(chain []adapter.Outbound) {', '''// One outcome per completed routed connection attempt. The original group
// chain is retained by the router even when the leaf is dialed directly.
func observeFlClashRoute(ctx context.Context, chain []adapter.Outbound, network string, failed bool) {
	if len(chain) < 2 || ctx.Err() != nil {
		return
	}
	tag := chain[len(chain)-1].Tag()
	for _, outbound := range chain[:len(chain)-1] {
		if observer, ok := outbound.(interface {
			ObserveFlClashDial(context.Context, string, string, bool)
		}); ok {
			observer.ObserveFlClashDial(ctx, network, tag, failed)
		}
	}
}

func (m *ConnectionManager) deleteURLTestHistory(chain []adapter.Outbound) {''')
source.write_text(text)
shutil.copyfile(here / "flclash_route_observer_test.go", source.parent / "flclash_route_observer_test.go")
print("Applied FlClash failure recovery to pinned sing-box group and routed connections")
