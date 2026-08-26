#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
SCRIPT="${ROOT}/scripts/runtime-indicator-v2-service-chain.sh"

fail() {
  echo "runtime Indicator V2 service-chain contract: $*" >&2
  exit 1
}

[[ -x "${SCRIPT}" ]] || fail "executable service-chain script is missing"
bash -n "${SCRIPT}" || fail "service-chain script is not valid Bash"

set +e
api_failure_output="$(
  (
    source "${SCRIPT}"
    curl() { return 22; }
    api_json POST 'http://127.0.0.1:1/api/failure-contract' '' '{}'
  ) 2>&1
)"
api_failure_status="$?"
set -e
[[ "${api_failure_status}" -ne 0 ]] || fail "failed API request was accepted"
grep -Fq 'API POST http://127.0.0.1:1/api/failure-contract failed' <<<"${api_failure_output}" \
  || fail "failed API request omitted its endpoint diagnostic"

for function_name in pg_admin pg_database; do
  function_body="$(
    source "${SCRIPT}"
    declare -f "${function_name}"
  )"
  for literal in \
    '-e PGPASSWORD="${PG_PASSWORD}"' \
    '-h "${PG_HOST}"' \
    '-p "${PG_PORT}"'; do
    grep -Fq -- "${literal}" <<<"${function_body}" \
      || fail "${function_name} does not route management SQL to the configured PostgreSQL endpoint: ${literal}"
  done
done

for literal in \
  'start)' \
  'await)' \
  'advance)' \
  'stop)' \
  'open-1023' \
  'finalized-1024-plus-tail' \
  'two-full-plus-tail' \
  'hushine_indicator_chain_' \
  '127.0.0.1' \
  'RUNTIME_COVERAGE_ENABLED=true' \
  'executor-coverage-dev' \
  '/api/auth/signup' \
  '/api/portfolios' \
  '/api/venues' \
  '/api/strategies' \
  '/api/runtimes' \
  '/run-strategy' \
  'strategy_indicator_chunks' \
  'futures_funding_rates_testusdt' \
  'assert_funding_income_once' \
  'assert_blocked_worker_heartbeat' \
  "snapshot_json #>> '{futures,last_applied_income_entry_id}'" \
  'protocol_version' \
  'strategy-debugger-cli' \
  '--expected-shas' \
  'owner_token' \
  'process_start_identity' \
  'evidence_eligible' \
  'source_dirty'; do
  grep -Fq -- "${literal}" "${SCRIPT}" \
    || fail "required contract literal is missing: ${literal}"
done

if grep -Fq 'strategy_path' "${SCRIPT}"; then
  fail "service-chain sends the removed strategy_path compatibility field"
fi
if grep -Fq 'positions:[{' "${SCRIPT}"; then
  fail "service-chain seeds a non-canonical one-way Futures position"
fi

for forbidden in \
  'HUSHINE_INDICATOR_V2_BARRIER_FILE=' \
  'CORE_SERVICE_GRPC_ADDR=' \
  'KAFKA_BROKERS=' \
  'TIMESCALEDB_DSN='; do
  if grep -F -- '-e' "${SCRIPT}" | grep -Fq -- "${forbidden}"; then
    fail "service-chain injects a forbidden generic hosted Runtime env: ${forbidden}"
  fi
done

test_root="$(mktemp -d)"
test_root="$(cd "${test_root}" && pwd -P)"
trap 'rm -rf -- "${test_root}"' EXIT
chmod 0700 "${test_root}"

fake_source="${test_root}/source"
mkdir -p "${fake_source}/gateway"
repositories=(
  core-service
  control-panel-service
  strategy-library
  strategy-service
  strategy-debugger-cli
  scraper
  gateway/quant-handler
  gateway/quant-frontend
  hushine-deploy
)
for repository in "${repositories[@]}"; do
  repository_root="${fake_source}/${repository}"
  mkdir -p "${repository_root}"
  git -C "${repository_root}" init -q
  git -C "${repository_root}" config user.name "Indicator V2 chain test"
  git -C "${repository_root}" config user.email "indicator-v2-chain@example.invalid"
  printf '%s\n' "${repository}" >"${repository_root}/tracked.txt"
  git -C "${repository_root}" add tracked.txt
  git -C "${repository_root}" commit -q -m "fixture"
