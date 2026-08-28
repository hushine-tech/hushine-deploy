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
scenario="${RUNTIME_RESTART_DRIVER_SCENARIO:-pass}"
if [[ "${RUNTIME_RESTART_DRIVER_FAIL_AT:-}" == "${action}" ]]; then
  echo "injected ${action} failure" >&2
  exit 97
fi
case "${action}" in
  preflight)
    mkdir -p "${RUNTIME_RESTART_CONTRACT_STATE}/runtimes/normal"
    chmod 0700 "${RUNTIME_RESTART_CONTRACT_STATE}" "${RUNTIME_RESTART_CONTRACT_STATE}/runtimes" "${RUNTIME_RESTART_CONTRACT_STATE}/runtimes/normal"
    jq -nc '{
      schema:2,mode:"contract",
      owner_token:"0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
      generation:"generation-0123456789abcdef0123456789abcdef",
      service_baseline:{was_running:true,config:"./config.local.yaml",ready_http:200,pid:4000},
      control_panel_stopped:false,fast_control:false,
      auth:{token:"contract.token.value",user_id:42},
      market:{symbol:"RCR0123456789ABUSDT",lower:"rcr0123456789abusdt",source:"runtime-channel-restart:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",database_created:false},
      normal:{provisioning:"ready",runtime_id:"selfhosted-abcdefghijklmnopqrstuv",credential_key_id:"abcdefghijklmnopqrstuv",container_name:"hushine-runtime-restart-normal-0123456789",runtime_root:"CONTRACT_RUNTIME_ROOT",portfolio_id:101,venue_id:201,strategy_id:301,session_id:"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}
    }' | sed "s#CONTRACT_RUNTIME_ROOT#${RUNTIME_RESTART_CONTRACT_STATE}/runtimes/normal#" >"${RUNTIME_RESTART_CONTRACT_STATE}/live-state.json"
    chmod 0600 "${RUNTIME_RESTART_CONTRACT_STATE}/live-state.json"
    jq -nc '{ok:true}'
    ;;
  create-normal)
    if [[ -n "${RUNTIME_RESTART_DRIVER_PARTIAL_AT:-}" ]]; then
      provisioning=credential_issued
      [[ "${RUNTIME_RESTART_DRIVER_PARTIAL_AT}" == "credential-issued" ]] \
        || provisioning=container_created
      temporary="${RUNTIME_RESTART_CONTRACT_STATE}/partial.tmp"
      jq --arg provisioning "${provisioning}" \
        '.normal={provisioning:$provisioning,runtime_id:"selfhosted-abcdefghijklmnopqrstuv",credential_key_id:"abcdefghijklmnopqrstuv",container_name:"hushine-runtime-restart-normal-0123456789",runtime_root:(.normal.runtime_root)}' \
        "${RUNTIME_RESTART_CONTRACT_STATE}/live-state.json" >"${temporary}"
      chmod 0600 "${temporary}"
      mv "${temporary}" "${RUNTIME_RESTART_CONTRACT_STATE}/live-state.json"
      exit 97
    fi
    jq -nc '{owner_token:"0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",runtime_id:"selfhosted-abcdefghijklmnopqrstuv",session_id:"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",credential_key_id:"abcdefghijklmnopqrstuv",container_name:"hushine-runtime-restart-normal-0123456789"}'
    ;;
  snapshot-before)
    jq -nc '{runtime_container_pid:4100,agent_pid:1,worker_pid:77,worker_generation:1,session_id:"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",session_status:"running",heartbeat_cursor_us:1000,heartbeat_at:"2026-08-28T01:00:00Z",indicator_cursor:1023,income_cursor:0,wallet_effect_count:0,agent_health_http:200,agent_ready_http:200,wallet:{wallet_balance:"100000.000000000000000000",available_balance:"99900.000000000000000000",total_value:"100100.000000000000000000",last_applied_income_entry_id:0}}'
    ;;
  start-pending-platform-rpc)
    jq -nc '{correlation_id:"pending-contract",caller:"python-worker",method:"notification.Publish",worker_started:true,worker_pid:77,proxy_produce_count:1,platform_execution_count:1}'
    ;;
  stop-control-panel)
    jq -e '.control_panel_stopped == true and .service_baseline.was_running == true' "${RUNTIME_RESTART_CONTRACT_STATE}/live-state.json" >/dev/null
    jq -nc '{stopped:true,only_control_panel:true}'
    ;;
  snapshot-disconnected)
    jq -nc '{runtime_container_pid:4100,agent_pid:1,worker_pid:77,worker_generation:1,session_id:"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",session_status:"running",heartbeat_cursor_us:1000,heartbeat_at:"2026-08-28T01:00:00Z",indicator_cursor:1023,income_cursor:0,wallet_effect_count:0,agent_health_http:200,agent_ready_http:503,wallet:{wallet_balance:"100000.000000000000000000",available_balance:"99900.000000000000000000",total_value:"100100.000000000000000000",last_applied_income_entry_id:0}}'
    ;;
  observe-pending-platform-rpc)
    jq -nc '{correlation_id:"pending-contract",caller_completed:true,caller_grpc_code:"Unavailable",caller_elapsed_ms:187,caller_completion_count:1,worker_pid:77,proxy_produce_count:1,platform_execution_count:1}'
    ;;
  start-control-panel)
    jq -nc '{started:true}'
    ;;
  wait-resume)
    case "${scenario}" in
      hello_fallback) credential=active; consumed="";;
      *) credential=consumed; consumed="selfhosted-abcdefghijklmnopqrstuv";;
    esac
    lease_count=1
    [[ "${scenario}" != "multiple_leases" ]] || lease_count=2
    jq -nc --arg status "${credential}" --arg consumed "${consumed}" --argjson count "${lease_count}" '{observed_at:"2026-08-28T01:00:02Z",agent_ready_http:200,runtime_status:"active",credential:{status:$status,consumed_runtime_id:$consumed},lease_before:{issued_at:"2026-08-28T01:00:00Z",updated_at:"2026-08-28T01:00:00Z",row_count:1},lease_after:{issued_at:"2026-08-28T01:00:00Z",updated_at:"2026-08-28T01:00:02Z",row_count:$count},connection_owner_before:{instance_id:"control-a",acquired_at:"2026-08-28T00:59:59Z"},connection_owner_after:{instance_id:"control-b",acquired_at:"2026-08-28T01:00:01Z"},admission_failures:0}'
    ;;
  observe-pending-after-resume)
    count=1
    [[ "${scenario}" != "replay" ]] || count=2
    window=8
    [[ "${scenario}" != "short_horizon" ]] || window=6
    jq -nc --argjson count "${count}" --argjson window "${window}" \
      '{correlation_id:"pending-contract",platform_execution_count:$count,proxy_produce_count:$count,caller_completion_count:1,observation_window_seconds:$window}'
    ;;
  advance-data)
    jq -nc '{advanced:true}'
    ;;
  snapshot-after)
    delta="-0.100000000000000000"
    [[ "${scenario}" != "wallet_double_apply" ]] || delta="-0.200000000000000000"
    wallet="99999.900000000000000000"; available="99899.900000000000000000"; total="100099.900000000000000000"
    if [[ "${scenario}" == "wallet_double_apply" ]]; then
      wallet="99999.800000000000000000"; available="99899.800000000000000000"; total="100099.800000000000000000"
    fi
    jq -nc --arg wallet "${wallet}" --arg available "${available}" --arg total "${total}" '{runtime_container_pid:4100,agent_pid:1,worker_pid:77,worker_generation:1,session_id:"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",session_status:"running",heartbeat_cursor_us:3000,heartbeat_at:"2026-08-28T01:00:03Z",indicator_cursor:1025,income_cursor:9,wallet_effect_count:1,agent_health_http:200,agent_ready_http:200,wallet:{wallet_balance:$wallet,available_balance:$available,total_value:$total,last_applied_income_entry_id:9},income:{income_entry_id:9,applied_amount:"-0.100000000000000000",asset:"USDT"}}'
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
    jq -e '.control_panel_stopped == true and .fast_control == true' "${RUNTIME_RESTART_CONTRACT_STATE}/live-state.json" >/dev/null
    jq -nc '{terminalized:true,grace_seconds:3}'
    ;;
  assert-terminal-resume-rejected)
    jq -nc '{resume_rejected:true,grpc_code:"FailedPrecondition",safe_stop:true,reconnect_attempts:1,reconnect_storm:false,agent_exit_code:1,matching_failure_rows:[{failure_code:"failed_precondition",attempt_count:1}]}'
    ;;
  validate-cleanup-ownership)
    jq -nc --slurpfile states "${RUNTIME_RESTART_CONTRACT_STATE}/live-state.json" '($states[0]) as $state | {
      relationships_valid:(
        $state.auth.user_id == 42
        and $state.normal.runtime_id == "selfhosted-abcdefghijklmnopqrstuv"
        and $state.normal.credential_key_id == "abcdefghijklmnopqrstuv"
        and (($state.normal.provisioning // "ready") != "ready" or (
          $state.normal.portfolio_id == 101
          and $state.normal.venue_id == 201
          and $state.normal.strategy_id == 301
          and $state.normal.session_id == "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"))
      ),
      container_labels_valid:true,
      market_ownership_valid:true
    }'
    ;;
  restore-control-panel)
    [[ "${scenario}" != "restore_failure" ]] || exit 96
    jq -nc '{baseline_restored:true,config:"./config.local.yaml",ready_http:200}'
    ;;
  cleanup)
    [[ "${scenario}" != "cleanup_failure" ]] || exit 95
    for step in order portfolio control market; do
      if ! jq -e --arg step "${step}" '.cleanup_progress[$step] == true' \
          "${RUNTIME_RESTART_CONTRACT_STATE}/live-state.json" >/dev/null; then
        temporary="${RUNTIME_RESTART_CONTRACT_STATE}/cleanup.tmp"
        jq --arg step "${step}" '.cleanup_progress[$step]=true' \
          "${RUNTIME_RESTART_CONTRACT_STATE}/live-state.json" >"${temporary}"
        chmod 0600 "${temporary}"
        mv "${temporary}" "${RUNTIME_RESTART_CONTRACT_STATE}/live-state.json"
        [[ "${scenario}" != "cleanup_after_${step}" ]] || exit 95
      fi
    done
    jq -nc '{ownership_validated:true,owned_only:true,artifacts_removed:true}'
    ;;
  *)
    echo "unexpected driver action: ${action}" >&2
    exit 64
    ;;
