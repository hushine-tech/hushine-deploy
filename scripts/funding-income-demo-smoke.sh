#!/usr/bin/env bash
set -euo pipefail

DEPLOY_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
SOURCE_ROOT="${HUSHINE_SOURCE_ROOT:-$(cd -- "${DEPLOY_ROOT}/.." && pwd -P)}"
CORE_ROOT="${SOURCE_ROOT}/core-service"
ENVIRONMENT="${FUNDING_SMOKE_ENVIRONMENT:-demo}"
CREDENTIAL_FD="${FUNDING_SMOKE_CREDENTIAL_FD:-}"
VENUE_ID="${FUNDING_SMOKE_VENUE_ID:-}"
SESSION_ID="${FUNDING_SMOKE_SESSION_ID:-}"

die() {
  echo "funding-income-demo-smoke: $*" >&2
  exit 2
}

for name in \
  BINANCE_DEMO_API_KEY \
  BINANCE_DEMO_API_SECRET \
  BINANCE_API_KEY \
  BINANCE_API_SECRET; do
  if printenv "${name}" >/dev/null 2>&1; then
    die "named credential environment variables are forbidden"
  fi
done

[[ "${ENVIRONMENT}" == "demo" ]] || die "only Demo environment is allowed"
[[ "${CREDENTIAL_FD}" =~ ^[0-9]+$ && "${CREDENTIAL_FD}" -ge 3 ]] \
  || die "FUNDING_SMOKE_CREDENTIAL_FD must be an inherited descriptor >= 3"
[[ "${VENUE_ID}" =~ ^[1-9][0-9]*$ ]] \
  || die "FUNDING_SMOKE_VENUE_ID must be a positive integer"
[[ -n "${SESSION_ID}" && "${SESSION_ID}" != *$'\n'* && "${SESSION_ID}" != *$'\r'* ]] \
  || die "FUNDING_SMOKE_SESSION_ID must be non-empty and single-line"
[[ -d "${CORE_ROOT}/cmd/funding-income-demo-smoke" ]] \
  || die "core-service Demo smoke command is missing"

temporary="$(mktemp -d "${TMPDIR:-/tmp}/hushine-funding-demo.XXXXXX")"
chmod 0700 "${temporary}"
cleanup() {
  rm -rf -- "${temporary}"
}
trap cleanup EXIT HUP INT TERM

(
  cd "${CORE_ROOT}"
  go build -trimpath -o "${temporary}/funding-income-demo-smoke" \
    ./cmd/funding-income-demo-smoke
)
chmod 0700 "${temporary}/funding-income-demo-smoke"

env -i \
  PATH="${PATH}" \
  HOME="${HOME:-/tmp}" \
  TMPDIR="${TMPDIR:-/tmp}" \
  LANG="${LANG:-C.UTF-8}" \
  "${temporary}/funding-income-demo-smoke" \
    --credential-fd "${CREDENTIAL_FD}" \
    --venue-id "${VENUE_ID}" \
    --session-id "${SESSION_ID}" \
    --environment demo
