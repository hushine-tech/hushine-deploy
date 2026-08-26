#!/usr/bin/env bash
set -euo pipefail

SCRIPT_PATH="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)/$(basename "${BASH_SOURCE[0]}")"
DEPLOY_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
SOURCE_ROOT="${HUSHINE_SOURCE_ROOT:-$(cd "${DEPLOY_ROOT}/.." && pwd -P)}"
PG_CONTAINER="${HUSHINE_LOCAL_PG_CONTAINER:-hushine-local-timescaledb-1}"
PG_HOST="${HUSHINE_LOCAL_PG_HOST:-127.0.0.1}"
PG_PORT="${HUSHINE_LOCAL_PG_PORT:-5432}"
PG_USER="${HUSHINE_LOCAL_PG_USER:-postgres}"
PG_PASSWORD="${HUSHINE_LOCAL_PG_PASSWORD:-postgres}"
RUNTIME_IMAGE="${HUSHINE_INDICATOR_CHAIN_IMAGE:-hushine/strategy-runtime:executor-coverage-dev}"
START_TIME_MS=1735689600000
END_TIME_MS=1735812600000

export NO_PROXY="127.0.0.1,localhost,::1,host.docker.internal${NO_PROXY:+,${NO_PROXY}}"
export no_proxy="${NO_PROXY}"
umask 077

die() {
  echo "runtime Indicator V2 service-chain: $*" >&2
  exit 1
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"
}

run_clean_env() {
  env -i \
    PATH="${PATH}" \
    HOME="${HOME:-/tmp}" \
    TMPDIR="${TMPDIR:-/tmp}" \
    USER="${USER:-hushine}" \
    LOGNAME="${LOGNAME:-${USER:-hushine}}" \
    LANG="${LANG:-C.UTF-8}" \
    NO_PROXY="${NO_PROXY}" \
    no_proxy="${no_proxy}" \
    "$@"
}

exec_clean_env() {
  exec env -i \
    PATH="${PATH}" \
    HOME="${HOME:-/tmp}" \
    TMPDIR="${TMPDIR:-/tmp}" \
    USER="${USER:-hushine}" \
    LOGNAME="${LOGNAME:-${USER:-hushine}}" \
    LANG="${LANG:-C.UTF-8}" \
    NO_PROXY="${NO_PROXY}" \
    no_proxy="${no_proxy}" \
    "$@"
}

