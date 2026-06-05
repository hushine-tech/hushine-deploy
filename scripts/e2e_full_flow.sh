#!/usr/bin/env bash
# ── E2E 全链路测试 ──────────────────────────────────────────────────────────────
# 从创建帐号 → 创建策略 → 挂载激活 → 运行回测 → 验证订单写入
# 用法: bash scripts/e2e_full_flow.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PYTHON="${PYTHON:-/opt/anaconda3/bin/python3}"
DB_HOST="${E2E_DB_HOST:-192.168.88.10}"
ACCOUNT_DB_NAME="${E2E_ACCOUNT_DB:-account}"
ORDER_DB_NAME="${E2E_ORDER_DB:-order}"
TIMESCALE_DB_PATTERN="${E2E_TIMESCALE_DB_PATTERN:-binance_{year}}"

# ── 端口配置（独立端口，避免冲突）──────────────────────────────────────────────
ACCT_HTTP=18080
ACCT_GRPC=18051
CP_HTTP=18082
CP_GRPC=18054
STRAT_GRPC=18053
HANDLER_HTTP=18090
JWT_SECRET="e2e-secret-key-do-not-use-in-prod"
RUN_ID="$(date +%s)-$$"
LOGIN_USER="e2e-user-${RUN_ID}"
LOGIN_PASS="e2e-pass-${RUN_ID}"
API="http://127.0.0.1:${HANDLER_HTTP}"
CP_CONFIG="/tmp/e2e-control-panel-${RUN_ID}.yaml"
RUNTIME_ID=""
TOKEN=""

# ── 颜色 ──────────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[0;33m'; NC='\033[0m'
pass() { echo -e "${GREEN}✓ $1${NC}"; }
fail() { echo -e "${RED}✗ $1${NC}"; FAILURES=$((FAILURES+1)); }
info() { echo -e "${YELLOW}► $1${NC}"; }

FAILURES=0
PIDS=()

cleanup() {
    info "Cleaning up..."
    if [ -n "${RUNTIME_ID:-}" ] && [ -n "${TOKEN:-}" ]; then
        curl -s -X DELETE "${API}/api/runtimes/${RUNTIME_ID}" -H "Authorization: Bearer ${TOKEN}" >/dev/null 2>&1 || true
    fi
    for pid in "${PIDS[@]}"; do
        kill "$pid" 2>/dev/null || true
        wait "$pid" 2>/dev/null || true
    done
    rm -f "${CP_CONFIG}"
    info "Done."
}
trap cleanup EXIT

# ══════════════════════════════════════════════════════════════════════════════
# Step 0: Seed test data
# ══════════════════════════════════════════════════════════════════════════════
info "Step 0: Seeding TESTUSDT test data (200 bars)"
cd "$ROOT/strategy-service"
$PYTHON scripts/seed_test_data.py 2>&1 | tail -3
pass "Test data seeded"

# ══════════════════════════════════════════════════════════════════════════════
# Step 1: Build services
# ══════════════════════════════════════════════════════════════════════════════
info "Step 1: Building services"
cd "$ROOT/core-service" && go build -o "$ROOT/.e2e-build/core-service" ./cmd/core-service 2>&1
cd "$ROOT/control-panel-service" && go build -o "$ROOT/.e2e-build/control-panel-service" ./cmd/control-panel-service 2>&1
cd "$ROOT/gateway/quant-handler" && go build -o "$ROOT/.e2e-build/quant-handler" ./cmd/quant-handler 2>&1
pass "All Go services built"

# ══════════════════════════════════════════════════════════════════════════════
# Step 2: Start services
# ══════════════════════════════════════════════════════════════════════════════
info "Step 2: Starting services"

