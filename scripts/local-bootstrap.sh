#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"

"$ROOT_DIR/scripts/wait-for-postgres.sh"

PGHOST=127.0.0.1 \
PGPORT=5432 \
PGUSER=postgres \
PGPASSWORD=postgres \
PGDATABASE_ADMIN=postgres \
  bash "$ROOT_DIR/scripts/ensure-all-dbs.sh"
