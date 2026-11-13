package group

import (
	"sync"
	"testing"
	"time"
)

func TestFlClashFailureGate(t *testing.T) {
	var g flclashFailureGate
	now := time.Unix(100, 0)
	if g.observe("tcp", "a", true, now) || g.observe("tcp", "a", true, now) {
		t.Fatal("admitted before three failures")
	}
	g.observe("tcp", "a", false, now)
	if g.observe("tcp", "a", true, now) || g.observe("tcp", "a", true, now) {
		t.Fatal("success must reset streak")
	}
	if g.observe("tcp", "b", true, now) || g.observe("tcp", "b", true, now) {
		t.Fatal("different outbound must reset streak")
	}
	g.observe("udp", "b", true, now)
	if !g.observe("tcp", "b", true, now) {
		t.Fatal("third TCP failure must admit recovery")
	}
	for i := 0; i < 10; i++ {
		if g.observe("udp", "b", true, now.Add(time.Minute)) { t.Fatal("parallel check") }
	}
	g.finish()
	if g.observe("udp", "b", true, now.Add(time.Second)) { t.Fatal("cooldown") }
	if !g.observe("udp", "b", true, now.Add(flclashFailureCooldown)) { t.Fatal("cooldown did not expire") }
	g.close()
	g.finish()
	if g.observe("udp", "b", true, now.Add(time.Hour)) { t.Fatal("closed gate") }
}

func TestFlClashNetworkReset(t *testing.T) {
	var g flclashFailureGate
	now := time.Unix(100, 0)
	g.observe("tcp", "a", true, now)
	g.observe("tcp", "a", true, now)
	g.reset()
	if g.observe("tcp", "a", true, now) || g.observe("tcp", "a", true, now) {
		t.Fatal("old network failures leaked into new network")
	}
	if !g.observe("tcp", "a", true, now) { t.Fatal("new network streak did not trigger") }
}

func TestFlClashConcurrentFailureGate(t *testing.T) {
	var g flclashFailureGate
	now := time.Unix(100, 0)
	var wg sync.WaitGroup
	admitted := make(chan struct{}, 100)
	for i := 0; i < 100; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			if g.observe("tcp", "node", true, now) { admitted <- struct{}{} }
		}()
	}
	wg.Wait()
	if len(admitted) != 1 { t.Fatalf("admitted %d checks", len(admitted)) }
}
