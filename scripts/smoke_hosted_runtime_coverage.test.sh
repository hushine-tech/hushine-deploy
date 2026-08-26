#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
SCRIPT="${ROOT}/scripts/smoke_hosted_runtime_coverage.sh"
HELPER="${ROOT}/scripts/smoke_hosted_runtime_coverage.go"
HELPER_TEST="${ROOT}/scripts/smoke_hosted_runtime_coverage_test.go"
COVERAGE_LIB="${ROOT}/scripts/lib/runtime_coverage.sh"

fail() {
  echo "hosted runtime coverage smoke contract failed: $*" >&2
  exit 1
}

require_literal() {
  local file="$1"
  local literal="$2"
  grep -Fq -- "${literal}" "${file}" || fail "missing ${literal} in $(basename "${file}")"
}

require_runtime_literal() {
  local literal="$1"
  grep -Fq -- "${literal}" "${SCRIPT}" "${COVERAGE_LIB}" \
    || fail "missing shared runtime coverage contract: ${literal}"
}

forbid_literal() {
  local literal="$1"
  if grep -Fq -- "${literal}" "${SCRIPT}" "${COVERAGE_LIB}" "${HELPER}"; then
    fail "unsafe or obsolete literal present: ${literal}"
  fi
}

test -x "${SCRIPT}" || fail "smoke script is not executable"
test -f "${HELPER}" || fail "Go helper is missing"
test -f "${HELPER_TEST}" || fail "Go helper strict-status test is missing"
test -f "${COVERAGE_LIB}" || fail "shared runtime coverage library is missing"
bash -n "${SCRIPT}"
bash -n "${COVERAGE_LIB}"
require_literal "${SCRIPT}" 'source "${DEPLOY_ROOT}/scripts/lib/runtime_coverage.sh"'
require_literal "${SCRIPT}" 'START_TIME_MS="${START_TIME_MS:-1735689600000}"'
require_literal "${SCRIPT}" 'END_TIME_MS="${END_TIME_MS:-1735701600000}"'
for literal in \
  'runtime_coverage_prepare_output_root() {' \
  'runtime_coverage_validate_layout() {' \
  'runtime_coverage_container_owned() {' \
  'runtime_coverage_reject_internal_env_names() {' \
  'runtime_coverage_stage_locked_inputs() {' \
  'runtime_coverage_require_finalization() {' \
  'runtime_coverage_require_python_hits() {' \
  'runtime_coverage_resolve_uv_bin() {' \
  'runtime_coverage_generate_reports() {'; do
  require_literal "${COVERAGE_LIB}" "${literal}"
done

# Coverage identity, trusted mount, and canonical path containment.
for literal in \
  'coverage_run_id' \
  'runtime_coverage_expected_run_label' \
  'runtime_id has unsafe characters' \
  '[[ ! -d "${directory}" || -L "${directory}" ]]' \
  '[[ "${runtime_root}" != "${runtimes_root}/${runtime_id}" ]]' \
  '"${mount_source}" != "${runtime_root}"'; do
  require_runtime_literal "${literal}"
done

# Fallback cleanup is allowed only for the exact labeled image/runtime/user.
for literal in \
  'owned_smoke_container() {' \
  'hushine.runtime.runtime_id' \
  'hushine.runtime.user_id' \
  'hushine.runtime.coverage' \
  '"${actual_image}" == "${image_id}"' \
  'refusing fallback cleanup: container ownership labels do not match smoke runtime' \
  'docker stop --time 10' \
  'docker rm -f'; do
  require_runtime_literal "${literal}"
done

# EXIT cleanup reconciles sessions that may exist even when RunStrategy's
# response was lost, and does so before attempting EndRuntime.
for literal in \
  'go build -o "${HELPER_BIN}"' \
  '"${HELPER_BIN}" \' \
  'echo "→ cleanup: stop running sessions for ${RUNTIME_ID}"' \
  '-action stop-running' \
  '-portfolio-addr "${PORTFOLIO_ADDR}"' \
  '-timeout 30s' \
  'echo "→ cleanup: EndRuntime ${RUNTIME_ID}"'; do
  require_literal "${SCRIPT}" "${literal}"
done
if grep -Fq -- 'go run "${DEPLOY_ROOT}/scripts/smoke_hosted_runtime_coverage.go"' "${SCRIPT}"; then
  fail "runtime cleanup helper must be prebuilt before provisioning"
fi
for literal in \
  'local fallback_failed=0' \
  'fallback_failed=1' \
  'return "${fallback_failed}"'; do
  require_literal "${SCRIPT}" "${literal}"
done

