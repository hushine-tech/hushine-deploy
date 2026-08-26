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
for repository in core-service scraper control-panel-service strategy-service gateway/quant-handler hushine-deploy; do
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
grep -Fq 'HUSHINE_TEST_PG_ADMIN_DSN="${LOCAL_PG_ADMIN_DSN}"' "${SCRIPT}" \
  || fail "fresh-schema assertion does not receive the owned local admin DSN"
grep -Fq 'go test -v -tags=integration ./internal/runtimeagent' "${SCRIPT}" \
  || fail "blocked-worker assertion is not compiled with the integration build tag"
grep -Fq -- '--- PASS: TestIndicatorV2Integration1023ThenTwoFrames' "${SCRIPT}" \
  || fail "Indicator assertion has no exact executed-test PASS check"
grep -Fq -- '--- PASS: TestBlockedWorkerKeepsRuntimeHeartbeatAndCanBeReplaced' "${SCRIPT}" \
  || fail "blocked-worker assertion has no exact executed-test PASS check"
grep -Fq 'runtimeagent-integration-test.log' "${SCRIPT}" \
  || fail "runtime-agent integration evidence is not retained for validation"
grep -Fq -- '--no-recreate' "${SCRIPT}" \
  || fail "local infrastructure may recreate containers that predate the gate"
grep -Fq 'containers.all.before' "${SCRIPT}" \
  || fail "container cleanup does not snapshot every pre-existing container"
grep -Fq 'docker rm -f' "${SCRIPT}" \
  || fail "containers created by the gate are not removed"
grep -Fq 'PGDATABASE_PORTFOLIO="${OWNED_PORTFOLIO_DB}"' "${SCRIPT}" \
  || fail "service-chain migrations do not use an owned Portfolio database"
grep -Fq 'SCRAPER_DATABASE_PREFIX="${OWNED_MARKET_PREFIX}"' "${SCRIPT}" \
  || fail "service-chain migrations do not use owned market-data databases"
grep -Fq 'drop_owned_databases' "${SCRIPT}" \
  || fail "owned database cleanup is missing"
for real_probe in \
  'probe_started_mock_adapter' \
  'probe_started_core_http' \
  'probe_started_control_http' \
  'probe_started_runtime_channel_mtls' \
  'probe_started_scraper_reconcile'; do
  grep -Fq "${real_probe}" "${SCRIPT}" \
    || fail "started-service probe is missing: ${real_probe}"
done
grep -Fq 'run_real_runtime_worker_chain' "${SCRIPT}" \
  || fail "real core-control-RuntimeChannel-Worker business chain is not invoked"

cleanup_bin="${fixture}/cleanup-bin"
mkdir -p "${cleanup_bin}"
cat >"${cleanup_bin}/docker" <<'FAKE_DOCKER_FAILURE'
#!/usr/bin/env bash
exit 73
FAKE_DOCKER_FAILURE
chmod 0700 "${cleanup_bin}/docker"
set +e
cleanup_failure_output="$(
  (
    export PATH="${cleanup_bin}:${PATH}"
    # shellcheck disable=SC1090
    source "${SCRIPT}"
    EVIDENCE_ROOT="${fixture}/cleanup-failure-evidence"
    mkdir -p "${EVIDENCE_ROOT}"
    CREATED_CONTAINERS=(created-by-gate)
    CHAIN_ASSERTIONS_PASSED=true
    cleanup_owned_resources
  ) 2>&1
)"
cleanup_failure_status="$?"
set -e
[[ "${cleanup_failure_status}" -ne 0 ]] \
  || fail "created-container removal failure did not fail the gate"
[[ "${cleanup_failure_output}" != *'funding-income service-chain: PASS'* ]] \
  || fail "gate printed PASS after cleanup failed"
grep -Fq 'cleanup failed' <<<"${cleanup_failure_output}" \
  || fail "cleanup failure did not emit a diagnostic"

set +e
database_cleanup_output="$(
  (
    export PATH="${cleanup_bin}:${PATH}"
    # shellcheck disable=SC1090
    source "${SCRIPT}"
    EVIDENCE_ROOT="${fixture}/database-cleanup-failure"
    mkdir -p "${EVIDENCE_ROOT}"
    OWNED_DATABASES=(hushine_funding_chain_contract_portfolio)
    CHAIN_ASSERTIONS_PASSED=true
    cleanup_owned_resources
  ) 2>&1
)"
database_cleanup_status="$?"
set -e
[[ "${database_cleanup_status}" -ne 0 ]] \
  || fail "owned-database drop failure did not fail the gate"
grep -Fq 'cleanup failed' <<<"${database_cleanup_output}" \
  || fail "owned-database cleanup failure omitted its diagnostic"