esac
DRIVER
chmod 0700 "${FIXTURE}/driver"

[[ -x "${HARNESS}" ]] || fail "missing executable harness: ${HARNESS}"
[[ -x "${DEPLOY_ROOT}/scripts/runtime-channel-kafka-proxy-integration.test.sh" ]] \
  || fail "missing executable real Kafka proxy integration"
grep -Fq 'github.com/IBM/sarama' "${DEPLOY_ROOT}/scripts/runtime-channel-kafka-proxy-integration.go" \
  || fail "Kafka proxy integration does not use the production Sarama client"
grep -Fq 'sarama.NewSyncProducer' "${DEPLOY_ROOT}/scripts/runtime-channel-kafka-proxy-integration.go" \
  || fail "Kafka proxy integration does not exercise SyncProducer"

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
  'caller_grpc_code == "Unavailable"' \
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

for existing_case in valid-looking tampered; do
  existing_state="${FIXTURE}/existing-${existing_case}"
  mkdir -m 0700 "${existing_state}"
  if [[ "${existing_case}" == "valid-looking" ]]; then
    jq -nc '{schema:2,mode:"contract",owner_token:("a" * 64)}' >"${existing_state}/live-state.json"
  else
    printf '%s\n' '{"schema":2,"owner_token":"x\u0027;DROP TABLE users;--"' >"${existing_state}/live-state.json"
  fi
  chmod 0600 "${existing_state}/live-state.json"
  : >"${existing_state}.log"
  if RUNTIME_RESTART_DRIVER="${FIXTURE}/driver" \
      RUNTIME_RESTART_DRIVER_LOG="${existing_state}.log" \
      HUSHINE_RUNTIME_RESTART_CONTRACT=1 \
      bash "${HARNESS}" --state-dir "${existing_state}" \
        >"${existing_state}.stdout" 2>"${existing_state}.stderr"; then
    fail "normal execution resumed a pre-existing ${existing_case} state"
  fi
  [[ ! -s "${existing_state}.log" ]] \
    || fail "pre-existing ${existing_case} state executed a driver mutation"
  grep -Fq -- '--cleanup-only' "${existing_state}.stderr" \
    || fail "pre-existing ${existing_case} state did not direct cleanup-only"
