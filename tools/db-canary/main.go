// Command db-canary measures what a client sees of a database instance (PLAN.md phase 6).
//
//	db-canary --engine mariadb --write-host alpha-primary.db-alpha.svc --read-host alpha-secondary.db-alpha.svc \
//	          --port 3306 --user alpha-canary --password-file /secrets/password --ca-file /secrets/ca.crt
//
// Every flag can also be set from the environment (see flagEnv below). HTTP on --listen:
//
//	GET  /metrics   Prometheus series db_canary_*
//	GET  /report    JSON report; verifies acknowledged writes before answering
//	POST /reset     clears the measurement window
//	GET  /healthz   200 once the canary runs
package main

import (
	"context"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"log/slog"
	"net/http"
	"os"
	"os/signal"
	"strconv"
	"syscall"
	"time"

	"github.com/prometheus/client_golang/prometheus"
	"github.com/prometheus/client_golang/prometheus/promhttp"
)

type options struct {
	engine       string
	writeHost    string
	readHost     string
	port         int
	user         string
	passwordFile string
	database     string
	caFile       string
	interval     time.Duration
	timeout      time.Duration
	retention    time.Duration
	listen       string
	writer       string
}

// flagEnv maps each flag to the environment variable that sets its default.
var flagEnv = map[string]string{
	"engine": "ENGINE", "write-host": "WRITE_HOST", "read-host": "READ_HOST", "port": "PORT",
	"user": "DB_USER", "password-file": "DB_PASSWORD_FILE", "database": "DB_NAME", "ca-file": "CA_FILE",
	"interval": "INTERVAL", "timeout": "TIMEOUT", "retention": "RETENTION", "listen": "LISTEN", "writer": "WRITER",
}

func parseOptions(args []string) (options, error) {
	fs := flag.NewFlagSet("db-canary", flag.ContinueOnError)
	var o options
	fs.StringVar(&o.engine, "engine", envOr("engine", "mariadb"), "mariadb or postgres")
	fs.StringVar(&o.writeHost, "write-host", envOr("write-host", ""), "primary Service host")
	fs.StringVar(&o.readHost, "read-host", envOr("read-host", ""), "secondary Service host")
	fs.IntVar(&o.port, "port", envInt("port", 3306), "database port")
	fs.StringVar(&o.user, "user", envOr("user", ""), "database user of the canary")
	fs.StringVar(&o.passwordFile, "password-file", envOr("password-file", ""), "file with the database password")
	fs.StringVar(&o.database, "database", envOr("database", "dbaas_canary"), "database that holds the heartbeat table")
	fs.StringVar(&o.caFile, "ca-file", envOr("ca-file", ""), "CA bundle to verify the server; empty skips verification")
	fs.DurationVar(&o.interval, "interval", envDuration("interval", time.Second), "time between writes and between reads")
	fs.DurationVar(&o.timeout, "timeout", envDuration("timeout", 2*time.Second), "timeout of one operation")
	fs.DurationVar(&o.retention, "retention", envDuration("retention", time.Hour), "rows older than this are pruned")
	fs.StringVar(&o.listen, "listen", envOr("listen", ":8080"), "address of the HTTP endpoints")
	fs.StringVar(&o.writer, "writer", envOr("writer", hostnameOr("canary")), "identity of this canary (the pod name)")
	if err := fs.Parse(args); err != nil {
		return o, err
	}
	switch {
	case o.engine != "mariadb" && o.engine != "postgres":
		return o, fmt.Errorf("engine must be mariadb or postgres, got %q", o.engine)
	case o.writeHost == "" || o.readHost == "":
		return o, errors.New("write-host and read-host are required")
	case o.user == "" || o.passwordFile == "":
		return o, errors.New("user and password-file are required")
	}
	return o, nil
}

func envOr(flagName, def string) string {
	if v, ok := os.LookupEnv(flagEnv[flagName]); ok && v != "" {
		return v
	}
	return def
}

func envInt(flagName string, def int) int {
	if v := envOr(flagName, ""); v != "" {
		if n, err := strconv.Atoi(v); err == nil {
			return n
		}
	}
	return def
}

