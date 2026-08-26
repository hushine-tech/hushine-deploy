#!/usr/bin/env bash
# D3 self-hosted runtime smoke launcher.
#
# Runs a strategy-runtime container in outbound RuntimeChannel mode. For a
# remote host that simulates the user's own Docker runtime, set:
#
#   REMOTE_HOST=<runtime-host> REMOTE_USER=hushine-tech \
#   RUNTIME_CHANNEL_ADDR=<mac-lan-ip>:50055 \
#   CREDENTIAL_FILE=/path/to/downloaded/runtime.cred \
#   scripts/smoke_d3_self_hosted_runtime.sh
#
# The script does not create credentials; download the `.cred` bundle from
# quant-frontend Runtime Management -> Runtime Credentials first.
set -euo pipefail

DEPLOY_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
SOURCE_ROOT="${DEPLOY_ROOT}"
if [[ ! -d "${SOURCE_ROOT}/strategy-service" && -d "${DEPLOY_ROOT}/../strategy-service" ]]; then
  SOURCE_ROOT="$(cd "${DEPLOY_ROOT}/.." && pwd -P)"
fi
if [[ ! -d "${SOURCE_ROOT}/strategy-service" ]]; then
  echo "cannot find service source tree under ${DEPLOY_ROOT} or ${DEPLOY_ROOT}/.." >&2
  exit 1
fi

RUNTIME_ROLE="${RUNTIME_ROLE:-executor}"
if [[ "${RUNTIME_ROLE}" != "executor" && "${RUNTIME_ROLE}" != "debugger" ]]; then
  echo "RUNTIME_ROLE must be executor or debugger"
  exit 2
fi

IMAGE="${IMAGE:-hushine/strategy-runtime:${RUNTIME_ROLE}-dev}"
CONTAINER_NAME="${CONTAINER_NAME:-hushine-self-hosted-runtime-default}"
CREDENTIAL_FILE="${CREDENTIAL_FILE:-}"
RUNTIME_CRED_PATH="${RUNTIME_CRED_PATH:-/etc/hushine/runtime.cred}"

RUNTIME_CHANNEL_ADDR="${RUNTIME_CHANNEL_ADDR:-host.docker.internal:50055}"

REMOTE_HOST="${REMOTE_HOST:-}"
REMOTE_USER="${REMOTE_USER:-hushine-tech}"
REMOTE_CRED_PATH="${REMOTE_CRED_PATH:-/home/${REMOTE_USER}/.hushine/runtime.cred}"
if [[ -z "${DEBUG_WORKSPACE:-}" ]]; then
  if [[ -n "${REMOTE_HOST}" ]]; then
    DEBUG_WORKSPACE="/home/${REMOTE_USER}/hushine-debug-workspace"
  else
    DEBUG_WORKSPACE="${HOME}/hushine-debug-workspace"
  fi
fi
SYNC_IMAGE="${SYNC_IMAGE:-0}"

if [[ -z "${CREDENTIAL_FILE}" ]]; then
  echo "required: CREDENTIAL_FILE=/path/to/downloaded/runtime.cred"
  exit 2
fi
if [[ ! -f "${CREDENTIAL_FILE}" ]]; then
  echo "credential file not found: ${CREDENTIAL_FILE}"
  exit 2
fi

build_image() {
  echo "→ building runtime images"
  bash "${SOURCE_ROOT}/strategy-service/scripts/build_strategy_runtime.sh" dev
}

run_local() {
  local args
  args=(
    docker run -d
    --rm
    --name "${CONTAINER_NAME}"
    -v "${CREDENTIAL_FILE}:${RUNTIME_CRED_PATH}:ro"
  )
  if [[ "${RUNTIME_ROLE}" == "debugger" ]]; then
    mkdir -p "${DEBUG_WORKSPACE}"
    args+=(
      -v "${DEBUG_WORKSPACE}:/workspace"
      -p 5678:5678
      -p 5679:5679
    )
  fi
  args+=(
    -e "RUNTIME_CREDENTIAL_PATH=${RUNTIME_CRED_PATH}"
    -e "RUNTIME_CHANNEL_GRPC_ADDR=${RUNTIME_CHANNEL_ADDR}"
    -e LOG_TRACING_ENABLED=false
    "${IMAGE}"
  )
  docker rm -f "${CONTAINER_NAME}" >/dev/null 2>&1 || true
  "${args[@]}"
}

run_remote() {
  local target="${REMOTE_USER}@${REMOTE_HOST}"
  local remote_dir
  remote_dir="$(dirname "${REMOTE_CRED_PATH}")"

  ssh "${target}" "mkdir -p '${remote_dir}' && chmod 700 '${remote_dir}'"
  scp "${CREDENTIAL_FILE}" "${target}:${REMOTE_CRED_PATH}"
  ssh "${target}" "chmod 600 '${REMOTE_CRED_PATH}'"

  if [[ "${SYNC_IMAGE}" == "1" ]]; then
    build_image
    echo "→ syncing image ${IMAGE} to ${target}"
    docker save "${IMAGE}" | ssh "${target}" docker load
  fi

  if [[ "${RUNTIME_ROLE}" == "debugger" ]]; then
    ssh "${target}" "mkdir -p '${DEBUG_WORKSPACE}'"
  fi
  local debug_args=""
  if [[ "${RUNTIME_ROLE}" == "debugger" ]]; then
    debug_args="-v '${DEBUG_WORKSPACE}:/workspace' -p 5678:5678 -p 5679:5679"
  fi

  ssh "${target}" "docker rm -f '${CONTAINER_NAME}' >/dev/null 2>&1 || true"
  ssh "${target}" "docker run -d \
    --rm \
    --name '${CONTAINER_NAME}' \
    -v '${REMOTE_CRED_PATH}:${RUNTIME_CRED_PATH}:ro' \
    ${debug_args} \
    -e RUNTIME_CREDENTIAL_PATH='${RUNTIME_CRED_PATH}' \
    -e RUNTIME_CHANNEL_GRPC_ADDR='${RUNTIME_CHANNEL_ADDR}' \
    -e LOG_TRACING_ENABLED=false \
    '${IMAGE}'"
}

if [[ -z "${REMOTE_HOST}" ]]; then
  echo "→ starting local self-hosted runtime container ${CONTAINER_NAME}"
  build_image
  run_local
else
  echo "→ starting remote self-hosted runtime on ${REMOTE_USER}@${REMOTE_HOST}"
  run_remote
fi

echo "✓ self-hosted runtime container launched"
echo "  runtime_channel = ${RUNTIME_CHANNEL_ADDR}"
echo "  role          = ${RUNTIME_ROLE}"
echo "  image         = ${IMAGE}"
echo "  container     = ${CONTAINER_NAME}"
echo "  platform deps = RuntimeChannel only (no account/order/Kafka/database env passed)"
if [[ "${RUNTIME_ROLE}" == "debugger" ]]; then
  echo "  workspace     = ${DEBUG_WORKSPACE} -> /workspace"
  echo "  replay        = docker exec -it ${CONTAINER_NAME} hushine-debug replay"
fi
echo "  cleanup       = docker rm -f ${CONTAINER_NAME}"
