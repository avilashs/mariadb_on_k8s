// Package main implements db-canary, the client's-eye measurement of PLAN.md phase 6.
//
// The canary behaves like a well-written application: it writes one row per second
// through the primary Service, reads the newest row through the secondary Service,
// and keeps a connection pool that redials on error. It has no failover logic of its
// own. What it measures is what a client sees: failed writes, the longest gap between
// acknowledged writes, the delay of replicas, and acknowledged writes that are missing.
package main

import (
	"context"
	"errors"
	"sync"
	"time"
)

// Writer is the primary side of the heartbeat table.
type Writer interface {
	// Migrate creates the heartbeat table when it is missing.
	Migrate(ctx context.Context) error
	// Insert writes one row. A nil error means the database acknowledged it.
	Insert(ctx context.Context, writer string, seq int64, ts time.Time) error
	// Seqs returns the sequence numbers of one writer's rows written at or after since.
	Seqs(ctx context.Context, writer string, since time.Time) ([]int64, error)
	// Prune deletes rows written before before.
	Prune(ctx context.Context, before time.Time) error
}

// Reader is the secondary side: the newest row a reader can see.
type Reader interface {
	// LatestTS returns the timestamp of the newest row, or the zero time if there is none.
	LatestTS(ctx context.Context) (time.Time, error)
}

// Config controls one canary.
type Config struct {
	Writer    string        // identity of this canary, the pod name
	Interval  time.Duration // one write and one read per interval
	Timeout   time.Duration // per operation
	Retention time.Duration // rows older than this are pruned; verification covers the window before it
}

// Canary runs the write and read loops and keeps the counters of PLAN.md phase 6.
type Canary struct {
	cfg     Config
	w       Writer
	r       Reader
	now     func() time.Time
	metrics *metrics

	mu sync.Mutex

	seq   int64
	acked map[int64]time.Time // acknowledged sequence numbers and the time each was written

	writeAttempts, writeFailures int64
	lastWriteOK                  time.Time
	longestWriteOutage           time.Duration

	readAttempts, readFailures int64
	lastReadOK                 time.Time
	longestReadOutage          time.Duration
	lastDelay                  time.Duration

	lostAcked int64
}

// New builds a canary. The clock is injected so that tests can drive time.
func New(cfg Config, w Writer, r Reader, now func() time.Time, m *metrics) (*Canary, error) {
	if cfg.Writer == "" {
		return nil, errors.New("the writer identity is required")
	}
	if cfg.Interval <= 0 || cfg.Timeout <= 0 || cfg.Retention <= 0 {
		return nil, errors.New("interval, timeout and retention must be positive")
	}
	if cfg.Retention < 2*time.Minute {
		return nil, errors.New("retention must be at least two minutes: verification covers retention minus one minute")
	}
	if now == nil {
		now = time.Now
	}
	return &Canary{cfg: cfg, w: w, r: r, now: now, metrics: m, acked: map[int64]time.Time{}}, nil
}

// Run runs the write, read and prune loops until ctx is done.
func (c *Canary) Run(ctx context.Context) {
	var wg sync.WaitGroup
	loop := func(every time.Duration, step func(context.Context)) {
		defer wg.Done()
		t := time.NewTicker(every)
		defer t.Stop()
		for {
			select {
			case <-ctx.Done():
				return
			case <-t.C:
				step(ctx)
			}
		}
	}
	wg.Add(3)
	go loop(c.cfg.Interval, func(ctx context.Context) { c.WriteOnce(ctx) })
	go loop(c.cfg.Interval, func(ctx context.Context) { c.ReadOnce(ctx) })
	go loop(time.Minute, func(ctx context.Context) { c.pruneOnce(ctx) })
	wg.Wait()
}

// WriteOnce makes one write attempt. Every attempt takes a sequence number, acknowledged
// or not, so a gap in the sequence on the reader side is a write that failed.
func (c *Canary) WriteOnce(ctx context.Context) bool {
	c.mu.Lock()
	c.seq++
	seq := c.seq
	c.mu.Unlock()

	ts := c.now()
	opCtx, cancel := context.WithTimeout(ctx, c.cfg.Timeout)
	defer cancel()
	err := c.w.Insert(opCtx, c.cfg.Writer, seq, ts)
	end := c.now()
	c.metrics.observeWrite(err, end.Sub(ts))

	c.mu.Lock()
	defer c.mu.Unlock()
	c.writeAttempts++
	if err != nil {
		c.writeFailures++
		return false
	}
	c.acked[seq] = ts
	if !c.lastWriteOK.IsZero() {
		if gap := end.Sub(c.lastWriteOK); gap > c.longestWriteOutage {
			c.longestWriteOutage = gap
		}
	}
	c.lastWriteOK = end
	c.metrics.setLastWriteSuccess(end)
	c.metrics.setLongestWriteOutage(c.longestWriteOutage)
	return true
}

