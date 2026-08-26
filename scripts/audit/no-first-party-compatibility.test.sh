#!/usr/bin/env bash
set -euo pipefail

DEPLOY_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)"
SCANNER="${DEPLOY_ROOT}/scripts/audit/no-first-party-compatibility.sh"
fixture="$(mktemp -d "${TMPDIR:-/tmp}/hushine-compatibility-audit.XXXXXX")"
trap 'rm -rf -- "${fixture}"' EXIT

fail() {
  echo "compatibility audit test failed: $*" >&2
  exit 1
}

hash_fixture() {
  find "${fixture}" -type f -exec shasum -a 256 {} + | LC_ALL=C sort
}

mkdir -p "${fixture}/src" "${fixture}/api" "${fixture}/db" "${fixture}/docs"
printf '%s\n' \
  'Use strategy-debugger-cli for the current local offline replay workflow.' \
  'strategy-debugger-cli is deprecated, but remains supported and required.' \
  >"${fixture}/README.md"
printf '%s\n' \
  'Agents must validate the current Package V2 offline workflow.' \
  >"${fixture}/AGENTS.md"
printf '%s\n' '// legacy Hushine route' >"${fixture}/src/legacy.go"
printf '%s\n' '// deprecated Hushine RPC' >"${fixture}/api/deprecated.proto"
printf '%s\n' '-- compatibility Hushine column' >"${fixture}/db/compatibility.sql"
printf '%s\n' 'This current guide documents a legacy Hushine setting.' >"${fixture}/docs/current.md"
printf '%s\n' \
  'var oldNames = []string{"TIMESCALEDB_DSN", "MOCK_BINANCE", "SYMBOL_CACHE_TTL", "HTTP_ADDR", "GRPC_ADDR"}' \
  >"${fixture}/src/config.go"
printf '%s\n' \
  'if scope == "" {}' \
  'const status = RuntimeStatusPaired' \
  >"${fixture}/src/runtime.go"
printf '%s\n' \
  'rpc UpdatePortfolioSnapshot(UpdatePortfolioSnapshotRequest) returns (UpdatePortfolioSnapshotResponse);' \
  'bool include_revoked = 2;' \
  >"${fixture}/api/current.proto"
printf '%s\n' 'SELECT values_json FROM strategy_indicators;' >"${fixture}/db/current.sql"
printf '%s\n' 'def init(output_dir: str, *types: Type) -> Logger:' >"${fixture}/src/logger.py"
printf '%s\n' \
  'const incomeEndpoint = "/fapi/v1/income"' \
  'const signedQuery = "incomeType=FUNDING_FEE"' \
  'fundingAmount := -signedQty * markPrice * fundingRate' \
  >"${fixture}/src/generic_funding.go"
printf '%s\n' \
  'nextFundingTime := fundingTime.Add(8 * time.Hour)' \
  >"${fixture}/src/funding_clock.go"
printf '%s\n' \
  'func Listen(handle func(context.Context, UserDataOrderEvent)) {}' \
  >"${fixture}/src/order_only_stream.go"
printf '%s\n' \
  'func Listen(' \
  '  handle func(' \
  '    context.Context,' \
  '    UserDataOrderEvent,' \
  '  ),' \
  ') {}' \
  >"${fixture}/src/multiline_order_only_stream.go"
printf '%s\n' \
  'nextFundingTime :=' \
  '  fundingTime.Add(' \
  '    8 * time.Hour,' \
  '  )' \
  >"${fixture}/src/multiline_funding_clock.go"
printf '%s\n' \
  'Use strategy-debugger-cli as the current supported runtime.' \
  >"${fixture}/docs/runtime.md"
printf '%s\n' \
  'Package-v2 offline replay is a current supported capability.' \
  >"${fixture}/docs/offline.md"
printf '%s\n' \
  'CREATE TABLE funding_fee_entries (id BIGINT PRIMARY KEY);' \
  >"${fixture}/db/funding_ledger.sql"
printf '%s\n' \
  'CREATE TABLE "funding_fee_entries" (id BIGINT PRIMARY KEY);' \
  >"${fixture}/db/quoted_funding_ledger.sql"
printf '%s\n' \
  'CREATE TABLE public.funding_fee_entries (id BIGINT PRIMARY KEY);' \
  >"${fixture}/db/schema_funding_ledger.sql"
