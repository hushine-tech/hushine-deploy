#!/usr/bin/env bash
# Run one credential-free Binance Spot Demo acceptance against an already
# provisioned Portfolio/Venue and an active deterministic strategy.
set -euo pipefail

DEPLOY_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
source "${DEPLOY_ROOT}/scripts/lib/runtime_coverage.sh"
SOURCE_ROOT="${HUSHINE_SOURCE_ROOT:-${DEPLOY_ROOT}}"
if [[ ! -d "${SOURCE_ROOT}/strategy-service" && -d "${DEPLOY_ROOT}/../strategy-service" ]]; then
  SOURCE_ROOT="$(cd -- "${DEPLOY_ROOT}/.." && pwd -P)"
fi
if [[ ! -d "${SOURCE_ROOT}/strategy-service" || ! -d "${SOURCE_ROOT}/control-panel-service" ]]; then
  echo "cannot find service source tree" >&2
  exit 1
fi

if [[ "$#" -ne 1 ]]; then
  echo "usage: USER_ID=... PORTFOLIO_ID=... VENUE_ID=... SPOT_DEMO_RUN_ID=... SPOT_DEMO_EVIDENCE_FILE=... SPOT_DEMO_OBSERVER_SESSION_FD=... $0 /absolute/runtime-coverage-output-dir" >&2
  exit 2
fi
runtime_coverage_prepare_output_root "$1"
OUTPUT_ROOT="${RUNTIME_COVERAGE_OUTPUT_ROOT}"

USER_ID="${USER_ID:-}"
PORTFOLIO_ID="${PORTFOLIO_ID:-}"
VENUE_ID="${VENUE_ID:-}"
SPOT_DEMO_RUN_ID="${SPOT_DEMO_RUN_ID:-}"
SPOT_DEMO_EVIDENCE_FILE="${SPOT_DEMO_EVIDENCE_FILE:-}"
SPOT_DEMO_OBSERVER_SESSION_FD="${SPOT_DEMO_OBSERVER_SESSION_FD:-}"
EVIDENCE_TIMEOUT_SECONDS="${SPOT_DEMO_EVIDENCE_TIMEOUT_SECONDS:-60}"
PROFILE="${PROFILE:-small}"
CONTROL_PANEL_ADDR="${CONTROL_PANEL_ADDR:-127.0.0.1:50054}"
PORTFOLIO_ADDR="${PORTFOLIO_ADDR:-127.0.0.1:50051}"
COVERAGE_IMAGE="${COVERAGE_IMAGE:-hushine/strategy-runtime:executor-coverage-spot-acceptance}"

for pair in "USER_ID:${USER_ID}" "PORTFOLIO_ID:${PORTFOLIO_ID}" "VENUE_ID:${VENUE_ID}"; do
  name="${pair%%:*}"
  value="${pair#*:}"
  if [[ ! "${value}" =~ ^[1-9][0-9]*$ ]]; then
    echo "${name} must be a positive integer" >&2
    exit 2
  fi
