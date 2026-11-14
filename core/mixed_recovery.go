package core

import (
	"context"
	"errors"
	"net"
	"runtime"
	"strconv"
	"syscall"
	"time"

	"github.com/metacubex/mihomo/listener"
	"github.com/metacubex/mihomo/log"
	"github.com/metacubex/mihomo/tunnel"
)

// Windows system proxy uses the loopback mixed port. A configuration that
// intentionally binds only to another address must not be repaired.
func loopbackMixedPort(port int, allowLan bool, bind string) bool {
	return port > 0 && port <= 65535 &&
		(!allowLan || bind == "*" || bind == "127.0.0.1" || bind == "0.0.0.0")
}

func localConnectionRefused(err error) bool {
	// Windows Winsock reports WSAECONNREFUSED (10061).
	return errors.Is(err, syscall.ECONNREFUSED) ||
		(runtime.GOOS == "windows" && errors.Is(err, syscall.Errno(10061)))
}

func confirmMissingMixedListener(ctx context.Context, dial func(context.Context) error, valid func() bool) bool {
	for i := 0; i < 2; i++ {
		if ctx.Err() != nil || !valid() || !localConnectionRefused(dial(ctx)) {
			return false
		}
	}
	return ctx.Err() == nil && valid()
}

// Protected by configMu. Bound retry frequency even when a port cannot bind.
var lastMixedRepair time.Time

func recoverWindowsMixedListener(ctx context.Context, valid func() bool) {
	if runtime.GOOS != "windows" {
		return
	}
	configMu.Lock()
	cfg := currentConfig
	if cfg == nil || !isRunning.Load() || appliedConfigDigest == nil {
		configMu.Unlock()
		return
	}
	port, allowLan, bind := cfg.General.MixedPort, cfg.General.AllowLan, cfg.General.BindAddress
	configMu.Unlock()
	if !loopbackMixedPort(port, allowLan, bind) {
		return
	}
	address := net.JoinHostPort("127.0.0.1", strconv.Itoa(port))
	dial := func(ctx context.Context) error {
		d := net.Dialer{Timeout: 500 * time.Millisecond}
		conn, err := d.DialContext(ctx, "tcp4", address)
		if conn != nil {
			_ = conn.Close()
		}
		return err
	}
	if !confirmMissingMixedListener(ctx, dial, valid) {
		return
	}
	configMu.Lock()
	defer configMu.Unlock()
	if !valid() || currentConfig != cfg || !isRunning.Load() ||
		cfg.General.MixedPort != port || cfg.General.AllowLan != allowLan ||
		cfg.General.BindAddress != bind || time.Since(lastMixedRepair) < time.Minute {
		return
	}
	// Recheck under the config lock: a concurrent configuration update may
	// have already restored the socket. Never reset a reachable listener.
	if !localConnectionRefused(dial(ctx)) || ctx.Err() != nil || !valid() {
		return
	}
	lastMixedRepair = time.Now()
	// The pinned Mihomo ReCreateMixed skips an unchanged RawAddress, even
	// when a previous UDP bind failure closed its TCP socket. Clear only
	// the mixed listener first; preserve TUN and existing outbound sessions.
	listener.ReCreateMixed(0, tunnel.Tunnel)
	listener.ReCreateMixed(port, tunnel.Tunnel)
	if err := dial(ctx); err != nil {
		log.Warnln("[Network recovery] mixed listener %s still unavailable after repair: %v", address, err)
	} else {
		log.Infoln("[Network recovery] restored mixed listener %s", address)
	}
}