printf '%s\n' \
  'CREATE TABLE "public"."funding_fee_entries" (id BIGINT PRIMARY KEY);' \
  >"${fixture}/db/quoted_schema_funding_ledger.sql"
printf '%s\n' \
  'CREATE TABLE' \
  '  funding_fee_audit_entries (' \
  '    id BIGINT PRIMARY KEY' \
  '  );' \
  >"${fixture}/db/multiline_funding_ledger.sql"

before="$(hash_fixture)"
set +e
output="$("${SCANNER}" "${fixture}" 2>&1)"
status=$?
set -e
after="$(hash_fixture)"

[[ "${status}" -eq 1 ]] \
  || fail "candidate scan returned ${status}, expected 1"
[[ "${before}" == "${after}" ]] \
  || fail "scanner modified an input fixture"

missing_expected=()
for expected in \
  '/README.md:1:Use strategy-debugger-cli for the current local offline replay workflow.' \
  '/README.md:2:strategy-debugger-cli is deprecated, but remains supported and required.' \
  '/AGENTS.md:1:Agents must validate the current Package V2 offline workflow.' \
  '/src/legacy.go:1:// legacy Hushine route' \
  '/api/deprecated.proto:1:// deprecated Hushine RPC' \
  '/db/compatibility.sql:1:-- compatibility Hushine column' \
  '/docs/current.md:1:This current guide documents a legacy Hushine setting.' \
  '/src/config.go:1:var oldNames = []string{"TIMESCALEDB_DSN", "MOCK_BINANCE", "SYMBOL_CACHE_TTL", "HTTP_ADDR", "GRPC_ADDR"}' \
  '/src/runtime.go:1:if scope == "" {}' \
  '/src/runtime.go:2:const status = RuntimeStatusPaired' \
  '/api/current.proto:1:rpc UpdatePortfolioSnapshot(UpdatePortfolioSnapshotRequest) returns (UpdatePortfolioSnapshotResponse);' \
  '/api/current.proto:2:bool include_revoked = 2;' \
  '/db/current.sql:1:SELECT values_json FROM strategy_indicators;' \
  '/src/logger.py:1:def init(output_dir: str, *types: Type) -> Logger:' \
  '/src/generic_funding.go:1:const incomeEndpoint = "/fapi/v1/income"' \
  '/src/generic_funding.go:2:const signedQuery = "incomeType=FUNDING_FEE"' \
  '/src/generic_funding.go:3:fundingAmount := -signedQty * markPrice * fundingRate' \
  '/src/funding_clock.go:1:nextFundingTime := fundingTime.Add(8 * time.Hour)' \
  '/src/order_only_stream.go:1:func Listen(handle func(context.Context, UserDataOrderEvent)) {}' \
  '/src/multiline_order_only_stream.go:' \
  '/src/multiline_funding_clock.go:' \
  '/docs/runtime.md:1:Use strategy-debugger-cli as the current supported runtime.' \
  '/docs/offline.md:1:Package-v2 offline replay is a current supported capability.' \
  '/db/funding_ledger.sql:1:CREATE TABLE funding_fee_entries (id BIGINT PRIMARY KEY);' \
  '/db/quoted_funding_ledger.sql:1:CREATE TABLE "funding_fee_entries" (id BIGINT PRIMARY KEY);' \
  '/db/schema_funding_ledger.sql:1:CREATE TABLE public.funding_fee_entries (id BIGINT PRIMARY KEY);' \
  '/db/quoted_schema_funding_ledger.sql:1:CREATE TABLE "public"."funding_fee_entries" (id BIGINT PRIMARY KEY);' \
  '/db/multiline_funding_ledger.sql:'; do
  grep -Fq -- "${expected}" <<<"${output}" \
    || missing_expected+=("${expected}")
