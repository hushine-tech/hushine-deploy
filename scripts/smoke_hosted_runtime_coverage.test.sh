#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
SCRIPT="${ROOT}/scripts/smoke_hosted_runtime_coverage.sh"
HELPER="${ROOT}/scripts/smoke_hosted_runtime_coverage.go"
HELPER_TEST="${ROOT}/scripts/smoke_hosted_runtime_coverage_test.go"

fail() {
  echo "hosted runtime coverage smoke contract failed: $*" >&2
  exit 1
}

require_literal() {
  local file="$1"
  local literal="$2"
  grep -Fq -- "${literal}" "${file}" || fail "missing ${literal} in $(basename "${file}")"
}

forbid_literal() {
  local literal="$1"
  if grep -Fq -- "${literal}" "${SCRIPT}" "${HELPER}"; then
    fail "unsafe or obsolete literal present: ${literal}"
  fi
}

test -x "${SCRIPT}" || fail "smoke script is not executable"
test -f "${HELPER}" || fail "Go helper is missing"
test -f "${HELPER_TEST}" || fail "Go helper strict-status test is missing"
bash -n "${SCRIPT}"

# Coverage identity, trusted mount, and canonical path containment.
for literal in \
  'coverage_run_id' \
  'EXPECTED_RUN_LABEL' \
  'runtime_id has unsafe characters' \
  '[[ ! -d "${directory}" || -L "${directory}" ]]' \
  '[[ "${RUNTIME_ROOT}" != "${RUNTIMES_ROOT}/${RUNTIME_ID}" ]]' \
  '"${MOUNT_SOURCE}" != "${RUNTIME_ROOT}"'; do
  require_literal "${SCRIPT}" "${literal}"
done

# Fallback cleanup is allowed only for the exact labeled image/runtime/user.
for literal in \
  'owned_smoke_container() {' \
  'hushine.runtime.runtime_id' \
  'hushine.runtime.user_id' \
  'hushine.runtime.coverage' \
  '"${image_id}" == "${IMAGE_ID}"' \
  'refusing fallback cleanup: container ownership labels do not match smoke runtime' \
  'docker stop --time 10' \
  'docker rm -f'; do
  require_literal "${SCRIPT}" "${literal}"
done
for literal in \
  'local fallback_failed=0' \
  'fallback_failed=1' \
  'return "${fallback_failed}"'; do
  require_literal "${SCRIPT}" "${literal}"
done

# Preview, active-session rejection, worker recreation, and final runtime state
# are semantic assertions rather than RPC-success-only checks.
for literal in \
  '!previewReady(resp)' \
  'resp.GetProfile() == "backtest"' \
  'len(resp.GetDeclaredInputs()) == 1' \
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

# The finalization marker must attest one complete boot with no forced worker,
# and graceful lifecycle facts must occur in exact order.
for literal in \
  'FINALIZATION_FILE="${RUNTIME_ROOT}/finalization.json"' \
  '.schema_version == 1' \
  '.state == "complete"' \
  '.worker_shutdown == "ok"' \
  '.forced_workers == 0' \
  '.go_snapshot == "ok"'; do
  require_literal "${SCRIPT}" "${literal}"
done
for literal in \
  'EVENT_UNTIL="$(( $(date +%s) + 2 ))"' \
  'jq -s -e' \
  '["kill:15", "die:0", "destroy"]'; do
  require_literal "${SCRIPT}" "${literal}"
done

fixture_dir="$(mktemp -d)"
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

# Reports use locked project tooling and RPC failures expose only operation and
# status code, never server details that could contain credentials.
require_literal "${SCRIPT}" 'uv run --frozen --extra coverage coverage combine --keep'
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
