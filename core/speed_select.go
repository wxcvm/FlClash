package core

import (
	"context"
	"encoding/json"
	"errors"
	"time"

	"github.com/metacubex/mihomo/common/utils"
	"github.com/metacubex/mihomo/constant"
)

type speedGroupState struct {
	Now            string `json:"now"`
	Fixed          string `json:"fixed"`
	TestURL        string `json:"testUrl"`
	ExpectedStatus string `json:"expectedStatus"`
}

func speedSelectionState(proxy constant.Proxy) (speedGroupState, error) {
	var state speedGroupState
	if proxy.Type() == constant.Selector {
		group, ok := adapterAs[pickableGroup](proxy)
		if !ok {
			return state, errGroupNotSelect
		}
		state.Now = group.Now()
		state.Fixed = state.Now
		return state, nil
	}
	data, err := proxy.Adapter().MarshalJSON()
	if err != nil {
		return state, err
	}
	err = json.Unmarshal(data, &state)
	return state, err
}

func speedGroupMember(group pickableGroup, name string) constant.Proxy {
	for _, member := range group.Proxies() {
		if member.Name() == name {
			return member
		}
	}
	return nil
}

// A download probe does not update URL-test health. Verify the group's own
// URL and expected HTTP status before pinning a throughput winner. The final
// check is made against the actual core selection, not the saved preference.
func handleSelectSpeedProxy(params *ChangeProxyParams) *ChangeProxyResult {
	fail := func(err error) *ChangeProxyResult {
		return &ChangeProxyResult{Message: err.Error()}
	}
	configMu.Lock()
	selectMu.Lock()
	groupProxy := lookupProxy(params.GroupName)
	group, err := selectableGroup(params.GroupName)
	if err != nil {
		selectMu.Unlock()
		configMu.Unlock()
		return fail(err)
	}
	if groupProxy.Type() != constant.Selector && groupProxy.Type() != constant.URLTest {
		selectMu.Unlock()
		configMu.Unlock()
		return fail(errGroupNotSelect)
	}
	member := speedGroupMember(group, params.ProxyName)
	before, err := speedSelectionState(groupProxy)
	epoch, _ := routeStamp()
	pathGeneration := networkPathGeneration
	selectMu.Unlock()
	configMu.Unlock()
	if err != nil {
		return fail(err)
	}
	if member == nil {
		return fail(errors.New("speed candidate is not a member of the group"))
	}

	if groupProxy.Type() == constant.URLTest {
		expected, err := utils.NewUnsignedRanges[uint16](before.ExpectedStatus)
		if err != nil {
			return fail(err)
		}
		ctx, cancel := context.WithTimeout(context.Background(), 8*time.Second)
		_, err = member.URLTest(ctx, before.TestURL, expected)
		cancel()
		if err != nil || !member.AliveForTestUrl(before.TestURL) {
			return fail(errors.New("speed candidate failed the group health check"))
		}
	}

	// Do not hold a selection lock across a network request. A manual pick,
	// config reload, or provider refresh during the health check wins.
	configMu.Lock()
	defer configMu.Unlock()
	selectMu.Lock()
	defer selectMu.Unlock()
	currentEpoch, _ := routeStamp()
	if currentEpoch != epoch || networkPathGeneration != pathGeneration ||
		lookupProxy(params.GroupName) != groupProxy ||
		speedGroupMember(group, params.ProxyName) != member {
		return fail(errors.New("speed selection changed during health check"))
	}
	current, err := speedSelectionState(groupProxy)
	if err != nil {
		return fail(err)
	}
	if current.Fixed != before.Fixed {
		return fail(errors.New("speed selection superseded by another choice"))
	}
	if groupProxy.Type() == constant.URLTest && !member.AliveForTestUrl(before.TestURL) {
		return fail(errors.New("speed candidate is no longer healthy"))
	}
	if err := group.Set(params.ProxyName); err != nil {
		return fail(err)
	}
	if group.Now() != params.ProxyName {
		group.ForceSet(current.Fixed)
		refreshRouteLocked(routeUnchanged)
		return fail(errors.New("core did not select the speed candidate"))
	}
	refreshRouteLocked(routeUnchanged)
	return &ChangeProxyResult{Changed: current.Now != params.ProxyName}
}
