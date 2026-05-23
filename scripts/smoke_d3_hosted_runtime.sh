#!/usr/bin/env bash
# D3 hosted/default runtime smoke.
#
# Starts the normal hosted Docker runtime through control-panel-service
# EnsureHostedRuntime. This is the "default mode" runtime path: inbound
# gRPC server + caller_token, unchanged by D3.
#
# UI equivalent: Runtime Management -> Start hosted runtime.
set -euo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"

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
bash "${ROOT_DIR}/strategy-service/scripts/build_strategy_runtime.sh" "${IMAGE_TAG}"

echo "→ EnsureHostedRuntime via ${CONTROL_PANEL_ADDR}"
(
  cd "${ROOT_DIR}/control-panel-service"
  go run scripts/smoke_ensure_runtime.go \
    -addr "${CONTROL_PANEL_ADDR}" \
    -user "${USER_ID}" \
    -profile "${PROFILE}"
)

echo "✓ hosted/default runtime smoke completed"
