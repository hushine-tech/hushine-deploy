#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
DEPLOY_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd -P)"
source "${DEPLOY_ROOT}/scripts/lib/runtime_coverage.sh"
SOURCE_ROOT="${HUSHINE_SOURCE_ROOT:-$(cd "${DEPLOY_ROOT}/.." && pwd -P)}"

if ! UV_BIN="$(runtime_coverage_resolve_uv_bin)"; then
  echo "runtime Indicator V2 smoke requires uv" >&2
  exit 2
fi
export UV_BIN

run_in() {
  local repository="$1"
  shift
  (
    cd "${SOURCE_ROOT}/${repository}"
    "$@"
  )
}

echo "→ Runtime Indicator V2 database gate"
HUSHINE_SOURCE_ROOT="${SOURCE_ROOT}" \
  "${SCRIPT_DIR}/runtime-indicator-v2-db-smoke.sh"

echo "→ Core V1/V2 coexistence and V2 service contracts"
run_in core-service \
  go test ./internal/service ./internal/repository \
  -run 'IndicatorProtoV1CoexistsWithV2|StrategyIndicator.*V2|Indicator.*V2' \
  -count=1 -v

echo "→ Authenticated RuntimeChannel V2 proxy"
run_in control-panel-service \
  go test ./internal/runtimechannel \
  -run 'IndicatorProtoV1CoexistsWithV2|Indicator.*V2|SessionFinalizationPending' \
  -count=1 -v

echo "→ Agent chunk/lifecycle/retry integration"
run_in strategy-service \
  go test ./internal/runtimeagent \
  -run 'TestIndicatorV2Integration1023ThenTwoFrames|IndicatorBufferV2|IndicatorStreamClock|SessionLifecycle|RetryPending|UnexpectedExit|RestartSession|TerminalRetry' \
  -count=1 -v

echo "→ Python production-shaped open-time fixture and additive worker wire"
(
  cd "${SOURCE_ROOT}/strategy-service"
  PYTHONPATH=".:../strategy-library" "${UV_BIN}" run --frozen --extra dev \
    pytest \
    tests/test_indicator_v2_open_time_cutover.py \
    tests/test_runtime_worker_proto.py \
    tests/test_worker_agent_client.py \
    -q
)

echo "→ Ten-minute blocked-user-code heartbeat/restart acceptance"
(
  cd "${SOURCE_ROOT}/strategy-service"
  HUSHINE_BLOCKED_WORKER_SECONDS="${HUSHINE_BLOCKED_WORKER_SECONDS:-660}" \
    HUSHINE_BLOCKED_WORKER_OBSERVE_SECONDS="${HUSHINE_BLOCKED_WORKER_OBSERVE_SECONDS:-600}" \
    ./scripts/runtime-agent-blocked-worker.test.sh
)

echo "→ Bare/Windows-compatible Runtime boundaries"
run_in strategy-service bash scripts/start-bare-runtime-debugpy.test.sh
run_in strategy-service bash scripts/runtime-agent-platform.test.sh

echo "→ Handler V1/V2 coexistence and field-preserving V2 JSON"
run_in gateway/quant-handler \
  go test ./internal/app \
  -run 'StrategyIndicatorV1CoexistsWithV2|StrategyIndicator.*V2|Session.*FinalizationPending' \
  -count=1 -v

echo "→ Portal V2 cache/time/marker/status contracts"
(
  cd "${SOURCE_ROOT}/gateway/quant-frontend"
  node scripts/session-indicator-data.test.mjs
  node scripts/runtime-status.test.mjs
  npm run test:session-custom-indicators
  npm run build
)

echo "✓ Runtime Indicator V2 focused smoke passed"
