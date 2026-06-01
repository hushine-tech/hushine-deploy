#!/usr/bin/env bash
# 一键重启当前机器上的 Hushine 应用服务。
# 约定：应用服务跑在本机；第三方依赖（PostgreSQL / Kafka / OTLP 等）
# 由 DEP_HOST 提供，默认 192.168.88.10。
set -euo pipefail

cd "$(dirname "$0")"
REPO_ROOT="$(pwd -P)"

if [ -f "${REPO_ROOT}/.env.local" ]; then
  set -a
  # 本地敏感配置，例如 TELEGRAM_BOT_TOKEN / TELEGRAM_BOT_USERNAME。
  # shellcheck disable=SC1091
  . "${REPO_ROOT}/.env.local"
  set +a
fi

DEP_HOST="${DEP_HOST:-192.168.88.10}"
REMOTE_RUNTIME_USER="${REMOTE_RUNTIME_USER:-hushine-tech}"
CONTROL_PANEL_ADDR="${CONTROL_PANEL_ADDR:-127.0.0.1:50054}"
APP_CONFIG="${APP_CONFIG:-./config.local.yaml}"
SCRAPER_LOG_CONFIG="${SCRAPER_LOG_CONFIG:-./log-config.local.json}"

export PATH="/usr/local/go/bin:${PATH}"
export NO_PROXY="127.0.0.1,localhost,::1,${DEP_HOST},${NO_PROXY:-}"
export no_proxy="$NO_PROXY"
export CONTROL_PANEL_SERVICE_GRPC_ADDR="${CONTROL_PANEL_SERVICE_GRPC_ADDR:-${CONTROL_PANEL_ADDR}}"
export MARKET_DATA_CONTROL_PANEL_GRPC_ADDR="${MARKET_DATA_CONTROL_PANEL_GRPC_ADDR:-${CONTROL_PANEL_ADDR}}"
export NOTIFICATION_KAFKA_BROKERS="${NOTIFICATION_KAFKA_BROKERS:-${DEP_HOST}:19092}"
export NOTIFICATION_KAFKA_TOPIC="${NOTIFICATION_KAFKA_TOPIC:-notification.events}"
export NOTIFICATION_KAFKA_GROUP_ID="${NOTIFICATION_KAFKA_GROUP_ID:-core-service-notification}"

check_port() {
  local host="$1"
  local port="$2"
  if command -v nc >/dev/null 2>&1; then
    nc -z -G 3 "$host" "$port" >/dev/null 2>&1 && return 0
    nc -z -w 3 "$host" "$port" >/dev/null 2>&1 && return 0
    return 1
  fi
  bash -lc "</dev/tcp/${host}/${port}" >/dev/null 2>&1
}

kill_process_patterns() {
  local pattern
  for pattern in "$@"; do
    pkill -TERM -f "$pattern" 2>/dev/null || true
  done
  sleep 2
  for pattern in "$@"; do
    pkill -KILL -f "$pattern" 2>/dev/null || true
  done
}

kill_listening_ports() {
  local spec port label pids
  for spec in "$@"; do
    port="${spec%%:*}"
    label="${spec#*:}"
    pids="$(lsof -nP -tiTCP:"${port}" -sTCP:LISTEN 2>/dev/null || true)"
    if [ -n "$pids" ]; then
      echo "  清理端口 ${port} (${label}) listener: $(echo "$pids" | tr '\n' ' ')"
      kill -TERM $pids 2>/dev/null || true
    fi
  done
  sleep 2
  for spec in "$@"; do
    port="${spec%%:*}"
    label="${spec#*:}"
    pids="$(lsof -nP -tiTCP:"${port}" -sTCP:LISTEN 2>/dev/null || true)"
    if [ -n "$pids" ]; then
      echo "  强制清理端口 ${port} (${label}) listener: $(echo "$pids" | tr '\n' ' ')"
      kill -KILL $pids 2>/dev/null || true
    fi
  done
}

assert_single_process() {
  local label="$1"
  local pattern="$2"
  local count
  count="$(pgrep -f "$pattern" 2>/dev/null | wc -l | tr -d ' ')"
  if [ "$count" != "1" ]; then
    echo "${label} 进程数量异常：${count}，期望 1。"
    pgrep -af "$pattern" 2>/dev/null || true
    exit 1
  fi
}

assert_single_listener() {
  local label="$1"
  local port="$2"
  local count
  count="$(lsof -nP -tiTCP:"${port}" -sTCP:LISTEN 2>/dev/null | sort -u | wc -l | tr -d ' ')"
  if [ "$count" != "1" ]; then
    echo "${label} 端口 ${port} listener 数量异常：${count}，期望 1。"
    lsof -nP -iTCP:"${port}" -sTCP:LISTEN 2>/dev/null || true
    exit 1
  fi
}