# core-service
cd "$ROOT/core-service"
TIMESCALEDB_DSN="host=${DB_HOST} port=5432 user=postgres password=postgres dbname=${ACCOUNT_DB_NAME} sslmode=disable" \
ORDER_TIMESCALEDB_DSN="host=${DB_HOST} port=5432 user=postgres password=postgres dbname=${ORDER_DB_NAME} sslmode=disable" \
MOCK_BINANCE=1 \
HTTP_ADDR=":${ACCT_HTTP}" \
GRPC_ADDR=":${ACCT_GRPC}" \
"$ROOT/.e2e-build/core-service" > /tmp/e2e-account.log 2>&1 &
PIDS+=($!)
echo "  core-service  PID=$! → HTTP:${ACCT_HTTP} gRPC:${ACCT_GRPC} (account.v1 + order.v1)"

# control-panel-service
cat > "${CP_CONFIG}" <<EOF
server:
  http_addr: ":${CP_HTTP}"
  grpc_addr: ":${CP_GRPC}"

database:
  host: "${DB_HOST}"
  port: 5432
  user: "postgres"
  password: "postgres"
  dbname: "control_panel"
  sslmode: "disable"

market_data:
  host: "${DB_HOST}"
  port: 5432
  user: "postgres"
  password: "postgres"
  database: "${TIMESCALE_DB_PATTERN}"
  sslmode: "disable"

dependencies:
  account_service_grpc: "127.0.0.1:${ACCT_GRPC}"
  order_service_grpc: "127.0.0.1:${ACCT_GRPC}"

provisioning:
  backend: "docker"
  image: "hushine/strategy-runtime:executor-dev"
  advertise_host: "127.0.0.1"
  port_range_base: 50100
  port_range_size: 200
  registration_timeout_seconds: 30
  docker:
    network_mode: "bridge"
    control_panel_dial_addr: "host.docker.internal:${CP_GRPC}"
    label_prefix: "hushine.runtime"
    runtime_user_grpc_port: 50053

notification:
  enabled: false
  kafka:
    brokers: ["${DB_HOST}:19092"]
    topic: "notification.events"
    client_id: "control-panel-service-e2e"

log:
  output_dir: "./logs"
  local_file:
    enabled: true
  kafka:
    enabled: false
  tracing:
    enabled: false
EOF

cd "$ROOT/control-panel-service"
CORE_SERVICE_GRPC_ADDR="127.0.0.1:${ACCT_GRPC}" \
ACCOUNT_SERVICE_GRPC_ADDR="127.0.0.1:${ACCT_GRPC}" \
ORDER_SERVICE_GRPC_ADDR="127.0.0.1:${ACCT_GRPC}" \
"$ROOT/.e2e-build/control-panel-service" -config "${CP_CONFIG}" > /tmp/e2e-control-panel.log 2>&1 &
PIDS+=($!)
echo "  control-panel    PID=$! → HTTP:${CP_HTTP} gRPC:${CP_GRPC}"

# strategy-service
cd "$ROOT/strategy-service"
PYTHONPATH="$ROOT/strategy-service:$ROOT/strategy-service/strategy-library" \
GRPC_ADDR="0.0.0.0:${STRAT_GRPC}" \
CORE_SERVICE_GRPC_ADDR="127.0.0.1:${ACCT_GRPC}" \
ACCOUNT_SERVICE_GRPC_ADDR="127.0.0.1:${ACCT_GRPC}" \
ORDER_SERVICE_GRPC_ADDR="127.0.0.1:${ACCT_GRPC}" \
TIMESCALE_HOST="${DB_HOST}" \
TIMESCALE_DB="${TIMESCALE_DB_PATTERN}" \
$PYTHON run_grpc_server.py > /tmp/e2e-strategy.log 2>&1 &
PIDS+=($!)
echo "  strategy-service PID=$! → gRPC:${STRAT_GRPC}"

# quant-handler
cd "$ROOT/gateway/quant-handler"
CORE_SERVICE_GRPC_ADDR="127.0.0.1:${ACCT_GRPC}" \
ACCOUNT_SERVICE_GRPC_ADDR="127.0.0.1:${ACCT_GRPC}" \
CONTROL_PANEL_SERVICE_GRPC_ADDR="127.0.0.1:${CP_GRPC}" \
QUANT_HANDLER_JWT_SECRET="${JWT_SECRET}" \
HTTP_ADDR=":${HANDLER_HTTP}" \
HANDLER_CORS_ORIGINS="http://localhost:5173" \
"$ROOT/.e2e-build/quant-handler" > /tmp/e2e-handler.log 2>&1 &
PIDS+=($!)
echo "  quant-handler    PID=$! → HTTP:${HANDLER_HTTP}"

