// Package main implements drain-guard (PLAN.md phase 7): a controller and an eviction
// webhook that make node drains role-aware for MariaDB. The decisions live here as pure
// functions so that they can be unit tested without a cluster.
package main

import (
	"sort"
	"strconv"
	"strings"
	"time"

	"k8s.io/apimachinery/pkg/util/version"
)

// abortedAnnotation records, on the MariaDB, the replica whose switchover the guard aborted
// and when, as "<index>@<RFC3339>". It lives on the object, not in one replica's memory: the
// webhook may be served by a replica that did not make the abort, and it must still see it.
const abortedAnnotation = "dbaas.local/drain-guard-aborted"

// parseAborted reads abortedAnnotation. It returns index -1 when the value is missing or malformed.
func parseAborted(v string) (int, time.Time) {
	idx, ts, ok := strings.Cut(v, "@")
	if !ok {
		return -1, time.Time{}
	}
	n, err := strconv.Atoi(idx)
	if err != nil || n < 0 {
		return -1, time.Time{}
	}
	at, err := time.Parse(time.RFC3339, ts)
	if err != nil {
		return -1, time.Time{}
	}
	return n, at
}

// switchoverTimeout bounds how long a planned switchover may stay pending. The operator
// makes the primary read-only while it waits for the replicas to catch up; an unbounded wait
// holds writes. Past this bound the guard aborts the switchover and the drain waits instead.
const switchoverTimeout = 2 * time.Minute

// switchoverStalled reports whether a switchover that has been pending since 'since' has
// run past the timeout at 'now'.
func switchoverStalled(since, now time.Time, timeout time.Duration) bool {
	return !since.IsZero() && now.Sub(since) >= timeout
}

// abortedTargetTTL is how long a replica whose switchover the guard aborted is left out of
// the candidates. Without it the guard picks the same replica again a minute later, and the
// primary goes read-only for two minutes per cycle while the drain never completes.
const abortedTargetTTL = 10 * time.Minute

// dropExcluded returns the pods whose index is not excluded.
func dropExcluded(pods []PodState, excluded map[int]bool) []PodState {
	if len(excluded) == 0 {
		return pods
	}
	out := make([]PodState, 0, len(pods))
	for _, p := range pods {
		if !excluded[p.Index] {
			out = append(out, p)
		}
	}
	return out
}

// evacuationCooldown is how long an evacuation request suppresses another one for the same
// instance (PLAN.md phase 7, step 2.1).
const evacuationCooldown = 60 * time.Second

// NodeInfo is what the guard needs to know about a node.
type NodeInfo struct {
	Name           string
	Unschedulable  bool
	TaintKeys      []string
	KubeletVersion string
	Created        time.Time
}

// draining reports whether a node is being drained: cordoned, or carrying one of the
// configured taints (PLAN.md phase 7, step 2).
func draining(n NodeInfo, drainKeys map[string]bool) bool {
	if n.Unschedulable {
		return true
	}
	for _, k := range n.TaintKeys {
		if drainKeys[k] {
			return true
		}
	}
	return false
}

// PodState is one database pod of an instance.
type PodState struct {
	Name     string
	Index    int
	Ready    bool
	NodeName string
}

// InstanceState is one MariaDB resource as the guard sees it.
type InstanceState struct {
	Namespace string
	Name      string
	// CurrentPrimary is status.currentPrimaryPodIndex; -1 when not known yet.
	CurrentPrimary int
	// DesiredPrimary is spec.replication.primary.podIndex; -1 when not set.
	DesiredPrimary int
	// SwitchoverFailing is true while the PrimarySwitched condition is False.
	SwitchoverFailing bool
	// AbortedTarget is the replica index whose switchover the guard aborted, and AbortedAt when;
	// AbortedTarget is -1 when there is none.
	AbortedTarget int
	AbortedAt     time.Time
	Pods          []PodState
}

// excluded returns the replica indexes that must not be chosen at 'now': a replica whose
// switchover was aborted stays out for abortedTargetTTL.
func (s InstanceState) excluded(now time.Time) map[int]bool {
	out := map[int]bool{}
	if s.AbortedTarget >= 0 && now.Sub(s.AbortedAt) < abortedTargetTTL {
		out[s.AbortedTarget] = true
	}
	return out
}

// switchoverPending is true while the operator has not reached the desired primary.
func (s InstanceState) switchoverPending() bool {
	if s.SwitchoverFailing {
		return true
	}
	return s.DesiredPrimary >= 0 && s.DesiredPrimary != s.CurrentPrimary
}

// pod returns the pod with the given index.
func (s InstanceState) pod(index int) (PodState, bool) {
	for _, p := range s.Pods {
		if p.Index == index {
			return p, true
		}
	}
	return PodState{}, false
}

// Evacuation decisions.
const (
	actionSwitch  = "switch"       // patch the desired primary to the target
	actionPending = "pending"      // a switchover is already pending or running
	actionRecent  = "recent"       // a request was made within the cooldown
	actionBlocked = "blocked"      // no candidate exists; retry later
	actionIdle    = "not-draining" // the primary's node is fine; nothing to do
)

