package main

import (
	"context"
	"encoding/json"
	"fmt"
	"time"

	corev1 "k8s.io/api/core/v1"
	"k8s.io/apimachinery/pkg/api/meta"
	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
	"k8s.io/apimachinery/pkg/runtime"
	"k8s.io/apimachinery/pkg/runtime/schema"
	"k8s.io/apimachinery/pkg/types"
	"sigs.k8s.io/controller-runtime/pkg/client"
)

// PostgreSQL (CloudNativePG) clusters.
//
// CloudNativePG protects the primary with a PodDisruptionBudget, so a drain of the primary's node is
// refused (not unsafe) and waits forever: nothing moves the primary. PLAN.md assumed that
// CloudNativePG "switches the primary away ahead of a drain"; it does not. A drain run found the
// suite stuck on a PostgreSQL primary that shared a node. So the guard does for PostgreSQL what it
// does for MariaDB: when the primary's node is cordoned or tainted for a drain, it asks for a
// switchover to the best replica, the same way `kubectl cnpg promote` does (a patch of the Cluster's
// status). No eviction webhook is needed: kubectl drain cordons the node first and retries the
// eviction, and the old primary's pod is released as soon as the role has moved.

var cnpgGVK = schema.GroupVersionKind{Group: "postgresql.cnpg.io", Version: "v1", Kind: "Cluster"}

const (
	// pgSwitchoverPhase is CloudNativePG's phase while a switchover runs (api/v1 PhaseSwitchover).
	pgSwitchoverPhase = "Switchover in progress"
	// pgTimeLayout is the timestamp layout CloudNativePG writes into its status.
	pgTimeLayout = "2006-01-02T15:04:05.000000Z07:00"
)

// pgInstanceState adapts a CloudNativePG Cluster to the InstanceState the planner works on. A pod
// "<cluster>-<n>" has index n. current and target are the pod names of status.currentPrimary and
// status.targetPrimary; an empty target means no switchover is under way. The planner then applies
// the same rules as for MariaDB: Ready replicas on nodes that are not draining, newest kubelet first.
// UnavailableReplicas stays 0: CloudNativePG's switchover does not wait for every replica.
func pgInstanceState(ns, name, current, target string, pods []PodState) InstanceState {
	s := InstanceState{
		Namespace: ns, Name: name, Pods: pods,
		CurrentPrimary: indexOf(current, name), DesiredPrimary: -1,
		AbortedTarget: -1, BaselinePrimary: -1,
	}
	if target != "" {
		s.DesiredPrimary = indexOf(target, name)
	}
	return s
}

// reconcilePostgres moves the primary of every CloudNativePG cluster off a draining node. A cluster
// API that is not installed is not an error: the platform may run MariaDB only.
func (g *Guard) reconcilePostgres(ctx context.Context, nodes map[string]NodeInfo) error {
	var list unstructured.UnstructuredList
	list.SetGroupVersionKind(cnpgGVK)
	if err := g.Reader.List(ctx, &list, client.MatchingLabels{"dbaas.local/engine": "postgres"}); err != nil {
		if meta.IsNoMatchError(err) {
			return nil
		}
		return fmt.Errorf("listing the PostgreSQL clusters: %w", err)
	}
	for i := range list.Items {
		obj := &list.Items[i]
		ns, name := obj.GetNamespace(), obj.GetName()
		current, _, _ := unstructured.NestedString(obj.Object, "status", "currentPrimary")
		target, _, _ := unstructured.NestedString(obj.Object, "status", "targetPrimary")

		var pods corev1.PodList
		if err := g.Reader.List(ctx, &pods, client.InNamespace(ns), client.MatchingLabels{"cnpg.io/cluster": name}); err != nil {
			return err
		}
		var states []PodState
		for j := range pods.Items {
			p := &pods.Items[j]
			// Instance pods only: the cluster's job pods (initdb, join) carry no instance role.
			if p.Labels["cnpg.io/podRole"] != "instance" {
				continue
			}
			if idx := indexOf(p.Name, name); idx >= 0 {
				states = append(states, PodState{Name: p.Name, Index: idx, Ready: podReady(p), NodeName: p.Spec.NodeName})
			}
		}
		s := pgInstanceState(ns, name, current, target, states)
		plan := planEvacuation(s, nodes, g.DrainKeys, g.Now(), g.lastRequestedAt(&s))
		switch plan.Action {
		case actionSwitch:
			if err := g.requestPGSwitchover(ctx, &s, obj, plan); err != nil {
				g.Recorder.Eventf(runtime.Object(obj), corev1.EventTypeWarning, "EvacuationFailed",
					"could not move the primary away from its draining node: %v", err)
			}
		case actionBlocked:
			g.mu.Lock()
			first := !g.blocked[key(ns, name)]
			g.blocked[key(ns, name)] = true
			g.mu.Unlock()
			g.Recorder.Eventf(runtime.Object(obj), corev1.EventTypeWarning, "EvacuationBlocked",
				"the primary's node is draining but no replica can take the role: %s", plan.Reason)
			if first {
				g.Metrics.observeEvacuation(ns, "blocked", 0)
			}
		default:
			g.mu.Lock()
			g.blocked[key(ns, name)] = false
			g.mu.Unlock()
		}
	}
	return nil
}

// requestPGSwitchover asks CloudNativePG for a switchover to the planned replica by patching the
// Cluster's status, the way `kubectl cnpg promote` does.
func (g *Guard) requestPGSwitchover(ctx context.Context, s *InstanceState, obj *unstructured.Unstructured, plan EvacuationPlan) error {
	k := key(s.Namespace, s.Name)
	target := fmt.Sprintf("%s-%d", s.Name, plan.TargetIndex)
	now := g.Now()
	patch, _ := json.Marshal(map[string]any{"status": map[string]any{
		"targetPrimary":          target,
		"targetPrimaryTimestamp": now.UTC().Format(pgTimeLayout),
		"phase":                  pgSwitchoverPhase,
		"phaseReason":            fmt.Sprintf("Switching over to %s", target),
	}})
	if err := g.Client.Status().Patch(ctx, obj, client.RawPatch(types.MergePatchType, patch)); err != nil {
		g.Metrics.observeEvacuation(s.Namespace, "error", 0)
		return fmt.Errorf("moving the primary of %s: %w", k, err)
	}
	g.mu.Lock()
	g.lastRequested[k] = now
	g.blocked[k] = false
	g.mu.Unlock()
	g.Recorder.Eventf(runtime.Object(obj), corev1.EventTypeNormal, "PrimaryEvacuated",
		"moving the primary from pod index %d to %d: its node is draining", s.CurrentPrimary, plan.TargetIndex)
	g.Metrics.observeEvacuation(s.Namespace, "switch", time.Since(now))
	return nil
}
