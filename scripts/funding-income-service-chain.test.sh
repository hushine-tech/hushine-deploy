#!/usr/bin/env bash
set -euo pipefail

DEPLOY_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
SOURCE_ROOT="${HUSHINE_SOURCE_ROOT:-$(cd -- "${DEPLOY_ROOT}/.." && pwd -P)}"
COMPOSE_FILE="${DEPLOY_ROOT}/deploy/local/docker-compose.yml"
LOCAL_PG_ADMIN_DSN="postgres://postgres:postgres@127.0.0.1:5432/postgres?sslmode=disable"
REQUIRED_REPOSITORIES=(core-service scraper control-panel-service strategy-service gateway/quant-handler hushine-deploy)
OWNED_PIDS=()
CREATED_CONTAINERS=()
STARTED_EXISTING_CONTAINERS=()
OWNED_DATABASES=()
EVIDENCE_ROOT=""
OWNED_PORTFOLIO_DB=""
OWNED_ORDER_DB=""
OWNED_CONTROL_DB=""
OWNED_MARKET_PREFIX=""
MOCK_PORT=""
CORE_HTTP_PORT=""
CORE_GRPC_PORT=""
CONTROL_HTTP_PORT=""
CONTROL_GRPC_PORT=""
RUNTIME_GRPC_PORT=""

die() {
  echo "funding-income service-chain: $*" >&2
  exit 1
}

require_clean_repositories() {
  local repository status
  for repository in "${REQUIRED_REPOSITORIES[@]}"; do
    [[ -d "${SOURCE_ROOT}/${repository}/.git" || -f "${SOURCE_ROOT}/${repository}/.git" ]] \
      || die "required repository is missing: ${repository}"
    status="$(git -C "${SOURCE_ROOT}/${repository}" status --porcelain --untracked-files=normal)"
    [[ -z "${status}" ]] || die "required repository is dirty: ${repository}"
  done
}

