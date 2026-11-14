package core

import (
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/metacubex/mihomo/component/auth"
	"github.com/metacubex/mihomo/config"
	"github.com/metacubex/mihomo/tunnel"
)

func TestNetworkHandoverDoesNotReloadWhenCoreIsStopped(t *testing.T) {
	previous := isRunning.Load()
	t.Cleanup(func() { isRunning.Store(previous) })

	cfg := &config.Config{}
	withCurrentConfig(t, cfg)
	isRunning.Store(false)
	reloadOutboundsOnNetworkChange()
	if currentConfig != cfg {
		t.Fatal("stopped core unexpectedly changed its config")
	}

	currentConfig = nil
	isRunning.Store(true)
	reloadOutboundsOnNetworkChange()
	if currentConfig != nil {
		t.Fatal("core without an applied profile unexpectedly reloaded")
	}
}

func TestNetworkReloadPreservesLiveSettings(t *testing.T) {
	path := filepath.Join(t.TempDir(), "config.yaml")
	profile := []byte("mixed-port: 7890\nmode: rule\nipv6: false\nsecret: old\ndns:\n  enable: true\n  enhanced-mode: fake-ip\n  nameserver: [1.1.1.1]\n")
	if err := os.WriteFile(path, profile, 0o600); err != nil {
		t.Fatal(err)
	}
	active, digest, err := loadConfigSnapshot(path)
	if err != nil {
		t.Fatal(err)
	}
	active.General.MixedPort = 7895
	active.General.Mode = tunnel.Global
	active.General.IPv6 = true
	active.General.Tun.Device = "live-tun"
	active.Controller.Secret = "live-secret"
	active.Users = []auth.AuthUser{{User: "live", Pass: "password"}}
	fresh, err := loadNetworkReloadConfig(path, digest, active)
	if err != nil {
		t.Fatal(err)
	}
	if fresh.General != active.General || fresh.Controller != active.Controller {
		t.Fatal("network reload replaced live configuration")
	}
	if fresh.General.MixedPort != 7895 || fresh.General.Mode != tunnel.Global ||
		!fresh.General.IPv6 || fresh.General.Tun.Device != "live-tun" ||
		fresh.Controller.Secret != "live-secret" {
		t.Fatal("network reload rolled back runtime settings")
	}
	if len(fresh.Users) != 1 || fresh.Users[0].User != "live" {
		t.Fatal("network reload lost runtime authentication")
	}
	if !fresh.DNS.Enable {
		t.Fatal("network reload lost the applied DNS configuration")
	}
}

func TestNetworkReloadRejectsUnappliedFile(t *testing.T) {
	path := filepath.Join(t.TempDir(), "config.yaml")
	if err := os.WriteFile(path, nil, 0o600); err != nil {
		t.Fatal(err)
	}
	active, digest, err := loadConfigSnapshot(path)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, []byte("mixed-port: 7999\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	if _, err := loadNetworkReloadConfig(path, digest, active); err == nil ||
		!strings.Contains(err.Error(), "changed since the last successful apply") {
		t.Fatalf("unexpected reload result: %v", err)
	}
}

func TestMergedProfileSnapshotMatchesPublishedFile(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "profile.yaml")
	output := filepath.Join(dir, "config.yaml")
	// Keep the input minimal: the merged document is the exact snapshot used
	// by the network reload, not the source subscription.
	if err := os.WriteFile(path, []byte("rules:\n  - MATCH,DIRECT\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	active, digest, err := loadConfigWithBaseSnapshot(
		&SetupBase{Path: path, Overlay: "mixed-port: 7890\n"}, output,
	)
	if err != nil {
		t.Fatal(err)
	}
	onDisk, err := digestConfigFile(output)
	if err != nil || onDisk != digest {
		t.Fatalf("published digest mismatch: %v", err)
	}
	if _, err := loadNetworkReloadConfig(output, digest, active); err != nil {
		t.Fatalf("merged profile cannot be reloaded: %v", err)
	}
}

func TestQueuedMobileRecoverySkipsSupersededHandover(t *testing.T) {
	older := mobileNetworkResetSequence.Add(1)
	newer := mobileNetworkResetSequence.Add(1)
	var calls int
	reset := func() { calls++ }

	// The newer handover may acquire the lock first. The old queued job
	// must not close the new connections when it eventually runs.
	runNetworkReset(newer, reset)
	runNetworkReset(older, reset)
	if calls != 1 {
		t.Fatalf("got %d recoveries, want 1", calls)
	}
	// Explicit host recovery is independent of the mobile sequence.
	runNetworkReset(0, reset)
	if calls != 2 {
		t.Fatalf("explicit recovery skipped: %d", calls)
	}
}

func TestMobileRecoverySupersededWhileWaitingForLock(t *testing.T) {
	networkResetMu.Lock()
	older := mobileNetworkResetSequence.Add(1)
	done := make(chan struct{})
	calls := 0
	go func() {
		runNetworkReset(older, func() { calls++ })
		close(done)
	}()
	newer := mobileNetworkResetSequence.Add(1)
	networkResetMu.Unlock()
	<-done
	if calls != 0 {
		t.Fatal("queued older handover was not skipped")
	}
	runNetworkReset(newer, func() { calls++ })
	if calls != 1 {
		t.Fatalf("latest handover did not recover: %d", calls)
	}
}