done
if [[ ! "${SPOT_DEMO_RUN_ID}" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]; then
  echo "SPOT_DEMO_RUN_ID contains unsafe characters" >&2
  exit 2
fi
if [[ ! "${SPOT_DEMO_OBSERVER_SESSION_FD}" =~ ^[0-9]+$ || "${SPOT_DEMO_OBSERVER_SESSION_FD}" -lt 3 ]]; then
  echo "SPOT_DEMO_OBSERVER_SESSION_FD must name an inherited descriptor >= 3" >&2
  exit 2
fi
if [[ ! -e "/dev/fd/${SPOT_DEMO_OBSERVER_SESSION_FD}" ]]; then
  echo "SPOT_DEMO_OBSERVER_SESSION_FD is not open" >&2
  exit 2
fi
if [[ ! "${EVIDENCE_TIMEOUT_SECONDS}" =~ ^[1-9][0-9]*$ || "${EVIDENCE_TIMEOUT_SECONDS}" -gt 60 ]]; then
  echo "SPOT_DEMO_EVIDENCE_TIMEOUT_SECONDS must be in [1,60]" >&2
  exit 2
fi
if [[ "${SPOT_DEMO_EVIDENCE_FILE}" != "${OUTPUT_ROOT}/exchange-evidence.json" ]]; then
  echo "SPOT_DEMO_EVIDENCE_FILE must be the canonical run-owned exchange artifact" >&2
  exit 2
fi
EXPECTED_RUN_LABEL="$(runtime_coverage_expected_run_label "${OUTPUT_ROOT}")"
if [[ "${EXPECTED_RUN_LABEL}" != "${SPOT_DEMO_RUN_ID}" ]]; then
  echo "coverage root ownership does not match SPOT_DEMO_RUN_ID" >&2
  exit 2
fi
if [[ -e "${SPOT_DEMO_EVIDENCE_FILE}" || -L "${SPOT_DEMO_EVIDENCE_FILE}" ]]; then
  echo "SPOT_DEMO_EVIDENCE_FILE already exists" >&2
  exit 2
fi

while IFS= read -r environment_name; do
  upper_name="$(tr '[:lower:]' '[:upper:]' <<<"${environment_name}")"
  case "${upper_name}" in
    *BINANCE*API*KEY*|*BINANCE*API*SECRET*|*BINANCE*KEY*|*BINANCE*SECRET*|SPOT_DEMO_API_KEY|SPOT_DEMO_API_SECRET)
      echo "credential environment is forbidden: ${environment_name}" >&2
      exit 2
      ;;
  esac
done < <(compgen -e)

for command in docker go jq python3 uv; do
  if ! command -v "${command}" >/dev/null 2>&1; then
    echo "required command not found: ${command}" >&2
    exit 1
  fi
done
IMAGE_ID="$(docker image inspect --format '{{.Id}}' "${COVERAGE_IMAGE}" 2>/dev/null || true)"
if [[ -z "${IMAGE_ID}" ]]; then
  echo "coverage image not found: ${COVERAGE_IMAGE}" >&2
  exit 1
fi

RUNTIME_ID=''
CONTAINER_NAME=''
RUNTIME_ENDED=0
HELPER_BIN=''
SMOKE_WORK_ROOT=''
OBSERVER_HANDOFF_CLOSED=0

close_observer_handoff() {
  if [[ "${OBSERVER_HANDOFF_CLOSED}" -eq 0 ]]; then
    exec {SPOT_DEMO_OBSERVER_SESSION_FD}>&-
    OBSERVER_HANDOFF_CLOSED=1
  fi
}

end_runtime() {
  if [[ -z "${RUNTIME_ID}" || "${RUNTIME_ENDED}" -eq 1 || -z "${HELPER_BIN}" ]]; then
    return 0
  fi
  if ! "${HELPER_BIN}" \
    -action end -control-panel-addr "${CONTROL_PANEL_ADDR}" \
    -user "${USER_ID}" -runtime "${RUNTIME_ID}" -timeout 45s; then
    return 1
  fi
  RUNTIME_ENDED=1
}

stop_running_sessions() {
  if [[ -z "${RUNTIME_ID}" || "${RUNTIME_ENDED}" -eq 1 || -z "${HELPER_BIN}" ]]; then
    return 0
  fi
  "${HELPER_BIN}" \
    -action stop-running -control-panel-addr "${CONTROL_PANEL_ADDR}" \
    -portfolio-addr "${PORTFOLIO_ADDR}" -user "${USER_ID}" \
    -runtime "${RUNTIME_ID}" -timeout 30s
}

fallback_cleanup_container() {
  if [[ -z "${CONTAINER_NAME}" ]] || ! docker container inspect "${CONTAINER_NAME}" >/dev/null 2>&1; then
    return 0
  fi
  if ! runtime_coverage_container_owned "${CONTAINER_NAME}" "${RUNTIME_ID}" "${USER_ID}" "${IMAGE_ID}"; then
    echo "refusing fallback cleanup: container ownership does not match Spot Demo run" >&2
    return 1
  fi
  local failed=0
  docker stop --time 10 "${CONTAINER_NAME}" >/dev/null || failed=1
  docker rm -f "${CONTAINER_NAME}" >/dev/null || failed=1
  return "${failed}"
}

