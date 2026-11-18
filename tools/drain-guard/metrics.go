package main

import (
	"time"

	"github.com/prometheus/client_golang/prometheus"
)

// metrics are the drain-guard series of PLAN.md phase 7. Names are part of the alert
// contract.
type guardMetrics struct {
	evacuations *prometheus.CounterVec
	denied      *prometheus.CounterVec
	blocked     prometheus.Gauge
	duration    prometheus.Histogram
}

func newGuardMetrics(reg prometheus.Registerer) *guardMetrics {
	m := &guardMetrics{
		evacuations: prometheus.NewCounterVec(prometheus.CounterOpts{
			Name: "drain_guard_evacuations_total",
			Help: "Primary evacuation decisions by namespace and result (switch, blocked, skipped, error).",
		}, []string{"namespace", "result"}),
		denied: prometheus.NewCounterVec(prometheus.CounterOpts{
			Name: "drain_guard_evictions_denied_total",
			Help: "Evictions of database pods refused by the webhook, by namespace and reason.",
		}, []string{"namespace", "reason"}),
		blocked: prometheus.NewGauge(prometheus.GaugeOpts{
			Name: "drain_guard_blocked_instances",
			Help: "Instances whose primary sits on a draining node and cannot move.",
		}),
		duration: prometheus.NewHistogram(prometheus.HistogramOpts{
			Name:    "drain_guard_evacuation_duration_seconds",
			Help:    "Time to request a primary move.",
			Buckets: []float64{0.001, 0.01, 0.05, 0.1, 0.5, 1, 5},
		}),
	}
	reg.MustRegister(m.evacuations, m.denied, m.blocked, m.duration)
	return m
}

func (m *guardMetrics) observeEvacuation(ns, result string, d time.Duration) {
	m.evacuations.WithLabelValues(ns, result).Inc()
	if result == "switch" {
		m.duration.Observe(d.Seconds())
	}
}

func (m *guardMetrics) observeDenied(ns, reason string) {
	m.denied.WithLabelValues(ns, reason).Inc()
}

func (m *guardMetrics) setBlocked(n int) {
	m.blocked.Set(float64(n))
}
