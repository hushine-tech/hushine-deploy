#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
SCRIPT="${ROOT}/scripts/smoke_hosted_runtime_coverage.sh"
HELPER="${ROOT}/scripts/smoke_hosted_runtime_coverage.go"

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
  '!resp.GetSupported() || !resp.GetOk() || len(resp.GetFailures()) != 0 || len(resp.GetDeclaredInputs()) == 0' \
  'grpcStatus.Code() != codes.AlreadyExists' \
  'end_runtime_active_session=blocked code=AlreadyExists' \
  'StopAction_STOP_ACTION_STOP_ONLY' \
  'terminal := waitSessionTerminal' \
  'runtime.GetRuntimeId() != strings.TrimSpace(*runtimeID)' \
  'runtime.GetSource() != "hosted"' \
  'runtime.GetCleanupStatus() != "succeeded"'; do
  require_literal "${HELPER}" "${literal}"
done
require_literal "${SCRIPT}" '"${SESSION_TWO_ID}" == "${SESSION_ONE_ID}"'

# The future event boundary captures Docker's slightly delayed destroy event;
# all three graceful lifecycle facts remain mandatory.
for literal in \
  'EVENT_UNTIL="$(( $(date +%s) + 2 ))"' \
  'select(.action == "kill" and .signal == "15")' \
  'select(.action == "die" and .exitCode == "0")' \
  'select(.action == "destroy")'; do
  require_literal "${SCRIPT}" "${literal}"
done

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
trap 'rm -f "${relative_output}"' EXIT
if USER_ID=127 "${SCRIPT}" relative/path >"${relative_output}" 2>&1; then
  fail "relative output path was accepted"
fi
grep -Fq 'output directory must be absolute' "${relative_output}" \
  || fail "relative output rejection was not explicit"

echo 'hosted runtime coverage smoke contract: PASS'
