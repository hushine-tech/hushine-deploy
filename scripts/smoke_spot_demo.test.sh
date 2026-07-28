#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
SCRIPT="${ROOT}/scripts/smoke_spot_demo.sh"
HELPER="${ROOT}/scripts/smoke_hosted_runtime_coverage.go"
HELPER_TEST="${ROOT}/scripts/smoke_hosted_runtime_coverage_test.go"
OBSERVER="${ROOT}/scripts/acceptance/observe_spot_demo.py"
FAKE_SERVER="${ROOT}/scripts/fixtures/spot_demo_fake_server.py"
COVERAGE_LIB="${ROOT}/scripts/lib/runtime_coverage.sh"

fail() {
  echo "Spot Demo smoke contract failed: $*" >&2
  exit 1
}

require_literal() {
  local file="$1" literal="$2"
  grep -Fq -- "${literal}" "${file}" || fail "missing ${literal} in $(basename "${file}")"
}

test -x "${SCRIPT}" || fail "smoke script is missing or not executable"
test -f "${HELPER}" || fail "shared Runtime smoke helper is missing"
test -f "${HELPER_TEST}" || fail "shared Runtime smoke helper tests are missing"
test -x "${OBSERVER}" || fail "exchange observer is missing"
test -x "${FAKE_SERVER}" || fail "official-shape fake exchange is missing"
test -f "${COVERAGE_LIB}" || fail "shared runtime coverage library is missing"
bash -n "${SCRIPT}"

for literal in \
  'set -euo pipefail' \
  'source "${DEPLOY_ROOT}/scripts/lib/runtime_coverage.sh"' \
  'VENUE_ID' \
  'SPOT_DEMO_RUN_ID' \
  'SPOT_DEMO_EVIDENCE_FILE' \
  'SPOT_DEMO_OBSERVER_SESSION_FD' \
  'credential environment is forbidden' \
  'runtime environment contains a Binance credential variable' \
  'sleep 0.5' \
  'evidence wait timed out after' \
  '--validate-evidence' \
  '-action spot-preview' \
  '-action baseline' \
  '-action run' \
  '-action verify' \
  '-action stop-only' \
  '-action stop-close' \
  'runtime_coverage_stage_locked_inputs' \
  'runtime_coverage_require_finalization' \
  'runtime_coverage_generate_reports'; do
  require_literal "${SCRIPT}" "${literal}"
done
require_literal "${SCRIPT}" 'runtime_coverage_resolve_uv_bin'
require_literal "${COVERAGE_LIB}" '${HOME}/.local/bin/uv'

if grep -Fq 'set -x' "${SCRIPT}"; then
  fail "smoke must never enable shell tracing"
fi
if grep -Fq 'exec {SPOT_DEMO_OBSERVER_SESSION_FD}>&- 2>/dev/null' "${SCRIPT}"; then
  fail "closing the observer FD must not permanently redirect shell stderr"
fi
if rg -n 'PYTHONPATH=' "${SCRIPT}" >/dev/null; then
  fail "production Spot Demo smoke must use the frozen installed environment"
fi
if grep -Fq '/Users/xdy/.local/bin/uv' "${SCRIPT}"; then
  fail "production Spot Demo smoke contains a machine-specific uv path"
fi

for literal in \
  'profile == "demo"' \
  'BTCUSDT' \
  'ETHUSDT' \
  'perpetual_futures' \
  'executed quantity' \
  'cumulative quote quantity' \
  'exchange trade ID' \
  'commission asset' \
  'reconciliation hard pass' \
  'undeclared Spot asset changed' \
  'Futures wallet changed'; do
  require_literal "${HELPER}" "${literal}"
done

# The fake exchange is executed here (not merely grepped) and must reach an
# acknowledged signed WebSocket API subscription without a retired listenKey.
tmp="$(mktemp -d)"
tmp="$(cd -- "${tmp}" && pwd -P)"
server_pid=''
observer_pid=''
cleanup() {
  if [[ -n "${observer_pid}" ]]; then
    kill "${observer_pid}" 2>/dev/null || true
    wait "${observer_pid}" 2>/dev/null || true
  fi
  if [[ -n "${server_pid}" ]]; then
    kill "${server_pid}" 2>/dev/null || true
    wait "${server_pid}" 2>/dev/null || true
  fi
  rm -rf -- "${tmp}"
}
trap cleanup EXIT INT TERM