state_bin="${fixture}/state-bin"
state_root="${fixture}/docker-state"
mkdir -p "${state_bin}" "${state_root}"
cat >"${state_bin}/docker" <<'FAKE_DOCKER_STATE'
#!/usr/bin/env bash
set -euo pipefail
action="$1"
shift
case "${action}" in
  inspect)
    if [[ "${1:-}" == "-f" ]]; then
      format="$2" id="$3"
      state="$(cat "${DOCKER_STATE_DIR}/${id}")"
      if [[ "${format}" == *'{{.Id}}'* ]]; then
        printf '%s|%s\n' "${id}" "${state}"
      else
        printf '%s\n' "${state}"
      fi
    else
      [[ -f "${DOCKER_STATE_DIR}/${1}" ]]
    fi
    ;;
  start) [[ "${FAIL_DOCKER_ACTION:-}" != start ]]; printf 'true|false\n' >"${DOCKER_STATE_DIR}/$1" ;;
  stop) [[ "${FAIL_DOCKER_ACTION:-}" != stop ]]; printf 'false|false\n' >"${DOCKER_STATE_DIR}/${@: -1}" ;;
  pause) [[ "${FAIL_DOCKER_ACTION:-}" != pause ]]; printf 'true|true\n' >"${DOCKER_STATE_DIR}/$1" ;;
  unpause) [[ "${FAIL_DOCKER_ACTION:-}" != unpause ]]; printf 'true|false\n' >"${DOCKER_STATE_DIR}/$1" ;;
  rm) [[ "${FAIL_DOCKER_ACTION:-}" != rm ]]; rm -f "${DOCKER_STATE_DIR}/${@: -1}" ;;
  *) exit 72 ;;
esac
FAKE_DOCKER_STATE
chmod 0700 "${state_bin}/docker"
printf 'true|false\n' >"${state_root}/running"
printf 'true|false\n' >"${state_root}/stopped"
printf 'true|false\n' >"${state_root}/paused"
state_cleanup_output="$(
  (
    export PATH="${state_bin}:${PATH}" DOCKER_STATE_DIR="${state_root}"
    # shellcheck disable=SC1090
    source "${SCRIPT}"
    EVIDENCE_ROOT="${fixture}/state-cleanup-evidence"
    mkdir -p "${EVIDENCE_ROOT}"
    printf '%s\n' 'running|true|false' 'stopped|false|false' 'paused|true|true' \
      >"${EVIDENCE_ROOT}/containers.state.before"
    CHAIN_ASSERTIONS_PASSED=true
    cleanup_owned_resources
  ) 2>&1
)"
[[ "$(cat "${state_root}/running")" == 'true|false' ]]
[[ "$(cat "${state_root}/stopped")" == 'false|false' ]]
[[ "$(cat "${state_root}/paused")" == 'true|true' ]]
grep -Fq 'assertions and cleanup verified' <<<"${state_cleanup_output}" \
  || fail "running/stopped/paused state restoration did not produce final PASS"

printf 'true|false\n' >"${state_root}/stopped"
set +e
stop_failure_output="$(
  (
    export PATH="${state_bin}:${PATH}" DOCKER_STATE_DIR="${state_root}" FAIL_DOCKER_ACTION=stop
    # shellcheck disable=SC1090
    source "${SCRIPT}"
    EVIDENCE_ROOT="${fixture}/stop-cleanup-failure"
    mkdir -p "${EVIDENCE_ROOT}"
    printf '%s\n' 'stopped|false|false' >"${EVIDENCE_ROOT}/containers.state.before"
    CHAIN_ASSERTIONS_PASSED=true
    cleanup_owned_resources
  ) 2>&1
)"
stop_failure_status="$?"
set -e
[[ "${stop_failure_status}" -ne 0 ]] || fail "pre-existing container stop failure was accepted"
[[ "${stop_failure_output}" != *'assertions and cleanup verified'* ]] \
  || fail "gate printed PASS after container-state restoration failed"

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

(
  export HUSHINE_SOURCE_ROOT="${fixture}"
  # shellcheck disable=SC1090
  source "${SCRIPT}"
  EVIDENCE_ROOT="${fixture}/evidence"
  start_owned_in core-probe "${fixture}/core-service" sh -c \
    'pwd -P >"$1"' _ "${fixture}/service.cwd"
  wait "${OWNED_PIDS[0]}"
)
expected_service_cwd="$(cd -- "${fixture}/core-service" && pwd -P)"
[[ "$(cat "${fixture}/service.cwd")" == "${expected_service_cwd}" ]] \
  || fail "owned service did not start from its repository working directory"

echo "funding-income service-chain contract: PASS"
