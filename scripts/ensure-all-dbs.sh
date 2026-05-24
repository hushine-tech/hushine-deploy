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

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"

echo "→ core-service (database: account)"
make -C "$ROOT_DIR/core-service" ensure-db

echo ""
echo "→ core-service order module (database: order)"
make -C "$ROOT_DIR/core-service" ensure-order-db

echo ""
echo "→ control-panel-service (database: control_panel)"
make -C "$ROOT_DIR/control-panel-service" ensure-db

echo ""
echo "→ scraper (databases: {exchange}_{year}; defaults to current-year binance/okx)"
make -C "$ROOT_DIR/scraper" ensure-db

echo ""
echo "✓ all databases ready"