# Preview, active-session rejection, worker recreation, and final runtime state
# are semantic assertions rather than RPC-success-only checks.
for literal in \
  '!previewReady(resp, *expectedInputCount)' \
  'resp.GetProfile() != "backtest"' \
  'expectedInputCount > 0 && len(resp.GetDeclaredInputs()) != expectedInputCount' \
  'strings.ToLower(strings.TrimSpace(input.GetMarket()))' \
  'if _, duplicate := seen[key]; duplicate' \
  'grpcStatus.Code() != codes.AlreadyExists' \
  'end_runtime_active_session=blocked code=AlreadyExists' \
  'StopAction_STOP_ACTION_STOP_ONLY' \
  'terminal := waitSessionTerminal' \
  'return value == "stopped"' \
  'runtime.GetRuntimeId() != strings.TrimSpace(*runtimeID)' \
  'runtime.GetSource() != "hosted"' \
  'return strings.TrimSpace(value) == "cancelled"' \
  'runtime.GetCleanupStatus() != "succeeded"'; do
  require_literal "${HELPER}" "${literal}"
done
require_literal "${SCRIPT}" '"${SESSION_TWO_ID}" == "${SESSION_ONE_ID}"'
require_literal "${SCRIPT}" '-expected-input-count "${EXPECTED_INPUT_COUNT}"'
require_literal "${SCRIPT}" 'EXPECTED_INPUT_COUNT="${EXPECTED_INPUT_COUNT:-4}"'

# The finalization marker must attest one complete boot with no forced worker,
# and graceful lifecycle facts must occur in exact order.
for literal in \
  'finalization_file="${runtime_root}/finalization.json"' \
  '.schema_version == 1' \
  '.state == "complete"' \
  '.worker_shutdown == "ok"' \
  '.forced_workers == 0' \
  '.go_snapshot == "ok"'; do
  require_runtime_literal "${literal}"
done
for literal in \
  'EVENT_UNTIL="$(( $(date +%s) + 2 ))"' \
  'jq -s -e' \
  '["kill:15", "die:0", "destroy"]'; do
  require_literal "${SCRIPT}" "${literal}"
done

fixture_dir="$(mktemp -d)"
fixture_dir="$(cd -- "${fixture_dir}" && pwd -P)"
ordered_events="${fixture_dir}/ordered.jsonl"
unordered_events="${fixture_dir}/unordered.jsonl"
cat >"${ordered_events}" <<'EOF'
{"action":"kill","signal":"15","exitCode":null}
{"action":"die","signal":null,"exitCode":"0"}
{"action":"destroy","signal":null,"exitCode":null}
EOF
cat >"${unordered_events}" <<'EOF'
{"action":"die","signal":null,"exitCode":"0"}
{"action":"kill","signal":"15","exitCode":null}
{"action":"destroy","signal":null,"exitCode":null}
EOF
event_order_query='[
  .[]
  | select(.action == "kill" or .action == "die" or .action == "destroy")
  | if .action == "kill" then "kill:\(.signal)"
    elif .action == "die" then "die:\(.exitCode)"
    else "destroy"
    end
] == ["kill:15", "die:0", "destroy"]'
jq -s -e "${event_order_query}" "${ordered_events}" >/dev/null \
  || fail "ordered lifecycle fixture was rejected"
if jq -s -e "${event_order_query}" "${unordered_events}" >/dev/null; then
  fail "out-of-order lifecycle fixture was accepted"
fi

valid_finalization="${fixture_dir}/valid-finalization.json"
forced_finalization="${fixture_dir}/forced-finalization.json"
cat >"${valid_finalization}" <<'EOF'
{"schema_version":1,"runtime_id":"rt-1","boot_id":"boot-1","state":"complete","worker_shutdown":"ok","forced_workers":0,"go_snapshot":"ok","completed_at":"2026-07-12T00:00:00Z"}
EOF
cat >"${forced_finalization}" <<'EOF'
{"schema_version":1,"runtime_id":"rt-1","boot_id":"boot-1","state":"incomplete","worker_shutdown":"forced","forced_workers":1,"go_snapshot":"ok","completed_at":"2026-07-12T00:00:00Z"}
EOF
finalization_query='type == "object"
  and (keys == ["boot_id", "completed_at", "forced_workers", "go_snapshot", "runtime_id", "schema_version", "state", "worker_shutdown"])
  and .schema_version == 1
  and .runtime_id == "rt-1"
  and (.boot_id | type == "string" and length > 0)
  and .state == "complete"
  and .worker_shutdown == "ok"
  and .forced_workers == 0
  and .go_snapshot == "ok"
  and (.completed_at | type == "string" and length > 0)'