export NO_PROXY="127.0.0.1,localhost"
export no_proxy="${NO_PROXY}"
state_file="${tmp}/server.json"
python3 "${FAKE_SERVER}" --port 0 --scenario success --state-file "${state_file}" \
  >"${tmp}/server.out" 2>"${tmp}/server.err" &
server_pid=$!
for _ in $(seq 1 100); do
  [[ -s "${state_file}" ]] && break
  sleep 0.05
done
[[ -s "${state_file}" ]] || fail "fake exchange did not become ready"
port="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["port"])' "${state_file}")"

coverage_root="${tmp}/observer-coverage"
mkdir -m 0700 "${coverage_root}"
handoff="${tmp}/handoff.fifo"
mkfifo -m 0600 "${handoff}"
HUSHINE_SPOT_DEMO_HTTP_BASE="http://127.0.0.1:${port}" \
HUSHINE_SPOT_DEMO_WS_URL="ws://127.0.0.1:${port}/ws-api/v3" \
  python3 "${OBSERVER}" \
    --run-id smoke-contract --user-id 7 --portfolio-id 11 --venue-id 13 \
    --coverage-root "${coverage_root}" --credential-fd 3 --timeout-seconds 5 \
    3< <(printf '%s\n' '{"api_key":"demo-key","api_secret":"demo-secret"}') \
    <"${handoff}" >"${tmp}/observer.out" 2>"${tmp}/observer.err" &
observer_pid=$!
printf '%s\n' '{"run_id":"smoke-contract","session_id":"session-contract"}' >"${handoff}"
wait "${observer_pid}" || fail "observer failed against the executed fake exchange"
observer_pid=''

python3 "${OBSERVER}" \
  --validate-evidence "${coverage_root}/exchange-evidence.json" --session-id session-contract \
  --run-id smoke-contract --user-id 7 --portfolio-id 11 --venue-id 13 \
  --coverage-root "${coverage_root}" >/dev/null
python3 - "${state_file}" <<'PY'
import json, sys
state = json.load(open(sys.argv[1]))
assert state["subscription_method"] == "userDataStream.subscribe.signature"
assert state["credential_header_seen"] is True
assert not any(item["path"] == "/api/v3/userDataStream" for item in state["requests"])
PY

kill "${server_pid}" 2>/dev/null || true
wait "${server_pid}" 2>/dev/null || true
server_pid=''

# Drive the complete smoke script through its public process/FD boundary. The
# service frontends are deterministic fakes, while evidence still comes from
# the executable official-shape exchange and the real observer/validator.
behavior_root="${tmp}/full-smoke"
fake_source="${behavior_root}/source"
fake_bin="${behavior_root}/bin"
expected_library_commit=0123456789abcdef0123456789abcdef01234567
mkdir -p \
  "${fake_bin}" \
  "${fake_source}/control-panel-service" \
  "${fake_source}/strategy-service" \
  "${fake_source}/strategy-library" \
  "${fake_source}/strategy-debugger-cli/scripts"
cat >"${fake_source}/strategy-debugger-cli/pyproject.toml" <<EOF
dependencies = [
  { git = "https://github.com/hushine-tech/strategy-library.git", rev = "${expected_library_commit}" },
]
EOF

cat >"${behavior_root}/fake-helper" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
action=''
report_root=''
while [[ "$#" -gt 0 ]]; do
  case "$1" in
    -action) action="$2"; shift 2 ;;
    -report-root) report_root="$2"; shift 2 ;;
    *) shift ;;
  esac