// EvacuationPlan is the result of planning one evacuation.
type EvacuationPlan struct {
	Action      string
	TargetIndex int
	Reason      string
}

// planEvacuation decides whether the primary of an instance must move, and where to.
// Candidates are replicas that are Ready and whose nodes are not draining. They are
// ordered by the newest kubelet version, then the newest node, then the lowest pod index:
// freshly rotated nodes are the youngest, so a rolling replacement moves the primary once.
func planEvacuation(s InstanceState, nodes map[string]NodeInfo, drainKeys map[string]bool,
	now, lastRequested time.Time) EvacuationPlan {
	if s.CurrentPrimary < 0 {
		return EvacuationPlan{Action: actionIdle, Reason: "the primary is not known yet"}
	}
	primary, ok := s.pod(s.CurrentPrimary)
	if !ok {
		return EvacuationPlan{Action: actionIdle, Reason: "the primary pod is not listed"}
	}
	node, ok := nodes[primary.NodeName]
	if !ok || !draining(node, drainKeys) {
		return EvacuationPlan{Action: actionIdle, Reason: "the primary's node is not draining"}
	}
	if s.switchoverPending() {
		return EvacuationPlan{Action: actionPending, Reason: "a switchover is already pending or running"}
	}
	if !lastRequested.IsZero() && now.Sub(lastRequested) < evacuationCooldown {
		return EvacuationPlan{Action: actionRecent, Reason: "an evacuation was requested less than a minute ago"}
	}

	var candidates []PodState
	for _, p := range s.Pods {
		if p.Index == s.CurrentPrimary || !p.Ready {
			continue
		}
		n, ok := nodes[p.NodeName]
		if !ok || draining(n, drainKeys) {
			continue
		}
		candidates = append(candidates, p)
	}
	if len(candidates) == 0 {
		return EvacuationPlan{Action: actionBlocked, Reason: "no ready replica sits on a node that is not draining"}
	}
	sort.SliceStable(candidates, func(i, j int) bool {
		return betterCandidate(candidates[i], candidates[j], nodes)
	})
	return EvacuationPlan{Action: actionSwitch, TargetIndex: candidates[0].Index}
}

// betterCandidate orders replicas for promotion: newest kubelet, newest node, lowest index.
func betterCandidate(a, b PodState, nodes map[string]NodeInfo) bool {
	na, nb := nodes[a.NodeName], nodes[b.NodeName]
	va, errA := version.ParseSemantic(na.KubeletVersion)
	vb, errB := version.ParseSemantic(nb.KubeletVersion)
	if errA == nil && errB == nil && !va.EqualTo(vb) {
		return va.GreaterThan(vb)
	}
	if !na.Created.Equal(nb.Created) {
		return na.Created.After(nb.Created)
	}
	return a.Index < b.Index
}

// EvictionDecision is the webhook's answer to one eviction request.
type EvictionDecision struct {
	Allow    bool
	Code     int32  // HTTP status when denied: 429, which drain tools retry
	Reason   string // Kubernetes status reason when denied
	Message  string
	Evacuate bool // true when the guard should move the primary away first
}

// decideEviction implements PLAN.md phase 7, step 3. isDatabase is false for pods that
// are not database pods of a managed instance; inst is nil when the owning MariaDB could
// not be read.
func decideEviction(podName string, isDatabase bool, inst *InstanceState, dryRun bool) EvictionDecision {
	if !isDatabase || inst == nil {
		return EvictionDecision{Allow: true}
	}
	pod, ok := inst.pod(indexOf(podName, inst.Name))
	primaryIndex := inst.CurrentPrimary
	desired := inst.DesiredPrimary
	isPrimary := ok && pod.Index == primaryIndex
	if (ok && desired >= 0 && pod.Index == desired) || isPrimary || inst.switchoverPending() {
		msg := "instance " + inst.Name + " in " + inst.Namespace + " is switching its primary; the primary pod is not evicted"
		if isPrimary || (ok && pod.Index == desired) {
			msg = "pod " + podName + " holds the primary role of instance " + inst.Name + "; the role moves first, retry the eviction"
		}
		return EvictionDecision{
			Allow:    false,
			Code:     429,
			Reason:   "TooManyRequests",
			Message:  msg,
			Evacuate: !dryRun,
		}
	}
	return EvictionDecision{Allow: true}
}

// indexOf returns the pod index of a database pod named <instance>-<index>, or -1.
func indexOf(podName, instance string) int {
	prefix := instance + "-"
	if len(podName) <= len(prefix) || podName[:len(prefix)] != prefix {
		return -1
	}
	n := 0
	for _, c := range podName[len(prefix):] {
		if c < '0' || c > '9' {
			return -1
		}
		n = n*10 + int(c-'0')
	}
	return n
}