// ReadOnce reads the newest row through the reader and records how far behind it is.
func (c *Canary) ReadOnce(ctx context.Context) bool {
	opCtx, cancel := context.WithTimeout(ctx, c.cfg.Timeout)
	defer cancel()
	latest, err := c.r.LatestTS(opCtx)
	end := c.now()
	c.metrics.observeRead(err)

	c.mu.Lock()
	defer c.mu.Unlock()
	c.readAttempts++
	if err != nil {
		c.readFailures++
		return false
	}
	switch {
	case !latest.IsZero():
		c.lastDelay = end.Sub(latest)
	default:
		// Nothing is visible yet. The delay is the age of the oldest write this canary
		// made, and zero when it has made none.
		c.lastDelay = 0
		if first := c.startedAt(); !first.IsZero() {
			c.lastDelay = end.Sub(first)
		}
	}
	c.metrics.setReplicaDelay(c.lastDelay)
	if !c.lastReadOK.IsZero() {
		if gap := end.Sub(c.lastReadOK); gap > c.longestReadOutage {
			c.longestReadOutage = gap
		}
	}
	c.lastReadOK = end
	c.metrics.setLongestReadOutage(c.longestReadOutage)
	return true
}

// startedAt is the earliest acknowledged write, or the zero time before the first one.
func (c *Canary) startedAt() time.Time {
	var first time.Time
	for _, ts := range c.acked {
		if first.IsZero() || ts.Before(first) {
			first = ts
		}
	}
	return first
}

func (c *Canary) pruneOnce(ctx context.Context) {
	opCtx, cancel := context.WithTimeout(ctx, c.cfg.Timeout*5)
	defer cancel()
	before := c.now().Add(-c.cfg.Retention)
	if err := c.w.Prune(opCtx, before); err != nil {
		return
	}
	c.mu.Lock()
	defer c.mu.Unlock()
	for seq, ts := range c.acked {
		if ts.Before(before) {
			delete(c.acked, seq)
		}
	}
}

// Verify compares the acknowledged writes with the rows the database holds and returns
// how many acknowledged writes are missing. Writes older than the retention minus one
// minute are not checked: pruning may have removed them legitimately.
func (c *Canary) Verify(ctx context.Context) (int64, error) {
	since := c.now().Add(-(c.cfg.Retention - time.Minute))

	c.mu.Lock()
	expected := map[int64]struct{}{}
	for seq, ts := range c.acked {
		if !ts.Before(since) {
			expected[seq] = struct{}{}
		}
	}
	c.mu.Unlock()

	opCtx, cancel := context.WithTimeout(ctx, c.cfg.Timeout*5)
	defer cancel()
	present, err := c.w.Seqs(opCtx, c.cfg.Writer, since)
	if err != nil {
		return 0, err
	}
	for _, seq := range present {
		delete(expected, seq)
	}
	missing := int64(len(expected))

	c.mu.Lock()
	c.lostAcked = missing
	c.mu.Unlock()
	c.metrics.setLostAcked(missing)
	return missing, nil
}

// Report is the JSON served on /report: the numbers a test or a dashboard needs.
type Report struct {
	Writer                 string  `json:"writer"`
	WriteAttempts          int64   `json:"write_attempts"`
	WriteFailures          int64   `json:"write_failures"`
	LongestWriteOutageSec  float64 `json:"longest_write_outage_seconds"`
	ReadAttempts           int64   `json:"read_attempts"`
	ReadFailures           int64   `json:"read_failures"`
	LongestReadOutageSec   float64 `json:"longest_read_outage_seconds"`
	ReplicaDelaySec        float64 `json:"replica_delay_seconds"`
	LostAcknowledgedWrites int64   `json:"lost_acknowledged_writes"`
	AcknowledgedWrites     int64   `json:"acknowledged_writes"`
	VerifiedWindowSeconds  float64 `json:"verified_window_seconds"`
}

// Snapshot verifies the acknowledged writes and returns the report.
func (c *Canary) Snapshot(ctx context.Context) (Report, error) {
	lost, err := c.Verify(ctx)
	if err != nil {
		return Report{}, err
	}
	c.mu.Lock()
	defer c.mu.Unlock()
	return Report{
		Writer:                 c.cfg.Writer,
		WriteAttempts:          c.writeAttempts,
		WriteFailures:          c.writeFailures,
		LongestWriteOutageSec:  c.longestWriteOutage.Seconds(),
		ReadAttempts:           c.readAttempts,
		ReadFailures:           c.readFailures,
		LongestReadOutageSec:   c.longestReadOutage.Seconds(),
		ReplicaDelaySec:        c.lastDelay.Seconds(),
		LostAcknowledgedWrites: lost,
		AcknowledgedWrites:     int64(len(c.acked)),
		VerifiedWindowSeconds:  (c.cfg.Retention - time.Minute).Seconds(),
	}, nil
}

// Reset clears every counter and the acknowledged set. The sequence keeps counting, so
// a reset never reuses a number that is still in the table.
func (c *Canary) Reset() {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.acked = map[int64]time.Time{}
	c.writeAttempts, c.writeFailures = 0, 0
	c.readAttempts, c.readFailures = 0, 0
	c.lastWriteOK, c.lastReadOK = time.Time{}, time.Time{}
	c.longestWriteOutage, c.longestReadOutage = 0, 0
	c.lastDelay, c.lostAcked = 0, 0
	c.metrics.reset()
}
