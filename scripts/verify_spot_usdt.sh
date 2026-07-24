#!/usr/bin/env bash
set -euo pipefail

DEPLOY_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
SOURCE_ROOT="${HUSHINE_SOURCE_ROOT:-$(cd "${DEPLOY_ROOT}/.." && pwd -P)}"
DRY_RUN="${HUSHINE_VERIFY_SPOT_DRY_RUN:-0}"
COMMAND_LOG="${HUSHINE_VERIFY_SPOT_COMMAND_LOG:-}"

usage() {
  echo "usage: $0 {backtest|demo|offline|ui|filters|stop|futures|all-local|release} [absolute-coverage-root]" >&2
  exit 64
}

log_line() {
  if [[ -n "${COMMAND_LOG}" ]]; then
    printf '%s\n' "$1" >>"${COMMAND_LOG}"
  fi
}

mark_scope() {
  log_line "scope:$1"
  echo "→ Spot verification scope: $1"
}

command_text() {
  local result="" item
  for item in "$@"; do
    printf -v item '%q' "${item}"
    result+="${result:+ }${item}"
  done
  printf '%s' "${result}"
}

run_in() {
  local directory="$1"
  shift
  log_line "command:cd $(command_text "${directory}") && $(command_text "$@")"
  if [[ "${DRY_RUN}" == "1" ]]; then
    return 0
  fi
  (
    cd "${directory}"
    "$@"
  )
}

require_go_test_exact() {
  local directory="$1" package="$2" test_name="$3" output
  log_line "command:cd $(command_text "${directory}") && $(command_text go test "${package}" -list "^${test_name}$")"
  if [[ "${DRY_RUN}" == "1" ]]; then
    return 0
  fi
  output="$(
    cd "${directory}"
    go test "${package}" -list "^${test_name}$"
  )"
  if ! grep -Fxq "${test_name}" <<<"${output}"; then
    echo "required Go test selection is empty: ${package} ${test_name}" >&2
    return 1
  fi
}

require_go_test_pattern() {
  local directory="$1" package="$2" pattern="$3" output
  log_line "command:cd $(command_text "${directory}") && $(command_text go test "${package}" -list "${pattern}")"
  if [[ "${DRY_RUN}" == "1" ]]; then
    return 0
  fi
  output="$(
    cd "${directory}"
    go test "${package}" -list "${pattern}"
  )"
  if ! grep -Eq '^Test' <<<"${output}"; then
    echo "required Go test pattern is empty: ${package} ${pattern}" >&2
    return 1
  fi
}

require_futures_pytest_collection() {
  local directory output name
  directory="${SOURCE_ROOT}/strategy-service"
  log_line "command:collect-futures-pytest"
  if [[ "${DRY_RUN}" == "1" ]]; then
    return 0
  fi
  output="$(
    cd "${directory}"
    env PYTHONPATH=.:../strategy-library uv run --frozen --extra dev pytest \
      tests/test_wallet_runtime.py tests/test_grpc_server.py --collect-only -q \
      -k 'futures_control_unchanged or futures_stop_paths_unchanged'
  )"
  for name in \
    test_futures_control_unchanged_build_wallet_backtest_environment_uses_binance_parity_after_c2a \
    test_futures_stop_paths_unchanged_stop_strategy_stop_only_persists_state_and_halts_runtime \
    test_futures_stop_paths_unchanged_stop_strategy_stop_and_close_backtest_futures_flattens_wallet; do
    if ! grep -Fq "${name}" <<<"${output}"; then
      echo "required pytest selection is empty: ${name}" >&2
      return 1
    fi
  done
}

run_ui_contracts() {
  log_line 'command:scripts/spot-*.test.mjs'
  if [[ "${DRY_RUN}" != "1" ]]; then
    (
      cd "${SOURCE_ROOT}/gateway/quant-frontend"
      local test_file
      for test_file in scripts/spot-*.test.mjs; do
        [[ -f "${test_file}" ]] || { echo "no Spot UI contracts found" >&2; exit 1; }
        node "${test_file}"
      done
    )
  fi
  run_in "${SOURCE_ROOT}/gateway/quant-frontend" npm run build
}

