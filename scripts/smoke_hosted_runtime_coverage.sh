#!/usr/bin/env bash
# Provision a real hosted coverage runtime, exercise both one-shot and active
# Python workers, end it through control-panel, and prove both language outputs
# are mergeable.
set -euo pipefail

DEPLOY_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
source "${DEPLOY_ROOT}/scripts/lib/runtime_coverage.sh"
SOURCE_ROOT="${HUSHINE_SOURCE_ROOT:-${DEPLOY_ROOT}}"
if [[ ! -d "${SOURCE_ROOT}/strategy-service" && -d "${DEPLOY_ROOT}/../strategy-service" ]]; then
  SOURCE_ROOT="$(cd "${DEPLOY_ROOT}/.." && pwd -P)"
fi
if [[ ! -d "${SOURCE_ROOT}/strategy-service" || ! -d "${SOURCE_ROOT}/control-panel-service" ]]; then
  echo "cannot find service source tree under ${DEPLOY_ROOT} or ${DEPLOY_ROOT}/.." >&2
  exit 1
fi

if [[ "$#" -ne 1 ]]; then
  echo "usage: USER_ID=<users.id> $0 /absolute/runtime-coverage-output-dir" >&2
  exit 2
fi
runtime_coverage_prepare_output_root "$1"
OUTPUT_ROOT="${RUNTIME_COVERAGE_OUTPUT_ROOT}"

USER_ID="${USER_ID:-}"
PORTFOLIO_ID="${PORTFOLIO_ID:-0}"
PROFILE="${PROFILE:-small}"
CONTROL_PANEL_ADDR="${CONTROL_PANEL_ADDR:-127.0.0.1:50054}"
PORTFOLIO_ADDR="${PORTFOLIO_ADDR:-127.0.0.1:50051}"
COVERAGE_IMAGE="${COVERAGE_IMAGE:-hushine/strategy-runtime:executor-coverage}"
# Defaults match strategy-service/scripts/seed_test_data.py (2025-01-01,
# 200 one-minute fixture bars). Real-data runs can override both bounds.
START_TIME_MS="${START_TIME_MS:-1735689600000}"
END_TIME_MS="${END_TIME_MS:-1735701600000}"
EXPECTED_INPUT_COUNT="${EXPECTED_INPUT_COUNT:-4}"

if [[ ! "${USER_ID}" =~ ^[1-9][0-9]*$ ]]; then
  echo "USER_ID must be a positive integer" >&2
  exit 2
fi
if [[ ! "${PORTFOLIO_ID}" =~ ^[0-9]+$ ]]; then
  echo "PORTFOLIO_ID must be zero or a positive integer" >&2
  exit 2
fi
if [[ ! "${EXPECTED_INPUT_COUNT}" =~ ^[0-9]+$ ]]; then
  echo "EXPECTED_INPUT_COUNT must be zero or a positive integer" >&2
  exit 2
fi
for command in docker go jq; do
  if ! command -v "${command}" >/dev/null 2>&1; then
    echo "required command not found: ${command}" >&2
    exit 1
  fi
done
if ! UV_BIN="$(runtime_coverage_resolve_uv_bin)"; then
  echo "required command not found: uv" >&2
  exit 1
fi
export UV_BIN

IMAGE_ID="$(docker image inspect --format '{{.Id}}' "${COVERAGE_IMAGE}" 2>/dev/null || true)"
if [[ -z "${IMAGE_ID}" ]]; then
  echo "coverage image not found: ${COVERAGE_IMAGE}" >&2
  exit 1
fi

RUNTIME_ID=""
CONTAINER_NAME=""
CONTAINER_ID=""
RUNTIME_ENDED=0
SMOKE_WORK_ROOT=""
HELPER_BIN=""
EVENT_SINCE="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

end_runtime() {
  if [[ -z "${RUNTIME_ID}" || "${RUNTIME_ENDED}" -eq 1 ]]; then
    return 0
  fi
  if ! (
    cd "${SOURCE_ROOT}/control-panel-service"
    "${HELPER_BIN}" \
      -action end \
      -control-panel-addr "${CONTROL_PANEL_ADDR}" \
      -user "${USER_ID}" \
      -runtime "${RUNTIME_ID}" \
      -timeout 45s
  ); then
    return 1
  fi
  RUNTIME_ENDED=1
}

