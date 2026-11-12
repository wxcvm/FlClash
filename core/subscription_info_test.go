package core

import (
	"regexp"
	"testing"

	"github.com/metacubex/mihomo/config"
	"go.yaml.in/yaml/v3"
)

func TestSubscriptionInfoExclusion(t *testing.T) {
	match := regexp.MustCompile(subscriptionInfoFilter)
	for _, name := range []string{"剩余流量：959.93 GB", "套餐到期: 长期有效", "  订阅到期：2027-01-01"} {
		if !match.MatchString(name) {
			t.Errorf("metadata not matched: %q", name)
		}
	}
	for _, name := range []string{"日本专线-0.1倍率", "美国凤凰城", "香港剩余流量优化节点"} {
		if match.MatchString(name) {
			t.Errorf("ordinary node matched: %q", name)
		}
	}
	var document yaml.Node
	if err := yaml.Unmarshal([]byte(`proxy-groups:
  - name: 自动选择
    type: url-test
    exclude-filter: unwanted
  - name: 故障转移
    type: fallback
    empty-fallback: DIRECT
  - name: 手动选择
    type: select
`), &document); err != nil {
		t.Fatal(err)
	}
	raw := config.DefaultRawConfig()
	if err := document.Decode(raw); err != nil {
		t.Fatal(err)
	}
	excludeSubscriptionInfoGroups(raw, document.Content[0])
	excludeSubscriptionInfoGroups(raw, document.Content[0])
	if got := raw.ProxyGroup[0]["exclude-filter"]; got != "unwanted`"+subscriptionInfoFilter {
		t.Fatalf("filter not preserved or duplicated: %v", got)
	}
	if raw.ProxyGroup[0]["empty-fallback"] != "REJECT" || raw.ProxyGroup[1]["empty-fallback"] != "DIRECT" {
		t.Fatal("automatic empty fallback was not preserved safely")
	}
	if raw.ProxyGroup[2]["exclude-filter"] != nil {
		t.Fatal("manual group was changed")
	}
	persisted := config.DefaultRawConfig()
	if err := document.Decode(persisted); err != nil {
		t.Fatal(err)
	}
	if persisted.ProxyGroup[0]["exclude-filter"] != raw.ProxyGroup[0]["exclude-filter"] {
		t.Fatal("runtime filter not persisted to merged document")
	}
}

func TestRuntimeAutomaticGroupExcludesSubscriptionInfo(t *testing.T) {
	cfg, err := parseConfigBytes([]byte(`proxies:
  - name: "剩余流量：959.93 GB"
    type: ss
    server: 127.0.0.1
    port: 8388
    cipher: aes-128-gcm
    password: test
  - name: "套餐到期：长期有效"
    type: ss
    server: 127.0.0.1
    port: 8389
    cipher: aes-128-gcm
    password: test
  - name: "日本专线"
    type: ss
    server: 127.0.0.1
    port: 8390
    cipher: aes-128-gcm
    password: test
proxy-groups:
  - name: 自动选择
    type: url-test
    proxies: ["剩余流量：959.93 GB", "套餐到期：长期有效", "日本专线"]
    url: https://example.com/generate_204
    interval: 300
  - name: 故障转移
    type: fallback
    proxies: ["剩余流量：959.93 GB", "日本专线"]
    url: https://example.com/generate_204
    interval: 300
  - name: 手动选择
    type: select
    proxies: ["剩余流量：959.93 GB", "日本专线"]
rules: ["MATCH,自动选择"]
`))
	if err != nil {
		t.Fatal(err)
	}
	for _, name := range []string{"自动选择", "故障转移"} {
		group, ok := adapterAs[pickableGroup](cfg.Proxies[name])
		if !ok {
			t.Fatalf("group %s unavailable", name)
		}
		members := group.Proxies()
		if len(members) != 1 || members[0].Name() != "日本专线" {
			t.Fatalf("group %s still includes metadata: %v", name, members)
		}
	}
	group, ok := adapterAs[pickableGroup](cfg.Proxies["手动选择"])
	if !ok || len(group.Proxies()) != 2 {
		t.Fatal("manual group lost its subscription entries")
	}
}