# ── Wait for services ────────────────────────────────────────────────────────
info "Waiting for services to be ready..."
# Wait for HTTP healthz first
for i in $(seq 1 30); do
    if curl -s "${API}/healthz" > /dev/null 2>&1 && curl -s "http://127.0.0.1:${CP_HTTP}/readyz" > /dev/null 2>&1; then
        break
    fi
    if [ "$i" -eq 30 ]; then
        fail "Services did not start within 30s"
        echo "--- core-service log ---"; tail -20 /tmp/e2e-account.log 2>/dev/null
        echo "--- control-panel log ---"; tail -20 /tmp/e2e-control-panel.log 2>/dev/null
        echo "--- strategy-service log ---"; tail -20 /tmp/e2e-strategy.log 2>/dev/null
        echo "--- quant-handler log ---";   tail -20 /tmp/e2e-handler.log 2>/dev/null
        exit 1
    fi
    sleep 1
done
# Wait for gRPC backend (core-service) to be reachable through handler
# Probe via quant-handler → core-service gRPC path using signup/login
sleep 1
for i in $(seq 1 15); do
    SIGNUP_RESP=$(curl -s -X POST "${API}/api/auth/signup" \
        -H 'Content-Type: application/json' \
        -d "{\"username\":\"${LOGIN_USER}\",\"password\":\"${LOGIN_PASS}\"}")
    LOGIN_RESP=$(curl -s -X POST "${API}/api/auth/login" \
        -H 'Content-Type: application/json' \
        -d "{\"username\":\"${LOGIN_USER}\",\"password\":\"${LOGIN_PASS}\"}")
    TEMP_TOKEN=$(echo "$LOGIN_RESP" | jq -r '.token // empty')
    PROBE=$(curl -s "${API}/api/accounts" -H "Authorization: Bearer ${TEMP_TOKEN}" 2>/dev/null)
    if echo "$PROBE" | jq -e 'type == "array"' > /dev/null 2>&1; then
        pass "All services ready (gRPC verified)"
        break
    fi
    if [ "$i" -eq 15 ]; then
        fail "core-service gRPC not ready within 15s: $PROBE"
        exit 1
    fi
    sleep 1
done

# ══════════════════════════════════════════════════════════════════════════════
# Step 3: Login
# ══════════════════════════════════════════════════════════════════════════════
info "Step 3: Login"
LOGIN_RESP=$(curl -s -X POST "${API}/api/auth/login" \
    -H 'Content-Type: application/json' \
    -d "{\"username\":\"${LOGIN_USER}\",\"password\":\"${LOGIN_PASS}\"}")
TOKEN=$(echo "$LOGIN_RESP" | jq -r '.token')
USER_ID=$(echo "$LOGIN_RESP" | jq -r '.user.id')
if [ -z "$TOKEN" ] || [ "$TOKEN" = "null" ]; then
    fail "Login failed: $LOGIN_RESP"
    exit 1
fi
if [ -z "$USER_ID" ] || [ "$USER_ID" = "null" ]; then
    fail "Login did not return user id: $LOGIN_RESP"
    exit 1
fi
AUTH="Authorization: Bearer ${TOKEN}"
pass "Login OK (user_id=${USER_ID}, token=${TOKEN:0:20}...)"

# ══════════════════════════════════════════════════════════════════════════════
# Step 4: Create account + backtest venue wallet
# ══════════════════════════════════════════════════════════════════════════════
info "Step 4: Create account context + backtest venue wallet (TESTUSDT isolated futures, 10000 USDT)"
ACCOUNT_RESP=$(curl -s -X POST "${API}/api/accounts" \
    -H "$AUTH" -H 'Content-Type: application/json' \
    -d '{
  "name": "e2e-full-flow",
  "description": "E2E portfolio context",
  "environment": 0
}')
ACCOUNT_ID=$(echo "$ACCOUNT_RESP" | jq -r '.account_id')
if [ -z "$ACCOUNT_ID" ] || [ "$ACCOUNT_ID" = "null" ]; then
    fail "Create account failed: $ACCOUNT_RESP"
    exit 1