jq -e "${finalization_query}" "${valid_finalization}" >/dev/null \
  || fail "valid finalization fixture was rejected"
if jq -e "${finalization_query}" "${forced_finalization}" >/dev/null; then
  fail "forced finalization fixture was accepted"
fi

nonzero_python_coverage="${fixture_dir}/nonzero-python-coverage.json"
zero_python_coverage="${fixture_dir}/zero-python-coverage.json"
printf '%s\n' '{"totals":{"covered_lines":1}}' >"${nonzero_python_coverage}"
printf '%s\n' '{"totals":{"covered_lines":0}}' >"${zero_python_coverage}"
source "${COVERAGE_LIB}"
relative_uv_root="${fixture_dir}/relative-uv"
mkdir -p "${relative_uv_root}/tools"
cat >"${relative_uv_root}/tools/uv" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod 0700 "${relative_uv_root}/tools/uv"
(
  cd "${relative_uv_root}"
  UV_BIN=tools/uv
  resolved_uv="$(runtime_coverage_resolve_uv_bin)"
  [[ "${resolved_uv}" == "${relative_uv_root}/tools/uv" ]] \
    || fail "relative UV_BIN was not normalized to an absolute executable"
  cd /
  "${resolved_uv}" --version
)
(
  cd "${relative_uv_root}"
  unset UV_BIN
  UV=tools/uv
  HOME="${fixture_dir}/empty-home"
  PATH="/usr/bin:/bin"
  resolved_uv="$(runtime_coverage_resolve_uv_bin)"
  [[ "${resolved_uv}" == "${relative_uv_root}/tools/uv" ]] \
    || fail "relative UV override was not normalized to an absolute executable"
)
if UV_BIN="${fixture_dir}/missing-uv" \
  UV= \
  HOME="${fixture_dir}/empty-home" \
  PATH="/usr/bin:/bin" \
  runtime_coverage_resolve_uv_bin >/dev/null; then
  fail "missing explicit UV_BIN unexpectedly fell back to another executable"
fi
UV_BIN="$(runtime_coverage_resolve_uv_bin)" || fail "uv executable is unavailable"
export UV_BIN
runtime_coverage_require_python_hits "${nonzero_python_coverage}" \
  || fail "nonzero Python coverage was rejected"
if runtime_coverage_require_python_hits "${zero_python_coverage}"; then
  fail "zero-hit Python coverage was accepted"
fi

safe_runtime_env_names=$'GOCOVERDIR\nHUSHINE_RUNTIME_COVERAGE_DIR\nHUSHINE_RUNTIME_CORE_SERVICE_COMMIT\nHUSHINE_RUNTIME_GOLANG_LIB_COMMIT\nRUNTIME_CHANNEL_GRPC_ADDR\nRUNTIME_CREDENTIAL_JSON\nRUNTIME_CHANNEL_TLS_BUNDLE_JSON'
unsafe_runtime_env_names=$'RUNTIME_CHANNEL_GRPC_ADDR\nKAFKA_BROKERS\nDATABASE_PASSWORD\nORDER_SERVICE_GRPC_ADDR\nEXCHANGE_API_SECRET'
runtime_coverage_reject_internal_env_names "${safe_runtime_env_names}" \
  || fail "safe RuntimeChannel-only environment names were rejected"
if runtime_coverage_reject_internal_env_names "${unsafe_runtime_env_names}"; then
  fail "internal service or exchange secret environment names were accepted"
fi

# The container mount is treated as untrusted raw input after exit. Reports and
# combined Python input live in a host-only 0700 sibling tree, and the Go helper
# performs recursive special-file rejection plus identity-stable shard copies.
for literal in \
  'report_root="${output_root}/smoke-reports/${runtime_id}"' \
  '-action stage-coverage' \
  '-output-root "${output_root}"' \
  '-runtime-root "${runtime_root}"' \
  '-report-root "${report_root}"' \
  'RUNTIME_COVERAGE_PYTHON_INPUT_DIR="${report_root}/python-input"' \
  'COVERAGE_FILE="${python_input_dir}/.coverage"' \
  'uv_bin="$(runtime_coverage_resolve_uv_bin)"' \
  '"${uv_bin}" run --frozen --extra coverage coverage combine --keep "${python_input_dir}"'; do
  require_runtime_literal "${literal}"
done
for literal in \
  'stageRuntimeCoverage' \
  'filepath.WalkDir' \
  'os.Lstat' \
  'os.SameFile' \
  'unix.O_NOFOLLOW' \
  'coverageDebugExecutable(), "run", "--frozen", "--extra", "coverage", "coverage", "debug", "data"'; do
  require_literal "${HELPER}" "${literal}"