library_pin() {
  sed -n 's/.*strategy-library\.git", rev = "\([0-9a-f]\{40\}\)".*/\1/p' \
    "${SOURCE_ROOT}/strategy-debugger-cli/pyproject.toml" | head -1
}

debugger_final_pin_check() {
  local expected="$1"
  log_line "command:debugger-final-pin-check ${expected}"
  if [[ "${DRY_RUN}" == "1" ]]; then
    return 0
  fi
  [[ "${#expected}" -eq 40 && "${expected}" != *[!0-9a-f]* ]] \
    || { echo "debugger strategy-library pin is invalid" >&2; return 1; }
  git -C "${SOURCE_ROOT}/strategy-library" cat-file -e "${expected}^{commit}"
  [[ "$(git -C "${SOURCE_ROOT}/strategy-library" rev-parse HEAD)" == "${expected}" ]] \
    || { echo "strategy-library HEAD does not match debugger pin" >&2; return 1; }
  grep -Fq "rev = \"${expected}\"" "${SOURCE_ROOT}/strategy-debugger-cli/pyproject.toml"
  grep -Fq "strategy-library.git?rev=${expected}#${expected}" "${SOURCE_ROOT}/strategy-debugger-cli/uv.lock"
}

run_debugger() {
  local expected
  expected="$(library_pin)"
  [[ "${#expected}" -eq 40 && "${expected}" != *[!0-9a-f]* ]] \
    || { echo "cannot resolve exact debugger strategy-library pin" >&2; return 1; }
  run_in "${SOURCE_ROOT}/strategy-debugger-cli" \
    ./scripts/with-local-strategy-library-git.sh "${SOURCE_ROOT}/strategy-library" "${expected}" "$@"
  debugger_final_pin_check "${expected}"
}

verify_fixture_hashes() {
  local core_fixture hosted_fixture library_fixture debugger_fixture golden fixture
  core_fixture="${SOURCE_ROOT}/core-service/internal/order/risk/testdata/spot_filter_contract_v1.json"
  hosted_fixture="${SOURCE_ROOT}/strategy-service/tests/fixtures/spot_filter_contract_v1.json"
  library_fixture="${SOURCE_ROOT}/strategy-library/tests/fixtures/spot_filter_contract_v1.json"
  debugger_fixture="${SOURCE_ROOT}/strategy-debugger-cli/tests/fixtures/spot_filter_contract_v1.json"
  log_line "command:shasum -a 256 ${core_fixture} ${hosted_fixture} ${library_fixture} ${debugger_fixture}"
  if [[ "${DRY_RUN}" == "1" ]]; then
    return 0
  fi
  golden="$(shasum -a 256 "${core_fixture}" | awk '{print $1}')"
  for fixture in "${hosted_fixture}" "${library_fixture}" "${debugger_fixture}"; do
    [[ "${golden}" == "$(shasum -a 256 "${fixture}" | awk '{print $1}')" ]] \
      || { echo "Spot filter fixture SHA mismatch: ${fixture}" >&2; return 1; }
  done
}

run_backtest() {
  local core_fixture
  core_fixture="${SOURCE_ROOT}/core-service/internal/order/risk/testdata/spot_filter_contract_v1.json"
  mark_scope backtest
  verify_fixture_hashes
  run_in "${SOURCE_ROOT}/core-service" go run ./cmd/generate-spot-filter-vectors -check "${core_fixture}"
  require_go_test_exact "${SOURCE_ROOT}/core-service" ./internal/order/risk TestSpotFilterContract
  run_in "${SOURCE_ROOT}/core-service" go test ./internal/order/risk -run '^TestSpotFilterContract$' -count=1
  run_in "${SOURCE_ROOT}/strategy-service" env PYTHONPATH=.:../strategy-library uv run --frozen --extra dev pytest tests/test_spot_filter_contract.py tests/test_spot_end_to_end.py -q
}

