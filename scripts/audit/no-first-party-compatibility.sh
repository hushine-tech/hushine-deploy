#!/usr/bin/env bash
set -euo pipefail

usage() {
  echo "usage: $0 [workspace-root]" >&2
  exit 2
}

[[ $# -le 1 ]] || usage
workspace_root="${1:-.}"
[[ -d "${workspace_root}" ]] || {
  echo "compatibility audit root is not a directory: ${workspace_root}" >&2
  exit 2
}
command -v rg >/dev/null 2>&1 || {
  echo "compatibility audit requires ripgrep (rg)" >&2
  exit 2
}
workspace_root="$(cd -- "${workspace_root}" && pwd -P)"

# Generic intent markers are supplemented by exact, known compatibility shapes.
# Old first-party names belong in this candidate expression, never the allowlist.
candidate_pattern='(?i:legacy|deprecated|compatibility)|RuntimeStatusPaired|UpdatePortfolioSnapshot|include_revoked|includeRevoked|IncludeRevoked|values_json|scope[[:space:]]*==[[:space:]]*""|\b(TIMESCALEDB_DSN|ORDER_TIMESCALEDB_DSN|MOCK_BINANCE|SYMBOL_CACHE_TTL|HTTP_ADDR|GRPC_ADDR|CORE_SERVICE_GRPC_ADDR|ORDER_SERVICE_GRPC_ADDR)\b|\b(advertise_host|port_range_base|port_range_size|runtime_env)\b|def[[:space:]]+init[[:space:]]*\([[:space:]]*output_dir[[:space:]]*:[[:space:]]*str[[:space:]]*,[[:space:]]*\*types'

raw_candidates="$(mktemp "${TMPDIR:-/tmp}/hushine-compatibility-raw.XXXXXX")"
filtered_candidates="$(mktemp "${TMPDIR:-/tmp}/hushine-compatibility-filtered.XXXXXX")"
trap 'rm -f -- "${raw_candidates}" "${filtered_candidates}"' EXIT

set +e
rg \
  --line-number \
  --with-filename \
  --no-heading \
  --color never \
  --glob '*.{go,py,proto,sql,md,rst,sh,bash,yaml,yml,toml,ts,tsx,js,mjs,cjs}' \
  --glob 'Dockerfile*' \
  --glob '!**/.git/**' \
  --glob '!**/gen/**' \
  --glob '!**/generated/**' \
  --glob '!**/*.pb.go' \
  --glob '!**/*_pb2.py' \
  --glob '!**/*_pb2_grpc.py' \
  --glob '!**/vendor/**' \
  --glob '!**/node_modules/**' \
  --glob '!**/.venv/**' \
  --glob '!**/venv/**' \
  --glob '!**/site-packages/**' \
  --glob '!**/dist/**' \
  --glob '!**/build/**' \
  --glob '!**/.next/**' \
  --glob '!**/coverage/**' \
  --glob '!**/.coverage/**' \
  --glob '!**/__pycache__/**' \
  --glob '!**/tests/**' \
  --glob '!**/test/**' \
  --glob '!**/testdata/**' \
  --glob '!**/fixtures/**' \
  --glob '!**/__tests__/**' \
  --glob '!**/mocks/**' \
  --glob '!**/*_test.go' \
  --glob '!**/test_*.py' \
  --glob '!**/*_test.py' \
  --glob '!**/*.test.*' \
  --glob '!**/*.spec.*' \
  --glob '!**/docs/superpowers/**' \
  --glob '!**/.superpowers/**' \
  --glob '!**/openspec/changes/archive/**' \
  --glob '!**/census-runs/**' \
  --glob '!**/scripts/audit/**' \
  -- "${candidate_pattern}" "${workspace_root}" >"${raw_candidates}"
rg_status=$?
set -e

case "${rg_status}" in
  0 | 1) ;;
  *)
    echo "compatibility audit scan failed" >&2
    exit 2
    ;;
esac

# These are current, externally owned protocol terms or current governance and
# historical-market-data statements. Keep the allowlist phrase-level and never
# add a removed Hushine field, RPC, environment variable, or status here.
awk '
  {
    text = $0
    sub(/^[^:]+:[0-9]+:/, "", text)

    if (text ~ /Jaeger Thrift HTTP receiver \(legacy\)/) next
    if (text ~ /Jaeger gRPC native receiver \(legacy\)/) next
    if (text ~ /Protocol\/migration\/history removal requires a separate compatibility decision\./) next
    if (text ~ /^[[:space:]]*Historical market data (is|remains) a current product function\.[[:space:]]*$/) next
    if (text ~ /scope[[:space:]]*==[[:space:]]*"historical"/) next

    print
  }
' "${raw_candidates}" >"${filtered_candidates}"

if [[ -s "${filtered_candidates}" ]]; then
  LC_ALL=C sort "${filtered_candidates}"
  exit 1
fi

exit 0
