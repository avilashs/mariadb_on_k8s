package main

import (
	"context"
	"net/http"

	corev1 "k8s.io/api/core/v1"
	apierrors "k8s.io/apimachinery/pkg/api/errors"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"sigs.k8s.io/controller-runtime/pkg/client"
	"sigs.k8s.io/controller-runtime/pkg/webhook/admission"
)

// evictionWebhook answers CREATE on pods/eviction (PLAN.md phase 7, step 3).
type evictionWebhook struct {
	g *Guard
}

// Handle implements admission.Handler. Failures are returned as errors, which the API
// server turns into a refusal (failurePolicy: Fail): the guard never silently allows.
func (h *evictionWebhook) Handle(ctx context.Context, req admission.Request) admission.Response {
	dryRun := req.DryRun != nil && *req.DryRun
	ns, podName := req.Namespace, req.Name

	pod := &corev1.Pod{}
	if err := h.g.Reader.Get(ctx, client.ObjectKey{Namespace: ns, Name: podName}, pod); err != nil {
		if apierrors.IsNotFound(err) {
			return admission.Allowed("pod not found: nothing to protect")
		}
		return admission.Errored(http.StatusServiceUnavailable, err)
	}

	isDB := pod.Labels["app.kubernetes.io/name"] == "mariadb" && pod.Labels["app.kubernetes.io/instance"] != ""
	var inst *InstanceState
	if isDB {
		s, _, err := h.g.loadInstance(ctx, ns, pod.Labels["app.kubernetes.io/instance"])
		if err != nil {
			return admission.Errored(http.StatusServiceUnavailable, err)
		}
		inst = s
	}

	decision := decideEviction(podName, isDB, inst, dryRun)
	if decision.Evacuate && inst != nil {
		// The primary is being drained: start its move now, so the retry succeeds sooner.
		if _, err := h.g.Evacuate(ctx, ns, inst.Name); err != nil {
			return admission.Errored(http.StatusServiceUnavailable, err)
		}
	}
	if decision.Allow {
		return admission.Allowed("")
	}
	h.g.Metrics.observeDenied(ns, decision.Reason)
	resp := admission.Denied(decision.Message)
	resp.Result.Code = decision.Code
	resp.Result.Reason = metav1.StatusReasonTooManyRequests
	return resp
}
