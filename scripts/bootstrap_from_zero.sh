#!/usr/bin/env bash
set -euo pipefail

# Usage:
#   DB_PASSWORD='strong_pass' ./scripts/bootstrap_from_zero.sh
# Optional env:
#   DB_NAME=wialon_wifi
#   DB_USER=wialon_wifi
#   PGHOST=127.0.0.1
#   PGPORT=5432
#   PG_SUPERUSER=postgres

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

DB_NAME="${DB_NAME:-wialon_wifi}"
DB_USER="${DB_USER:-wialon_wifi}"
DB_PASSWORD="${DB_PASSWORD:-}"
PGHOST="${PGHOST:-127.0.0.1}"
PGPORT="${PGPORT:-5432}"
PG_SUPERUSER="${PG_SUPERUSER:-postgres}"

if [[ -z "$DB_PASSWORD" ]]; then
  echo "ERROR: DB_PASSWORD is required"
  exit 1
fi

PSQL_SUPER=(psql -v ON_ERROR_STOP=1 -h "$PGHOST" -p "$PGPORT" -U "$PG_SUPERUSER")

echo "[1/5] Ensuring role '$DB_USER' exists..."
ROLE_EXISTS="$(${PSQL_SUPER[@]} -d postgres -Atqc "SELECT 1 FROM pg_roles WHERE rolname='${DB_USER}'")"
if [[ "$ROLE_EXISTS" != "1" ]]; then
  ${PSQL_SUPER[@]} -d postgres -c "CREATE ROLE \"${DB_USER}\" LOGIN PASSWORD '${DB_PASSWORD}';"
else
  echo "Role '$DB_USER' already exists"
fi

echo "[2/5] Ensuring database '$DB_NAME' exists..."
DB_EXISTS="$(${PSQL_SUPER[@]} -d postgres -Atqc "SELECT 1 FROM pg_database WHERE datname='${DB_NAME}'")"
if [[ "$DB_EXISTS" != "1" ]]; then
  ${PSQL_SUPER[@]} -d postgres -c "CREATE DATABASE \"${DB_NAME}\" OWNER \"${DB_USER}\";"
else
  echo "Database '$DB_NAME' already exists"
fi

echo "[3/5] Applying schema migrations..."
for f in \
  "$ROOT_DIR/sql/001_schema.sql" \
  "$ROOT_DIR/sql/002_constraints_indexes.sql" \
  "$ROOT_DIR/sql/003_sd_parser_trigger.sql" \
  "$ROOT_DIR/sql/004_retention.sql" \
  "$ROOT_DIR/sql/005_grants.sql"
do
  echo "  -> $(basename "$f")"
  ${PSQL_SUPER[@]} -d "$DB_NAME" -f "$f"
done

echo "[4/5] Running smoke test (transaction rollback)..."
${PSQL_SUPER[@]} -d "$DB_NAME" -f "$ROOT_DIR/sql/006_smoke_test.sql"

echo "[5/5] Done"
echo "Database '$DB_NAME' is initialized for Wialon ingestion."
