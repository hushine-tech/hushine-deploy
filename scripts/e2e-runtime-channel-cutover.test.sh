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
  '/api/portfolios'
  '/api/venues'
  'portfolio_service_grpc:'
  'portfolio_snapshots'
  'i.portfolio_id'
  "TIMESCALE_DB_PATTERN='binance_{year}'"
  'tests/strategies/test_multi_stream_full_flow.py'
  '\"position_side\": \"BOTH\"'
  'Expected 440 merged bars (200 + 40 + 200)'
  'TEMP_TOKEN=$(echo "$LOGIN_RESP" | jq -r '\''.token // empty'\'' 2>/dev/null || true)'
  'LOCAL_NO_PROXY="127.0.0.1,localhost,::1"'
  'export NO_PROXY="${LOCAL_NO_PROXY}${NO_PROXY:+,${NO_PROXY}}"'
  'export no_proxy="${LOCAL_NO_PROXY}${no_proxy:+,${no_proxy}}"'
  '"$ROOT/.e2e-build/core-service" -config /dev/null'
  '"$ROOT/.e2e-build/quant-handler" -config /dev/null'
)

for literal in "${required_literals[@]}"; do
  if ! grep -Fq -- "$literal" "$script"; then
    echo "missing RuntimeChannel e2e literal: $literal" >&2
    exit 1
  fi
done

for forbidden in \
  'run_grpc_server.py' \
  'STRAT_GRPC' \
  '/tmp/e2e-strategy.log' \
  'strategy-service PID' \
  '/api/accounts' \
  'account_service_grpc:' \
  'account_service_pb2' \
  'account_snapshots' \
  'i.account_id'; do
  if grep -Fq -- "$forbidden" "$script"; then
    echo "forbidden legacy strategy-service e2e literal still present: $forbidden" >&2
    exit 1
  fi
done

venue_payload="$(sed -n '/^VENUE_RESP=/,/^VENUE_ID=/p' "$script")"
if grep -Fq -- '\"direction\"' <<<"$venue_payload"; then
  echo "removed futures direction field still present in current e2e Venue payload" >&2
  exit 1
fi

if grep -Fq -- '\"leverage\"' <<<"$venue_payload"; then
  echo "strategy-owned leverage still present in current e2e Venue payload" >&2
  exit 1
fi

if grep -Fq -- 'E2E_TIMESCALE_DB_PATTERN:-binance_{year}' "$script"; then
  echo "brace-bearing database pattern must not be embedded in parameter-expansion default" >&2
  exit 1
fi
