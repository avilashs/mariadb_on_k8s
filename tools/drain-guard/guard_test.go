package main

import (
	"testing"
	"time"
)

var (
	t0    = time.Date(2026, 11, 18, 12, 0, 0, 0, time.UTC)
	keys  = map[string]bool{"node.kubernetes.io/unschedulable": true, "ToBeDeletedByClusterAutoscaler": true, "karpenter.sh/disrupted": true}
	nodeA = NodeInfo{Name: "n-a", KubeletVersion: "v1.36.4", Created: t0.Add(-48 * time.Hour)}
	nodeB = NodeInfo{Name: "n-b", KubeletVersion: "v1.36.4", Created: t0.Add(-24 * time.Hour)}
	nodeC = NodeInfo{Name: "n-c", KubeletVersion: "v1.36.4", Created: t0.Add(-72 * time.Hour)}
)

func nodesOf(ns ...NodeInfo) map[string]NodeInfo {
	out := map[string]NodeInfo{}
	for _, n := range ns {
		out[n.Name] = n
	}
	return out
}

// instance returns three pods of "alpha": 0 on n-a, 1 on n-b, 2 on n-c, primary 0.
func instance(primary int) InstanceState {
	return InstanceState{
		Namespace: "db-alpha", Name: "alpha", CurrentPrimary: primary, DesiredPrimary: primary,
		Pods: []PodState{
			{Name: "alpha-0", Index: 0, Ready: true, NodeName: "n-a"},
			{Name: "alpha-1", Index: 1, Ready: true, NodeName: "n-b"},
			{Name: "alpha-2", Index: 2, Ready: true, NodeName: "n-c"},
		},
	}
}

func TestDrainingIsCordonedOrTaintedWithAKnownKey(t *testing.T) {
	cases := []struct {
		name string
		n    NodeInfo
		want bool
	}{
		{"cordoned", NodeInfo{Unschedulable: true}, true},
		{"autoscaler taint", NodeInfo{TaintKeys: []string{"ToBeDeletedByClusterAutoscaler"}}, true},
		{"karpenter taint", NodeInfo{TaintKeys: []string{"karpenter.sh/disrupted"}}, true},
		{"unrelated taint", NodeInfo{TaintKeys: []string{"workload"}}, false},
		{"healthy", NodeInfo{}, false},
	}
	for _, c := range cases {
		if got := draining(c.n, keys); got != c.want {
			t.Errorf("%s: draining = %v, want %v", c.name, got, c.want)
		}
	}
}

func TestCandidateOrderNewestKubeletThenNewestNodeThenLowestIndex(t *testing.T) {
	older := NodeInfo{Name: "old", KubeletVersion: "v1.35.2", Created: t0}
	newest := NodeInfo{Name: "new", KubeletVersion: "v1.36.4", Created: t0.Add(-time.Hour)}
	nodes := nodesOf(older, newest)
	a := PodState{Index: 1, NodeName: "old"}
	b := PodState{Index: 2, NodeName: "new"}
	if !betterCandidate(b, a, nodes) {
		t.Error("the newer kubelet must win over the older one")
	}

	sameVersionOld := NodeInfo{Name: "x", KubeletVersion: "v1.36.4", Created: t0.Add(-72 * time.Hour)}
	sameVersionNew := NodeInfo{Name: "y", KubeletVersion: "v1.36.4", Created: t0}
	nodes = nodesOf(sameVersionOld, sameVersionNew)
	if !betterCandidate(PodState{Index: 2, NodeName: "y"}, PodState{Index: 1, NodeName: "x"}, nodes) {
		t.Error("with equal kubelets the newer node must win, whatever the index")
	}

	nodes = nodesOf(NodeInfo{Name: "p", KubeletVersion: "v1.36.4", Created: t0}, NodeInfo{Name: "q", KubeletVersion: "v1.36.4", Created: t0})
	if !betterCandidate(PodState{Index: 1, NodeName: "p"}, PodState{Index: 2, NodeName: "q"}, nodes) {
		t.Error("with equal kubelets and nodes the lowest index must win")
	}
}

func TestPrimaryOnHealthyNodeIsLeftAlone(t *testing.T) {
	plan := planEvacuation(instance(0), nodesOf(nodeA, nodeB, nodeC), keys, t0, time.Time{})
	if plan.Action != actionIdle {
		t.Fatalf("a healthy primary node must not trigger a move, got %+v", plan)
	}
}

func TestDrainingPrimaryMovesToTheBestReplica(t *testing.T) {
	drainingA := nodeA
	drainingA.Unschedulable = true
	plan := planEvacuation(instance(0), nodesOf(drainingA, nodeB, nodeC), keys, t0, time.Time{})
	if plan.Action != actionSwitch {
		t.Fatalf("want a switch, got %+v", plan)
	}
	// nodeB is newer than nodeC, and the versions are equal.
	if plan.TargetIndex != 1 {
		t.Fatalf("want the replica on the newest node (index 1), got %d", plan.TargetIndex)
	}
}

func TestSkipsReplicasThatAreNotReadyOrOnDrainingNodes(t *testing.T) {
	drainingA := nodeA
	drainingA.Unschedulable = true
	drainingB := nodeB
	drainingB.Unschedulable = true
	s := instance(0)
	s.Pods[2].Ready = false // index 2 is not ready
	plan := planEvacuation(s, nodesOf(drainingA, drainingB, nodeC), keys, t0, time.Time{})
	if plan.Action != actionBlocked {
		t.Fatalf("index 1 is draining, index 2 is not ready: want blocked, got %+v", plan)
	}
}