cleanup_local_work() {
  if [[ -z "${SMOKE_WORK_ROOT}" ]]; then
    return 0
  fi
  if [[ ! -d "${SMOKE_WORK_ROOT}" || -L "${SMOKE_WORK_ROOT}" || "${HELPER_BIN}" != "${SMOKE_WORK_ROOT}/smoke-helper" ]]; then
    echo "refusing to remove unexpected Spot Demo work root" >&2
    return 1
  fi
  rm -rf -- "${SMOKE_WORK_ROOT}"
  SMOKE_WORK_ROOT=''
  HELPER_BIN=''
}

cleanup() {
  local rc="$?" cleanup_failed=0
  trap - EXIT
  close_observer_handoff
  if [[ -n "${RUNTIME_ID}" && "${RUNTIME_ENDED}" -eq 0 ]]; then
    stop_running_sessions >&2 || cleanup_failed=1
    end_runtime >&2 || cleanup_failed=1
  fi
  fallback_cleanup_container || cleanup_failed=1
  cleanup_local_work || cleanup_failed=1
  if [[ "${cleanup_failed}" -ne 0 && "${rc}" -eq 0 ]]; then
    rc=1
  fi
  exit "${rc}"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

SMOKE_WORK_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/hushine-spot-demo-smoke.XXXXXX")"
chmod 0700 "${SMOKE_WORK_ROOT}"
HELPER_BIN="${SMOKE_WORK_ROOT}/smoke-helper"
(
  cd "${SOURCE_ROOT}/control-panel-service"
  go build -o "${HELPER_BIN}" "${DEPLOY_ROOT}/scripts/smoke_hosted_runtime_coverage.go"
)
chmod 0700 "${HELPER_BIN}"

SMOKE_NAME="spot-demo-${SPOT_DEMO_RUN_ID}-$$"
set +e
ENSURE_OUTPUT="$({
  cd "${SOURCE_ROOT}/control-panel-service"
  go run scripts/smoke_ensure_runtime.go \
    -addr "${CONTROL_PANEL_ADDR}" -user "${USER_ID}" -profile "${PROFILE}" \
    -name "${SMOKE_NAME}" -timeout 150s
} 2>&1)"
ENSURE_RC="$?"
set -e
if [[ "${ENSURE_RC}" -ne 0 ]]; then
  echo "EnsureHostedRuntime failed with exit ${ENSURE_RC}" >&2
  exit "${ENSURE_RC}"
fi
RUNTIME_ID="$(sed -n 's/.*runtime_id=\([^[:space:]]*\).*/\1/p' <<<"${ENSURE_OUTPUT}" | head -1)"
if [[ -z "${RUNTIME_ID}" || "${ENSURE_OUTPUT}" != *"provisioned=true"* || ! "${RUNTIME_ID}" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]; then
  echo "EnsureHostedRuntime returned an invalid runtime identity" >&2
  exit 1
fi
CONTAINER_NAME="hushine-runtime-${RUNTIME_ID}"

runtime_coverage_validate_layout "${OUTPUT_ROOT}" "${RUNTIME_ID}"
RUNTIME_ROOT="${RUNTIME_COVERAGE_RUNTIME_ROOT}"
GO_DIR="${RUNTIME_COVERAGE_GO_DIR}"
runtime_coverage_validate_container "${CONTAINER_NAME}" "${RUNTIME_ID}" "${USER_ID}" "${IMAGE_ID}" "${RUNTIME_ROOT}" "${OUTPUT_ROOT}"
CONTAINER_ID="${RUNTIME_COVERAGE_CONTAINER_ID}"
while IFS= read -r runtime_environment_name; do
  upper_name="$(tr '[:lower:]' '[:upper:]' <<<"${runtime_environment_name}")"
  case "${upper_name}" in
    *BINANCE*API*KEY*|*BINANCE*API*SECRET*|*BINANCE*KEY*|*BINANCE*SECRET*)
      echo "runtime environment contains a Binance credential variable" >&2
      exit 1
      ;;
  esac