done

valid_shas="${test_root}/valid-shas.json"
source_sha_map='{}'
for repository in "${repositories[@]}"; do
  repository_sha="$(git -C "${fake_source}/${repository}" rev-parse HEAD)"
  source_sha_map="$(jq -c \
    --arg repository "${repository}" \
    --arg repository_sha "${repository_sha}" \
    '. + {($repository):$repository_sha}' <<<"${source_sha_map}")"
done
jq -S -nc --argjson source_shas "${source_sha_map}" \
  '{schema:1,source_shas:$source_shas}' >"${valid_shas}"
chmod 0600 "${valid_shas}"
(
  export HUSHINE_SOURCE_ROOT="${fake_source}"
  source "${SCRIPT}"
  validate_expected_source_shas "${valid_shas}" >/dev/null
) || fail "valid expected SHA map was rejected because of JSON key order"

clean_evidence="$(
  export HUSHINE_SOURCE_ROOT="${fake_source}"
  source "${SCRIPT}"
  source_evidence_json pre "" false
)"
jq -e '
  .evidence_eligible == true
  and all(.source_dirty[]; . == false)
' <<<"${clean_evidence}" >/dev/null \
  || fail "clean pre-cutover source was not evidence eligible"

printf '%s\n' dirty >>"${fake_source}/core-service/tracked.txt"
if (
  export HUSHINE_SOURCE_ROOT="${fake_source}"
  source "${SCRIPT}"
  source_evidence_json pre "" false
); then
  fail "normal pre-cutover start accepted a dirty repository"
fi
debug_evidence="$(
  export HUSHINE_SOURCE_ROOT="${fake_source}"
  source "${SCRIPT}"
  source_evidence_json pre "" true
)"
jq -e '
  .evidence_eligible == false
  and .source_dirty["core-service"] == true
' <<<"${debug_evidence}" >/dev/null \
  || fail "explicit dirty debug mode was not marked ineligible for sealing"
git -C "${fake_source}/core-service" restore tracked.txt

(
  export HUSHINE_SOURCE_ROOT="${fake_source}"
  source "${SCRIPT}"
  runtime_image_labels_json() {
    jq -nc \
      --arg strategy "$(jq -r '.["strategy-service"]' <<<"${source_sha_map}")" \
      --arg library "$(jq -r '.["strategy-library"]' <<<"${source_sha_map}")" \
      '{
        "org.hushine.runtime.source-dirty":"false",
        "org.hushine.runtime.strategy-service.commit":$strategy,
        "org.hushine.runtime.strategy-library.commit":$library,
        "org.hushine.runtime.golang-lib.commit":"ffffffffffffffffffffffffffffffffffffffff",
        "org.hushine.runtime.source-state.sha256":
          "1111111111111111111111111111111111111111111111111111111111111111",
        "org.hushine.runtime.image-build-id":"fixture-build"
      }'
  }
  golang_lib_sha() {
    printf '%s\n' ffffffffffffffffffffffffffffffffffffffff
  }
  golang_lib_is_clean() { return 0; }
  validate_runtime_image_provenance "${source_sha_map}" true >/dev/null
) || fail "matching clean Runtime image provenance was rejected"

if (
  export HUSHINE_SOURCE_ROOT="${fake_source}"
  source "${SCRIPT}"
  runtime_image_labels_json() {
    jq -nc \
      --arg strategy "$(jq -r '.["strategy-service"]' <<<"${source_sha_map}")" \
      --arg library "$(jq -r '.["strategy-library"]' <<<"${source_sha_map}")" \
      '{
        "org.hushine.runtime.source-dirty":"true",
        "org.hushine.runtime.strategy-service.commit":$strategy,
        "org.hushine.runtime.strategy-library.commit":$library,
        "org.hushine.runtime.golang-lib.commit":"ffffffffffffffffffffffffffffffffffffffff",
        "org.hushine.runtime.source-state.sha256":
          "1111111111111111111111111111111111111111111111111111111111111111",
        "org.hushine.runtime.image-build-id":"fixture-build"
      }'
  }
  golang_lib_sha() {
    printf '%s\n' ffffffffffffffffffffffffffffffffffffffff
  }
  golang_lib_is_clean() { return 0; }
  validate_runtime_image_provenance "${source_sha_map}" true >/dev/null
); then
  fail "evidence-eligible chain accepted a dirty Runtime image"
