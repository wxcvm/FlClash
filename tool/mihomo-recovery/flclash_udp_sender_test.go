package tunnel

import (
	"sync"
	"sync/atomic"
	"testing"

	C "github.com/metacubex/mihomo/constant"
)

// Only Drop is used by the queue; the embedded interface deliberately
// makes any unexpected packet processing fail.
type flclashUDPDropPacket struct {
	C.PacketAdapter
	drops atomic.Int32
}

func (p *flclashUDPDropPacket) Drop() { p.drops.Add(1) }

func TestFlClashUDPSenderCloseDrainsConcurrentEnqueues(t *testing.T) {
	for round := 0; round < 100; round++ {
		s := newPacketSender().(*packetSender)
		packets := make([]flclashUDPDropPacket, 64)
		var wg sync.WaitGroup
		start := make(chan struct{})
		for i := range packets {
			wg.Add(1)
			go func(p *flclashUDPDropPacket) {
				defer wg.Done()
				<-start
				s.Send(p)
			}(&packets[i])
		}
		wg.Add(1)
		go func() {
			defer wg.Done()
			<-start
			s.Close()
		}()
		close(start)
		wg.Wait()
		if len(s.ch) != 0 {
			t.Fatalf("round %d: closed sender retained %d packets", round, len(s.ch))
		}
		for i := range packets {
			if got := packets[i].drops.Load(); got != 1 {
				t.Fatalf("round %d packet %d: dropped %d times, want 1", round, i, got)
			}
		}
	}
}

func TestFlClashUDPSenderDropsAfterClose(t *testing.T) {
	s := newPacketSender().(*packetSender)
	s.Close()
	p := &flclashUDPDropPacket{}
	s.Send(p)
	if p.drops.Load() != 1 || len(s.ch) != 0 {
		t.Fatal("closed sender accepted a packet")
	}
}
