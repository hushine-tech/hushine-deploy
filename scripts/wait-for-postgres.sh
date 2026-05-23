#!/usr/bin/env bash
set -euo pipefail

PGHOST="${PGHOST:-127.0.0.1}"
PGPORT="${PGPORT:-5432}"
PGUSER="${PGUSER:-postgres}"
PGPASSWORD="${PGPASSWORD:-postgres}"
PGDATABASE_ADMIN="${PGDATABASE_ADMIN:-postgres}"
TIMEOUT_SECONDS="${TIMEOUT_SECONDS:-90}"

deadline=$((SECONDS + TIMEOUT_SECONDS))

ready() {
  if command -v pg_isready >/dev/null 2>&1; then
    PGPASSWORD="$PGPASSWORD" pg_isready -h "$PGHOST" -p "$PGPORT" -U "$PGUSER" -d "$PGDATABASE_ADMIN" >/dev/null 2>&1
    return $?
  fi
  if command -v docker >/dev/null 2>&1; then
    docker compose -f deploy/local/docker-compose.yml exec -T timescaledb \
      pg_isready -U "$PGUSER" -d "$PGDATABASE_ADMIN" >/dev/null 2>&1
    return $?
  fi
  return 1
}

until ready; do
  if (( SECONDS >= deadline )); then
    echo "wait-for-postgres: timeout waiting for ${PGHOST}:${PGPORT}/${PGDATABASE_ADMIN}" >&2
    exit 1
  fi
  sleep 2
done

echo "postgres ready: ${PGHOST}:${PGPORT}/${PGDATABASE_ADMIN}"
