package core

import "testing"

func TestClaudeItemReportsTheAddressTheServiceSaw(t *testing.T) {
	item := claudeItem(&ProbeResult{
		StatusCode: 200,
		Body:       "fl=abc\nip=198.51.100.9\nloc=US\n",
	})
	if item.Ip != "198.51.100.9" || item.Region != "US" || item.Status != serviceAvailable {
		t.Errorf(
			"item = %+v, want the trace's address and region",
			item,
		)
	}
}

func TestReadChatGptTraceReportsTheAddressTheServiceSaw(t *testing.T) {
	item := ServiceCheckItem{Status: serviceAvailable}
	readChatGptTrace(
		&item,
		&ProbeResult{
			StatusCode: 200,
			Body:       "ip=2001:db8::7\nloc=JP\n",
		},
	)
	if item.Ip != "2001:db8::7" || item.Region != "JP" {
		t.Errorf(
			"item = %+v, want the trace's address and region",
			item,
		)
	}

	unanswered := ServiceCheckItem{Status: serviceAvailable}
	readChatGptTrace(&unanswered, &ProbeResult{Error: probeErrorTimeout})
	if unanswered.Ip != "" || unanswered.Region != "" {
		t.Errorf(
			"item = %+v, want nothing from a trace that never answered",
			unanswered,
		)
	}
}

func TestTraceIpKeepsOnlyAnAddress(t *testing.T) {
	if got := traceIp("ip=203.0.113.7\n"); got != "203.0.113.7" {
		t.Errorf("IPv4 traceIp = %q, want 203.0.113.7", got)
	}
	if got := traceIp("ip=::ffff:203.0.113.7\n"); got != "203.0.113.7" {
		t.Errorf("mapped IPv4 traceIp = %q, want 203.0.113.7", got)
	}
	if got := traceIp("ip=2001:db8::1\n"); got != "2001:db8::1" {
		t.Errorf("IPv6 traceIp = %q, want 2001:db8::1", got)
	}
	for _, body := range []string{
		"ip=<html>blocked\n",
		"ip=\nloc=US\n",
		"loc=US\n",
		"<html>ip=203.0.113.7</>\n",
	} {
		if got := traceIp(body); got != "" {
			t.Errorf("traceIp(%q) = %q, want empty", body, got)
		}
	}
}
