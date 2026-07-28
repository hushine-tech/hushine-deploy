#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
SCRIPT="${ROOT}/scripts/verify_spot_usdt.sh"

fail() {
  echo "verify Spot USDT contract failed: $*" >&2
  exit 1
}

test -x "${SCRIPT}" || fail "verifier is missing or not executable"
bash -n "${SCRIPT}"
grep -Fq 'set -euo pipefail' "${SCRIPT}" || fail "strict mode is required"
grep -Fq 'source "${DEPLOY_ROOT}/scripts/lib/runtime_coverage.sh"' "${SCRIPT}" \
  || fail "shared tool-path resolver is required"
if grep -Fq 'set -x' "${SCRIPT}"; then
  fail "verifier must never enable shell tracing"
fi

expected_scopes='backtest demo offline ui filters stop futures all-local release'
grep -Fq 'backtest|demo|offline|ui|filters|stop|futures|all-local|release' "${SCRIPT}" \
  || fail "exact nine-scope allow-list is missing"

tmp="$(mktemp -d)"
trap 'rm -rf -- "${tmp}"' EXIT
log="${tmp}/commands.log"

run_dry() {
  : >"${log}"
  HUSHINE_VERIFY_SPOT_DRY_RUN=1 HUSHINE_VERIFY_SPOT_COMMAND_LOG="${log}" \
    "${SCRIPT}" "$@"
}

assert_ordered_scopes() {
  local expected="$1"
  local actual
  actual="$(sed -n 's/^scope://p' "${log}" | paste -sd' ' -)"
  [[ "${actual}" == "${expected}" ]] || fail "scope order=${actual@Q}, want ${expected@Q}"
}

for scope in ${expected_scopes}; do
  if [[ "${scope}" == "demo" || "${scope}" == "release" ]]; then
    continue
  fi
  run_dry "${scope}"
done

run_dry backtest
source_root="$(cd "${ROOT}/.." && pwd -P)"
core_fixture="${source_root}/core-service/internal/order/risk/testdata/spot_filter_contract_v1.json"
grep -Fq -- "-check ${core_fixture}" "${log}" \
  || fail "backtest must pass the generator an absolute core fixture path"

run_dry filters
grep -Fq -- "-check ${core_fixture}" "${log}" \
  || fail "filters must pass the generator an absolute core fixture path"

run_dry all-local
assert_ordered_scopes 'all-local backtest offline ui filters stop futures'
if grep -Fxq 'scope:demo' "${log}"; then
  fail "all-local must never run Demo"
fi

fallback_home="${tmp}/fallback-home"
fallback_uv_log="${tmp}/fallback-uv.log"
mkdir -p "${fallback_home}/.local/bin"
cat >"${fallback_home}/.local/bin/uv" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"${FAKE_UV_LOG}"
EOF
chmod 0700 "${fallback_home}/.local/bin/uv"
go_bin_dir="$(dirname -- "$(command -v go)")"
GOCACHE="$(go env GOCACHE)" \
GOMODCACHE="$(go env GOMODCACHE)" \
HOME="${fallback_home}" \
PATH="${go_bin_dir}:/usr/local/bin:/usr/bin:/bin" \
FAKE_UV_LOG="${fallback_uv_log}" \
  "${SCRIPT}" backtest
grep -Fq 'run --frozen --extra dev pytest tests/test_spot_filter_contract.py tests/test_spot_end_to_end.py -q' \
  "${fallback_uv_log}" \
  || fail "verifier did not resolve uv from HOME/.local/bin"

for literal in \
  'go run ./cmd/generate-spot-filter-vectors -check' \
  "-run '^TestSpotFilterContract$'" \
  'require_go_test_exact' \
  'require_futures_pytest_collection' \
  'tests/test_spot_end_to_end.py' \
  'tests/test_spot_package_v2.py' \
  'tests/test_mixed_route_package_v2.py' \
  'scripts/with-local-strategy-library-git.sh' \
  'debugger-final-pin-check' \
  'scripts/spot-*.test.mjs' \
  'npm run build' \
  'TestSpotCloseOperationsMigrationContract' \
  'TestFuturesRuntimeChannelOrderAndStopProxyUnchanged'; do
  grep -Fq -- "${literal}" "${SCRIPT}" || fail "missing command mapping: ${literal}"
done

for invalid in all unknown ''; do
  : >"${log}"
  set +e
  HUSHINE_VERIFY_SPOT_DRY_RUN=1 HUSHINE_VERIFY_SPOT_COMMAND_LOG="${log}" \
    "${SCRIPT}" ${invalid:+"${invalid}"} >"${tmp}/invalid.out" 2>"${tmp}/invalid.err"
  status=$?
  set -e
  [[ "${status}" -ne 0 ]] || fail "invalid scope ${invalid@Q} was accepted"
  [[ ! -s "${log}" ]] || fail "invalid scope ${invalid@Q} started a subprocess"
done

coverage_root="${tmp}/coverage"
mkdir -m 0700 "${coverage_root}"
evidence_file="${coverage_root}/exchange-evidence.json"
: >"${log}"
set +e
HUSHINE_VERIFY_SPOT_DRY_RUN=1 HUSHINE_VERIFY_SPOT_COMMAND_LOG="${log}" \
  "${SCRIPT}" release "${coverage_root}" >"${tmp}/release.out" 2>"${tmp}/release.err"
status=$?
set -e
[[ "${status}" -ne 0 ]] || fail "release without Demo prerequisites was accepted"
grep -Fq 'BLOCKED_SPOT_DEMO_PREREQUISITE' "${tmp}/release.err" \
  || fail "release blocker is not stable"
[[ ! -s "${log}" ]] || fail "blocked release started local work"

exec 9>"${tmp}/observer-control"
: >"${log}"
USER_ID=7 PORTFOLIO_ID=11 VENUE_ID=13 \
SPOT_DEMO_RUN_ID=spot-demo-contract \
SPOT_DEMO_EVIDENCE_FILE="${evidence_file}" \
SPOT_DEMO_OBSERVER_SESSION_FD=9 \
HUSHINE_VERIFY_SPOT_DRY_RUN=1 HUSHINE_VERIFY_SPOT_COMMAND_LOG="${log}" \
  "${SCRIPT}" release "${coverage_root}"
exec 9>&-
assert_ordered_scopes 'release all-local backtest offline ui filters stop futures demo'

debugger_runs="$(grep -Fc 'scripts/with-local-strategy-library-git.sh' "${log}" || true)"
pin_checks="$(grep -Fc 'debugger-final-pin-check' "${log}" || true)"
[[ "${debugger_runs}" -gt 0 && "${pin_checks}" -ge "${debugger_runs}" ]] \
  || fail "every debugger subprocess must be followed by a final pin check"

echo "verify Spot USDT contracts passed"
