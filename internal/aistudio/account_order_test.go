package aistudio

import (
	"context"
	"reflect"
	"testing"
	"time"
)

func orderedFixture() (*AccountPool, []string) {
	order := []string{"charlie.main@example.com", "alpha.sub@example.com", "bravo.sub@example.com", "delta.sub@example.com"}
	model := Model{ID: "gemini", Methods: []string{"generateContent"}, Capabilities: map[string]bool{"chat_model": true}}
	var accounts []*Account
	for _, id := range []string{order[3], order[2], order[1], order[0]} {
		accounts = append(accounts, &Account{ID: id, Config: AccountConfig{Enabled: true}, State: AccountReady, Models: []Model{model}, modelAccessGeneration: 1})
	}
	pool := NewAccountPool(accounts, 1)
	pool.SetRoutingStrategy("fill-first")
	pool.SetAccountOrder(order)
	pool.SetUpstreamChannels([]Channel{ChannelPlayground})
	return pool, order
}

func TestAccountOrderBothSortsAndRoundRobin(t *testing.T) {
	pool, order := orderedFixture()
	selection := AccountSelection{ModelID: "gemini", Method: "generateContent"}
	indices, err := pool.selectionIndicesLocked(selection)
	if err != nil {
		t.Fatal(err)
	}
	var ids []string
	for _, i := range indices {
		ids = append(ids, pool.accounts[i].ID)
	}
	if !reflect.DeepEqual(ids, order) {
		t.Fatalf("indices=%v", ids)
	}
	var channels []string
	for _, c := range pool.channelCandidatesLocked(indices, selection) {
		channels = append(channels, pool.accounts[c.index].ID)
	}
	if !reflect.DeepEqual(channels, order) {
		t.Fatalf("channels=%v", channels)
	}
	pool.SetAccountOrder([]string{" " + order[0] + " ", order[0], "", order[1]})
	if len(pool.accountOrder) != 2 || !pool.accountLessLocked(order[0], order[1]) || !pool.accountLessLocked(order[1], order[2]) || !pool.accountLessLocked(order[2], order[3]) {
		t.Fatalf("partial/duplicate order not normalized: %v", pool.accountOrder)
	}
	pool.SetRoutingStrategy("round-robin")
	for _, want := range []string{order[1], order[2], order[0], order[3], order[1]} {
		lease, _, err := pool.TryAcquireFor(context.Background(), selection)
		if err != nil || lease == nil {
			t.Fatalf("lease=%v err=%v", lease, err)
		}
		if got := lease.Account().ID; got != want {
			t.Fatalf("round-robin=%s want=%s", got, want)
		}
		if err := lease.Release(); err != nil {
			t.Fatal(err)
		}
	}
}

func TestAccountOrderBusyCooldownDisabledAndPinning(t *testing.T) {
	pool, order := orderedFixture()
	selection := AccountSelection{ModelID: "gemini", Method: "generateContent"}
	primary, _, err := pool.TryAcquireFor(context.Background(), selection)
	if err != nil || primary == nil || primary.Account().ID != order[0] {
		t.Fatalf("primary=%v err=%v", primary, err)
	}
	fallback, _, err := pool.TryAcquireFor(context.Background(), selection)
	if err != nil || fallback == nil || fallback.Account().ID != order[1] {
		t.Fatalf("fallback=%v err=%v", fallback, err)
	}
	fallback.Release()
	primary.Release()
	if err := pool.MarkCooldownIfGeneration(order[0], ChannelCooldownScope(ChannelPlayground, "gemini"), 1, time.Now(), time.Now().Add(time.Hour), "test"); err != nil {
		t.Fatal(err)
	}
	fallback, _, err = pool.TryAcquireFor(context.Background(), selection)
	if err != nil || fallback == nil || fallback.Account().ID != order[1] {
		t.Fatalf("cooldown fallback=%v err=%v", fallback, err)
	}
	fallback.Release()
	pool.byID[order[1]].Config.Enabled = false
	fallback, _, err = pool.TryAcquireFor(context.Background(), selection)
	if err != nil || fallback == nil || fallback.Account().ID != order[2] {
		t.Fatalf("disabled fallback=%v err=%v", fallback, err)
	}
	fallback.Release()
	pool.resources["file"] = order[3]
	for _, pinned := range []AccountSelection{{AccountID: order[3]}, {ResourceID: "file"}} {
		indices, err := pool.selectionIndicesLocked(pinned)
		if err != nil || len(indices) != 1 || pool.accounts[indices[0]].ID != order[3] {
			t.Fatalf("pin=%+v indices=%v err=%v", pinned, indices, err)
		}
	}
	if _, err := pool.selectionIndicesLocked(AccountSelection{AccountID: order[2], ResourceID: "file"}); err == nil {
		t.Fatal("conflicting ownership accepted")
	}
}

func TestAccountOrderPreferredStandby(t *testing.T) {
	pool, order := orderedFixture()
	groups, err := pool.ClassifyCandidates(context.Background(), AccountSelection{ModelID: "gemini", Method: "generateContent"}, []string{order[1]})
	if err != nil {
		t.Fatal(err)
	}
	if got := pool.PreferredStandbyAccount(groups.StandbyReady, groups.WarmReady); got != order[0] {
		t.Fatalf("standby=%s", got)
	}
	pool.byID[order[0]].active = 1
	groups, err = pool.ClassifyCandidates(context.Background(), AccountSelection{ModelID: "gemini", Method: "generateContent"}, []string{order[1]})
	if err != nil {
		t.Fatal(err)
	}
	if got := pool.PreferredStandbyAccount(groups.StandbyReady, groups.WarmReady); got != "" {
		t.Fatalf("busy primary should not delay warm fallback: %s", got)
	}
	pool.SetRoutingStrategy("round-robin")
	if got := pool.PreferredStandbyAccount([]string{order[0]}, []string{order[1]}); got != "" {
		t.Fatalf("round-robin override=%s", got)
	}
	pool.SetRoutingStrategy("fill-first")
	pool.SetAccountOrder(nil)
	if got := pool.PreferredStandbyAccount([]string{order[0]}, []string{order[1]}); got != "" {
		t.Fatalf("default override=%s", got)
	}
}