done

# RPC failures expose only operation and status code, never server details that
# could contain credentials.
require_literal "${HELPER}" 'fatalf("%s failed: code=%s", operation, grpcStatus.Code())'
for literal in \
  'StopAction_STOP_ACTION_CANCEL' \
  'grpcStatus.Message()' \
  'set -x' \
  'RUNTIME_CREDENTIAL_JSON' \
  'docker kill' \
  'uv run --with coverage coverage'; do
  forbid_literal "${literal}"
done
for literal in \
  'EVENTS_FILE="${RUNTIME_ROOT}/docker-events.jsonl"' \
  'GO_MERGED="${RUNTIME_ROOT}/go-merged"' \
  'PYTHON_RC="${RUNTIME_ROOT}/python-report.coveragerc"' \
  '>"${RUNTIME_ROOT}/python-report.txt"' \
  '-o "${RUNTIME_ROOT}/python-coverage.json"'; do
  if grep -Fq -- "${literal}" "${SCRIPT}"; then
    fail "smoke-owned report still targets the container mount: ${literal}"
  fi
done

# Execute the real EXIT trap with fake RPC/Docker frontends. The second
# RunStrategy creates a session but loses its response, so the script has no
# session ID to stop directly; cleanup must still discover/stop it before end.
cleanup_fixture="${fixture_dir}/cleanup-response-lost"
cleanup_bin="${cleanup_fixture}/bin"
cleanup_output="${cleanup_fixture}/run/coverage/runtime-agent"
cleanup_log="${cleanup_fixture}/actions.log"
cleanup_ended="${cleanup_fixture}/ended"
mkdir -p "${cleanup_bin}" "${cleanup_output}/runtimes/rt-response-lost/go" "${cleanup_output}/runtimes/rt-response-lost/python"
cat >"${cleanup_fixture}/fake-helper" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
action=''
timeout=''
while [[ "$#" -gt 0 ]]; do
  case "$1" in
    -action) action="$2"; shift 2 ;;
    -timeout) timeout="$2"; shift 2 ;;
    *) shift ;;
  esac
done
printf '%s:%s\n' "${action}" "${timeout}" >>"${TEST_ACTION_LOG}"
case "${action}" in
  preview) echo 'profile=backtest supported=true ok=true failure_count=0 declared_input_count=1' ;;
  run) exit 23 ;;
  stop-running) echo 'runtime_id=rt-response-lost running_sessions_stopped=1' ;;
  end)
    : >"${TEST_ENDED_FILE}"
    echo 'runtime_id=rt-response-lost status=cancelled source=hosted cleanup_status=succeeded'
    ;;
  *) exit 1 ;;
esac
EOF
chmod +x "${cleanup_fixture}/fake-helper"
cat >"${cleanup_bin}/go" <<'EOF'
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
if [[ "$*" == *"smoke_ensure_runtime.go"* ]]; then
  echo 'runtime_id=rt-response-lost provisioned=true'
  exit 0
fi
echo 'unexpected go invocation after helper prebuild' >&2
exit 91
EOF
cat >"${cleanup_bin}/docker" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ "$1 $2" == 'image inspect' ]]; then
  echo 'sha256:test-image'
  exit 0
fi
if [[ "$1 $2" != 'container inspect' ]]; then
  exit 1
fi
if [[ -e "${TEST_ENDED_FILE}" ]]; then
  exit 1
fi
if [[ "$*" == *'--format'* ]]; then
  case "$*" in
    *'.Id'*) echo 'container-response-lost' ;;
    *'.Image'*) echo 'sha256:test-image' ;;
    *'runtime_id'*) echo 'rt-response-lost' ;;
    *'user_id'*) echo '127' ;;
    *'coverage"'*) echo 'true' ;;
    *) exit 1 ;;
  esac
else
  echo '{}'
fi
EOF
cat >"${cleanup_bin}/jq" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
case "$*" in
  *Mounts*) echo "${TEST_RUNTIME_ROOT}" ;;
  *Config.Env*) printf '%s\n' GOCOVERDIR HUSHINE_RUNTIME_COVERAGE_DIR ;;
  *) exit 1 ;;
