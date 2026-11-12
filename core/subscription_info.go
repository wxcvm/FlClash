package core

import (
	"strings"

	"github.com/metacubex/mihomo/config"
	"go.yaml.in/yaml/v3"
)

// Subscription providers sometimes encode account information as reachable
// proxies. Match only explicit metadata labels, not ordinary node names.
const subscriptionInfoFilter = `^\s*(剩余流量|流量剩余|套餐到期|订阅到期|到期时间|剩余时间)\s*[:：]`

// Use the core's native exclusion filter so URL-test/fallback/load-balance
// cannot select the informational entries, including provider-backed groups.
// Keep the source profile and manually selectable groups intact.
func excludeSubscriptionInfoGroups(raw *config.RawConfig, root *yaml.Node) {
	var groups *yaml.Node
	if root != nil {
		groups = resolveAlias(mappingValue(root, "proxy-groups"))
	}
	for i, group := range raw.ProxyGroup {
		kind, _ := group["type"].(string)
		switch kind {
		case "url-test", "fallback", "load-balance":
		default:
			continue
		}
		existing, ok := group["exclude-filter"].(string)
		if !ok && group["exclude-filter"] != nil {
			continue
		}
		filter := subscriptionInfoFilter
		if existing != "" {
			if strings.Contains(existing, subscriptionInfoFilter) {
				filter = existing
			} else {
				filter = existing + "`" + subscriptionInfoFilter
			}
		}
		group["exclude-filter"] = filter
		// An empty automatic group must not become an accidental direct route
		// just because all its candidates were subscription information.
		if group["empty-fallback"] == nil || group["empty-fallback"] == "" {
			group["empty-fallback"] = "REJECT"
		}
		if groups == nil || groups.Kind != yaml.SequenceNode || i >= len(groups.Content) {
			continue
		}
		node := resolveAlias(groups.Content[i])
		if node == nil || node.Kind != yaml.MappingNode {
			continue
		}
		setMappingValue(node, "exclude-filter", &yaml.Node{
			Kind: yaml.ScalarNode, Tag: "!!str", Value: filter,
		})
		if fallback, ok := group["empty-fallback"].(string); ok {
			setMappingValue(node, "empty-fallback", &yaml.Node{
				Kind: yaml.ScalarNode, Tag: "!!str", Value: fallback,
			})
		}
	}
}