cleanup_owned_processes() {
  local index pid
  for ((index=${#OWNED_PIDS[@]}-1; index>=0; index--)); do
    pid="${OWNED_PIDS[index]}"
    kill -0 "${pid}" 2>/dev/null || continue
    kill -TERM "${pid}" 2>/dev/null || true
    for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
      kill -0 "${pid}" 2>/dev/null || break
      sleep 0.1
    done
    kill -0 "${pid}" 2>/dev/null && kill -KILL "${pid}" 2>/dev/null || true
    wait "${pid}" 2>/dev/null || true
  done
  OWNED_PIDS=()
}

cleanup_owned_resources() {
  local rc="$?" container
  trap - EXIT HUP INT TERM
  cleanup_owned_processes
  drop_owned_databases || true
  if [[ -n "${EVIDENCE_ROOT}" && -f "${EVIDENCE_ROOT}/containers.all.before" ]]; then
    record_local_container_changes || true
  fi
  for container in "${CREATED_CONTAINERS[@]}"; do
    docker rm -f "${container}" >/dev/null 2>&1 || true
  done
  for container in "${STARTED_EXISTING_CONTAINERS[@]}"; do
    docker stop --time 10 "${container}" >/dev/null 2>&1 || true
  done
  [[ -z "${EVIDENCE_ROOT}" ]] || rm -rf -- "${EVIDENCE_ROOT}"
  exit "${rc}"
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

wait_tcp() {
  local port="$1" name="$2" log_name="${3:-$2}"
  local deadline=$((SECONDS + ${SERVICE_READY_TIMEOUT_SECONDS:-45}))
  until python3 - "${port}" <<'PY' >/dev/null 2>&1
import socket, sys
with socket.create_connection(("127.0.0.1", int(sys.argv[1])), timeout=0.25):
    pass
PY
  do
    if (( SECONDS >= deadline )); then
      if [[ -n "${EVIDENCE_ROOT}" && -f "${EVIDENCE_ROOT}/${log_name}.log" ]]; then
        echo "--- ${name} startup log ---" >&2
        tail -n 200 "${EVIDENCE_ROOT}/${log_name}.log" >&2
        echo "--- end ${name} startup log ---" >&2
      fi
      die "${name} did not become ready on loopback:${port}"
    fi
    sleep 0.25
  done
}

wait_http() {
  local url="$1" name="$2" log_name="${3:-$2}" status=""
  local deadline=$((SECONDS + ${SERVICE_READY_TIMEOUT_SECONDS:-45}))
  until status="$(curl -sS -o "${EVIDENCE_ROOT}/${log_name}-http-response" -w '%{http_code}' "${url}" 2>/dev/null)" \
    && [[ "${status}" =~ ^2[0-9][0-9]$ ]]; do
    if (( SECONDS >= deadline )); then
      [[ ! -f "${EVIDENCE_ROOT}/${log_name}.log" ]] || tail -n 200 "${EVIDENCE_ROOT}/${log_name}.log" >&2
      [[ ! -f "${EVIDENCE_ROOT}/${log_name}-http-response" ]] \
        || { echo "--- ${name} HTTP ${status} ---" >&2; cat "${EVIDENCE_ROOT}/${log_name}-http-response" >&2; }
      die "${name} did not become HTTP-ready: ${url}"
    fi
    sleep 0.25
  done
}

start_owned_in() {
  local name="$1" working_directory="$2"
  shift 2
  (cd -- "${working_directory}" && exec "$@") >"${EVIDENCE_ROOT}/${name}.log" 2>&1 &
  OWNED_PIDS+=("$!")
}

append_unique() {
  local name="$1" value="$2" current
  eval 'for current in "${'"${name}"'[@]}"; do [[ "${current}" == "${value}" ]] && return; done'
  eval "${name}+=(\"${value}\")"
}

record_local_container_changes() {
  local container
  while IFS= read -r container; do
    [[ -n "${container}" ]] || continue
    if ! grep -Fqx "${container}" "${EVIDENCE_ROOT}/containers.all.before"; then
      append_unique CREATED_CONTAINERS "${container}"
    elif ! grep -Fqx "${container}" "${EVIDENCE_ROOT}/containers.running.before" \
      && docker inspect -f '{{.State.Running}}' "${container}" 2>/dev/null | grep -Fqx true; then
      append_unique STARTED_EXISTING_CONTAINERS "${container}"
    fi
  done < <(docker compose -f "${COMPOSE_FILE}" ps -a -q)
}

drop_owned_databases() {
  local database
  [[ ${#OWNED_DATABASES[@]} -gt 0 ]] || return 0
  for database in "${OWNED_DATABASES[@]}"; do
    [[ "${database}" =~ ^hushine_funding_chain_[a-z0-9_]+$ ]] || continue
    docker compose -f "${COMPOSE_FILE}" exec -T timescaledb \
      psql -X -q -U postgres -d postgres -v ON_ERROR_STOP=1 \
      -v owned_db="${database}" -c \
      "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname = :'owned_db' AND pid <> pg_backend_pid();" \
      >/dev/null 2>&1 || true
    docker compose -f "${COMPOSE_FILE}" exec -T timescaledb \
      dropdb -U postgres --if-exists "${database}" >/dev/null 2>&1 || true
  done
  OWNED_DATABASES=()
}

verify_income_schema() {
  local result
  result="$(docker compose -f "${COMPOSE_FILE}" exec -T timescaledb \
    psql -X -At -U postgres -d "${OWNED_PORTFOLIO_DB}" -v ON_ERROR_STOP=1 -c \
    "SELECT
       (SELECT count(*) FROM pg_class WHERE relkind='r' AND relname='venue_income_entries'),
       (SELECT count(*) FROM pg_indexes WHERE schemaname='public' AND indexname IN
         ('uq_venue_income_external_transaction','uq_venue_income_settlement'));"
  )"
  [[ "${result}" == "1|2" ]] \
    || die "Income schema identity = ${result}, want one table and two unique indexes"
  echo "schema: one venue_income_entries table; both unique identities present"
}

initialize_owned_databases() {
  local suffix year pass
  suffix="$(python3 - <<'PY'
import secrets
print(secrets.token_hex(4))
PY
)"
  year="$(date -u +%Y)"
  OWNED_PORTFOLIO_DB="hushine_funding_chain_${suffix}_portfolio"
  OWNED_ORDER_DB="hushine_funding_chain_${suffix}_order"
  OWNED_CONTROL_DB="hushine_funding_chain_${suffix}_control"
  OWNED_MARKET_PREFIX="hushine_funding_chain_${suffix}_"
  OWNED_DATABASES=(
    "${OWNED_PORTFOLIO_DB}"
    "${OWNED_ORDER_DB}"
    "${OWNED_CONTROL_DB}"
    "${OWNED_MARKET_PREFIX}binance_${year}"
  )
  for pass in 1 2; do
    echo "database bootstrap pass ${pass}: owned service-chain databases"
    (cd "${SOURCE_ROOT}/core-service" && \
      PGHOST=127.0.0.1 PGPORT=5432 PGUSER=postgres PGPASSWORD=postgres PGDATABASE_ADMIN=postgres \
      PGDATABASE_PORTFOLIO="${OWNED_PORTFOLIO_DB}" make ensure-db)
    (cd "${SOURCE_ROOT}/core-service" && \
      ORDER_DATABASE_HOST=127.0.0.1 ORDER_DATABASE_PORT=5432 ORDER_DATABASE_USER=postgres \
      ORDER_DATABASE_PASSWORD=postgres ORDER_DATABASE_DBNAME="${OWNED_ORDER_DB}" ORDER_DATABASE_SSLMODE=disable \
      make ensure-order-db)
    (cd "${SOURCE_ROOT}/control-panel-service" && \
      PGHOST=127.0.0.1 PGPORT=5432 PGUSER=postgres PGPASSWORD=postgres PGDATABASE_ADMIN=postgres \
      PGDATABASE_CONTROL_PANEL="${OWNED_CONTROL_DB}" make ensure-db)
    (cd "${SOURCE_ROOT}/scraper" && \
      PGHOST=127.0.0.1 PGPORT=5432 PGUSER=postgres PGPASSWORD=postgres PGDATABASE_ADMIN=postgres \
      SCRAPER_DATABASE_PREFIX="${OWNED_MARKET_PREFIX}" SCRAPER_EXCHANGES=binance SCRAPER_YEARS="${year}" \
      make ensure-db)
  done
}

prepare_service_chain_configs() {
  python3 - \
    "${SOURCE_ROOT}/core-service/config.local.yaml" \
    "${SOURCE_ROOT}/control-panel-service/config.local.yaml" \
    "${SOURCE_ROOT}/scraper/config.local.yaml" \
    "${SOURCE_ROOT}/scraper/log-config.local.json" \
    "${EVIDENCE_ROOT}" "${OWNED_MARKET_PREFIX}" <<'PY'
import json
from pathlib import Path
import re
import sys

core_source, control_source, scraper_source, scraper_log_source, output, market_prefix = sys.argv[1:]
output = Path(output)

def isolated_service_yaml(source, target, log_dir):
    text = Path(source).read_text(encoding="utf-8")
    log_match = re.search(r"(?ms)^log:\n.*?(?=^[^ \n]|\Z)", text)
    if not log_match:
        raise SystemExit(f"log block missing: {source}")
    block = log_match.group(0)
    block, kafka_count = re.subn(
        r"(?m)^(  kafka:\n    enabled:) true$", r"\1 false", block, count=1
    )
    block, trace_count = re.subn(
        r"(?m)^(  tracing:\n    enabled:) true$", r"\1 false", block, count=1
    )
    block, output_count = re.subn(
        r'(?m)^  output_dir:.*$', f'  output_dir: {json.dumps(str(log_dir))}', block, count=1
    )
    if (kafka_count, trace_count, output_count) != (1, 1, 1):
        raise SystemExit(f"log isolation fields missing: {source}")
    Path(target).write_text(text[:log_match.start()] + block + text[log_match.end():], encoding="utf-8")

isolated_service_yaml(core_source, output / "core-service.yaml", output / "core-logs")
isolated_service_yaml(control_source, output / "control-panel-service.yaml", output / "control-logs")

scraper_text = Path(scraper_source).read_text(encoding="utf-8")
scraper_text, count = re.subn(
    r'dbname: "\{exchange\}_\{year\}"',
    f'dbname: "{market_prefix}{{exchange}}_{{year}}"',
    scraper_text,
)
if count < 2:
    raise SystemExit("scraper database templates are missing")
Path(output / "scraper.yaml").write_text(scraper_text, encoding="utf-8")

scraper_log = json.loads(Path(scraper_log_source).read_text(encoding="utf-8"))
scraper_log["output_dir"] = str(output / "scraper-logs")
scraper_log["kafka"]["enabled"] = False
scraper_log["tracing"]["enabled"] = False
Path(output / "scraper-log.json").write_text(json.dumps(scraper_log, indent=2) + "\n", encoding="utf-8")
PY
  chmod 0600 \
    "${EVIDENCE_ROOT}/core-service.yaml" \
    "${EVIDENCE_ROOT}/control-panel-service.yaml" \
    "${EVIDENCE_ROOT}/scraper.yaml" \
    "${EVIDENCE_ROOT}/scraper-log.json"
}

build_and_start_services() {
  MOCK_PORT="$(choose_port)"
  CORE_HTTP_PORT="$(choose_port)"
  CORE_GRPC_PORT="$(choose_port)"
  CONTROL_HTTP_PORT="$(choose_port)"
  CONTROL_GRPC_PORT="$(choose_port)"
  RUNTIME_GRPC_PORT="$(choose_port)"

  (cd "${SOURCE_ROOT}/core-service" && go build -trimpath -o "${EVIDENCE_ROOT}/mock-binance" ./cmd/mock-binance)
  (cd "${SOURCE_ROOT}/core-service" && go build -trimpath -o "${EVIDENCE_ROOT}/core-service" ./cmd/core-service)
  (cd "${SOURCE_ROOT}/core-service" && go build -trimpath -o "${EVIDENCE_ROOT}/funding-income-demo-smoke" ./cmd/funding-income-demo-smoke)
  (cd "${SOURCE_ROOT}/control-panel-service" && go build -trimpath -o "${EVIDENCE_ROOT}/control-panel-service" ./cmd/control-panel-service)
  (cd "${SOURCE_ROOT}/scraper" && go build -trimpath -o "${EVIDENCE_ROOT}/scraper" ./cmd/scraper)

  start_owned_in mock-binance "${SOURCE_ROOT}/core-service" \
    "${EVIDENCE_ROOT}/mock-binance" -addr "127.0.0.1:${MOCK_PORT}"
  wait_tcp "${MOCK_PORT}" "Mock Binance"

  start_owned_in core-service "${SOURCE_ROOT}/core-service" env \
    SERVER_HTTP_ADDR="127.0.0.1:${CORE_HTTP_PORT}" \
    SERVER_GRPC_ADDR="127.0.0.1:${CORE_GRPC_PORT}" \
    DATABASE_DBNAME="${OWNED_PORTFOLIO_DB}" \
    ORDER_DATABASE_DBNAME="${OWNED_ORDER_DB}" \
    BINANCE_FUTURES_REST_BASE_URL="http://127.0.0.1:${MOCK_PORT}" \
    BINANCE_FUTURES_WS_BASE_URL="ws://127.0.0.1:${MOCK_PORT}" \
    NOTIFICATION_ENABLED=false \
    "${EVIDENCE_ROOT}/core-service" -config "${EVIDENCE_ROOT}/core-service.yaml"
  wait_tcp "${CORE_GRPC_PORT}" "core-service"

  start_owned_in control-panel-service "${SOURCE_ROOT}/control-panel-service" env \
    SERVER_HTTP_ADDR="127.0.0.1:${CONTROL_HTTP_PORT}" \
    SERVER_GRPC_ADDR="127.0.0.1:${CONTROL_GRPC_PORT}" \
    DATABASE_DBNAME="${OWNED_CONTROL_DB}" \
    MARKET_DATA_DB_DATABASE="${OWNED_MARKET_PREFIX}{exchange}_{year}" \
    RUNTIME_CHANNEL_SERVER_GRPC_ADDR="127.0.0.1:${RUNTIME_GRPC_PORT}" \
    DEPENDENCIES_CORE_SERVICE_GRPC="127.0.0.1:${CORE_GRPC_PORT}" \
    DEPENDENCIES_ORDER_SERVICE_GRPC="127.0.0.1:${CORE_GRPC_PORT}" \
    NOTIFICATION_ENABLED=false \
    "${EVIDENCE_ROOT}/control-panel-service" -config "${EVIDENCE_ROOT}/control-panel-service.yaml"
  wait_tcp "${CONTROL_GRPC_PORT}" "control-panel-service"
  wait_tcp "${RUNTIME_GRPC_PORT}" "RuntimeChannel"

  python3 - "${EVIDENCE_ROOT}/scraper.yaml" "${CONTROL_GRPC_PORT}" <<'PY'
from pathlib import Path
import sys
target, port = Path(sys.argv[1]), sys.argv[2]
text = target.read_text(encoding="utf-8")
text = text.replace('market_data_control_panel_grpc: "127.0.0.1:50054"', f'market_data_control_panel_grpc: "127.0.0.1:{port}"')
target.write_text(text, encoding="utf-8")
PY
  start_owned_in scraper "${SOURCE_ROOT}/scraper" "${EVIDENCE_ROOT}/scraper" \
    -config "${EVIDENCE_ROOT}/scraper.yaml" -log-config "${EVIDENCE_ROOT}/scraper-log.json"
  sleep 2
  kill -0 "${OWNED_PIDS[${#OWNED_PIDS[@]}-1]}" 2>/dev/null \
    || die "scraper exited during real service startup"
  echo "services: Mock Binance, core-service, control-panel-service, RuntimeChannel, scraper ready"
}

probe_started_mock_adapter() {
  curl -fsS "http://127.0.0.1:${MOCK_PORT}/fapi/v1/exchangeInfo" \
    >"${EVIDENCE_ROOT}/mock-exchange-info.json"
  (
    exec 3< <(printf '%s\n%s\n' 'service-chain-key' 'service-chain-secret')
    env -i PATH="${PATH}" HOME="${HOME:-/tmp}" TMPDIR="${TMPDIR:-/tmp}" \
      "${EVIDENCE_ROOT}/funding-income-demo-smoke" \
      --credential-fd 3 --venue-id 1 --session-id service-chain \
      --environment demo --rest-base-url "http://127.0.0.1:${MOCK_PORT}"
  ) >"${EVIDENCE_ROOT}/mock-income-summary.json"
  python3 - "${EVIDENCE_ROOT}/mock-income-summary.json" <<'PY'
import json, sys
summary = json.load(open(sys.argv[1], encoding="utf-8"))
assert summary["environment"] == "demo"
assert summary["venue_id"] == 1
assert summary["record_count"] >= 0
PY
  ! grep -Eq 'service-chain-(key|secret)|signature=|tranId|incomeType' \
    "${EVIDENCE_ROOT}/mock-income-summary.json" \
    || die "started Mock adapter probe leaked credential or Income detail"
  echo "probe: production Demo Income adapter reached started Mock Binance"
}

probe_started_core_http() {
  wait_http "http://127.0.0.1:${CORE_HTTP_PORT}/portfolios?user_id=1" "core-service" "core-service"
  curl -fsS "http://127.0.0.1:${CORE_HTTP_PORT}/portfolios?user_id=1" \
    >"${EVIDENCE_ROOT}/core-portfolios.json"
  python3 - "${EVIDENCE_ROOT}/core-portfolios.json" <<'PY'
import json, sys
assert isinstance(json.load(open(sys.argv[1], encoding="utf-8")), list)
PY
  echo "probe: started core-service queried its owned Portfolio database"
}

probe_started_control_http() {
  wait_http "http://127.0.0.1:${CONTROL_HTTP_PORT}/healthz" "control-panel health" "control-panel-service"
  wait_http "http://127.0.0.1:${CONTROL_HTTP_PORT}/readyz" "control-panel readiness" "control-panel-service"
  echo "probe: started control-panel-service health and readiness passed"
}

probe_started_runtime_channel_mtls() {
  openssl req -new -newkey rsa:2048 -nodes -subj '/CN=funding-chain-runtime-client' \
    -keyout "${EVIDENCE_ROOT}/runtime-client.key" \
    -out "${EVIDENCE_ROOT}/runtime-client.csr" >/dev/null 2>&1
  openssl x509 -req -days 1 -sha256 \
    -in "${EVIDENCE_ROOT}/runtime-client.csr" \
    -CA "${DEPLOY_ROOT}/certs/runtime-client-ca.pem" \
    -CAkey "${DEPLOY_ROOT}/certs/runtime-client-ca.key" \
    -CAserial "${EVIDENCE_ROOT}/runtime-client-ca.srl" -CAcreateserial \
    -out "${EVIDENCE_ROOT}/runtime-client.pem" >/dev/null 2>&1
  openssl s_client -quiet -verify_return_error \
    -connect "127.0.0.1:${RUNTIME_GRPC_PORT}" \
    -servername runtime-channel.local \
    -CAfile "${DEPLOY_ROOT}/certs/runtime-channel-ca.pem" \
    -cert "${EVIDENCE_ROOT}/runtime-client.pem" \
    -key "${EVIDENCE_ROOT}/runtime-client.key" \
    </dev/null >"${EVIDENCE_ROOT}/runtime-channel-mtls.log" 2>&1 || true
  grep -Fq 'Verification: OK' "${EVIDENCE_ROOT}/runtime-channel-mtls.log" \
    || grep -Fq 'Verify return code: 0 (ok)' "${EVIDENCE_ROOT}/runtime-channel-mtls.log" \
    || die "started RuntimeChannel did not complete an authenticated mTLS handshake"
  echo "probe: started RuntimeChannel accepted an mTLS client"
}

probe_started_scraper_reconcile() {
  local scraper_pid="${OWNED_PIDS[${#OWNED_PIDS[@]}-1]}" deadline=$((SECONDS + 15))
  until [[ -f "${EVIDENCE_ROOT}/scraper-logs/system.log" ]] \
    && grep -Fq 'market_data_control_plane_ready' "${EVIDENCE_ROOT}/scraper-logs/system.log"; do
    kill -0 "${scraper_pid}" 2>/dev/null || die "scraper exited before control-plane reconcile"
    (( SECONDS < deadline )) || die "scraper did not initialize the control-plane client"
    sleep 0.25
  done
  sleep 6
  kill -0 "${scraper_pid}" 2>/dev/null || die "scraper exited during control-plane reconcile"
  ! grep -Fq 'market_data_control_plane_reconcile_failed' "${EVIDENCE_ROOT}/scraper-logs/system.log" \
    || die "started scraper failed to reconcile through started control-panel-service"
  echo "probe: started scraper completed control-plane reconcile without error"
}

probe_started_services() {
  probe_started_mock_adapter
  probe_started_core_http
  probe_started_control_http
  probe_started_runtime_channel_mtls
  probe_started_scraper_reconcile
}

run_approved_assertions() {
  echo "assertions: Mock Spot/Futures GTC IOC FOK GTX Market"
  (cd "${SOURCE_ROOT}/core-service" && go test ./internal/exchange/binance \
    -run '^TestBinanceFactoryMock(CapturesOrderConditionCombinations|MapsSpotAndFuturesOrderOutcomes)$' -count=1)
  echo "assertions: liquidation/ADL and Account Update/REST + REST-only once"
  (cd "${SOURCE_ROOT}/core-service" && go test ./internal/order/executor ./internal/income \
    -run 'Test(UserDataStreamManagerPreservesMatchedFuturesLiquidationAndADLEventTypeAfterRESTRecovery|UserDataStreamManagerSpotAccountEventsNeverEnterFunding|FundingAccountEventCreatesPendingAndTriggersImmediateIncomeRepair|FundingCoordinatorDuplicateRESTRecordsConvergeWithoutSecondWalletEffect)$' -count=1)
  echo "assertions: production Timescale Income wallet idempotency"
  (cd "${SOURCE_ROOT}/core-service" && \
    DATABASE_HOST=127.0.0.1 DATABASE_PORT=5432 DATABASE_USER=postgres DATABASE_PASSWORD=postgres DATABASE_DBNAME="${OWNED_PORTFOLIO_DB}" DATABASE_SSLMODE=disable \
    go test -v -tags=integration ./internal/repository -run '^TestFundingIncomeDurableIdempotencyAndWalletAttribution$' -count=1 \
      | tee "${EVIDENCE_ROOT}/income-timescale-test.log")
  grep -Fq -- '--- PASS: TestFundingIncomeDurableIdempotencyAndWalletAttribution' \
    "${EVIDENCE_ROOT}/income-timescale-test.log" \
    || die "production Timescale Income test did not run to PASS"
  ! grep -Fq -- '--- SKIP:' "${EVIDENCE_ROOT}/income-timescale-test.log" \
    || die "production Timescale Income test skipped"
  echo "assertions: fresh Portfolio schema is complete and idempotent"
  (cd "${SOURCE_ROOT}/core-service" && \
    HUSHINE_TEST_PG_ADMIN_DSN="${LOCAL_PG_ADMIN_DSN}" \
    go test -v -tags=integration ./internal/storage/migrations \
      -run '^TestPortfolioBaselineFreshBootstrapIsCompleteAndIdempotent$' -count=1 \
      | tee "${EVIDENCE_ROOT}/fresh-schema-test.log")
  grep -Fq -- '--- PASS: TestPortfolioBaselineFreshBootstrapIsCompleteAndIdempotent' \
    "${EVIDENCE_ROOT}/fresh-schema-test.log" \
    || die "fresh Portfolio schema integration did not run to PASS"
  echo "assertions: BTC/ETH/ZEC Funding-before-Kline and Spot no Funding"
  (cd "${SOURCE_ROOT}/strategy-service" && \
    PYTHONPATH=.:../strategy-library uv run --frozen --extra dev pytest -q \
      tests/test_backtest_pages.py::test_btc_eth_zec_same_time_funding_precedes_every_kline_in_stream_order \
      tests/test_backtest_pages.py::test_spot_timeline_contains_only_klines_and_no_funding_coverage_requirement \
      tests/test_grpc_server.py::test_spot_backtest_never_settles_funding)
  echo "assertions: 1023->1025 seal/open and blocked/restarted Worker heartbeat/Income once"
  (cd "${SOURCE_ROOT}/strategy-service" && go test -v -tags=integration ./internal/runtimeagent \
    -run 'Test(IndicatorV2Integration1023ThenTwoFrames|BlockedWorkerKeepsRuntimeHeartbeatAndCanBeReplaced)$' -count=1 \
      | tee "${EVIDENCE_ROOT}/runtimeagent-integration-test.log")
  grep -Fq -- '--- PASS: TestIndicatorV2Integration1023ThenTwoFrames' \
    "${EVIDENCE_ROOT}/runtimeagent-integration-test.log" \
    || die "Indicator V2 integration test did not run to PASS"
  grep -Fq -- '--- PASS: TestBlockedWorkerKeepsRuntimeHeartbeatAndCanBeReplaced' \
    "${EVIDENCE_ROOT}/runtimeagent-integration-test.log" \
    || die "blocked-worker integration test did not run to PASS"
  ! grep -Fq -- '--- SKIP:' "${EVIDENCE_ROOT}/runtimeagent-integration-test.log" \
    || die "runtime-agent integration test skipped"
}

main() {
  command -v docker >/dev/null 2>&1 || die "docker is required"
  command -v go >/dev/null 2>&1 || die "go is required"
  command -v uv >/dev/null 2>&1 || die "uv is required"
  command -v curl >/dev/null 2>&1 || die "curl is required"
  command -v openssl >/dev/null 2>&1 || die "openssl is required"
  require_clean_repositories
  EVIDENCE_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/hushine-funding-chain.XXXXXX")"
  chmod 0700 "${EVIDENCE_ROOT}"
  trap cleanup_owned_resources EXIT HUP INT TERM

  docker compose -f "${COMPOSE_FILE}" ps -a -q >"${EVIDENCE_ROOT}/containers.all.before"
  docker compose -f "${COMPOSE_FILE}" ps --status running -q >"${EVIDENCE_ROOT}/containers.running.before"
  docker image inspect elk-kafka-es-bridge:latest >/dev/null 2>&1 \
    || docker compose -f "${COMPOSE_FILE}" build kafka-es-bridge
  docker compose -f "${COMPOSE_FILE}" up -d --no-build --no-recreate
  record_local_container_changes
  make -C "${DEPLOY_ROOT}" SOURCE_ROOT="${SOURCE_ROOT}" local-configs
  initialize_owned_databases
  prepare_service_chain_configs
  verify_income_schema
  build_and_start_services
  probe_started_services
  run_approved_assertions
  echo "funding-income service-chain: PASS"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