done
printf '%s\n' "${action}" >>"${TEST_ACTION_LOG}"
case "${action}" in
  spot-preview)
    echo 'profile=demo ready=true inputs=3 targets=2 routes=3'
    ;;
  baseline)
    printf '%s\n' '{"spot":{"BTC":{"free":"0"},"ETH":{"free":"0"},"USDT":{"free":"1000"}},"futures":{}}'
    ;;
  run)
    count=0
    if [[ -f "${TEST_RUN_COUNTER}" ]]; then
      count="$(cat "${TEST_RUN_COUNTER}")"
    fi
    count="$((count + 1))"
    printf '%s\n' "${count}" >"${TEST_RUN_COUNTER}"
    printf 'runtime_id=rt-spot session_id=session-spot-%s\n' "${count}"
    ;;
  verify)
    if [[ "${TEST_SCENARIO}" == 'reconciliation' ]]; then
      echo 'reconciliation hard pass mismatch' >&2
      exit 42
    fi
    echo 'spot_demo_exact_match=true reconciliation=hard_pass'
    ;;
  stop-only)
    echo 'session_status=stopped close_results=0'
    ;;
  stop-close)
    echo 'session_status=stopped close_results=2 reconciliation=hard_pass'
    ;;
  stop-running)
    echo 'running_sessions_stopped=1'
    ;;
  end)
    : >"${TEST_ENDED_FILE}"
    echo 'runtime_id=rt-spot status=cancelled cleanup_status=succeeded'
    ;;
  stage-coverage)
    [[ -n "${report_root}" ]]
    mkdir -m 0700 -p "${report_root}/python-input"
    printf 'coverage-sqlite-fixture\n' >"${report_root}/python-input/.coverage"
    ;;
  *)
    echo "unexpected helper action: ${action}" >&2
    exit 90
    ;;
esac
EOF
chmod +x "${behavior_root}/fake-helper"

cat >"${fake_bin}/go" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" == 'build' ]]; then
  output=''
  while [[ "$#" -gt 0 ]]; do
    case "$1" in
      -o) output="$2"; shift 2 ;;
      *) shift ;;
    esac
  done
  cp "${TEST_FAKE_HELPER}" "${output}"
  chmod +x "${output}"
  exit 0
fi
if [[ "$*" == *'smoke_ensure_runtime.go'* ]]; then
  echo 'runtime_id=rt-spot provisioned=true'
  exit 0
fi
if [[ "${1:-}" == 'tool' && "${2:-}" == 'covdata' ]]; then
  output=''
  for argument in "$@"; do
    case "${argument}" in -o=*) output="${argument#-o=}" ;; esac
  done
  [[ -n "${output}" ]]
  if [[ "${3:-}" == 'merge' ]]; then
    mkdir -p "${output}"
    printf 'merged\n' >"${output}/covmeta.fixture"
  else
    printf 'mode: atomic\nfixture.go:1.1,1.2 1 1\n' >"${output}"
  fi
  exit 0
fi
if [[ "${1:-}" == 'tool' && "${2:-}" == 'cover' ]]; then
  echo 'total: (statements) 100.0%'
  exit 0
fi
echo "unexpected go invocation: $*" >&2
exit 91
EOF

cat >"${fake_bin}/docker" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-} ${2:-}" == 'image inspect' ]]; then
  echo 'sha256:spot-test-image'
  exit 0
fi
if [[ "${1:-} ${2:-}" == 'container inspect' ]]; then
  if [[ -e "${TEST_ENDED_FILE}" ]]; then
    exit 1
  fi
  if [[ "$*" == *'--format'* ]]; then
    case "$*" in
      *coverage_run_id*) echo "${TEST_RUN_ID}" ;;
      *runtime_id*) echo 'rt-spot' ;;
      *user_id*) echo '7' ;;
      *'hushine.runtime.coverage"'*) echo 'true' ;;
      *'.Image'*) echo 'sha256:spot-test-image' ;;
      *'.Id'*) echo 'container-spot' ;;
      *) exit 92 ;;
    esac
  else
    if [[ "${TEST_RUNTIME_ENV_SECRET}" == '1' ]]; then
      printf '[{"Mounts":[{"Destination":"/coverage","Source":"%s"}],"Config":{"Env":["GOCOVERDIR=/coverage/go","HUSHINE_RUNTIME_COVERAGE_DIR=/coverage/python","BINANCE_API_KEY=forbidden"]}}]\n' "${TEST_RUNTIME_ROOT}"
    else
      printf '[{"Mounts":[{"Destination":"/coverage","Source":"%s"}],"Config":{"Env":["GOCOVERDIR=/coverage/go","HUSHINE_RUNTIME_COVERAGE_DIR=/coverage/python"]}}]\n' "${TEST_RUNTIME_ROOT}"
    fi
  fi
  exit 0
