#!/usr/bin/env bash
#
# Create all Hushine databases + apply every service's migrations in the right
# order. Idempotent — safe to rerun on an existing environment.
#
# Honors standard PG env vars (see db/README.md):
#   PGHOST / PGPORT / PGUSER / PGPASSWORD / PGDATABASE_ADMIN
#
# Usage:
#   scripts/ensure-all-dbs.sh
#
# Or from the repo root:
#   make ensure-dbs
set -euo pipefail

DEPLOY_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
SOURCE_ROOT="${HUSHINE_SOURCE_ROOT:-$(cd -- "${DEPLOY_ROOT}/.." && pwd)}"

for required_repo in core-service control-panel-service scraper; do
	if [[ ! -d "${SOURCE_ROOT}/${required_repo}" ]]; then
		echo "missing required repository: ${SOURCE_ROOT}/${required_repo}" >&2
		exit 1
	fi
done

order_db_env=()
uses_pg_env=false
for pg_var in PGHOST PGPORT PGUSER PGPASSWORD; do
	if [[ -n "${!pg_var:-}" ]]; then
		uses_pg_env=true
	fi
done

if [[ -z "${ORDER_TIMESCALEDB_DSN:-}" && "$uses_pg_env" == true ]]; then
	[[ -n "${PGHOST:-}" && -z "${ORDER_DATABASE_HOST:-}" ]] && order_db_env+=("ORDER_DATABASE_HOST=${PGHOST}")
	[[ -n "${PGPORT:-}" && -z "${ORDER_DATABASE_PORT:-}" ]] && order_db_env+=("ORDER_DATABASE_PORT=${PGPORT}")
	[[ -n "${PGUSER:-}" && -z "${ORDER_DATABASE_USER:-}" ]] && order_db_env+=("ORDER_DATABASE_USER=${PGUSER}")
	[[ -n "${PGPASSWORD:-}" && -z "${ORDER_DATABASE_PASSWORD:-}" ]] && order_db_env+=("ORDER_DATABASE_PASSWORD=${PGPASSWORD}")
	[[ -z "${ORDER_DATABASE_DBNAME:-}" ]] && order_db_env+=("ORDER_DATABASE_DBNAME=order")
	[[ -z "${ORDER_DATABASE_SSLMODE:-}" ]] && order_db_env+=("ORDER_DATABASE_SSLMODE=disable")
fi

echo "→ core-service (database: portfolio)"
make -C "$SOURCE_ROOT/core-service" ensure-db

echo ""
echo "→ core-service order module (database: order)"
env "${order_db_env[@]}" make -C "$SOURCE_ROOT/core-service" ensure-order-db

echo ""
echo "→ control-panel-service (database: control_panel)"
make -C "$SOURCE_ROOT/control-panel-service" ensure-db

echo ""
echo "→ scraper (databases: {exchange}_{year}; defaults to current-year binance/okx)"
make -C "$SOURCE_ROOT/scraper" ensure-db

echo ""
echo "✓ all databases ready"