canonical_state_dir() {
  local requested="$1" canonical
  [[ "${requested}" == /* ]] || die "--state-dir must be absolute"
  [[ ! -L "${requested}" ]] || die "--state-dir must not be a symlink"
  mkdir -p -- "${requested}"
  chmod 0700 "${requested}"
  canonical="$(cd "${requested}" && pwd -P)"
  [[ "${canonical}" == "${requested}" ]] || die "--state-dir must be canonical"
  printf '%s\n' "${canonical}"
}

atomic_json() {
  local destination="$1"
  shift
  local temporary="${destination}.tmp.$$"
  jq "$@" >"${temporary}"
  chmod 0600 "${temporary}"
  mv -f -- "${temporary}" "${destination}"
}

safe_database_name() {
  [[ "$1" =~ ^hushine_indicator_chain_[a-z0-9_]+$ && ${#1} -le 63 ]]
}

pg_admin() {
  docker exec -i \
    -e PGPASSWORD="${PG_PASSWORD}" \
    "${PG_CONTAINER}" \
    psql -X -v ON_ERROR_STOP=1 \
      -h "${PG_HOST}" -p "${PG_PORT}" \
      -U "${PG_USER}" -d postgres "$@"
}

pg_database() {
  local database="$1"
  shift
  safe_database_name "${database}" || die "unsafe chain database name: ${database}"
  docker exec -i \
    -e PGPASSWORD="${PG_PASSWORD}" \
    "${PG_CONTAINER}" \
    psql -X -v ON_ERROR_STOP=1 \
      -h "${PG_HOST}" -p "${PG_PORT}" \
      -U "${PG_USER}" -d "${database}" "$@"
}

database_exists() {
  local database="$1"
  [[ "$(pg_admin -Atc "SELECT count(*) FROM pg_database WHERE datname = '${database}'")" == "1" ]]
}

database_comment() {
  local database="$1"
  pg_admin -Atc \
    "SELECT COALESCE(shobj_description(oid, 'pg_database'), '') FROM pg_database WHERE datname = '${database}'"
}

choose_port() {
  python3 - <<'PY'
import socket
sock = socket.socket()
sock.bind(("127.0.0.1", 0))
print(sock.getsockname()[1])
sock.close()
PY
}

process_start_identity() {
  ps -o lstart= -p "$1" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//'
}

record_process() {
  local state_dir="$1" name="$2" pid="$3" identity temporary
  identity="$(process_start_identity "${pid}")"
  [[ -n "${identity}" ]] || die "${name} exited before its process identity was recorded"
  temporary="${state_dir}/pids.json.tmp.$$"
  jq \
    --arg name "${name}" \
    --argjson pid "${pid}" \
    --arg process_start_identity "${identity}" \
    '. + [{
      name: $name,
      pid: $pid,
      process_start_identity: $process_start_identity
    }]' \
    "${state_dir}/pids.json" >"${temporary}"
  chmod 0600 "${temporary}"
  mv -f -- "${temporary}" "${state_dir}/pids.json"
}

process_matches() {
  local pid="$1" expected="$2" actual
  kill -0 "${pid}" 2>/dev/null || return 1
  actual="$(process_start_identity "${pid}")"
  [[ -n "${actual}" && "${actual}" == "${expected}" ]]
}

send_process_signal() {
  kill "-$1" "$2"
}

terminate_owned_process() {
  local pid="$1" identity="$2" term_checks="${3:-40}"
  [[ "${pid}" =~ ^[0-9]+$ && "${pid}" -gt 1 && -n "${identity}" ]] || return 1
  [[ "${term_checks}" =~ ^[0-9]+$ && "${term_checks}" -gt 0 ]] || return 1
  process_matches "${pid}" "${identity}" || return 0
  send_process_signal TERM "${pid}" 2>/dev/null || return 1
  for _ in $(seq 1 "${term_checks}"); do
    process_matches "${pid}" "${identity}" || return 0
    sleep 0.25
  done
  process_matches "${pid}" "${identity}" || return 0
  send_process_signal KILL "${pid}" 2>/dev/null || return 1
  for _ in $(seq 1 20); do
    process_matches "${pid}" "${identity}" || return 0
    sleep 0.1
  done
  ! process_matches "${pid}" "${identity}"
}

cleanup_failed_start() {
  local rc="$?"
  trap - EXIT INT TERM
  (( rc != 0 )) || rc=1
  if [[ -n "${STARTUP_SUPERVISOR_PID:-}" \
    && -n "${STARTUP_SUPERVISOR_IDENTITY:-}" ]]; then
    terminate_owned_process \
      "${STARTUP_SUPERVISOR_PID}" "${STARTUP_SUPERVISOR_IDENTITY}" 360 \
      || true
  fi
  exit "${rc}"
}

wait_http() {
  local url="$1" name="$2" deadline=$((SECONDS + 60))
  until curl -fsS "${url}" >/dev/null 2>&1; do
    (( SECONDS < deadline )) || die "${name} did not become ready at ${url}"
    sleep 1
  done
}

api_json() {
  local method="$1" url="$2" token="${3:-}" body="${4:-}"
  local args=(-fsS -X "${method}" -H "Accept: application/json")
  [[ -z "${token}" ]] || args+=(-H "Authorization: Bearer ${token}")
  if [[ -n "${body}" ]]; then
    args+=(-H "Content-Type: application/json" --data-binary "${body}")
  fi
  if ! curl "${args[@]}" "${url}"; then
    die "API ${method} ${url} failed"
  fi
}

source_sha_json() {
  local value='{}' repository sha
  for repository in \
    core-service \
    control-panel-service \
    strategy-service \
    strategy-library \
    strategy-debugger-cli \
    scraper \
    gateway/quant-handler \
    gateway/quant-frontend \
    hushine-deploy; do
    [[ -d "${SOURCE_ROOT}/${repository}" ]] \
      || die "repository is missing: ${repository}"
    sha="$(git -C "${SOURCE_ROOT}/${repository}" rev-parse HEAD)"
    value="$(jq -c --arg key "${repository}" --arg sha "${sha}" \
      '. + {($key): $sha}' <<<"${value}")"
  done
  printf '%s\n' "${value}"
}

source_dirty_json() {
  local value='{}' repository dirty
  for repository in \
    core-service \
    control-panel-service \
    strategy-service \
    strategy-library \
    strategy-debugger-cli \
    scraper \
    gateway/quant-handler \
    gateway/quant-frontend \
    hushine-deploy; do
    dirty=false
    [[ -z "$(git -C "${SOURCE_ROOT}/${repository}" status \
      --porcelain --untracked-files=normal)" ]] || dirty=true
    value="$(jq -c \
      --arg repository "${repository}" \
      --argjson dirty "${dirty}" \
      '. + {($repository):$dirty}' <<<"${value}")"
  done
  printf '%s\n' "${value}"
}

source_evidence_json() {
  local phase="$1" expected_shas="${2:-}" allow_dirty_debug="${3:-false}"
  local sources dirty evidence_eligible=true
  [[ "${allow_dirty_debug}" == "true" || "${allow_dirty_debug}" == "false" ]] \
    || die "invalid dirty debug mode"
  case "${phase}" in
    pre)
      [[ -z "${expected_shas}" ]] \
        || die "pre phase does not accept --expected-shas"
      sources="$(source_sha_json | jq -S -c .)"
      dirty="$(source_dirty_json | jq -S -c .)"
      if [[ "${allow_dirty_debug}" == "true" ]]; then
        evidence_eligible=false
      elif jq -e 'any(.[]; . == true)' <<<"${dirty}" >/dev/null; then
        die "normal pre-cutover start requires every source repository clean"
      fi
      ;;
    post)
      [[ "${allow_dirty_debug}" == "false" ]] \
        || die "post phase does not allow dirty debug mode"
      [[ -n "${expected_shas}" ]] \
        || die "post phase requires --expected-shas"
      sources="$(validate_expected_source_shas "${expected_shas}")"
      dirty="$(source_dirty_json | jq -S -c .)"
      jq -e 'all(.[]; . == false)' <<<"${dirty}" >/dev/null \
        || die "post-cutover source repository became dirty"
      ;;
    *)
      die "--phase must be pre or post"
      ;;
  esac
  jq -S -nc \
    --argjson source_shas "${sources}" \
    --argjson source_dirty "${dirty}" \
    --argjson evidence_eligible "${evidence_eligible}" \
    '{
      source_shas:$source_shas,
      source_dirty:$source_dirty,
      evidence_eligible:$evidence_eligible
    }'
}

runtime_image_labels_json() {
  docker image inspect --format '{{json .Config.Labels}}' "${RUNTIME_IMAGE}"
}

golang_lib_sha() {
  git -C "${SOURCE_ROOT}/golang-lib" rev-parse HEAD
}

golang_lib_is_clean() {
  [[ -z "$(git -C "${SOURCE_ROOT}/golang-lib" status \
    --porcelain --untracked-files=normal)" ]]
}

validate_runtime_image_provenance() {
  local sources="$1" evidence_eligible="$2" labels strategy library golang
  [[ "${evidence_eligible}" == "true" || "${evidence_eligible}" == "false" ]] \
    || return 1
  labels="$(runtime_image_labels_json)" || return 1
  strategy="$(jq -er '.["strategy-service"]' <<<"${sources}")" || return 1
  library="$(jq -er '.["strategy-library"]' <<<"${sources}")" || return 1
  golang="$(golang_lib_sha)" || return 1
  jq -e \
    --arg strategy "${strategy}" \
    --arg library "${library}" \
    --arg golang "${golang}" \
    --argjson evidence_eligible "${evidence_eligible}" \
    '
      type == "object"
      and .["org.hushine.runtime.strategy-service.commit"] == $strategy
      and .["org.hushine.runtime.strategy-library.commit"] == $library
      and .["org.hushine.runtime.golang-lib.commit"] == $golang
      and (.["org.hushine.runtime.source-dirty"] == "true"
        or .["org.hushine.runtime.source-dirty"] == "false")
      and (
        ($evidence_eligible | not)
        or .["org.hushine.runtime.source-dirty"] == "false"
      )
      and (.["org.hushine.runtime.source-state.sha256"]
        | test("^[0-9a-f]{64}$"))
      and (.["org.hushine.runtime.image-build-id"]
        | type == "string" and length > 0)
    ' <<<"${labels}" >/dev/null || return 1
  if [[ "${evidence_eligible}" == "true" ]]; then
    golang_lib_is_clean || return 1
  fi
  jq -S -c '{
    source_dirty:(.["org.hushine.runtime.source-dirty"] == "true"),
    strategy_service_commit:.["org.hushine.runtime.strategy-service.commit"],
    strategy_library_commit:.["org.hushine.runtime.strategy-library.commit"],
    golang_lib_commit:.["org.hushine.runtime.golang-lib.commit"],
    source_state_sha256:.["org.hushine.runtime.source-state.sha256"],
    image_build_id:.["org.hushine.runtime.image-build-id"]
  }' <<<"${labels}"
}

file_mode() {
  if stat -f '%Lp' "$1" >/dev/null 2>&1; then
    stat -f '%Lp' "$1"
  else
    stat -c '%a' "$1"
  fi
}

validate_owner_file() {
  local owner_file="$1" database
  [[ -f "${owner_file}" && ! -L "${owner_file}" ]] || return 1
  [[ "$(file_mode "${owner_file}")" == "600" ]] || return 1
  jq -e '
    type == "object"
    and (
      keys == ["databases", "generation", "owner_token", "schema"]
      or keys == ["databases", "generation", "owner_token", "runtime", "schema"]
    )
    and .schema == 1
    and (.owner_token | type == "string" and test("^[0-9a-f]{64}$"))
    and (.generation | type == "string" and test("^generation-[0-9a-f]{32}$"))
    and (.databases | type == "object")
    and (.databases | keys) == [
      "control_panel", "market", "market_prefix", "order", "portfolio"
    ]
    and (.databases.market_prefix
      | type == "string"
        and test("^hushine_indicator_chain_[a-z0-9_]+_$")
        and length <= 63)
    and .databases.portfolio == (.databases.market_prefix + "portfolio")
    and .databases.order == (.databases.market_prefix + "order")
    and .databases.control_panel == (.databases.market_prefix + "control")
    and .databases.market == (.databases.market_prefix + "binance_2025")
    and all(
      .databases.portfolio,
      .databases.order,
      .databases.control_panel,
      .databases.market;
      type == "string"
      and test("^hushine_indicator_chain_[a-z0-9_]+$")
      and length <= 63
    )
    and (
      (has("runtime") | not)
      or (
        (.runtime | type == "object")
        and (.runtime | keys) == [
          "container_id",
          "container_name",
          "coverage_mount_source",
          "coverage_run_id",
          "image_id",
          "resource_name",
          "runtime_id",
          "user_id"
        ]
        and (.runtime.container_id | test("^[0-9a-f]{64}$"))
        and (.runtime.image_id | test("^sha256:[0-9a-f]{64}$"))
        and (.runtime.runtime_id | test("^rt-[0-9a-f]{24}$"))
        and .runtime.container_name == ("hushine-runtime-" + .runtime.runtime_id)
        and (.runtime.user_id | type == "string" and test("^[0-9]+$"))
        and (.runtime.coverage_run_id | type == "string" and length > 0)
        and (.runtime.coverage_mount_source | type == "string" and startswith("/"))
        and (.runtime.resource_name | type == "string" and startswith("indicator-chain-"))
      )
    )
  ' "${owner_file}" >/dev/null || return 1
  while IFS= read -r database; do
    safe_database_name "${database}" || return 1
  done < <(jq -r '.databases | [.portfolio,.order,.control_panel,.market][]' \
    "${owner_file}")
}

remove_owned_runtime_container() {
  local owner_file="$1" container_id inspect
  jq -e 'has("runtime")' "${owner_file}" >/dev/null || return 0
  container_id="$(jq -er .runtime.container_id "${owner_file}")" || return 1
  if ! inspect="$(docker container inspect "${container_id}" 2>/dev/null)"; then
    return 0
  fi
  jq -e --slurpfile owner "${owner_file}" '
    $owner[0].runtime as $expected
    | .[0] as $actual
    | $actual.Id == $expected.container_id
      and ($actual.Name | ltrimstr("/")) == $expected.container_name
      and $actual.Image == $expected.image_id
      and $actual.Config.Labels["hushine.runtime.runtime_id"] == $expected.runtime_id
      and $actual.Config.Labels["hushine.runtime.user_id"] == $expected.user_id
      and $actual.Config.Labels["hushine.runtime.coverage"] == "true"
      and $actual.Config.Labels["hushine.runtime.coverage_run_id"] == $expected.coverage_run_id
      and $actual.Config.Labels["hushine.runtime.name"] == $expected.resource_name
      and any(
        $actual.Mounts[];
        .Destination == "/coverage"
        and .Source == $expected.coverage_mount_source
      )
  ' <<<"${inspect}" >/dev/null || return 1
  docker rm -f "${container_id}" >/dev/null 2>&1 || return 1
  ! docker container inspect "${container_id}" >/dev/null 2>&1
}

expected_source_shas() {
  local expected_file="$1"
  [[ "${expected_file}" == /* ]] || die "--expected-shas must be absolute"
  [[ -f "${expected_file}" && ! -L "${expected_file}" ]] \
    || die "--expected-shas must be a regular non-symlink file"
  [[ "$(file_mode "${expected_file}")" == "600" ]] \
    || die "--expected-shas must have mode 0600"
  jq -e '
    type == "object"
    and keys == ["schema", "source_shas"]
    and .schema == 1
    and (.source_shas | type == "object")
    and (.source_shas | keys) == [
      "control-panel-service",
      "core-service",
      "gateway/quant-frontend",
      "gateway/quant-handler",
      "hushine-deploy",
      "scraper",
      "strategy-debugger-cli",
      "strategy-library",
      "strategy-service"
    ]
    and all(.source_shas[];
      type == "string" and test("^[0-9a-f]{40}$")
    )
  ' "${expected_file}" >/dev/null \
    || die "--expected-shas has an invalid schema or repository set"
  jq -c .source_shas "${expected_file}"
}

validate_expected_source_shas() {
  local expected_file="$1" expected current repository
  expected="$(expected_source_shas "${expected_file}" | jq -S -c .)"
  current="$(source_sha_json | jq -S -c .)"
  [[ "${current}" == "${expected}" ]] || die "source SHA mismatch"
  while IFS= read -r repository; do
    [[ -z "$(git -C "${SOURCE_ROOT}/${repository}" status --porcelain --untracked-files=normal)" ]] \
      || die "source repository is not clean: ${repository}"
  done < <(jq -r 'keys[]' <<<"${current}")
  printf '%s\n' "${current}"
}

owned_database_json() {
  local suffix="$1"
  jq -nc \
    --arg portfolio "hushine_indicator_chain_${suffix}_portfolio" \
    --arg orders "hushine_indicator_chain_${suffix}_order" \
    --arg control "hushine_indicator_chain_${suffix}_control" \
    --arg market_prefix "hushine_indicator_chain_${suffix}_" \
    --arg market "hushine_indicator_chain_${suffix}_binance_2025" \
    '{
      portfolio: $portfolio,
      order: $orders,
      control_panel: $control,
      market_prefix: $market_prefix,
      market: $market
    }'
}

create_owned_databases() {
  local databases="$1" owner="$2" database
  local -a database_names=()
  while IFS= read -r database; do
    database_names[${#database_names[@]}]="${database}"
  done < <(jq -r '[.portfolio,.order,.control_panel,.market][]' <<<"${databases}")

  for database in "${database_names[@]}"; do
    safe_database_name "${database}" || die "unsafe generated database name: ${database}"
    database_exists "${database}" && die "refusing pre-existing chain database: ${database}"
  done

  for database in "${database_names[@]}"; do
    pg_admin -c "CREATE DATABASE ${database}" >/dev/null
    pg_admin -c \
      "COMMENT ON DATABASE ${database} IS 'hushine-indicator-chain:${owner}'" \
      >/dev/null
  done
}

apply_owned_migrations() {
  local databases="$1" portfolio order control market_prefix
  portfolio="$(jq -r .portfolio <<<"${databases}")"
  order="$(jq -r .order <<<"${databases}")"
  control="$(jq -r .control_panel <<<"${databases}")"
  market_prefix="$(jq -r .market_prefix <<<"${databases}")"

  (
    cd "${SOURCE_ROOT}/core-service"
    run_clean_env \
      PGHOST="${PG_HOST}" PGPORT="${PG_PORT}" PGUSER="${PG_USER}" \
      PGPASSWORD="${PG_PASSWORD}" PGDATABASE_ADMIN=postgres \
      PGDATABASE_PORTFOLIO="${portfolio}" \
      go run ./cmd/ensure-portfolio-db
  ) >"${STATE_DIR}/logs/ensure-portfolio.log" 2>&1
  (
    cd "${SOURCE_ROOT}/core-service"
    run_clean_env \
      ORDER_DATABASE_HOST="${PG_HOST}" ORDER_DATABASE_PORT="${PG_PORT}" \
      ORDER_DATABASE_USER="${PG_USER}" ORDER_DATABASE_PASSWORD="${PG_PASSWORD}" \
      ORDER_DATABASE_DBNAME="${order}" ORDER_DATABASE_SSLMODE=disable \
      go run ./cmd/ensure-order-db -config /dev/null
  ) >"${STATE_DIR}/logs/ensure-order.log" 2>&1
  (
    cd "${SOURCE_ROOT}/control-panel-service"
    run_clean_env \
      PGHOST="${PG_HOST}" PGPORT="${PG_PORT}" PGUSER="${PG_USER}" \
      PGPASSWORD="${PG_PASSWORD}" PGDATABASE_ADMIN=postgres \
      PGDATABASE_CONTROL_PANEL="${control}" \
      go run ./cmd/ensure-control-panel-db
  ) >"${STATE_DIR}/logs/ensure-control-panel.log" 2>&1
  (
    cd "${SOURCE_ROOT}/scraper"
    run_clean_env \
      PGHOST="${PG_HOST}" PGPORT="${PG_PORT}" PGUSER="${PG_USER}" \
      PGPASSWORD="${PG_PASSWORD}" PGDATABASE_ADMIN=postgres \
      SCRAPER_DATABASE_PREFIX="${market_prefix}" \
      SCRAPER_EXCHANGES=binance SCRAPER_YEARS=2025 \
      go run ./cmd/ensure-scraper-db
  ) >"${STATE_DIR}/logs/ensure-market.log" 2>&1
}

seed_market_data() {
  local market="$1" control="$2"
  pg_database "${market}" >/dev/null <<'SQL'
CREATE TABLE IF NOT EXISTS futures_klines_testusdt_1m (
    time TIMESTAMPTZ NOT NULL,
    symbol TEXT NOT NULL,
    market TEXT NOT NULL DEFAULT 'futures',
    exchange TEXT NOT NULL DEFAULT 'binance',
    open_time TIMESTAMPTZ NOT NULL,
    close_time TIMESTAMPTZ NOT NULL,
    open DOUBLE PRECISION NOT NULL,
    high DOUBLE PRECISION NOT NULL,
    low DOUBLE PRECISION NOT NULL,
    close DOUBLE PRECISION NOT NULL,
    volume DOUBLE PRECISION NOT NULL DEFAULT 0,
    quote_volume DOUBLE PRECISION NOT NULL DEFAULT 0,
    num_trades BIGINT NOT NULL DEFAULT 0,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    PRIMARY KEY (time, symbol)
);
SELECT create_hypertable(
    'futures_klines_testusdt_1m',
    'time',
    if_not_exists => TRUE
);
INSERT INTO futures_klines_testusdt_1m (
    time, symbol, market, exchange, open_time, close_time,
    open, high, low, close, volume, quote_volume, num_trades
)
SELECT
    '2025-01-01T00:00:00Z'::timestamptz + item * interval '1 minute',
    'TESTUSDT',
    'futures',
    'binance',
    '2025-01-01T00:00:00Z'::timestamptz + item * interval '1 minute',
    '2025-01-01T00:00:00Z'::timestamptz + item * interval '1 minute'
        + interval '59.999 seconds',
    100 + (item % 100),
    101 + (item % 100),
    99 + (item % 100),
    100 + (item % 100),
    1000,
    (100 + (item % 100)) * 1000,
    100
FROM generate_series(0, 2049) AS item
ON CONFLICT (time, symbol) DO NOTHING;
DO $verify$
BEGIN
    IF (
        SELECT count(*)
        FROM futures_klines_testusdt_1m
        WHERE symbol = 'TESTUSDT'
    ) <> 2050 THEN
        RAISE EXCEPTION 'expected exactly 2050 TESTUSDT bars';
    END IF;
END
$verify$;

CREATE TABLE IF NOT EXISTS futures_funding_rates_testusdt (
    time TIMESTAMPTZ NOT NULL,
    symbol TEXT NOT NULL,
    market TEXT NOT NULL DEFAULT 'futures',
    exchange TEXT NOT NULL DEFAULT 'binance',
    funding_rate NUMERIC(38,18) NOT NULL,
    mark_price NUMERIC(38,18) NOT NULL,
    next_funding_time TIMESTAMPTZ,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    PRIMARY KEY (time, symbol)
);
SELECT create_hypertable(
    'futures_funding_rates_testusdt',
    'time',
    if_not_exists => TRUE
);
INSERT INTO futures_funding_rates_testusdt (
    time, symbol, market, exchange, funding_rate, mark_price, next_funding_time
) VALUES (
    '2025-01-01T00:06:00Z', 'TESTUSDT', 'futures', 'binance',
    0.001000000000000000, 106.000000000000000000,
    '2025-01-01T08:06:00Z'
) ON CONFLICT (time, symbol) DO NOTHING;
SQL
  pg_database "${control}" >/dev/null <<'SQL'
INSERT INTO market_data_coverage_segments (
    exchange, market, kind, symbol, "interval", year,
    segment_start_at, segment_end_at, row_count, source
) VALUES
    ('binance', 'futures', 'kline', 'TESTUSDT', '1m', 2025,
     '2025-01-01T00:00:00Z', '2025-01-02T10:10:00Z', 2050,
     'runtime-indicator-v2-service-chain'),
    ('binance', 'futures', 'funding_rate', 'TESTUSDT', '', 2025,
     '2025-01-01T00:00:00Z', '2025-01-02T10:10:00Z', 1,
     'runtime-indicator-v2-service-chain')
ON CONFLICT DO NOTHING;
SQL
}

write_control_config() {
  local databases="$1" ports="$2" cert_dir="$3" coverage_root="$4"
  local control_db market_template core_grpc cp_http cp_grpc runtime_grpc
  control_db="$(jq -r .control_panel <<<"${databases}")"
  market_template="$(jq -r '.market_prefix + "{exchange}_{year}"' <<<"${databases}")"
  core_grpc="$(jq -r .core_grpc <<<"${ports}")"
  cp_http="$(jq -r .control_http <<<"${ports}")"
  cp_grpc="$(jq -r .control_grpc <<<"${ports}")"
  runtime_grpc="$(jq -r .runtime_grpc <<<"${ports}")"
  cat >"${STATE_DIR}/control-panel.yaml" <<EOF
server:
  http_addr: "127.0.0.1:${cp_http}"
  grpc_addr: "127.0.0.1:${cp_grpc}"
runtime_channel_server:
  grpc_addr: "127.0.0.1:${runtime_grpc}"
  tls:
    enabled: true
    cert_file: "${cert_dir}/runtime-channel-server.pem"
    key_file: "${cert_dir}/runtime-channel-server.key"
    server_name: "runtime-channel.local"
    client_ca_file: "${cert_dir}/runtime-client-ca.pem"
    client_ca_key_file: "${cert_dir}/runtime-client-ca.key"
database:
  host: "${PG_HOST}"
  port: ${PG_PORT}
  user: "${PG_USER}"
  password: "${PG_PASSWORD}"
  dbname: "${control_db}"
  sslmode: "disable"
market_data:
  host: "${PG_HOST}"
  port: ${PG_PORT}
  user: "${PG_USER}"
  password: "${PG_PASSWORD}"
  database: "${market_template}"
  sslmode: "disable"
  live_delivery_enabled: false
dependencies:
  portfolio_service_grpc: "127.0.0.1:${core_grpc}"
  order_service_grpc: "127.0.0.1:${core_grpc}"
provisioning:
  backend: "docker"
  image: "hushine/strategy-runtime:executor-dev"
  registration_timeout_seconds: 60
  docker:
    network_mode: "bridge"
    runtime_channel_dial_addr: "host.docker.internal:${runtime_grpc}"
    label_prefix: "hushine.runtime"
    coverage:
      enabled: true
      image: "${RUNTIME_IMAGE}"
      output_dir: "${coverage_root}"
      stop_timeout_seconds: 20
notification:
  enabled: false
log:
  output_dir: "${STATE_DIR}/logs/control-panel"
  local_file:
    enabled: true
  kafka:
    enabled: false
  tracing:
    enabled: false
EOF
  chmod 0600 "${STATE_DIR}/control-panel.yaml"
}

generate_runtime_certs() {
  local cert_dir="$1"
  mkdir -m 0700 -p "${cert_dir}"
  cat >"${cert_dir}/runtime-channel-server.cnf" <<'EOF'
[req]
distinguished_name=runtime_channel_dn
x509_extensions=runtime_channel_server
prompt=no

[runtime_channel_dn]
CN=runtime-channel.local

[runtime_channel_server]
basicConstraints=critical,CA:FALSE
keyUsage=critical,digitalSignature,keyEncipherment
extendedKeyUsage=serverAuth
subjectAltName=DNS:runtime-channel.local,DNS:host.docker.internal,IP:127.0.0.1
EOF
  chmod 0600 "${cert_dir}/runtime-channel-server.cnf"
  openssl req -x509 -newkey rsa:2048 -nodes -days 1 \
    -config "${cert_dir}/runtime-channel-server.cnf" \
    -keyout "${cert_dir}/runtime-channel-server.key" \
    -out "${cert_dir}/runtime-channel-server.pem" \
    >"${STATE_DIR}/logs/runtime-certs.log" 2>&1
  openssl req -x509 -newkey rsa:2048 -nodes -days 1 \
    -subj "/CN=hushine-runtime-client-ca-chain" \
    -keyout "${cert_dir}/runtime-client-ca.key" \
    -out "${cert_dir}/runtime-client-ca.pem" \
    >>"${STATE_DIR}/logs/runtime-certs.log" 2>&1
  chmod 0600 "${cert_dir}"/*.key
}

build_service_binaries() {
  mkdir -m 0700 -p "${STATE_DIR}/bin"
  (
    cd "${SOURCE_ROOT}/core-service"
    go build -o "${STATE_DIR}/bin/core-service" ./cmd/core-service
  ) >"${STATE_DIR}/logs/build-core.log" 2>&1
  (
    cd "${SOURCE_ROOT}/control-panel-service"
    go build -o "${STATE_DIR}/bin/control-panel-service" ./cmd/control-panel-service
  ) >"${STATE_DIR}/logs/build-control-panel.log" 2>&1
  (
    cd "${SOURCE_ROOT}/gateway/quant-handler"
    go build -o "${STATE_DIR}/bin/quant-handler" ./cmd/quant-handler
  ) >"${STATE_DIR}/logs/build-handler.log" 2>&1
}

start_services() {
  local databases="$1" ports="$2" jwt_secret="$3"
  local portfolio_db order_db core_http core_grpc cp_http cp_grpc handler_http frontend_http
  portfolio_db="$(jq -r .portfolio <<<"${databases}")"
  order_db="$(jq -r .order <<<"${databases}")"
  core_http="$(jq -r .core_http <<<"${ports}")"
  core_grpc="$(jq -r .core_grpc <<<"${ports}")"
  cp_http="$(jq -r .control_http <<<"${ports}")"
  cp_grpc="$(jq -r .control_grpc <<<"${ports}")"
  handler_http="$(jq -r .handler_http <<<"${ports}")"
  frontend_http="$(jq -r .frontend_http <<<"${ports}")"

  (
    cd "${SOURCE_ROOT}/core-service"
    exec_clean_env \
      DATABASE_HOST="${PG_HOST}" DATABASE_PORT="${PG_PORT}" \
      DATABASE_USER="${PG_USER}" DATABASE_PASSWORD="${PG_PASSWORD}" \
      DATABASE_DBNAME="${portfolio_db}" DATABASE_SSLMODE=disable \
      ORDER_DATABASE_HOST="${PG_HOST}" ORDER_DATABASE_PORT="${PG_PORT}" \
      ORDER_DATABASE_USER="${PG_USER}" ORDER_DATABASE_PASSWORD="${PG_PASSWORD}" \
      ORDER_DATABASE_DBNAME="${order_db}" ORDER_DATABASE_SSLMODE=disable \
      SERVER_HTTP_ADDR="127.0.0.1:${core_http}" \
      SERVER_GRPC_ADDR="127.0.0.1:${core_grpc}" \
      EXCHANGE_MOCK_BINANCE=true NOTIFICATION_ENABLED=false \
      "${STATE_DIR}/bin/core-service" -config /dev/null
  ) >"${STATE_DIR}/logs/core-service.log" 2>&1 &
  record_process "${STATE_DIR}" core-service "$!"

  (
    cd "${SOURCE_ROOT}/control-panel-service"
    exec_clean_env \
      RUNTIME_COVERAGE_ENABLED=true \
      RUNTIME_COVERAGE_OUTPUT_DIR="${STATE_DIR}/coverage" \
      RUNTIME_COVERAGE_IMAGE="${RUNTIME_IMAGE}" \
      "${STATE_DIR}/bin/control-panel-service" -config "${STATE_DIR}/control-panel.yaml"
  ) >"${STATE_DIR}/logs/control-panel-service.log" 2>&1 &
  record_process "${STATE_DIR}" control-panel-service "$!"

  (
    cd "${SOURCE_ROOT}/gateway/quant-handler"
    exec_clean_env \
      SERVER_HTTP_ADDR="127.0.0.1:${handler_http}" \
      DEPENDENCIES_CORE_SERVICE_GRPC="127.0.0.1:${core_grpc}" \
      DEPENDENCIES_ORDER_SERVICE_GRPC="127.0.0.1:${core_grpc}" \
      DEPENDENCIES_CONTROL_PANEL_SERVICE_GRPC="127.0.0.1:${cp_grpc}" \
      AUTH_JWT_SECRET="${jwt_secret}" \
      AUTH_CORS_ORIGINS="http://127.0.0.1:${frontend_http}" \
      "${STATE_DIR}/bin/quant-handler" -config /dev/null
  ) >"${STATE_DIR}/logs/quant-handler.log" 2>&1 &
  record_process "${STATE_DIR}" quant-handler "$!"

  (
    cd "${SOURCE_ROOT}/gateway/quant-frontend"
    exec_clean_env \
      VITE_API_BASE_URL="http://127.0.0.1:${handler_http}" \
      "${SOURCE_ROOT}/gateway/quant-frontend/node_modules/vite/bin/vite.js" \
      --host 127.0.0.1 --port "${frontend_http}" --strictPort
  ) >"${STATE_DIR}/logs/quant-frontend.log" 2>&1 &
  record_process "${STATE_DIR}" quant-frontend "$!"

  wait_http "http://127.0.0.1:${handler_http}/healthz" quant-handler
  wait_http "http://127.0.0.1:${cp_http}/readyz" control-panel-service
  wait_http "http://127.0.0.1:${frontend_http}" quant-frontend
}

create_strategy_source() {
  local owner="$1" generation="$2"
  python3 - \
    "${SOURCE_ROOT}/strategy-service/tests/strategies/indicator_v2_open_time_cutover.py" \
    "${owner}" "${generation}" <<'PY'
import json
import pathlib
import sys

path, owner, generation = sys.argv[1:]
source = pathlib.Path(path).read_text(encoding="utf-8")
replacements = {
    'ACCEPTANCE_BARRIER_FILE = ""':
        'ACCEPTANCE_BARRIER_FILE = "/coverage/indicator-v2-barrier.json"',
    'ACCEPTANCE_BARRIER_OWNER_TOKEN = ""':
        f"ACCEPTANCE_BARRIER_OWNER_TOKEN = {json.dumps(owner)}",
    'ACCEPTANCE_BARRIER_GENERATION = ""':
        f"ACCEPTANCE_BARRIER_GENERATION = {json.dumps(generation)}",
}
for old, new in replacements.items():
    if source.count(old) != 1:
        raise SystemExit(f"fixture contract changed: {old}")
    source = source.replace(old, new)
print(source, end="")
PY
}

journal_runtime_container() {
  local owner_file="$1" container_name="$2" runtime="$3" user_id="$4"
  local image_id="$5" runtime_root="$6" output_root="$7" resource_name="$8"
  local container_id run_label
  container_id="$(docker container inspect --format '{{.Id}}' "${container_name}")" \
    || die "provisioned Runtime container is unavailable for ownership journal"
  run_label="$(runtime_coverage_expected_run_label "${output_root}")"
  atomic_json "${owner_file}" \
    --arg container_id "${container_id}" \
    --arg container_name "${container_name}" \
    --arg image_id "${image_id}" \
    --arg runtime_id "${runtime}" \
    --arg user_id "${user_id}" \
    --arg coverage_run_id "${run_label}" \
    --arg coverage_mount_source "${runtime_root}" \
    --arg resource_name "${resource_name}" \
    '.runtime = {
      container_id:$container_id,
      container_name:$container_name,
      image_id:$image_id,
      runtime_id:$runtime_id,
      user_id:$user_id,
      coverage_run_id:$coverage_run_id,
      coverage_mount_source:$coverage_mount_source,
      resource_name:$resource_name
    }' \
    "${owner_file}"
  validate_owner_file "${owner_file}" \
    || die "runtime owner journal is invalid"
}

provision_acceptance_run() {
  local ports="$1" owner="$2" generation="$3" image_id="$4"
  local handler_http api username password signup login token user_id
  local portfolio venue strategy runtime runtime_name session source source_json
  local response runtime_root
  handler_http="$(jq -r .handler_http <<<"${ports}")"
  api="http://127.0.0.1:${handler_http}"
  username="indicator-chain-${owner:0:12}"
  password="chain-${owner:12:32}"

  signup="$(jq -nc --arg username "${username}" --arg password "${password}" \
    '{username:$username,password:$password}')"
  api_json POST "${api}/api/auth/signup" "" "${signup}" \
    >"${STATE_DIR}/signup.json"
  login="$(api_json POST "${api}/api/auth/login" "" "${signup}")"
  token="$(jq -er .token <<<"${login}")"
  user_id="$(jq -er '.user.user_id' <<<"${login}")"
  atomic_json "${STATE_DIR}/auth.json" -nc \
    --arg token "${token}" \
    --arg username "${username}" \
    --arg password "${password}" \
    --argjson user_id "${user_id}" \
    '{schema:1,token:$token,username:$username,password:$password,user_id:$user_id}'

  response="$(api_json POST "${api}/api/portfolios" "${token}" \
    '{"name":"Indicator V2 chain","description":"Owned real-chain acceptance","environment":0}')"
  portfolio="$(jq -er .portfolio_id <<<"${response}")"

  response="$(api_json POST "${api}/api/venues" "${token}" "$(jq -nc \
    --argjson portfolio "${portfolio}" \
    '{
      portfolio_id:$portfolio,
      exchange:"binance",
      market:"perpetual_futures",
      environment:"backtest",
      status:"active",
      display_name:"Indicator V2 chain Futures",
      margin_mode:"cross",
      position_mode:"one_way",
      futures:{
        margin_mode:"cross",
        position_mode:"one_way",
        initial_balance:100000,
        positions:[{
          symbol:"TESTUSDT",
          direction:0,
          initial_balance:100000,
          leverage:20,
          fee_rate:0.0004
        }]
      }
    }')")"
  venue="$(jq -er .venue_id <<<"${response}")"

  source="$(create_strategy_source "${owner}" "${generation}")"
  source_json="$(jq -nc --arg name "indicator-v2-chain-${owner:0:8}" \
    --arg code "${source}" \
    '{name:$name,version:"2.0.0",description:"Indicator V2 real-chain fixture",code:$code}')"
  response="$(api_json POST "${api}/api/strategies" "${token}" "${source_json}")"
  strategy="$(jq -er .strategy_id <<<"${response}")"
  api_json POST "${api}/api/portfolios/${portfolio}/strategies/${strategy}" \
    "${token}" >/dev/null
  api_json POST "${api}/api/portfolios/${portfolio}/strategies/${strategy}/activate" \
    "${token}" >/dev/null

  runtime_name="indicator-chain-${owner:0:10}"
  response="$(api_json POST "${api}/api/runtimes" "${token}" \
    "$(jq -nc --arg name "${runtime_name}" \
      '{name:$name,resource_profile:"small"}')")"
  runtime="$(jq -er '.runtime.runtime_id' <<<"${response}")"
  [[ "$(jq -r .provisioned <<<"${response}")" == "true" ]] \
    || die "hosted Runtime was not newly provisioned"

  source "${DEPLOY_ROOT}/scripts/lib/runtime_coverage.sh"
  runtime_root="${STATE_DIR}/coverage/runtimes/${runtime}"
  journal_runtime_container \
    "${STATE_DIR}/owner.json" "hushine-runtime-${runtime}" "${runtime}" \
    "${user_id}" "${image_id}" "${runtime_root}" "${STATE_DIR}/coverage" \
    "${runtime_name}"
  runtime_coverage_prepare_output_root "${STATE_DIR}/coverage"
  runtime_coverage_validate_layout "${STATE_DIR}/coverage" "${runtime}"
  runtime_root="${RUNTIME_COVERAGE_RUNTIME_ROOT}"
  runtime_coverage_validate_container \
    "hushine-runtime-${runtime}" "${runtime}" "${user_id}" "${image_id}" \
    "${runtime_root}" "${STATE_DIR}/coverage"

  atomic_json "${STATE_DIR}/owner.json" \
    --arg container_id "${RUNTIME_COVERAGE_CONTAINER_ID}" \
    --arg container_name "hushine-runtime-${runtime}" \
    --arg image_id "${RUNTIME_COVERAGE_CONTAINER_IMAGE_ID}" \
    --arg runtime_id "${runtime}" \
    --arg user_id "${user_id}" \
    --arg coverage_run_id "${RUNTIME_COVERAGE_RUN_LABEL}" \
    --arg coverage_mount_source "${runtime_root}" \
    --arg resource_name "${runtime_name}" \
    '.runtime = {
      container_id:$container_id,
      container_name:$container_name,
      image_id:$image_id,
      runtime_id:$runtime_id,
      user_id:$user_id,
      coverage_run_id:$coverage_run_id,
      coverage_mount_source:$coverage_mount_source,
      resource_name:$resource_name
    }' \
    "${STATE_DIR}/owner.json"
  validate_owner_file "${STATE_DIR}/owner.json" \
    || die "runtime owner journal is invalid"

  atomic_json "${runtime_root}/indicator-v2-barrier.json" -nc \
    --arg owner_token "${owner}" \
    --arg generation "${generation}" \
    --arg runtime_id "${runtime}" \
    '{
      schema:1,
      owner_token:$owner_token,
      generation:$generation,
      runtime_id:$runtime_id,
      session_id:"",
      target_completed:1023,
      ack_file:"/coverage/indicator-v2-ack.json"
    }'

  response="$(api_json POST "${api}/api/portfolios/${portfolio}/run-strategy" \
    "${token}" "$(jq -nc \
      --arg runtime_id "${runtime}" \
      --argjson start_time_ms "${START_TIME_MS}" \
      --argjson end_time_ms "${END_TIME_MS}" \
      '{
        strategy_path:"",
        interval:"1m",
        start_time_ms:$start_time_ms,
        end_time_ms:$end_time_ms,
        runtime_id:$runtime_id
      }')")"
  session="$(jq -er .session_id <<<"${response}")"

  atomic_json "${runtime_root}/indicator-v2-barrier.json" \
    --arg session_id "${session}" \
    '.session_id = $session_id' \
    "${runtime_root}/indicator-v2-barrier.json"

  jq -nc \
    --arg api "${api}" \
    --argjson user_id "${user_id}" \
    --argjson portfolio_id "${portfolio}" \
    --argjson venue_id "${venue}" \
    --argjson strategy_id "${strategy}" \
    --arg runtime_id "${runtime}" \
    --arg session_id "${session}" \
    --arg runtime_root "${runtime_root}" \
    '{
      api:$api,
      user_id:$user_id,
      portfolio_id:$portfolio_id,
      venue_id:$venue_id,
      strategy_id:$strategy_id,
      runtime_id:$runtime_id,
      session_id:$session_id,
      runtime_root:$runtime_root
    }'
}

write_chain_json() {
  local phase="$1" owner="$2" generation="$3" databases="$4" ports="$5"
  local identities="$6" sources="$7" source_dirty="$8" evidence_eligible="$9"
  local image_provenance="${10}" image_id="${11}" provisioned="${12}"
  local frontend_http handler_http supervisor_pid supervisor_identity
  frontend_http="$(jq -r .frontend_http <<<"${ports}")"
  handler_http="$(jq -r .handler_http <<<"${ports}")"
  supervisor_pid="$$"
  supervisor_identity="$(process_start_identity "$$")"
  atomic_json "${STATE_DIR}/chain.json" -nc \
    --arg phase "${phase}" \
    --arg status "running" \
    --arg owner_token "${owner}" \
    --arg generation "${generation}" \
    --argjson databases "${databases}" \
    --argjson ports "${ports}" \
    --argjson processes "${identities}" \
    --argjson source_shas "${sources}" \
    --argjson source_dirty "${source_dirty}" \
    --argjson evidence_eligible "${evidence_eligible}" \
    --argjson runtime_image_provenance "${image_provenance}" \
    --arg runtime_image "${RUNTIME_IMAGE}" \
    --arg runtime_image_id "${image_id}" \
    --argjson supervisor_pid "${supervisor_pid}" \
    --arg supervisor_start_identity "${supervisor_identity}" \
    --arg frontend_url "http://127.0.0.1:${frontend_http}" \
    --arg handler_url "http://127.0.0.1:${handler_http}" \
    --argjson provisioned "${provisioned}" \
    '{
      schema:1,
      phase:$phase,
      status:$status,
      owner_token:$owner_token,
      generation:$generation,
      source_shas:$source_shas,
      source_dirty:$source_dirty,
      evidence_eligible:$evidence_eligible,
      runtime_image_provenance:$runtime_image_provenance,
      databases:$databases,
      ports:$ports,
      processes:$processes,
      supervisor:{
        pid:$supervisor_pid,
        process_start_identity:$supervisor_start_identity
      },
      runtime_image:$runtime_image,
      runtime_image_id:$runtime_image_id,
      urls:{
        frontend:$frontend_url,
        handler:$handler_url
      },
      user_id:$provisioned.user_id,
      portfolio_id:$provisioned.portfolio_id,
      venue_id:$provisioned.venue_id,
      strategy_id:$provisioned.strategy_id,
      runtime_id:$provisioned.runtime_id,
      session_id:$provisioned.session_id,
      runtime_root:$provisioned.runtime_root,
      created_at:(now|todateiso8601),
      cleanup:null
    }'
}

release_acceptance_barrier() {
  local state_dir="$1" owner_file chain_file barrier runtime_root
  local owner generation runtime session
  owner_file="${state_dir}/owner.json"
  chain_file="${state_dir}/chain.json"
  [[ -f "${chain_file}" && ! -L "${chain_file}" ]] || return 1
  [[ "$(file_mode "${chain_file}")" == "600" ]] || return 1
  validate_owner_file "${owner_file}" || return 1
  owner="$(jq -er .owner_token "${chain_file}")" || return 1
  generation="$(jq -er .generation "${chain_file}")" || return 1
  runtime="$(jq -er .runtime_id "${chain_file}")" || return 1
  session="$(jq -er .session_id "${chain_file}")" || return 1
  runtime_root="$(jq -er .runtime_root "${chain_file}")" || return 1
  [[ "${owner}" == "$(jq -r .owner_token "${owner_file}")" ]] || return 1
  [[ "${runtime_root}" == "${state_dir}/coverage/runtimes/${runtime}" ]] || return 1
  [[ -d "${runtime_root}" && ! -L "${runtime_root}" ]] || return 1
  barrier="${runtime_root}/indicator-v2-barrier.json"
  [[ -f "${barrier}" && ! -L "${barrier}" ]] || return 1
  [[ "$(file_mode "${barrier}")" == "600" ]] || return 1
  jq -e \
    --arg owner "${owner}" \
    --arg generation "${generation}" \
    --arg runtime "${runtime}" \
    --arg session "${session}" \
    '.schema == 1
     and .owner_token == $owner
     and .generation == $generation
     and .runtime_id == $runtime
     and .session_id == $session
     and .ack_file == "/coverage/indicator-v2-ack.json"
     and (.target_completed | type == "number")' \
    "${barrier}" >/dev/null || return 1
  atomic_json "${barrier}" \
    '.target_completed = 2051' \
    "${barrier}"
}

cleanup_supervisor() {
  local rc="$?" token="" api="" session="" runtime="" auth=""
  local cleanup_ok=true owner_valid=false
  trap - EXIT INT TERM
  if [[ -f "${STATE_DIR}/owner.json" ]] \
    && validate_owner_file "${STATE_DIR}/owner.json"; then
    owner_valid=true
    token="$(jq -r .owner_token "${STATE_DIR}/owner.json" 2>/dev/null || true)"
  elif [[ -f "${STATE_DIR}/owner.json" ]]; then
    cleanup_ok=false
  fi
  if [[ "${owner_valid}" == "true" && -f "${STATE_DIR}/chain.json" ]]; then
    release_acceptance_barrier "${STATE_DIR}" || cleanup_ok=false
  fi
  if [[ "${owner_valid}" == "true" \
    && -f "${STATE_DIR}/chain.json" \
    && -f "${STATE_DIR}/auth.json" \
    && "$(jq -r .owner_token "${STATE_DIR}/chain.json" 2>/dev/null || true)" == "${token}" ]]; then
    api="$(jq -r .urls.handler "${STATE_DIR}/chain.json")"
    session="$(jq -r .session_id "${STATE_DIR}/chain.json")"
    runtime="$(jq -r .runtime_id "${STATE_DIR}/chain.json")"
    auth="$(jq -r .token "${STATE_DIR}/auth.json")"
    api_json POST "${api}/api/strategy-sessions/${session}/stop" "${auth}" \
      '{"stop_action":"STOP_ONLY"}' \
      >"${STATE_DIR}/stop-session.json" 2>"${STATE_DIR}/logs/stop-session.log" \
      || cleanup_ok=false
    api_json DELETE "${api}/api/runtimes/${runtime}" "${auth}" \
      >"${STATE_DIR}/end-runtime.json" 2>"${STATE_DIR}/logs/end-runtime.log" \
      || cleanup_ok=false
  fi

  if [[ "${owner_valid}" == "true" && -f "${STATE_DIR}/pids.json" ]]; then
    while IFS=$'\t' read -r pid identity; do
      terminate_owned_process "${pid}" "${identity}" || cleanup_ok=false
    done < <(jq -r 'reverse[] | [.pid,.process_start_identity] | @tsv' \
      "${STATE_DIR}/pids.json")
  fi

  if [[ "${owner_valid}" == "true" ]]; then
    remove_owned_runtime_container "${STATE_DIR}/owner.json" || cleanup_ok=false
  fi

  if [[ "${owner_valid}" == "true" && -n "${token}" ]]; then
    local -a database_names=()
    while IFS= read -r database; do
      database_names[${#database_names[@]}]="${database}"
    done < <(jq -r '.databases | [.portfolio,.order,.control_panel,.market][]' \
      "${STATE_DIR}/owner.json")
    for database in "${database_names[@]}"; do
      if ! safe_database_name "${database}"; then
        cleanup_ok=false
        continue
      fi
      if database_exists "${database}"; then
        if [[ "$(database_comment "${database}")" != "hushine-indicator-chain:${token}" ]]; then
          cleanup_ok=false
          continue
        fi
        pg_admin -c \
          "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname = '${database}' AND pid <> pg_backend_pid()" \
          >/dev/null 2>&1 || cleanup_ok=false
        pg_admin -c "DROP DATABASE ${database}" >/dev/null 2>&1 || cleanup_ok=false
      fi
    done
  fi

  if [[ -f "${STATE_DIR}/chain.json" ]]; then
    atomic_json "${STATE_DIR}/chain.json" \
      --argjson ok "${cleanup_ok}" \
      --argjson exit_code "${rc}" \
      '.status = (if $ok then "stopped" else "cleanup_failed" end)
       | .cleanup = {
           complete:$ok,
           supervisor_exit_code:$exit_code,
           completed_at:(now|todateiso8601)
         }' \
      "${STATE_DIR}/chain.json"
  fi
  [[ "${cleanup_ok}" == "true" ]] || rc=1
  exit "${rc}"
}

supervise() {
  local phase="$1" expected_shas="${3:-}" allow_dirty_debug="${4:-false}"
  STATE_DIR="$(canonical_state_dir "$2")"
  export STATE_DIR
  trap cleanup_supervisor EXIT INT TERM
  mkdir -m 0700 -p "${STATE_DIR}/logs" "${STATE_DIR}/coverage"
  printf '[]\n' >"${STATE_DIR}/pids.json"
  chmod 0600 "${STATE_DIR}/pids.json"

  local suffix owner generation databases ports sources source_dirty
  local evidence_eligible source_evidence image_provenance image_id cert_dir jwt_secret
  local provisioned processes
  suffix="$(date -u +%m%d%H%M%S)_$$_$(openssl rand -hex 3)"
  owner="$(openssl rand -hex 32)"
  generation="generation-$(openssl rand -hex 16)"
  databases="$(owned_database_json "${suffix}")"
  source_evidence="$(
    source_evidence_json "${phase}" "${expected_shas}" "${allow_dirty_debug}"
  )"
  sources="$(jq -c .source_shas <<<"${source_evidence}")"
  source_dirty="$(jq -c .source_dirty <<<"${source_evidence}")"
  evidence_eligible="$(jq -r .evidence_eligible <<<"${source_evidence}")"
  image_id="$(docker image inspect --format '{{.Id}}' "${RUNTIME_IMAGE}")"
  image_provenance="$(
    validate_runtime_image_provenance "${sources}" "${evidence_eligible}"
  )" || die "coverage Runtime image provenance does not match source"
  ports="$(jq -nc \
    --argjson core_http "$(choose_port)" \
    --argjson core_grpc "$(choose_port)" \
    --argjson control_http "$(choose_port)" \
    --argjson control_grpc "$(choose_port)" \
    --argjson runtime_grpc "$(choose_port)" \
    --argjson handler_http "$(choose_port)" \
    --argjson frontend_http "$(choose_port)" \
    '{
      core_http:$core_http,
      core_grpc:$core_grpc,
      control_http:$control_http,
      control_grpc:$control_grpc,
      runtime_grpc:$runtime_grpc,
      handler_http:$handler_http,
      frontend_http:$frontend_http
    }')"
  atomic_json "${STATE_DIR}/owner.json" -nc \
    --arg owner_token "${owner}" \
    --arg generation "${generation}" \
    --argjson databases "${databases}" \
    '{schema:1,owner_token:$owner_token,generation:$generation,databases:$databases}'

  create_owned_databases "${databases}" "${owner}"
  apply_owned_migrations "${databases}"
  seed_market_data \
    "$(jq -r .market <<<"${databases}")" \
    "$(jq -r .control_panel <<<"${databases}")"
  build_service_binaries
  cert_dir="${STATE_DIR}/certs"
  generate_runtime_certs "${cert_dir}"
  write_control_config "${databases}" "${ports}" "${cert_dir}" "${STATE_DIR}/coverage"
  jwt_secret="chain-jwt-${owner}"
  start_services "${databases}" "${ports}" "${jwt_secret}"
  provisioned="$(provision_acceptance_run "${ports}" "${owner}" "${generation}" "${image_id}")"
  processes="$(<"${STATE_DIR}/pids.json")"
  write_chain_json "${phase}" "${owner}" "${generation}" "${databases}" "${ports}" \
    "${processes}" "${sources}" "${source_dirty}" "${evidence_eligible}" \
    "${image_provenance}" "${image_id}" "${provisioned}"

  while [[ ! -f "${STATE_DIR}/stop-request" ]]; do
    while IFS=$'\t' read -r pid identity name; do
      process_matches "${pid}" "${identity}" \
        || die "owned process exited unexpectedly: ${name}"
    done < <(jq -r '.[] | [.pid,.process_start_identity,.name] | @tsv' \
      "${STATE_DIR}/pids.json")
    runtime="$(jq -r .runtime_id "${STATE_DIR}/chain.json")"
    docker container inspect "hushine-runtime-${runtime}" >/dev/null 2>&1 \
      || die "hosted runtime container exited unexpectedly"
    sleep 1
  done
}

require_chain() {
  STATE_DIR="$(canonical_state_dir "$1")"
  export STATE_DIR
  [[ -f "${STATE_DIR}/chain.json" && -f "${STATE_DIR}/owner.json" ]] \
    || die "chain state is incomplete"
  [[ "$(jq -r .schema "${STATE_DIR}/chain.json")" == "1" ]] \
    || die "unsupported chain schema"
  local chain_owner owner_owner
  chain_owner="$(jq -r .owner_token "${STATE_DIR}/chain.json")"
  owner_owner="$(jq -r .owner_token "${STATE_DIR}/owner.json")"
  [[ -n "${chain_owner}" && "${chain_owner}" == "${owner_owner}" ]] \
    || die "chain ownership token mismatch"
}

assert_funding_income_once() {
  local state_dir="$1" database session venue result
  local count income_id cursor status source income_type applied
  require_chain "${state_dir}"
  database="$(jq -r .databases.portfolio "${STATE_DIR}/chain.json")"
  session="$(jq -r .session_id "${STATE_DIR}/chain.json")"
  venue="$(jq -r .venue_id "${STATE_DIR}/chain.json")"
  result="$(pg_database "${database}" -Atc "
WITH exact_income AS (
  SELECT income_entry_id, status, source, income_type, applied_amount
  FROM venue_income_entries
  WHERE session_id = '${session}' AND venue_id = ${venue}
)
SELECT
  count(*),
  COALESCE(max(income_entry_id), 0),
  COALESCE((
    SELECT snapshot_json #>> '{futures,last_applied_income_entry_id}'
    FROM venue_wallet_states WHERE venue_id = ${venue}
  ), '0'),
  COALESCE(max(status), ''),
  COALESCE(max(source), ''),
  COALESCE(max(income_type), ''),
  COALESCE(max(applied_amount), 0)
FROM exact_income;")"
  IFS='|' read -r count income_id cursor status source income_type applied <<<"${result}"
  [[ "${count}" == "1" && "${income_id}" =~ ^[1-9][0-9]*$ ]]
  [[ "${cursor}" == "${income_id}" ]]
  [[ "${status}" == "calculated" && "${source}" == "backtest" ]]
  [[ "${income_type}" == "FUNDING_FEE" ]]
  [[ "${applied}" != "0" && "${applied}" != "0.000000000000000000" ]]
  echo "runtime Indicator V2 service-chain: Funding Income wallet-once PASS"
}

assert_blocked_worker_heartbeat() {
  local state_dir="$1" database runtime before after status deadline
  require_chain "${state_dir}"
  database="$(jq -r .databases.control_panel "${STATE_DIR}/chain.json")"
  runtime="$(jq -r .runtime_id "${STATE_DIR}/chain.json")"
  before="$(pg_database "${database}" -Atc \
    "SELECT COALESCE(extract(epoch FROM heartbeat_at) * 1000000, 0)::bigint FROM runtime_registry WHERE runtime_id='${runtime}';")"
  [[ "${before}" =~ ^[1-9][0-9]*$ ]] \
    || die "blocked Worker chain has no initial Agent heartbeat"
  deadline=$((SECONDS + 30))
  while :; do
    IFS='|' read -r after status < <(pg_database "${database}" -Atc \
      "SELECT COALESCE(extract(epoch FROM heartbeat_at) * 1000000, 0)::bigint, status FROM runtime_registry WHERE runtime_id='${runtime}';")
    if [[ "${after}" =~ ^[1-9][0-9]*$ && "${after}" -gt "${before}" && "${status}" == "active" ]]; then
      break
    fi
    (( SECONDS < deadline )) || die "Agent heartbeat did not advance while Worker was barrier-blocked"
    sleep 0.5
  done
  echo "runtime Indicator V2 service-chain: blocked Worker Agent heartbeat PASS"
}

indicator_snapshot() {
  local database="$1" session="$2"
  pg_database "${database}" -Atc "
SELECT COALESCE(
  jsonb_agg(
    jsonb_build_object(
      'session_id', session_id,
      'indicator_key', indicator_key,
      'stream_key', stream_key,
      'chunk_index', chunk_index,
      'start_sequence', start_sequence,
      'end_sequence', end_sequence,
      'start_time_ms', start_time_ms,
      'end_time_ms', end_time_ms,
      'interval_ms', interval_ms,
      'count', count,
      'revision', revision,
      'finalized', finalized,
      'protocol_version', protocol_version,
      'times_ms', to_jsonb(times_ms),
      'scalar_values', to_jsonb(scalar_values),
      'markers', markers_json,
      'updated_at', updated_at
    )
    ORDER BY indicator_key, chunk_index
  ),
  '[]'::jsonb
)::text
FROM strategy_indicator_chunks
WHERE session_id = '${session}'"
}

canonical_indicator_items() {
  jq -S -c '
    [
      .[] | {
        session_id,
        stream_key,
        indicator_key,
        chunk_index,
        start_sequence,
        end_sequence,
        start_time_ms,
        end_time_ms,
        interval_ms,
        count,
        times_ms,
        scalar_values,
        markers,
        revision,
        finalized,
        protocol_version
      }
    ]
    | sort_by(.stream_key, .indicator_key, .chunk_index)
  '
}

assert_api_matches_database() {
  local database_items="$1" api_response="$2" database_canonical api_canonical
  database_canonical="$(canonical_indicator_items <<<"${database_items}")" \
    || return 1
  api_canonical="$(
    jq -c '.items' <<<"${api_response}" | canonical_indicator_items
  )" || return 1
  [[ "${database_canonical}" == "${api_canonical}" ]]
}

sha256_text() {
  if command -v shasum >/dev/null 2>&1; then
    printf '%s' "$1" | shasum -a 256 | awk '{print $1}'
  else
    printf '%s' "$1" | sha256sum | awk '{print $1}'
  fi
}

order_snapshot() {
  local database="$1" session="$2"
  pg_database "${database}" -Atc "
SELECT COALESCE(
  jsonb_agg(
    jsonb_build_object(
      'time_ms', (extract(epoch FROM i.time) * 1000)::bigint,
      'symbol', i.symbol,
      'side', i.side,
      'intent_status', i.status,
      'reject_code', i.reject_code,
      'order_status', o.status,
      'orig_qty', o.orig_qty::text,
      'executed_qty', o.executed_qty::text,
      'avg_price', o.avg_price::text,
      'cumulative_quote_qty', o.cumulative_quote_qty::text,
      'error_code', o.error_code,
      'error_message', o.error_message,
      'recovery_status', o.recovery_status,
      'fill_status', f.status,
      'qty', f.qty::text,
      'fill_price', f.fill_price::text,
      'quote_qty', f.quote_qty::text,
      'quote_qty_unresolved', f.quote_qty_unresolved,
      'fee', f.fee::text,
      'fee_asset', f.fee_asset
    )
    ORDER BY i.time
  ),
  '[]'::jsonb
)::text
FROM order_intents i
JOIN orders o USING (intent_id)
JOIN order_fills f USING (intent_id, order_id)
WHERE i.session_id = '${session}'"
}

assert_cutover_orders() {
  local orders="$1"
  jq -e --argjson start "${START_TIME_MS}" '
    . == [
      {
        time_ms:($start + 4 * 60000 + 59999),
        symbol:"TESTUSDT",side:1,intent_status:1,reject_code:"",
        order_status:3,orig_qty:"0.001000000000000000",
        executed_qty:"0.001000000000000000",
        avg_price:"104.000000000000000000",
        cumulative_quote_qty:"0.104000000000000000",
        error_code:"",error_message:"",recovery_status:"",
        fill_status:1,qty:"0.001000000000000000",
        fill_price:"104.000000000000000000",
        quote_qty:"0.104000000000000000",
        quote_qty_unresolved:false,fee:"0.000041600000000000",
        fee_asset:"USDT"
      },
      {
        time_ms:($start + 9 * 60000 + 59999),
        symbol:"TESTUSDT",side:2,intent_status:1,reject_code:"",
        order_status:3,orig_qty:"0.001000000000000000",
        executed_qty:"0.001000000000000000",
        avg_price:"109.000000000000000000",
        cumulative_quote_qty:"0.109000000000000000",
        error_code:"",error_message:"",recovery_status:"",
        fill_status:1,qty:"0.001000000000000000",
        fill_price:"109.000000000000000000",
        quote_qty:"0.109000000000000000",
        quote_qty_unresolved:false,fee:"0.000043600000000000",
        fee_asset:"USDT"
      },
      {
        time_ms:($start + 1438 * 60000 + 59999),
        symbol:"TESTUSDT",side:1,intent_status:1,reject_code:"",
        order_status:3,orig_qty:"0.001000000000000000",
        executed_qty:"0.001000000000000000",
        avg_price:"138.000000000000000000",
        cumulative_quote_qty:"0.138000000000000000",
        error_code:"",error_message:"",recovery_status:"",
        fill_status:1,qty:"0.001000000000000000",
        fill_price:"138.000000000000000000",
        quote_qty:"0.138000000000000000",
        quote_qty_unresolved:false,fee:"0.000055200000000000",
        fee_asset:"USDT"
      }
    ]
  ' <<<"${orders}" >/dev/null
}

assert_cutover_markers() {
  local snapshot="$1" state="$2"
  jq -e \
    --argjson start "${START_TIME_MS}" \
    --arg state "${state}" '
      [
        .[] | .markers[]? | {
          sequence,
          offset,
          time_ms,
          text,
          price,
          color,
          position,
          shape
        }
      ] as $actual
      | (
          [
            {
              sequence:4,
              offset:4,
              time_ms:($start + 4 * 60000),
              text:"BUY",
              price:104,
              color:"#16a34a",
              position:"belowBar",
              shape:"arrowUp"
            },
            {
              sequence:9,
              offset:9,
              time_ms:($start + 9 * 60000),
              text:"SELL",
              price:109,
              color:"#dc2626",
              position:"aboveBar",
              shape:"arrowDown"
            }
          ]
          + (
            if $state == "two-full-plus-tail" then
              [{
                sequence:1438,
                offset:414,
                time_ms:($start + 1438 * 60000),
                text:"BUY",
                price:138,
                color:"#16a34a",
                position:"belowBar",
                shape:"arrowUp"
              }]
            else
              []
            end
          )
        ) as $expected
      | $actual == $expected
    ' <<<"${snapshot}" >/dev/null
}

api_indicator_snapshot() {
  local api="$1" token="$2" session="$3" stream="$4"
  curl -fsS -G \
    -H "Authorization: Bearer ${token}" \
    --data-urlencode "stream_key=${stream}" \
    --data-urlencode "start_time_ms=${START_TIME_MS}" \
    --data-urlencode "end_time_ms=${END_TIME_MS}" \
    "${api}/api/sessions/${session}/indicators/chunks"
}

assert_snapshot_state() {
  local state="$1" snapshot="$2"
  case "${state}" in
    open-1023)
      jq -e '
        length == 2
        and all(.[];
          .chunk_index == 0
          and .count == 1023
          and .revision == 1023
          and .finalized == false
          and .protocol_version == 2
          and (.times_ms | length) == 1023
        )
      ' <<<"${snapshot}" >/dev/null
      ;;
    finalized-1024-plus-tail)
      jq -e '
        length == 4
        and ([.[] | select(.chunk_index == 0 and .count == 1024 and .revision == 1024 and .finalized == true)] | length) == 2
        and ([.[] | select(.chunk_index == 1 and .count == 1 and .revision == 1 and .finalized == false)] | length) == 2
        and all(.[];
          .protocol_version == 2
          and (.times_ms | length) == .count
        )
      ' <<<"${snapshot}" >/dev/null
      ;;
    two-full-plus-tail)
      jq -e '
        length == 6
        and ([.[] | select(.chunk_index == 0 and .count == 1024 and .finalized == true)] | length) == 2
        and ([.[] | select(.chunk_index == 1 and .count == 1024 and .finalized == true)] | length) == 2
        and ([.[] | select(.chunk_index == 2 and .count == 1 and .revision == 1 and .finalized == false)] | length) == 2
        and all(.[];
          .revision == .count
          and .protocol_version == 2
          and (.times_ms | length) == .count
        )
      ' <<<"${snapshot}" >/dev/null
      ;;
    *)
      die "unsupported await state: ${state}"
      ;;
  esac
}

validate_barrier_ack() {
  local ack="$1" chain="$2" expected_completed="$3" expected_open_time
  [[ "${expected_completed}" =~ ^[0-9]+$ && "${expected_completed}" -gt 0 ]] \
    || return 1
  [[ -f "${ack}" && ! -L "${ack}" ]] || return 1
  [[ "$(file_mode "${ack}")" == "600" ]] || return 1
  [[ -f "${chain}" && ! -L "${chain}" ]] || return 1
  [[ "$(file_mode "${chain}")" == "600" ]] || return 1
  expected_open_time=$((START_TIME_MS + (expected_completed - 1) * 60000))
  jq -e \
    --slurpfile chain "${chain}" \
    --argjson completed "${expected_completed}" \
    --argjson last_open_time_ms "${expected_open_time}" \
    '
      ($chain[0]) as $chain
      | type == "object"
      and keys == [
        "generation",
        "last_open_time_ms",
        "owner_token",
        "runtime_id",
        "schema",
        "session_id"
      ]
      and .schema == 1
      and .owner_token == $chain.owner_token
      and .generation == $chain.generation
      and .runtime_id == $chain.runtime_id
      and .session_id == $chain.session_id
      and .completed == $completed
      and .last_open_time_ms == $last_open_time_ms
    ' "${ack}" >/dev/null
}

validate_transition_assertion() {
  local assertions="$1" chain="$2" state="$3" expected_completed="$4"
  [[ -f "${assertions}" && ! -L "${assertions}" ]] || return 1
  [[ "$(file_mode "${assertions}")" == "600" ]] || return 1
  [[ -f "${chain}" && ! -L "${chain}" ]] || return 1
  [[ "$(file_mode "${chain}")" == "600" ]] || return 1
  jq -e \
    --slurpfile chain "${chain}" \
    --arg state "${state}" \
    --argjson completed "${expected_completed}" \
    '
      ($chain[0]) as $chain
      | .schema == 1
      and .owner_token == $chain.owner_token
      and .generation == $chain.generation
      and .runtime_id == $chain.runtime_id
      and .session_id == $chain.session_id
      and (.states[$state] | type == "object")
      and .states[$state].completed == $completed
    ' "${assertions}" >/dev/null
}

await_state() {
  local requested_state="$1" state_dir="$2"
  require_chain "${state_dir}"
  local database session runtime_root ack expected_completed deadline snapshot=""
  local api token stream api_snapshot before after expected_marker_time marker_time
  local database_canonical api_canonical database_hash api_hash chunk_summary
  local orders='[]'
  database="$(jq -r .databases.portfolio "${STATE_DIR}/chain.json")"
  session="$(jq -r .session_id "${STATE_DIR}/chain.json")"
  runtime_root="$(jq -r .runtime_root "${STATE_DIR}/chain.json")"
  api="$(jq -r .urls.handler "${STATE_DIR}/chain.json")"
  token="$(jq -r .token "${STATE_DIR}/auth.json")"
  ack="${runtime_root}/indicator-v2-ack.json"
  case "${requested_state}" in
    open-1023) expected_completed=1023 ;;
    finalized-1024-plus-tail) expected_completed=1025 ;;
    two-full-plus-tail) expected_completed=2049 ;;
    *) die "unsupported await state: ${requested_state}" ;;
  esac

  deadline=$((SECONDS + 120))
  until [[ -f "${ack}" ]] \
    && [[ "$(jq -r .completed "${ack}" 2>/dev/null || true)" == "${expected_completed}" ]]; do
    (( SECONDS < deadline )) || die "timed out waiting for ${requested_state} worker acknowledgement"
    sleep 0.25
  done
  validate_barrier_ack \
    "${ack}" "${STATE_DIR}/chain.json" "${expected_completed}" \
    || die "worker acknowledgement identity or K-line open_time mismatch"

  deadline=$((SECONDS + 90))
  until snapshot="$(indicator_snapshot "${database}" "${session}")" \
    && assert_snapshot_state "${requested_state}" "${snapshot}" 2>/dev/null; do
    (( SECONDS < deadline )) || die "timed out waiting for ${requested_state} database state"
    sleep 0.5
  done
  assert_cutover_markers "${snapshot}" "${requested_state}" \
    || die "${requested_state} custom BUY/SELL markers are incomplete or misaligned"

  stream="$(jq -er '.[0].stream_key' <<<"${snapshot}")"
  api_snapshot="$(api_indicator_snapshot "${api}" "${token}" "${session}" "${stream}")"
  jq -e '
    (.items | length) > 0
    and all(.items[];
      .protocol_version == 2
      and has("times_ms")
      and has("revision")
      and has("finalized")
    )
  ' <<<"${api_snapshot}" >/dev/null \
    || die "${requested_state} handler V2 response contract failed"
  assert_api_matches_database "${snapshot}" "${api_snapshot}" \
    || die "${requested_state} handler response does not exactly match database chunks"
  database_canonical="$(canonical_indicator_items <<<"${snapshot}")"
  api_canonical="$(
    jq -c '.items' <<<"${api_snapshot}" | canonical_indicator_items
  )"
  database_hash="$(sha256_text "${database_canonical}")"
  api_hash="$(sha256_text "${api_canonical}")"
  [[ "${database_hash}" == "${api_hash}" ]] \
    || die "${requested_state} API/database canonical hashes differ"
  chunk_summary="$(jq -c '
    [
      .[] | {
        stream_key,
        indicator_key,
        chunk_index,
        start_sequence,
        end_sequence,
        start_time_ms,
        end_time_ms,
        count,
        revision,
        finalized,
        protocol_version,
        scalar_count:(.scalar_values | length),
        marker_count:(.markers | length)
      }
    ]
  ' <<<"${database_canonical}")"

  if [[ "${requested_state}" == "open-1023" ]]; then
    before="${snapshot}"
    local stable_deadline=$((SECONDS + 5))
    while (( SECONDS < stable_deadline )); do
      sleep 0.25
    done
    after="$(indicator_snapshot "${database}" "${session}")"
    [[ "${after}" == "${before}" ]] \
      || die "repeated 1023 sync changed rows, revisions, or updated_at"
  fi

  if [[ "${requested_state}" == "two-full-plus-tail" ]]; then
    expected_marker_time=$((START_TIME_MS + 1438 * 60000))
    marker_time="$(jq -er '
      [.[] | .markers[]? | select(.sequence == 1438)][0].time_ms
    ' <<<"${snapshot}")"
    [[ "${marker_time}" == "${expected_marker_time}" ]] \
      || die "marker 1438 is not anchored to K-line open_time"
    orders="$(order_snapshot \
      "$(jq -r .databases.order "${STATE_DIR}/chain.json")" "${session}")"
    assert_cutover_orders "${orders}" \
      || die "cutover orders do not preserve exact quantity, price, fee, or close_time facts"
  fi

  local assertions="${STATE_DIR}/assertions.json" temporary
  if [[ ! -f "${assertions}" ]]; then
    atomic_json "${assertions}" -nc \
      --arg owner_token "$(jq -r .owner_token "${STATE_DIR}/chain.json")" \
      --arg generation "$(jq -r .generation "${STATE_DIR}/chain.json")" \
      --arg runtime_id "$(jq -r .runtime_id "${STATE_DIR}/chain.json")" \
      --arg session_id "$(jq -r .session_id "${STATE_DIR}/chain.json")" \
      '{
        schema:1,
        owner_token:$owner_token,
        generation:$generation,
        runtime_id:$runtime_id,
        session_id:$session_id,
        states:{}
      }'
  fi
  temporary="${assertions}.tmp.$$"
  jq \
    --arg state "${requested_state}" \
    --argjson completed "${expected_completed}" \
    --arg database_sha256 "${database_hash}" \
    --arg api_sha256 "${api_hash}" \
    --argjson chunks "${chunk_summary}" \
    --argjson orders "${orders}" \
    '.states[$state] = {
      completed:$completed,
      database_sha256:$database_sha256,
      api_sha256:$api_sha256,
      api_database_equal:($database_sha256 == $api_sha256),
      chunks:$chunks,
      orders:$orders,
      observed_at:(now|todateiso8601)
    }' \
    "${assertions}" >"${temporary}"
  chmod 0600 "${temporary}"
  mv -f -- "${temporary}" "${assertions}"
  echo "runtime Indicator V2 service-chain: ${requested_state} PASS"
}

advance_state() {
  local count="$1" state_dir="$2"
  [[ "${count}" == "1025" || "${count}" == "2049" ]] \
    || die "advance count must be 1025 or 2049"
  require_chain "${state_dir}"
  local control ack current expected prior_state owner generation runtime session temporary
  control="$(jq -r .runtime_root "${STATE_DIR}/chain.json")/indicator-v2-barrier.json"
  ack="$(jq -r .runtime_root "${STATE_DIR}/chain.json")/indicator-v2-ack.json"
  [[ -f "${control}" && ! -L "${control}" ]] || die "barrier control file is missing or unsafe"
  current="$(jq -r .target_completed "${control}")"
  if [[ "${count}" == "1025" ]]; then
    expected=1023
    prior_state=open-1023
  else
    expected=1025
    prior_state=finalized-1024-plus-tail
  fi
  [[ "${current}" == "${expected}" ]] \
    || die "invalid barrier transition ${current} -> ${count}"
  validate_barrier_ack "${ack}" "${STATE_DIR}/chain.json" "${expected}" \
    || die "barrier transition lacks a matching worker acknowledgement"
  validate_transition_assertion \
    "${STATE_DIR}/assertions.json" "${STATE_DIR}/chain.json" \
    "${prior_state}" "${expected}" \
    || die "barrier transition lacks a matching prior state assertion"
  owner="$(jq -r .owner_token "${STATE_DIR}/chain.json")"
  generation="$(jq -r .generation "${STATE_DIR}/chain.json")"
  runtime="$(jq -r .runtime_id "${STATE_DIR}/chain.json")"
  session="$(jq -r .session_id "${STATE_DIR}/chain.json")"
  jq -e \
    --arg owner "${owner}" \
    --arg generation "${generation}" \
    --arg runtime "${runtime}" \
    --arg session "${session}" \
    '.owner_token == $owner
     and .generation == $generation
     and .runtime_id == $runtime
     and .session_id == $session' \
    "${control}" >/dev/null \
    || die "barrier identity does not match chain"
  rm -f -- "${ack}"
  temporary="${control}.tmp.$$"
  jq --argjson count "${count}" '.target_completed = $count' \
    "${control}" >"${temporary}"
  chmod 0600 "${temporary}"
  mv -f -- "${temporary}" "${control}"
  echo "runtime Indicator V2 service-chain: advanced ${expected} -> ${count}"
}

start_chain() {
  local phase="$1" state_dir expected_shas="${3:-}" allow_dirty_debug="${4:-false}"
  state_dir="$(canonical_state_dir "$2")"
  source_evidence_json \
    "${phase}" "${expected_shas}" "${allow_dirty_debug}" >/dev/null
  for path in chain.json owner.json failure.json stop-request; do
    [[ ! -e "${state_dir}/${path}" ]] || die "state directory is already in use: ${path}"
  done
  require_command curl
  require_command docker
  require_command go
  require_command jq
  require_command npm
  require_command openssl
  require_command python3
  docker container inspect "${PG_CONTAINER}" >/dev/null 2>&1 \
    || die "local TimescaleDB container is not running: ${PG_CONTAINER}"
  docker image inspect "${RUNTIME_IMAGE}" >/dev/null 2>&1 \
    || die "coverage runtime image is missing: ${RUNTIME_IMAGE}"

  local supervisor_args=(
    __supervise --phase "${phase}" --state-dir "${state_dir}"
  )
  [[ -z "${expected_shas}" ]] \
    || supervisor_args+=(--expected-shas "${expected_shas}")
  [[ "${allow_dirty_debug}" == "false" ]] \
    || supervisor_args+=(--allow-dirty-debug)
  nohup "${SCRIPT_PATH}" "${supervisor_args[@]}" \
    >"${state_dir}/supervisor.log" 2>&1 &
  local supervisor_pid="$!" deadline=$((SECONDS + 180))
  local supervisor_identity=""
  for _ in $(seq 1 20); do
    supervisor_identity="$(process_start_identity "${supervisor_pid}")"
    [[ -n "${supervisor_identity}" ]] && break
    kill -0 "${supervisor_pid}" 2>/dev/null || break
    sleep 0.05
  done
  STARTUP_SUPERVISOR_PID="${supervisor_pid}"
  STARTUP_SUPERVISOR_IDENTITY="${supervisor_identity}"
  STARTUP_STATE_DIR="${state_dir}"
  trap cleanup_failed_start EXIT INT TERM
  while [[ ! -f "${state_dir}/chain.json" ]]; do
    if ! kill -0 "${supervisor_pid}" 2>/dev/null; then
      tail -n 120 "${state_dir}/supervisor.log" >&2 || true
      die "service-chain supervisor exited during startup"
    fi
    (( SECONDS < deadline )) || die "timed out starting real service chain"
    sleep 1
  done
  await_state open-1023 "${state_dir}"
  assert_funding_income_once "${state_dir}"
  assert_blocked_worker_heartbeat "${state_dir}"
  trap - EXIT INT TERM
  unset STARTUP_SUPERVISOR_PID STARTUP_SUPERVISOR_IDENTITY STARTUP_STATE_DIR
  echo "runtime Indicator V2 service-chain: start PASS state_dir=${state_dir}"
}

stop_chain() {
  local state_dir
  state_dir="$(canonical_state_dir "$1")"
  require_chain "${state_dir}"
  local pid identity deadline
  pid="$(jq -r .supervisor.pid "${STATE_DIR}/chain.json")"
  identity="$(jq -r .supervisor.process_start_identity "${STATE_DIR}/chain.json")"
  process_matches "${pid}" "${identity}" \
    || die "supervisor process identity no longer matches"
  printf '%s\n' "$(jq -r .owner_token "${STATE_DIR}/chain.json")" \
    >"${STATE_DIR}/stop-request"
  chmod 0600 "${STATE_DIR}/stop-request"
  deadline=$((SECONDS + 90))
  while process_matches "${pid}" "${identity}"; do
    (( SECONDS < deadline )) || {
      terminate_owned_process "${pid}" "${identity}" 360 || true
      die "timed out stopping service-chain supervisor"
    }
    sleep 1
  done
  [[ "$(jq -r '.cleanup.complete // false' "${STATE_DIR}/chain.json")" == "true" ]] \
    || die "service-chain cleanup did not complete"
  echo "runtime Indicator V2 service-chain: stop PASS"
}

usage() {
  cat >&2 <<'EOF'
usage:
  runtime-indicator-v2-service-chain.sh start --phase pre --state-dir /absolute/path
  runtime-indicator-v2-service-chain.sh start --phase pre --state-dir /absolute/path --allow-dirty-debug
  runtime-indicator-v2-service-chain.sh start --phase post --state-dir /absolute/path --expected-shas /absolute/final-shas.json
  runtime-indicator-v2-service-chain.sh await open-1023|finalized-1024-plus-tail|two-full-plus-tail --state-dir /absolute/path
  runtime-indicator-v2-service-chain.sh advance 1025|2049 --state-dir /absolute/path
  runtime-indicator-v2-service-chain.sh stop --state-dir /absolute/path
EOF
  exit 2
}

if [[ "${BASH_SOURCE[0]}" != "$0" ]]; then
  return 0
fi

ACTION="${1:-}"
[[ -n "${ACTION}" ]] || usage
shift
case "${ACTION}" in
  start)
    phase=""
    state_dir=""
    expected_shas=""
    allow_dirty_debug=false
    while (( $# )); do
      case "$1" in
        --phase) phase="${2:-}"; shift 2 ;;
        --state-dir) state_dir="${2:-}"; shift 2 ;;
        --expected-shas) expected_shas="${2:-}"; shift 2 ;;
        --allow-dirty-debug) allow_dirty_debug=true; shift ;;
        *) usage ;;
      esac
    done
    [[ -n "${phase}" && -n "${state_dir}" ]] || usage
    start_chain "${phase}" "${state_dir}" "${expected_shas}" "${allow_dirty_debug}"
    ;;
  await)
    requested="${1:-}"
    shift || true
    [[ "${1:-}" == "--state-dir" && -n "${2:-}" && $# -eq 2 ]] || usage
    await_state "${requested}" "$2"
    ;;
  advance)
    count="${1:-}"
    shift || true
    [[ "${1:-}" == "--state-dir" && -n "${2:-}" && $# -eq 2 ]] || usage
    advance_state "${count}" "$2"
    ;;
  stop)
    [[ "${1:-}" == "--state-dir" && -n "${2:-}" && $# -eq 2 ]] || usage
    stop_chain "$2"
    ;;
  __supervise)
    phase=""
    state_dir=""
    expected_shas=""
    allow_dirty_debug=false
    while (( $# )); do
      case "$1" in
        --phase) phase="${2:-}"; shift 2 ;;
        --state-dir) state_dir="${2:-}"; shift 2 ;;
        --expected-shas) expected_shas="${2:-}"; shift 2 ;;
        --allow-dirty-debug) allow_dirty_debug=true; shift ;;
        *) usage ;;
      esac
    done
    [[ -n "${phase}" && -n "${state_dir}" ]] || usage
    supervise "${phase}" "${state_dir}" "${expected_shas}" "${allow_dirty_debug}"
    ;;
  *)
    usage
    ;;
esac