done

evidence="${FIXTURE}/evidence.json"
mkdir -m 0700 "${FIXTURE}/state"
if ! RUNTIME_RESTART_DRIVER="${FIXTURE}/driver" \
    RUNTIME_RESTART_DRIVER_LOG="${FIXTURE}/driver.log" \
    RUNTIME_RESTART_CONTRACT_STATE="${FIXTURE}/state" \
    HUSHINE_RUNTIME_RESTART_CONTRACT=1 \
    bash "${HARNESS}" --state-dir "${FIXTURE}/state" \
      --evidence-file "${evidence}" >"${FIXTURE}/stdout.log" 2>"${FIXTURE}/stderr.log"; then
  fail "harness did not derive and validate raw restart observations: stderr=$(tr '\n' ' ' <"${FIXTURE}/stderr.log"); actions=$(tr '\n' ',' <"${FIXTURE}/driver.log"); state=$(jq -c . "${FIXTURE}/state/live-state.json" 2>/dev/null || true)"
fi

jq -e '
  .schema == 1
  and .result == "PASS"
  and .normal.fixture == {
    owner_token:"0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
    runtime_id:"selfhosted-abcdefghijklmnopqrstuv",
    session_id:"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
    credential_key_id:"abcdefghijklmnopqrstuv",
    container_name:"hushine-runtime-restart-normal-0123456789"
  }
  and .normal.before.runtime_container_pid == 4100
  and .normal.before.agent_pid == 1
  and .normal.before.worker_pid == 77
  and .normal.before.worker_generation == 1
  and .normal.before.session_id == "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
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
  and .normal.pending_rpc.platform_execution_count == 1
  and .normal.pending_rpc.proxy_produce_count == 1
  and .normal.pending_rpc.observation_window_seconds >= 7
  and .normal.pending_rpc.observation_source == "worker+kafka"
  and .normal.resume.first_frame == "RESUME"
  and .normal.resume.agent_ready_http == 200
  and .normal.resume.proof.credential_status == "consumed"
  and .normal.resume.proof.lease_row_count == 1
  and .normal.after.runtime_container_pid == .normal.before.runtime_container_pid
  and .normal.after.agent_pid == .normal.before.agent_pid
  and .normal.after.worker_pid == .normal.before.worker_pid
  and .normal.after.worker_generation == .normal.before.worker_generation
  and .normal.after.session_id == .normal.before.session_id
  and .normal.after.heartbeat_cursor_us > .normal.before.heartbeat_cursor_us
  and .normal.after.indicator_cursor > .normal.before.indicator_cursor
  and .normal.after.income_cursor > .normal.before.income_cursor
  and .normal.after.wallet_effect_count == 1
  and .normal.funding_exactly_once.expected_wallet_delta == "-0.100000000000000000"
  and .normal.funding_exactly_once.actual_wallet_delta == "-0.100000000000000000"
  and .normal.funding_exactly_once.income_entry_id == 9
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
start-pending-platform-rpc
stop-control-panel
snapshot-disconnected
observe-pending-platform-rpc
start-control-panel
wait-resume
observe-pending-after-resume
advance-data
snapshot-after
create-revoke
revoke-credential
assert-revoke-terminal
create-terminal-grace
exceed-terminal-grace
assert-terminal-resume-rejected
restore-control-panel
validate-cleanup-ownership
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
    RUNTIME_RESTART_CONTRACT_STATE="${FIXTURE}/failure-state" \
    RUNTIME_RESTART_DRIVER_FAIL_AT=create-normal \
    HUSHINE_RUNTIME_RESTART_CONTRACT=1 \
    bash "${HARNESS}" --state-dir "${FIXTURE}/failure-state" \
      >"${FIXTURE}/failure-stdout.log" 2>"${FIXTURE}/failure-stderr.log"; then
  fail "injected live-action failure did not stop the harness"