fi

expected_shas="${test_root}/expected-shas.json"
jq -nc '{
  schema: 1,
  source_shas: {
    "core-service": "0000000000000000000000000000000000000000",
    "control-panel-service": "0000000000000000000000000000000000000000",
    "strategy-library": "0000000000000000000000000000000000000000",
    "strategy-service": "0000000000000000000000000000000000000000",
    "strategy-debugger-cli": "0000000000000000000000000000000000000000",
    "scraper": "0000000000000000000000000000000000000000",
    "gateway/quant-handler": "0000000000000000000000000000000000000000",
    "gateway/quant-frontend": "0000000000000000000000000000000000000000",
    "hushine-deploy": "0000000000000000000000000000000000000000"
  }
}' >"${expected_shas}"
chmod 0600 "${expected_shas}"

set +e
post_output="$(
  "${SCRIPT}" start --phase post \
    --state-dir "${test_root}/post-state" \
    --expected-shas "${expected_shas}" 2>&1
)"
post_status="$?"
set -e
[[ "${post_status}" -ne 0 ]] \
  || fail "post start accepted a stale expected SHA map"
grep -Fq 'source SHA mismatch' <<<"${post_output}" \
  || fail "post start did not fail at the expected SHA boundary"

checked_databases="${test_root}/checked-databases"
admin_calls="${test_root}/admin-calls"
(
  source "${SCRIPT}"
  database_exists() {
    printf '%s\n' "$1" >>"${checked_databases}"
    while IFS= read -r _discarded; do :; done
    return 1
  }
  pg_admin() {
    printf '%s\n' "$*" >>"${admin_calls}"
    while IFS= read -r _discarded; do :; done
  }
  create_owned_databases \
    '{"portfolio":"hushine_indicator_chain_test_portfolio","order":"hushine_indicator_chain_test_order","control_panel":"hushine_indicator_chain_test_control","market":"hushine_indicator_chain_test_binance_2025"}' \
    'test-owner'
)
[[ "$(wc -l <"${checked_databases}" | tr -d ' ')" == "4" ]] \
  || fail "database preflight did not inspect all four owned databases"
[[ "$(wc -l <"${admin_calls}" | tr -d ' ')" == "8" ]] \
  || fail "database setup did not create and comment all four owned databases"

(
  export TIMESCALEDB_DSN='postgres://poison.invalid/poison'
  export SCRAPER_DBS='poison_2020'
  export DATABASE_DBNAME='poison_portfolio'
  export ORDER_DATABASE_DBNAME='poison_order'
  export MARKET_DATA_DB_DATABASE='poison_market'
  export SERVER_GRPC_ADDR='poison.invalid:1'
  source "${SCRIPT}"
  run_clean_env bash -c '
    test -z "${TIMESCALEDB_DSN+x}"
    test -z "${SCRAPER_DBS+x}"
    test -z "${DATABASE_DBNAME+x}"
    test -z "${ORDER_DATABASE_DBNAME+x}"
    test -z "${MARKET_DATA_DB_DATABASE+x}"
    test -z "${SERVER_GRPC_ADDR+x}"
  '
) || fail "clean service environment leaked an ambient routing override"

for function_name in apply_owned_migrations; do
  function_body="$(
    export HUSHINE_SOURCE_ROOT="${fake_source}"
    source "${SCRIPT}"
    declare -f "${function_name}"
  )"
  grep -Fq 'run_clean_env' <<<"${function_body}" \
    || fail "${function_name} does not launch commands through the clean environment"
done

exec_probe="${test_root}/exec-probe.sh"
printf '%s\n' \
  '#!/usr/bin/env bash' \
  'printf "%s\n" "$$" >"$1"' \
  'while :; do sleep 1; done' \
  >"${exec_probe}"
