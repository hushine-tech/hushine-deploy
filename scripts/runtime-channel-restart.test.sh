#!/usr/bin/env bash
set -euo pipefail

DEPLOY_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
HARNESS="${DEPLOY_ROOT}/scripts/test-runtime-channel-restart.sh"
FIXTURE="$(mktemp -d "${TMPDIR:-/tmp}/runtime-channel-restart-contract.XXXXXX")"
trap 'rm -rf -- "${FIXTURE}"' EXIT

fail() {
  echo "runtime-channel restart contract: $*" >&2
  exit 1
}

cat >"${FIXTURE}/driver" <<'DRIVER'
#!/usr/bin/env bash
set -euo pipefail
action="$1"
shift
printf '%s\n' "${action}" >>"${RUNTIME_RESTART_DRIVER_LOG}"
if [[ "${RUNTIME_RESTART_DRIVER_FAIL_AT:-}" == "${action}" ]]; then
  echo "injected ${action} failure" >&2
  exit 97
fi
case "${action}" in
  preflight)
    jq -nc '{ok:true}'
    ;;
  create-normal)
    jq -nc '{owner_token:"owned-contract",runtime_id:"runtime-contract",session_id:"session-contract",credential_key_id:"credential-contract",container_name:"hushine-runtime-restart-contract"}'
    ;;
  snapshot-before)
    jq -nc '{runtime_container_pid:4100,agent_pid:1,worker_pid:77,worker_generation:1,session_id:"session-contract",session_status:"running",heartbeat_cursor_us:1000,heartbeat_at:"2026-08-28T01:00:00Z",indicator_cursor:1023,income_cursor:0,wallet_effect_count:0,agent_health_http:200,agent_ready_http:200}'
    ;;
  stop-control-panel)
    jq -nc '{stopped:true,only_control_panel:true}'
    ;;
  snapshot-disconnected)
    jq -nc '{runtime_container_pid:4100,agent_pid:1,worker_pid:77,worker_generation:1,session_id:"session-contract",session_status:"running",heartbeat_cursor_us:1000,heartbeat_at:"2026-08-28T01:00:00Z",indicator_cursor:1023,income_cursor:0,wallet_effect_count:0,agent_health_http:200,agent_ready_http:503}'
    ;;
  pending-rpc)
    jq -nc '{status:"failed",grpc_code:"Unavailable",elapsed_ms:187,replay_count:0,correlation_id:"pending-contract"}'
    ;;
  start-control-panel)
    jq -nc '{started:true}'
    ;;
  wait-resume)
    jq -nc '{resumed:true,first_frame:"RESUME",agent_ready_http:200,resume_observed_at:"2026-08-28T01:00:02Z"}'
    ;;
  advance-data)
    jq -nc '{advanced:true}'
    ;;
  snapshot-after)
    jq -nc '{runtime_container_pid:4100,agent_pid:1,worker_pid:77,worker_generation:1,session_id:"session-contract",session_status:"running",heartbeat_cursor_us:3000,heartbeat_at:"2026-08-28T01:00:03Z",indicator_cursor:1025,income_cursor:9,wallet_effect_count:1,agent_health_http:200,agent_ready_http:200}'
    ;;
  create-revoke)
    jq -nc '{owner_token:"owned-revoke",runtime_id:"runtime-revoke",credential_key_id:"credential-revoke",container_name:"hushine-runtime-revoke"}'
    ;;
  revoke-credential)
    jq -nc '{revoked:true,streams_closed:1,runtimes_ended:1}'
    ;;
  assert-revoke-terminal)
    jq -nc '{safe_stop:true,reconnect_attempts:1,reconnect_storm:false,agent_exit_code:1}'
    ;;
  create-terminal-grace)
    jq -nc '{owner_token:"owned-grace",runtime_id:"runtime-grace",credential_key_id:"credential-grace",container_name:"hushine-runtime-grace"}'
    ;;
  exceed-terminal-grace)
    jq -nc '{terminalized:true,grace_seconds:3}'
    ;;
  assert-terminal-resume-rejected)
    jq -nc '{resume_rejected:true,grpc_code:"FailedPrecondition",safe_stop:true,reconnect_attempts:1,reconnect_storm:false,agent_exit_code:1}'
    ;;
  cleanup)
    jq -nc '{owned_only:true,artifacts_removed:true}'
    ;;
  *)
    echo "unexpected driver action: ${action}" >&2
    exit 64
    ;;
esac
DRIVER
chmod 0700 "${FIXTURE}/driver"

[[ -x "${HARNESS}" ]] || fail "missing executable harness: ${HARNESS}"

for live_contract in \
  'runtime_channel_leases' \
  'runtime_container_pid' \
  'strategy_service.session_worker_entry' \
  'worker_generation' \
  'heartbeat_cursor_us' \
  'strategy_indicator_chunks' \
  'venue_income_entries' \
  'last_applied_income_entry_id' \
  'agent_health_http' \
  'agent_ready_http' \
  'only_control_panel' \
  'grpc_code:"Unavailable"' \
  'first_frame:"RESUME"' \
  'revoke-credential)' \
  'exceed-terminal-grace)' \
  'hushine.acceptance.runtime-restart'; do
  grep -Fq "${live_contract}" "${HARNESS}" \
    || fail "live harness is missing contract: ${live_contract}"