fi
cat >"${FIXTURE}/failure-actions" <<'ACTIONS'
preflight
create-normal
restore-control-panel
validate-cleanup-ownership
cleanup
ACTIONS
cmp -s "${FIXTURE}/failure-actions" "${FIXTURE}/driver.log" \
  || fail "failure path continued after error or skipped cleanup"

run_service_recovery_failure() {
  local fail_at="$1" state
  state="${FIXTURE}/service-failure-${fail_at}"
  mkdir -m 0700 "${state}"
  : >"${state}.log"
  if RUNTIME_RESTART_DRIVER="${FIXTURE}/driver" \
      RUNTIME_RESTART_DRIVER_LOG="${state}.log" \
      RUNTIME_RESTART_CONTRACT_STATE="${state}" \
      RUNTIME_RESTART_DRIVER_FAIL_AT="${fail_at}" \
      HUSHINE_RUNTIME_RESTART_CONTRACT=1 \
      bash "${HARNESS}" --state-dir "${state}" >"${state}.stdout" 2>"${state}.stderr"; then
    fail "injected ${fail_at} failure did not fail"
  fi
  grep -Fxq restore-control-panel "${state}.log" \
    || fail "injected ${fail_at} failure did not restore control-panel"
  [[ "$(grep -Fxc cleanup "${state}.log")" == "1" ]] \
    || fail "injected ${fail_at} failure did not run exact cleanup"
}