chmod 0700 "${exec_probe}"
exec_probe_pid="${test_root}/exec-probe.pid"
(
  source "${SCRIPT}"
  exec_clean_env "${exec_probe}" "${exec_probe_pid}"
) &
wrapper_pid="$!"
deadline=$((SECONDS + 5))
while [[ ! -s "${exec_probe_pid}" ]]; do
  (( SECONDS < deadline )) || fail "exec-clean probe did not start"
  sleep 0.05
done
[[ "$(<"${exec_probe_pid}")" == "${wrapper_pid}" ]] \
  || fail "clean service launcher left a wrapper process in the ownership journal"
probe_identity="$(ps -o lstart= -p "${wrapper_pid}" | sed \
  -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
(
  source "${SCRIPT}"
  terminate_owned_process "${wrapper_pid}" "${probe_identity}"
) || fail "exec-clean probe could not be terminated by recorded identity"

start_services_body="$(
  export HUSHINE_SOURCE_ROOT="${fake_source}"
  source "${SCRIPT}"
  declare -f start_services
)"
[[ "$(grep -Fc 'exec_clean_env' <<<"${start_services_body}")" == "4" ]] \
  || fail "all four services must replace their launcher with the owned process"
if grep -Fq 'npm run dev' <<<"${start_services_body}"; then
  fail "frontend ownership still records an npm wrapper instead of Vite"
fi

valid_owner="${test_root}/valid-owner.json"
jq -nc '{
  schema:1,
  owner_token:"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
  generation:"generation-bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
  databases:{
    portfolio:"hushine_indicator_chain_test_portfolio",
    order:"hushine_indicator_chain_test_order",
    control_panel:"hushine_indicator_chain_test_control",
    market_prefix:"hushine_indicator_chain_test_",
    market:"hushine_indicator_chain_test_binance_2025"
  }
}' >"${valid_owner}"
chmod 0600 "${valid_owner}"
(
  source "${SCRIPT}"
  validate_owner_file "${valid_owner}"
) || fail "valid owner journal was rejected"

tampered_owner="${test_root}/tampered-owner.json"
jq '.databases.order = "postgres"' "${valid_owner}" >"${tampered_owner}"
chmod 0600 "${tampered_owner}"
if (
  source "${SCRIPT}"
  validate_owner_file "${tampered_owner}"
); then
  fail "owner journal accepted an unsafe database set"
fi

release_state="${test_root}/release-state"
release_runtime_root="${release_state}/coverage/runtimes/rt-aaaaaaaaaaaaaaaaaaaaaaaa"
mkdir -m 0700 -p "${release_runtime_root}"
cp "${valid_owner}" "${release_state}/owner.json"
chmod 0600 "${release_state}/owner.json"
jq -nc \
  --arg owner 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' \
  --arg generation 'generation-bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb' \
  --arg runtime_id 'rt-aaaaaaaaaaaaaaaaaaaaaaaa' \
  --arg session_id 'cccccccccccccccccccccccccccccccc' \
  --arg runtime_root "${release_runtime_root}" \
  '{
    schema:1,
    owner_token:$owner,
    generation:$generation,
    runtime_id:$runtime_id,
    session_id:$session_id,
    runtime_root:$runtime_root
  }' >"${release_state}/chain.json"
chmod 0600 "${release_state}/chain.json"
jq -nc '{
  schema:1,
  owner_token:"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
  generation:"generation-bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
  runtime_id:"rt-aaaaaaaaaaaaaaaaaaaaaaaa",
  session_id:"cccccccccccccccccccccccccccccccc",
  target_completed:1023,
  ack_file:"/coverage/indicator-v2-ack.json"
}' >"${release_runtime_root}/indicator-v2-barrier.json"
chmod 0600 "${release_runtime_root}/indicator-v2-barrier.json"
(
  source "${SCRIPT}"
  release_acceptance_barrier "${release_state}"
) || fail "owned acceptance barrier could not be released for cleanup"
jq -e '
  .target_completed == 2051
  and .owner_token == "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
  and .runtime_id == "rt-aaaaaaaaaaaaaaaaaaaaaaaa"
  and .session_id == "cccccccccccccccccccccccccccccccc"
