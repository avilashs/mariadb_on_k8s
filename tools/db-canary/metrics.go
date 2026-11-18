package main

import (
	"time"

	"github.com/prometheus/client_golang/prometheus"
)

// metrics are the Prometheus series of PLAN.md phase 6. Names are part of the alert
// and dashboard contract; do not rename them.
type metrics struct {
	writeTotal       *prometheus.CounterVec
	writeDuration    prometheus.Histogram
	readTotal        *prometheus.CounterVec
	replicaDelay     prometheus.Gauge
	lastWriteSuccess prometheus.Gauge
	longestWriteOut  prometheus.Gauge
	longestReadOut   prometheus.Gauge
	lostAckedWrites  prometheus.Gauge
	registry         *prometheus.Registry
	resetableGauges  []prometheus.Gauge
}

func newMetrics(reg *prometheus.Registry) *metrics {
	m := &metrics{
		writeTotal: prometheus.NewCounterVec(prometheus.CounterOpts{
			Name: "db_canary_write_total",
			Help: "Write attempts by result (ok or error).",
		}, []string{"result"}),
		writeDuration: prometheus.NewHistogram(prometheus.HistogramOpts{
			Name:    "db_canary_write_duration_seconds",
			Help:    "Duration of write attempts, successful or not.",
			Buckets: []float64{0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1, 2, 5},
		}),
		readTotal: prometheus.NewCounterVec(prometheus.CounterOpts{
			Name: "db_canary_read_total",
			Help: "Read attempts through the secondary Service by result.",
		}, []string{"result"}),
		replicaDelay: prometheus.NewGauge(prometheus.GaugeOpts{
			Name: "db_canary_replica_delay_seconds",
			Help: "Age of the newest row a reader can see.",
		}),
		lastWriteSuccess: prometheus.NewGauge(prometheus.GaugeOpts{
			Name: "db_canary_last_write_success_timestamp_seconds",
			Help: "Unix time of the last acknowledged write.",
		}),
		longestWriteOut: prometheus.NewGauge(prometheus.GaugeOpts{
			Name: "db_canary_longest_write_outage_seconds",
			Help: "Longest gap between two acknowledged writes since the last reset.",
		}),
		longestReadOut: prometheus.NewGauge(prometheus.GaugeOpts{
			Name: "db_canary_longest_read_outage_seconds",
			Help: "Longest gap between two successful reads since the last reset.",
		}),
		lostAckedWrites: prometheus.NewGauge(prometheus.GaugeOpts{
			Name: "db_canary_lost_acked_writes",
			Help: "Acknowledged writes missing from the database at the last verification.",
		}),
		registry: reg,
	}
	m.resetableGauges = []prometheus.Gauge{m.replicaDelay, m.longestWriteOut, m.longestReadOut, m.lostAckedWrites}
	reg.MustRegister(m.writeTotal, m.writeDuration, m.readTotal, m.replicaDelay,
		m.lastWriteSuccess, m.longestWriteOut, m.longestReadOut, m.lostAckedWrites)
	return m
}

func resultLabel(err error) string {
	if err != nil {
		return "error"
	}
	return "ok"
}

func (m *metrics) observeWrite(err error, d time.Duration) {
	m.writeTotal.WithLabelValues(resultLabel(err)).Inc()
	m.writeDuration.Observe(d.Seconds())
}

func (m *metrics) observeRead(err error) {
	m.readTotal.WithLabelValues(resultLabel(err)).Inc()
}

func (m *metrics) setLastWriteSuccess(t time.Time) {
	m.lastWriteSuccess.Set(float64(t.UnixNano()) / 1e9)
}

func (m *metrics) setLongestWriteOutage(d time.Duration) { m.longestWriteOut.Set(d.Seconds()) }
func (m *metrics) setLongestReadOutage(d time.Duration)  { m.longestReadOut.Set(d.Seconds()) }
func (m *metrics) setReplicaDelay(d time.Duration)       { m.replicaDelay.Set(d.Seconds()) }
func (m *metrics) setLostAcked(n int64)                  { m.lostAckedWrites.Set(float64(n)) }

// reset zeroes the gauges that describe a measurement window. Counters are monotonic
// by design and keep their values, as Prometheus expects.
func (m *metrics) reset() {
	for _, g := range m.resetableGauges {
		g.Set(0)
	}
}