done
[[ ${#missing_expected[@]} -eq 0 ]] \
  || fail "candidate output omitted: ${missing_expected[*]}"

rm -rf -- "${fixture:?}"/*
mkdir -p \
  "${fixture}/src" \
  "${fixture}/docs" \
  "${fixture}/db" \
  "${fixture}/gen" \
  "${fixture}/generated" \
  "${fixture}/vendor/example" \
  "${fixture}/node_modules/example" \
  "${fixture}/tests" \
  "${fixture}/fixtures" \
  "${fixture}/testdata" \
  "${fixture}/core-service/internal/exchange/binance" \
  "${fixture}/scraper/internal/exchange/binance" \
  "${fixture}/docs/superpowers/plans" \
  "${fixture}/census-runs/current"

printf '%s\n' \
  'strategy-debugger-cli is deprecated and is not supported as a current runtime.' \
  >"${fixture}/README.md"
printf '%s\n' \
  'Package V2 offline replay is deprecated and not supported.' \
  >"${fixture}/AGENTS.md"

printf '%s\n' 'if scope == "historical" {}' >"${fixture}/src/current.go"
printf '%s\n' \
  'http_addr: ":8080"' \
  'grpc_addr: ":50051"' \
  'mock_binance: false' \
  'symbol_cache_ttl: "6h"' \
  'kline_interval: "1m"' \
  >"${fixture}/src/current.yaml"
printf '%s\n' \
  '- "14268:14268" # Jaeger Thrift HTTP receiver (legacy)' \
  >"${fixture}/src/external_protocol.yaml"
printf '%s\n' \
  'Historical market data is a current product function.' \
  'Protocol/migration/history removal requires a separate compatibility decision.' \
  >"${fixture}/docs/current.md"

printf '%s\n' '// legacy generated binding' >"${fixture}/gen/service.pb.go"
printf '%s\n' '-- deprecated generated schema' >"${fixture}/generated/schema.sql"
printf '%s\n' '// compatibility dependency' >"${fixture}/vendor/example/dependency.go"
printf '%s\n' '// legacy JavaScript dependency' >"${fixture}/node_modules/example/index.js"
printf '%s\n' '// compatibility test' >"${fixture}/tests/compatibility.go"
printf '%s\n' '-- legacy fixture' >"${fixture}/fixtures/legacy.sql"
printf '%s\n' '// deprecated test data' >"${fixture}/testdata/deprecated.proto"
printf '%s\n' '# Legacy dated decision record' \
  >"${fixture}/docs/superpowers/plans/2026-08-24-history.md"
printf '%s\n' '# Compatibility census artifact' \
  >"${fixture}/census-runs/current/inventory.md"
printf '%s\n' \
  'const incomeEndpoint = "/fapi/v1/income"' \
  'const signedQuery = "incomeType=FUNDING_FEE"' \
  'fundingAmount := -signedQty * markPrice * fundingRate' \
  >"${fixture}/core-service/internal/exchange/binance/funding.go"
printf '%s\n' \
  'const fundingEndpoint = "/fapi/v1/fundingRate"' \
  >"${fixture}/scraper/internal/exchange/binance/funding.go"
printf '%s\n' \
  'func Listen(handle func(context.Context, UserDataEvent)) {}' \
  >"${fixture}/src/canonical_stream.go"
printf '%s\n' \
  'func Listen(' \
  '  handle func(' \
  '    context.Context,' \
  '    UserDataEvent,' \
  '  ),' \
  ') {}' \
  >"${fixture}/src/multiline_canonical_stream.go"
printf '%s\n' \
  'CREATE TABLE venue_income_entries (income_entry_id BIGINT PRIMARY KEY);' \
  >"${fixture}/db/venue_income.sql"
printf '%s\n' \
  'CREATE TABLE "venue_income_entries" (income_entry_id BIGINT PRIMARY KEY);' \
  >"${fixture}/db/quoted_venue_income.sql"
printf '%s\n' \
  'CREATE TABLE public.venue_income_entries (income_entry_id BIGINT PRIMARY KEY);' \
  >"${fixture}/db/schema_venue_income.sql"
printf '%s\n' \
  'CREATE TABLE "public"."venue_income_entries" (income_entry_id BIGINT PRIMARY KEY);' \
  >"${fixture}/db/quoted_schema_venue_income.sql"
printf '%s\n' \
  'CREATE TABLE' \
  '  venue_income_entries (' \
  '    income_entry_id BIGINT PRIMARY KEY' \
  '  );' \
  >"${fixture}/db/multiline_venue_income.sql"
printf '%s\n' \
  '# Historical strategy-debugger-cli decision' \
  >"${fixture}/docs/superpowers/plans/2026-08-26-debugger-history.md"

before="$(hash_fixture)"
output="$("${SCANNER}" "${fixture}" 2>&1)" \
  || fail "scanner rejected allowed or excluded content: ${output}"
after="$(hash_fixture)"

[[ -z "${output}" ]] \
  || fail "clean fixture produced output: ${output}"
[[ "${before}" == "${after}" ]] \
  || fail "scanner modified a clean fixture"

echo "first-party compatibility audit fixture: PASS"