fi
if [[ "${1:-}" == 'stop' || "${1:-} ${2:-}" == 'rm -f' ]]; then
  exit 0
fi
echo "unexpected docker invocation: $*" >&2
exit 93
EOF

cat >"${fake_bin}/uv" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ "$*" == *'coverage combine'* ]]; then
  exit 0
fi
if [[ "$*" == *'coverage report'* ]]; then
  echo 'TOTAL 1 0 100%'
  exit 0
fi
if [[ "$*" == *'coverage json'* ]]; then
  output=''
  while [[ "$#" -gt 0 ]]; do
    case "$1" in
      -o) output="$2"; shift 2 ;;
      *) shift ;;
    esac
  done
  printf '%s\n' '{"meta":{"version":"fixture"},"files":{},"totals":{"covered_lines":1,"num_statements":1,"percent_covered":100}}' >"${output}"
  exit 0
fi
echo "unexpected uv invocation: $*" >&2
exit 94
EOF

cat >"${fake_source}/strategy-debugger-cli/scripts/with-local-strategy-library-git.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
[[ "$#" -ge 4 ]]
[[ "$1" == "${TEST_EXPECTED_LIBRARY_SOURCE}" ]]
[[ "$2" == "${TEST_EXPECTED_LIBRARY_COMMIT}" ]]
[[ "$3" == "${TEST_EXPECTED_UV_BIN}" ]]
printf 'offline-wrapper\n' >>"${TEST_OFFLINE_LOG}"
EOF
chmod +x \
  "${fake_bin}/go" \
  "${fake_bin}/docker" \
  "${fake_bin}/uv" \
  "${fake_source}/strategy-debugger-cli/scripts/with-local-strategy-library-git.sh"

cat >"${behavior_root}/publish-evidence.py" <<'PY'
#!/usr/bin/env python3
import hashlib
import json
import os
import sys

template, output, scenario, run_id = sys.argv[1:]
handoff = json.loads(sys.stdin.readline())
if handoff.get("run_id") != run_id:
    raise SystemExit("run mismatch")
with open(template, encoding="utf-8") as handle:
    value = json.load(handle)
value.update(
    run_id=run_id,
    user_id=7,
    portfolio_id=11,
    venue_id=13,
    session_id=str(handoff["session_id"]),
    complete=(scenario != "incomplete"),
)
value.pop("canonical_payload_sha256", None)
canonical = json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode()
value["canonical_payload_sha256"] = hashlib.sha256(canonical).hexdigest()
if scenario == "hash":
    value["orders"][0]["executedQty"] = "9.99900000"
temporary = output + ".publisher-tmp"
flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL
descriptor = os.open(temporary, flags, 0o600)
with os.fdopen(descriptor, "w", encoding="utf-8") as handle:
    json.dump(value, handle, sort_keys=True, separators=(",", ":"))
    handle.flush()
    os.fsync(handle.fileno())
if scenario == "ownership":
    os.chmod(temporary, 0o644)
os.replace(temporary, output)
PY
chmod +x "${behavior_root}/publish-evidence.py"

original_path="${PATH}"
active_exchange_pid=''
active_observer_pid=''
active_publisher_pid=''
stop_active_processes() {
  local pid
  for pid in "${active_observer_pid}" "${active_publisher_pid}" "${active_exchange_pid}"; do
    if [[ -n "${pid}" ]]; then
      kill "${pid}" 2>/dev/null || true
      wait "${pid}" 2>/dev/null || true
    fi
  done
  active_exchange_pid=''
  active_observer_pid=''
  active_publisher_pid=''
}