esac
EOF
cat >"${cleanup_bin}/uv" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
chmod +x "${cleanup_bin}/go" "${cleanup_bin}/docker" "${cleanup_bin}/jq" "${cleanup_bin}/uv"
set +e
PATH="${cleanup_bin}:${PATH}" \
TEST_ACTION_LOG="${cleanup_log}" \
TEST_ENDED_FILE="${cleanup_ended}" \
TEST_FAKE_HELPER="${cleanup_fixture}/fake-helper" \
TEST_RUNTIME_ROOT="${cleanup_output}/runtimes/rt-response-lost" \
USER_ID=127 \
HUSHINE_SOURCE_ROOT="${ROOT}/.." \
"${SCRIPT}" "${cleanup_output}" >"${cleanup_fixture}/stdout" 2>"${cleanup_fixture}/stderr"
cleanup_rc="$?"
set -e
if [[ "${cleanup_rc}" -eq 0 ]]; then
  fail "lost RunStrategy response fixture unexpectedly succeeded"
fi
cleanup_tail="$(tail -n 2 "${cleanup_log}")"
if [[ "${cleanup_tail}" != $'stop-running:30s\nend:45s' ]]; then
  fail "EXIT cleanup order/bounds were unexpected; want stop-running then end"
fi

# Real locked coverage data crosses the trust boundary only through the helper.
# A valid shard stages successfully; a symlink canary and malformed SQLite input
# both fail closed without modifying the external target.
strategy_root="${ROOT}/../strategy-service"
locked_fixture="${fixture_dir}/locked-coverage"
valid_output="${locked_fixture}/valid"
valid_runtime="${valid_output}/runtimes/rt-valid"
valid_report="${valid_output}/smoke-reports/rt-valid"
mkdir -p "${valid_runtime}/go" "${valid_runtime}/python"
(
  cd "${strategy_root}"
  "$(runtime_coverage_resolve_uv_bin)" run --frozen --extra coverage coverage run --parallel-mode \
    --data-file="${valid_runtime}/python/.coverage" \
    -m strategy_service.gen.strategy_service_pb2
)
(
  cd "${ROOT}/../control-panel-service"
  go run "${HELPER}" \
    -action stage-coverage \
    -output-root "${valid_output}" \
    -runtime-root "${valid_runtime}" \
    -report-root "${valid_report}" \
    -strategy-root "${strategy_root}" \
    -runtime rt-valid
)
find "${valid_report}/python-input" -maxdepth 1 -name '.coverage*' -type f -print -quit | grep -q . \
  || fail "valid locked shard was not staged"

symlink_output="${locked_fixture}/symlink"
symlink_runtime="${symlink_output}/runtimes/rt-symlink"
symlink_report="${symlink_output}/smoke-reports/rt-symlink"
canary="${locked_fixture}/outside-canary"
mkdir -p "${symlink_runtime}/go" "${symlink_runtime}/python"
printf 'unchanged\n' >"${canary}"
ln -s "${canary}" "${symlink_runtime}/python/.coverage.escape"
if (
  cd "${ROOT}/../control-panel-service"
  go run "${HELPER}" \
    -action stage-coverage \
    -output-root "${symlink_output}" \
    -runtime-root "${symlink_runtime}" \
    -report-root "${symlink_report}" \
    -strategy-root "${strategy_root}" \
    -runtime rt-symlink
); then
  fail "symlink coverage shard was accepted"
fi
[[ "$(cat "${canary}")" == 'unchanged' ]] || fail "symlink canary target was modified"

malformed_output="${locked_fixture}/malformed"
malformed_runtime="${malformed_output}/runtimes/rt-malformed"
malformed_report="${malformed_output}/smoke-reports/rt-malformed"
mkdir -p "${malformed_runtime}/go" "${malformed_runtime}/python"
printf 'not a coverage sqlite database\n' >"${malformed_runtime}/python/.coverage.bad"
if (
  cd "${ROOT}/../control-panel-service"
  go run "${HELPER}" \
    -action stage-coverage \
    -output-root "${malformed_output}" \
    -runtime-root "${malformed_runtime}" \
    -report-root "${malformed_report}" \
    -strategy-root "${strategy_root}" \
    -runtime rt-malformed
); then
  fail "malformed coverage shard was accepted"
fi
if [[ -e "${malformed_report}/python-input/.coverage" ]]; then
  fail "malformed retry fabricated a combined coverage database"
fi

relative_output="$(mktemp)"
trap 'rm -f "${relative_output}"; rm -rf "${fixture_dir}"' EXIT
if USER_ID=127 "${SCRIPT}" relative/path >"${relative_output}" 2>&1; then
  fail "relative output path was accepted"
fi
grep -Fq 'output directory must be absolute' "${relative_output}" \
  || fail "relative output rejection was not explicit"

(
  cd "${ROOT}/../control-panel-service"
  go test "${HELPER}" "${HELPER_TEST}"
)

echo 'hosted runtime coverage smoke contract: PASS'
