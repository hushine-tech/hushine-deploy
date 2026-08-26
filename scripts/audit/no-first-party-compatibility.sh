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

scan_args=(
  --line-number \
  --with-filename \
  --no-heading \
  --color never \
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
)

append_candidates() {
  local pattern="$1"
  shift
  local rg_status
  set +e
  rg "$@" "${scan_args[@]}" -- "${pattern}" "${workspace_root}" >>"${raw_candidates}"
  rg_status=$?
  set -e
  case "${rg_status}" in
    0 | 1) ;;
    *)
      echo "compatibility audit scan failed" >&2
      exit 2
      ;;
  esac
}

append_candidates \
  "${candidate_pattern}" \
  --glob '*.{go,py,proto,sql,md,rst,sh,bash,yaml,yml,toml,ts,tsx,js,mjs,cjs}' \
  --glob 'Dockerfile*'

# Exchange-private Funding endpoints, signing markers, and the Binance linear
# formula belong only below each repository's Binance Adapter. These exact
# shapes intentionally exclude the adapter-local implementation and its mocks.
append_candidates \
  '(?i:/fapi/v1/(income|fundingRate|premiumIndex)|[[:punct:]]incomeType[[:punct:]][^;]*FUNDING_FEE|binance-usdm-linear|(signed_?[[:alnum:]]*qty[^;]*mark_?[[:alnum:]]*price[^;]*funding_?[[:alnum:]]*rate|signed_?[[:alnum:]]*qty[^;]*funding_?[[:alnum:]]*rate[^;]*mark_?[[:alnum:]]*price|mark_?[[:alnum:]]*price[^;]*signed_?[[:alnum:]]*qty[^;]*funding_?[[:alnum:]]*rate|mark_?[[:alnum:]]*price[^;]*funding_?[[:alnum:]]*rate[^;]*signed_?[[:alnum:]]*qty|funding_?[[:alnum:]]*rate[^;]*signed_?[[:alnum:]]*qty[^;]*mark_?[[:alnum:]]*price|funding_?[[:alnum:]]*rate[^;]*mark_?[[:alnum:]]*price[^;]*signed_?[[:alnum:]]*qty))' \
  --glob '*.{go,py,ts,tsx,js,mjs,cjs}' \
  --glob '!**/internal/exchange/binance/**'

# Reject only Funding-derived eight-hour arithmetic; unrelated eight-hour
# certificate/debug-package durations remain valid current behavior.
append_candidates \
  '(?i:(next_?[[:alnum:]]*funding|funding_?[[:alnum:]]*time)[^;]*(8[[:space:]]*\*[[:space:]]*time\.Hour|timedelta\([[:space:]]*hours[[:space:]]*=[[:space:]]*8[[:space:]]*\)))' \
  --glob '*.{go,py}'

# The canonical stream callback carries UserDataEvent. A callback typed to the
# order payload would silently restore the superseded order-only contract.
append_candidates \
  'func[[:space:]]*\([^)]*UserDataOrderEvent' \
  --glob '*.{go,proto}'

# Dated Superpowers artifacts are already excluded above. Current user-facing
# documentation must not present the retired debugger CLI as a supported path.
append_candidates \
  'strategy-debugger-cli' \
  --glob '**/docs/**'

# The current baseline has one Income/Funding ledger table. The awk allowlist
# below admits only its exact canonical table name.
append_candidates \
  '(?i:CREATE[[:space:]]+TABLE([[:space:]]+IF[[:space:]]+NOT[[:space:]]+EXISTS)?[[:space:]]+[A-Za-z0-9_]*(income|funding|ledger)[A-Za-z0-9_]*)' \
  --glob '*.sql'

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
    if (text ~ /^[[:space:]]*CREATE[[:space:]]+TABLE([[:space:]]+IF[[:space:]]+NOT[[:space:]]+EXISTS)?[[:space:]]+venue_income_entries([[:space:]]|\()/) next

    print
  }
' "${raw_candidates}" >"${filtered_candidates}"

if [[ -s "${filtered_candidates}" ]]; then
  LC_ALL=C sort "${filtered_candidates}"
  exit 1
fi

exit 0