run_service_recovery_failure snapshot-disconnected
run_service_recovery_failure start-control-panel
run_service_recovery_failure assert-terminal-resume-rejected

for partial_at in credential-issued container-created readiness-timeout; do
  partial_state="${FIXTURE}/partial-${partial_at}"
  mkdir -m 0700 "${partial_state}"
  : >"${partial_state}.log"
  if RUNTIME_RESTART_DRIVER="${FIXTURE}/driver" \
      RUNTIME_RESTART_DRIVER_LOG="${partial_state}.log" \
      RUNTIME_RESTART_DRIVER_PARTIAL_AT="${partial_at}" \
      HUSHINE_RUNTIME_RESTART_CONTRACT=1 \
      bash "${HARNESS}" --state-dir "${partial_state}" \
        >"${partial_state}.stdout" 2>"${partial_state}.stderr"; then
    fail "partial provisioning ${partial_at} unexpectedly passed"
  fi
  expected_provisioning=container_created
  [[ "${partial_at}" == "credential-issued" ]] && expected_provisioning=credential_issued
  jq -e --arg expected "${expected_provisioning}" '
    .normal.provisioning == $expected
    and .normal.runtime_id == "selfhosted-abcdefghijklmnopqrstuv"
    and .normal.credential_key_id == "abcdefghijklmnopqrstuv"
    and .normal.container_name == "hushine-runtime-restart-normal-0123456789"
    and (.normal.runtime_root | endswith("/runtimes/normal"))
  ' "${partial_state}/live-state.json" >/dev/null \
    || fail "partial provisioning ${partial_at} did not persist exact ownership"
  cat >"${partial_state}.expected" <<'ACTIONS'
preflight
create-normal
restore-control-panel
validate-cleanup-ownership
cleanup
ACTIONS
  cmp -s "${partial_state}.expected" "${partial_state}.log" \
    || fail "partial provisioning ${partial_at} did not clean exactly"
done

for cleanup_step in order portfolio control market; do
  cleanup_state="${FIXTURE}/cleanup-resume-${cleanup_step}"
  mkdir -m 0700 "${cleanup_state}"
  : >"${cleanup_state}.log"
  if RUNTIME_RESTART_DRIVER="${FIXTURE}/driver" \
      RUNTIME_RESTART_DRIVER_LOG="${cleanup_state}.log" \
      RUNTIME_RESTART_DRIVER_SCENARIO="cleanup_after_${cleanup_step}" \
      HUSHINE_RUNTIME_RESTART_CONTRACT=1 \
      bash "${HARNESS}" --state-dir "${cleanup_state}" \
        >"${cleanup_state}.stdout" 2>"${cleanup_state}.stderr"; then
    fail "injected cleanup-after-${cleanup_step} failure unexpectedly passed"
  fi
  RUNTIME_RESTART_DRIVER="${FIXTURE}/driver" \
    RUNTIME_RESTART_DRIVER_LOG="${cleanup_state}.log" \
    RUNTIME_RESTART_DRIVER_SCENARIO="cleanup_after_${cleanup_step}" \
    HUSHINE_RUNTIME_RESTART_CONTRACT=1 \
    bash "${HARNESS}" --state-dir "${cleanup_state}" --cleanup-only \
      >"${cleanup_state}.cleanup.stdout" 2>"${cleanup_state}.cleanup.stderr" \
    || fail "cleanup-only did not resume after ${cleanup_step} cleanup failure"
  [[ "$(tail -n 3 "${cleanup_state}.log" | tr '\n' ' ')" == \
      "restore-control-panel validate-cleanup-ownership cleanup " ]] \
    || fail "cleanup-only did not restore before validate/cleanup after ${cleanup_step}"
  jq -e '.cleanup_progress == {order:true,portfolio:true,control:true,market:true}' \
    "${cleanup_state}/live-state.json" >/dev/null \
    || fail "cleanup-only did not complete all DB progress after ${cleanup_step}"
done

run_false_positive() {
  local scenario="$1" state
  state="${FIXTURE}/false-${scenario}"
  mkdir -m 0700 "${state}"
  : >"${state}.log"
  if RUNTIME_RESTART_DRIVER="${FIXTURE}/driver" \
      RUNTIME_RESTART_DRIVER_LOG="${state}.log" \
      RUNTIME_RESTART_CONTRACT_STATE="${state}" \
      RUNTIME_RESTART_DRIVER_SCENARIO="${scenario}" \
      HUSHINE_RUNTIME_RESTART_CONTRACT=1 \
      bash "${HARNESS}" --state-dir "${state}" >"${state}.stdout" 2>"${state}.stderr"; then
    fail "false-positive scenario passed: ${scenario}"
  fi
}

