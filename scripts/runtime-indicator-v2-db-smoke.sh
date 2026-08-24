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
OWNED_DATABASES=(
  "${FRESH_DB}"
  "${BUNDLE_DB}"
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

echo "→ Generated portfolio bundle matches current service migrations"
rendered_bundle_dir="${WORK_DIR}/generated"
HUSHINE_SOURCE_ROOT="${SOURCE_ROOT}" \
  bash "${DEPLOY_ROOT}/scripts/db/render-schema-bundle.sh" \
  "${rendered_bundle_dir}" >/dev/null
cmp \
  "${rendered_bundle_dir}/portfolio.sql" \
  "${DEPLOY_ROOT}/db/generated/portfolio.sql" \
  || {
    echo "tracked schema bundle is stale: portfolio.sql" >&2
    exit 1
  }

echo "→ Indicator V2 fresh-baseline integration test"
run_integration_without_skip \
  TestPortfolioBaselineFreshBootstrapIsCompleteAndIdempotent \
  "${FRESH_DB}"

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

echo "✓ Runtime Indicator V2 database smoke passed"