run_offline() {
  mark_scope offline
  verify_fixture_hashes
  run_in "${SOURCE_ROOT}/core-service" go run ./cmd/generate-spot-filter-vectors -check "${SOURCE_ROOT}/strategy-library/tests/fixtures/spot_filter_contract_v1.json"
  run_in "${SOURCE_ROOT}/core-service" go run ./cmd/generate-spot-filter-vectors -check "${SOURCE_ROOT}/strategy-debugger-cli/tests/fixtures/spot_filter_contract_v1.json"
  run_in "${SOURCE_ROOT}/strategy-library" uv run --isolated --no-project --with-editable '.[test]' pytest tests/hushine_strategy/test_spot_filter_contract.py -q
  run_debugger uv run --frozen --extra test pytest tests/test_spot_filter_contract.py tests/test_spot_package_v2.py tests/test_mixed_route_package_v2.py -q
}

run_filters() {
  local core_fixture
  core_fixture="${SOURCE_ROOT}/core-service/internal/order/risk/testdata/spot_filter_contract_v1.json"
  mark_scope filters
  verify_fixture_hashes
  run_in "${SOURCE_ROOT}/core-service" go run ./cmd/generate-spot-filter-vectors -check "${core_fixture}"
  require_go_test_exact "${SOURCE_ROOT}/core-service" ./internal/order/risk TestSpotFilterContract
  run_in "${SOURCE_ROOT}/core-service" go test ./internal/order/risk -run '^TestSpotFilterContract$' -count=1
  run_in "${SOURCE_ROOT}/strategy-service" env PYTHONPATH=.:../strategy-library uv run --frozen --extra dev pytest tests/test_spot_filter_contract.py tests/test_spot_end_to_end.py -q
  run_in "${SOURCE_ROOT}/strategy-library" uv run --isolated --no-project --with-editable '.[test]' pytest tests/hushine_strategy/test_spot_filter_contract.py tests/hushine_strategy/test_mixed_route_replay.py -q
  run_debugger uv run --frozen --extra test pytest tests/test_spot_filter_contract.py tests/test_spot_package_v2.py tests/test_mixed_route_package_v2.py -q
}

run_stop() {
  mark_scope stop
  require_go_test_exact "${SOURCE_ROOT}/core-service" ./internal/order/spotclose TestPlannerSendsNoOrdersWhenAnySpotTargetIsLocked
  run_in "${SOURCE_ROOT}/core-service" go test ./internal/order/spotclose -run '^TestPlannerSendsNoOrdersWhenAnySpotTargetIsLocked$' -count=1
  require_go_test_exact "${SOURCE_ROOT}/core-service" ./internal/order/storage/migrations TestSpotCloseOperationsMigrationContract
  run_in "${SOURCE_ROOT}/core-service" go test ./internal/order/storage/migrations -run '^TestSpotCloseOperationsMigrationContract$' -count=1
  require_go_test_pattern "${SOURCE_ROOT}/control-panel-service" ./internal/runtimechannel '^TestCloseSpotTargetsProxy'
  run_in "${SOURCE_ROOT}/control-panel-service" go test ./internal/runtimechannel -run '^TestCloseSpotTargetsProxy' -count=1
  run_in "${SOURCE_ROOT}/strategy-service" env PYTHONPATH=.:../strategy-library uv run --frozen --extra dev pytest tests/test_grpc_server.py -q -k 'spot and stop'
}

run_futures() {
  mark_scope futures
  require_go_test_exact "${SOURCE_ROOT}/core-service" ./internal/exchange/binance TestFuturesSymbolRuleContractUnchanged
  require_go_test_exact "${SOURCE_ROOT}/core-service" ./internal/exchange/binance TestFuturesExchangeInfoAndRiskControl
  require_go_test_exact "${SOURCE_ROOT}/core-service" ./internal/exchange/binance TestFuturesUserDataListenKeyUnchanged
  run_in "${SOURCE_ROOT}/core-service" go test ./internal/exchange/binance -run '^(TestFuturesSymbolRuleContractUnchanged|TestFuturesExchangeInfoAndRiskControl|TestFuturesUserDataListenKeyUnchanged)$' -count=1
  require_go_test_exact "${SOURCE_ROOT}/core-service" ./internal/order/service TestFuturesMarketLimitRiskLifecycleControlUnchanged
  run_in "${SOURCE_ROOT}/core-service" go test ./internal/order/service -run '^TestFuturesMarketLimitRiskLifecycleControlUnchanged$' -count=1
  require_futures_pytest_collection
  run_in "${SOURCE_ROOT}/strategy-service" env PYTHONPATH=.:../strategy-library uv run --frozen --extra dev pytest tests/test_wallet_runtime.py tests/test_grpc_server.py -q -k 'futures_control_unchanged or futures_stop_paths_unchanged'
  require_go_test_exact "${SOURCE_ROOT}/control-panel-service" ./internal/runtimechannel TestFuturesRuntimeChannelOrderAndStopProxyUnchanged
  run_in "${SOURCE_ROOT}/control-panel-service" go test ./internal/runtimechannel -run '^TestFuturesRuntimeChannelOrderAndStopProxyUnchanged$' -count=1
}

