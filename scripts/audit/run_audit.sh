#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
MODE="${1:-all}"
AUDIT_RUN_E2E="${AUDIT_RUN_E2E:-0}"
AUDIT_HTTP_PORT="${AUDIT_HTTP_PORT:-18091}"
export GOCACHE="${GOCACHE:-${ROOT}/.cache/go-build}"

choose_python() {
    local cand
    for cand in "${PYTHON:-}" /opt/anaconda3/bin/python3 python3 python; do
        if [ -n "${cand}" ] && command -v "${cand}" >/dev/null 2>&1; then
            printf '%s\n' "${cand}"
            return 0
        fi
    done
    return 1
}

if ! PYTHON_BIN="$(choose_python)"; then
    echo "No Python interpreter found. Set PYTHON=/path/to/python3."
    exit 1
fi

mkdir -p "${ROOT}/.audit-build" "${GOCACHE}"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m'

FAILURES=0
SKIPS=0
PASSES=0

pass() {
    PASSES=$((PASSES + 1))
    echo -e "${GREEN}PASS${NC} $1"
}

fail() {
    FAILURES=$((FAILURES + 1))
    echo -e "${RED}FAIL${NC} $1"
}

skip() {
    SKIPS=$((SKIPS + 1))
    echo -e "${YELLOW}SKIP${NC} $1"
}

section() {
    echo
    echo -e "${BLUE}== $1 ==${NC}"
}

can_bind_local_port() {
    "${PYTHON_BIN}" - <<'PY'
import socket
import sys

s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
try:
    s.bind(("127.0.0.1", 0))
except OSError:
    sys.exit(1)
finally:
    s.close()
PY
}

run_step() {
    local label="$1"
    local dir="$2"
    local cmd="$3"

    echo "-> ${label}"
    if (cd "${dir}" && eval "${cmd}"); then
        pass "${label}"
    else
        fail "${label}"
    fi
}

run_quant_handler_smoke() {
    local label="quant-handler standalone /healthz smoke"
    local bin="${ROOT}/.audit-build/quant-handler"
    local log_file="/tmp/hushine-audit-quant-handler.log"
    local pid=""
    local ok="0"

    echo "-> ${label}"
    if ! (cd "${ROOT}/gateway/quant-handler" && go build -o "${bin}" ./cmd/quant-handler); then
        fail "${label} (build)"
        return
    fi

    (
        cd "${ROOT}/gateway/quant-handler"
        # Compatibility var: order.v1 is served by core-service in normal runs.
        CORE_SERVICE_GRPC_ADDR="127.0.0.1:59991" \
        ORDER_SERVICE_GRPC_ADDR="127.0.0.1:59991" \
        AUTH_JWT_SECRET="audit-secret" \
        AUTH_LOGIN_PASSWORD="audit-password" \
        HTTP_ADDR=":${AUDIT_HTTP_PORT}" \
        "${bin}" -config "/tmp/hushine-audit-missing-quant-handler.yaml" >"${log_file}" 2>&1
    ) &
    pid=$!

    for _ in $(seq 1 20); do
        if curl -fsS "http://127.0.0.1:${AUDIT_HTTP_PORT}/healthz" >/dev/null 2>&1; then
            ok="1"
            break
        fi
        sleep 0.5
    done

    kill "${pid}" >/dev/null 2>&1 || true
    wait "${pid}" >/dev/null 2>&1 || true

    if [ "${ok}" = "1" ]; then
        pass "${label}"
    elif grep -q "bind: operation not permitted" "${log_file}" 2>/dev/null; then
        skip "${label} (sandbox does not allow local port bind)"
    else
        fail "${label}"
        echo "   log: ${log_file}"
    fi
}

run_compatibility() {
    section "Compatibility"
    run_step "golang-lib go test (non-bind packages)" "${ROOT}/golang-lib" \
        'pkgs="$(go list ./... | grep -v "/middleware/httpclient$" | grep -v "/middleware/wsclient$")"; go test ${pkgs}'
    if can_bind_local_port; then
        run_step "golang-lib/middleware/httpclient go test" "${ROOT}/golang-lib" "go test ./middleware/httpclient"
        run_step "golang-lib/middleware/wsclient go test" "${ROOT}/golang-lib" "go test ./middleware/wsclient"
    else
        skip "golang-lib/middleware/httpclient go test (sandbox does not allow local listener bind)"
        skip "golang-lib/middleware/wsclient go test (sandbox does not allow local listener bind)"
    fi
    run_step "golang-lib/log-shipper go test ./..." "${ROOT}/golang-lib/log-shipper" "go test ./..."
    run_step "core-service build" "${ROOT}/core-service" "go build ./cmd/core-service"
    run_step "core-service make test" "${ROOT}/core-service" "make test"
    run_step "core-service order module build" "${ROOT}/core-service" "go build ./cmd/ensure-order-db"
    run_step "core-service order module tests" "${ROOT}/core-service" "go test ./internal/order/..."
    run_step "gateway/quant-handler build" "${ROOT}/gateway/quant-handler" "go build ./cmd/quant-handler"
    run_step "gateway/quant-handler make test" "${ROOT}/gateway/quant-handler" "make test"
    run_quant_handler_smoke
    run_step "scraper build" "${ROOT}/scraper" "go build ./cmd/scraper"
    run_step "scraper go test ./..." "${ROOT}/scraper" "go test ./..."
}

run_wallet() {
    section "Wallet"
    run_step "strategy-library wallet matrix tests" "${ROOT}/strategy-library" \
        "PYTHONPATH=. ${PYTHON_BIN} -m pytest tests/test_indicator_scenarios.py tests/test_cross_margin.py tests/test_hedge_mode.py tests/test_liquidation_risk.py tests/test_wallet_hierarchy.py tests/test_binance_wallet.py -q"
    run_step "strategy-service wallet and ordering tests" "${ROOT}/strategy-service" \
        "PYTHONPATH=.:./strategy-library ${PYTHON_BIN} -m pytest tests/test_strategy_engine.py tests/test_data_loop.py tests/test_wallet_strict_rules.py -q"
}

run_core_flow() {
    section "Core Flow"
    if [ "${AUDIT_RUN_E2E}" != "1" ]; then
        skip "scripts/e2e_full_flow.sh (set AUDIT_RUN_E2E=1 to enable infra-backed backtest e2e)"
        return
    fi
    run_step "scripts/e2e_full_flow.sh" "${ROOT}" "bash scripts/e2e_full_flow.sh"
}

usage() {
    cat <<'EOF'
Usage: bash scripts/audit/run_audit.sh [all|compatibility|wallet|core-flow]

Environment:
  PYTHON=/path/to/python3   Override Python interpreter.
  AUDIT_RUN_E2E=1           Enable infra-backed backtest e2e.
  AUDIT_HTTP_PORT=18091     Override quant-handler standalone smoke port.
EOF
}

case "${MODE}" in
    all)
        run_compatibility
        run_wallet
        run_core_flow
        ;;
    compatibility)
        run_compatibility
        ;;
    wallet)
        run_wallet
        ;;
    core-flow)
        run_core_flow
        ;;
    -h|--help|help)
        usage
        exit 0
        ;;
    *)
        echo "Unknown audit mode: ${MODE}"
        usage
        exit 2
        ;;
esac

echo
echo "Summary: PASS=${PASSES} FAIL=${FAILURES} SKIP=${SKIPS}"
exit "${FAILURES}"
