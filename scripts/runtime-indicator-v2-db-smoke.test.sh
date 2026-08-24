#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
SOURCE_ROOT="$(cd "${ROOT}/.." && pwd -P)"

fail() {
  echo "runtime Indicator V2 DB smoke contract: $*" >&2
  exit 1
}

test_root="$(mktemp -d)"
trap 'rm -rf -- "${test_root}"' EXIT
chmod 0700 "${test_root}"

fake_bin="${test_root}/bin"
cmp_calls="${test_root}/cmp-calls.log"
go_calls="${test_root}/go-calls.log"
mkdir -p "${fake_bin}"

cat >"${fake_bin}/cmp" <<'FAKE_CMP'
#!/usr/bin/env bash
set -euo pipefail
printf '%s %s\n' "$(basename "$1")" "$(basename "$2")" >>"${CMP_CALLS}"
exit 0
FAKE_CMP

cat >"${fake_bin}/go" <<'FAKE_GO'
#!/usr/bin/env bash
set -euo pipefail

if [[ -n "${HUSHINE_INDICATOR_V2_DESTRUCTIVE_MODE:-}" \
  || -n "${HUSHINE_INDICATOR_V2_ACCEPTANCE_OWNER_FILE:-}" ]]; then
  echo "removed Indicator V2 cutover authorization environment was exported" >&2
  exit 95
fi

printf '%s\n' "$*" >>"${GO_CALLS}"
case "$*" in
  'test -tags=integration . -run ^TestPortfolioBaselineFreshBootstrapIsCompleteAndIdempotent$ -count=1 -v')
    if [[ "${HUSHINE_FAKE_GO_NO_TESTS:-0}" == "1" ]]; then
      printf '%s\n' \
        'testing: warning: no tests to run' \
        'PASS' \
        'ok  hushine/core-service/internal/storage/migrations  0.001s [no tests to run]'
      exit 0
    fi
    printf '%s\n' \
      '=== RUN   TestPortfolioBaselineFreshBootstrapIsCompleteAndIdempotent' \
      '--- PASS: TestPortfolioBaselineFreshBootstrapIsCompleteAndIdempotent (0.00s)' \
      'PASS' \
      'ok  hushine/core-service/internal/storage/migrations  0.001s'
    ;;
  'run ./cmd/ensure-portfolio-db')
    printf 'ensure-portfolio-db: OK (database %s + migrations)\n' \
      "${PGDATABASE_PORTFOLIO}"
    ;;
  *)
    echo "unexpected Go action: $*" >&2
    exit 96
    ;;
esac
FAKE_GO

cat >"${fake_bin}/psql" <<'FAKE_PSQL'
#!/usr/bin/env bash
set -euo pipefail

case "$*" in
  *'COMMENT ON DATABASE'*|*'strategy_indicator_definitions) + (SELECT count(*) FROM strategy_indicator_chunks)'*)
    echo "removed Indicator V1 upgrade action reached psql: $*" >&2
    exit 97
    ;;
  *values_json*)
    echo "removed Indicator V1 column guard reached psql: $*" >&2
    exit 98
    ;;
  *'SELECT EXISTS(SELECT 1 FROM pg_database'*)
    printf '%s\n' 'f'
    ;;
  *'SELECT md5('*|*protocol_version*)
    printf '%s\n' 't'
    ;;
esac
FAKE_PSQL

chmod 0700 "${fake_bin}/cmp" "${fake_bin}/go" "${fake_bin}/psql"

set +e
smoke_output="$({
  PATH="${fake_bin}:${PATH}" \
  CMP_CALLS="${cmp_calls}" \
  GO_CALLS="${go_calls}" \
  HUSHINE_SOURCE_ROOT="${SOURCE_ROOT}" \
    bash "${ROOT}/scripts/runtime-indicator-v2-db-smoke.sh"
} 2>&1)"
smoke_status="$?"
set -e

[[ "${smoke_status}" -eq 0 ]] \
  || fail "fresh-baseline smoke failed: ${smoke_output}"

expected_calls="${test_root}/expected-go-calls.log"
cat >"${expected_calls}" <<'EXPECTED_CALLS'
test -tags=integration . -run ^TestPortfolioBaselineFreshBootstrapIsCompleteAndIdempotent$ -count=1 -v
run ./cmd/ensure-portfolio-db
run ./cmd/ensure-portfolio-db
EXPECTED_CALLS

cmp "${expected_calls}" "${go_calls}" \
  || fail "database smoke did not execute only the fresh-baseline Go actions"
[[ "$(cat "${cmp_calls}")" == 'portfolio.sql portfolio.sql' ]] \
  || fail "database smoke compared bundles outside the Portfolio Indicator scope"
grep -Fq '✓ Runtime Indicator V2 database smoke passed' <<<"${smoke_output}" \
  || fail "database smoke did not report successful fresh-baseline completion"

set +e
no_tests_output="$({
  PATH="${fake_bin}:${PATH}" \
  CMP_CALLS="${cmp_calls}" \
  GO_CALLS="${go_calls}" \
  HUSHINE_FAKE_GO_NO_TESTS=1 \
  HUSHINE_SOURCE_ROOT="${SOURCE_ROOT}" \
    bash "${ROOT}/scripts/runtime-indicator-v2-db-smoke.sh"
} 2>&1)"
no_tests_status="$?"
set -e

[[ "${no_tests_status}" -ne 0 ]] \
  || fail "database smoke accepted an exit-zero Go transcript with no tests run: ${no_tests_output}"
grep -Fq \
  'TestPortfolioBaselineFreshBootstrapIsCompleteAndIdempotent did not run during mandatory DB smoke' \
  <<<"${no_tests_output}" \
  || fail "database smoke rejected the no-test transcript for the wrong reason: ${no_tests_output}"
