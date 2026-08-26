#!/usr/bin/env bash
set -euo pipefail

DEPLOY_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
SOURCE_ROOT="${HUSHINE_SOURCE_ROOT:-$(cd -- "${DEPLOY_ROOT}/.." && pwd -P)}"
COMPOSE_FILE="${DEPLOY_ROOT}/deploy/local/docker-compose.yml"
REQUIRED_REPOSITORIES=(core-service scraper control-panel-service strategy-service hushine-deploy)
OWNED_PIDS=()
OWNED_CONTAINERS=()
EVIDENCE_ROOT=""

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
  if [[ -n "${EVIDENCE_ROOT}" && -f "${EVIDENCE_ROOT}/containers.before" ]]; then
    record_new_local_containers "${EVIDENCE_ROOT}/containers.before" || true
  fi
  for container in "${OWNED_CONTAINERS[@]}"; do
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
  local port="$1" name="$2" deadline=$((SECONDS + 45))
  until python3 - "${port}" <<'PY' >/dev/null 2>&1
import socket, sys
with socket.create_connection(("127.0.0.1", int(sys.argv[1])), timeout=0.25):
    pass
PY
  do
    (( SECONDS < deadline )) || die "${name} did not become ready on loopback:${port}"
    sleep 0.25
  done
}

start_owned() {
  local name="$1"
  shift
  "$@" >"${EVIDENCE_ROOT}/${name}.log" 2>&1 &
  OWNED_PIDS+=("$!")
}

record_new_local_containers() {
  local before_file="$1" container
  while IFS= read -r container; do
    [[ -n "${container}" ]] || continue
    grep -Fqx "${container}" "${before_file}" || OWNED_CONTAINERS+=("${container}")
  done < <(docker compose -f "${COMPOSE_FILE}" ps --status running -q)
}

verify_income_schema() {
  local result
  result="$(docker compose -f "${COMPOSE_FILE}" exec -T timescaledb \
    psql -X -At -U postgres -d portfolio -v ON_ERROR_STOP=1 -c \
    "SELECT
       (SELECT count(*) FROM pg_class WHERE relkind='r' AND relname='venue_income_entries'),
       (SELECT count(*) FROM pg_indexes WHERE schemaname='public' AND indexname IN
         ('uq_venue_income_external_transaction','uq_venue_income_settlement'));"
  )"
  [[ "${result}" == "1|2" ]] \
    || die "Income schema identity = ${result}, want one table and two unique indexes"
  echo "schema: one venue_income_entries table; both unique identities present"
}