' "${release_runtime_root}/indicator-v2-barrier.json" >/dev/null \
  || fail "acceptance cleanup release changed identity or used the wrong target"

ack="${release_runtime_root}/indicator-v2-ack.json"
jq -nc \
  --argjson last_open_time_ms "$((1735689600000 + 1022 * 60000))" \
  '{
    schema:1,
    owner_token:"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
    generation:"generation-bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
    runtime_id:"rt-aaaaaaaaaaaaaaaaaaaaaaaa",
    session_id:"cccccccccccccccccccccccccccccccc",
    completed:1023,
    last_open_time_ms:$last_open_time_ms
  }' >"${ack}"
chmod 0600 "${ack}"
assertions="${release_state}/assertions.json"
jq -nc '{
  schema:1,
  owner_token:"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
  generation:"generation-bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
  runtime_id:"rt-aaaaaaaaaaaaaaaaaaaaaaaa",
  session_id:"cccccccccccccccccccccccccccccccc",
  states:{"open-1023":{completed:1023}}
}' >"${assertions}"
chmod 0600 "${assertions}"
(
  source "${SCRIPT}"
  validate_barrier_ack "${ack}" "${release_state}/chain.json" 1023
  validate_transition_assertion \
    "${assertions}" "${release_state}/chain.json" open-1023 1023
) || fail "valid barrier acknowledgement/assertion pair was rejected"

bad_ack="${release_runtime_root}/bad-ack.json"
jq '.last_open_time_ms += 1' "${ack}" >"${bad_ack}"
chmod 0600 "${bad_ack}"
if (
  source "${SCRIPT}"
  validate_barrier_ack "${bad_ack}" "${release_state}/chain.json" 1023
); then
  fail "barrier acknowledgement accepted the wrong K-line open_time"
fi

database_items='[{
  "session_id":"session-1",
  "stream_key":"stream-1",
  "indicator_key":"scalar",
  "chunk_index":0,
  "start_sequence":0,
  "end_sequence":0,
  "start_time_ms":1735689600000,
  "end_time_ms":1735689600000,
  "interval_ms":60000,
  "count":1,
  "times_ms":[1735689600000],
  "scalar_values":[1],
  "markers":[],
  "revision":1,
  "finalized":false,
  "protocol_version":2
}]'
api_items='{"items":[{
  "protocol_version":2,
  "finalized":false,
  "revision":1,
  "markers":[],
  "scalar_values":[1],
  "times_ms":[1735689600000],
  "count":1,
  "interval_ms":60000,
  "end_time_ms":1735689600000,
  "start_time_ms":1735689600000,
  "end_sequence":0,
  "start_sequence":0,
  "chunk_index":0,
  "indicator_key":"scalar",
  "stream_key":"stream-1",
  "session_id":"session-1"
}]}'
(
  source "${SCRIPT}"
  assert_api_matches_database "${database_items}" "${api_items}"
) || fail "equivalent API and database indicator chunks did not compare equal"
if (
  source "${SCRIPT}"
  assert_api_matches_database \
    "${database_items}" "$(jq '.items[0].revision = 2' <<<"${api_items}")"
); then
  fail "API/database indicator comparison accepted a revision mismatch"
fi

await_state_dir="${test_root}/await-current-v2"
await_runtime_root="${test_root}/await-runtime"
mkdir -p "${await_state_dir}" "${await_runtime_root}"
jq -nc \
  --arg runtime_root "${await_runtime_root}" \
  '{
    schema:1,
    owner_token:"owner",
    generation:"generation",
    runtime_id:"runtime",
    session_id:"session-1",
    runtime_root:$runtime_root,
    databases:{portfolio:"hushine_indicator_chain_portfolio",order:"hushine_indicator_chain_order"},
    urls:{handler:"http://127.0.0.1:1"}
  }' >"${await_state_dir}/chain.json"