done <<<"${RUNTIME_COVERAGE_CONTAINER_ENV_NAMES}"
echo "runtime_id=${RUNTIME_ID} container_id=${CONTAINER_ID} coverage_run_id=${SPOT_DEMO_RUN_ID}"

"${HELPER_BIN}" \
  -action spot-preview -control-panel-addr "${CONTROL_PANEL_ADDR}" \
  -portfolio-addr "${PORTFOLIO_ADDR}" -user "${USER_ID}" \
  -runtime "${RUNTIME_ID}" -portfolio "${PORTFOLIO_ID}" -timeout 60s

BASELINE_FILE="${OUTPUT_ROOT}/spot-baseline-${RUNTIME_ID}.json"
if [[ -e "${BASELINE_FILE}" || -L "${BASELINE_FILE}" ]]; then
  echo "run-owned Spot baseline already exists" >&2
  exit 1
fi
umask 077
set -o noclobber
if ! "${HELPER_BIN}" \
  -action baseline -portfolio-addr "${PORTFOLIO_ADDR}" \
  -user "${USER_ID}" -runtime "${RUNTIME_ID}" \
  -portfolio "${PORTFOLIO_ID}" -venue "${VENUE_ID}" -timeout 60s \
  >"${BASELINE_FILE}"; then
  set +o noclobber
  exit 1
fi
set +o noclobber
chmod 0600 "${BASELINE_FILE}"

RUN_ONE_OUTPUT="$("${HELPER_BIN}" \
  -action run -control-panel-addr "${CONTROL_PANEL_ADDR}" \
  -portfolio-addr "${PORTFOLIO_ADDR}" -user "${USER_ID}" \
  -runtime "${RUNTIME_ID}" -portfolio "${PORTFOLIO_ID}" -timeout 60s)"
SESSION_ONE_ID="$(sed -n 's/.*session_id=\([^[:space:]]*\).*/\1/p' <<<"${RUN_ONE_OUTPUT}" | head -1)"
if [[ -z "${SESSION_ONE_ID}" || ! "${SESSION_ONE_ID}" =~ ^[A-Za-z0-9][A-Za-z0-9._:-]*$ ]]; then
  echo "RunStrategy returned an invalid Session identity" >&2
  exit 1
fi
printf '{"run_id":"%s","session_id":"%s"}\n' "${SPOT_DEMO_RUN_ID}" "${SESSION_ONE_ID}" >&"${SPOT_DEMO_OBSERVER_SESSION_FD}"
close_observer_handoff

evidence_ready=0
for _ in $(seq 1 "$((EVIDENCE_TIMEOUT_SECONDS * 2))"); do
  if [[ -f "${SPOT_DEMO_EVIDENCE_FILE}" && ! -L "${SPOT_DEMO_EVIDENCE_FILE}" ]]; then
    evidence_ready=1
    break
  fi
  sleep 0.5
done
if [[ "${evidence_ready}" -ne 1 ]]; then
  echo "evidence wait timed out after ${EVIDENCE_TIMEOUT_SECONDS}s" >&2
  exit 1
fi
python3 "${DEPLOY_ROOT}/scripts/acceptance/observe_spot_demo.py" \
  --validate-evidence "${SPOT_DEMO_EVIDENCE_FILE}" --session-id "${SESSION_ONE_ID}" \
  --run-id "${SPOT_DEMO_RUN_ID}" --user-id "${USER_ID}" \
  --portfolio-id "${PORTFOLIO_ID}" --venue-id "${VENUE_ID}" \
  --coverage-root "${OUTPUT_ROOT}"

