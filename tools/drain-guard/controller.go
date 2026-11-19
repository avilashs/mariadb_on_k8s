package main

import (
	"context"
	"encoding/json"
	"fmt"
	"strconv"
	"sync"
	"time"

	corev1 "k8s.io/api/core/v1"
	apierrors "k8s.io/apimachinery/pkg/api/errors"
	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
	"k8s.io/apimachinery/pkg/runtime"
	"k8s.io/apimachinery/pkg/runtime/schema"
	"k8s.io/apimachinery/pkg/types"
	"k8s.io/client-go/tools/record"
	"sigs.k8s.io/controller-runtime/pkg/client"
)

var mariadbGVK = schema.GroupVersionKind{Group: "k8s.mariadb.com", Version: "v1alpha1", Kind: "MariaDB"}

// Guard holds the state shared by the reconciler and the eviction webhook.
type Guard struct {
	Client    client.Client // cached, for the reconciler's lists
	Reader    client.Reader // live, for the webhook: decisions must not use stale data
	DrainKeys map[string]bool
	Metrics   *guardMetrics
	Recorder  record.EventRecorder
	Now       func() time.Time

	mu            sync.Mutex
	lastRequested map[string]time.Time
	blocked       map[string]bool
	pendingSince  map[string]time.Time // when a switchover was first seen pending, per replica
}

// NewGuard returns a guard with empty state.
func NewGuard(c client.Client, r client.Reader, drainKeys map[string]bool, m *guardMetrics, rec record.EventRecorder) *Guard {
	return &Guard{
		Client: c, Reader: r, DrainKeys: drainKeys, Metrics: m, Recorder: rec,
		Now: time.Now, lastRequested: map[string]time.Time{}, blocked: map[string]bool{},
		pendingSince: map[string]time.Time{},
	}
}

func key(ns, name string) string { return ns + "/" + name }

// loadNodes reads every node into the form the decisions use.
func (g *Guard) loadNodes(ctx context.Context) (map[string]NodeInfo, error) {
	var list corev1.NodeList
	if err := g.Reader.List(ctx, &list); err != nil {
		return nil, err
	}
	out := make(map[string]NodeInfo, len(list.Items))
	for _, n := range list.Items {
		info := NodeInfo{
			Name:           n.Name,
			Unschedulable:  n.Spec.Unschedulable,
			KubeletVersion: n.Status.NodeInfo.KubeletVersion,
			Created:        n.CreationTimestamp.Time,
		}
		for _, t := range n.Spec.Taints {
			info.TaintKeys = append(info.TaintKeys, t.Key)
		}
		out[n.Name] = info
	}
	return out, nil
}

// loadInstance reads one MariaDB and its database pods. It returns (nil, nil) when the
// resource does not exist, which makes its pods unmanaged.
func (g *Guard) loadInstance(ctx context.Context, ns, name string) (*InstanceState, *unstructured.Unstructured, error) {
	obj := &unstructured.Unstructured{}
	obj.SetGroupVersionKind(mariadbGVK)
	if err := g.Reader.Get(ctx, types.NamespacedName{Namespace: ns, Name: name}, obj); err != nil {
		if apierrors.IsNotFound(err) {
			return nil, nil, nil
		}
		return nil, nil, err
	}
	s := &InstanceState{Namespace: ns, Name: name, CurrentPrimary: -1, DesiredPrimary: -1}
	// The abort is recorded on the object, so every replica sees it (see abortedAnnotation).
	s.AbortedTarget, s.AbortedAt = parseAborted(obj.GetAnnotations()[abortedAnnotation])
	if v, found, _ := unstructured.NestedInt64(obj.Object, "status", "currentPrimaryPodIndex"); found {
		s.CurrentPrimary = int(v)
	}
	if v, found, _ := unstructured.NestedInt64(obj.Object, "spec", "replication", "primary", "podIndex"); found {
		s.DesiredPrimary = int(v)
	}
	conditions, _, _ := unstructured.NestedSlice(obj.Object, "status", "conditions")
	for _, c := range conditions {
		m, ok := c.(map[string]any)
		if !ok {
			continue
		}
		if m["type"] == "PrimarySwitched" && m["status"] == "False" {
			s.SwitchoverFailing = true
		}
	}

	var pods corev1.PodList
	if err := g.Reader.List(ctx, &pods, client.InNamespace(ns), client.MatchingLabels{
		"app.kubernetes.io/name":     "mariadb",
		"app.kubernetes.io/instance": name,
	}); err != nil {
		return nil, nil, err
	}
	for _, p := range pods.Items {
		idx := indexOf(p.Name, name)
		if v, err := strconv.Atoi(p.Labels["apps.kubernetes.io/pod-index"]); err == nil {
			idx = v
		}
		if idx < 0 {
			continue
		}
		s.Pods = append(s.Pods, PodState{Name: p.Name, Index: idx, Ready: podReady(&p), NodeName: p.Spec.NodeName})
	}
	return s, obj, nil
}

