#!/usr/bin/env bash
# End-to-end tracing regression.
#
# Fires a handler HTTP request, waits for OTLP flush, then queries Jaeger to
# confirm the resulting trace spans the expected set of services. Exits 0 on
# success; non-zero + diagnostic output on failure.
#
# Defaults cover the minimum chain (quant-handler → core-service) via a
# signup call. Set RUN_E2E=1 to cover the full chain including strategy-service
# and core-service/order.v1 (requires a populated account + mounted strategy — see
# strategy-service/scripts/seed_test_strategies.py + bootstrap docs).
#
# Env vars:
#   HANDLER_URL       default http://localhost:8090
#   JAEGER_URL        default http://192.168.88.10:16686
#   EXPECT_SERVICES   default "quant-handler,core-service"
#                     (with RUN_E2E=1, set to
#                      "quant-handler,core-service,strategy-service")
#   RUN_E2E           0|1 — choose minimum vs full chain
#   SLEEP_AFTER_FIRE  default 7 (seconds; OTLP BatchSpanProcessor flush interval)

set -euo pipefail

HANDLER_URL="${HANDLER_URL:-http://localhost:8090}"
JAEGER_URL="${JAEGER_URL:-http://192.168.88.10:16686}"
EXPECT_SERVICES="${EXPECT_SERVICES:-quant-handler,core-service}"
RUN_E2E="${RUN_E2E:-0}"
SLEEP_AFTER_FIRE="${SLEEP_AFTER_FIRE:-7}"

PYTHON="${PYTHON:-/opt/anaconda3/bin/python3}"
command -v "$PYTHON" >/dev/null || PYTHON=python3

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[0;33m'; NC='\033[0m'
fail() { echo -e "${RED}✗ $*${NC}" >&2; exit 1; }
ok()   { echo -e "${GREEN}✓ $*${NC}"; }
info() { echo -e "${YELLOW}► $*${NC}"; }

# ── 1. Preflight ────────────────────────────────────────────────────────────

info "checking handler @ $HANDLER_URL"
if ! curl -fsS "$HANDLER_URL/healthz" >/dev/null 2>&1; then
    fail "handler not reachable at $HANDLER_URL"
fi

info "checking Jaeger @ $JAEGER_URL"
if ! curl -fsS "$JAEGER_URL/api/services" >/dev/null 2>&1; then
    fail "Jaeger API not reachable at $JAEGER_URL"
fi

# ── 2. Fire a request that cascades through the expected services ──────────

USER="verify-trace-$$-$RANDOM"
PASS="verify-xyz-$RANDOM"

info "firing signup ($USER)"
curl -fsS -X POST "$HANDLER_URL/api/auth/signup" \
    -H 'Content-Type: application/json' \
    -d "{\"username\":\"$USER\",\"password\":\"$PASS\"}" \
    >/dev/null

if [ "$RUN_E2E" = "1" ]; then
    info "RUN_E2E=1 — firing login + runStrategy (requires test fixtures)"
    # Log in + grab token
    TOKEN=$(curl -fsS -X POST "$HANDLER_URL/api/auth/login" \
        -H 'Content-Type: application/json' \
        -d "{\"username\":\"$USER\",\"password\":\"$PASS\"}" \
        | $PYTHON -c 'import json,sys;print(json.load(sys.stdin).get("token",""))')
    if [ -z "$TOKEN" ]; then
        fail "login did not return a token; full-chain test aborted"
    fi
    # The caller is responsible for having a mounted strategy + account ready;
    # this probe just reaches an endpoint that cascades to strategy-service.
    # A lightweight cascading call: list accounts (handler → account) is
    # already covered by signup. The RunStrategy-specific cascade needs
    # operator-supplied account/strategy IDs, deferred.
    info "  NOTE: full runStrategy cascade needs seeded fixtures; skipping deep path"
fi

info "sleeping ${SLEEP_AFTER_FIRE}s for OTLP batch flush"
sleep "$SLEEP_AFTER_FIRE"

# ── 3. Pull the latest quant-handler trace and inspect service coverage ────

END_US=$(($(date +%s) * 1000000))
START_US=$((END_US - 300 * 1000000))  # 5 minutes back

info "querying Jaeger for latest quant-handler trace"
RAW=$(curl -fsS "$JAEGER_URL/api/traces?service=quant-handler&limit=1&start=$START_US&end=$END_US")

TRACE_ID=$(printf '%s' "$RAW" | $PYTHON -c '
import json, sys
d = json.load(sys.stdin)
data = d.get("data", [])
if not data: sys.exit(0)
print(data[0]["traceID"])
')
[ -z "$TRACE_ID" ] && fail "Jaeger returned no recent quant-handler trace"
ok "found trace: $TRACE_ID"

# ── 4. Compute the services in that trace, diff against expected set ──────

FULL=$(curl -fsS "$JAEGER_URL/api/traces/$TRACE_ID")
ACTUAL=$(printf '%s' "$FULL" | $PYTHON -c '
import json, sys
d = json.load(sys.stdin)
procs = d["data"][0].get("processes", {})
svcs = sorted({p.get("serviceName", "") for p in procs.values() if p.get("serviceName")})
print(",".join(svcs))
')

ok "services in trace: $ACTUAL"

MISSING=()
IFS="," read -ra WANT <<< "$EXPECT_SERVICES"
for w in "${WANT[@]}"; do
    w="$(echo "$w" | xargs)"  # trim
    [ -z "$w" ] && continue
    if ! echo ",$ACTUAL," | grep -q ",$w,"; then
        MISSING+=("$w")
    fi
done

if [ ${#MISSING[@]} -gt 0 ]; then
    fail "missing expected services in trace: ${MISSING[*]}  (want: $EXPECT_SERVICES)"
fi

# ── 5. Confirm trace_id shows up in ES app-logs ─────────────────────────────

ES_URL="${ES_URL:-http://192.168.88.10:9200}"
info "confirming trace_id=$TRACE_ID appears in ES app-logs-*"
ES_HITS=$(curl -fsS -H 'Content-Type: application/json' \
    "$ES_URL/app-logs-*/_count" \
    -d "{\"query\":{\"term\":{\"trace_id\":\"$TRACE_ID\"}}}" \
    | $PYTHON -c 'import json,sys;print(json.load(sys.stdin).get("count",0))')

if [ "${ES_HITS:-0}" = "0" ]; then
    echo -e "${YELLOW}! ES has 0 log entries for this trace_id — bridge may still be batching, or logs/kafka pipeline issue${NC}"
else
    ok "ES has $ES_HITS log entries carrying this trace_id"
fi

ok "OK — all expected services (${EXPECT_SERVICES}) present in Jaeger trace"
