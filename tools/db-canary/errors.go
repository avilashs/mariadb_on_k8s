package main

import (
	"database/sql"
	"errors"

	"github.com/go-sql-driver/mysql"
	"github.com/jackc/pgx/v5/pgconn"
)

// isReadOnlyError reports whether a database error says that the server the connection
// points at is read-only. That is what the old primary answers after a planned switchover
// demoted it in place: the TCP connection stays open, so a pooled connection keeps reaching
// the old primary and every write on it fails until the pool dials again.
//
//	MariaDB 1290: the server runs with the --read-only option
//	MariaDB 1792: cannot execute a statement in a read-only transaction
//	MariaDB 1836: running in read-only mode
//	PostgreSQL 25006: read_only_sql_transaction
func isReadOnlyError(err error) bool {
	var me *mysql.MySQLError
	if errors.As(err, &me) {
		switch me.Number {
		case 1290, 1792, 1836:
			return true
		}
	}
	var pe *pgconn.PgError
	return errors.As(err, &pe) && pe.Code == "25006"
}

// dropIdleConns closes the idle connections of a pool, so the next attempt dials the Service
// again and reaches whatever pod holds the role now. database/sql discards a connection only
// on a bad-connection error; a read-only error is not one, so without this the connection
// would live until ConnMaxLifetime.
func dropIdleConns(db *sql.DB, keep int) {
	db.SetMaxIdleConns(0)
	db.SetMaxIdleConns(keep)
}
