#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
DEPLOY_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd -P)"
SOURCE_ROOT="${HUSHINE_SOURCE_ROOT:-$(cd "${DEPLOY_ROOT}/.." && pwd -P)}"
CORE_ROOT="${SOURCE_ROOT}/core-service"

PGHOST="${PGHOST:-127.0.0.1}"
PGPORT="${PGPORT:-5432}"
PGUSER="${PGUSER:-postgres}"
PGPASSWORD="${PGPASSWORD:-postgres}"
PGDATABASE_ADMIN="${PGDATABASE_ADMIN:-postgres}"
export PGHOST PGPORT PGUSER PGPASSWORD PGDATABASE_ADMIN

for command in go openssl python3; do
  command -v "${command}" >/dev/null 2>&1 || {
    echo "runtime Indicator V2 DB smoke requires ${command}" >&2
    exit 2
  }
done

PSQL_TRANSPORT=local
POSTGRES_CONTAINER=""
if ! command -v psql >/dev/null 2>&1; then
  command -v docker >/dev/null 2>&1 || {
    echo "runtime Indicator V2 DB smoke requires psql or Docker" >&2
    exit 2
  }
  if [[ "${PGHOST}" != "127.0.0.1" && "${PGHOST}" != "localhost" ]]; then
    echo "container psql fallback is only valid for local PostgreSQL" >&2
    exit 2
  fi
  POSTGRES_CONTAINER="${HUSHINE_LOCAL_POSTGRES_CONTAINER:-hushine-local-timescaledb-1}"
  docker inspect "${POSTGRES_CONTAINER}" >/dev/null 2>&1 || {
    echo "local PostgreSQL container is unavailable: ${POSTGRES_CONTAINER}" >&2
    exit 2
  }
  PSQL_TRANSPORT=container
fi

run_psql() {
  if [[ "${PSQL_TRANSPORT}" == "local" ]]; then
    command psql "$@"
    return
  fi
  docker exec -i \
    -e PGPASSWORD="${PGPASSWORD}" \
    "${POSTGRES_CONTAINER}" \
    psql -h 127.0.0.1 -p 5432 -U "${PGUSER}" "$@"
}

run_suffix="$(
  {
    printf '%s' "$$"
    openssl rand -hex 8
  } | tr -d '\n' | tr '[:upper:]' '[:lower:]'
)"
FRESH_DB="hushine_indicator_acceptance_${run_suffix}_fresh"
BUNDLE_DB="hushine_indicator_acceptance_${run_suffix}_bundle"
UPGRADE_DB="hushine_indicator_acceptance_${run_suffix}_upgrade"
ORDER_GUARD_DB="hushine_indicator_acceptance_${run_suffix}_order_guard"
OWNED_DATABASES=(
  "${FRESH_DB}"
  "${BUNDLE_DB}"
  "${UPGRADE_DB}"
  "${ORDER_GUARD_DB}"
)
WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/hushine-indicator-v2-db.XXXXXX")"
chmod 700 "${WORK_DIR}"

is_owned_database_name() {
  [[ "$1" =~ ^hushine_indicator_acceptance_[a-z0-9_]+$ ]]
}

database_exists() {
  local database="$1"
  is_owned_database_name "${database}" || {
    echo "refusing unsafe database existence check ${database}" >&2
    return 1
  }
  run_psql -X -v ON_ERROR_STOP=1 -d "${PGDATABASE_ADMIN}" -At \
    -c "SELECT EXISTS(SELECT 1 FROM pg_database WHERE datname='${database}')" \
    | grep -qx 't'
}

drop_owned_database() {
  local database="$1"
  is_owned_database_name "${database}" || {
    echo "refusing unsafe cleanup database ${database}" >&2
    return 1
  }
  if ! database_exists "${database}"; then
    return 0
  fi
  run_psql -X -v ON_ERROR_STOP=1 -d "${PGDATABASE_ADMIN}" \
    -v database_name="${database}" >/dev/null <<'SQL'
SELECT pg_terminate_backend(pid)
FROM pg_stat_activity
WHERE datname=:'database_name' AND pid <> pg_backend_pid();
SELECT format('DROP DATABASE %I', :'database_name') \gexec
SQL
}

cleanup() {
  local status=$?
  trap - EXIT INT TERM
  local cleanup_status=0
  for database in "${OWNED_DATABASES[@]}"; do
    drop_owned_database "${database}" || cleanup_status=1
  done
  rm -rf "${WORK_DIR}"
  if [[ "${status}" -eq 0 && "${cleanup_status}" -ne 0 ]]; then
    status="${cleanup_status}"
  fi
  exit "${status}"
}
trap cleanup EXIT INT TERM