for scenario in replay short_horizon hello_fallback multiple_leases wallet_double_apply cleanup_failure restore_failure; do
  run_false_positive "${scenario}"
done

make_manifest() {
  local destination="$1"
  mkdir -m 0700 "${destination}"
  RUNTIME_RESTART_DRIVER_LOG="${destination}.setup.log" \
    RUNTIME_RESTART_CONTRACT_STATE="${destination}" \
    "${FIXTURE}/driver" preflight >/dev/null
}

assert_tamper_rejected_without_cleanup() {
  local label="$1" filter="$2" state
  state="${FIXTURE}/tamper-${label}"
  make_manifest "${state}"
  jq "${filter}" "${state}/live-state.json" >"${state}/tampered.json"
  mv "${state}/tampered.json" "${state}/live-state.json"
  chmod 0600 "${state}/live-state.json"
  : >"${state}.log"
  if RUNTIME_RESTART_DRIVER="${FIXTURE}/driver" \
      RUNTIME_RESTART_DRIVER_LOG="${state}.log" \
      RUNTIME_RESTART_CONTRACT_STATE="${state}" \
      HUSHINE_RUNTIME_RESTART_CONTRACT=1 \
      bash "${HARNESS}" --state-dir "${state}" --cleanup-only \
        >"${state}.stdout" 2>"${state}.stderr"; then
    fail "tampered cleanup manifest passed: ${label}"
  fi
  if grep -Eq '^(restore-control-panel|cleanup)$' "${state}.log"; then
    fail "tampered cleanup executed a mutating action: ${label}"
  fi
}

assert_tamper_rejected_without_cleanup user_id '.auth.user_id=43'
assert_tamper_rejected_without_cleanup session_id '.normal.session_id="bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"'
assert_tamper_rejected_without_cleanup runtime_id '.normal.runtime_id="selfhosted-zyxwvutsrqponmlkjihgfe"'
assert_tamper_rejected_without_cleanup credential_id '.normal.credential_key_id="zyxwvutsrqponmlkjihgfe"'
assert_tamper_rejected_without_cleanup portfolio_id '.normal.portfolio_id=999'
assert_tamper_rejected_without_cleanup owner '.owner_token="ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff"'
assert_tamper_rejected_without_cleanup source '.market.source="runtime-channel-restart:ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff"'
assert_tamper_rejected_without_cleanup symbol '.market.symbol="RCRFFFFFFFFFFFFUSDT"'
assert_tamper_rejected_without_cleanup injection '.normal.session_id="x\u0027;DROP TABLE users;--"'
assert_tamper_rejected_without_cleanup mode '.mode="live"'

mode_state="${FIXTURE}/tamper-file-mode"
make_manifest "${mode_state}"
chmod 0644 "${mode_state}/live-state.json"
: >"${mode_state}.log"
if RUNTIME_RESTART_DRIVER="${FIXTURE}/driver" \
    RUNTIME_RESTART_DRIVER_LOG="${mode_state}.log" \
    RUNTIME_RESTART_CONTRACT_STATE="${mode_state}" \
    HUSHINE_RUNTIME_RESTART_CONTRACT=1 \
    bash "${HARNESS}" --state-dir "${mode_state}" --cleanup-only \
      >"${mode_state}.stdout" 2>"${mode_state}.stderr"; then
  fail "wrong-mode cleanup manifest passed"
fi
[[ ! -s "${mode_state}.log" ]] || fail "wrong-mode manifest executed a cleanup action"

diagnostic_input="${FIXTURE}/docker-inspect.json"
diagnostic_output="${FIXTURE}/docker-diagnostic.json"
jq -nc '[{Id:"sha256:container",Config:{Image:"runtime-image",Env:["RUNTIME_CREDENTIAL_JSON=PRIVATE_KEY","RUNTIME_CHANNEL_TLS_BUNDLE_JSON=TLS_SECRET"],Labels:{"hushine.acceptance.runtime-restart":"0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef","secret":"do-not-retain"}},State:{Status:"running",Running:true,Pid:9191,ExitCode:0,Error:""}}]' >"${diagnostic_input}"
bash "${HARNESS}" --sanitize-docker-inspect "${diagnostic_input}" \
  --diagnostic-output "${diagnostic_output}"
