package outboundgroup

import (
	"sync"
	"time"
)

const flclashRecoveryCooldown = 5 * time.Second

type flclashFailureStreak struct {
	name string
	first time.Time
	count int
}

// Two transport streaks per group, no unbounded per-node history.
type flclashFailureGate struct {
	mu sync.Mutex
	streak map[string]flclashFailureStreak
	running bool
	last time.Time
}

func (g *flclashFailureGate) failure(network, name string, now time.Time, window time.Duration, threshold int, immediate bool) bool {
	g.mu.Lock()
	defer g.mu.Unlock()
	if g.streak == nil {
		g.streak = make(map[string]flclashFailureStreak)
	}
	s := g.streak[network]
	if s.name != name || now.Sub(s.first) > window {
		s = flclashFailureStreak{name: name, first: now}
	}
	if s.count < threshold {
		s.count++
	}
	g.streak[network] = s
	if (!immediate && s.count < threshold) || g.running ||
		(!g.last.IsZero() && now.Sub(g.last) < flclashRecoveryCooldown) {
		return false
	}
	g.running = true
	g.last = now
	clear(g.streak)
	return true
}

func (g *flclashFailureGate) success(network, name string) {
	g.mu.Lock()
	defer g.mu.Unlock()
	if g.streak[network].name == name {
		delete(g.streak, network)
	}
}

func (g *flclashFailureGate) finish() {
	g.mu.Lock()
	defer g.mu.Unlock()
	g.running = false
}