create_owned_database() {
  local database="$1"
  is_owned_database_name "${database}" || {
    echo "refusing unsafe database ${database}" >&2
    return 1
  }
  if database_exists "${database}"; then
    echo "refusing pre-existing acceptance database ${database}" >&2
    return 1
  fi
  run_psql -X -v ON_ERROR_STOP=1 -d "${PGDATABASE_ADMIN}" \
    -v database_name="${database}" >/dev/null <<'SQL'
SELECT format('CREATE DATABASE %I', :'database_name') \gexec
SQL
}

database_dsn="$(
  python3 - "${PGUSER}" "${PGPASSWORD}" "${PGHOST}" "${PGPORT}" "${PGDATABASE_ADMIN}" <<'PY'
import sys
from urllib.parse import quote

user, password, host, port, database = sys.argv[1:]
print(
    "postgres://"
    + quote(user, safe="")
    + ":"
    + quote(password, safe="")
    + "@"
    + host
    + ":"
    + port
    + "/"
    + quote(database, safe="")
    + "?sslmode=disable"
)
PY
)"
ADMIN_DSN="${HUSHINE_TEST_PG_ADMIN_DSN:-${database_dsn}}"

run_integration_without_skip() {
  local test_name="$1"
  local database="$2"
  local log="${WORK_DIR}/${test_name}.log"
  (
    cd "${CORE_ROOT}/internal/storage/migrations"
    HUSHINE_TEST_PG_ADMIN_DSN="${ADMIN_DSN}" \
      HUSHINE_TEST_DATABASE_NAME="${database}" \
      go test -tags=integration . -run "^${test_name}$" -count=1 -v
  ) 2>&1 | tee "${log}"
  if grep -Eq -- '(^|[[:space:]])SKIP([[:space:]]|:|$)' "${log}"; then
    echo "${test_name} skipped during mandatory DB smoke" >&2
    return 1
  fi
  if database_exists "${database}"; then
    echo "${test_name} left its owned database behind" >&2
    return 1
  fi
}

run_portfolio_runner() {
  local database="$1"
  (
    cd "${CORE_ROOT}"
    PGDATABASE_PORTFOLIO="${database}" go run ./cmd/ensure-portfolio-db
  )
}

psql_owned() {
  local database="$1"
  shift
  is_owned_database_name "${database}" || {
    echo "refusing unsafe psql target ${database}" >&2
    return 1
  }
  run_psql -X -v ON_ERROR_STOP=1 -d "${database}" "$@"
}

indicator_v1_rows() {
  psql_owned "${UPGRADE_DB}" -Atc \
    "SELECT (SELECT count(*) FROM strategy_indicator_definitions) + (SELECT count(*) FROM strategy_indicator_chunks)"
}

schema_fingerprint() {
  local database="$1"
  psql_owned "${database}" -Atc "
SELECT md5(
  COALESCE(
    (
      SELECT string_agg(filename, ',' ORDER BY filename)
      FROM schema_migrations
    ),
    ''
  ) || '|' || COALESCE(
    (
      SELECT string_agg(table_name || '.' || column_name, ',' ORDER BY table_name, column_name)
      FROM information_schema.columns
      WHERE table_schema='public'
    ),
    ''
  )
)"
}

order_rows_fingerprint() {
  psql_owned "${ORDER_GUARD_DB}" -Atc "
SELECT md5(
  (SELECT string_agg(to_jsonb(item)::text, '' ORDER BY order_id) FROM orders AS item)
  ||
  (SELECT string_agg(to_jsonb(item)::text, '' ORDER BY fill_id) FROM order_fills AS item)
)"
}

echo "→ Generated schema bundle matches current service migrations"
rendered_bundle_dir="${WORK_DIR}/generated"
HUSHINE_SOURCE_ROOT="${SOURCE_ROOT}" \
  bash "${DEPLOY_ROOT}/scripts/db/render-schema-bundle.sh" \
  "${rendered_bundle_dir}" >/dev/null
for generated_file in \
  00_create_databases.psql \
  portfolio.sql \
  order.sql \
  control_panel.sql \
  market_data_year.sql \
  README.md; do
  cmp \
    "${rendered_bundle_dir}/${generated_file}" \
    "${DEPLOY_ROOT}/db/generated/${generated_file}" \
    || {
      echo "tracked schema bundle is stale: ${generated_file}" >&2
      exit 1
    }
