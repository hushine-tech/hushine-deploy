#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

required_patterns=(
  './bin/account-service -config'
  './bin/control-panel-service -config'
  './bin/quant-handler -config'
  'run_grpc_server.py -config'
  './bin/scraper -config'
)

required_literals=(
  'kill_listening_ports'
  'app_ports=('
  '50051:account-service'
  '50053:strategy-service'
  '50054:control-panel-service'
  '8090:quant-handler'
  '5173:quant-frontend'
  'legacy_ports=('
  '50052:legacy-order-service'
  'assert_single_listener'
)

forbidden_literals=(
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