fi
pass "Account created: ID=${ACCOUNT_ID}"

VENUE_BODY=$(cat <<EOF
{
  "account_id": ${ACCOUNT_ID},
  "exchange": "binance",
  "market": "perpetual_futures",
  "environment": "backtest",
  "status": "active",
  "display_name": "e2e-backtest-binance-usdm",
  "margin_mode": "isolated",
  "position_mode": "one_way",
  "futures": {
    "margin_mode": "isolated",
    "position_mode": "one_way",
    "initial_balance": 10000,
    "positions": [
      {"symbol": "TESTUSDT", "direction": 0, "initial_balance": 10000, "leverage": 20, "fee_rate": 0.0004}
    ]
  }
}
EOF
)
VENUE_RESP=$(curl -s -X POST "${API}/api/venues" \
    -H "$AUTH" -H 'Content-Type: application/json' \
    -d "${VENUE_BODY}")
VENUE_ID=$(echo "$VENUE_RESP" | jq -r '.venue_id')
if [ -z "$VENUE_ID" ] || [ "$VENUE_ID" = "null" ]; then
    fail "Create venue failed: $VENUE_RESP"
    exit 1
fi
pass "Backtest venue created: ID=${VENUE_ID}"

# ══════════════════════════════════════════════════════════════════════════════
# Step 5: Create strategy
# ══════════════════════════════════════════════════════════════════════════════
info "Step 5: Create strategy (test_full_flow)"
STRATEGY_CODE=$(cat "$ROOT/strategy-service/tests/strategies/test_full_flow.py")
# Escape for JSON
STRATEGY_CODE_JSON=$(echo "$STRATEGY_CODE" | $PYTHON -c 'import sys,json; print(json.dumps(sys.stdin.read()))')
E2E_TS=$(date +%s)

STRATEGY_RESP=$(curl -s -X POST "${API}/api/strategies" \
    -H "$AUTH" -H 'Content-Type: application/json' \
    -d "{
  \"name\": \"e2e-full-flow-${E2E_TS}\",
  \"version\": \"1.0.0\",
  \"description\": \"E2E test: buy<120 sell>180\",
  \"code\": ${STRATEGY_CODE_JSON}
}")
STRATEGY_ID=$(echo "$STRATEGY_RESP" | jq -r '.strategy_id')
if [ -z "$STRATEGY_ID" ] || [ "$STRATEGY_ID" = "null" ]; then
    fail "Create strategy failed: $STRATEGY_RESP"
    exit 1
fi
pass "Strategy created: ID=${STRATEGY_ID}"

# ══════════════════════════════════════════════════════════════════════════════
# Step 6: Mount + Activate
# ══════════════════════════════════════════════════════════════════════════════
info "Step 6: Mount + Activate strategy on account"
MOUNT_RESP=$(curl -s -X POST "${API}/api/accounts/${ACCOUNT_ID}/strategies/${STRATEGY_ID}" -H "$AUTH")
echo "  Mount: $MOUNT_RESP"

ACTIVATE_RESP=$(curl -s -X POST "${API}/api/accounts/${ACCOUNT_ID}/strategies/${STRATEGY_ID}/activate" -H "$AUTH")
echo "  Activate: $ACTIVATE_RESP"

# Verify active
ACCT_STRATS=$(curl -s "${API}/api/accounts/${ACCOUNT_ID}/strategies" -H "$AUTH")
ACTIVE_COUNT=$(echo "$ACCT_STRATS" | jq '[.[] | select(.active==true)] | length')
if [ "$ACTIVE_COUNT" -eq 1 ]; then
    pass "Strategy mounted and activated"