jq -e '.pid == 9191 and .status == "running" and .running == true and .exit_code == 0 and .image == "runtime-image" and (.safe_labels | keys == ["hushine.acceptance.runtime-restart"])' "${diagnostic_output}" >/dev/null \
  || fail "diagnostic allow-list projection is incomplete"
if grep -Eq 'PRIVATE_KEY|TLS_SECRET|RUNTIME_CREDENTIAL_JSON|RUNTIME_CHANNEL_TLS_BUNDLE_JSON|do-not-retain' "${diagnostic_output}"; then
  fail "diagnostic projection retained forbidden credential material"
fi

control_pid_file="${FIXTURE}/control.run.pid"
printf '%s\n' "$$" >"${control_pid_file}"
bash "${HARNESS}" --validate-control-owner "${control_pid_file}" --listener-pid "$$" \
  >"${FIXTURE}/control-owner.stdout" 2>"${FIXTURE}/control-owner.stderr" \
  || fail "matching managed/listener control-panel PID was rejected"
if bash "${HARNESS}" --validate-control-owner "${control_pid_file}" --listener-pid "$(( $$ + 1000000 ))" \
    >"${FIXTURE}/control-mismatch.stdout" 2>"${FIXTURE}/control-mismatch.stderr"; then
  fail "mismatched managed/listener control-panel PID passed"
fi
grep -Fq 'environmental blocker: managed control-panel PID' "${FIXTURE}/control-mismatch.stderr" \
  || fail "control-panel ownership mismatch was not explicit"

python3 - "${HARNESS}" "${DEPLOY_ROOT}/../strategy-service/tests/strategies/indicator_v2_open_time_cutover.py" <<'PY'
import ast
import pathlib
import subprocess
import sys

harness = pathlib.Path(sys.argv[1]).read_text(encoding="utf-8")
fixture = sys.argv[2]
function = harness.split("create_strategy_source() {", 1)[1]
program = function.split("<<'PY'\n", 1)[1].split("\nPY\n", 1)[0]
completed = subprocess.run(
    [sys.executable, "-", fixture, "a" * 64, "generation-" + "b" * 32, "RCRAAAAAAAAAAAAUSDT"],
    input=program,
    text=True,
    capture_output=True,
    check=True,
)
generated = completed.stdout
ast.parse(generated)
assert "threading.Thread" not in generated
assert "self._run_acceptance_pending_call(pending)" in generated
assert 'armed_file' in generated and 'release_file' in generated
assert 'session_binding_file' in generated
assert 'self._read_private_json(binding_path)' in generated
assert 'session binding ownership changed' in generated
assert 'pending_call arm ownership changed' in generated
assert 'release ownership changed' in generated
pending_phase = harness.split("    start-pending-platform-rpc)", 1)[1].split("    stop-control-panel)", 1)[0]
advance_phase = harness.split("    advance-data)", 1)[1].split("    create-revoke)", 1)[0]
fixture_phase = harness.split("create_normal_fixture() {", 1)[1].split("\nsession_status() {", 1)[0]
runtime_phase = harness.split("start_owned_runtime() {", 1)[1].split("\ncreate_strategy_source() {", 1)[0]
cleanup_phase = harness.split("cleanup_live() {", 1)[1].split("\nlive_action() {", 1)[0]
stop_phase = harness.split("    stop-control-panel)", 1)[1].split("    observe-pending-platform-rpc)", 1)[0]
assert "runtime-restart-barrier.json" not in pending_phase
assert "runtime-restart-barrier.json" not in advance_phase
assert 'create_once_json "${armed_file}"' in pending_phase
assert 'create_once_json "${release}"' in advance_phase
assert '--arg owner_token "${owner}"' in pending_phase
assert '--arg owner_token "$(state_get .owner_token)"' in advance_phase
assert fixture_phase.count('create_once_json "${runtime_root}/runtime-restart-barrier.json"') == 1
assert 'create_once_json "${runtime_root}/session-binding.json"' in fixture_phase
assert '.session_id=$session' not in fixture_phase
credential_checkpoint = runtime_phase.index('provisioning:"credential_issued"')
docker_run = runtime_phase.index('docker run')
container_checkpoint = runtime_phase.index('--arg provisioning "container_created"')
readiness_wait = runtime_phase.index('agent readiness')
ready_checkpoint = runtime_phase.index('--arg provisioning "ready"')
assert credential_checkpoint < docker_run < container_checkpoint < readiness_wait < ready_checkpoint
for cleanup_step in ("order", "portfolio", "control", "market"):
    assert f'cleanup_step_done {cleanup_step}' in cleanup_phase
    assert f'mark_cleanup_step {cleanup_step}' in cleanup_phase
    assert f'if ! cleanup_step_done {cleanup_step}' not in cleanup_phase
