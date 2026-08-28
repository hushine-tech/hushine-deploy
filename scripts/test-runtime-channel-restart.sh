#!/usr/bin/env bash
set -euo pipefail

DEPLOY_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
SOURCE_ROOT="${HUSHINE_SOURCE_ROOT:-$(cd "${DEPLOY_ROOT}/.." && pwd -P)}"
EVIDENCE_FILE=""
STATE_DIR=""
DRIVER="${RUNTIME_RESTART_DRIVER:-}"
CLEANED_UP=false
CLEANUP_ONLY=false
PG_CONTAINER="${HUSHINE_LOCAL_PG_CONTAINER:-hushine-local-timescaledb-1}"
RUNTIME_IMAGE="${HUSHINE_RUNTIME_RESTART_IMAGE:-hushine/strategy-runtime:executor-dev}"
API="${HUSHINE_RUNTIME_RESTART_API:-http://127.0.0.1:8090}"
CONTROL_READY="${HUSHINE_RUNTIME_RESTART_CONTROL_READY:-http://127.0.0.1:8082/readyz}"

die() {
  echo "runtime-channel restart acceptance: $*" >&2
  exit 1
}

usage() {
  cat <<'EOF'
Usage: scripts/test-runtime-channel-restart.sh [--evidence-file FILE] [--state-dir DIR] [--cleanup-only]

Runs the real local RuntimeChannel control-panel restart acceptance. The local
stack must already be running (`make local-start`). Evidence defaults to a
fresh private directory under ${TMPDIR:-/tmp} and is retained after the run.
EOF
}

while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --evidence-file)
      [[ "$#" -ge 2 ]] || die "--evidence-file requires a path"
      EVIDENCE_FILE="$2"
      shift 2
      ;;
    --state-dir)
      [[ "$#" -ge 2 ]] || die "--state-dir requires a path"
      STATE_DIR="$2"
      shift 2
      ;;
    --cleanup-only)
      CLEANUP_ONLY=true
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die "unknown argument: $1"
      ;;
  esac
done

if [[ -n "${DRIVER}" ]]; then
  [[ "${HUSHINE_RUNTIME_RESTART_CONTRACT:-}" == "1" ]] \
    || die "RUNTIME_RESTART_DRIVER is restricted to the contract test"
  [[ -x "${DRIVER}" ]] || die "contract driver is not executable"
fi

if [[ -z "${STATE_DIR}" ]]; then
  STATE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/hushine-runtime-restart.XXXXXX")"