echo "→ 停止现有服务..."
make local-stop

if command -v docker >/dev/null 2>&1; then
  # 旧部署方式可能留下同名 strategy-service 容器并占用 50053。
  docker rm -f hushine-strategy-service >/dev/null 2>&1 || true
fi

app_ports=(
  "50051:core-service"
  "18080:core-service-http"
  "50053:strategy-service"
  "50054:control-panel-service"
  "8082:control-panel-service-http"
  "8090:quant-handler"
  "5173:quant-frontend"
)

# 历史遗留：order.v1 已并入 core-service，但开发机上可能还残留旧独立
# order-service 进程。这里仅清理，不再启动它。
legacy_ports=(
  "50052:legacy-order-service"
)

# 兜底：仅清理仓库自己的残留进程，避免误杀同机其它服务（如 GitLab / Kafka / DB）。
cleanup_patterns=(
  "${REPO_ROOT}/core-service/bin/core-service" \
  './bin/core-service -config' \
  'go run ./cmd/core-service -config' \
  "${REPO_ROOT}/control-panel-service/bin/control-panel-service" \
  './bin/control-panel-service -config' \
  'go run ./cmd/control-panel-service -config' \
  "${REPO_ROOT}/gateway/quant-handler/bin/quant-handler" \
  './bin/quant-handler -config' \
  'go run ./cmd/quant-handler -config' \
  "${REPO_ROOT}/strategy-service/run_grpc_server.py" \
  'run_grpc_server.py -config' \
  "${REPO_ROOT}/scraper/bin/scraper" \
  './bin/scraper -config' \
  'go run ./cmd/scraper -config' \
  'vite preview --port 5173 --host'
)

legacy_cleanup_patterns=(
  "${REPO_ROOT}/order-service/bin/order-service" \
  './bin/order-service -config' \
  'go run ./cmd/order-service -config'
)

kill_process_patterns "${cleanup_patterns[@]}" "${legacy_cleanup_patterns[@]}"
kill_listening_ports "${app_ports[@]}" "${legacy_ports[@]}"

echo "→ 检查本机基础设施..."
for port in 5432 19092 4318; do
  if ! check_port "${DEP_HOST}" "${port}"; then
    echo "缺少依赖：${DEP_HOST}:$port 不可达。"
    exit 1
  fi
done

echo "→ 应用数据库迁移..."
make ensure-dbs

echo "→ 启动应用服务...（远端 runtime 用户默认 ${REMOTE_RUNTIME_USER}@${DEP_HOST}）"
make -C core-service start CONFIG="${APP_CONFIG}"
sleep 2
make -C control-panel-service start CONFIG="${APP_CONFIG}"
make -C strategy-service start CONFIG="${APP_CONFIG}"
make -C scraper start CONFIG="${APP_CONFIG}" LOG_CONFIG="${SCRAPER_LOG_CONFIG}"
sleep 1
make -C gateway/quant-handler start CONFIG="${APP_CONFIG}"
make -C gateway/quant-frontend start

assert_single_process "control-panel-service" "control-panel-service.*-config"
for spec in "${app_ports[@]}"; do
  assert_single_listener "${spec#*:}" "${spec%%:*}"
done

echo ""
echo "日志文件："
echo "  core-service/logs/core-service.out"
echo "  control-panel-service/logs/control-panel-service.out"
echo "  strategy-service/logs/strategy-service.out"
echo "  scraper/logs/scraper.out"
echo "  gateway/quant-handler/logs/quant-handler.out"
echo "  gateway/quant-frontend/logs/quant-frontend.out"
echo ""
echo "Runtime 测试入口："
echo "  UI: http://localhost:5173/runtimes"
echo "  Hosted: USER_ID=<account.users.id> make smoke-hosted-runtime"
echo "  Self-hosted local: CREDENTIAL_FILE=/path/to/runtime.cred CONTROL_PANEL_ADDR=host.docker.internal:50054 make smoke-self-hosted-runtime"
echo "  Self-hosted remote: CREDENTIAL_FILE=/path/to/runtime.cred REMOTE_HOST=${DEP_HOST} REMOTE_USER=${REMOTE_RUNTIME_USER} CONTROL_PANEL_ADDR=<mac-lan-ip>:50054 make smoke-self-hosted-runtime"
echo ""
echo "Notification Management："
echo "  Kafka topic: ${NOTIFICATION_KAFKA_TOPIC} via ${NOTIFICATION_KAFKA_BROKERS}"
echo "  Telegram 发送/绑定需要在启动 core-service 前设置 TELEGRAM_BOT_TOKEN 和 TELEGRAM_BOT_USERNAME。"
