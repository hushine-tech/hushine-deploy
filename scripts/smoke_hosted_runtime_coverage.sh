#!/usr/bin/env bash
# Provision a real hosted coverage runtime, execute a one-shot Python worker,
# end it through control-panel, and prove both language outputs are mergeable.
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
RUNTIME_ENDED=0

end_runtime() {
  if [[ -z "${RUNTIME_ID}" || "${RUNTIME_ENDED}" -eq 1 ]]; then
    return 0
  fi
  (
    cd "${SOURCE_ROOT}/control-panel-service"
    go run "${DEPLOY_ROOT}/scripts/smoke_hosted_runtime_coverage.go" \
      -action end \
      -control-panel-addr "${CONTROL_PANEL_ADDR}" \
      -user "${USER_ID}" \
      -runtime "${RUNTIME_ID}" \
      -timeout 45s
  )
  RUNTIME_ENDED=1
}

cleanup() {
  local rc="$?"
  trap - EXIT
  if [[ -n "${RUNTIME_ID}" && "${RUNTIME_ENDED}" -eq 0 ]]; then
    echo "→ cleanup: EndRuntime ${RUNTIME_ID}" >&2
    end_runtime >&2 || true
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
  echo "${ENSURE_OUTPUT}" | sed -E 's/(credential|token|password|secret|private_key)([^, ]*)/\1=<redacted>/Ig' >&2
  exit "${ENSURE_RC}"
fi
RUNTIME_ID="$(sed -n 's/.*runtime_id=\([^[:space:]]*\).*/\1/p' <<<"${ENSURE_OUTPUT}" | head -1)"
if [[ -z "${RUNTIME_ID}" || "${ENSURE_OUTPUT}" != *"provisioned=true"* ]]; then
  echo "EnsureHostedRuntime did not provision a unique runtime" >&2
  exit 1
fi
echo "runtime_id=${RUNTIME_ID} provisioned=true"

CONTAINER_NAME="hushine-runtime-${RUNTIME_ID}"
RUNTIME_ROOT="${OUTPUT_ROOT}/runtimes/${RUNTIME_ID}"
GO_DIR="${RUNTIME_ROOT}/go"
PYTHON_DIR="${RUNTIME_ROOT}/python"
for directory in "${RUNTIME_ROOT}" "${GO_DIR}" "${PYTHON_DIR}"; do
  if [[ ! -d "${directory}" || -L "${directory}" ]]; then
    echo "expected safe coverage directory missing: ${directory}" >&2
    exit 1
  fi
done

CONTAINER_ID="$(docker container inspect --format '{{.Id}}' "${CONTAINER_NAME}")"
CONTAINER_IMAGE_ID="$(docker container inspect --format '{{.Image}}' "${CONTAINER_NAME}")"
COVERAGE_LABEL="$(docker container inspect --format '{{index .Config.Labels "hushine.runtime.coverage"}}' "${CONTAINER_NAME}")"
RUN_LABEL="$(docker container inspect --format '{{index .Config.Labels "hushine.runtime.coverage_run_id"}}' "${CONTAINER_NAME}")"
MOUNT_SOURCE="$(docker container inspect "${CONTAINER_NAME}" | jq -r '.[0].Mounts[] | select(.Destination == "/coverage") | .Source')"
ENV_NAMES="$(docker container inspect "${CONTAINER_NAME}" | jq -r '.[0].Config.Env | map(split("=")[0]) | .[]')"
if [[ "${CONTAINER_IMAGE_ID}" != "${IMAGE_ID}" || "${COVERAGE_LABEL}" != "true" || "${MOUNT_SOURCE}" != "${RUNTIME_ROOT}" ]]; then
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
  uv run --with coverage coverage combine --keep "${PYTHON_DIR}"
  uv run --with coverage coverage report --keep-combined >"${RUNTIME_ROOT}/python-report.txt"
  uv run --with coverage coverage json --keep-combined -o "${RUNTIME_ROOT}/python-coverage.json"
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