func envDuration(flagName string, def time.Duration) time.Duration {
	if v := envOr(flagName, ""); v != "" {
		if d, err := time.ParseDuration(v); err == nil {
			return d
		}
	}
	return def
}

func hostnameOr(def string) string {
	if h, err := os.Hostname(); err == nil && h != "" {
		return h
	}
	return def
}

// engineStore is what main needs from a backend: both sides and a way to close them.
type engineStore interface {
	Writer
	Reader
	Close()
}

func openStore(o options) (engineStore, error) {
	password, err := os.ReadFile(o.passwordFile)
	if err != nil {
		return nil, fmt.Errorf("reading the password: %w", err)
	}
	cfg := DBConfig{
		WriteHost: o.writeHost, ReadHost: o.readHost, Port: o.port, User: o.user,
		Password: string(password), Database: o.database, CAFile: o.caFile, Timeout: o.timeout,
	}
	if o.engine == "postgres" {
		return newPostgresStore(cfg)
	}
	return newMySQLStore(cfg)
}

// migrate retries until the table exists. A database that is not up yet is the normal
// case on a fresh instance, so the canary waits instead of failing.
func migrate(ctx context.Context, log *slog.Logger, s Writer) error {
	backoff := time.Second
	for {
		mctx, cancel := context.WithTimeout(ctx, 10*time.Second)
		err := s.Migrate(mctx)
		cancel()
		if err == nil {
			return nil
		}
		log.Warn("the heartbeat table is not ready yet", "error", err.Error(), "retry_in", backoff.String())
		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-time.After(backoff):
		}
		if backoff < 30*time.Second {
			backoff *= 2
		}
	}
}

func serve(ctx context.Context, log *slog.Logger, o options, c *Canary, reg *prometheus.Registry) error {
	mux := http.NewServeMux()
	mux.Handle("GET /metrics", promhttp.HandlerFor(reg, promhttp.HandlerOpts{}))
	mux.HandleFunc("GET /healthz", func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusOK)
	})
	mux.HandleFunc("GET /report", func(w http.ResponseWriter, r *http.Request) {
		rep, err := c.Snapshot(r.Context())
		if err != nil {
			http.Error(w, "verification failed: "+err.Error(), http.StatusServiceUnavailable)
			return
		}
		w.Header().Set("Content-Type", "application/json")
		_ = json.NewEncoder(w).Encode(rep)
	})
	mux.HandleFunc("POST /reset", func(w http.ResponseWriter, _ *http.Request) {
		c.Reset()
		log.Info("measurement window reset")
		w.WriteHeader(http.StatusNoContent)
	})

	srv := &http.Server{Addr: o.listen, Handler: mux, ReadHeaderTimeout: 5 * time.Second}
	errc := make(chan error, 1)
	go func() { errc <- srv.ListenAndServe() }()
	select {
	case <-ctx.Done():
		shutdownCtx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		return srv.Shutdown(shutdownCtx)
	case err := <-errc:
		return err
	}
}

func main() {
	log := slog.New(slog.NewJSONHandler(os.Stdout, nil))
	o, err := parseOptions(os.Args[1:])
	if err != nil {
		log.Error("invalid options", "error", err.Error())
		os.Exit(2)
	}

	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGTERM, syscall.SIGINT)
	defer stop()

	store, err := openStore(o)
	if err != nil {
		log.Error("opening the connections failed", "error", err.Error())
		os.Exit(1)
	}
	defer store.Close()

	if err := migrate(ctx, log, store); err != nil {
		log.Info("stopped before the table existed", "error", err.Error())
		return
	}

	reg := prometheus.NewRegistry()
	m := newMetrics(reg)
	c, err := New(Config{Writer: o.writer, Interval: o.interval, Timeout: o.timeout, Retention: o.retention},
		store, store, time.Now, m)
	if err != nil {
		log.Error("invalid configuration", "error", err.Error())
		os.Exit(2)
	}

	log.Info("canary running", "engine", o.engine, "writer", o.writer, "interval", o.interval.String())
	go c.Run(ctx)
	if err := serve(ctx, log, o, c, reg); err != nil && !errors.Is(err, http.ErrServerClosed) {
		log.Error("http server stopped", "error", err.Error())
		os.Exit(1)
	}
	log.Info("canary stopped")
}
