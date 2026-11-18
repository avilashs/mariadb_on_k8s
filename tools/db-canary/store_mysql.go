package main

import (
	"context"
	"crypto/tls"
	"crypto/x509"
	"database/sql"
	"errors"
	"fmt"
	"os"
	"time"

	"github.com/go-sql-driver/mysql"
)

// DBConfig is where one engine's connections go. Hosts are Service names; the canary
// never talks to a pod directly.
type DBConfig struct {
	WriteHost string
	ReadHost  string
	Port      int
	User      string
	Password  string
	Database  string
	CAFile    string // optional: verify the server against this CA; empty skips verification
	Timeout   time.Duration
}

const heartbeatDDLMySQL = `CREATE TABLE IF NOT EXISTS heartbeat (
  writer VARCHAR(64) NOT NULL,
  seq BIGINT NOT NULL,
  ts DATETIME(6) NOT NULL,
  PRIMARY KEY (writer, seq),
  KEY heartbeat_ts (ts)
) ENGINE=InnoDB`

// mysqlStore implements Writer and Reader over the MySQL protocol (MariaDB).
type mysqlStore struct {
	write *sql.DB
	read  *sql.DB
}

func openMySQL(host string, cfg DBConfig, tlsName string) (*sql.DB, error) {
	c := mysql.NewConfig()
	c.User = cfg.User
	c.Passwd = cfg.Password
	c.Net = "tcp"
	c.Addr = fmt.Sprintf("%s:%d", host, cfg.Port)
	c.DBName = cfg.Database
	c.ParseTime = true
	c.Loc = time.UTC
	c.Timeout = cfg.Timeout
	c.ReadTimeout = cfg.Timeout
	c.WriteTimeout = cfg.Timeout
	c.AllowNativePasswords = true
	c.TLSConfig = tlsName
	db, err := sql.Open("mysql", c.FormatDSN())
	if err != nil {
		return nil, err
	}
	// Bounded lifetime: a connection that was routed to a pod that has since gone is
	// dropped within minutes even if nothing errors on it.
	db.SetConnMaxLifetime(5 * time.Minute)
	db.SetConnMaxIdleTime(time.Minute)
	db.SetMaxOpenConns(2)
	db.SetMaxIdleConns(2)
	return db, nil
}

// registerMySQLTLS registers a verifying TLS config for the given CA. Without a CA the
// connection is still encrypted (instances require TLS) but the server is not verified:
// that is the kind test setup only, and production always sets a CA.
func registerMySQLTLS(caFile string) (string, error) {
	if caFile == "" {
		return "skip-verify", nil
	}
	pem, err := os.ReadFile(caFile)
	if err != nil {
		return "", fmt.Errorf("reading the CA bundle: %w", err)
	}
	pool := x509.NewCertPool()
	if !pool.AppendCertsFromPEM(pem) {
		return "", errors.New("the CA bundle holds no certificate")
	}
	const name = "dbaas-canary"
	if err := mysql.RegisterTLSConfig(name, &tls.Config{RootCAs: pool, MinVersion: tls.VersionTLS12}); err != nil {
		return "", err
	}
	return name, nil
}

func newMySQLStore(cfg DBConfig) (*mysqlStore, error) {
	tlsName, err := registerMySQLTLS(cfg.CAFile)
	if err != nil {
		return nil, err
	}
	w, err := openMySQL(cfg.WriteHost, cfg, tlsName)
	if err != nil {
		return nil, err
	}
	r, err := openMySQL(cfg.ReadHost, cfg, tlsName)
	if err != nil {
		_ = w.Close()
		return nil, err
	}
	return &mysqlStore{write: w, read: r}, nil
}

func (s *mysqlStore) Close() {
	_ = s.write.Close()
	_ = s.read.Close()
}

func (s *mysqlStore) Migrate(ctx context.Context) error {
	_, err := s.write.ExecContext(ctx, heartbeatDDLMySQL)
	return err
}

func (s *mysqlStore) Insert(ctx context.Context, writer string, seq int64, ts time.Time) error {
	_, err := s.write.ExecContext(ctx,
		"INSERT INTO heartbeat (writer, seq, ts) VALUES (?, ?, ?)", writer, seq, ts.UTC())
	return err
}

func (s *mysqlStore) Seqs(ctx context.Context, writer string, since time.Time) ([]int64, error) {
	rows, err := s.write.QueryContext(ctx,
		"SELECT seq FROM heartbeat WHERE writer = ? AND ts >= ?", writer, since.UTC())
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []int64
	for rows.Next() {
		var seq int64
		if err := rows.Scan(&seq); err != nil {
			return nil, err
		}
		out = append(out, seq)
	}
	return out, rows.Err()
}

func (s *mysqlStore) Prune(ctx context.Context, before time.Time) error {
	// Bounded batches keep each statement short; a long delete would hold locks on the primary.
	for {
		res, err := s.write.ExecContext(ctx,
			"DELETE FROM heartbeat WHERE ts < ? LIMIT 5000", before.UTC())
		if err != nil {
			return err
		}
		n, err := res.RowsAffected()
		if err != nil || n < 5000 {
			return err
		}
	}
}

func (s *mysqlStore) LatestTS(ctx context.Context) (time.Time, error) {
	var ts sql.NullTime
	if err := s.read.QueryRowContext(ctx, "SELECT MAX(ts) FROM heartbeat").Scan(&ts); err != nil {
		return time.Time{}, err
	}
	if !ts.Valid {
		return time.Time{}, nil
	}
	return ts.Time, nil
}
