#!/usr/bin/env bash
set -euo pipefail

DEPLOY_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
SOURCE_ROOT="${HUSHINE_SOURCE_ROOT:-$(cd -- "${DEPLOY_ROOT}/.." && pwd -P)}"

fail() {
  echo "local-independence contract: $*" >&2
  exit 1
}

active_paths=(
  "${SOURCE_ROOT}/core-service/config.yaml"
  "${SOURCE_ROOT}/core-service/internal/config"
  "${SOURCE_ROOT}/core-service/scripts"
  "${SOURCE_ROOT}/scraper/config.yaml"
  "${SOURCE_ROOT}/scraper/log-config.json"
  "${SOURCE_ROOT}/scraper/cmd"
  "${SOURCE_ROOT}/control-panel-service/config.yaml"
  "${SOURCE_ROOT}/control-panel-service/internal/config"
  "${SOURCE_ROOT}/control-panel-service/cmd"
  "${SOURCE_ROOT}/strategy-service/Makefile"
  "${DEPLOY_ROOT}/scripts/prepare-local-configs.py"
  "${DEPLOY_ROOT}/scripts/pg-forward.py"
  "${DEPLOY_ROOT}/scripts/pg-forward.sh"
  "${DEPLOY_ROOT}/restart.sh"
)

matches="$(rg -n '192\.168\.88\.10' "${active_paths[@]}" \
  --glob '!**/*_test.go' --glob '!**/*.test.sh' || true)"
[[ -z "${matches}" ]] || fail "active defaults still reference shared infrastructure:\n${matches}"

set +e
forward_output="$(python3 "${DEPLOY_ROOT}/scripts/pg-forward.py" \
  --listen-host 127.0.0.1 --listen-port 0 2>&1)"
forward_status="$?"
set -e
[[ "${forward_status}" -eq 2 ]] \
  || fail "remote forwarder accepted a missing explicit --target-host"
grep -Fq -- '--target-host' <<<"${forward_output}" \
  || fail "remote forwarder did not identify the required target host"

echo "local-independence contract: PASS"