"${HELPER_BIN}" \
  -action verify -portfolio-addr "${PORTFOLIO_ADDR}" \
  -user "${USER_ID}" -runtime "${RUNTIME_ID}" -portfolio "${PORTFOLIO_ID}" \
  -venue "${VENUE_ID}" -session "${SESSION_ONE_ID}" \
  -evidence-file "${SPOT_DEMO_EVIDENCE_FILE}" -baseline-file "${BASELINE_FILE}" \
  -timeout 60s

"${HELPER_BIN}" \
  -action stop-only -control-panel-addr "${CONTROL_PANEL_ADDR}" \
  -portfolio-addr "${PORTFOLIO_ADDR}" -user "${USER_ID}" \
  -runtime "${RUNTIME_ID}" -session "${SESSION_ONE_ID}" -timeout 60s

RUN_TWO_OUTPUT="$("${HELPER_BIN}" \
  -action run -control-panel-addr "${CONTROL_PANEL_ADDR}" \
  -portfolio-addr "${PORTFOLIO_ADDR}" -user "${USER_ID}" \
  -runtime "${RUNTIME_ID}" -portfolio "${PORTFOLIO_ID}" -timeout 60s)"
SESSION_TWO_ID="$(sed -n 's/.*session_id=\([^[:space:]]*\).*/\1/p' <<<"${RUN_TWO_OUTPUT}" | head -1)"
if [[ -z "${SESSION_TWO_ID}" || "${SESSION_TWO_ID}" == "${SESSION_ONE_ID}" ]]; then
  echo "worker recreation did not produce a new Session identity" >&2
  exit 1
fi
"${HELPER_BIN}" \
  -action stop-close -operation-id "spot-demo-close-${SPOT_DEMO_RUN_ID}" \
  -control-panel-addr "${CONTROL_PANEL_ADDR}" -portfolio-addr "${PORTFOLIO_ADDR}" \
  -user "${USER_ID}" -runtime "${RUNTIME_ID}" -session "${SESSION_TWO_ID}" -timeout 90s

(
  cd "${SOURCE_ROOT}/strategy-debugger-cli"
  library_commit="$(
    sed -n 's/.*strategy-library\.git", rev = "\([0-9a-f]\{40\}\)".*/\1/p' \
      pyproject.toml | head -1
  )"
  [[ "${#library_commit}" -eq 40 && "${library_commit}" != *[!0-9a-f]* ]] || {
    echo "cannot resolve exact debugger strategy-library pin" >&2
    exit 1
  }
  ./scripts/with-local-strategy-library-git.sh "${SOURCE_ROOT}/strategy-library" \
    "${library_commit}" uv run --frozen --extra test pytest \
      tests/test_spot_package_v2.py tests/test_mixed_route_package_v2.py -q
)

end_runtime
for attempt in $(seq 1 30); do
  if ! docker container inspect "${CONTAINER_NAME}" >/dev/null 2>&1; then
    break
  fi
  if [[ "${attempt}" -eq 30 ]]; then
    echo "Spot Demo Runtime container remains after EndRuntime" >&2
    exit 1
  fi
  sleep 1
done

runtime_coverage_stage_locked_inputs "${HELPER_BIN}" "${SOURCE_ROOT}" "${OUTPUT_ROOT}" "${RUNTIME_ROOT}" "${RUNTIME_ID}"
REPORT_ROOT="${RUNTIME_COVERAGE_REPORT_ROOT}"
PYTHON_INPUT_DIR="${RUNTIME_COVERAGE_PYTHON_INPUT_DIR}"
runtime_coverage_require_finalization "${RUNTIME_ROOT}" "${RUNTIME_ID}"
runtime_coverage_generate_reports "${SOURCE_ROOT}" "${GO_DIR}" "${PYTHON_INPUT_DIR}" "${REPORT_ROOT}"

cleanup_local_work
trap - EXIT INT TERM
echo "Spot Demo smoke completed"
echo "session_id=${SESSION_ONE_ID}"
echo "runtime_root=${RUNTIME_ROOT}"
echo "report_root=${REPORT_ROOT}"