jq -nc '{owner_token:"owner"}' >"${await_state_dir}/owner.json"
jq -nc '{token:"token"}' >"${await_state_dir}/auth.json"
jq -nc '{completed:1025}' >"${await_runtime_root}/indicator-v2-ack.json"
chmod 0600 \
  "${await_state_dir}/chain.json" \
  "${await_state_dir}/owner.json" \
  "${await_state_dir}/auth.json" \
  "${await_runtime_root}/indicator-v2-ack.json"
api_items_with_unrelated_field="$(jq '.items[0].values_json = "ignored-extra-field"' <<<"${api_items}")"
(
  source "${SCRIPT}"
  validate_barrier_ack() { return 0; }
  indicator_snapshot() { printf '%s\n' "${database_items}"; }
  assert_snapshot_state() { return 0; }
  assert_cutover_markers() { return 0; }
  api_indicator_snapshot() { printf '%s\n' "${api_items_with_unrelated_field}"; }
  await_state finalized-1024-plus-tail "${await_state_dir}"
) >/dev/null \
  || fail "current V2 response validation still branches on a removed schema field"

valid_orders="$(jq -nc \
  --argjson start 1735689600000 \
  '[
    {
      time_ms:($start + 4 * 60000 + 59999),
      symbol:"TESTUSDT",side:1,intent_status:1,reject_code:"",
      order_status:3,orig_qty:"0.001000000000000000",
      executed_qty:"0.001000000000000000",
      avg_price:"104.000000000000000000",
      cumulative_quote_qty:"0.104000000000000000",
      error_code:"",error_message:"",recovery_status:"",
      fill_status:1,qty:"0.001000000000000000",
      fill_price:"104.000000000000000000",
      quote_qty:"0.104000000000000000",
      quote_qty_unresolved:false,fee:"0.000041600000000000",fee_asset:"USDT"
    },
    {
      time_ms:($start + 9 * 60000 + 59999),
      symbol:"TESTUSDT",side:2,intent_status:1,reject_code:"",
      order_status:3,orig_qty:"0.001000000000000000",
      executed_qty:"0.001000000000000000",
      avg_price:"109.000000000000000000",
      cumulative_quote_qty:"0.109000000000000000",
      error_code:"",error_message:"",recovery_status:"",
      fill_status:1,qty:"0.001000000000000000",
      fill_price:"109.000000000000000000",
      quote_qty:"0.109000000000000000",
      quote_qty_unresolved:false,fee:"0.000043600000000000",fee_asset:"USDT"
    },
    {
      time_ms:($start + 1438 * 60000 + 59999),
      symbol:"TESTUSDT",side:1,intent_status:1,reject_code:"",
      order_status:3,orig_qty:"0.001000000000000000",
      executed_qty:"0.001000000000000000",
      avg_price:"138.000000000000000000",
      cumulative_quote_qty:"0.138000000000000000",
      error_code:"",error_message:"",recovery_status:"",
      fill_status:1,qty:"0.001000000000000000",
      fill_price:"138.000000000000000000",
      quote_qty:"0.138000000000000000",
      quote_qty_unresolved:false,fee:"0.000055200000000000",fee_asset:"USDT"
    }
  ]')"
(
  source "${SCRIPT}"
  assert_cutover_orders "${valid_orders}"
) || fail "valid exact Futures ledger facts were rejected"
if (
  source "${SCRIPT}"
  assert_cutover_orders "$(jq '.[0].fee = "0.000041600000000001"' <<<"${valid_orders}")"
); then
  fail "cutover order assertion accepted an inexact fee"
fi

signal_log="${test_root}/signal-log"
(
  source "${SCRIPT}"
  alive=true
  process_matches() {
    [[ "${alive}" == "true" && "$1" == "42" && "$2" == "owned-start" ]]
  }
  send_process_signal() {
    printf '%s %s\n' "$1" "$2" >>"${signal_log}"
    [[ "$1" != "KILL" ]] || alive=false
  }
  sleep() { :; }
  terminate_owned_process 42 owned-start
) || fail "owned process termination did not complete"
[[ "$(<"${signal_log}")" == $'TERM 42\nKILL 42' ]] \
  || fail "owned process termination did not use the guarded TERM/KILL sequence"

