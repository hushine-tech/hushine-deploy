#!/usr/bin/env bash
# ── E2E 全链路测试 ──────────────────────────────────────────────────────────────
# 从创建 Portfolio/Venue → 创建策略 → 挂载激活 → 运行回测 → 验证订单写入
# 用法: bash scripts/e2e_full_flow.sh
set -euo pipefail

LOCAL_NO_PROXY="127.0.0.1,localhost,::1"
export NO_PROXY="${LOCAL_NO_PROXY}${NO_PROXY:+,${NO_PROXY}}"
export no_proxy="${LOCAL_NO_PROXY}${no_proxy:+,${no_proxy}}"

SCRIPT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
if [ -d "${SCRIPT_ROOT}/strategy-service" ] && [ -d "${SCRIPT_ROOT}/core-service" ]; then
    ROOT="${SCRIPT_ROOT}"
elif [ -d "${SCRIPT_ROOT}/../strategy-service" ] && [ -d "${SCRIPT_ROOT}/../core-service" ]; then
    ROOT="$(cd "${SCRIPT_ROOT}/.." && pwd)"
else
    ROOT="${SCRIPT_ROOT}"
fi
PYTHON="${PYTHON:-/opt/anaconda3/bin/python3}"
DB_HOST="${E2E_DB_HOST:-127.0.0.1}"
PORTFOLIO_DB_NAME="${E2E_PORTFOLIO_DB:-portfolio}"
ORDER_DB_NAME="${E2E_ORDER_DB:-order}"
TIMESCALE_DB_PATTERN="${E2E_TIMESCALE_DB_PATTERN:-}"
if [ -z "${TIMESCALE_DB_PATTERN}" ]; then
    TIMESCALE_DB_PATTERN='binance_{year}'
fi

# ── 端口配置（独立端口，避免冲突）──────────────────────────────────────────────
CORE_HTTP=18080
CORE_GRPC=18051
CP_HTTP=18082
CP_GRPC=18054
CP_RUNTIME_GRPC=18055
HANDLER_HTTP=18090
JWT_SECRET="e2e-secret-key-do-not-use-in-prod"
RUN_ID="$(date +%s)-$$"
LOGIN_USER="e2e-user-${RUN_ID}"
LOGIN_PASS="e2e-pass-${RUN_ID}"
API="http://127.0.0.1:${HANDLER_HTTP}"
CP_CONFIG="/tmp/e2e-control-panel-${RUN_ID}.yaml"
CERT_DIR="/tmp/e2e-runtime-certs-${RUN_ID}"
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
    rm -rf "${CERT_DIR}"
    info "Done."
}
trap cleanup EXIT

# ══════════════════════════════════════════════════════════════════════════════
# Step 0: Seed test data
# ══════════════════════════════════════════════════════════════════════════════
info "Step 0: Seeding TESTUSDT test data (200 bars)"
cd "$ROOT/scraper"
PGHOST="${DB_HOST}" \
PGPORT=5432 \
PGUSER=postgres \
PGPASSWORD=postgres \
PGDATABASE_ADMIN=postgres \
SCRAPER_DBS=binance_2025 \
go run ./cmd/ensure-scraper-db >/tmp/e2e-ensure-scraper.log 2>&1
cd "$ROOT/strategy-service"
TIMESCALE_HOST="${DB_HOST}" \
TIMESCALE_PORT=5432 \
TIMESCALE_DB=binance_2025 \
TIMESCALE_USER=postgres \
TIMESCALE_PASSWORD=postgres \
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
mkdir -p "${CERT_DIR}"
openssl req -x509 -newkey rsa:2048 -nodes -days 1 \
  -subj "/CN=runtime-channel.local" \
  -addext "subjectAltName=DNS:runtime-channel.local,DNS:host.docker.internal,IP:127.0.0.1" \
  -keyout "${CERT_DIR}/runtime-channel-server.key" \
  -out "${CERT_DIR}/runtime-channel-server.pem" >/tmp/e2e-runtime-certs.log 2>&1
