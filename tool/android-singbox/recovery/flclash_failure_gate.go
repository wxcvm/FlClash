package group

import (
	"sync"
	"time"
)

// flclashFailureGate is scoped to one opted-in URLTest group. Completion
// order defines the streak; unrelated transport types don't reset each other.
type flclashFailureGate struct {
	mu sync.Mutex
	streak map[string]flclashFailureStreak
	last time.Time
	running bool
	closed bool
}

type flclashFailureStreak struct {
	tag string
	count int
}

const flclashFailureThreshold = 3
const flclashFailureCooldown = 10 * time.Second

func (g *flclashFailureGate) observe(network, tag string, failed bool, now time.Time) bool {
	g.mu.Lock()
	defer g.mu.Unlock()
	if g.closed { return false }
	if g.streak == nil { g.streak = make(map[string]flclashFailureStreak) }
	s := g.streak[network]
	if s.tag != tag || !failed {
		s = flclashFailureStreak{tag: tag}
	}
	if failed && s.count < flclashFailureThreshold { s.count++ }
	g.streak[network] = s
	if !failed || s.count < flclashFailureThreshold || g.running ||
		(!g.last.IsZero() && now.Sub(g.last) < flclashFailureCooldown) {
		return false
	}
	g.running = true
	g.last = now
	// Require a fresh streak after admitting a check. Concurrent failures
	// may accumulate again, but may not launch another check in parallel.
	clear(g.streak)
	return true
}

func (g *flclashFailureGate) finish() {
	g.mu.Lock()
	defer g.mu.Unlock()
	g.running = false
}

func (g *flclashFailureGate) reset() {
	g.mu.Lock()
	defer g.mu.Unlock()
	clear(g.streak)
}

func (g *flclashFailureGate) close() {
	g.mu.Lock()
	defer g.mu.Unlock()
	g.closed = true
	clear(g.streak)
}
