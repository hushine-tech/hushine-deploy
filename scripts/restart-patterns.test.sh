#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

required_patterns=(
  './bin/core-service -config'
  './bin/control-panel-service -config'
  './bin/quant-handler -config'
  'run_grpc_server.py -config'
  './bin/scraper -config'
)

required_literals=(
  'kill_listening_ports'
  'app_ports=('
  '50051:core-service'
  '50054:control-panel-service'
  '50055:control-panel-runtime-channel'
  '8090:quant-handler'
  '5173:quant-frontend'
  'legacy_ports=('
  '50053:legacy-strategy-service'
  '50052:legacy-order-service'
  'assert_single_listener'
  'DEPLOY_ROOT="$(pwd -P)"'
  'SOURCE_ROOT="${DEPLOY_ROOT}"'
  'SOURCE_ROOT="$(cd "${DEPLOY_ROOT}/.." && pwd -P)"'
  'make -C "${SOURCE_ROOT}" ensure-dbs'
  'make -C "${SOURCE_ROOT}/core-service" start CONFIG="${APP_CONFIG}"'
  'CORE_CREDENTIAL_ENCRYPTION_KEY="${CORE_CREDENTIAL_ENCRYPTION_KEY:-0123456789abcdef0123456789abcdef}"'
  'CORE_CREDENTIAL_KEY_VERSION="${CORE_CREDENTIAL_KEY_VERSION:-dev-v1}"'
  'RUNTIME_PLATFORM_DEBUG_BARE_RUNTIME_ENABLED="${RUNTIME_PLATFORM_DEBUG_BARE_RUNTIME_ENABLED:-true}"'
  'RUNTIME_CHANNEL_SERVER_TLS_CLIENT_CA_FILE'
  'RUNTIME_CHANNEL_SERVER_TLS_CLIENT_CA_KEY_FILE'
  'RUNTIME_CHANNEL_SERVER_TLS_SERVER_NAME'
  'RUNTIME_PLATFORM_BARE_BOOTSTRAP_IP_ALLOWLIST'
  'Bare local: cd strategy-service && make build && DEBUG_WAIT=0 scripts/start-bare-runtime-debugpy.sh --user-id <users.id> --platform-host 127.0.0.1'
)

forbidden_literals=(
  'make -C '"strategy-service"' start'
  'strategy-service/'"logs/strategy-service.out"
  'make -C '"order-service"' start'
  'order-service/'"logs/order-service.out"
)

for pattern in "${required_patterns[@]}"; do
  if ! grep -Fq "$pattern" restart.sh; then
    echo "missing restart cleanup pattern: $pattern" >&2
    exit 1
  fi
done

for literal in "${forbidden_literals[@]}"; do
  if grep -Fq "$literal" restart.sh; then
    echo "obsolete independent order-service pattern still present: $literal" >&2
    exit 1
  fi
done

for literal in "${required_literals[@]}"; do
  if ! grep -Fq "$literal" restart.sh; then
    echo "missing restart port cleanup literal: $literal" >&2
    exit 1
  fi
done

for smoke_script in scripts/smoke_d3_hosted_runtime.sh scripts/smoke_d3_self_hosted_runtime.sh; do
  for literal in \
    'DEPLOY_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"' \
    'SOURCE_ROOT="${DEPLOY_ROOT}"' \
    'SOURCE_ROOT="$(cd "${DEPLOY_ROOT}/.." && pwd -P)"'; do
    if ! grep -Fq -- "$literal" "$smoke_script"; then
      echo "missing source-root smoke literal in ${smoke_script}: $literal" >&2
      exit 1
    fi
  done
done

if ! grep -Fq 'go run scripts/smoke_ensure_runtime.go' scripts/smoke_d3_hosted_runtime.sh; then
  echo "hosted runtime smoke no longer calls smoke_ensure_runtime.go" >&2
  exit 1
fi