build_and_start_services() {
  local mock_port core_http core_grpc control_http control_grpc runtime_grpc scraper_config
  mock_port="$(choose_port)"
  core_http="$(choose_port)"
  core_grpc="$(choose_port)"
  control_http="$(choose_port)"
  control_grpc="$(choose_port)"
  runtime_grpc="$(choose_port)"

  (cd "${SOURCE_ROOT}/core-service" && go build -trimpath -o "${EVIDENCE_ROOT}/mock-binance" ./cmd/mock-binance)
  (cd "${SOURCE_ROOT}/core-service" && go build -trimpath -o "${EVIDENCE_ROOT}/core-service" ./cmd/core-service)
  (cd "${SOURCE_ROOT}/control-panel-service" && go build -trimpath -o "${EVIDENCE_ROOT}/control-panel-service" ./cmd/control-panel-service)
  (cd "${SOURCE_ROOT}/scraper" && go build -trimpath -o "${EVIDENCE_ROOT}/scraper" ./cmd/scraper)

  start_owned mock-binance "${EVIDENCE_ROOT}/mock-binance" -addr "127.0.0.1:${mock_port}"
  wait_tcp "${mock_port}" "Mock Binance"

  start_owned core-service env \
    SERVER_HTTP_ADDR="127.0.0.1:${core_http}" \
    SERVER_GRPC_ADDR="127.0.0.1:${core_grpc}" \
    BINANCE_FUTURES_REST_BASE_URL="http://127.0.0.1:${mock_port}" \
    BINANCE_FUTURES_WS_BASE_URL="ws://127.0.0.1:${mock_port}" \
    NOTIFICATION_ENABLED=false \
    "${EVIDENCE_ROOT}/core-service" -config "${SOURCE_ROOT}/core-service/config.local.yaml"
  wait_tcp "${core_grpc}" "core-service"

  start_owned control-panel-service env \
    SERVER_HTTP_ADDR="127.0.0.1:${control_http}" \
    SERVER_GRPC_ADDR="127.0.0.1:${control_grpc}" \
    RUNTIME_CHANNEL_SERVER_GRPC_ADDR="127.0.0.1:${runtime_grpc}" \
    DEPENDENCIES_CORE_SERVICE_GRPC="127.0.0.1:${core_grpc}" \
    DEPENDENCIES_ORDER_SERVICE_GRPC="127.0.0.1:${core_grpc}" \
    NOTIFICATION_ENABLED=false \
    "${EVIDENCE_ROOT}/control-panel-service" -config "${SOURCE_ROOT}/control-panel-service/config.local.yaml"
  wait_tcp "${control_grpc}" "control-panel-service"
  wait_tcp "${runtime_grpc}" "RuntimeChannel"

  scraper_config="${EVIDENCE_ROOT}/scraper.yaml"
  python3 - "${SOURCE_ROOT}/scraper/config.local.yaml" "${scraper_config}" "${control_grpc}" <<'PY'
from pathlib import Path
import sys
source, target, port = Path(sys.argv[1]), Path(sys.argv[2]), sys.argv[3]
text = source.read_text(encoding="utf-8")
text = text.replace('market_data_control_panel_grpc: "127.0.0.1:50054"', f'market_data_control_panel_grpc: "127.0.0.1:{port}"')
target.write_text(text, encoding="utf-8")
PY
  start_owned scraper "${EVIDENCE_ROOT}/scraper" \
    -config "${scraper_config}" -log-config "${SOURCE_ROOT}/scraper/log-config.local.json"
  sleep 2
  kill -0 "${OWNED_PIDS[${#OWNED_PIDS[@]}-1]}" 2>/dev/null \
    || die "scraper exited during real service startup"
  echo "services: Mock Binance, core-service, control-panel-service, RuntimeChannel, scraper ready"
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
    DATABASE_HOST=127.0.0.1 DATABASE_PORT=5432 DATABASE_USER=postgres DATABASE_PASSWORD=postgres DATABASE_DBNAME=portfolio DATABASE_SSLMODE=disable \
    go test -v -tags=integration ./internal/repository -run '^TestFundingIncomeDurableIdempotencyAndWalletAttribution$' -count=1 \
      | tee "${EVIDENCE_ROOT}/income-timescale-test.log")
  grep -Fq -- '--- PASS: TestFundingIncomeDurableIdempotencyAndWalletAttribution' \
    "${EVIDENCE_ROOT}/income-timescale-test.log" \
    || die "production Timescale Income test did not run to PASS"
  ! grep -Fq -- '--- SKIP:' "${EVIDENCE_ROOT}/income-timescale-test.log" \
    || die "production Timescale Income test skipped"
  echo "assertions: fresh Portfolio schema is complete and idempotent"
  (cd "${SOURCE_ROOT}/core-service" && \
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
  (cd "${SOURCE_ROOT}/strategy-service" && go test ./internal/runtimeagent \
    -run 'Test(IndicatorV2Integration1023ThenTwoFrames|BlockedWorkerKeepsRuntimeHeartbeatAndCanBeReplaced)$' -count=1)
}

main() {
  command -v docker >/dev/null 2>&1 || die "docker is required"
  command -v go >/dev/null 2>&1 || die "go is required"
  command -v uv >/dev/null 2>&1 || die "uv is required"
  require_clean_repositories
  EVIDENCE_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/hushine-funding-chain.XXXXXX")"
  chmod 0700 "${EVIDENCE_ROOT}"
  trap cleanup_owned_resources EXIT HUP INT TERM

  docker compose -f "${COMPOSE_FILE}" ps --status running -q >"${EVIDENCE_ROOT}/containers.before"
  make -C "${DEPLOY_ROOT}" SOURCE_ROOT="${SOURCE_ROOT}" local-infra-up
  record_new_local_containers "${EVIDENCE_ROOT}/containers.before"
  make -C "${DEPLOY_ROOT}" SOURCE_ROOT="${SOURCE_ROOT}" local-configs
  make -C "${DEPLOY_ROOT}" SOURCE_ROOT="${SOURCE_ROOT}" local-ensure-dbs
  make -C "${DEPLOY_ROOT}" SOURCE_ROOT="${SOURCE_ROOT}" local-ensure-dbs
  verify_income_schema
  build_and_start_services
  run_approved_assertions
  echo "funding-income service-chain: PASS"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