prepare_smoke_case() {
  local run_id="$1"
  case_root="${behavior_root}/${run_id}"
  coverage_root="${case_root}/${run_id}"
  runtime_root="${coverage_root}/runtimes/rt-spot"
  evidence_file="${coverage_root}/exchange-evidence.json"
  action_log="${case_root}/actions.log"
  offline_log="${case_root}/offline.log"
  ended_file="${case_root}/ended"
  run_counter="${case_root}/run-counter"
  rm -rf -- "${case_root}"
  mkdir -m 0700 -p "${runtime_root}/go" "${runtime_root}/python"
  printf 'go-covdata-fixture\n' >"${runtime_root}/go/covmeta.fixture"
  printf 'python-coverage-fixture\n' >"${runtime_root}/python/.coverage.fixture"
  cat >"${runtime_root}/finalization.json" <<EOF
{"schema_version":1,"runtime_id":"rt-spot","boot_id":"boot-${run_id}","state":"complete","worker_shutdown":"ok","forced_workers":0,"go_snapshot":"ok","completed_at":"2026-07-23T00:00:00Z"}
EOF
}

run_smoke() {
  local run_id="$1" descriptor="$2" scenario="$3" runtime_secret="${4:-0}" evidence_timeout="${5:-1}"
  env -i \
    PATH="${fake_bin}:${original_path}" \
    HOME="${HOME}" \
    TMPDIR="${TMPDIR:-/tmp}" \
    LANG="${LANG:-C}" \
    USER_ID=7 \
    PORTFOLIO_ID=11 \
    VENUE_ID=13 \
    SPOT_DEMO_RUN_ID="${run_id}" \
    SPOT_DEMO_EVIDENCE_FILE="${evidence_file}" \
    SPOT_DEMO_OBSERVER_SESSION_FD="${descriptor}" \
    SPOT_DEMO_EVIDENCE_TIMEOUT_SECONDS="${evidence_timeout}" \
    HUSHINE_SOURCE_ROOT="${fake_source}" \
    TEST_ACTION_LOG="${action_log}" \
    TEST_OFFLINE_LOG="${offline_log}" \
    TEST_EXPECTED_LIBRARY_SOURCE="${fake_source}/strategy-library" \
    TEST_EXPECTED_LIBRARY_COMMIT="${expected_library_commit}" \
    TEST_EXPECTED_UV_BIN="${fake_bin}/uv" \
    TEST_ENDED_FILE="${ended_file}" \
    TEST_RUN_COUNTER="${run_counter}" \
    TEST_RUNTIME_ROOT="${runtime_root}" \
    TEST_FAKE_HELPER="${behavior_root}/fake-helper" \
    TEST_RUN_ID="${run_id}" \
    TEST_SCENARIO="${scenario}" \
    TEST_RUNTIME_ENV_SECRET="${runtime_secret}" \
    "${SCRIPT}" "${coverage_root}"
}

start_fake_exchange() {
  local scenario="$1" run_id="$2" observer_timeout="${3:-1}"
  exchange_state="${case_root}/exchange-${scenario}.json"
  python3 "${FAKE_SERVER}" --port 0 --scenario "${scenario}" --state-file "${exchange_state}" \
    >"${case_root}/exchange-${scenario}.out" 2>"${case_root}/exchange-${scenario}.err" &
  active_exchange_pid=$!
  for _ in $(seq 1 100); do
    [[ -s "${exchange_state}" ]] && break
    kill -0 "${active_exchange_pid}" 2>/dev/null || fail "fake exchange ${scenario} exited before ready"
    sleep 0.05
  done
  [[ -s "${exchange_state}" ]] || fail "fake exchange ${scenario} did not become ready"
  exchange_port="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["port"])' "${exchange_state}")"
  handoff_fifo="${case_root}/handoff.fifo"
  mkfifo -m 0600 "${handoff_fifo}"
  env -i \
    PATH="${original_path}" \
    HOME="${HOME}" \
    TMPDIR="${TMPDIR:-/tmp}" \
    NO_PROXY=127.0.0.1,localhost \
    no_proxy=127.0.0.1,localhost \
    HUSHINE_SPOT_DEMO_HTTP_BASE="http://127.0.0.1:${exchange_port}" \
    HUSHINE_SPOT_DEMO_WS_URL="ws://127.0.0.1:${exchange_port}/ws-api/v3" \
    python3 "${OBSERVER}" \
      --run-id "${run_id}" --user-id 7 --portfolio-id 11 --venue-id 13 \
      --coverage-root "${coverage_root}" --credential-fd 3 --timeout-seconds "${observer_timeout}" \
      3< <(printf '%s\n' '{"api_key":"demo-key","api_secret":"demo-secret"}') \
      <"${handoff_fifo}" >"${case_root}/observer.out" 2>"${case_root}/observer.err" &
  active_observer_pid=$!
  exec {handoff_fd}>"${handoff_fifo}"
}