identity_change_log="${test_root}/identity-change-log"
(
  source "${SCRIPT}"
  identity_matches=true
  process_matches() {
    [[ "${identity_matches}" == "true" && "$1" == "43" && "$2" == "old-start" ]]
  }
  send_process_signal() {
    printf '%s %s\n' "$1" "$2" >>"${identity_change_log}"
    identity_matches=false
  }
  sleep() { :; }
  terminate_owned_process 43 old-start
) || fail "identity change should be treated as the owned process having exited"
[[ "$(<"${identity_change_log}")" == 'TERM 43' ]] \
  || fail "a reused PID received a signal after its identity changed"

cleanup_body="$(
  export HUSHINE_SOURCE_ROOT="${fake_source}"
  source "${SCRIPT}"
  declare -f cleanup_supervisor
)"
grep -Fq 'validate_owner_file' <<<"${cleanup_body}" \
  || fail "cleanup does not validate the owner journal before deleting resources"
grep -Fq 'terminate_owned_process' <<<"${cleanup_body}" \
  || fail "cleanup does not use identity-guarded process termination"
grep -Fq 'remove_owned_runtime_container' <<<"${cleanup_body}" \
  || fail "cleanup does not use the full runtime-container ownership check"

provision_body="$(
  export HUSHINE_SOURCE_ROOT="${fake_source}"
  source "${SCRIPT}"
  declare -f provision_acceptance_run
)"
if grep -Fq 'leverage:20' <<<"${provision_body}"; then
  fail "venue bootstrap still sends the removed per-position leverage field"
fi
for literal in \
  'journal_runtime_container' \
  'RUNTIME_COVERAGE_CONTAINER_ID' \
  'RUNTIME_COVERAGE_CONTAINER_IMAGE_ID' \
  'RUNTIME_COVERAGE_RUN_LABEL' \
  'coverage_mount_source' \
  'resource_name' \
  'validate_owner_file'; do
  grep -Fq "${literal}" <<<"${provision_body}" \
    || fail "runtime owner journal is missing identity field: ${literal}"
done
journal_line="$(grep -nF 'journal_runtime_container' <<<"${provision_body}" | head -1 | cut -d: -f1)"
validation_line="$(grep -nF 'runtime_coverage_validate_container' <<<"${provision_body}" | head -1 | cut -d: -f1)"
[[ -n "${journal_line}" && -n "${validation_line}" && "${journal_line}" -lt "${validation_line}" ]] \
  || fail "provisioned Runtime is not ownership-journaled before fallible validation"

supervise_body="$(
  export HUSHINE_SOURCE_ROOT="${fake_source}"
  source "${SCRIPT}"
  declare -f supervise
)"
if grep -Fq 'provisioned="$(provision_acceptance_run' <<<"${supervise_body}"; then
  fail "provisioning still runs inside an errexit-suppressing command substitution"
fi
grep -Fq 'provision_acceptance_run "${ports}" "${owner}" "${generation}" "${image_id}"' <<<"${supervise_body}" \
  || fail "supervisor does not invoke provisioning as a fail-fast simple command"

start_body="$(
  export HUSHINE_SOURCE_ROOT="${fake_source}"
  source "${SCRIPT}"
  declare -f start_chain
)"
grep -Fq 'cleanup_failed_start' <<<"${start_body}" \
  || fail "start does not install cleanup for an await/startup failure"
grep -Fq 'trap - EXIT INT TERM' <<<"${start_body}" \
  || fail "start does not disarm failure cleanup after successful acceptance"

if grep -Eq 'kill -(TERM|KILL)' "${SCRIPT}"; then
  fail "service-chain bypasses identity-guarded process signaling"
fi

if grep -Fq -- '-addext' "${SCRIPT}"; then
  fail "certificate generation relies on non-portable openssl -addext"
fi
grep -Fq 'subjectAltName=DNS:runtime-channel.local' "${SCRIPT}" \
  || fail "portable RuntimeChannel certificate config is missing the SAN contract"

if grep -Eq '(^|[^A-Z_])SKIP([^A-Z_]|$)' "${SCRIPT}"; then
  fail "service-chain contains a skip path"
fi

echo "runtime Indicator V2 service-chain contract: PASS"