run_all_local() {
  mark_scope all-local
  run_backtest
  run_offline
  mark_scope ui
  run_ui_contracts
  run_filters
  run_stop
  run_futures
}

blocked_demo() {
  echo "BLOCKED_SPOT_DEMO_PREREQUISITE: $*" >&2
  exit 3
}

validate_demo_prerequisites() {
  local coverage_root="$1" fd evidence_parent canonical_parent
  [[ "${coverage_root}" == /* ]] || blocked_demo "coverage root must be absolute"
  [[ -d "${coverage_root}" && ! -L "${coverage_root}" ]] || blocked_demo "coverage root must exist and not be a symlink"
  for name in USER_ID PORTFOLIO_ID VENUE_ID; do
    [[ "${!name:-}" =~ ^[1-9][0-9]*$ ]] || blocked_demo "${name} must be a positive integer"
  done
  [[ "${SPOT_DEMO_RUN_ID:-}" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || blocked_demo "SPOT_DEMO_RUN_ID is missing or unsafe"
  [[ "${SPOT_DEMO_EVIDENCE_FILE:-}" == /* ]] || blocked_demo "SPOT_DEMO_EVIDENCE_FILE must be absolute"
  evidence_parent="$(dirname -- "${SPOT_DEMO_EVIDENCE_FILE}")"
  [[ -d "${evidence_parent}" && ! -L "${evidence_parent}" ]] || blocked_demo "evidence parent must exist and not be a symlink"
  canonical_parent="$(cd "${evidence_parent}" && pwd -P)"
  [[ "${canonical_parent}" == "$(cd "${coverage_root}" && pwd -P)" ]] || blocked_demo "evidence file must be directly under coverage root"
  [[ "$(basename -- "${SPOT_DEMO_EVIDENCE_FILE}")" == "exchange-evidence.json" ]] || blocked_demo "evidence filename must be exchange-evidence.json"
  fd="${SPOT_DEMO_OBSERVER_SESSION_FD:-}"
  [[ "${fd}" =~ ^[0-9]+$ && -w "/dev/fd/${fd}" ]] || blocked_demo "SPOT_DEMO_OBSERVER_SESSION_FD must name an inherited writable FD"
}

run_demo() {
  local coverage_root="$1"
  mark_scope demo
  run_in "${DEPLOY_ROOT}" ./scripts/smoke_spot_demo.sh "${coverage_root}"
}

[[ "$#" -ge 1 ]] || usage
scope="$1"
shift
case "${scope}" in
  backtest|offline|ui|filters|stop|futures|all-local)
    [[ "$#" -eq 0 ]] || usage
    ;;
  demo|release)
    [[ "$#" -eq 1 ]] || usage
    validate_demo_prerequisites "$1"
    ;;
  *)
    usage
    ;;
esac

case "${scope}" in
  backtest) run_backtest ;;
  demo) run_demo "$1" ;;
  offline) run_offline ;;
  ui) mark_scope ui; run_ui_contracts ;;
  filters) run_filters ;;
  stop) run_stop ;;
  futures) run_futures ;;
  all-local) run_all_local ;;
  release)
    coverage_root="$1"
    mark_scope release
    run_all_local
    run_demo "${coverage_root}"
    ;;
esac

echo "✓ Spot USDT verification completed: ${scope}"
