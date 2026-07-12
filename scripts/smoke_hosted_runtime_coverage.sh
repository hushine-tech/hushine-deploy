#!/usr/bin/env bash
# Provision a real hosted coverage runtime, exercise both one-shot and active
# Python workers, end it through control-panel, and prove both language outputs
# are mergeable.
set -euo pipefail

DEPLOY_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
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
OUTPUT_ROOT="$1"
case "${OUTPUT_ROOT}" in
  /*) ;;
  *)
    echo "output directory must be absolute: ${OUTPUT_ROOT}" >&2
    exit 2
    ;;
esac

USER_ID="${USER_ID:-}"
PORTFOLIO_ID="${PORTFOLIO_ID:-0}"
PROFILE="${PROFILE:-small}"
CONTROL_PANEL_ADDR="${CONTROL_PANEL_ADDR:-127.0.0.1:50054}"
PORTFOLIO_ADDR="${PORTFOLIO_ADDR:-127.0.0.1:50051}"
COVERAGE_IMAGE="${COVERAGE_IMAGE:-hushine/strategy-runtime:executor-coverage}"
START_TIME_MS="${START_TIME_MS:-1780272000000}"
END_TIME_MS="${END_TIME_MS:-1783728000000}"

if [[ ! "${USER_ID}" =~ ^[1-9][0-9]*$ ]]; then
  echo "USER_ID must be a positive integer" >&2
  exit 2
fi
if [[ ! "${PORTFOLIO_ID}" =~ ^[0-9]+$ ]]; then
  echo "PORTFOLIO_ID must be zero or a positive integer" >&2
  exit 2
fi
for command in docker go jq uv; do
  if ! command -v "${command}" >/dev/null 2>&1; then
    echo "required command not found: ${command}" >&2
    exit 1
  fi
done

mkdir -p "${OUTPUT_ROOT}"
chmod 0700 "${OUTPUT_ROOT}"
OUTPUT_ROOT="$(cd "${OUTPUT_ROOT}" && pwd -P)"
IMAGE_ID="$(docker image inspect --format '{{.Id}}' "${COVERAGE_IMAGE}" 2>/dev/null || true)"
if [[ -z "${IMAGE_ID}" ]]; then
  echo "coverage image not found: ${COVERAGE_IMAGE}" >&2
  exit 1
fi

RUNTIME_ID=""
CONTAINER_NAME=""
CONTAINER_ID=""
RUNTIME_ENDED=0
EVENT_SINCE="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

end_runtime() {
  if [[ -z "${RUNTIME_ID}" || "${RUNTIME_ENDED}" -eq 1 ]]; then
    return 0
  fi
  if ! (
    cd "${SOURCE_ROOT}/control-panel-service"
    go run "${DEPLOY_ROOT}/scripts/smoke_hosted_runtime_coverage.go" \
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

owned_smoke_container() {
  local runtime_label user_label coverage_label image_id
  if ! docker container inspect "${CONTAINER_NAME}" >/dev/null 2>&1; then
    return 1
  fi
  runtime_label="$(docker container inspect --format '{{index .Config.Labels "hushine.runtime.runtime_id"}}' "${CONTAINER_NAME}")"
  user_label="$(docker container inspect --format '{{index .Config.Labels "hushine.runtime.user_id"}}' "${CONTAINER_NAME}")"
  coverage_label="$(docker container inspect --format '{{index .Config.Labels "hushine.runtime.coverage"}}' "${CONTAINER_NAME}")"
  image_id="$(docker container inspect --format '{{.Image}}' "${CONTAINER_NAME}")"
  [[ "${runtime_label}" == "${RUNTIME_ID}" && "${user_label}" == "${USER_ID}" && "${coverage_label}" == "true" && "${image_id}" == "${IMAGE_ID}" ]]
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

cleanup() {
  local rc="$?"
  local cleanup_failed=0
  trap - EXIT
  if [[ -n "${RUNTIME_ID}" && "${RUNTIME_ENDED}" -eq 0 ]]; then
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
  if [[ "${cleanup_failed}" -ne 0 ]]; then
    echo "cleanup failed; owned runtime may require operator intervention: ${RUNTIME_ID}" >&2
    if [[ "${rc}" -eq 0 ]]; then
      rc=1
    fi
  fi
  exit "${rc}"
}
trap cleanup EXIT

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
RUNTIMES_ROOT="${OUTPUT_ROOT}/runtimes"
RUNTIME_ROOT="${RUNTIMES_ROOT}/${RUNTIME_ID}"
GO_DIR="${RUNTIME_ROOT}/go"
PYTHON_DIR="${RUNTIME_ROOT}/python"
for directory in "${RUNTIMES_ROOT}" "${RUNTIME_ROOT}" "${GO_DIR}" "${PYTHON_DIR}"; do
  if [[ ! -d "${directory}" || -L "${directory}" ]]; then
    echo "expected safe coverage directory missing: ${directory}" >&2
    exit 1
  fi
done
RUNTIMES_ROOT="$(cd "${RUNTIMES_ROOT}" && pwd -P)"
RUNTIME_ROOT="$(cd "${RUNTIME_ROOT}" && pwd -P)"
if [[ "${RUNTIME_ROOT}" != "${RUNTIMES_ROOT}/${RUNTIME_ID}" ]]; then
  echo "runtime coverage path escapes output root" >&2
  exit 1
fi
GO_DIR="${RUNTIME_ROOT}/go"
PYTHON_DIR="${RUNTIME_ROOT}/python"

CONTAINER_ID="$(docker container inspect --format '{{.Id}}' "${CONTAINER_NAME}")"
CONTAINER_IMAGE_ID="$(docker container inspect --format '{{.Image}}' "${CONTAINER_NAME}")"
COVERAGE_LABEL="$(docker container inspect --format '{{index .Config.Labels "hushine.runtime.coverage"}}' "${CONTAINER_NAME}")"
RUN_LABEL="$(docker container inspect --format '{{index .Config.Labels "hushine.runtime.coverage_run_id"}}' "${CONTAINER_NAME}")"
MOUNT_SOURCE="$(docker container inspect "${CONTAINER_NAME}" | jq -r '.[0].Mounts[] | select(.Destination == "/coverage") | .Source')"
ENV_NAMES="$(docker container inspect "${CONTAINER_NAME}" | jq -r '.[0].Config.Env | map(split("=")[0]) | .[]')"
EXPECTED_RUN_LABEL="$(basename "${OUTPUT_ROOT}")"
if [[ "${EXPECTED_RUN_LABEL}" == "runtime-agent" && "$(basename "$(dirname "${OUTPUT_ROOT}")")" == "coverage" ]]; then
  EXPECTED_RUN_LABEL="$(basename "$(dirname "$(dirname "${OUTPUT_ROOT}")")")"
fi
if [[ "${CONTAINER_IMAGE_ID}" != "${IMAGE_ID}" || "${COVERAGE_LABEL}" != "true" || "${RUN_LABEL}" != "${EXPECTED_RUN_LABEL}" || "${MOUNT_SOURCE}" != "${RUNTIME_ROOT}" ]]; then
  echo "coverage container image/label/mount validation failed" >&2
  exit 1
fi
for name in GOCOVERDIR HUSHINE_RUNTIME_COVERAGE_DIR; do
  if ! grep -Fxq "${name}" <<<"${ENV_NAMES}"; then
    echo "coverage environment name missing: ${name}" >&2
    exit 1
  fi
done
echo "container_id=${CONTAINER_ID} image_id=${CONTAINER_IMAGE_ID} coverage_label=${COVERAGE_LABEL} coverage_run_id=${RUN_LABEL}"

echo "→ PreviewRunStrategy through RuntimeChannel (one-shot Python worker)"
(
  cd "${SOURCE_ROOT}/control-panel-service"
  go run "${DEPLOY_ROOT}/scripts/smoke_hosted_runtime_coverage.go" \
    -action preview \
    -control-panel-addr "${CONTROL_PANEL_ADDR}" \
    -portfolio-addr "${PORTFOLIO_ADDR}" \
    -user "${USER_ID}" \
    -runtime "${RUNTIME_ID}" \
    -portfolio "${PORTFOLIO_ID}" \
    -start-time-ms "${START_TIME_MS}" \
    -end-time-ms "${END_TIME_MS}" \
    -timeout 45s
)

echo "→ RunStrategy through RuntimeChannel (active Python session worker)"
RUN_ONE_OUTPUT="$({
  cd "${SOURCE_ROOT}/control-panel-service"
  go run "${DEPLOY_ROOT}/scripts/smoke_hosted_runtime_coverage.go" \
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
  go run "${DEPLOY_ROOT}/scripts/smoke_hosted_runtime_coverage.go" \
    -action expect-end-blocked \
    -control-panel-addr "${CONTROL_PANEL_ADDR}" \
    -user "${USER_ID}" \
    -runtime "${RUNTIME_ID}" \
    -timeout 15s
)

echo "→ StopStrategy first active worker"
(
  cd "${SOURCE_ROOT}/control-panel-service"
  go run "${DEPLOY_ROOT}/scripts/smoke_hosted_runtime_coverage.go" \
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
  go run "${DEPLOY_ROOT}/scripts/smoke_hosted_runtime_coverage.go" \
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
  go run "${DEPLOY_ROOT}/scripts/smoke_hosted_runtime_coverage.go" \
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

FINALIZATION_FILE="${RUNTIME_ROOT}/finalization.json"
if [[ ! -f "${FINALIZATION_FILE}" || -L "${FINALIZATION_FILE}" ]]; then
  echo "runtime coverage finalization marker is missing or unsafe" >&2
  exit 1
fi
if ! jq -e --arg runtime_id "${RUNTIME_ID}" '
  type == "object"
  and (keys == ["boot_id", "completed_at", "forced_workers", "go_snapshot", "runtime_id", "schema_version", "state", "worker_shutdown"])
  and .schema_version == 1
  and .runtime_id == $runtime_id
  and (.boot_id | type == "string" and length > 0)
  and .state == "complete"
  and .worker_shutdown == "ok"
  and .forced_workers == 0
  and .go_snapshot == "ok"
  and (.completed_at | type == "string" and length > 0)
' "${FINALIZATION_FILE}" >/dev/null; then
  echo "runtime coverage finalization marker is not complete" >&2
  exit 1
fi

EVENTS_FILE="${RUNTIME_ROOT}/docker-events.jsonl"
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

if ! find "${GO_DIR}" -type f -print -quit | grep -q .; then
  echo "Go coverage output is missing: ${GO_DIR}" >&2
  exit 1
fi
if ! find "${PYTHON_DIR}" -name '.coverage*' -type f -print -quit | grep -q .; then
  echo "Python coverage output is missing: ${PYTHON_DIR}" >&2
  exit 1
fi

GO_MERGED="${RUNTIME_ROOT}/go-merged"
generate_go_reports() {
  rm -rf "${GO_MERGED}"
  mkdir -p "${GO_MERGED}"
  (
    cd "${SOURCE_ROOT}/strategy-service"
    go tool covdata merge -i="${GO_DIR}" -o="${GO_MERGED}"
    go tool covdata textfmt -i="${GO_MERGED}" -o="${RUNTIME_ROOT}/go.cover.out"
    go tool cover -func="${RUNTIME_ROOT}/go.cover.out" >"${RUNTIME_ROOT}/go-functions.txt"
  )
}
generate_go_reports

PYTHON_RC="${RUNTIME_ROOT}/python-report.coveragerc"
{
  echo '[run]'
  echo 'source = strategy_service'
  echo
  echo '[paths]'
  echo 'source ='
  printf '    %s\n' "${SOURCE_ROOT}/strategy-service/strategy_service"
  echo '    /app/strategy-service/strategy_service'
} >"${PYTHON_RC}"
export COVERAGE_FILE="${PYTHON_DIR}/.coverage"
export COVERAGE_RCFILE="${PYTHON_RC}"
(
  cd "${SOURCE_ROOT}/strategy-service"
  uv run --frozen --extra coverage coverage combine --keep "${PYTHON_DIR}"
  uv run --frozen --extra coverage coverage report --keep-combined >"${RUNTIME_ROOT}/python-report.txt"
  uv run --frozen --extra coverage coverage json --keep-combined -o "${RUNTIME_ROOT}/python-coverage.json"
)

for report in \
  "${RUNTIME_ROOT}/go.cover.out" \
  "${RUNTIME_ROOT}/go-functions.txt" \
  "${RUNTIME_ROOT}/python-report.txt" \
  "${RUNTIME_ROOT}/python-coverage.json"; do
  if [[ ! -s "${report}" ]]; then
    echo "coverage report is missing or empty: ${report}" >&2
    exit 1
  fi
done

trap - EXIT
echo "✓ hosted runtime coverage smoke completed"
echo "runtime_root=${RUNTIME_ROOT}"
echo "go_report=${RUNTIME_ROOT}/go.cover.out"
echo "python_report=${RUNTIME_ROOT}/python-coverage.json"