func podReady(p *corev1.Pod) bool {
	for _, c := range p.Status.Conditions {
		if c.Type == corev1.PodReady {
			return c.Status == corev1.ConditionTrue
		}
	}
	return false
}

// Reconcile looks at every MariaDB and moves the primary off any draining node.
func (g *Guard) Reconcile(ctx context.Context) error {
	var list unstructured.UnstructuredList
	list.SetGroupVersionKind(mariadbGVK)
	if err := g.Reader.List(ctx, &list, client.MatchingLabels{"dbaas.local/engine": "mariadb"}); err != nil {
		return err
	}
	nodes, err := g.loadNodes(ctx)
	if err != nil {
		return err
	}
	for _, item := range list.Items {
		s, obj, err := g.loadInstance(ctx, item.GetNamespace(), item.GetName())
		if err != nil {
			return err
		}
		if s == nil {
			continue
		}
		if err := g.abortStalledSwitchover(ctx, s, obj); err != nil {
			return err
		}
		s.Pods = dropExcluded(s.Pods, s.excluded(g.Now()))
		plan := planEvacuation(*s, nodes, g.DrainKeys, g.Now(), g.lastRequestedAt(s))
		if err := g.act(ctx, s, obj, plan); err != nil {
			return err
		}
	}
	g.Metrics.setBlocked(g.blockedCount())
	return nil
}

// abortStalledSwitchover points the desired primary back at the current one when a switchover
// has been pending longer than switchoverTimeout. The operator then stops waiting and the
// primary becomes writable again. The drain waits; nothing is forced.
func (g *Guard) abortStalledSwitchover(ctx context.Context, s *InstanceState, obj *unstructured.Unstructured) error {
	k := key(s.Namespace, s.Name)
	g.mu.Lock()
	if !s.switchoverPending() {
		delete(g.pendingSince, k)
		g.mu.Unlock()
		return nil
	}
	since, seen := g.pendingSince[k]
	if !seen {
		g.pendingSince[k] = g.Now()
		g.mu.Unlock()
		return nil
	}
	g.mu.Unlock()
	if !switchoverStalled(since, g.Now(), switchoverTimeout) || s.CurrentPrimary < 0 || s.DesiredPrimary == s.CurrentPrimary {
		return nil
	}
	// One patch: the target goes back to the current primary and the aborted target is recorded
	// on the object, where every replica of the guard reads it.
	patch, _ := json.Marshal(map[string]any{
		"metadata": map[string]any{"annotations": map[string]any{
			abortedAnnotation: fmt.Sprintf("%d@%s", s.DesiredPrimary, g.Now().UTC().Format(time.RFC3339)),
		}},
		"spec": map[string]any{"replication": map[string]any{
			"primary": map[string]any{"podIndex": s.CurrentPrimary},
		}},
	})
	if err := g.Client.Patch(ctx, obj, client.RawPatch(types.MergePatchType, patch)); err != nil {
		return fmt.Errorf("aborting the stalled switchover of %s: %w", k, err)
	}
	g.mu.Lock()
	delete(g.pendingSince, k)
	g.lastRequested[k] = g.Now()
	g.mu.Unlock()
	g.Recorder.Eventf(runtime.Object(obj), corev1.EventTypeWarning, "SwitchoverAborted",
		"the switchover to pod index %d had been pending for %s: moving the primary back to %d; the drain waits",
		s.DesiredPrimary, g.Now().Sub(since).Round(time.Second), s.CurrentPrimary)
	g.Metrics.observeEvacuation(s.Namespace, "aborted", 0)
	return nil
}

