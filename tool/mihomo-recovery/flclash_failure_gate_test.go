package outboundgroup

import (
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

func TestFlClashFailureGate(t *testing.T) {
	var g flclashFailureGate
	now := time.Unix(100, 0)
	fail := func(n, name string, when time.Time) bool {
		return g.failure(n, name, when, 5*time.Second, 3, false)
	}
	if fail("tcp", "a", now) || fail("tcp", "a", now) { t.Fatal("early trigger") }
	g.success("tcp", "a")
	if fail("tcp", "a", now) || fail("tcp", "a", now) { t.Fatal("success did not reset") }
	if fail("tcp", "b", now) || fail("tcp", "b", now) { t.Fatal("different node inherited streak") }
	if fail("udp", "b", now) { t.Fatal("UDP inherited TCP streak") }
	if !fail("tcp", "b", now) { t.Fatal("threshold not reached") }
	if g.failure("udp", "b", now.Add(time.Minute), 5*time.Second, 3, true) { t.Fatal("parallel check") }
	g.finish()
	if g.failure("tcp", "b", now.Add(time.Second), 5*time.Second, 3, true) { t.Fatal("cooldown") }
	if !g.failure("tcp", "b", now.Add(5*time.Second), 5*time.Second, 3, true) { t.Fatal("refusal not admitted") }
}

func TestFlClashFailureWindow(t *testing.T) {
	var g flclashFailureGate
	now := time.Unix(100, 0)
	g.failure("tcp", "a", now, time.Second, 2, false)
	if g.failure("tcp", "a", now.Add(2*time.Second), time.Second, 2, false) { t.Fatal("expired streak") }
	if !g.failure("tcp", "a", now.Add(2*time.Second), time.Second, 2, false) { t.Fatal("new streak") }
}

func TestFlClashFailureConcurrent(t *testing.T) {
	var g flclashFailureGate
	var count atomic.Int32
	var wg sync.WaitGroup
	now := time.Unix(100, 0)
	for i := 0; i < 100; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			if g.failure("tcp", "a", now, time.Second, 3, false) { count.Add(1) }
		}()
	}
	wg.Wait()
	if count.Load() != 1 { t.Fatalf("admitted %d checks", count.Load()) }
}