stop_running_sessions() {
  if [[ -z "${RUNTIME_ID}" || "${RUNTIME_ENDED}" -eq 1 ]]; then
    return 0
  fi
  (
    cd "${SOURCE_ROOT}/control-panel-service"
    "${HELPER_BIN}" \
      -action stop-running \
      -control-panel-addr "${CONTROL_PANEL_ADDR}" \
      -portfolio-addr "${PORTFOLIO_ADDR}" \
      -user "${USER_ID}" \
      -runtime "${RUNTIME_ID}" \
      -timeout 30s
  )
}

owned_smoke_container() {
  runtime_coverage_container_owned "${CONTAINER_NAME}" "${RUNTIME_ID}" "${USER_ID}" "${IMAGE_ID}"
}

fallback_cleanup_container() {
  local fallback_failed=0
  if ! docker container inspect "${CONTAINER_NAME}" >/dev/null 2>&1; then
    return 0
  fi
  if ! owned_smoke_container; then
    echo "refusing fallback cleanup: container ownership labels do not match smoke runtime" >&2
    return 1
  fi
  if ! docker stop --time 10 "${CONTAINER_NAME}" >/dev/null; then
    echo "fallback docker stop failed for owned smoke container" >&2
    fallback_failed=1
  fi
  if ! docker rm -f "${CONTAINER_NAME}" >/dev/null; then
    echo "fallback docker removal failed for owned smoke container" >&2
    fallback_failed=1
  fi
  return "${fallback_failed}"
}

cleanup_local_work() {
  if [[ -z "${SMOKE_WORK_ROOT}" ]]; then
    return 0
  fi
  if [[ ! -d "${SMOKE_WORK_ROOT}" || -L "${SMOKE_WORK_ROOT}" || "${HELPER_BIN}" != "${SMOKE_WORK_ROOT}/smoke-helper" ]]; then
    echo "refusing to remove unexpected smoke work root" >&2
    return 1
  fi
  rm -rf -- "${SMOKE_WORK_ROOT}"
  SMOKE_WORK_ROOT=""
  HELPER_BIN=""
}

cleanup() {
  local rc="$?"
  local cleanup_failed=0
  trap - EXIT
  if [[ -n "${RUNTIME_ID}" && "${RUNTIME_ENDED}" -eq 0 ]]; then
    echo "→ cleanup: stop running sessions for ${RUNTIME_ID}" >&2
    if ! stop_running_sessions >&2; then
      cleanup_failed=1
    fi
    echo "→ cleanup: EndRuntime ${RUNTIME_ID}" >&2
    if ! end_runtime >&2; then
      cleanup_failed=1
    fi
  fi
  if [[ -n "${CONTAINER_NAME}" ]] && docker container inspect "${CONTAINER_NAME}" >/dev/null 2>&1; then
    if ! fallback_cleanup_container; then
      cleanup_failed=1
    fi
  fi
  if ! cleanup_local_work; then
    cleanup_failed=1
  fi
  if [[ "${cleanup_failed}" -ne 0 ]]; then
    echo "cleanup failed; owned runtime may require operator intervention: ${RUNTIME_ID}" >&2
    if [[ "${rc}" -eq 0 ]]; then
      rc=1
    fi
  fi
  exit "${rc}"
}
trap cleanup EXIT

SMOKE_WORK_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/hushine-coverage-smoke.XXXXXX")"
chmod 0700 "${SMOKE_WORK_ROOT}"
HELPER_BIN="${SMOKE_WORK_ROOT}/smoke-helper"
(
  cd "${SOURCE_ROOT}/control-panel-service"
  go build -o "${HELPER_BIN}" "${DEPLOY_ROOT}/scripts/smoke_hosted_runtime_coverage.go"
)
chmod 0700 "${HELPER_BIN}"

SMOKE_NAME="coverage-smoke-$(date -u +%Y%m%d%H%M%S)-$$"
echo "→ EnsureHostedRuntime via ${CONTROL_PANEL_ADDR} image=${COVERAGE_IMAGE}"
set +e
ENSURE_OUTPUT="$({
  cd "${SOURCE_ROOT}/control-panel-service"
  go run scripts/smoke_ensure_runtime.go \
    -addr "${CONTROL_PANEL_ADDR}" \
    -user "${USER_ID}" \
    -profile "${PROFILE}" \
    -name "${SMOKE_NAME}" \
    -timeout 150s
} 2>&1)"
ENSURE_RC="$?"
set -e
if [[ "${ENSURE_RC}" -ne 0 ]]; then
  echo "EnsureHostedRuntime failed with exit ${ENSURE_RC}" >&2
  exit "${ENSURE_RC}"