func TestBlockedWhenNoReplicaCanTakeTheRole(t *testing.T) {
	drainingA := nodeA
	drainingA.Unschedulable = true
	s := instance(0)
	s.Pods = s.Pods[:1]
	plan := planEvacuation(s, nodesOf(drainingA), keys, t0, time.Time{})
	if plan.Action != actionBlocked {
		t.Fatalf("a single pod with a draining node must be blocked, got %+v", plan)
	}
}

func TestPendingSwitchoverIsNotDoubled(t *testing.T) {
	drainingA := nodeA
	drainingA.Unschedulable = true
	s := instance(0)
	s.DesiredPrimary = 2 // the operator has not reached it yet
	plan := planEvacuation(s, nodesOf(drainingA, nodeB, nodeC), keys, t0, time.Time{})
	if plan.Action != actionPending {
		t.Fatalf("want pending while a switchover runs, got %+v", plan)
	}
	s = instance(0)
	s.SwitchoverFailing = true
	plan = planEvacuation(s, nodesOf(drainingA, nodeB, nodeC), keys, t0, time.Time{})
	if plan.Action != actionPending {
		t.Fatalf("a failing switchover counts as pending, got %+v", plan)
	}
}

func TestEvacuationCooldownSuppressesRepeatRequests(t *testing.T) {
	drainingA := nodeA
	drainingA.Unschedulable = true
	plan := planEvacuation(instance(0), nodesOf(drainingA, nodeB, nodeC), keys, t0, t0.Add(-30*time.Second))
	if plan.Action != actionRecent {
		t.Fatalf("a request thirty seconds ago must suppress another, got %+v", plan)
	}
	plan = planEvacuation(instance(0), nodesOf(drainingA, nodeB, nodeC), keys, t0, t0.Add(-61*time.Second))
	if plan.Action != actionSwitch {
		t.Fatalf("after the cooldown a request is made again, got %+v", plan)
	}
}

func TestForcedEvacuationTreatsThePrimaryNodeAsDraining(t *testing.T) {
	// The eviction itself is the drain: the node is not cordoned yet.
	plan := planEvacuationForced(instance(0), nodesOf(nodeA, nodeB, nodeC), keys, t0, time.Time{})
	if plan.Action != actionSwitch || plan.TargetIndex != 1 {
		t.Fatalf("forced evacuation must move the primary, got %+v", plan)
	}
}

func TestEvictionOfAnyNonDatabasePodIsAllowed(t *testing.T) {
	d := decideEviction("nginx-0", false, nil, false)
	if !d.Allow {
		t.Fatalf("non-database pods are not the guard's business: %+v", d)
	}
	s := instance(0)
	d = decideEviction("alpha-0", true, nil, false)
	if !d.Allow {
		t.Fatalf("an unknown owner must not block: %+v", d)
	}
	_ = s
}

func TestEvictionOfThePrimaryIsRefusedWith429AndEvacuates(t *testing.T) {
	s := instance(0)
	d := decideEviction("alpha-0", true, &s, false)
	if d.Allow || d.Code != 429 || d.Reason != "TooManyRequests" {
		t.Fatalf("the primary's eviction must be refused with 429, got %+v", d)
	}
	if !d.Evacuate {
		t.Fatal("a refused primary eviction must start the evacuation")
	}
}

func TestDryRunIsRefusedButDoesNotEvacuate(t *testing.T) {
	s := instance(0)
	d := decideEviction("alpha-0", true, &s, true)
	if d.Allow || d.Evacuate {
		t.Fatalf("a dry run must be answered and must not trigger a switchover: %+v", d)
	}
}

func TestEvictionOfAReplicaIsAllowedWhileTheRoleIsStable(t *testing.T) {
	s := instance(0)
	d := decideEviction("alpha-2", true, &s, false)
	if !d.Allow {
		t.Fatalf("a replica may be evicted when the budget allows it, got %+v", d)
	}
}

func TestEvictionIsRefusedDuringASwitchoverEvenForAReplica(t *testing.T) {
	s := instance(0)
	s.DesiredPrimary = 1
	d := decideEviction("alpha-2", true, &s, false)
	if d.Allow || d.Code != 429 {
		t.Fatalf("during a switchover no database pod of the instance may go, got %+v", d)
	}
}

func TestEvictionOfTheDesiredPrimaryIsRefused(t *testing.T) {
	s := instance(0)
	s.DesiredPrimary = 2
	d := decideEviction("alpha-2", true, &s, false)
	if d.Allow {
		t.Fatalf("the desired primary must be protected too, got %+v", d)
	}
}

func TestIndexOfParsesOrdinals(t *testing.T) {
	cases := map[string]int{"alpha-0": 0, "alpha-12": 12, "alpha": -1, "beta-1": -1, "alpha-x": -1, "alpha-": -1}
	for name, want := range cases {
		if got := indexOf(name, "alpha"); got != want {
			t.Errorf("indexOf(%q) = %d, want %d", name, got, want)
		}
	}
}

func TestSwitchoverIsStalledOnlyPastTheTimeout(t *testing.T) {
	since := t0
	if switchoverStalled(since, t0.Add(119*time.Second), switchoverTimeout) {
		t.Error("a switchover two minutes minus a second old is not stalled yet")
	}
	if !switchoverStalled(since, t0.Add(2*time.Minute), switchoverTimeout) {
		t.Error("a switchover exactly at the timeout is stalled")
	}
	if switchoverStalled(time.Time{}, t0.Add(time.Hour), switchoverTimeout) {
		t.Error("a switchover never seen pending is not stalled")
	}
}