done

echo "→ Indicator V2 isolated migration tests"
run_integration_without_skip \
  TestIndicatorV2FreshBootstrapIsCompleteAndIdempotent \
  "${FRESH_DB}"
run_integration_without_skip \
  TestIndicatorV1PopulatedUpgradePreservesEveryRetainedTable \
  "${UPGRADE_DB}"

for database in "${OWNED_DATABASES[@]}"; do
  create_owned_database "${database}"
done

echo "→ Production runner fresh bootstrap and idempotence"
fresh_first="${WORK_DIR}/fresh-first.log"
fresh_second="${WORK_DIR}/fresh-second.log"
run_portfolio_runner "${FRESH_DB}" | tee "${fresh_first}"
grep -Fq \
  "ensure-portfolio-db: OK (database ${FRESH_DB} + migrations)" \
  "${fresh_first}"
fresh_hash="$(schema_fingerprint "${FRESH_DB}")"
run_portfolio_runner "${FRESH_DB}" | tee "${fresh_second}"
grep -Fq \
  "ensure-portfolio-db: OK (database ${FRESH_DB} + migrations)" \
  "${fresh_second}"
[[ "$(schema_fingerprint "${FRESH_DB}")" == "${fresh_hash}" ]] || {
  echo "fresh production runner is not idempotent" >&2
  exit 1
}

echo "→ Generated portfolio bundle fresh bootstrap and idempotence"
psql_owned "${BUNDLE_DB}" \
  <"${DEPLOY_ROOT}/db/generated/portfolio.sql" >/dev/null
bundle_hash="$(schema_fingerprint "${BUNDLE_DB}")"
psql_owned "${BUNDLE_DB}" \
  <"${DEPLOY_ROOT}/db/generated/portfolio.sql" >/dev/null
[[ "$(schema_fingerprint "${BUNDLE_DB}")" == "${bundle_hash}" ]] || {
  echo "generated portfolio bundle is not idempotent" >&2
  exit 1
}
[[ "$(
  psql_owned "${BUNDLE_DB}" -Atc "
SELECT
  NOT EXISTS (
    SELECT 1
    FROM information_schema.columns
    WHERE table_schema='public'
      AND table_name='strategy_indicator_chunks'
      AND column_name='values_json'
  )
  AND EXISTS (
    SELECT 1
    FROM information_schema.columns
    WHERE table_schema='public'
      AND table_name='strategy_indicator_chunks'
      AND column_name='protocol_version'
  )
"
)" == "t" ]] || {
  echo "generated portfolio bundle did not bootstrap Indicator V2" >&2
  exit 1
}

echo "→ Populate a legacy V1 target behind the destructive guard"
run_portfolio_runner "${UPGRADE_DB}" >/dev/null
psql_owned "${UPGRADE_DB}" \
  <"${CORE_ROOT}/internal/storage/migrations/testdata/indicator_v1_fixture.sql" \
  >/dev/null
[[ "$(indicator_v1_rows)" == "4" ]] || {
  echo "legacy V1 fixture did not produce four rows" >&2
  exit 1
}

echo "→ Seed a separate order/fill database"
psql_owned "${ORDER_GUARD_DB}" \
  <"${DEPLOY_ROOT}/db/generated/order.sql" >/dev/null
psql_owned "${ORDER_GUARD_DB}" >/dev/null <<'SQL'
INSERT INTO order_intents (
  intent_id, time, updated_at, portfolio_id, venue_id, user_id, strategy_id,
  session_id, environment, exchange, market, symbol, side, position_side,
  order_type, requested_qty, requested_price, status
) VALUES (
  'indicator-v2-intent', '2026-01-01T00:00:00Z', '2026-01-01T00:00:00Z',
  1, 1, 1, 1, 'indicator-v2-session', 1, 1, 1, 'TESTUSDT', 1, 0, 1,
  1, 100, 2
);
INSERT INTO order_attempts (
  attempt_id, intent_id, time, updated_at, status
) VALUES (
  'indicator-v2-attempt', 'indicator-v2-intent',
  '2026-01-01T00:00:00Z', '2026-01-01T00:00:00Z', 2
);
INSERT INTO orders (
  order_id, attempt_id, intent_id, orig_qty, executed_qty, remaining_qty,
  avg_price, price, status, time, updated_at
) VALUES (
  'indicator-v2-order', 'indicator-v2-attempt', 'indicator-v2-intent',
  1, 1, 0, 100, 100, 3, '2026-01-01T00:00:00Z',
  '2026-01-01T00:00:00Z'
);
INSERT INTO order_fills (
  time, fill_id, order_id, attempt_id, intent_id, qty, fill_price, status
) VALUES (
  '2026-01-01T00:00:00Z', 'indicator-v2-fill', 'indicator-v2-order',
  'indicator-v2-attempt', 'indicator-v2-intent', 1, 100, 1
);
SQL
order_hash_before="$(order_rows_fingerprint)"