fi
RUNTIME_ID="$(sed -n 's/.*runtime_id=\([^[:space:]]*\).*/\1/p' <<<"${ENSURE_OUTPUT}" | head -1)"
if [[ -z "${RUNTIME_ID}" || "${ENSURE_OUTPUT}" != *"provisioned=true"* ]]; then
  echo "EnsureHostedRuntime did not provision a unique runtime" >&2
  exit 1
fi
if [[ ! "${RUNTIME_ID}" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]; then
  echo "runtime_id has unsafe characters" >&2
  exit 1
fi
echo "runtime_id=${RUNTIME_ID} provisioned=true"

CONTAINER_NAME="hushine-runtime-${RUNTIME_ID}"
runtime_coverage_validate_layout "${OUTPUT_ROOT}" "${RUNTIME_ID}"
RUNTIMES_ROOT="${RUNTIME_COVERAGE_RUNTIMES_ROOT}"
RUNTIME_ROOT="${RUNTIME_COVERAGE_RUNTIME_ROOT}"
GO_DIR="${RUNTIME_COVERAGE_GO_DIR}"
PYTHON_DIR="${RUNTIME_COVERAGE_PYTHON_DIR}"
runtime_coverage_validate_container "${CONTAINER_NAME}" "${RUNTIME_ID}" "${USER_ID}" "${IMAGE_ID}" "${RUNTIME_ROOT}" "${OUTPUT_ROOT}"
CONTAINER_ID="${RUNTIME_COVERAGE_CONTAINER_ID}"
CONTAINER_IMAGE_ID="${RUNTIME_COVERAGE_CONTAINER_IMAGE_ID}"
RUN_LABEL="${RUNTIME_COVERAGE_RUN_LABEL}"
echo "container_id=${CONTAINER_ID} image_id=${CONTAINER_IMAGE_ID} coverage_label=true coverage_run_id=${RUN_LABEL}"

echo "→ PreviewRunStrategy through RuntimeChannel (one-shot Python worker)"
(
  cd "${SOURCE_ROOT}/control-panel-service"
  "${HELPER_BIN}" \
    -action preview \
    -control-panel-addr "${CONTROL_PANEL_ADDR}" \
    -portfolio-addr "${PORTFOLIO_ADDR}" \
    -user "${USER_ID}" \
    -runtime "${RUNTIME_ID}" \
    -portfolio "${PORTFOLIO_ID}" \
    -start-time-ms "${START_TIME_MS}" \
    -end-time-ms "${END_TIME_MS}" \
    -expected-input-count "${EXPECTED_INPUT_COUNT}" \
    -timeout 45s
)

echo "→ RunStrategy through RuntimeChannel (active Python session worker)"
RUN_ONE_OUTPUT="$({
  cd "${SOURCE_ROOT}/control-panel-service"
  "${HELPER_BIN}" \
    -action run \
    -control-panel-addr "${CONTROL_PANEL_ADDR}" \
    -portfolio-addr "${PORTFOLIO_ADDR}" \
    -user "${USER_ID}" \
    -runtime "${RUNTIME_ID}" \
    -portfolio "${PORTFOLIO_ID}" \
    -start-time-ms "${START_TIME_MS}" \
    -end-time-ms "${END_TIME_MS}" \
    -timeout 45s
})"
SESSION_ONE_ID="$(sed -n 's/.*session_id=\([^[:space:]]*\).*/\1/p' <<<"${RUN_ONE_OUTPUT}" | head -1)"
if [[ -z "${SESSION_ONE_ID}" ]]; then
  echo "RunStrategy returned no session_id" >&2
  exit 1
fi
echo "${RUN_ONE_OUTPUT}"

echo "→ assert EndRuntime rejects the active session"
(
  cd "${SOURCE_ROOT}/control-panel-service"
  "${HELPER_BIN}" \
    -action expect-end-blocked \
    -control-panel-addr "${CONTROL_PANEL_ADDR}" \
    -user "${USER_ID}" \
    -runtime "${RUNTIME_ID}" \
    -timeout 15s
)

echo "→ StopStrategy first active worker"
(
  cd "${SOURCE_ROOT}/control-panel-service"
  "${HELPER_BIN}" \
    -action stop \
    -control-panel-addr "${CONTROL_PANEL_ADDR}" \
    -portfolio-addr "${PORTFOLIO_ADDR}" \
    -user "${USER_ID}" \
    -runtime "${RUNTIME_ID}" \
    -session "${SESSION_ONE_ID}" \
    -timeout 45s
)

