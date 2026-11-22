// Command loadgen is a small closed- or open-loop load generator for MariaDB. It measures per-statement latency
// (mean, p50, p95, p99, max) and throughput over TLS, which sysbench and mariadb-slap could not give together.
//
//	loadgen -host testdb-primary -user appuser -db appdb -clients 32 -duration 60s -workload mixed -prepare
//
// The password is read from the environment variable named by -password-env (default PW). With -rate > 0 the load
// is open loop: statements are scheduled at that total rate and latency is measured from the scheduled start, so a
// slow server shows up as latency instead of as fewer requests (no coordinated omission).
package main

import (
	"context"
	"crypto/tls"
	"database/sql"
	"flag"
	"fmt"
	"math/rand"
	"os"
	"sort"
	"sync"
	"time"

	"github.com/go-sql-driver/mysql"
)

type result struct {
	lat  []time.Duration
	errs int
}

func main() {
	var (
		host     = flag.String("host", "127.0.0.1", "server host")
		port     = flag.Int("port", 3306, "server port")
		user     = flag.String("user", "", "user")
		pwEnv    = flag.String("password-env", "PW", "environment variable holding the password")
		db       = flag.String("db", "", "database")
		useTLS   = flag.Bool("tls", true, "use TLS (the certificate is not verified: a benchmark inside the cluster)")
		clients  = flag.Int("clients", 16, "concurrent clients")
		duration = flag.Duration("duration", 60*time.Second, "measured duration")
		warmup   = flag.Duration("warmup", 10*time.Second, "warm-up, not measured")
		workload = flag.String("workload", "mixed", "read | write | mixed (80% read, 20% write)")
		rows     = flag.Int("rows", 100000, "rows in the table")
		rate     = flag.Float64("rate", 0, "total statements per second (open loop); 0 = closed loop")
		prepare  = flag.Bool("prepare", false, "create and fill the table first")
	)
	flag.Parse()
	if *user == "" || *db == "" {
		fmt.Fprintln(os.Stderr, "-user and -db are required")
		os.Exit(2)
	}
	cfg := mysql.NewConfig()
	cfg.User, cfg.Passwd, cfg.DBName = *user, os.Getenv(*pwEnv), *db
	cfg.Net, cfg.Addr = "tcp", fmt.Sprintf("%s:%d", *host, *port)
	cfg.Timeout, cfg.ReadTimeout, cfg.WriteTimeout = 5*time.Second, 30*time.Second, 30*time.Second
	if *useTLS {
		if err := mysql.RegisterTLSConfig("bench", &tls.Config{InsecureSkipVerify: true, MinVersion: tls.VersionTLS12}); err != nil {
			fatal(err)
		}
		cfg.TLSConfig = "bench"
	}
	conn, err := mysql.NewConnector(cfg)
	if err != nil {
		fatal(err)
	}
	pool := sql.OpenDB(conn)
	pool.SetMaxOpenConns(*clients)
	pool.SetMaxIdleConns(*clients)
	defer pool.Close()
	ctx := context.Background()
	if err := pool.PingContext(ctx); err != nil {
		fatal(err)
	}
	if *prepare {
		for _, q := range []string{
			"DROP TABLE IF EXISTS lg_t",
			"CREATE TABLE lg_t (id INT PRIMARY KEY, k INT NOT NULL, c CHAR(120) NOT NULL, pad CHAR(60) NOT NULL) ENGINE=InnoDB",
		} {
			if _, err := pool.ExecContext(ctx, q); err != nil {
				fatal(err)
			}
		}
		for lo := 1; lo <= *rows; lo += 5000 {
			hi := lo + 4999
			if hi > *rows {
				hi = *rows
			}
			q := fmt.Sprintf("INSERT INTO lg_t SELECT seq, seq %% 1000, MD5(seq), MD5(seq+1) FROM seq_%d_to_%d", lo, hi)
			if _, err := pool.ExecContext(ctx, q); err != nil {
				fatal(err)
			}
		}
		fmt.Printf("prepared %d rows\n", *rows)
	}

	op := func(r *rand.Rand) error {
		id := r.Intn(*rows) + 1
		write := *workload == "write" || (*workload == "mixed" && r.Intn(100) < 20)
		if write {
			_, err := pool.ExecContext(ctx, "UPDATE lg_t SET k = k + 1 WHERE id = ?", id)
			return err
		}
		var c string
		return pool.QueryRowContext(ctx, "SELECT c FROM lg_t WHERE id = ?", id).Scan(&c)
	}

	start := time.Now()
	measureFrom := start.Add(*warmup)
	end := measureFrom.Add(*duration)
	results := make([]result, *clients)
	var wg sync.WaitGroup
	for w := 0; w < *clients; w++ {
		wg.Add(1)
		go func(w int) {
			defer wg.Done()
			r := rand.New(rand.NewSource(time.Now().UnixNano() + int64(w)))
			var interval time.Duration
			next := time.Now()
			if *rate > 0 {
				interval = time.Duration(float64(time.Second) * float64(*clients) / *rate)
				next = next.Add(time.Duration(r.Int63n(int64(interval))))
			}
			for {
				began := time.Now()
				if *rate > 0 {
					if d := time.Until(next); d > 0 {
						time.Sleep(d)
					}
					began = next // latency counts from the scheduled start
					next = next.Add(interval)
				}
				if began.After(end) {
					return
				}
				err := op(r)
				took := time.Since(began)
				if began.Before(measureFrom) {
					continue
				}
				if err != nil {
					results[w].errs++
					continue
				}
				results[w].lat = append(results[w].lat, took)
			}
		}(w)
	}
	wg.Wait()

	var all []time.Duration
	errs := 0
	for _, r := range results {
		all = append(all, r.lat...)
		errs += r.errs
	}
	if len(all) == 0 {
		fatal(fmt.Errorf("no successful statements (%d errors)", errs))
	}
	sort.Slice(all, func(i, j int) bool { return all[i] < all[j] })
	var sum time.Duration
	for _, d := range all {
		sum += d
	}
	pct := func(p float64) float64 {
		i := int(float64(len(all)-1) * p)
		return float64(all[i]) / float64(time.Millisecond)
	}
	mode := "closed-loop"
	if *rate > 0 {
		mode = fmt.Sprintf("open-loop %.0f/s", *rate)
	}
	fmt.Printf("workload=%s clients=%d %s duration=%s statements=%d errors=%d qps=%.0f mean=%.2fms p50=%.2fms p95=%.2fms p99=%.2fms max=%.2fms\n",
		*workload, *clients, mode, *duration, len(all), errs,
		float64(len(all))/duration.Seconds(), float64(sum)/float64(len(all))/float64(time.Millisecond),
		pct(0.50), pct(0.95), pct(0.99), float64(all[len(all)-1])/float64(time.Millisecond))
}

func fatal(err error) {
	fmt.Fprintln(os.Stderr, "loadgen:", err)
	os.Exit(1)
}