owner_token="$(openssl rand -hex 32)"
mismatched_token="$(openssl rand -hex 32)"
owner_file="${WORK_DIR}/upgrade-owner.json"
mismatched_owner_file="${WORK_DIR}/upgrade-owner-mismatch.json"
printf '{"schema":1,"database":"%s","owner_token":"%s"}\n' \
  "${UPGRADE_DB}" "${owner_token}" >"${owner_file}"
printf '{"schema":1,"database":"%s","owner_token":"%s"}\n' \
  "${UPGRADE_DB}" "${mismatched_token}" >"${mismatched_owner_file}"
chmod 600 "${owner_file}" "${mismatched_owner_file}"
run_psql -X -v ON_ERROR_STOP=1 -d "${PGDATABASE_ADMIN}" \
  -c "COMMENT ON DATABASE \"${UPGRADE_DB}\" IS 'hushine-indicator-acceptance:${owner_token}'" \
  >/dev/null

echo "→ Destructive guard rejects missing and mismatched ownership"
if run_portfolio_runner "${UPGRADE_DB}" >"${WORK_DIR}/missing-owner.log" 2>&1; then
  echo "legacy V1 migration ran without explicit ownership" >&2
  exit 1
fi
grep -Fq 'INDICATOR_V2_CUTOVER_AUTH_REQUIRED' "${WORK_DIR}/missing-owner.log"
[[ "$(indicator_v1_rows)" == "4" ]] || {
  echo "missing-owner rejection changed V1 rows" >&2
  exit 1
}
if (
  export HUSHINE_INDICATOR_V2_DESTRUCTIVE_MODE=acceptance
  export HUSHINE_INDICATOR_V2_ACCEPTANCE_OWNER_FILE="${mismatched_owner_file}"
  run_portfolio_runner "${UPGRADE_DB}"
) >"${WORK_DIR}/mismatched-owner.log" 2>&1; then
  echo "legacy V1 migration accepted a mismatched owner token" >&2
  exit 1
fi
grep -Fq 'INDICATOR_V2_ACCEPTANCE_OWNERSHIP_INVALID' \
  "${WORK_DIR}/mismatched-owner.log"
[[ "$(indicator_v1_rows)" == "4" ]] || {
  echo "mismatched-owner rejection changed V1 rows" >&2
  exit 1
}

echo "→ Owned destructive indicator-only upgrade"
(
  export HUSHINE_INDICATOR_V2_DESTRUCTIVE_MODE=acceptance
  export HUSHINE_INDICATOR_V2_ACCEPTANCE_OWNER_FILE="${owner_file}"
  run_portfolio_runner "${UPGRADE_DB}"
) | tee "${WORK_DIR}/owned-upgrade.log"
grep -Fq \
  "ensure-portfolio-db: OK (database ${UPGRADE_DB} + migrations)" \
  "${WORK_DIR}/owned-upgrade.log"
[[ "$(indicator_v1_rows)" == "0" ]] || {
  echo "owned V1 upgrade left legacy indicator rows" >&2
  exit 1
}
psql_owned "${UPGRADE_DB}" -Atc "
SELECT count(*) = 10
FROM information_schema.columns
WHERE table_schema='public' AND (
  (
    table_name='strategy_indicator_chunks' AND column_name IN (
      'start_sequence', 'end_sequence', 'times_ms', 'scalar_values',
      'markers_json', 'revision', 'finalized', 'protocol_version'
    )
  )
  OR (
    table_name='strategy_indicator_definitions'
    AND column_name='protocol_version'
  )
  OR (
    table_name='strategy_sessions'
    AND column_name='indicator_finalization_pending'
  )
)" | grep -qx 't'
[[ "$(order_rows_fingerprint)" == "${order_hash_before}" ]] || {
  echo "portfolio indicator upgrade changed the separate order/fill database" >&2
  exit 1
}

echo "✓ Runtime Indicator V2 database smoke passed"