echo "→ RunStrategy again to prove worker recreation"
RUN_TWO_OUTPUT="$({
  cd "${SOURCE_ROOT}/control-panel-service"
  "${HELPER_BIN}" \
    -action run \
    -control-panel-addr "${CONTROL_PANEL_ADDR}" \
    -portfolio-addr "${PORTFOLIO_ADDR}" \
    -user "${USER_ID}" \
    -runtime "${RUNTIME_ID}" \
    -portfolio "${PORTFOLIO_ID}" \
    -start-time-ms "${START_TIME_MS}" \
    -end-time-ms "${END_TIME_MS}" \
    -timeout 45s
})"
SESSION_TWO_ID="$(sed -n 's/.*session_id=\([^[:space:]]*\).*/\1/p' <<<"${RUN_TWO_OUTPUT}" | head -1)"
if [[ -z "${SESSION_TWO_ID}" || "${SESSION_TWO_ID}" == "${SESSION_ONE_ID}" ]]; then
  echo "first and second session IDs differ check failed" >&2
  exit 1
fi
echo "${RUN_TWO_OUTPUT}"

echo "→ StopStrategy recreated worker"
(
  cd "${SOURCE_ROOT}/control-panel-service"
  "${HELPER_BIN}" \
    -action stop \
    -control-panel-addr "${CONTROL_PANEL_ADDR}" \
    -portfolio-addr "${PORTFOLIO_ADDR}" \
    -user "${USER_ID}" \
    -runtime "${RUNTIME_ID}" \
    -session "${SESSION_TWO_ID}" \
    -timeout 45s
)

echo "→ EndRuntime through control-panel"
end_runtime
for attempt in $(seq 1 30); do
  if ! docker container inspect "${CONTAINER_NAME}" >/dev/null 2>&1; then
    break
  fi
  if [[ "${attempt}" -eq 30 ]]; then
    echo "smoke container remains after EndRuntime: ${CONTAINER_NAME}" >&2
    exit 1
  fi
  sleep 1
done

echo "→ validate stopped runtime mount and stage Python coverage"
runtime_coverage_stage_locked_inputs "${HELPER_BIN}" "${SOURCE_ROOT}" "${OUTPUT_ROOT}" "${RUNTIME_ROOT}" "${RUNTIME_ID}"
REPORT_ROOT="${RUNTIME_COVERAGE_REPORT_ROOT}"
PYTHON_INPUT_DIR="${RUNTIME_COVERAGE_PYTHON_INPUT_DIR}"
runtime_coverage_require_finalization "${RUNTIME_ROOT}" "${RUNTIME_ID}"
FINALIZATION_FILE="${RUNTIME_COVERAGE_FINALIZATION_FILE}"

EVENTS_FILE="${REPORT_ROOT}/docker-events.jsonl"
# Docker can publish the destroy event just after container disappearance.
# A near-future Unix boundary lets the event stream include that final record.
EVENT_UNTIL="$(( $(date +%s) + 2 ))"
docker events --since "${EVENT_SINCE}" --until "${EVENT_UNTIL}" --filter "container=${CONTAINER_ID}" --format '{{json .}}' \
  | jq -c '{time:.time,action:.Action,id:.Actor.ID,image:(.Actor.Attributes.image // null),name:(.Actor.Attributes.name // null),runtime_id:(.Actor.Attributes["hushine.runtime.runtime_id"] // null),user_id:(.Actor.Attributes["hushine.runtime.user_id"] // null),coverage:(.Actor.Attributes["hushine.runtime.coverage"] // null),coverage_run_id:(.Actor.Attributes["hushine.runtime.coverage_run_id"] // null),signal:(.Actor.Attributes.signal // null),exitCode:(.Actor.Attributes.exitCode // null)}' \
  >"${EVENTS_FILE}"
if ! jq -s -e '
  [
    .[]
    | select(.action == "kill" or .action == "die" or .action == "destroy")
    | if .action == "kill" then "kill:\(.signal)"
      elif .action == "die" then "die:\(.exitCode)"
      else "destroy"
      end
  ] == ["kill:15", "die:0", "destroy"]
' "${EVENTS_FILE}" >/dev/null; then
  echo "graceful Docker lifecycle order is invalid" >&2
  exit 1
fi

runtime_coverage_generate_reports "${SOURCE_ROOT}" "${GO_DIR}" "${PYTHON_INPUT_DIR}" "${REPORT_ROOT}"

if ! cleanup_local_work; then
  exit 1
fi
trap - EXIT
echo "✓ hosted runtime coverage smoke completed"
echo "runtime_root=${RUNTIME_ROOT}"
echo "report_root=${REPORT_ROOT}"
echo "go_report=${REPORT_ROOT}/go.cover.out"
echo "python_report=${REPORT_ROOT}/python-coverage.json"
