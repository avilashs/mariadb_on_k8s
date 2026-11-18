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

	pgx "github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/stdlib"
)

const heartbeatDDLPostgres = `CREATE TABLE IF NOT EXISTS heartbeat (
  writer text NOT NULL,
  seq bigint NOT NULL,
  ts timestamptz NOT NULL,
  PRIMARY KEY (writer, seq)
);
CREATE INDEX IF NOT EXISTS heartbeat_ts ON heartbeat (ts)`

// postgresStore implements Writer and Reader over the PostgreSQL protocol.
type postgresStore struct {
	write *sql.DB
	read  *sql.DB
}

func openPostgres(host string, cfg DBConfig, tlsConf *tls.Config) (*sql.DB, error) {
	c, err := pgx.ParseConfig("")
	if err != nil {
		return nil, err
	}
	c.Host = host
	c.Port = uint16(cfg.Port)
	c.User = cfg.User
	c.Password = cfg.Password
	c.Database = cfg.Database
	c.ConnectTimeout = cfg.Timeout
	c.TLSConfig = tlsConf
	db := stdlib.OpenDB(*c)
	db.SetConnMaxLifetime(5 * time.Minute)
	db.SetConnMaxIdleTime(time.Minute)
	db.SetMaxOpenConns(2)
	db.SetMaxIdleConns(2)
	return db, nil
}

func postgresTLS(caFile string) (*tls.Config, error) {
	if caFile == "" {
		// Encrypted, not verified: kind test setup only. Production sets a CA.
		return &tls.Config{InsecureSkipVerify: true, MinVersion: tls.VersionTLS12}, nil //nolint:gosec // see above
	}
	pem, err := os.ReadFile(caFile)
	if err != nil {
		return nil, fmt.Errorf("reading the CA bundle: %w", err)
	}
	pool := x509.NewCertPool()
	if !pool.AppendCertsFromPEM(pem) {
		return nil, errors.New("the CA bundle holds no certificate")
	}
	return &tls.Config{RootCAs: pool, MinVersion: tls.VersionTLS12}, nil
}

func newPostgresStore(cfg DBConfig) (*postgresStore, error) {
	tlsConf, err := postgresTLS(cfg.CAFile)
	if err != nil {
		return nil, err
	}
	w, err := openPostgres(cfg.WriteHost, cfg, tlsConf)
	if err != nil {
		return nil, err
	}
	r, err := openPostgres(cfg.ReadHost, cfg, tlsConf)
	if err != nil {
		_ = w.Close()
		return nil, err
	}
	return &postgresStore{write: w, read: r}, nil
}

func (s *postgresStore) Close() {
	_ = s.write.Close()
	_ = s.read.Close()
}

func (s *postgresStore) Migrate(ctx context.Context) error {
	_, err := s.write.ExecContext(ctx, heartbeatDDLPostgres)
	return err
}

func (s *postgresStore) Insert(ctx context.Context, writer string, seq int64, ts time.Time) error {
	_, err := s.write.ExecContext(ctx,
		"INSERT INTO heartbeat (writer, seq, ts) VALUES ($1, $2, $3)", writer, seq, ts.UTC())
	return err
}

func (s *postgresStore) Seqs(ctx context.Context, writer string, since time.Time) ([]int64, error) {
	rows, err := s.write.QueryContext(ctx,
		"SELECT seq FROM heartbeat WHERE writer = $1 AND ts >= $2", writer, since.UTC())
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

func (s *postgresStore) Prune(ctx context.Context, before time.Time) error {
	_, err := s.write.ExecContext(ctx, "DELETE FROM heartbeat WHERE ts < $1", before.UTC())
	return err
}

func (s *postgresStore) LatestTS(ctx context.Context) (time.Time, error) {
	var ts sql.NullTime
	if err := s.read.QueryRowContext(ctx, "SELECT max(ts) FROM heartbeat").Scan(&ts); err != nil {
		return time.Time{}, err
	}
	if !ts.Valid {
		return time.Time{}, nil
	}
	return ts.Time, nil
}
