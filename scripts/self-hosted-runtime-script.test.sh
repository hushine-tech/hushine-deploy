#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

script="scripts/smoke_d3_self_hosted_runtime.sh"

required_literals=(
  '--rm'
  '-e "RUNTIME_CREDENTIAL_PATH=${RUNTIME_CRED_PATH}"'
  '-e "RUNTIME_CHANNEL_GRPC_ADDR=${RUNTIME_CHANNEL_ADDR}"'
  '-e RUNTIME_CREDENTIAL_PATH='"'"'${RUNTIME_CRED_PATH}'"'"''
  '-e RUNTIME_CHANNEL_GRPC_ADDR='"'"'${RUNTIME_CHANNEL_ADDR}'"'"''
)

for literal in "${required_literals[@]}"; do
  if ! grep -Fq -- "$literal" "$script"; then
    echo "missing self-hosted runtime launcher literal: $literal" >&2
    exit 1
  fi
done

for forbidden in '--restart' 'unless-stopped' 'RUNTIME_RUNTIME_ID' 'runtime_id_from_credential()' 'CONTROL_PANEL_SERVICE_GRPC_ADDR' 'RUNTIME_INGRESS_MODE'; do
  if grep -Fq -- "$forbidden" "$script"; then
    echo "forbidden self-hosted runtime launcher literal still present: $forbidden" >&2
    exit 1
  fi
done