else
    fail "Expected 1 active strategy, got ${ACTIVE_COUNT}"
fi

# ══════════════════════════════════════════════════════════════════════════════
# Step 7: Ensure hosted runtime + run backtest
# ══════════════════════════════════════════════════════════════════════════════
info "Step 7: Ensure hosted runtime"
bash "$ROOT/strategy-service/scripts/build_strategy_runtime.sh" dev >/tmp/e2e-runtime-image.log 2>&1
cd "$ROOT/control-panel-service"
RUNTIME_RESP=$(go run scripts/smoke_ensure_runtime.go \
    -addr "127.0.0.1:${CP_GRPC}" \
    -user "${USER_ID}" \
    -profile small \
    -validate true 2>&1)
echo "$RUNTIME_RESP"
RUNTIME_ID=$(echo "$RUNTIME_RESP" | awk -F'= ' '/runtime_id/{gsub(/[[:space:]]/, "", $2); print $2; exit}')
if [ -z "$RUNTIME_ID" ]; then
    fail "EnsureHostedRuntime did not return runtime_id"
    echo "--- control-panel log ---"
    tail -40 /tmp/e2e-control-panel.log
    echo "--- runtime image log ---"
    tail -40 /tmp/e2e-runtime-image.log
    exit 1
fi
pass "Hosted runtime active: ${RUNTIME_ID}"

info "Step 8: Run backtest (200 bars, 1m interval, TESTUSDT)"
# start_time_ms = 2025-01-01T00:00:00Z = 1735689600000
# end_time_ms   = 2025-01-01T03:20:00Z = 1735701600000
RUN_RESP=$(curl -s -X POST "${API}/api/accounts/${ACCOUNT_ID}/run-strategy" \
    -H "$AUTH" -H 'Content-Type: application/json' \
    -d "{
  \"strategy_path\": \"\",
  \"interval\": \"1m\",
  \"start_time_ms\": 1735689600000,
  \"end_time_ms\": 1735701600000,
  \"runtime_id\": \"${RUNTIME_ID}\"
}")
SESSION_ID=$(echo "$RUN_RESP" | jq -r '.session_id')
if [ -z "$SESSION_ID" ] || [ "$SESSION_ID" = "null" ]; then
    fail "Run backtest failed: $RUN_RESP"
    echo "--- strategy-service log ---"
    tail -30 /tmp/e2e-strategy.log
    exit 1
fi
pass "Backtest started: session=${SESSION_ID}"

# ══════════════════════════════════════════════════════════════════════════════
# Step 9: Poll status
# ══════════════════════════════════════════════════════════════════════════════
info "Step 9: Polling backtest status..."
for i in $(seq 1 30); do
    STATUS_RESP=$(curl -s "${API}/api/strategy-sessions/${SESSION_ID}" -H "$AUTH" 2>/dev/null || echo '{"status":"error"}')
    STATUS=$(echo "$STATUS_RESP" | jq -r '.status')
    BARS=$(echo "$STATUS_RESP" | jq -r '.bars_processed')

    if [ "$STATUS" = "completed" ] || [ "$STATUS" = "finished" ]; then
        pass "Backtest completed: bars_processed=${BARS}"
        break
    elif [ "$STATUS" = "failed" ]; then
        ERROR=$(echo "$STATUS_RESP" | jq -r '.error')
        fail "Backtest failed: ${ERROR}"
        echo "--- strategy-service log (last 40 lines) ---"
        tail -40 /tmp/e2e-strategy.log
        exit 1
    fi
    echo "  [${i}] status=${STATUS} bars=${BARS}"
    sleep 2
done

if [ "$STATUS" != "completed" ] && [ "$STATUS" != "finished" ]; then
    fail "Backtest did not complete within 60s"
    exit 1
fi

# ══════════════════════════════════════════════════════════════════════════════
# Step 10: Verify results
# ══════════════════════════════════════════════════════════════════════════════
info "Step 10: Verifying results"

# 9a. bars_processed == 200
if [ "$BARS" = "200" ]; then
    pass "bars_processed = 200"
