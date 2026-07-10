#!/usr/bin/env bash
# Smoke helper for self-hosted debugger runtime workflow.
#
# Required env:
#   TOKEN=<jwt>
#   PORTFOLIO_ID=<portfolio id>
#   RUNTIME_ID=<self-hosted debugger runtime id>
#   START_TIME_MS=<inclusive start epoch ms>
#   END_TIME_MS=<exclusive end epoch ms>
#
# Optional env:
#   BASE_URL=http://localhost:8090
#   MARKET=perpetual_futures
#   SYMBOL=ETHUSDT
#   INTERVAL=1m
#   CONTAINER_PATH=/workspace
set -euo pipefail

BASE_URL="${BASE_URL:-http://localhost:8090}"
TOKEN="${TOKEN:?TOKEN is required}"
PORTFOLIO_ID="${PORTFOLIO_ID:?PORTFOLIO_ID is required}"
RUNTIME_ID="${RUNTIME_ID:?RUNTIME_ID is required}"
START_TIME_MS="${START_TIME_MS:?START_TIME_MS is required}"
END_TIME_MS="${END_TIME_MS:?END_TIME_MS is required}"
MARKET="${MARKET:-perpetual_futures}"
SYMBOL="${SYMBOL:-ETHUSDT}"
INTERVAL="${INTERVAL:-1m}"
CONTAINER_PATH="${CONTAINER_PATH:-/workspace}"

auth_header=(-H "Authorization: Bearer ${TOKEN}" -H "Content-Type: application/json")

echo "Preparing debug workspace on runtime ${RUNTIME_ID}"
curl -fsS \
  "${auth_header[@]}" \
  -X POST "${BASE_URL}/api/runtimes/${RUNTIME_ID}/prepare-debugging" \
  -d "$(printf '{"container_path":"%s"}' "${CONTAINER_PATH}")"

echo
echo "Loading debug dataset ${MARKET}/${SYMBOL}/${INTERVAL} ${START_TIME_MS}-${END_TIME_MS}"
curl -fsS \
  "${auth_header[@]}" \
  -X POST "${BASE_URL}/api/portfolios/${PORTFOLIO_ID}/debug-dataset" \
  -d "$(printf '{"runtime_id":"%s","market":"%s","symbol":"%s","interval":"%s","start_time_ms":%s,"end_time_ms":%s}' \
    "${RUNTIME_ID}" "${MARKET}" "${SYMBOL}" "${INTERVAL}" "${START_TIME_MS}" "${END_TIME_MS}")"

echo
echo "Dataset loaded. Enter the debugger runtime container and run:"
echo "  hushine-debug replay"