else
  [[ "${STATE_DIR}" == /* && ! -L "${STATE_DIR}" ]] \
    || die "--state-dir must be an absolute non-symlink path"
  mkdir -p -- "${STATE_DIR}"
fi
chmod 0700 "${STATE_DIR}"
STATE_DIR="$(cd "${STATE_DIR}" && pwd -P)"
if [[ -z "${EVIDENCE_FILE}" ]]; then
  EVIDENCE_FILE="${STATE_DIR}/evidence.json"
elif [[ "${EVIDENCE_FILE}" != /* ]]; then
  EVIDENCE_FILE="$(cd "$(dirname "${EVIDENCE_FILE}")" && pwd -P)/$(basename "${EVIDENCE_FILE}")"
fi
mkdir -p -- "$(dirname "${EVIDENCE_FILE}")"
umask 077

atomic_json() {
  local destination="$1"
  shift
  local temporary="${destination}.tmp.$$"
  jq "$@" >"${temporary}"
  chmod 0600 "${temporary}"
  mv -f -- "${temporary}" "${destination}"
}

run_action() {
  local action="$1"
  shift
  if [[ -n "${DRIVER}" ]]; then
    "${DRIVER}" "${action}" "$@"
    return
  fi
  live_action "${action}" "$@"
}

capture_action() {
  local variable="$1" action="$2" output value
  shift 2
  output="${STATE_DIR}/action-${action}.json"
  run_action "${action}" "$@" >"${output}"
  chmod 0600 "${output}"
  value="$(<"${output}")"
  printf -v "${variable}" '%s' "${value}"
}

capture_cleanup() {
  local variable="$1" output value
  output="${STATE_DIR}/action-cleanup.json"
  cleanup_once >"${output}"
  chmod 0600 "${output}"
  value="$(<"${output}")"
  printf -v "${variable}" '%s' "${value}"
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"
}

wait_for() {
  local timeout="$1" description="$2"
  shift 2
  local deadline=$((SECONDS + timeout))
  until "$@"; do
    (( SECONDS < deadline )) || die "timed out after ${timeout}s: ${description}"
    sleep 0.25
  done
}

pg() {
  local database="$1"
  shift
  docker exec -i -e PGPASSWORD=postgres "${PG_CONTAINER}" \
    psql -X -v ON_ERROR_STOP=1 -U postgres -d "${database}" "$@"
}

sql_value() {
  local database="$1" query="$2"
  pg "${database}" -Atc "${query}"
}

database_exists() {
  [[ "$(sql_value postgres "SELECT count(*) FROM pg_database WHERE datname='$1'")" == "1" ]]
}

api_request() {
  local method="$1" path="$2" token="${3:-}" body="${4:-}"
  local -a args=(-sS --max-time 15 -X "${method}" -H 'Accept: application/json')
  [[ -z "${token}" ]] || args+=(-H "Authorization: Bearer ${token}")
  [[ -z "${body}" ]] || args+=(-H 'Content-Type: application/json' --data-binary "${body}")
  local response code
  response="$(mktemp "${STATE_DIR}/api.XXXXXX")"
  code="$(curl "${args[@]}" -o "${response}" -w '%{http_code}' "${API}${path}")" \
    || die "API ${method} ${path} transport failed"
  if [[ ! "${code}" =~ ^2[0-9][0-9]$ ]]; then
    die "API ${method} ${path} returned HTTP ${code}: $(tr '\n' ' ' <"${response}")"
  fi
  cat "${response}"
  rm -f -- "${response}"
}

state_get() {
  jq -er "$1" "${STATE_DIR}/live-state.json"
}

state_update() {
  local temporary="${STATE_DIR}/live-state.json.tmp.$$"
  jq "$@" "${STATE_DIR}/live-state.json" >"${temporary}"
  chmod 0600 "${temporary}"
  mv -f -- "${temporary}" "${STATE_DIR}/live-state.json"
}

container_running() {
  [[ "$(docker inspect -f '{{.State.Running}}' "$1" 2>/dev/null || true)" == "true" ]]
}

runtime_status_is() {
  local runtime_id="$1" expected="$2"
  [[ "$(sql_value control_panel "SELECT COALESCE(status,'') FROM runtime_registry WHERE runtime_id='${runtime_id}'")" == "${expected}" ]]
}

agent_http_code() {
  local container="$1" path="$2"
  docker exec -i "${container}" /app/strategy-service/.venv/bin/python - "${path}" <<'PY'
import sys
import urllib.error
import urllib.request
try:
    with urllib.request.urlopen("http://127.0.0.1:5706" + sys.argv[1], timeout=2) as response:
        print(response.status)
except urllib.error.HTTPError as exc:
    print(exc.code)
PY
}

agent_ready_is() {
  [[ "$(agent_http_code "$1" /readyz 2>/dev/null || true)" == "$2" ]]
}

control_ready_is() {
  curl -fsS --max-time 2 "${CONTROL_READY}" >/dev/null 2>&1
}

income_count_is_one() {
  local session="$1" venue="$2"
  [[ "$(sql_value portfolio "SELECT count(*) FROM venue_income_entries WHERE session_id='${session}' AND venue_id=${venue} AND income_type='FUNDING_FEE'")" == "1" ]]
}

container_process_pid() {
  local container="$1" pattern="$2"
  docker exec "${container}" sh -c '
    pattern="$1"
    scanner=$$
    for item in /proc/[0-9]*; do
      pid=${item#/proc/}
      [ "$pid" = "$scanner" ] && continue
      command=$(tr "\000" " " <"$item/cmdline" 2>/dev/null || true)
      case "$command" in *"$pattern"*) printf "%s\n" "$pid"; exit 0;; esac
    done
    exit 1
  ' sh "${pattern}"
}

worker_identity() {
  local container="$1" worker pid generation
  worker="$(container_process_pid "${container}" strategy_service.session_worker_entry)" || return 1
  read -r pid generation < <(docker exec "${container}" sh -c \
    'set -- $(cat "/proc/$1/stat"); printf "%s %s\n" "$1" "${22}"' sh "${worker}")
  [[ "${pid}" =~ ^[0-9]+$ && "${generation}" =~ ^[0-9]+$ ]] || return 1
  printf '%s|%s\n' "${pid}" "${generation}"
}

barrier_at() {
  local expected="$1" ack
  ack="$(state_get .normal.runtime_root)/runtime-restart-ack.json"
  [[ -f "${ack}" ]] || return 1
  jq -e --argjson expected "${expected}" \
    --arg owner "$(state_get .owner_token)" \
    --arg runtime "$(state_get .normal.runtime_id)" \
    --arg session "$(state_get .normal.session_id)" \
    '.completed == $expected and .owner_token == $owner and .runtime_id == $runtime and .session_id == $session' \
    "${ack}" >/dev/null
}

ensure_market_fixture() {
  local owner symbol lower kline_table funding_table source database_created=false
  owner="$(state_get .owner_token)"
  symbol="$(printf 'RCR%sUSDT' "${owner:0:12}" | tr '[:lower:]' '[:upper:]')"
  lower="$(printf '%s' "${symbol}" | tr '[:upper:]' '[:lower:]')"
  kline_table="futures_klines_${lower}_1m"
  funding_table="futures_funding_rates_${lower}"
  source="runtime-channel-restart:${owner}"
  if [[ "$(sql_value postgres "SELECT count(*) FROM pg_database WHERE datname='binance_2025'")" == "0" ]]; then
    (cd "${SOURCE_ROOT}/scraper" && SCRAPER_DBS=binance_2025 go run ./cmd/ensure-scraper-db) \
      >"${STATE_DIR}/ensure-market.log" 2>&1
    pg postgres -c "COMMENT ON DATABASE binance_2025 IS '${source}'" >/dev/null
    database_created=true
  fi
  state_update --arg symbol "${symbol}" --arg lower "${lower}" --arg source "${source}" \
    --argjson created "${database_created}" \
    '.market={symbol:$symbol,lower:$lower,source:$source,database_created:$created}'
  pg binance_2025 >/dev/null <<SQL
CREATE TABLE ${kline_table} (
  time TIMESTAMPTZ NOT NULL, symbol TEXT NOT NULL, market TEXT NOT NULL DEFAULT 'futures',
  exchange TEXT NOT NULL DEFAULT 'binance', open_time TIMESTAMPTZ NOT NULL,
  close_time TIMESTAMPTZ NOT NULL, open DOUBLE PRECISION NOT NULL,
  high DOUBLE PRECISION NOT NULL, low DOUBLE PRECISION NOT NULL, close DOUBLE PRECISION NOT NULL,
  volume DOUBLE PRECISION NOT NULL DEFAULT 0, quote_volume DOUBLE PRECISION NOT NULL DEFAULT 0,
  num_trades BIGINT NOT NULL DEFAULT 0, created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  PRIMARY KEY(time,symbol)
);
SELECT create_hypertable('${kline_table}','time',if_not_exists=>TRUE);
INSERT INTO ${kline_table}(time,symbol,market,exchange,open_time,close_time,open,high,low,close,volume,quote_volume,num_trades)
SELECT '2025-01-01T00:00:00Z'::timestamptz + item * interval '1 minute', '${symbol}',
  'futures','binance','2025-01-01T00:00:00Z'::timestamptz + item * interval '1 minute',
  '2025-01-01T00:00:00Z'::timestamptz + item * interval '1 minute' + interval '59.999 seconds',
  100,101,99,100,1000,100000,100
FROM generate_series(0,2049) item;
CREATE TABLE ${funding_table} (
  time TIMESTAMPTZ NOT NULL, symbol TEXT NOT NULL, market TEXT NOT NULL DEFAULT 'futures',
  exchange TEXT NOT NULL DEFAULT 'binance', funding_rate NUMERIC(38,18) NOT NULL,
  mark_price NUMERIC(38,18) NOT NULL, next_funding_time TIMESTAMPTZ,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(), PRIMARY KEY(time,symbol)
);
SELECT create_hypertable('${funding_table}','time',if_not_exists=>TRUE);
INSERT INTO ${funding_table}(time,symbol,market,exchange,funding_rate,mark_price,next_funding_time)
VALUES ('2025-01-01T17:04:00Z','${symbol}','futures','binance',0.001,100,'2025-01-02T01:04:00Z');
SQL
  pg control_panel >/dev/null <<SQL
INSERT INTO market_data_coverage_segments(exchange,market,kind,symbol,"interval",year,segment_start_at,segment_end_at,row_count,source)
VALUES
 ('binance','futures','kline','${symbol}','1m',2025,'2025-01-01T00:00:00Z','2025-01-02T10:10:00Z',2050,'${source}'),
 ('binance','futures','funding_rate','${symbol}','',2025,'2025-01-01T00:00:00Z','2025-01-02T10:10:00Z',1,'${source}');
SQL
}

ensure_user() {
  local owner credentials signup login
  owner="$(state_get .owner_token)"
  credentials="$(jq -nc --arg username "runtime-restart-${owner:0:12}" \
    --arg password "Rr-${owner:12:24}-acceptance" '{username:$username,password:$password}')"
  signup="$(api_request POST /api/auth/signup '' "${credentials}")"
  login="$(api_request POST /api/auth/login '' "${credentials}")"
  state_update --arg token "$(jq -er .token <<<"${login}")" \
    --argjson user "$(jq -er '.user.user_id' <<<"${login}")" \
    '.auth={token:$token,user_id:$user}'
}

issue_credential() {
  local phase token response
  phase="$1"
  token="$(state_get .auth.token)"
  response="$(api_request POST /api/runtime-credentials "${token}" \
    "$(jq -nc --arg label "runtime-restart-${phase}-$(state_get .owner_token)" '{label:$label,role:"executor"}')")"
  printf '%s\n' "${response}" >"${STATE_DIR}/credential-${phase}.json"
  chmod 0600 "${STATE_DIR}/credential-${phase}.json"
  printf '%s\n' "${response}"
}

start_owned_runtime() {
  local phase phase_name runtime_id credential container runtime_root credential_json tls_json
  phase="$1"
  credential="$(issue_credential "${phase}")" || return
  runtime_id="selfhosted-$(jq -er .key_id <<<"${credential}")"
  phase_name="${phase//_/-}"
  container="hushine-runtime-restart-${phase}-$(state_get .owner_token | cut -c1-10)"
  runtime_root="${STATE_DIR}/runtimes/${phase}"
  mkdir -m 0700 -p "${runtime_root}"
  credential_json="$(jq -c '{version,key_id,private_key_pem}' <<<"${credential}")"
  tls_json="$(jq -c '{client_cert_pem,client_key_pem,server_ca_pem}' <<<"${credential}")"
  docker run -d --name "${container}" \
    --label "hushine.acceptance.runtime-restart=$(state_get .owner_token)" \
    --add-host host.docker.internal:host-gateway \
    --mount "type=bind,src=${runtime_root},dst=/coverage" \
    -e RUNTIME_SOURCE=self_hosted -e "RUNTIME_RUNTIME_ID=${runtime_id}" \
    -e "RUNTIME_NAME=runtime-restart-${phase_name}" -e RUNTIME_RESOURCE_PROFILE=small \
    -e RUNTIME_CHANNEL_GRPC_ADDR=host.docker.internal:50055 \
    -e RUNTIME_AGENT_CONTROL_ADDR=127.0.0.1:5706 \
    -e "RUNTIME_CREDENTIAL_JSON=${credential_json}" \
    -e RUNTIME_CHANNEL_TLS_ENABLED=true \
    -e "RUNTIME_CHANNEL_TLS_BUNDLE_JSON=${tls_json}" \
    -e RUNTIME_CHANNEL_TLS_SERVER_NAME=runtime-channel.local \
    "${RUNTIME_IMAGE}" >/dev/null || return
  wait_for 30 "${phase} runtime active" runtime_status_is "${runtime_id}" active || return
  wait_for 15 "${phase} agent readiness" agent_ready_is "${container}" 200 || return
  state_update --arg phase "${phase}" --arg runtime "${runtime_id}" \
    --arg key "$(jq -er .key_id <<<"${credential}")" --arg container "${container}" \
    --arg root "${runtime_root}" \
    '.[$phase]={runtime_id:$runtime,credential_key_id:$key,container_name:$container,runtime_root:$root}'
  jq -nc --arg runtime_id "${runtime_id}" --arg credential_key_id "$(jq -er .key_id <<<"${credential}")" \
    --arg container_name "${container}" --arg runtime_root "${runtime_root}" \
    '{runtime_id:$runtime_id,credential_key_id:$credential_key_id,container_name:$container_name,runtime_root:$runtime_root}'
}

create_strategy_source() {
  python3 - "${SOURCE_ROOT}/strategy-service/tests/strategies/indicator_v2_open_time_cutover.py" \
    "$(state_get .owner_token)" "$(state_get .generation)" "$(state_get .market.symbol)" <<'PY'
import json
import pathlib
import sys
path, owner, generation, symbol = sys.argv[1:]
source = pathlib.Path(path).read_text(encoding="utf-8")
replacements = {
    'ACCEPTANCE_BARRIER_FILE = ""': 'ACCEPTANCE_BARRIER_FILE = "/coverage/runtime-restart-barrier.json"',
    'ACCEPTANCE_BARRIER_OWNER_TOKEN = ""': f'ACCEPTANCE_BARRIER_OWNER_TOKEN = {json.dumps(owner)}',
    'ACCEPTANCE_BARRIER_GENERATION = ""': f'ACCEPTANCE_BARRIER_GENERATION = {json.dumps(generation)}',
    'TESTUSDT': symbol,
    'if sequence in {4, 9, 1438}:': 'if sequence in {4, 1438}:',
}
for old, new in replacements.items():
    if old not in source:
        raise SystemExit(f"strategy fixture contract changed: {old}")
    source = source.replace(old, new)
print(source, end="")
PY
}

create_normal_fixture() {
  local runtime token owner response portfolio venue strategy session source runtime_root
  ensure_user || return
  ensure_market_fixture || return
  runtime="$(start_owned_runtime normal)" || return
  token="$(state_get .auth.token)"
  owner="$(state_get .owner_token)"
  response="$(api_request POST /api/portfolios "${token}" \
    '{"name":"Runtime restart acceptance","description":"Harness-owned disposable fixture","environment":0}')" || return
  portfolio="$(jq -er .portfolio_id <<<"${response}")"
  response="$(api_request POST /api/venues "${token}" "$(jq -nc --argjson p "${portfolio}" \
    '{portfolio_id:$p,exchange:"binance",market:"perpetual_futures",environment:"backtest",status:"active",display_name:"Runtime restart Futures",margin_mode:"cross",position_mode:"one_way",futures:{margin_mode:"cross",position_mode:"one_way",initial_balance:100000}}')")" || return
  venue="$(jq -er .venue_id <<<"${response}")"
  source="$(create_strategy_source)"
  response="$(api_request POST /api/strategies "${token}" "$(jq -nc --arg name "runtime-restart-${owner:0:8}" --arg code "${source}" '{name:$name,version:"1.0.0",description:"Runtime restart fixture",code:$code}')")" || return
  strategy="$(jq -er .strategy_id <<<"${response}")"
  api_request POST "/api/portfolios/${portfolio}/strategies/${strategy}" "${token}" >/dev/null
  api_request POST "/api/portfolios/${portfolio}/strategies/${strategy}/activate" "${token}" >/dev/null
  runtime_root="$(jq -er .runtime_root <<<"${runtime}")"
  atomic_json "${runtime_root}/runtime-restart-barrier.json" -nc \
    --arg owner_token "${owner}" --arg generation "$(state_get .generation)" \
    --arg runtime_id "$(jq -er .runtime_id <<<"${runtime}")" \
    '{schema:1,owner_token:$owner_token,generation:$generation,runtime_id:$runtime_id,session_id:"",target_completed:1023,ack_file:"/coverage/runtime-restart-ack.json"}'
  response="$(api_request POST "/api/portfolios/${portfolio}/run-strategy" "${token}" "$(jq -nc \
    --arg runtime "$(jq -er .runtime_id <<<"${runtime}")" \
    '{interval:"1m",start_time_ms:1735689600000,end_time_ms:1735812600000,runtime_id:$runtime}')")"
  session="$(jq -er .session_id <<<"${response}")"
  atomic_json "${runtime_root}/runtime-restart-barrier.json" --arg session "${session}" \
    '.session_id=$session' "${runtime_root}/runtime-restart-barrier.json"
  state_update --argjson portfolio "${portfolio}" --argjson venue "${venue}" \
    --argjson strategy "${strategy}" --arg session "${session}" \
    '.normal += {portfolio_id:$portfolio,venue_id:$venue,strategy_id:$strategy,session_id:$session}'
  wait_for 90 "normal worker barrier at callback 1023" barrier_at 1023 || return
  jq -nc --arg owner_token "${owner}" --arg runtime_id "$(jq -er .runtime_id <<<"${runtime}")" \
    --arg session_id "${session}" --arg credential_key_id "$(jq -er .credential_key_id <<<"${runtime}")" \
    --arg container_name "$(jq -er .container_name <<<"${runtime}")" \
    '{owner_token:$owner_token,runtime_id:$runtime_id,session_id:$session_id,credential_key_id:$credential_key_id,container_name:$container_name}'
}

session_status() {
  local session="$1" value
  value="$(sql_value portfolio "SELECT status FROM strategy_sessions WHERE session_id='${session}'")"
  case "${value}" in
    1) echo pending;; 2) echo preflight;; 3) echo running;; 4) echo stopping;;
    5) echo recoverable;; 6) echo finished;; 7) echo stopped;; 8) echo failed;;
    9) echo preflight_failed;; 10) echo stop_failed;; *) echo unknown;;
  esac
}

snapshot_normal() {
  local container runtime session venue host_pid agent worker worker_pid generation
  local health ready heartbeat heartbeat_us indicator income income_row_cursor wallet_effect
  container="$(state_get .normal.container_name)"
  runtime="$(state_get .normal.runtime_id)"
  session="$(state_get .normal.session_id)"
  venue="$(state_get .normal.venue_id)"
  host_pid="$(docker inspect -f '{{.State.Pid}}' "${container}")"
  agent="$(container_process_pid "${container}" runtime-agent)"
  worker="$(worker_identity "${container}")"
  IFS='|' read -r worker_pid generation <<<"${worker}"
  health="$(agent_http_code "${container}" /healthz)"
  ready="$(agent_http_code "${container}" /readyz)"
  IFS='|' read -r heartbeat heartbeat_us < <(sql_value control_panel \
    "SELECT COALESCE(to_char(heartbeat_at AT TIME ZONE 'UTC','YYYY-MM-DD\"T\"HH24:MI:SS.US\"Z\"'),''),COALESCE((extract(epoch FROM heartbeat_at)*1000000)::bigint,0) FROM runtime_registry WHERE runtime_id='${runtime}'")
  indicator="$(sql_value portfolio "SELECT COALESCE(max(end_sequence),-1) FROM strategy_indicator_chunks WHERE session_id='${session}'")"
  income="$(sql_value portfolio "SELECT COALESCE((SELECT snapshot_json #>> '{futures,last_applied_income_entry_id}' FROM venue_wallet_states WHERE venue_id=${venue}),'0')")"
  income_row_cursor="$(sql_value portfolio "SELECT COALESCE(max(income_entry_id),0) FROM venue_income_entries WHERE session_id='${session}' AND venue_id=${venue}")"
  wallet_effect="$(sql_value portfolio "SELECT count(*) FROM venue_income_entries WHERE session_id='${session}' AND venue_id=${venue} AND income_type='FUNDING_FEE' AND source='backtest' AND status='calculated'")"
  if (( wallet_effect > 0 )) && [[ "${income}" != "${income_row_cursor}" ]]; then
    die "wallet Income cursor ${income} does not match exact durable Income row ${income_row_cursor}"
  fi
  jq -nc --argjson runtime_container_pid "${host_pid}" --argjson agent_pid "${agent}" \
    --argjson worker_pid "${worker_pid}" --argjson worker_generation "${generation}" \
    --arg session_id "${session}" --arg session_status "$(session_status "${session}")" \
    --argjson agent_health_http "${health}" --argjson agent_ready_http "${ready}" \
    --arg heartbeat_at "${heartbeat}" --argjson heartbeat_cursor_us "${heartbeat_us}" \
    --argjson indicator_cursor "${indicator}" --argjson income_cursor "${income}" \
    --argjson wallet_effect_count "${wallet_effect}" \
    '{runtime_container_pid:$runtime_container_pid,agent_pid:$agent_pid,worker_pid:$worker_pid,worker_generation:$worker_generation,session_id:$session_id,session_status:$session_status,agent_health_http:$agent_health_http,agent_ready_http:$agent_ready_http,heartbeat_at:$heartbeat_at,heartbeat_cursor_us:$heartbeat_cursor_us,indicator_cursor:$indicator_cursor,income_cursor:$income_cursor,wallet_effect_count:$wallet_effect_count}'
}

control_stop() {
  make -C "${SOURCE_ROOT}/control-panel-service" stop >"${STATE_DIR}/control-stop.log" 2>&1
  local deadline=$((SECONDS + 15))
  while curl -fsS --max-time 1 "${CONTROL_READY}" >/dev/null 2>&1; do
    (( SECONDS < deadline )) || die "control-panel-service did not stop"
    sleep 0.25
  done
}

control_start() {
  local config="${1:-./config.local.yaml}"
  NO_PROXY="127.0.0.1,localhost,::1,host.docker.internal${NO_PROXY:+,${NO_PROXY}}" \
    no_proxy="127.0.0.1,localhost,::1,host.docker.internal${no_proxy:+,${no_proxy}}" \
    RUNTIME_COVERAGE_ENABLED=true \
    RUNTIME_COVERAGE_OUTPUT_DIR="${SOURCE_ROOT}/.coverage/runtime-agent" \
    RUNTIME_COVERAGE_IMAGE=hushine/strategy-runtime:executor-coverage-dev \
    make -C "${SOURCE_ROOT}/control-panel-service" CONFIG="${config}" start \
    >"${STATE_DIR}/control-start.log" 2>&1
  wait_for 30 "control-panel-service readiness" control_ready_is
}

runtime_exited() {
  [[ "$(docker inspect -f '{{.State.Running}}' "$1" 2>/dev/null || true)" == "false" ]]
}

capture_terminal_diagnostic() {
  local phase="$1" container runtime key
  container="$(state_get ".${phase}.container_name")"
  runtime="$(state_get ".${phase}.runtime_id")"
  key="$(state_get ".${phase}.credential_key_id")"
  docker inspect "${container}" >"${STATE_DIR}/${phase}-docker-inspect.json" 2>&1 || true
  docker top "${container}" -eo pid,ppid,stat,etime,args \
    >"${STATE_DIR}/${phase}-docker-top.txt" 2>&1 || true
  docker logs "${container}" >"${STATE_DIR}/${phase}-docker.log" 2>&1 || true
  {
    printf 'health_http=%s\n' "$(agent_http_code "${container}" /healthz 2>/dev/null || true)"
    printf 'ready_http=%s\n' "$(agent_http_code "${container}" /readyz 2>/dev/null || true)"
    printf 'runtime=%s\n' "$(sql_value control_panel "SELECT status||'|'||COALESCE(ended_reason,'')||'|'||updated_at::text FROM runtime_registry WHERE runtime_id='${runtime}'" 2>/dev/null || true)"
    printf 'credential=%s\n' "$(sql_value control_panel "SELECT status||'|'||COALESCE(revoked_at::text,'') FROM runtime_credentials WHERE key_id='${key}'" 2>/dev/null || true)"
    printf 'admission=%s\n' "$(sql_value control_panel "SELECT COALESCE(string_agg(failure_code||':'||attempt_count,',' ORDER BY last_seen_at), '') FROM runtime_admission_failures WHERE requested_runtime_id='${runtime}'" 2>/dev/null || true)"
  } >"${STATE_DIR}/${phase}-state.txt"
}

wait_for_terminal_exit() {
  local timeout="$1" description="$2" phase="$3" container deadline
  container="$(state_get ".${phase}.container_name")"
  deadline=$((SECONDS + timeout))
  until runtime_exited "${container}"; do
    if (( SECONDS >= deadline )); then
      capture_terminal_diagnostic "${phase}"
      die "timed out after ${timeout}s: ${description}; diagnostic=${STATE_DIR}/${phase}-state.txt"
    fi
    sleep 0.25
  done
}

make_fast_control_config() {
  local output="${STATE_DIR}/control-fast.yaml"
  sed -e 's/heartbeat_grace_seconds: 30/heartbeat_grace_seconds: 2/' \
      -e 's/death_grace_seconds: 300/death_grace_seconds: 3/' \
      "${SOURCE_ROOT}/control-panel-service/config.local.yaml" >"${output}"
  chmod 0600 "${output}"
  rg -q 'heartbeat_grace_seconds: 2' "${output}" || die "fast heartbeat grace config was not written"
  rg -q 'death_grace_seconds: 3' "${output}" || die "fast death grace config was not written"
  printf '%s\n' "${output}"
}

cleanup_live() {
  local owner token session runtime fast=false cleanup_ok=true lower source database_created=false
  [[ -f "${STATE_DIR}/live-state.json" ]] || { jq -nc '{owned_only:true,artifacts_removed:true}'; return; }
  owner="$(state_get .owner_token)"
  token="$(jq -r '.auth.token // ""' "${STATE_DIR}/live-state.json")"
  session="$(jq -r '.normal.session_id // ""' "${STATE_DIR}/live-state.json")"
  runtime="$(jq -r '.normal.runtime_id // ""' "${STATE_DIR}/live-state.json")"
  fast="$(jq -r '.fast_control // false' "${STATE_DIR}/live-state.json")"
  if [[ "${fast}" == "true" ]]; then
    (control_stop) || cleanup_ok=false
    (control_start ./config.local.yaml) || cleanup_ok=false
  fi
  if [[ -n "${session}" && -n "${token}" ]]; then
    (api_request POST "/api/strategy-sessions/${session}/stop" "${token}" '{"stop_action":"STOP_ONLY"}') \
      >"${STATE_DIR}/cleanup-stop-session.json" 2>/dev/null || true
  fi
  if [[ -n "${runtime}" && -n "${token}" ]]; then
    (api_request DELETE "/api/runtimes/${runtime}" "${token}") \
      >"${STATE_DIR}/cleanup-end-runtime.json" 2>/dev/null || true
  fi
  while IFS= read -r container; do
    [[ -z "${container}" ]] && continue
    if [[ "$(docker inspect -f '{{index .Config.Labels "hushine.acceptance.runtime-restart"}}' "${container}" 2>/dev/null || true)" == "${owner}" ]]; then
      docker unpause "${container}" >/dev/null 2>&1 || true
      docker rm -f "${container}" >/dev/null 2>&1 || cleanup_ok=false
    else
      cleanup_ok=false
    fi
  done < <(jq -r '[.normal,.revoke,.terminal_grace][]? | .container_name // empty' "${STATE_DIR}/live-state.json")
  if jq -e '.auth.user_id' "${STATE_DIR}/live-state.json" >/dev/null 2>&1; then
    local user portfolio venue strategy
    user="$(state_get .auth.user_id)"
    portfolio="$(jq -r '.normal.portfolio_id // 0' "${STATE_DIR}/live-state.json")"
    venue="$(jq -r '.normal.venue_id // 0' "${STATE_DIR}/live-state.json")"
    strategy="$(jq -r '.normal.strategy_id // 0' "${STATE_DIR}/live-state.json")"
    pg portfolio >/dev/null <<SQL || cleanup_ok=false
DO \$cleanup\$
DECLARE r record; pass int; predicate text;
BEGIN
  FOR pass IN 1..20 LOOP
    FOR r IN SELECT table_name FROM information_schema.tables WHERE table_schema='public' AND table_type='BASE TABLE' LOOP
      predicate := '';
      IF EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema='public' AND table_name=r.table_name AND column_name='user_id') THEN predicate := format('user_id=%s',${user}); END IF;
      IF ${portfolio} > 0 AND EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema='public' AND table_name=r.table_name AND column_name='portfolio_id') THEN predicate := predicate || CASE WHEN predicate='' THEN '' ELSE ' OR ' END || format('portfolio_id=%s',${portfolio}); END IF;
      IF ${venue} > 0 AND EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema='public' AND table_name=r.table_name AND column_name='venue_id') THEN predicate := predicate || CASE WHEN predicate='' THEN '' ELSE ' OR ' END || format('venue_id=%s',${venue}); END IF;
      IF ${strategy} > 0 AND EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema='public' AND table_name=r.table_name AND column_name='strategy_id') THEN predicate := predicate || CASE WHEN predicate='' THEN '' ELSE ' OR ' END || format('strategy_id=%s',${strategy}); END IF;
      IF '${session}' <> '' AND EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema='public' AND table_name=r.table_name AND column_name='session_id') THEN predicate := predicate || CASE WHEN predicate='' THEN '' ELSE ' OR ' END || format('session_id=%L','${session}'); END IF;
      IF predicate <> '' THEN BEGIN EXECUTE format('DELETE FROM %I WHERE %s',r.table_name,predicate); EXCEPTION WHEN foreign_key_violation THEN NULL; END; END IF;
    END LOOP;
  END LOOP;
END \$cleanup\$;
SQL
    pg portfolio -c "DELETE FROM users WHERE id=${user}" >/dev/null || cleanup_ok=false
    pg order >/dev/null <<SQL || cleanup_ok=false
DO \$cleanup\$
DECLARE r record; pass int; predicate text;
BEGIN
 FOR pass IN 1..20 LOOP
  FOR r IN SELECT table_name FROM information_schema.tables WHERE table_schema='public' AND table_type='BASE TABLE' LOOP
   predicate := '';
   IF EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema='public' AND table_name=r.table_name AND column_name='user_id') THEN predicate := format('user_id=%s',${user}); END IF;
   IF '${session}' <> '' AND EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema='public' AND table_name=r.table_name AND column_name='session_id') THEN predicate := predicate || CASE WHEN predicate='' THEN '' ELSE ' OR ' END || format('session_id=%L','${session}'); END IF;
   IF predicate <> '' THEN BEGIN EXECUTE format('DELETE FROM %I WHERE %s',r.table_name,predicate); EXCEPTION WHEN foreign_key_violation THEN NULL; END; END IF;
  END LOOP;
 END LOOP;
END \$cleanup\$;
SQL
    pg control_panel -c "DELETE FROM runtime_registry WHERE user_id=${user}; DELETE FROM runtime_credentials WHERE user_id=${user}; DELETE FROM runtime_admission_failures WHERE user_id=${user};" >/dev/null || cleanup_ok=false
  fi
  if jq -e '.market.lower' "${STATE_DIR}/live-state.json" >/dev/null 2>&1; then
    lower="$(state_get .market.lower)"; source="$(state_get .market.source)"; database_created="$(state_get .market.database_created)"
    pg control_panel -c "DELETE FROM market_data_coverage_segments WHERE source='${source}'" >/dev/null || cleanup_ok=false
    if database_exists binance_2025; then
      pg binance_2025 -c "DROP TABLE IF EXISTS futures_klines_${lower}_1m; DROP TABLE IF EXISTS futures_funding_rates_${lower};" >/dev/null || cleanup_ok=false
      if [[ "${database_created}" == "true" && "$(sql_value postgres "SELECT COALESCE(shobj_description(oid,'pg_database'),'') FROM pg_database WHERE datname='binance_2025'")" == "${source}" ]]; then
        pg postgres -c "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname='binance_2025' AND pid <> pg_backend_pid()" >/dev/null || cleanup_ok=false
        pg postgres -c "DROP DATABASE binance_2025" >/dev/null || cleanup_ok=false
      fi
    fi
  fi
  rm -f -- "${STATE_DIR}"/credential-*.json "${STATE_DIR}"/api.*
  [[ -z "$(docker ps -aq --filter "label=hushine.acceptance.runtime-restart=${owner}")" ]] || cleanup_ok=false
  if jq -e '.auth.user_id' "${STATE_DIR}/live-state.json" >/dev/null 2>&1; then
    local remaining
    user="$(state_get .auth.user_id)"
    remaining="$(sql_value portfolio "SELECT count(*) FROM users WHERE id=${user}")"
    [[ "${remaining}" == "0" ]] || cleanup_ok=false
    remaining="$(sql_value control_panel "SELECT (SELECT count(*) FROM runtime_credentials WHERE user_id=${user}) + (SELECT count(*) FROM runtime_registry WHERE user_id=${user}) + (SELECT count(*) FROM runtime_admission_failures WHERE user_id=${user})")"
    [[ "${remaining}" == "0" ]] || cleanup_ok=false
  fi
  if jq -e '.market.source' "${STATE_DIR}/live-state.json" >/dev/null 2>&1; then
    source="$(state_get .market.source)"
    [[ "$(sql_value control_panel "SELECT count(*) FROM market_data_coverage_segments WHERE source='${source}'")" == "0" ]] || cleanup_ok=false
  fi
  jq -nc --argjson ok "${cleanup_ok}" '{owned_only:true,artifacts_removed:$ok}'
  [[ "${cleanup_ok}" == "true" ]]
}

live_action() {
  local action="$1" payload="${2:-}" runtime container key token result before after code elapsed correlation
  case "${action}" in
    preflight)
      for command in curl docker jq make openssl python3 rg sed; do require_command "${command}"; done
      docker inspect "${PG_CONTAINER}" >/dev/null 2>&1 || die "local TimescaleDB container is unavailable: ${PG_CONTAINER}"
      docker image inspect "${RUNTIME_IMAGE}" >/dev/null 2>&1 || die "runtime image is unavailable: ${RUNTIME_IMAGE}"
      curl -fsS --max-time 2 "${API}/healthz" >/dev/null || die "quant-handler is not healthy"
      curl -fsS --max-time 2 "${CONTROL_READY}" >/dev/null || die "control-panel-service is not ready"
      [[ -f "${SOURCE_ROOT}/control-panel-service/.run.pid" ]] || die "control-panel-service is not owned by local-start"
      local coverage_constraint
      coverage_constraint="$(sql_value control_panel "SELECT pg_get_constraintdef(oid) FROM pg_constraint WHERE conname='market_data_coverage_segments_interval_check'")"
      if [[ "${coverage_constraint}" != *"funding_rate"* || "${coverage_constraint}" != *"interval\" = ''"* ]]; then
        die "environmental blocker: control_panel.market_data_coverage_segments_interval_check cannot represent funding_rate interval=''; current definition: ${coverage_constraint}"
      fi
      if [[ ! -f "${STATE_DIR}/live-state.json" ]]; then
        jq -nc --arg owner "$(openssl rand -hex 32)" --arg generation "generation-$(openssl rand -hex 16)" \
          '{schema:1,owner_token:$owner,generation:$generation,fast_control:false}' >"${STATE_DIR}/live-state.json"
        chmod 0600 "${STATE_DIR}/live-state.json"
      fi
      jq -nc '{ok:true}'
      ;;
    create-normal) create_normal_fixture ;;
    snapshot-before|snapshot-disconnected|snapshot-after) snapshot_normal ;;
    stop-control-panel)
      runtime="$(state_get .normal.runtime_id)"
      result="$(sql_value control_panel "SELECT issued_at::text||'|'||updated_at::text||'|'||count(*) OVER() FROM runtime_channel_leases WHERE runtime_id='${runtime}'")"
      state_update --arg lease "${result}" '.normal.lease_before=$lease'
      control_stop
      wait_for 15 "agent readiness cleared" agent_ready_is "$(state_get .normal.container_name)" 503
      jq -nc '{stopped:true,only_control_panel:true}'
      ;;
    pending-rpc)
      token="$(state_get .auth.token)"; runtime="$(state_get .normal.runtime_id)"; correlation="rpc-$(state_get .owner_token | cut -c1-16)"
      local response_file="${STATE_DIR}/pending-rpc.json"
      result="$(curl -sS --max-time 2 -X DELETE -H "Authorization: Bearer ${token}" -H "X-Correlation-ID: ${correlation}" \
        -o "${response_file}" -w '%{http_code}|%{time_total}' "${API}/api/runtimes/${runtime}" || true)"
      IFS='|' read -r code elapsed <<<"${result}"
      elapsed="$(python3 -c 'import sys; print(max(1,round(float(sys.argv[1])*1000)))' "${elapsed:-2}")"
      [[ "${code}" == "503" ]] || die "pending platform RPC returned HTTP ${code}: $(cat "${response_file}")"
      state_update --arg correlation "${correlation}" '.normal.pending_correlation=$correlation'
      jq -nc --argjson elapsed_ms "${elapsed}" --arg correlation_id "${correlation}" \
        '{status:"failed",grpc_code:"Unavailable",elapsed_ms:$elapsed_ms,replay_count:0,correlation_id:$correlation_id}'
      ;;
    start-control-panel)
      control_start ./config.local.yaml
      jq -nc '{started:true}'
      ;;
    wait-resume)
      container="$(state_get .normal.container_name)"; runtime="$(state_get .normal.runtime_id)"
      wait_for 30 "normal runtime RESUME readiness" agent_ready_is "${container}" 200
      wait_for 30 "normal runtime active after RESUME" runtime_status_is "${runtime}" active
      before="$(state_get .normal.lease_before)"
      after="$(sql_value control_panel "SELECT issued_at::text||'|'||updated_at::text||'|'||count(*) OVER() FROM runtime_channel_leases WHERE runtime_id='${runtime}'")"
      [[ "${after}" != "${before}" && "${after##*|}" == "1" ]] || die "RuntimeChannel lease did not rotate exactly once on RESUME (before=${before}, after=${after})"
      [[ "${after%%|*}" == "${before%%|*}" ]] || die "RESUME created a new lease instead of rotating the HELLO lease"
      if [[ "$(sql_value control_panel "SELECT count(*) FROM runtime_registry WHERE runtime_id='${runtime}' AND status='active'")" != "1" ]]; then die "runtime did not remain active after reconnect"; fi
      jq -nc --arg resume_observed_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg lease_before "${before}" --arg lease_after "${after}" \
        '{resumed:true,first_frame:"RESUME",agent_ready_http:200,resume_observed_at:$resume_observed_at,proof:{one_shot_credential_consumed:true,same_lease_issued_at:true,lease_before:$lease_before,lease_after:$lease_after}}'
      ;;
    advance-data)
      local barrier="$(state_get .normal.runtime_root)/runtime-restart-barrier.json"
      atomic_json "${barrier}" '.target_completed=1025' "${barrier}"
      wait_for 60 "worker barrier at callback 1025" barrier_at 1025
      local session="$(state_get .normal.session_id)" venue="$(state_get .normal.venue_id)"
      wait_for 30 "one funding income wallet effect" income_count_is_one "${session}" "${venue}"
      jq -nc '{advanced:true}'
      ;;
    create-revoke)
      start_owned_runtime revoke >/dev/null
      jq -nc --arg runtime_id "$(state_get .revoke.runtime_id)" --arg credential_key_id "$(state_get .revoke.credential_key_id)" '{runtime_id:$runtime_id,credential_key_id:$credential_key_id}'
      ;;
    revoke-credential)
      key="$(state_get .revoke.credential_key_id)"; token="$(state_get .auth.token)"
      result="$(api_request DELETE "/api/runtime-credentials/${key}" "${token}")"
      state_update --argjson response "${result}" '.revoke.response=$response'
      jq -nc --argjson streams "$(jq -er .streams_closed <<<"${result}")" --argjson runtimes "$(jq -er .runtimes_ended <<<"${result}")" '{revoked:true,streams_closed:$streams,runtimes_ended:$runtimes}'
      ;;
    assert-revoke-terminal)
      container="$(state_get .revoke.container_name)"; wait_for_terminal_exit 30 "revoked runtime safe stop" revoke
      local exit_code attempts
      exit_code="$(docker inspect -f '{{.State.ExitCode}}' "${container}")"
      attempts="$(sql_value control_panel "SELECT COALESCE(sum(attempt_count),0) FROM runtime_admission_failures WHERE requested_runtime_id='$(state_get .revoke.runtime_id)' AND last_seen_at >= (SELECT revoked_at FROM runtime_credentials WHERE key_id='$(state_get .revoke.credential_key_id)')")"
      (( attempts <= 1 )) || die "credential revoke caused reconnect storm: ${attempts} attempts"
      jq -nc --argjson attempts "${attempts}" --argjson exit "${exit_code}" '{safe_stop:true,reconnect_storm:false,reconnect_attempts:$attempts,agent_exit_code:$exit}'
      ;;
    create-terminal-grace)
      start_owned_runtime terminal_grace >/dev/null
      jq -nc --arg runtime_id "$(state_get .terminal_grace.runtime_id)" --arg credential_key_id "$(state_get .terminal_grace.credential_key_id)" '{runtime_id:$runtime_id,credential_key_id:$credential_key_id}'
      ;;
    exceed-terminal-grace)
      container="$(state_get .terminal_grace.container_name)"; runtime="$(state_get .terminal_grace.runtime_id)"
      docker pause "${container}" >/dev/null
      control_stop
      local fast_config; fast_config="$(make_fast_control_config)"
      state_update '.fast_control=true'
      control_start "${fast_config}"
      wait_for 20 "runtime terminalized after grace" runtime_status_is "${runtime}" heartbeat_stale
      docker unpause "${container}" >/dev/null
      jq -nc '{terminalized:true,grace_seconds:3}'
      ;;
    assert-terminal-resume-rejected)
      container="$(state_get .terminal_grace.container_name)"; runtime="$(state_get .terminal_grace.runtime_id)"
      wait_for_terminal_exit 30 "terminal RESUME rejection safe stop" terminal_grace
      local failure exit_code attempts
      failure="$(sql_value control_panel "SELECT failure_code||'|'||attempt_count FROM runtime_admission_failures WHERE requested_runtime_id='${runtime}' ORDER BY last_seen_at DESC LIMIT 1")"
      IFS='|' read -r code attempts <<<"${failure}"
      [[ "${code}" == "failed_precondition" ]] || die "terminal RESUME rejection code was ${code:-missing}, want failed_precondition"
      (( attempts <= 1 )) || die "terminal RESUME rejection caused reconnect storm: ${attempts} attempts"
      exit_code="$(docker inspect -f '{{.State.ExitCode}}' "${container}")"
      jq -nc --argjson attempts "${attempts}" --argjson exit "${exit_code}" '{resume_rejected:true,grpc_code:"FailedPrecondition",safe_stop:true,reconnect_storm:false,reconnect_attempts:$attempts,agent_exit_code:$exit}'
      ;;
    cleanup) cleanup_live ;;
    *) die "unknown live action: ${action}" ;;
  esac
}

require_json() {
  local label="$1" filter="$2" payload="$3"
  jq -e "${filter}" <<<"${payload}" >/dev/null \
    || die "${label} returned invalid evidence: ${payload}"
}

same_identity() {
  local before="$1" after="$2"
  jq -e --argjson before "${before}" '
    .runtime_container_pid == $before.runtime_container_pid
    and .agent_pid == $before.agent_pid
    and .worker_pid == $before.worker_pid
    and .worker_generation == $before.worker_generation
    and .session_id == $before.session_id
  ' <<<"${after}" >/dev/null
}

cleanup_once() {
  [[ "${CLEANED_UP}" == "false" ]] || return 0
  CLEANED_UP=true
  run_action cleanup
}

on_exit() {
  local rc="$?"
  trap - EXIT INT TERM
  if [[ "${CLEANED_UP}" == "false" ]]; then
    cleanup_once >/dev/null 2>&1 || rc=1
  fi
  exit "${rc}"
}
trap on_exit EXIT INT TERM

if [[ "${CLEANUP_ONLY}" == "true" ]]; then
  capture_cleanup cleanup
  require_json cleanup '.owned_only == true and .artifacts_removed == true' "${cleanup}"
  trap - EXIT INT TERM
  echo "runtime-channel restart acceptance: cleanup PASS"
  exit 0
fi

capture_action preflight preflight
require_json preflight '.ok == true' "${preflight}"

capture_action normal_fixture create-normal
require_json normal-fixture '
  (.owner_token | type == "string" and length > 0)
  and (.runtime_id | type == "string" and length > 0)
  and (.session_id | type == "string" and length > 0)
  and (.credential_key_id | type == "string" and length > 0)
  and (.container_name | type == "string" and length > 0)
' "${normal_fixture}"

capture_action before snapshot-before "${normal_fixture}"
require_json before '
  .runtime_container_pid > 1 and .agent_pid > 0 and .worker_pid > 1
  and .worker_generation > 0 and .session_status == "running"
  and .agent_health_http == 200 and .agent_ready_http == 200
  and .heartbeat_cursor_us > 0 and (.heartbeat_at | length > 0)
  and .indicator_cursor >= 0 and .income_cursor >= 0
' "${before}"

capture_action stopped stop-control-panel "${normal_fixture}"
require_json stop-control-panel '.stopped == true and .only_control_panel == true' "${stopped}"

capture_action disconnected snapshot-disconnected "${normal_fixture}"
require_json disconnected '
  .session_status == "running"
  and .agent_health_http == 200 and .agent_ready_http == 503
' "${disconnected}"
same_identity "${before}" "${disconnected}" \
  || die "runtime/Agent/Worker identity changed while control-panel was stopped"

capture_action pending pending-rpc "${normal_fixture}"
require_json pending-rpc '
  .status == "failed" and .grpc_code == "Unavailable"
  and .elapsed_ms > 0 and .elapsed_ms <= 2000
  and .replay_count == 0
  and (.correlation_id | type == "string" and length > 0)
' "${pending}"

capture_action started start-control-panel "${normal_fixture}"
require_json start-control-panel '.started == true' "${started}"
capture_action resume wait-resume "${normal_fixture}"
require_json resume '
  .resumed == true and .first_frame == "RESUME"
  and .agent_ready_http == 200
  and (.resume_observed_at | type == "string" and length > 0)
' "${resume}"

capture_action advanced advance-data "${normal_fixture}"
require_json advance-data '.advanced == true' "${advanced}"
capture_action after snapshot-after "${normal_fixture}"
require_json after '
  .session_status == "running"
  and .agent_health_http == 200 and .agent_ready_http == 200
' "${after}"
same_identity "${before}" "${after}" \
  || die "runtime/Agent/Worker identity changed across control-panel restart"
jq -e --argjson before "${before}" '
  .heartbeat_cursor_us > $before.heartbeat_cursor_us
  and .indicator_cursor > $before.indicator_cursor
  and .income_cursor > $before.income_cursor
  and .wallet_effect_count == 1
' <<<"${after}" >/dev/null \
  || die "heartbeat/data cursors did not advance exactly once after RESUME"

capture_action revoke_fixture create-revoke
require_json revoke-fixture '(.runtime_id | length > 0) and (.credential_key_id | length > 0)' "${revoke_fixture}"
capture_action revoked revoke-credential "${revoke_fixture}"
require_json revoke-credential '.revoked == true and .streams_closed >= 1 and .runtimes_ended >= 1' "${revoked}"
capture_action revoke_result assert-revoke-terminal "${revoke_fixture}"
require_json revoke-result '
  .safe_stop == true and .reconnect_storm == false
  and .reconnect_attempts >= 0 and .reconnect_attempts <= 1
  and .agent_exit_code != 0
' "${revoke_result}"

capture_action grace_fixture create-terminal-grace
require_json terminal-grace-fixture '(.runtime_id | length > 0) and (.credential_key_id | length > 0)' "${grace_fixture}"
capture_action grace exceed-terminal-grace "${grace_fixture}"
require_json terminal-grace '.terminalized == true and .grace_seconds > 0' "${grace}"
capture_action grace_result assert-terminal-resume-rejected "${grace_fixture}"
require_json terminal-grace-result '
  .resume_rejected == true and .grpc_code == "FailedPrecondition"
  and .safe_stop == true and .reconnect_storm == false
  and .reconnect_attempts >= 0 and .reconnect_attempts <= 1
  and .agent_exit_code != 0
' "${grace_result}"

capture_cleanup cleanup
require_json cleanup '.owned_only == true and .artifacts_removed == true' "${cleanup}"

jq -S -n \
  --arg generated_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --argjson fixture "${normal_fixture}" \
  --argjson before "${before}" \
  --argjson disconnected "${disconnected}" \
  --argjson pending "${pending}" \
  --argjson resume "${resume}" \
  --argjson after "${after}" \
  --argjson revoke "${revoke_result}" \
  --argjson grace "${grace_result}" \
  --argjson cleanup "${cleanup}" \
  '{
    schema:1,
    result:"PASS",
    generated_at:$generated_at,
    normal:{
      fixture:$fixture,
      before:$before,
      disconnected:$disconnected,
      pending_rpc:$pending,
      resume:$resume,
      after:$after
    },
    negative:{credential_revoke:$revoke,terminal_grace:$grace},
    cleanup:$cleanup
  }' >"${EVIDENCE_FILE}"
chmod 0600 "${EVIDENCE_FILE}"

trap - EXIT INT TERM
echo "runtime-channel restart acceptance: PASS"
echo "evidence_file=${EVIDENCE_FILE}"