else
    fail "Expected 200 bars, got ${BARS}"
fi

# 9b. order_fills in DB
info "  Querying order_fills..."
ORDER_RESULT=$($PYTHON -c "
import psycopg2, json
conn = psycopg2.connect('host=${DB_HOST} port=5432 dbname=${ORDER_DB_NAME} user=postgres password=postgres sslmode=disable')
cur = conn.cursor()
cur.execute('''
    SELECT order_id, account_id, user_id, symbol, side, qty, fill_price, status, strategy_id, market, session_id
    FROM order_fills
    WHERE user_id = %s AND account_id = %s
    ORDER BY time
''', (${USER_ID}, ${ACCOUNT_ID}))
rows = cur.fetchall()
print(json.dumps([{
    'order_id': r[0], 'account_id': r[1], 'user_id': r[2], 'symbol': r[3], 'side': r[4], 'qty': float(r[5]),
    'fill_price': float(r[6]), 'status': r[7],
    'strategy_id': r[8], 'market': r[9], 'session_id': r[10]
} for r in rows]))
cur.close()
conn.close()
")

ORDER_COUNT=$(echo "$ORDER_RESULT" | jq 'length')
echo "  order_fills count: ${ORDER_COUNT}"
echo "$ORDER_RESULT" | jq -r '.[] | "    user=\(.user_id) acct=\(.account_id) session=\(.session_id) \(.side) \(.qty) \(.symbol) @ \(.fill_price) | strategy_id=\(.strategy_id) market=\(.market)"'

if [ "$ORDER_COUNT" -ge 2 ]; then
    pass "order_fills: ${ORDER_COUNT} trades recorded"
else
    fail "Expected at least 2 trades, got ${ORDER_COUNT}"
fi

# Check strategy_id is set
STRAT_ID_SET=$(echo "$ORDER_RESULT" | jq "[.[] | select(.strategy_id == ${STRATEGY_ID})] | length")
if [ "$STRAT_ID_SET" = "$ORDER_COUNT" ]; then
    pass "All order_fills have correct strategy_id=${STRATEGY_ID}"
else
    fail "Not all order_fills have strategy_id=${STRATEGY_ID} (${STRAT_ID_SET}/${ORDER_COUNT})"
fi

# Check market is set
MARKET_SET=$(echo "$ORDER_RESULT" | jq '[.[] | select(.market == "futures")] | length')
if [ "$MARKET_SET" = "$ORDER_COUNT" ]; then
    pass "All order_fills have market='futures'"
else
    fail "Not all order_fills have market='futures' (${MARKET_SET}/${ORDER_COUNT})"
fi

# Check account_id is preserved
ACCOUNT_ID_SET=$(echo "$ORDER_RESULT" | jq "[.[] | select(.account_id == ${ACCOUNT_ID})] | length")
if [ "$ACCOUNT_ID_SET" = "$ORDER_COUNT" ]; then
    pass "All order_fills have correct account_id=${ACCOUNT_ID}"
else
    fail "Not all order_fills have account_id=${ACCOUNT_ID} (${ACCOUNT_ID_SET}/${ORDER_COUNT})"
fi

# Check user_id is preserved
USER_ID_SET=$(echo "$ORDER_RESULT" | jq "[.[] | select(.user_id == ${USER_ID})] | length")
if [ "$USER_ID_SET" = "$ORDER_COUNT" ]; then
    pass "All order_fills have correct user_id=${USER_ID}"
else
    fail "Not all order_fills have user_id=${USER_ID} (${USER_ID_SET}/${ORDER_COUNT})"
fi

# Check session_id is set
SESSION_ID_SET=$(echo "$ORDER_RESULT" | jq "[.[] | select(.session_id == \"${SESSION_ID}\")] | length")
if [ "$SESSION_ID_SET" = "$ORDER_COUNT" ]; then
    pass "All order_fills have correct session_id=${SESSION_ID}"
else
    fail "Not all order_fills have session_id=${SESSION_ID} (${SESSION_ID_SET}/${ORDER_COUNT})"
fi

# 9c. account_snapshots with strategy_id
info "  Querying account_snapshots..."
SNAPSHOT_RESULT=$($PYTHON -c "
import psycopg2
conn = psycopg2.connect('host=${DB_HOST} port=5432 dbname=${ACCOUNT_DB_NAME} user=postgres password=postgres sslmode=disable')
cur = conn.cursor()
cur.execute('''
    SELECT COUNT(*) FROM account_snapshots
    WHERE account_id = %s AND strategy_id = %s AND session_id = %s
''', (${ACCOUNT_ID}, ${STRATEGY_ID}, '${SESSION_ID}'))
print(cur.fetchone()[0])
cur.close()
conn.close()
")

if [ "$SNAPSHOT_RESULT" -ge 1 ]; then
    pass "account_snapshots: ${SNAPSHOT_RESULT} snapshots with strategy_id=${STRATEGY_ID} session_id=${SESSION_ID}"
else
    fail "No account_snapshots with strategy_id=${STRATEGY_ID} session_id=${SESSION_ID}"
fi

# 9d. strategy_sessions row carries account_id + strategy_id + completed status
info "  Querying strategy_sessions..."
SESSION_ROW=$($PYTHON -c "
import psycopg2, json
conn = psycopg2.connect('host=${DB_HOST} port=5432 dbname=${ACCOUNT_DB_NAME} user=postgres password=postgres sslmode=disable')
cur = conn.cursor()
cur.execute('''
    SELECT account_id, strategy_id, status, bars_processed
    FROM strategy_sessions
    WHERE session_id = %s
''', ('${SESSION_ID}',))
row = cur.fetchone()
print(json.dumps({
    'account_id': row[0],
    'strategy_id': row[1],
    'status': row[2],
    'bars_processed': row[3],
}) if row else 'null')
cur.close()
conn.close()
")

if [ "$SESSION_ROW" = "null" ]; then
    fail "strategy_sessions row missing for session_id=${SESSION_ID}"
else
    SESSION_ACCOUNT_ID=$(echo "$SESSION_ROW" | jq -r '.account_id')
    SESSION_STRATEGY_ID=$(echo "$SESSION_ROW" | jq -r '.strategy_id')
    SESSION_STATUS=$(echo "$SESSION_ROW" | jq -r '.status')
    SESSION_BARS=$(echo "$SESSION_ROW" | jq -r '.bars_processed')

    [ "$SESSION_ACCOUNT_ID" = "$ACCOUNT_ID" ] && pass "strategy_sessions account_id matches ${ACCOUNT_ID}" || fail "strategy_sessions account_id=${SESSION_ACCOUNT_ID}, expected ${ACCOUNT_ID}"
    [ "$SESSION_STRATEGY_ID" = "$STRATEGY_ID" ] && pass "strategy_sessions strategy_id matches ${STRATEGY_ID}" || fail "strategy_sessions strategy_id=${SESSION_STRATEGY_ID}, expected ${STRATEGY_ID}"
    if [ "$SESSION_STATUS" = "completed" ] || [ "$SESSION_STATUS" = "finished" ]; then
        pass "strategy_sessions status=${SESSION_STATUS}"
    else
        fail "strategy_sessions status=${SESSION_STATUS}, expected completed/finished"
    fi
    [ "$SESSION_BARS" = "$BARS" ] && pass "strategy_sessions bars_processed=${BARS}" || fail "strategy_sessions bars_processed=${SESSION_BARS}, expected ${BARS}"
fi

# ══════════════════════════════════════════════════════════════════════════════
# Summary
# ══════════════════════════════════════════════════════════════════════════════
echo ""
echo "════════════════════════════════════════════════════════════"
if [ $FAILURES -eq 0 ]; then
    echo -e "${GREEN}  ALL CHECKS PASSED${NC}"
else
    echo -e "${RED}  ${FAILURES} CHECK(S) FAILED${NC}"
fi
echo "════════════════════════════════════════════════════════════"
exit $FAILURES
