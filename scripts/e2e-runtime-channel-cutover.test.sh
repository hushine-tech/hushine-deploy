#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

script="scripts/e2e_full_flow.sh"

required_literals=(
  'CP_RUNTIME_GRPC=18055'
  'runtime_channel_server:'
  'runtime_channel_dial_addr: "host.docker.internal:${CP_RUNTIME_GRPC}"'
  'strategy-service/scripts/build_strategy_runtime.sh'
  'scripts/smoke_ensure_runtime.go'
)

for literal in "${required_literals[@]}"; do
  if ! grep -Fq -- "$literal" "$script"; then
    echo "missing RuntimeChannel e2e literal: $literal" >&2
    exit 1
  fi
done

for forbidden in 'run_grpc_server.py' 'STRAT_GRPC' '/tmp/e2e-strategy.log' 'strategy-service PID'; do
  if grep -Fq -- "$forbidden" "$script"; then
    echo "forbidden legacy strategy-service e2e literal still present: $forbidden" >&2
    exit 1
  fi
done