assert "'issued_at',l.issued_at::text,'updated_at',l.updated_at::text" in stop_phase
PY

python3 - "${DEPLOY_ROOT}/scripts/runtime-channel-kafka-hold-proxy.py" "${FIXTURE}/proxy-test" <<'PY'
import importlib.util
import json
import socket
import struct
import sys
import threading
import time
from pathlib import Path

spec = importlib.util.spec_from_file_location("task8_kafka_proxy", sys.argv[1])
module = importlib.util.module_from_spec(spec)
assert spec.loader is not None
spec.loader.exec_module(module)
control = Path(sys.argv[2])
control.mkdir(mode=0o700)
correlation = "rpc-contract-framing"
module.atomic_json(control / "hold.json", {"schema": 1, "correlation_id": correlation})
proxy = module.HoldProxy("127.0.0.1", 9092, control)
proxy.set_advertised_endpoint("127.0.0.1", 19092)
produce_client, produce_proxy = socket.socketpair()
produce_upstream, produce_broker = socket.socketpair()
metadata_client, metadata_proxy = socket.socketpair()
metadata_upstream, metadata_broker = socket.socketpair()
threading.Thread(target=proxy.client_to_broker, args=(1, produce_proxy, produce_upstream), daemon=True).start()
threading.Thread(target=proxy.broker_to_client, args=(1, produce_upstream, produce_proxy), daemon=True).start()
threading.Thread(target=proxy.client_to_broker, args=(2, metadata_proxy, metadata_upstream), daemon=True).start()
threading.Thread(target=proxy.broker_to_client, args=(2, metadata_upstream, metadata_proxy), daemon=True).start()

# Two connections deliberately reuse correlation 73. Only the Produce response
# on connection 1 may be held; Metadata on connection 2 must be routed back to
# the proxy endpoint so a real Sarama producer cannot bypass it.
produce_body = struct.pack(">hhi", 0, 3, 73) + struct.pack(">h", 6) + b"sarama" + correlation.encode()
produce_request = struct.pack(">i", len(produce_body)) + produce_body
produce_client.sendall(produce_request)
assert module.recv_frame(produce_broker) == produce_request
deadline = time.monotonic() + 2
while not (control / "produce-observation.json").exists() and time.monotonic() < deadline:
    time.sleep(0.01)
raw = json.loads((control / "produce-observation.json").read_text())
assert raw["produce_request_count"] == 1 and raw["correlation_id"] == correlation

metadata_body = struct.pack(">hhi", 3, 7, 73) + struct.pack(">h", 6) + b"sarama" + struct.pack(">i", 0)
metadata_request = struct.pack(">i", len(metadata_body)) + metadata_body
metadata_client.sendall(metadata_request)
assert module.recv_frame(metadata_broker) == metadata_request
metadata_response_body = (
    struct.pack(">iii", 73, 0, 1)
    + struct.pack(">i", 1)
    + struct.pack(">h", 5) + b"kafka"
    + struct.pack(">i", 9092)
    + struct.pack(">h", -1)
    + struct.pack(">h", -1)
    + struct.pack(">i", 1)
    + struct.pack(">i", 0)
)
metadata_response = struct.pack(">i", len(metadata_response_body)) + metadata_response_body
metadata_broker.sendall(metadata_response)
rewritten = module.recv_frame(metadata_client)
assert rewritten is not None
body = rewritten[4:]
offset = 4 + 4 + 4 + 4
(host_size,) = struct.unpack(">h", body[offset:offset + 2])
offset += 2
assert body[offset:offset + host_size] == b"127.0.0.1"
offset += host_size
(advertised_port,) = struct.unpack(">i", body[offset:offset + 4])
assert advertised_port == 19092

produce_response_body = struct.pack(">i", 73) + b"held-response"
produce_response = struct.pack(">i", len(produce_response_body)) + produce_response_body
produce_broker.sendall(produce_response)
deadline = time.monotonic() + 2
while not (control / "response-held.json").exists() and time.monotonic() < deadline:
    time.sleep(0.01)
assert (control / "response-held.json").exists()
produce_client.settimeout(0.1)
try:
    produce_client.recv(1)
    raise AssertionError("matching Produce response was not held")
except TimeoutError:
    pass
(control / "hold.json").unlink()
produce_client.settimeout(2)
assert module.recv_frame(produce_client) == produce_response
PY
echo "runtime-channel restart contract: PASS"