done
grep -Fq 'make -C "${SOURCE_ROOT}/control-panel-service" stop' "${HARNESS}" \
  || fail "live harness does not stop only control-panel-service"
if grep -Eq 'local-infra-reset|docker compose[^#]*(down|rm)|down[[:space:]]+-v' "${HARNESS}"; then
  fail "live harness contains destructive shared-infrastructure cleanup"
fi

evidence="${FIXTURE}/evidence.json"
mkdir -m 0700 "${FIXTURE}/state"
RUNTIME_RESTART_DRIVER="${FIXTURE}/driver" \
RUNTIME_RESTART_DRIVER_LOG="${FIXTURE}/driver.log" \
HUSHINE_RUNTIME_RESTART_CONTRACT=1 \
bash "${HARNESS}" --state-dir "${FIXTURE}/state" \
  --evidence-file "${evidence}" >"${FIXTURE}/stdout.log"

jq -e '
  .schema == 1
  and .result == "PASS"
  and .normal.fixture == {
    owner_token:"owned-contract",
    runtime_id:"runtime-contract",
    session_id:"session-contract",
    credential_key_id:"credential-contract",
    container_name:"hushine-runtime-restart-contract"
  }
  and .normal.before.runtime_container_pid == 4100
  and .normal.before.agent_pid == 1
  and .normal.before.worker_pid == 77
  and .normal.before.worker_generation == 1
  and .normal.before.session_id == "session-contract"
  and .normal.before.heartbeat_cursor_us == 1000
  and .normal.before.heartbeat_at == "2026-08-28T01:00:00Z"
  and .normal.before.indicator_cursor == 1023
  and .normal.before.income_cursor == 0
  and .normal.disconnected.agent_health_http == 200
  and .normal.disconnected.agent_ready_http == 503
  and .normal.disconnected.session_status == "running"
  and .normal.pending_rpc.status == "failed"
  and .normal.pending_rpc.grpc_code == "Unavailable"
  and .normal.pending_rpc.elapsed_ms > 0
  and .normal.pending_rpc.elapsed_ms <= 2000
  and .normal.pending_rpc.replay_count == 0
  and .normal.resume.first_frame == "RESUME"
  and .normal.resume.agent_ready_http == 200
  and .normal.after.runtime_container_pid == .normal.before.runtime_container_pid
  and .normal.after.agent_pid == .normal.before.agent_pid
  and .normal.after.worker_pid == .normal.before.worker_pid
  and .normal.after.worker_generation == .normal.before.worker_generation
  and .normal.after.session_id == .normal.before.session_id
  and .normal.after.heartbeat_cursor_us > .normal.before.heartbeat_cursor_us
  and .normal.after.indicator_cursor > .normal.before.indicator_cursor
  and .normal.after.income_cursor > .normal.before.income_cursor
  and .normal.after.wallet_effect_count == 1
  and .negative.credential_revoke.reconnect_storm == false
  and .negative.credential_revoke.reconnect_attempts == 1
  and .negative.credential_revoke.safe_stop == true
  and .negative.terminal_grace.resume_rejected == true
  and .negative.terminal_grace.grpc_code == "FailedPrecondition"
  and .negative.terminal_grace.reconnect_storm == false
  and .negative.terminal_grace.safe_stop == true
  and .cleanup.owned_only == true
  and .cleanup.artifacts_removed == true
' "${evidence}" >/dev/null || fail "evidence contract is incomplete"

expected_actions="${FIXTURE}/expected-actions"
cat >"${expected_actions}" <<'ACTIONS'
preflight
create-normal
snapshot-before
stop-control-panel
snapshot-disconnected
pending-rpc
start-control-panel
wait-resume
advance-data
snapshot-after
create-revoke
revoke-credential
assert-revoke-terminal
create-terminal-grace
exceed-terminal-grace
assert-terminal-resume-rejected
cleanup
ACTIONS
cmp -s "${expected_actions}" "${FIXTURE}/driver.log" \
  || fail "orchestration omitted, reordered, or replayed a phase"

grep -Fq 'runtime-channel restart acceptance: PASS' "${FIXTURE}/stdout.log" \
  || fail "harness did not print final PASS"

: >"${FIXTURE}/driver.log"
mkdir -m 0700 "${FIXTURE}/failure-state"
if RUNTIME_RESTART_DRIVER="${FIXTURE}/driver" \
    RUNTIME_RESTART_DRIVER_LOG="${FIXTURE}/driver.log" \
    RUNTIME_RESTART_DRIVER_FAIL_AT=create-normal \
    HUSHINE_RUNTIME_RESTART_CONTRACT=1 \
    bash "${HARNESS}" --state-dir "${FIXTURE}/failure-state" \
      >"${FIXTURE}/failure-stdout.log" 2>"${FIXTURE}/failure-stderr.log"; then
  fail "injected live-action failure did not stop the harness"
fi
cat >"${FIXTURE}/failure-actions" <<'ACTIONS'
preflight
create-normal
cleanup
ACTIONS
cmp -s "${FIXTURE}/failure-actions" "${FIXTURE}/driver.log" \
  || fail "failure path continued after error or skipped cleanup"
echo "runtime-channel restart contract: PASS"
