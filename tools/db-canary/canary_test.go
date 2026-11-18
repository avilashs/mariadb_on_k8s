package main

import (
	"context"
	"encoding/json"
	"errors"
	"sync"
	"testing"
	"time"

	"github.com/prometheus/client_golang/prometheus"
)

// fakeClock is advanced by the tests, never by the wall clock.
type fakeClock struct {
	mu sync.Mutex
	t  time.Time
}

func (c *fakeClock) now() time.Time {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.t
}

func (c *fakeClock) advance(d time.Duration) {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.t = c.t.Add(d)
}

var errDown = errors.New("connection refused")

// fakeDB holds rows like a primary and reads like a replica. Failures are injected per call.
type fakeDB struct {
	mu          sync.Mutex
	rows        map[int64]time.Time // seq -> ts, for one writer
	failInserts int                 // the next N inserts fail
	failReads   int                 // the next N reads fail
	latest      time.Time           // what a reader sees; zero means nothing yet
}

func newFakeDB() *fakeDB { return &fakeDB{rows: map[int64]time.Time{}} }

func (db *fakeDB) Migrate(context.Context) error { return nil }

func (db *fakeDB) Insert(_ context.Context, _ string, seq int64, ts time.Time) error {
	db.mu.Lock()
	defer db.mu.Unlock()
	if db.failInserts > 0 {
		db.failInserts--
		return errDown
	}
	db.rows[seq] = ts
	if ts.After(db.latest) {
		db.latest = ts
	}
	return nil
}

func (db *fakeDB) Seqs(_ context.Context, _ string, since time.Time) ([]int64, error) {
	db.mu.Lock()
	defer db.mu.Unlock()
	var out []int64
	for seq, ts := range db.rows {
		if !ts.Before(since) {
			out = append(out, seq)
		}
	}
	return out, nil
}

func (db *fakeDB) Prune(_ context.Context, before time.Time) error {
	db.mu.Lock()
	defer db.mu.Unlock()
	for seq, ts := range db.rows {
		if ts.Before(before) {
			delete(db.rows, seq)
		}
	}
	return nil
}

func (db *fakeDB) LatestTS(context.Context) (time.Time, error) {
	db.mu.Lock()
	defer db.mu.Unlock()
	if db.failReads > 0 {
		db.failReads--
		return time.Time{}, errDown
	}
	return db.latest, nil
}

// drop removes an acknowledged row, as a lost write would.
func (db *fakeDB) drop(seq int64) {
	db.mu.Lock()
	defer db.mu.Unlock()
	delete(db.rows, seq)
}

func newTestCanary(t *testing.T, db *fakeDB, clock *fakeClock) *Canary {
	t.Helper()
	c, err := New(Config{Writer: "alpha-0", Interval: time.Second, Timeout: 2 * time.Second, Retention: 10 * time.Minute},
		db, db, clock.now, newMetrics(prometheus.NewRegistry()))
	if err != nil {
		t.Fatalf("New: %v", err)
	}
	return c
}

