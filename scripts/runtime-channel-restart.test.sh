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
      normal:{runtime_id:"selfhosted-abcdefghijklmnopqrstuv",credential_key_id:"abcdefghijklmnopqrstuv",container_name:"hushine-runtime-restart-normal-0123456789",runtime_root:"CONTRACT_RUNTIME_ROOT",portfolio_id:101,venue_id:201,strategy_id:301,session_id:"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}
    }' | sed "s#CONTRACT_RUNTIME_ROOT#${RUNTIME_RESTART_CONTRACT_STATE}/runtimes/normal#" >"${RUNTIME_RESTART_CONTRACT_STATE}/live-state.json"
    chmod 0600 "${RUNTIME_RESTART_CONTRACT_STATE}/live-state.json"
    jq -nc '{ok:true}'
    ;;
  create-normal)
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
    jq -nc --argjson count "${count}" '{correlation_id:"pending-contract",platform_execution_count:$count,caller_completion_count:1}'
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
        and $state.normal.portfolio_id == 101
        and $state.normal.venue_id == 201
        and $state.normal.strategy_id == 301
        and $state.normal.session_id == "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
        and $state.normal.runtime_id == "selfhosted-abcdefghijklmnopqrstuv"
        and $state.normal.credential_key_id == "abcdefghijklmnopqrstuv"
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
validate-cleanup-ownership
restore-control-panel
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
validate-cleanup-ownership
restore-control-panel
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

for scenario in replay hello_fallback multiple_leases wallet_double_apply cleanup_failure restore_failure; do
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
client_peer, proxy_client = socket.socketpair()
proxy_broker, broker_peer = socket.socketpair()
threading.Thread(target=proxy.client_to_broker, args=(proxy_client, proxy_broker), daemon=True).start()
request_body = struct.pack(">hhi", 0, 9, 73) + correlation.encode()
request = struct.pack(">i", len(request_body)) + request_body
client_peer.sendall(request)
assert module.recv_frame(broker_peer) == request
deadline = time.monotonic() + 2
while not (control / "produce-observation.json").exists() and time.monotonic() < deadline:
    time.sleep(0.01)
raw = json.loads((control / "produce-observation.json").read_text())
assert raw["produce_request_count"] == 1 and raw["correlation_id"] == correlation
threading.Thread(target=proxy.broker_to_client, args=(proxy_broker, proxy_client), daemon=True).start()
response_body = struct.pack(">i", 73) + b"held-response"
response = struct.pack(">i", len(response_body)) + response_body
broker_peer.sendall(response)
deadline = time.monotonic() + 2
while not (control / "response-held.json").exists() and time.monotonic() < deadline:
    time.sleep(0.01)
assert (control / "response-held.json").exists()
client_peer.settimeout(0.1)
try:
    client_peer.recv(1)
    raise AssertionError("matching Produce response was not held")
except TimeoutError:
    pass
(control / "hold.json").unlink()
client_peer.settimeout(2)
assert module.recv_frame(client_peer) == response
PY
echo "runtime-channel restart contract: PASS"