openssl req -x509 -newkey rsa:2048 -nodes -days 1 \
  -subj "/CN=hushine-runtime-client-ca-e2e" \
  -keyout "${CERT_DIR}/runtime-client-ca.key" \
  -out "${CERT_DIR}/runtime-client-ca.pem" >>/tmp/e2e-runtime-certs.log 2>&1
chmod 600 "${CERT_DIR}"/*.key

# core-service. Keep tracked deployment logging/notification endpoints out of
# this isolated harness; an empty YAML retains safe defaults and env overrides.
cd "$ROOT/core-service"
DATABASE_HOST="${DB_HOST}" DATABASE_PORT=5432 DATABASE_USER=postgres DATABASE_PASSWORD=postgres \
DATABASE_DBNAME="${PORTFOLIO_DB_NAME}" DATABASE_SSLMODE=disable \
ORDER_DATABASE_HOST="${DB_HOST}" ORDER_DATABASE_PORT=5432 ORDER_DATABASE_USER=postgres ORDER_DATABASE_PASSWORD=postgres \
ORDER_DATABASE_DBNAME="${ORDER_DB_NAME}" ORDER_DATABASE_SSLMODE=disable \
EXCHANGE_MOCK_BINANCE=true \
SERVER_HTTP_ADDR=":${CORE_HTTP}" \
SERVER_GRPC_ADDR=":${CORE_GRPC}" \
"$ROOT/.e2e-build/core-service" -config /dev/null > /tmp/e2e-core.log 2>&1 &
PIDS+=($!)
echo "  core-service  PID=$! → HTTP:${CORE_HTTP} gRPC:${CORE_GRPC} (portfolio.v1 + order.v1)"

# control-panel-service
cat > "${CP_CONFIG}" <<EOF
server:
  http_addr: ":${CP_HTTP}"
  grpc_addr: ":${CP_GRPC}"

runtime_channel_server:
  grpc_addr: ":${CP_RUNTIME_GRPC}"
  tls:
    enabled: true
    cert_file: "${CERT_DIR}/runtime-channel-server.pem"
    key_file: "${CERT_DIR}/runtime-channel-server.key"
    server_name: "runtime-channel.local"
    client_ca_file: "${CERT_DIR}/runtime-client-ca.pem"
    client_ca_key_file: "${CERT_DIR}/runtime-client-ca.key"

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
  portfolio_service_grpc: "127.0.0.1:${CORE_GRPC}"
  order_service_grpc: "127.0.0.1:${CORE_GRPC}"

provisioning:
  backend: "docker"
  image: "hushine/strategy-runtime:executor-dev"
  registration_timeout_seconds: 30
  docker:
    network_mode: "bridge"
    runtime_channel_dial_addr: "host.docker.internal:${CP_RUNTIME_GRPC}"
    label_prefix: "hushine.runtime"

notification:
  enabled: false
  kafka:
    brokers: ["${DB_HOST}:9092"]
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
DEPENDENCIES_CORE_SERVICE_GRPC="127.0.0.1:${CORE_GRPC}" \
DEPENDENCIES_ORDER_SERVICE_GRPC="127.0.0.1:${CORE_GRPC}" \
MARKET_DATA_DB_HOST="${DB_HOST}" \
MARKET_DATA_DB_PORT=5432 \
MARKET_DATA_DB_USER=postgres \
MARKET_DATA_DB_PASSWORD=postgres \
MARKET_DATA_DB_DATABASE="${TIMESCALE_DB_PATTERN}" \
MARKET_DATA_DB_SSLMODE=disable \
"$ROOT/.e2e-build/control-panel-service" -config "${CP_CONFIG}" > /tmp/e2e-control-panel.log 2>&1 &
PIDS+=($!)
echo "  control-panel    PID=$! → HTTP:${CP_HTTP} gRPC:${CP_GRPC} RuntimeChannel:${CP_RUNTIME_GRPC}"

# quant-handler uses the same isolated default-config pattern.
cd "$ROOT/gateway/quant-handler"
DEPENDENCIES_CORE_SERVICE_GRPC="127.0.0.1:${CORE_GRPC}" \
DEPENDENCIES_ORDER_SERVICE_GRPC="127.0.0.1:${CORE_GRPC}" \
DEPENDENCIES_CONTROL_PANEL_SERVICE_GRPC="127.0.0.1:${CP_GRPC}" \
AUTH_JWT_SECRET="${JWT_SECRET}" \
SERVER_HTTP_ADDR=":${HANDLER_HTTP}" \
AUTH_CORS_ORIGINS="http://localhost:5173" \
"$ROOT/.e2e-build/quant-handler" -config /dev/null > /tmp/e2e-handler.log 2>&1 &
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
        echo "--- core-service log ---"; tail -20 /tmp/e2e-core.log 2>/dev/null
        echo "--- control-panel log ---"; tail -20 /tmp/e2e-control-panel.log 2>/dev/null
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
    TEMP_TOKEN=$(echo "$LOGIN_RESP" | jq -r '.token // empty' 2>/dev/null || true)
    PROBE=$(curl -s "${API}/api/portfolios" -H "Authorization: Bearer ${TEMP_TOKEN}" 2>/dev/null)
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
USER_ID=$(echo "$LOGIN_RESP" | jq -r '.user.user_id // .user.id')
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
# Step 4: Create Portfolio + backtest Venue
# ══════════════════════════════════════════════════════════════════════════════
info "Step 4: Create Portfolio context + backtest Venue"
PORTFOLIO_RESP=$(curl -s -X POST "${API}/api/portfolios" \
    -H "$AUTH" -H 'Content-Type: application/json' \
    -d '{"name":"e2e-full-flow","description":"E2E portfolio context","environment":0}')
PORTFOLIO_ID=$(echo "$PORTFOLIO_RESP" | jq -r '.portfolio_id')
if [ -z "$PORTFOLIO_ID" ] || [ "$PORTFOLIO_ID" = "null" ]; then
    fail "Create Portfolio failed: $PORTFOLIO_RESP"
    exit 1
fi
pass "Portfolio created: ID=${PORTFOLIO_ID}"

VENUE_RESP=$(curl -s -X POST "${API}/api/venues" \
    -H "$AUTH" -H 'Content-Type: application/json' \
    -d "{
  \"portfolio_id\": ${PORTFOLIO_ID},
  \"exchange\": \"binance\",
  \"market\": \"perpetual_futures\",
  \"environment\": \"backtest\",
  \"status\": \"active\",
  \"display_name\": \"e2e-binance-futures\",
  \"margin_mode\": \"cross\",
  \"position_mode\": \"one_way\",
  \"futures\": {
    \"margin_mode\": \"cross\",
    \"position_mode\": \"one_way\",
    \"initial_balance\": 10000,
    \"positions\": [{
      \"symbol\": \"TESTUSDT\",
      \"position_side\": \"BOTH\",
      \"initial_balance\": 10000,
      \"fee_rate\": 0.0004
    }, {
      \"symbol\": \"ALTUSDT\",
      \"position_side\": \"BOTH\",
      \"initial_balance\": 10000,
      \"fee_rate\": 0.0004
    }]
  }
}")
VENUE_ID=$(echo "$VENUE_RESP" | jq -r '.venue_id')
if [ -z "$VENUE_ID" ] || [ "$VENUE_ID" = "null" ]; then
    fail "Create backtest Venue failed: $VENUE_RESP"
    exit 1
fi
pass "Backtest Venue created and bound: ID=${VENUE_ID}"

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
info "Step 6: Mount + Activate strategy on Portfolio"
MOUNT_RESP=$(curl -s -X POST "${API}/api/portfolios/${PORTFOLIO_ID}/strategies/${STRATEGY_ID}" -H "$AUTH")
echo "  Mount: $MOUNT_RESP"

ACTIVATE_RESP=$(curl -s -X POST "${API}/api/portfolios/${PORTFOLIO_ID}/strategies/${STRATEGY_ID}/activate" -H "$AUTH")
echo "  Activate: $ACTIVATE_RESP"

# Verify active
PORTFOLIO_STRATEGIES=$(curl -s "${API}/api/portfolios/${PORTFOLIO_ID}/strategies" -H "$AUTH")
ACTIVE_COUNT=$(echo "$PORTFOLIO_STRATEGIES" | jq '[.[] | select(.active==true)] | length')
if [ "$ACTIVE_COUNT" -eq 1 ]; then
    pass "Strategy mounted and activated"
else
    fail "Expected 1 active strategy, got ${ACTIVE_COUNT}"
fi

# ══════════════════════════════════════════════════════════════════════════════
# Step 7: Ensure hosted runtime + run backtest
# ══════════════════════════════════════════════════════════════════════════════
info "Step 7: Ensure hosted runtime"
bash "$ROOT/strategy-service/scripts/build_strategy_runtime.sh" --allow-dirty dev \
    >/tmp/e2e-runtime-image.log 2>&1
cd "$ROOT/control-panel-service"
set +e
RUNTIME_RESP=$(go run scripts/smoke_ensure_runtime.go \
    -addr "127.0.0.1:${CP_GRPC}" \
    -user "${USER_ID}" \
    -profile small 2>&1)
RUNTIME_RC=$?
set -e
echo "$RUNTIME_RESP"
if [ "$RUNTIME_RC" -ne 0 ]; then
    fail "EnsureHostedRuntime command failed: exit=${RUNTIME_RC}"
    echo "--- control-panel log ---"
    tail -60 /tmp/e2e-control-panel.log
    echo "--- runtime image log ---"
    tail -60 /tmp/e2e-runtime-image.log
    exit 1
fi
RUNTIME_ID=$(echo "$RUNTIME_RESP" | sed -n 's/.*runtime_id=\([^[:space:]]*\).*/\1/p' | head -1)
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
RUN_RESP=$(curl -s -X POST "${API}/api/portfolios/${PORTFOLIO_ID}/run-strategy" \
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
    echo "--- control-panel log ---"
    tail -40 /tmp/e2e-control-panel.log
    echo "--- quant-handler log ---"
    tail -40 /tmp/e2e-handler.log
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

    if [ "$STATUS" = "finished" ]; then
        pass "Backtest completed: bars_processed=${BARS}"
        break
    elif [ "$STATUS" = "failed" ]; then
        ERROR=$(echo "$STATUS_RESP" | jq -r '.error')
        fail "Backtest failed: ${ERROR}"
        echo "--- control-panel log (last 40 lines) ---"
        tail -40 /tmp/e2e-control-panel.log
        exit 1
    fi
    echo "  [${i}] status=${STATUS} bars=${BARS}"
    sleep 2
done

if [ "$STATUS" != "finished" ]; then
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
    SELECT f.order_id, i.portfolio_id, i.user_id, i.symbol, i.side, f.qty, f.fill_price,
           f.status, COALESCE(i.strategy_id, 0), i.market, COALESCE(i.session_id, '')
    FROM order_fills f
    JOIN order_intents i ON i.intent_id = f.intent_id
    WHERE i.user_id = %s AND i.portfolio_id = %s
    ORDER BY f.time
''', (${USER_ID}, ${PORTFOLIO_ID}))
rows = cur.fetchall()
side_labels = {1: 'BUY', 2: 'SELL'}
market_labels = {1: 'spot', 2: 'perpetual_futures', 3: 'delivery_futures'}
print(json.dumps([{
    'order_id': r[0], 'portfolio_id': r[1], 'user_id': r[2], 'symbol': r[3], 'side': side_labels.get(r[4], str(r[4])), 'qty': float(r[5]),
    'fill_price': float(r[6]), 'status': r[7],
    'strategy_id': r[8], 'market': market_labels.get(r[9], str(r[9])), 'session_id': r[10]
} for r in rows]))
cur.close()
conn.close()
")

ORDER_COUNT=$(echo "$ORDER_RESULT" | jq 'length')
echo "  order_fills count: ${ORDER_COUNT}"
echo "$ORDER_RESULT" | jq -r '.[] | "    user=\(.user_id) portfolio=\(.portfolio_id) session=\(.session_id) \(.side) \(.qty) \(.symbol) @ \(.fill_price) | strategy_id=\(.strategy_id) market=\(.market)"'

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
MARKET_SET=$(echo "$ORDER_RESULT" | jq '[.[] | select(.market == "perpetual_futures")] | length')
if [ "$MARKET_SET" = "$ORDER_COUNT" ]; then
    pass "All order_fills have market='perpetual_futures'"
else
    fail "Not all order_fills have market='perpetual_futures' (${MARKET_SET}/${ORDER_COUNT})"
fi

# Check portfolio_id is preserved
PORTFOLIO_ID_SET=$(echo "$ORDER_RESULT" | jq "[.[] | select(.portfolio_id == ${PORTFOLIO_ID})] | length")
if [ "$PORTFOLIO_ID_SET" = "$ORDER_COUNT" ]; then
    pass "All order_fills have correct portfolio_id=${PORTFOLIO_ID}"
else
    fail "Not all order_fills have portfolio_id=${PORTFOLIO_ID} (${PORTFOLIO_ID_SET}/${ORDER_COUNT})"
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

# 9c. portfolio_snapshots with strategy_id
info "  Querying portfolio_snapshots..."
SNAPSHOT_RESULT=$($PYTHON -c "
import psycopg2
conn = psycopg2.connect('host=${DB_HOST} port=5432 dbname=${PORTFOLIO_DB_NAME} user=postgres password=postgres sslmode=disable')
cur = conn.cursor()
cur.execute('''
    SELECT COUNT(*) FROM portfolio_snapshots
    WHERE portfolio_id = %s AND strategy_id = %s AND session_id = %s
''', (${PORTFOLIO_ID}, ${STRATEGY_ID}, '${SESSION_ID}'))
print(cur.fetchone()[0])
cur.close()
conn.close()
")

if [ "$SNAPSHOT_RESULT" -ge 1 ]; then
    pass "portfolio_snapshots: ${SNAPSHOT_RESULT} snapshots with strategy_id=${STRATEGY_ID} session_id=${SESSION_ID}"
else
    fail "No portfolio_snapshots with strategy_id=${STRATEGY_ID} session_id=${SESSION_ID}"
fi

# 9d. strategy_sessions row carries portfolio_id + strategy_id + completed status
info "  Querying strategy_sessions..."
SESSION_ROW=$($PYTHON -c "
import psycopg2, json
conn = psycopg2.connect('host=${DB_HOST} port=5432 dbname=${PORTFOLIO_DB_NAME} user=postgres password=postgres sslmode=disable')
cur = conn.cursor()
cur.execute('''
    SELECT portfolio_id, strategy_id, status, bars_processed
    FROM strategy_sessions
    WHERE session_id = %s
''', ('${SESSION_ID}',))
row = cur.fetchone()
print(json.dumps({
    'portfolio_id': row[0],
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
    SESSION_PORTFOLIO_ID=$(echo "$SESSION_ROW" | jq -r '.portfolio_id')
    SESSION_STRATEGY_ID=$(echo "$SESSION_ROW" | jq -r '.strategy_id')
    SESSION_STATUS=$(echo "$SESSION_ROW" | jq -r '.status')
    SESSION_BARS=$(echo "$SESSION_ROW" | jq -r '.bars_processed')

    [ "$SESSION_PORTFOLIO_ID" = "$PORTFOLIO_ID" ] && pass "strategy_sessions portfolio_id matches ${PORTFOLIO_ID}" || fail "strategy_sessions portfolio_id=${SESSION_PORTFOLIO_ID}, expected ${PORTFOLIO_ID}"
    [ "$SESSION_STRATEGY_ID" = "$STRATEGY_ID" ] && pass "strategy_sessions strategy_id matches ${STRATEGY_ID}" || fail "strategy_sessions strategy_id=${SESSION_STRATEGY_ID}, expected ${STRATEGY_ID}"
    if [ "$SESSION_STATUS" = "finished" ] || [ "$SESSION_STATUS" = "6" ]; then
        pass "strategy_sessions status=${SESSION_STATUS}"
    else
        fail "strategy_sessions status=${SESSION_STATUS}, expected finished/6"
    fi
    [ "$SESSION_BARS" = "$BARS" ] && pass "strategy_sessions bars_processed=${BARS}" || fail "strategy_sessions bars_processed=${SESSION_BARS}, expected ${BARS}"
fi

# ══════════════════════════════════════════════════════════════════════════════
# Step 11: Verify one strategy can replay independent symbols and intervals
# ══════════════════════════════════════════════════════════════════════════════
info "Step 11: Run multi-stream backtest (TESTUSDT 1m + TESTUSDT 5m + ALTUSDT 1m)"
curl -s -X POST "${API}/api/portfolios/${PORTFOLIO_ID}/strategies/${STRATEGY_ID}/deactivate" -H "$AUTH" >/dev/null

MULTI_STRATEGY_CODE=$(cat "$ROOT/strategy-service/tests/strategies/test_multi_stream_full_flow.py")
MULTI_STRATEGY_CODE_JSON=$(echo "$MULTI_STRATEGY_CODE" | $PYTHON -c 'import sys,json; print(json.dumps(sys.stdin.read()))')
MULTI_STRATEGY_RESP=$(curl -s -X POST "${API}/api/strategies" \
    -H "$AUTH" -H 'Content-Type: application/json' \
    -d "{
  \"name\": \"e2e-multi-stream-${E2E_TS}\",
  \"version\": \"1.0.0\",
  \"description\": \"E2E test: same symbol different intervals plus second symbol\",
  \"code\": ${MULTI_STRATEGY_CODE_JSON}
}")
MULTI_STRATEGY_ID=$(echo "$MULTI_STRATEGY_RESP" | jq -r '.strategy_id')
if [ -z "$MULTI_STRATEGY_ID" ] || [ "$MULTI_STRATEGY_ID" = "null" ]; then
    fail "Create multi-stream strategy failed: $MULTI_STRATEGY_RESP"
    exit 1
fi
curl -s -X POST "${API}/api/portfolios/${PORTFOLIO_ID}/strategies/${MULTI_STRATEGY_ID}" -H "$AUTH" >/dev/null
curl -s -X POST "${API}/api/portfolios/${PORTFOLIO_ID}/strategies/${MULTI_STRATEGY_ID}/activate" -H "$AUTH" >/dev/null

MULTI_RUN_RESP=$(curl -s -X POST "${API}/api/portfolios/${PORTFOLIO_ID}/run-strategy" \
    -H "$AUTH" -H 'Content-Type: application/json' \
    -d "{
  \"strategy_path\": \"\",
  \"interval\": \"1m\",
  \"start_time_ms\": 1735689600000,
  \"end_time_ms\": 1735701600000,
  \"runtime_id\": \"${RUNTIME_ID}\"
}")
MULTI_SESSION_ID=$(echo "$MULTI_RUN_RESP" | jq -r '.session_id')
if [ -z "$MULTI_SESSION_ID" ] || [ "$MULTI_SESSION_ID" = "null" ]; then
    fail "Run multi-stream backtest failed: $MULTI_RUN_RESP"
    exit 1
fi

MULTI_STATUS=""
MULTI_BARS="0"
for i in $(seq 1 30); do
    MULTI_STATUS_RESP=$(curl -s "${API}/api/strategy-sessions/${MULTI_SESSION_ID}" -H "$AUTH" 2>/dev/null || echo '{"status":"error"}')
    MULTI_STATUS=$(echo "$MULTI_STATUS_RESP" | jq -r '.status')
    MULTI_BARS=$(echo "$MULTI_STATUS_RESP" | jq -r '.bars_processed')
    if [ "$MULTI_STATUS" = "finished" ]; then
        break
    elif [ "$MULTI_STATUS" = "failed" ]; then
        fail "Multi-stream backtest failed: $(echo "$MULTI_STATUS_RESP" | jq -r '.error')"
        exit 1
    fi
    sleep 2
done

if [ "$MULTI_STATUS" != "finished" ]; then
    fail "Multi-stream backtest did not complete within 60s (status=${MULTI_STATUS})"
elif [ "$MULTI_BARS" = "440" ]; then
    pass "Multi-stream replay kept all three streams independent: bars_processed=440"
else
    fail "Expected 440 merged bars (200 + 40 + 200), got ${MULTI_BARS}"
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