func TestAcknowledgedWritesAreCounted(t *testing.T) {
	clock := &fakeClock{t: time.Date(2026, 11, 18, 12, 0, 0, 0, time.UTC)}
	db := newFakeDB()
	c := newTestCanary(t, db, clock)
	for i := 0; i < 3; i++ {
		clock.advance(time.Second)
		if !c.WriteOnce(context.Background()) {
			t.Fatalf("write %d failed against a healthy database", i)
		}
	}
	rep, err := c.Snapshot(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if rep.WriteAttempts != 3 || rep.WriteFailures != 0 || rep.AcknowledgedWrites != 3 {
		t.Fatalf("want 3 attempts, 0 failures, 3 acknowledged; got %+v", rep)
	}
	if rep.LongestWriteOutageSec != 1 {
		t.Fatalf("healthy writes one second apart must show a one second gap, got %v", rep.LongestWriteOutageSec)
	}
}

func TestWriteOutageIsTheGapBetweenAcknowledgedWrites(t *testing.T) {
	clock := &fakeClock{t: time.Date(2026, 11, 18, 12, 0, 0, 0, time.UTC)}
	db := newFakeDB()
	c := newTestCanary(t, db, clock)
	ctx := context.Background()

	clock.advance(time.Second)
	c.WriteOnce(ctx) // acknowledged at T
	db.failInserts = 5
	for i := 0; i < 5; i++ {
		clock.advance(time.Second)
		if c.WriteOnce(ctx) {
			t.Fatal("a write succeeded while the database was refusing them")
		}
	}
	clock.advance(time.Second)
	if !c.WriteOnce(ctx) {
		t.Fatal("the write after the outage failed")
	}
	rep, _ := c.Snapshot(ctx)
	if rep.LongestWriteOutageSec != 6 {
		t.Fatalf("five failed attempts then a success one second later is a six second gap, got %v", rep.LongestWriteOutageSec)
	}
	if rep.WriteFailures != 5 {
		t.Fatalf("want 5 failures, got %d", rep.WriteFailures)
	}
}

func TestCanaryKeepsWritingThroughErrorsWithoutSpecialHandling(t *testing.T) {
	clock := &fakeClock{t: time.Date(2026, 11, 18, 12, 0, 0, 0, time.UTC)}
	db := newFakeDB()
	db.failInserts = 3
	c := newTestCanary(t, db, clock)
	ctx := context.Background()
	for i := 0; i < 6; i++ {
		clock.advance(time.Second)
		c.WriteOnce(ctx)
	}
	rep, _ := c.Snapshot(ctx)
	if rep.WriteFailures != 3 || rep.AcknowledgedWrites != 3 {
		t.Fatalf("want 3 failures and 3 acknowledged after redial; got %+v", rep)
	}
}

func TestSequenceNumbersAdvanceForFailedAttempts(t *testing.T) {
	clock := &fakeClock{t: time.Date(2026, 11, 18, 12, 0, 0, 0, time.UTC)}
	db := newFakeDB()
	db.failInserts = 1
	c := newTestCanary(t, db, clock)
	c.WriteOnce(context.Background()) // seq 1, fails
	clock.advance(time.Second)
	c.WriteOnce(context.Background()) // seq 2, acknowledged
	if _, ok := db.rows[1]; ok {
		t.Fatal("the failed attempt must not be in the table")
	}
	if _, ok := db.rows[2]; !ok {
		t.Fatal("the second attempt must be the sequence number 2")
	}
}

func TestLostAcknowledgedWriteIsDetected(t *testing.T) {
	clock := &fakeClock{t: time.Date(2026, 11, 18, 12, 0, 0, 0, time.UTC)}
	db := newFakeDB()
	c := newTestCanary(t, db, clock)
	ctx := context.Background()
	for i := 0; i < 5; i++ {
		clock.advance(time.Second)
		c.WriteOnce(ctx)
	}
	db.drop(3)
	lost, err := c.Verify(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if lost != 1 {
		t.Fatalf("one acknowledged write was removed, Verify reports %d", lost)
	}
}

func TestVerificationIgnoresWritesOutsideTheWindow(t *testing.T) {
	clock := &fakeClock{t: time.Date(2026, 11, 18, 12, 0, 0, 0, time.UTC)}
	db := newFakeDB()
	c := newTestCanary(t, db, clock) // retention 10 minutes, window 9 minutes
	ctx := context.Background()
	clock.advance(time.Second)
	c.WriteOnce(ctx) // seq 1, acknowledged at T+1s
	clock.advance(20 * time.Minute)
	db.drop(1) // pruned by retention, which is not a loss
	lost, _ := c.Verify(ctx)
	if lost != 0 {
		t.Fatalf("a write older than the window must not count as lost, got %d", lost)
	}
}

func TestReplicaDelayIsTheAgeOfTheNewestVisibleRow(t *testing.T) {
	clock := &fakeClock{t: time.Date(2026, 11, 18, 12, 0, 0, 0, time.UTC)}
	db := newFakeDB()
	c := newTestCanary(t, db, clock)
	ctx := context.Background()
	clock.advance(time.Second)
	c.WriteOnce(ctx)
	clock.advance(2 * time.Second)
	db.mu.Lock()
	db.latest = clock.now().Add(-2 * time.Second) // the replica is two seconds behind
	db.mu.Unlock()
	if !c.ReadOnce(ctx) {
		t.Fatal("read failed")
	}
	rep, _ := c.Snapshot(ctx)
	if rep.ReplicaDelaySec != 2 {
		t.Fatalf("want a replica delay of 2s, got %v", rep.ReplicaDelaySec)
	}
}

func TestReadFailuresAreCountedAndReadOutageMeasured(t *testing.T) {
	clock := &fakeClock{t: time.Date(2026, 11, 18, 12, 0, 0, 0, time.UTC)}
	db := newFakeDB()
	c := newTestCanary(t, db, clock)
	ctx := context.Background()
	c.ReadOnce(ctx)
	db.failReads = 2
	for i := 0; i < 2; i++ {
		clock.advance(time.Second)
		if c.ReadOnce(ctx) {
			t.Fatal("read succeeded while failing")
		}
	}
	clock.advance(time.Second)
	c.ReadOnce(ctx)
	rep, _ := c.Snapshot(ctx)
	if rep.ReadAttempts != 4 || rep.ReadFailures != 2 {
		t.Fatalf("want 4 read attempts and 2 failures, got %+v", rep)
	}
	if rep.LongestReadOutageSec != 3 {
		t.Fatalf("want a three second read gap, got %v", rep.LongestReadOutageSec)
	}
}

func TestResetClearsTheWindowButNotTheSequence(t *testing.T) {
	clock := &fakeClock{t: time.Date(2026, 11, 18, 12, 0, 0, 0, time.UTC)}
	db := newFakeDB()
	c := newTestCanary(t, db, clock)
	ctx := context.Background()
	clock.advance(time.Second)
	c.WriteOnce(ctx)
	c.Reset()
	rep, _ := c.Snapshot(ctx)
	if rep.WriteAttempts != 0 || rep.AcknowledgedWrites != 0 || rep.LongestWriteOutageSec != 0 {
		t.Fatalf("reset must clear the window, got %+v", rep)
	}
	clock.advance(time.Second)
	c.WriteOnce(ctx)
	if _, ok := db.rows[2]; !ok {
		t.Fatal("after a reset the sequence must keep counting, so no number is reused")
	}
}

func TestReportHasTheDocumentedFields(t *testing.T) {
	clock := &fakeClock{t: time.Date(2026, 11, 18, 12, 0, 0, 0, time.UTC)}
	c := newTestCanary(t, newFakeDB(), clock)
	rep, err := c.Snapshot(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	raw, _ := json.Marshal(rep)
	var fields map[string]any
	if err := json.Unmarshal(raw, &fields); err != nil {
		t.Fatal(err)
	}
	for _, key := range []string{"writer", "write_attempts", "write_failures", "longest_write_outage_seconds",
		"read_attempts", "read_failures", "longest_read_outage_seconds", "replica_delay_seconds",
		"lost_acknowledged_writes", "acknowledged_writes"} {
		if _, ok := fields[key]; !ok {
			t.Errorf("report lacks %q", key)
		}
	}
}

func TestNewRejectsUnsafeConfiguration(t *testing.T) {
	clock := &fakeClock{t: time.Now()}
	db := newFakeDB()
	m := newMetrics(prometheus.NewRegistry())
	cases := map[string]Config{
		"no writer":       {Interval: time.Second, Timeout: time.Second, Retention: time.Hour},
		"zero interval":   {Writer: "a", Timeout: time.Second, Retention: time.Hour},
		"short retention": {Writer: "a", Interval: time.Second, Timeout: time.Second, Retention: time.Minute},
	}
	for name, cfg := range cases {
		if _, err := New(cfg, db, db, clock.now, m); err == nil {
			t.Errorf("%s: New accepted an unsafe configuration", name)
		}
	}
}
