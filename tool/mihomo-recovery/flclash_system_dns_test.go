package dns

import (
	"context"
	"testing"

	"github.com/metacubex/mihomo/component/resolver"
	D "github.com/miekg/dns"
)

type flclashSystemDNSClient struct {
	answeringClient
	resets int
}

func (c *flclashSystemDNSClient) ResetConnection() { c.resets++ }

func TestFlClashClearAllSystemResolver(t *testing.T) {
	client := &flclashSystemDNSClient{
		answeringClient: answeringClient{address: "udp://192.0.2.53:53", ip: "198.51.100.7"},
	}
	system := &Resolver{main: []dnsClient{client}, cache: Config{}.newCache()}
	previousSystem, previousDefault := resolver.SystemResolver, resolver.DefaultResolver
	resolver.SystemResolver, resolver.DefaultResolver = system, nil
	t.Cleanup(func() {
		resolver.SystemResolver, resolver.DefaultResolver = previousSystem, previousDefault
	})
	if _, err := system.LookupIPv4(context.Background(), "system.example"); err != nil {
		t.Fatal(err)
	}
	question := D.Question{Name: "system.example.", Qtype: D.TypeA, Qclass: D.ClassINET}
	if _, _, hit := getMsgFromCache(system.cache, question); !hit {
		t.Fatal("expected cached system DNS answer")
	}
	ClearAll()
	if _, _, hit := getMsgFromCache(system.cache, question); hit {
		t.Fatal("system DNS answer survived network change")
	}
	if client.resets != 1 {
		t.Fatalf("system transport reset %d times, want 1", client.resets)
	}
}