start_evidence_publisher() {
  local scenario="$1" run_id="$2" template="$3"
  handoff_fifo="${case_root}/publisher-handoff.fifo"
  mkfifo -m 0600 "${handoff_fifo}"
  env -i PATH="${original_path}" HOME="${HOME}" \
    python3 "${behavior_root}/publish-evidence.py" \
      "${template}" "${evidence_file}" "${scenario}" "${run_id}" \
      <"${handoff_fifo}" >"${case_root}/publisher.out" 2>"${case_root}/publisher.err" &
  active_publisher_pid=$!
  exec {handoff_fd}>"${handoff_fifo}"
}

# Success proves the complete action sequence, observer handoff, official
# evidence validation, two distinct Sessions, both stop modes, offline replay,
# graceful Runtime end, finalization, and both coverage report formats.
prepare_smoke_case smoke-success
start_fake_exchange success smoke-success 15
set +e
run_smoke smoke-success "${handoff_fd}" success 0 20 >"${case_root}/smoke.out" 2>"${case_root}/smoke.err"
smoke_status=$?
set -e
exec {handoff_fd}>&-
set +e
wait "${active_observer_pid}"
observer_status=$?
set -e
active_observer_pid=''
kill "${active_exchange_pid}" 2>/dev/null || true
wait "${active_exchange_pid}" 2>/dev/null || true
active_exchange_pid=''
if [[ "${smoke_status}" -ne 0 ]]; then
  fail "complete smoke fixture failed; stdout=$(tail -n 12 "${case_root}/smoke.out" | tr '\n' '|') stderr=$(tail -n 12 "${case_root}/smoke.err" | tr '\n' '|') observer=$(tail -n 12 "${case_root}/observer.err" | tr '\n' '|') files=$(find "${coverage_root}" -maxdepth 2 -type f -print | tr '\n' ',') actions=$(tr '\n' ',' <"${action_log}" 2>/dev/null || true)"
fi
[[ "${observer_status}" -eq 0 ]] || fail "observer failed during complete smoke fixture"
expected_actions=$'spot-preview\nbaseline\nrun\nverify\nstop-only\nrun\nstop-close\nend\nstage-coverage'
[[ "$(cat "${action_log}")" == "${expected_actions}" ]] \
  || fail "complete smoke action order is incorrect"
[[ "$(cat "${offline_log}")" == 'offline-wrapper' ]] \
  || fail "package-v2 offline replay was not executed"
for report in go.cover.out go-functions.txt python-report.txt python-coverage.json; do
  [[ -s "${coverage_root}/smoke-reports/rt-spot/${report}" ]] \
    || fail "complete smoke did not publish ${report}"
done
evidence_template="${behavior_root}/valid-evidence.json"
cp "${evidence_file}" "${evidence_template}"
chmod 0600 "${evidence_template}"

# A Runtime container carrying any Binance credential variable must fail before
# Session creation, then still stop discovered work before ending the Runtime.
prepare_smoke_case smoke-runtime-secret
exec {handoff_fd}>"${case_root}/unused-handoff"
set +e
run_smoke smoke-runtime-secret "${handoff_fd}" success 1 \
  >"${case_root}/smoke.out" 2>"${case_root}/smoke.err"
