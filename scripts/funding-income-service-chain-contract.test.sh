#!/usr/bin/env bash
set -euo pipefail

DEPLOY_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
SCRIPT="${DEPLOY_ROOT}/scripts/funding-income-service-chain.test.sh"

fail() {
  echo "funding-income service-chain contract: $*" >&2
  exit 1
}

[[ -x "${SCRIPT}" ]] || fail "executable service-chain gate is missing"
bash -n "${SCRIPT}" || fail "service-chain gate is not valid Bash"

fixture="$(mktemp -d "${TMPDIR:-/tmp}/funding-chain-contract.XXXXXX")"
trap 'rm -rf -- "${fixture}"' EXIT
chmod 0700 "${fixture}"
for repository in core-service scraper control-panel-service strategy-service hushine-deploy; do
  mkdir -p "${fixture}/${repository}"
  git -C "${fixture}/${repository}" init -q
  git -C "${fixture}/${repository}" config user.name "Funding chain test"
  git -C "${fixture}/${repository}" config user.email "funding-chain@example.invalid"
  echo clean >"${fixture}/${repository}/tracked"
  git -C "${fixture}/${repository}" add tracked
  git -C "${fixture}/${repository}" commit -qm fixture
done

(
  export HUSHINE_SOURCE_ROOT="${fixture}"
  # shellcheck disable=SC1090
  source "${SCRIPT}"
  require_clean_repositories
) || fail "clean required repositories were rejected"

echo dirty >>"${fixture}/core-service/tracked"
set +e
dirty_output="$(
  (
    export HUSHINE_SOURCE_ROOT="${fixture}"
    # shellcheck disable=SC1090
    source "${SCRIPT}"
    require_clean_repositories
  ) 2>&1
)"
dirty_status="$?"
set -e
[[ "${dirty_status}" -ne 0 ]] || fail "dirty required repository was accepted"
grep -Fq 'core-service' <<<"${dirty_output}" || fail "dirty rejection omitted repository identity"

owned_marker="${fixture}/owned.marker"
unowned_marker="${fixture}/unowned.marker"
bash -c 'trap "echo stopped >\"$1\"; exit" TERM; while :; do sleep 1; done' _ "${owned_marker}" &
owned_pid="$!"
bash -c 'trap "echo stopped >\"$1\"; exit" TERM; while :; do sleep 1; done' _ "${unowned_marker}" &
unowned_pid="$!"
(
  export HUSHINE_SOURCE_ROOT="${fixture}"
  # shellcheck disable=SC1090
  source "${SCRIPT}"
  OWNED_PIDS=("${owned_pid}")
  cleanup_owned_processes
)
for _ in 1 2 3 4 5 6 7 8 9 10; do
  kill -0 "${owned_pid}" 2>/dev/null || break
  sleep 0.1
done
kill -0 "${owned_pid}" 2>/dev/null && fail "owned process was not stopped"
kill -0 "${unowned_pid}" 2>/dev/null || fail "cleanup stopped an unowned process"
kill -TERM "${unowned_pid}" 2>/dev/null || true
wait "${unowned_pid}" 2>/dev/null || true

make -C "${DEPLOY_ROOT}" -n funding-income-service-chain >/dev/null \
  || fail "Makefile service-chain entry point is missing"
make -C "${DEPLOY_ROOT}" -n funding-income-demo-smoke >/dev/null \
  || fail "Makefile Demo smoke entry point is missing"

mkdir -p "${fixture}/evidence"
printf '%s\n' 'core-startup-root-cause' >"${fixture}/evidence/core-service.log"
set +e
readiness_output="$(
  (
    export HUSHINE_SOURCE_ROOT="${fixture}"
    export SERVICE_READY_TIMEOUT_SECONDS=0
    # shellcheck disable=SC1090
    source "${SCRIPT}"
    EVIDENCE_ROOT="${fixture}/evidence"
    wait_tcp 1 "core-service" "core-service"
  ) 2>&1
)"
readiness_status="$?"
set -e
[[ "${readiness_status}" -ne 0 ]] || fail "failed readiness check unexpectedly passed"
grep -Fq 'core-startup-root-cause' <<<"${readiness_output}" \
  || fail "readiness failure omitted the owned service log"

echo "funding-income service-chain contract: PASS"