func (g *Guard) lastRequestedAt(s *InstanceState) time.Time {
	g.mu.Lock()
	defer g.mu.Unlock()
	return g.lastRequested[key(s.Namespace, s.Name)]
}

func (g *Guard) blockedCount() int {
	g.mu.Lock()
	defer g.mu.Unlock()
	n := 0
	for _, b := range g.blocked {
		if b {
			n++
		}
	}
	return n
}

// act carries out one plan on the MariaDB object it was planned from.
func (g *Guard) act(ctx context.Context, s *InstanceState, obj *unstructured.Unstructured, plan EvacuationPlan) error {
	k := key(s.Namespace, s.Name)
	switch plan.Action {
	case actionSwitch:
		start := g.Now()
		patch, _ := json.Marshal(map[string]any{"spec": map[string]any{"replication": map[string]any{
			"primary": map[string]any{"podIndex": plan.TargetIndex},
		}}})
		if err := g.Client.Patch(ctx, obj, client.RawPatch(types.MergePatchType, patch)); err != nil {
			g.Metrics.observeEvacuation(s.Namespace, "error", 0)
			return fmt.Errorf("moving the primary of %s: %w", k, err)
		}
		g.mu.Lock()
		g.lastRequested[k] = start
		g.blocked[k] = false
		g.mu.Unlock()
		g.Recorder.Eventf(runtime.Object(obj), corev1.EventTypeNormal, "PrimaryEvacuated",
			"moving the primary from pod index %d to %d: its node is draining", s.CurrentPrimary, plan.TargetIndex)
		g.Metrics.observeEvacuation(s.Namespace, "switch", g.Now().Sub(start))
	case actionBlocked:
		g.mu.Lock()
		first := !g.blocked[k]
		g.blocked[k] = true
		g.mu.Unlock()
		g.Recorder.Eventf(runtime.Object(obj), corev1.EventTypeWarning, "EvacuationBlocked",
			"the primary's node is draining but no replica can take the role: %s", plan.Reason)
		if first {
			g.Metrics.observeEvacuation(s.Namespace, "blocked", 0)
		}
	case actionPending, actionRecent:
		g.Metrics.observeEvacuation(s.Namespace, "skipped", 0)
	}
	return nil
}

// Evacuate moves the primary away for the webhook. It returns the plan, so the caller can
// tell the user what happened.
func (g *Guard) Evacuate(ctx context.Context, ns, name string) (EvacuationPlan, error) {
	s, obj, err := g.loadInstance(ctx, ns, name)
	if err != nil || s == nil {
		return EvacuationPlan{Action: actionIdle}, err
	}
	nodes, err := g.loadNodes(ctx)
	if err != nil {
		return EvacuationPlan{}, err
	}
	s.Pods = dropExcluded(s.Pods, s.excluded(g.Now()))
	plan := planEvacuationForced(*s, nodes, g.DrainKeys, g.Now(), g.lastRequestedAt(s))
	if err := g.act(ctx, s, obj, plan); err != nil {
		return plan, err
	}
	g.Metrics.setBlocked(g.blockedCount())
	return plan, nil
}

// planEvacuationForced is planEvacuation for an eviction request: the primary's node is
// treated as draining, because the eviction is the drain.
func planEvacuationForced(s InstanceState, nodes map[string]NodeInfo, drainKeys map[string]bool,
	now, lastRequested time.Time) EvacuationPlan {
	if s.CurrentPrimary >= 0 {
		if p, ok := s.pod(s.CurrentPrimary); ok {
			if n, ok := nodes[p.NodeName]; ok {
				// Present the primary's node as draining for the shared decision.
				n.Unschedulable = true
				nodes[p.NodeName] = n
			}
		}
	}
	return planEvacuation(s, nodes, drainKeys, now, lastRequested)
}
