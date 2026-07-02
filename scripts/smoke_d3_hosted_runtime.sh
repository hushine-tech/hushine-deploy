#!/usr/bin/env bash
# D3 hosted/default runtime smoke.
#
# Starts the normal hosted Docker runtime through control-panel-service
# EnsureHostedRuntime. Hosted runtimes now self-register through the dedicated
# RuntimeChannel listener; this smoke calls the normal control-panel gRPC API
# that provisions the container.
#
# UI equivalent: Runtime Management -> Start hosted runtime.
set -euo pipefail

DEPLOY_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
SOURCE_ROOT="${DEPLOY_ROOT}"
if [[ ! -d "${SOURCE_ROOT}/strategy-service" && -d "${DEPLOY_ROOT}/../strategy-service" ]]; then
  SOURCE_ROOT="$(cd "${DEPLOY_ROOT}/.." && pwd -P)"
fi
if [[ ! -d "${SOURCE_ROOT}/strategy-service" || ! -d "${SOURCE_ROOT}/control-panel-service" ]]; then
  echo "cannot find service source tree under ${DEPLOY_ROOT} or ${DEPLOY_ROOT}/.." >&2
  exit 1
fi

USER_ID="${USER_ID:-${1:-}}"
PROFILE="${PROFILE:-small}"
IMAGE_TAG="${IMAGE_TAG:-dev}"
CONTROL_PANEL_ADDR="${CONTROL_PANEL_ADDR:-127.0.0.1:50054}"

if [[ -z "${USER_ID}" ]]; then
  echo "usage: USER_ID=<account.users.id> $0"
  echo "   or: $0 <account.users.id>"
  exit 2
fi

echo "→ build hosted runtime image hushine/strategy-runtime:${IMAGE_TAG}"
bash "${SOURCE_ROOT}/strategy-service/scripts/build_strategy_runtime.sh" "${IMAGE_TAG}"

echo "→ EnsureHostedRuntime via ${CONTROL_PANEL_ADDR}"
(
  cd "${SOURCE_ROOT}/control-panel-service"
  go run scripts/smoke_ensure_runtime.go \
    -addr "${CONTROL_PANEL_ADDR}" \
    -user "${USER_ID}" \
    -profile "${PROFILE}"
)

echo "✓ hosted/default runtime smoke completed"