smoke_status=$?
set -e
exec {handoff_fd}>&-
[[ "${smoke_status}" -ne 0 ]] || fail "Runtime credential environment was accepted"
grep -Fq 'hosted runtime received forbidden internal environment names' "${case_root}/smoke.err" \
  || fail "Runtime credential rejection was not explicit at the shared isolation boundary"
[[ "$(cat "${action_log}")" == $'stop-running\nend' ]] \
  || fail "Runtime credential failure cleanup order is incorrect"

# Evidence ownership/hash/completeness are validated by the smoke itself, and a
# reconciliation mismatch from the core comparison is never downgraded.
for scenario in ownership hash incomplete reconciliation; do
  run_id="smoke-${scenario}"
  prepare_smoke_case "${run_id}"
  publisher_scenario="${scenario}"
  [[ "${scenario}" == 'reconciliation' ]] && publisher_scenario=success
  start_evidence_publisher "${publisher_scenario}" "${run_id}" "${evidence_template}"
  set +e
  run_smoke "${run_id}" "${handoff_fd}" "${scenario}" \
    >"${case_root}/smoke.out" 2>"${case_root}/smoke.err"
  smoke_status=$?
  set -e
  exec {handoff_fd}>&-
  wait "${active_publisher_pid}" || fail "evidence publisher ${scenario} failed"
  active_publisher_pid=''
  [[ "${smoke_status}" -ne 0 ]] || fail "${scenario} failure was accepted"
  case "${scenario}" in
    ownership) grep -Fq 'ownership, mode, or link count is invalid' "${case_root}/smoke.err" ;;
    hash) grep -Fq 'canonical hash does not match' "${case_root}/smoke.err" ;;
    incomplete) grep -Fq 'not a complete schema-v1 artifact' "${case_root}/smoke.err" ;;
    reconciliation) grep -Fq 'reconciliation hard pass mismatch' "${case_root}/smoke.err" ;;
  esac || fail "${scenario} failure was not propagated exactly: $(tail -n 8 "${case_root}/smoke.err" | tr '\n' '|')"
  tail_actions="$(tail -n 2 "${action_log}")"
  [[ "${tail_actions}" == $'stop-running\nend' ]] \
    || fail "${scenario} cleanup did not stop Sessions before EndRuntime"
done

# Every official-shape exchange failure prevents evidence publication and
# causes the complete smoke to fail within its bounded evidence wait.
for scenario in subscription 429 5xx schema permission timeout; do
  run_id="smoke-${scenario}"
  prepare_smoke_case "${run_id}"
  start_fake_exchange "${scenario}" "${run_id}"
  set +e
  run_smoke "${run_id}" "${handoff_fd}" success \
    >"${case_root}/smoke.out" 2>"${case_root}/smoke.err"
  smoke_status=$?
  set -e
  exec {handoff_fd}>&-
  set +e
  wait "${active_observer_pid}"
  observer_status=$?
  set -e
  active_observer_pid=''
  kill "${active_exchange_pid}" 2>/dev/null || true
  wait "${active_exchange_pid}" 2>/dev/null || true
  active_exchange_pid=''
  [[ "${observer_status}" -ne 0 ]] || fail "observer ${scenario} fixture unexpectedly succeeded"
  [[ "${smoke_status}" -ne 0 ]] || fail "smoke ${scenario} fixture unexpectedly succeeded"
  grep -Fq 'evidence wait timed out after 1s' "${case_root}/smoke.err" \
    || fail "smoke ${scenario} failure was not bounded/propagated"
  [[ ! -e "${evidence_file}" && ! -e "${evidence_file}.tmp" ]] \
    || fail "smoke ${scenario} left incomplete exchange evidence"
done

stop_active_processes

(
  cd "${ROOT}/../control-panel-service"
  go test "${HELPER}" "${HELPER_TEST}" -count=1
)

echo "Spot Demo smoke contracts passed"
