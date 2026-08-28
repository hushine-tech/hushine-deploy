#!/usr/bin/env bash
set -euo pipefail

DEPLOY_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
SOURCE_ROOT="${HUSHINE_SOURCE_ROOT:-$(cd "${DEPLOY_ROOT}/.." && pwd -P)}"
EVIDENCE_FILE=""
STATE_DIR=""
DRIVER="${RUNTIME_RESTART_DRIVER:-}"
CLEANED_UP=false
CLEANUP_ONLY=false
SANITIZE_INSPECT=""
DIAGNOSTIC_OUTPUT=""
PG_CONTAINER="${HUSHINE_LOCAL_PG_CONTAINER:-hushine-local-timescaledb-1}"
RUNTIME_IMAGE="${HUSHINE_RUNTIME_RESTART_IMAGE:-hushine/strategy-runtime:executor-dev}"
KAFKA_CONTAINER="${HUSHINE_RUNTIME_RESTART_KAFKA_CONTAINER:-hushine-local-kafka-1}"
API="${HUSHINE_RUNTIME_RESTART_API:-http://127.0.0.1:8090}"
CONTROL_READY="${HUSHINE_RUNTIME_RESTART_CONTROL_READY:-http://127.0.0.1:8082/readyz}"

die() {
  echo "runtime-channel restart acceptance: $*" >&2
  exit 1
}

usage() {
  cat <<'EOF'
Usage: scripts/test-runtime-channel-restart.sh [--evidence-file FILE] [--state-dir DIR] [--cleanup-only]
       scripts/test-runtime-channel-restart.sh --sanitize-docker-inspect FILE --diagnostic-output FILE

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
    --sanitize-docker-inspect)
      [[ "$#" -ge 2 ]] || die "--sanitize-docker-inspect requires a path"
      SANITIZE_INSPECT="$2"
      shift 2
      ;;
    --diagnostic-output)
      [[ "$#" -ge 2 ]] || die "--diagnostic-output requires a path"
      DIAGNOSTIC_OUTPUT="$2"
      shift 2
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

if [[ -n "${SANITIZE_INSPECT}" || -n "${DIAGNOSTIC_OUTPUT}" ]]; then
  [[ -n "${SANITIZE_INSPECT}" && -n "${DIAGNOSTIC_OUTPUT}" ]] \
    || die "diagnostic projection requires both input and output paths"
  [[ -f "${SANITIZE_INSPECT}" && ! -L "${SANITIZE_INSPECT}" ]] \
    || die "diagnostic input must be a regular non-symlink file"
  [[ ! -L "${DIAGNOSTIC_OUTPUT}" ]] || die "diagnostic output must not be a symlink"
  jq -e 'type == "array" and length == 1' "${SANITIZE_INSPECT}" >/dev/null \
    || die "diagnostic input must contain one Docker inspect record"
  jq '.[0] | {
    container_id:(.Id // ""),
    pid:(.State.Pid // 0),
    status:(.State.Status // ""),
    running:(.State.Running // false),
    exit_code:(.State.ExitCode // 0),
    image:(.Config.Image // ""),
    safe_labels:{
      "hushine.acceptance.runtime-restart":(.Config.Labels["hushine.acceptance.runtime-restart"] // "")
    }
  }' "${SANITIZE_INSPECT}" >"${DIAGNOSTIC_OUTPUT}"
  chmod 0600 "${DIAGNOSTIC_OUTPUT}"
  exit 0
fi

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
export RUNTIME_RESTART_CONTRACT_STATE="${STATE_DIR}"
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

file_uid_mode() {
  local path="$1"
  if stat -f '%u|%Lp' "${path}" >/dev/null 2>&1; then
    stat -f '%u|%Lp' "${path}"
  else
    stat -c '%u|%a' "${path}"
  fi
}

validate_cleanup_manifest() {
  local manifest="${STATE_DIR}/live-state.json" expected_mode owner expected_symbol expected_lower expected_source
  local expected_uid uid_mode
  [[ -f "${manifest}" && ! -L "${manifest}" ]] || die "cleanup manifest must be a regular non-symlink file"
  expected_uid="$(id -u)"
  uid_mode="$(file_uid_mode "${STATE_DIR}")"
  [[ "${uid_mode}" == "${expected_uid}|700" ]] || die "cleanup state directory must be owned by the current user with mode 0700"
  uid_mode="$(file_uid_mode "${manifest}")"
  [[ "${uid_mode}" == "${expected_uid}|600" ]] || die "cleanup manifest must be owned by the current user with mode 0600"
  expected_mode=live
  [[ -z "${DRIVER}" ]] || expected_mode=contract
  owner="$(jq -er '.owner_token | select(type == "string" and test("^[0-9a-f]{64}$"))' "${manifest}")" \
    || die "cleanup manifest owner_token is invalid"
  expected_symbol="$(printf 'RCR%sUSDT' "${owner:0:12}" | tr '[:lower:]' '[:upper:]')"
  expected_lower="$(printf '%s' "${expected_symbol}" | tr '[:upper:]' '[:lower:]')"
  expected_source="runtime-channel-restart:${owner}"
  jq -e \
    --arg mode "${expected_mode}" --arg owner "${owner}" --arg symbol "${expected_symbol}" \
    --arg lower "${expected_lower}" --arg source "${expected_source}" --arg state_dir "${STATE_DIR}" '
    .schema == 2 and .mode == $mode and .owner_token == $owner
    and ((keys - ["schema","mode","owner_token","generation","service_baseline","control_panel_stopped","fast_control","kafka_proxy","auth","market","normal","revoke","terminal_grace","pending_rpc"]) | length) == 0
    and (.generation | type == "string" and test("^generation-[0-9a-f]{32}$"))
    and (.control_panel_stopped | type == "boolean")
    and (.fast_control | type == "boolean")
    and (.service_baseline | type == "object"
      and (keys | sort) == ["config","pid","ready_http","was_running"]
      and (.was_running | type == "boolean")
      and .config == "./config.local.yaml"
      and (.ready_http | type == "number")
      and (.pid | type == "number" and . >= 0))
    and ((.auth // null) == null or (
      (.auth | keys | sort) == ["token","user_id"]
      and (.auth.user_id | type == "number" and . > 0 and floor == .)
      and (.auth.token | type == "string" and test("^[A-Za-z0-9_-]+\\.[A-Za-z0-9_-]+\\.[A-Za-z0-9_-]+$"))))
    and ((.market // null) == null or (
      (.market | keys - ["fixture_committed"] | sort) == ["database_created","lower","source","symbol"]
      and .market.symbol == $symbol and .market.lower == $lower and .market.source == $source
      and (.market.database_created | type == "boolean")
      and ((.market.fixture_committed // false) | type == "boolean")))
    and ((.kafka_proxy // null) == null or (
      (.kafka_proxy | keys | sort) == ["config","control_dir","pid","port"]
      and (.kafka_proxy.pid | type == "number" and . > 1 and floor == .)
      and (.kafka_proxy.port | type == "number" and . > 0 and . < 65536 and floor == .)
      and .kafka_proxy.config == ($state_dir + "/control-pending.yaml")
      and .kafka_proxy.control_dir == ($state_dir + "/kafka-proxy")))
    and ((.pending_rpc // null) == null or (
      (.pending_rpc | keys) == ["correlation_id"]
      and (.pending_rpc.correlation_id | test("^rpc-[0-9a-f]{24}$"))))
    and (. as $root | ["normal","revoke","terminal_grace"] | all(. as $phase |
      (($root[$phase] // null) == null or (
        (($root[$phase] | keys) - ["runtime_id","credential_key_id","container_name","runtime_root","portfolio_id","venue_id","strategy_id","session_id","lease_before","connection_owner_before","response","terminalized_at"] | length) == 0
        and ($root[$phase].runtime_id | type == "string" and test("^selfhosted-[A-Za-z0-9_-]{22}$"))
        and ($root[$phase].credential_key_id | type == "string" and test("^[A-Za-z0-9_-]{22}$"))
        and $root[$phase].runtime_id == ("selfhosted-" + $root[$phase].credential_key_id)
        and $root[$phase].container_name == ("hushine-runtime-restart-" + $phase + "-" + ($owner[0:10]))
        and $root[$phase].runtime_root == ($state_dir + "/runtimes/" + $phase)
        and (($root[$phase].session_id // null) == null or ($root[$phase].session_id | test("^[0-9a-f]{32}$")))
        and (["portfolio_id","venue_id","strategy_id"] | all(. as $id |
          (($root[$phase][$id] // null) == null or ($root[$phase][$id] | type == "number" and . > 0 and floor == .))))))))
  ' "${manifest}" >/dev/null || die "cleanup manifest schema or derived ownership fields are invalid"
}

validate_cleanup_ownership() {
  local raw user owner username phase runtime key container count source symbol
  if [[ -n "${DRIVER}" ]]; then
    raw="$(run_action validate-cleanup-ownership)" \
      || die "cleanup ownership observation failed"
    jq -e '.relationships_valid == true and .container_labels_valid == true and .market_ownership_valid == true' \
      <<<"${raw}" >/dev/null || die "cleanup ownership observation rejected the manifest"
    return
  fi
  owner="$(state_get .owner_token)"
  if jq -e '.auth != null' "${STATE_DIR}/live-state.json" >/dev/null; then
    user="$(state_get .auth.user_id)"
    username="runtime-restart-${owner:0:12}"
    count="$(pg portfolio -At -v user_id="${user}" -v username="${username}" <<'SQL'
SELECT count(*) FROM users WHERE id=:'user_id'::bigint AND username=:'username';
SQL
)"
    [[ "${count}" == "1" ]] || die "cleanup user ownership relationship is invalid"
  fi
  for phase in normal revoke terminal_grace; do
    jq -e --arg phase "${phase}" '.[$phase] != null' "${STATE_DIR}/live-state.json" >/dev/null || continue
    runtime="$(state_get ".${phase}.runtime_id")"; key="$(state_get ".${phase}.credential_key_id")"
    container="$(state_get ".${phase}.container_name")"
    count="$(pg control_panel -At -v user_id="${user}" -v runtime_id="${runtime}" -v key_id="${key}" <<'SQL'
SELECT (SELECT count(*) FROM runtime_registry WHERE user_id=:'user_id'::bigint AND runtime_id=:'runtime_id' AND credential_key_id=:'key_id')
     + (SELECT count(*) FROM runtime_credentials WHERE user_id=:'user_id'::bigint AND key_id=:'key_id');
SQL
)"
    [[ "${count}" == "2" ]] || die "cleanup ${phase} runtime/credential ownership relationship is invalid"
    if docker inspect "${container}" >/dev/null 2>&1; then
      [[ "$(docker inspect -f '{{index .Config.Labels "hushine.acceptance.runtime-restart"}}' "${container}")" == "${owner}" ]] \
        || die "cleanup ${phase} container owner label is invalid"
    fi
  done
  if jq -e '.normal.portfolio_id != null' "${STATE_DIR}/live-state.json" >/dev/null; then
    count="$(pg portfolio -At \
      -v user_id="${user}" -v portfolio_id="$(state_get .normal.portfolio_id)" \
      -v venue_id="$(state_get .normal.venue_id)" -v strategy_id="$(state_get .normal.strategy_id)" \
      -v session_id="$(state_get .normal.session_id)" -v runtime_id="$(state_get .normal.runtime_id)" <<'SQL'
SELECT (SELECT count(*) FROM portfolios WHERE portfolio_id=:'portfolio_id'::bigint AND user_id=:'user_id'::bigint)
     + (SELECT count(*) FROM venues WHERE venue_id=:'venue_id'::bigint AND portfolio_id=:'portfolio_id'::bigint AND user_id=:'user_id'::bigint)
     + (SELECT count(*) FROM strategies WHERE strategy_id=:'strategy_id'::bigint AND user_id=:'user_id'::bigint)
     + (SELECT count(*) FROM strategy_sessions WHERE session_id=:'session_id' AND portfolio_id=:'portfolio_id'::bigint AND user_id=:'user_id'::bigint AND strategy_id=:'strategy_id'::bigint AND runtime_id=:'runtime_id');
SQL
)"
    [[ "${count}" == "4" ]] || die "cleanup Portfolio/Venue/Strategy/Session ownership relationship is invalid"
  fi
  if jq -e '.market != null and (.market.fixture_committed // false)' "${STATE_DIR}/live-state.json" >/dev/null; then
    source="runtime-channel-restart:${owner}"
    symbol="$(printf 'RCR%sUSDT' "${owner:0:12}" | tr '[:lower:]' '[:upper:]')"
    count="$(pg control_panel -At -v source="${source}" -v symbol="${symbol}" <<'SQL'
SELECT count(*) FILTER (WHERE symbol=:'symbol')::text || '|' || count(*)::text
FROM market_data_coverage_segments WHERE source=:'source';
SQL
)"
    [[ "${count}" == "2|2" ]] || die "cleanup market coverage ownership relationship is invalid"
  fi
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

json_file_matches() {
  local path="$1" filter="$2"
  [[ -f "${path}" && ! -L "${path}" ]] && jq -e "${filter}" "${path}" >/dev/null 2>&1
}

kafka_notification_count() {
  local correlation="$1" output
  output="$(docker exec "${KAFKA_CONTAINER}" kafka-console-consumer \
    --bootstrap-server 127.0.0.1:9092 --topic notification.events \
    --from-beginning --timeout-ms 1500 2>/dev/null || true)"
  awk -v needle="${correlation}" 'index($0, needle) { count++ } END { print count + 0 }' <<<"${output}"
}

kafka_notification_count_is() {
  [[ "$(kafka_notification_count "$1")" == "$2" ]]
}

kafka_notification_count_stays_one() {
  local correlation="$1" deadline=$((SECONDS + 3))
  while (( SECONDS < deadline )); do
    [[ "$(kafka_notification_count "${correlation}")" == "1" ]] || return 1
  done
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
  state_update '.market.fixture_committed=true'
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
    'import stat\nimport time': 'import stat\nimport threading\nimport time',
    'from pathlib import Path\nfrom typing import Any': 'from pathlib import Path\nfrom typing import Any\n\nfrom google.protobuf.struct_pb2 import Struct',
    'ACCEPTANCE_BARRIER_FILE = ""': 'ACCEPTANCE_BARRIER_FILE = "/coverage/runtime-restart-barrier.json"',
    'ACCEPTANCE_BARRIER_OWNER_TOKEN = ""': f'ACCEPTANCE_BARRIER_OWNER_TOKEN = {json.dumps(owner)}',
    'ACCEPTANCE_BARRIER_GENERATION = ""': f'ACCEPTANCE_BARRIER_GENERATION = {json.dumps(generation)}',
    'TESTUSDT': symbol,
    'if sequence in {4, 9, 1438}:': 'if sequence in {4, 1438}:',
    'self._last_open_time_ms = 0': 'self._last_open_time_ms = 0\n        self._acceptance_pending_started = False',
}
for old, new in replacements.items():
    if old not in source:
        raise SystemExit(f"strategy fixture contract changed: {old}")
    source = source.replace(old, new)
anchor = '    def _barrier_before_next_callback(self) -> None:\n'
pending_method = '''    def _run_acceptance_pending_call(self, control: dict[str, Any]) -> None:
        correlation = str(control["correlation_id"])
        started_path = Path(str(control["started_file"]))
        result_path = Path(str(control["result_file"]))
        started_ns = time.time_ns()
        self._atomic_private_json(started_path, {
            "schema": 1,
            "correlation_id": correlation,
            "caller": "python-worker",
            "method": "notification.Publish",
            "worker_pid": os.getpid(),
            "started_at_ns": started_ns,
        })
        request = Struct()
        request.update({
            "category": "custom",
            "severity": "info",
            "title": "Runtime restart acceptance",
            "message": correlation,
            "session_id": str(control["session_id"]),
            "dedupe_key": correlation,
        })
        code = "OK"
        message = ""
        try:
            self.notify._client._proxy.invoke(
                "notification.Publish", request, Struct, timeout_seconds=30.0
            )
        except Exception as exc:
            code = str(getattr(exc, "code", ""))
            message = str(exc)
        self._atomic_private_json(result_path, {
            "schema": 1,
            "correlation_id": correlation,
            "caller_completed": True,
            "caller_grpc_code": code,
            "caller_error": message,
            "caller_elapsed_ms": max(1, (time.time_ns() - started_ns) // 1_000_000),
            "caller_completion_count": 1,
            "worker_pid": os.getpid(),
        })

'''
if anchor not in source:
    raise SystemExit(f"strategy fixture contract changed: {anchor!r}")
source = source.replace(anchor, pending_method + anchor, 1)
barrier_anchor = '            target = self._positive_int(\n'
barrier_pending = '''            pending = control.get("pending_call")
            if pending is not None and not self._acceptance_pending_started:
                if not isinstance(pending, dict):
                    raise RuntimeError("pending_call must be an object")
                correlation = str(pending.get("correlation_id") or "")
                paths = [Path(str(pending.get(name) or "")) for name in ("started_file", "result_file")]
                if not correlation.startswith("rpc-") or any(
                    not path.is_absolute() or path.parent != Path("/coverage") for path in paths
                ):
                    raise RuntimeError("pending_call ownership fields are invalid")
                pending["session_id"] = session_id
                self._acceptance_pending_started = True
                threading.Thread(
                    target=self._run_acceptance_pending_call,
                    args=(pending,),
                    name="runtime-restart-pending-call",
                    daemon=True,
                ).start()
'''
if barrier_anchor not in source:
    raise SystemExit(f"strategy fixture contract changed: {barrier_anchor!r}")
source = source.replace(barrier_anchor, barrier_pending + barrier_anchor, 1)
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
  local wallet_balance available_balance total_value income_amount income_asset
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
  IFS='|' read -r wallet_balance available_balance total_value < <(pg portfolio -At -F '|' -v venue_id="${venue}" <<'SQL'
SELECT wallet_balance::text,available_balance::text,total_value::text
FROM venue_wallet_states WHERE venue_id=:'venue_id'::bigint;
SQL
)
  IFS='|' read -r income_amount income_asset < <(pg portfolio -At -F '|' -v session_id="${session}" -v venue_id="${venue}" <<'SQL'
SELECT COALESCE(max(applied_amount)::text,''),COALESCE(max(asset),'')
FROM venue_income_entries e WHERE session_id=:'session_id' AND venue_id=:'venue_id'::bigint
  AND income_type='FUNDING_FEE'
  AND income_entry_id=(SELECT max(income_entry_id) FROM venue_income_entries
    WHERE session_id=:'session_id' AND venue_id=:'venue_id'::bigint AND income_type='FUNDING_FEE');
SQL
)
  if (( wallet_effect > 0 )) && [[ "${income}" != "${income_row_cursor}" ]]; then
    die "wallet Income cursor ${income} does not match exact durable Income row ${income_row_cursor}"
  fi
  jq -nc --argjson runtime_container_pid "${host_pid}" --argjson agent_pid "${agent}" \
    --argjson worker_pid "${worker_pid}" --argjson worker_generation "${generation}" \
    --arg session_id "${session}" --arg session_status "$(session_status "${session}")" \
    --argjson agent_health_http "${health}" --argjson agent_ready_http "${ready}" \
    --arg heartbeat_at "${heartbeat}" --argjson heartbeat_cursor_us "${heartbeat_us}" \
    --argjson indicator_cursor "${indicator}" --argjson income_cursor "${income}" \
    --argjson wallet_effect_count "${wallet_effect}" --arg wallet_balance "${wallet_balance}" \
    --arg available_balance "${available_balance}" --arg total_value "${total_value}" \
    --arg income_amount "${income_amount}" --arg income_asset "${income_asset}" --argjson income_id "${income_row_cursor}" \
    '{runtime_container_pid:$runtime_container_pid,agent_pid:$agent_pid,worker_pid:$worker_pid,worker_generation:$worker_generation,session_id:$session_id,session_status:$session_status,agent_health_http:$agent_health_http,agent_ready_http:$agent_ready_http,heartbeat_at:$heartbeat_at,heartbeat_cursor_us:$heartbeat_cursor_us,indicator_cursor:$indicator_cursor,income_cursor:$income_cursor,wallet_effect_count:$wallet_effect_count,wallet:{wallet_balance:$wallet_balance,available_balance:$available_balance,total_value:$total_value,last_applied_income_entry_id:$income_cursor},income:(if $income_id > 0 then {income_entry_id:$income_id,applied_amount:$income_amount,asset:$income_asset} else null end)}'
}

control_stop() {
  make -C "${SOURCE_ROOT}/control-panel-service" stop >"${STATE_DIR}/control-stop.log" 2>&1
  local deadline=$((SECONDS + 15))
  while curl -fsS --max-time 1 "${CONTROL_READY}" >/dev/null 2>&1; do
    (( SECONDS < deadline )) || die "control-panel-service did not stop"
    sleep 0.25
  done
}

control_runtime_config() {
  jq -r '.kafka_proxy.config // "./config.local.yaml"' "${STATE_DIR}/live-state.json"
}

start_kafka_hold_proxy() {
  local proxy_dir="${STATE_DIR}/kafka-proxy" pid port config
  mkdir -m 0700 -p "${proxy_dir}"
  python3 "${DEPLOY_ROOT}/scripts/runtime-channel-kafka-hold-proxy.py" \
    --target-port 9092 --control-dir "${proxy_dir}" \
    >"${proxy_dir}/proxy.log" 2>&1 &
  pid=$!
  if ! (wait_for 10 "Kafka hold proxy endpoint" test -s "${proxy_dir}/endpoint.json"); then
    kill "${pid}" 2>/dev/null || true
    wait "${pid}" 2>/dev/null || true
    die "Kafka hold proxy failed to publish its endpoint"
  fi
  port="$(jq -er '.port | select(type == "number" and . > 0)' "${proxy_dir}/endpoint.json")"
  config="${STATE_DIR}/control-pending.yaml"
  if ! python3 - "${SOURCE_ROOT}/control-panel-service/config.local.yaml" "${port}" >"${config}" <<'PY'
import pathlib
import sys

source = pathlib.Path(sys.argv[1]).read_text(encoding="utf-8").splitlines()
port = int(sys.argv[2])
in_notification = False
replaced = False
for line in source:
    if line == "notification:":
        in_notification = True
    elif line and not line.startswith((" ", "#")):
        in_notification = False
    if in_notification and line.strip().startswith("brokers:"):
        line = f'    brokers: ["127.0.0.1:{port}"]'
        replaced = True
    print(line)
if not replaced:
    raise SystemExit("notification Kafka broker config was not found")
PY
  then
    kill "${pid}" 2>/dev/null || true
    wait "${pid}" 2>/dev/null || true
    die "notification Kafka proxy config generation failed"
  fi
  chmod 0600 "${config}"
  state_update --argjson pid "${pid}" --argjson port "${port}" --arg config "${config}" --arg dir "${proxy_dir}" \
    '.kafka_proxy={pid:$pid,port:$port,config:$config,control_dir:$dir}'
}

stop_kafka_hold_proxy() {
  local pid
  pid="$(jq -r '.kafka_proxy.pid // 0' "${STATE_DIR}/live-state.json")"
  rm -f -- "${STATE_DIR}/kafka-proxy/hold.json"
  if [[ "${pid}" =~ ^[1-9][0-9]*$ ]] && kill -0 "${pid}" 2>/dev/null; then
    kill "${pid}" 2>/dev/null || true
    wait "${pid}" 2>/dev/null || true
  fi
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

restore_control_panel_baseline() {
  local was_running fast stopped proxy_active=false
  was_running="$(state_get .service_baseline.was_running)"
  fast="$(state_get .fast_control)"
  stopped="$(state_get .control_panel_stopped)"
  jq -e '.kafka_proxy != null' "${STATE_DIR}/live-state.json" >/dev/null 2>&1 && proxy_active=true
  if [[ "${was_running}" == "true" ]]; then
    if [[ "${fast}" == "true" || "${proxy_active}" == "true" ]]; then
      state_update '.control_panel_stopped=true'
      if control_ready_is || [[ -f "${SOURCE_ROOT}/control-panel-service/.run.pid" ]]; then
        control_stop
      fi
      control_start ./config.local.yaml
    elif [[ "${stopped}" == "true" ]] || ! control_ready_is; then
      control_start ./config.local.yaml
    fi
    wait_for 30 "restored control-panel-service readiness" control_ready_is
    state_update '.fast_control=false | .control_panel_stopped=false'
    stop_kafka_hold_proxy
    jq -nc '{baseline_restored:true,config:"./config.local.yaml",ready_http:200}'
    return
  fi
  if control_ready_is; then
    state_update '.control_panel_stopped=true'
    control_stop
  fi
  stop_kafka_hold_proxy
  state_update '.fast_control=false | .control_panel_stopped=false'
  jq -nc '{baseline_restored:true,config:"stopped",ready_http:0}'
}

runtime_exited() {
  [[ "$(docker inspect -f '{{.State.Running}}' "$1" 2>/dev/null || true)" == "false" ]]
}

capture_terminal_diagnostic() {
  local phase="$1" container runtime key owner
  container="$(state_get ".${phase}.container_name")"
  runtime="$(state_get ".${phase}.runtime_id")"
  key="$(state_get ".${phase}.credential_key_id")"
  owner="$(state_get .owner_token)"
  jq -nc \
    --arg container_id "$(docker inspect -f '{{.Id}}' "${container}" 2>/dev/null || true)" \
    --argjson pid "$(docker inspect -f '{{.State.Pid}}' "${container}" 2>/dev/null || echo 0)" \
    --arg status "$(docker inspect -f '{{.State.Status}}' "${container}" 2>/dev/null || true)" \
    --argjson running "$(docker inspect -f '{{.State.Running}}' "${container}" 2>/dev/null || echo false)" \
    --argjson exit_code "$(docker inspect -f '{{.State.ExitCode}}' "${container}" 2>/dev/null || echo 0)" \
    --arg image "$(docker inspect -f '{{.Config.Image}}' "${container}" 2>/dev/null || true)" \
    --arg owner "${owner}" \
    '{container_id:$container_id,pid:$pid,status:$status,running:$running,exit_code:$exit_code,image:$image,safe_labels:{"hushine.acceptance.runtime-restart":$owner}}' \
    >"${STATE_DIR}/${phase}-docker-inspect.json"
  chmod 0600 "${STATE_DIR}/${phase}-docker-inspect.json"
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
      "$(control_runtime_config)" >"${output}"
  chmod 0600 "${output}"
  rg -q 'heartbeat_grace_seconds: 2' "${output}" || die "fast heartbeat grace config was not written"
  rg -q 'death_grace_seconds: 3' "${output}" || die "fast death grace config was not written"
  printf '%s\n' "${output}"
}

cleanup_live() {
  local owner token session runtime cleanup_ok=true lower source database_created=false
  local user=0 portfolio=0 venue=0 strategy=0 username
  local normal_runtime="" revoke_runtime="" terminal_runtime=""
  local normal_key="" revoke_key="" terminal_key=""
  [[ -f "${STATE_DIR}/live-state.json" ]] || { jq -nc '{owned_only:true,artifacts_removed:true}'; return; }
  owner="$(state_get .owner_token)"
  token="$(jq -r '.auth.token // ""' "${STATE_DIR}/live-state.json")"
  session="$(jq -r '.normal.session_id // ""' "${STATE_DIR}/live-state.json")"
  runtime="$(jq -r '.normal.runtime_id // ""' "${STATE_DIR}/live-state.json")"
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
  if jq -e '.auth.user_id != null' "${STATE_DIR}/live-state.json" >/dev/null 2>&1; then
    user="$(state_get .auth.user_id)"
    username="runtime-restart-${owner:0:12}"
    portfolio="$(jq -r '.normal.portfolio_id // 0' "${STATE_DIR}/live-state.json")"
    venue="$(jq -r '.normal.venue_id // 0' "${STATE_DIR}/live-state.json")"
    strategy="$(jq -r '.normal.strategy_id // 0' "${STATE_DIR}/live-state.json")"
    normal_runtime="$(jq -r '.normal.runtime_id // ""' "${STATE_DIR}/live-state.json")"
    revoke_runtime="$(jq -r '.revoke.runtime_id // ""' "${STATE_DIR}/live-state.json")"
    terminal_runtime="$(jq -r '.terminal_grace.runtime_id // ""' "${STATE_DIR}/live-state.json")"
    normal_key="$(jq -r '.normal.credential_key_id // ""' "${STATE_DIR}/live-state.json")"
    revoke_key="$(jq -r '.revoke.credential_key_id // ""' "${STATE_DIR}/live-state.json")"
    terminal_key="$(jq -r '.terminal_grace.credential_key_id // ""' "${STATE_DIR}/live-state.json")"
    pg order -v user_id="${user}" -v session_id="${session}" -v portfolio_id="${portfolio}" \
      -v venue_id="${venue}" >/dev/null <<'SQL' || cleanup_ok=false
BEGIN;
CREATE TEMP TABLE task8_owned_intents ON COMMIT DROP AS
  SELECT intent_id FROM order_intents WHERE user_id=:'user_id'::bigint;
CREATE TEMP TABLE task8_owned_orders ON COMMIT DROP AS
  SELECT order_id FROM orders WHERE intent_id IN (SELECT intent_id FROM task8_owned_intents);
DELETE FROM spot_order_admission_leases l USING spot_close_operations o
 WHERE l.owner_session_id=o.session_id AND l.owner_operation_id=o.operation_id AND o.user_id=:'user_id'::bigint;
DELETE FROM spot_close_targets t USING spot_close_operations o
 WHERE t.session_id=o.session_id AND t.operation_id=o.operation_id AND o.user_id=:'user_id'::bigint;
DELETE FROM spot_close_operations WHERE user_id=:'user_id'::bigint;
DELETE FROM order_recovery_signals WHERE order_id IN (SELECT order_id FROM task8_owned_orders);
DELETE FROM order_fill_identities WHERE order_id IN (SELECT order_id FROM task8_owned_orders)
  OR (:'venue_id'::bigint > 0 AND venue_id=:'venue_id'::bigint);
DELETE FROM order_lifecycle_events WHERE intent_id IN (SELECT intent_id FROM task8_owned_intents)
  OR (:'session_id' <> '' AND session_id=:'session_id' AND portfolio_id=:'portfolio_id'::bigint);
DELETE FROM order_fills WHERE intent_id IN (SELECT intent_id FROM task8_owned_intents);
DELETE FROM orders WHERE intent_id IN (SELECT intent_id FROM task8_owned_intents);
DELETE FROM order_attempts WHERE intent_id IN (SELECT intent_id FROM task8_owned_intents);
DELETE FROM order_intents WHERE intent_id IN (SELECT intent_id FROM task8_owned_intents);
COMMIT;
SQL
    pg portfolio -v user_id="${user}" -v username="${username}" -v portfolio_id="${portfolio}" \
      -v venue_id="${venue}" -v strategy_id="${strategy}" -v session_id="${session}" \
      >/dev/null <<'SQL' || cleanup_ok=false
BEGIN;
CREATE TEMP TABLE task8_owned_operations ON COMMIT DROP AS
  SELECT operation_id FROM strategy_launch_operations WHERE user_id=:'user_id'::bigint;
DELETE FROM strategy_leverage_notification_outbox WHERE user_id=:'user_id'::bigint;
DELETE FROM strategy_leverage_apply_attempts WHERE operation_id IN (SELECT operation_id FROM task8_owned_operations);
DELETE FROM strategy_target_admissions WHERE operation_id IN (SELECT operation_id FROM task8_owned_operations)
  OR (:'venue_id'::bigint > 0 AND venue_id=:'venue_id'::bigint)
  OR (:'session_id' <> '' AND session_id=:'session_id');
DELETE FROM strategy_launch_operations WHERE user_id=:'user_id'::bigint;
DELETE FROM spot_session_risk_facts WHERE user_id=:'user_id'::bigint;
DELETE FROM reconciliation_runs WHERE user_id=:'user_id'::bigint;
DELETE FROM portfolio_snapshots WHERE user_id=:'user_id'::bigint;
DELETE FROM current_portfolio_snapshots WHERE user_id=:'user_id'::bigint;
DELETE FROM venue_events WHERE user_id=:'user_id'::bigint;
DELETE FROM venue_wallet_states WHERE user_id=:'user_id'::bigint;
DELETE FROM strategy_sessions WHERE user_id=:'user_id'::bigint;
DELETE FROM portfolio_strategies WHERE portfolio_id IN (SELECT portfolio_id FROM portfolios WHERE user_id=:'user_id'::bigint);
DELETE FROM venues WHERE user_id=:'user_id'::bigint;
DELETE FROM portfolios WHERE user_id=:'user_id'::bigint;
DELETE FROM strategies WHERE user_id=:'user_id'::bigint;
DELETE FROM notification_channels WHERE user_id=:'user_id'::bigint;
DELETE FROM notification_settings WHERE user_id=:'user_id'::bigint;
DELETE FROM users WHERE id=:'user_id'::bigint AND username=:'username';
COMMIT;
SQL
    pg control_panel -v user_id="${user}" -v portfolio_id="${portfolio}" -v strategy_id="${strategy}" \
      -v session_id="${session}" -v venue_id="${venue}" \
      -v normal_runtime="${normal_runtime}" -v revoke_runtime="${revoke_runtime}" -v terminal_runtime="${terminal_runtime}" \
      -v normal_key="${normal_key}" -v revoke_key="${revoke_key}" -v terminal_key="${terminal_key}" \
      >/dev/null <<'SQL' || cleanup_ok=false
BEGIN;
CREATE TEMP TABLE task8_owned_streams ON COMMIT DROP AS
  SELECT DISTINCT stream_id FROM market_data_requests WHERE user_id=:'user_id'::bigint;
DELETE FROM market_data_leases WHERE session_id=:'session_id' OR portfolio_id=:'portfolio_id'::bigint OR strategy_id=:'strategy_id'::bigint;
DELETE FROM market_data_history_requests WHERE user_id=:'user_id'::bigint;
DELETE FROM market_data_requests WHERE user_id=:'user_id'::bigint;
DELETE FROM session_market_data_subscriptions WHERE user_id=:'user_id'::bigint;
DELETE FROM market_data_streams s WHERE s.stream_id IN (SELECT stream_id FROM task8_owned_streams)
  AND NOT EXISTS (SELECT 1 FROM market_data_requests r WHERE r.stream_id=s.stream_id)
  AND NOT EXISTS (SELECT 1 FROM market_data_leases l WHERE l.stream_id=s.stream_id);
DELETE FROM runtime_commands WHERE user_id=:'user_id'::bigint;
DELETE FROM runtime_debug_datasets WHERE user_id=:'user_id'::bigint;
DELETE FROM runtime_admission_failures WHERE user_id=:'user_id'::bigint
  AND requested_runtime_id IN (:'normal_runtime',:'revoke_runtime',:'terminal_runtime');
DELETE FROM runtime_channel_leases WHERE user_id=:'user_id'::bigint
  AND runtime_id IN (:'normal_runtime',:'revoke_runtime',:'terminal_runtime')
  AND credential_key_id IN (:'normal_key',:'revoke_key',:'terminal_key');
DELETE FROM runtime_registry WHERE user_id=:'user_id'::bigint
  AND runtime_id IN (:'normal_runtime',:'revoke_runtime',:'terminal_runtime');
DELETE FROM runtime_credentials WHERE user_id=:'user_id'::bigint
  AND key_id IN (:'normal_key',:'revoke_key',:'terminal_key');
COMMIT;
SQL
  fi
  if jq -e '.market != null' "${STATE_DIR}/live-state.json" >/dev/null 2>&1; then
    source="runtime-channel-restart:${owner}"
    lower="$(printf 'RCR%sUSDT' "${owner:0:12}" | tr '[:upper:]' '[:lower:]')"
    database_created="$(state_get .market.database_created)"
    pg control_panel -v source="${source}" -v symbol="$(printf '%s' "${lower}" | tr '[:lower:]' '[:upper:]')" \
      >/dev/null <<'SQL' || cleanup_ok=false
DELETE FROM market_data_coverage_segments WHERE source=:'source' AND symbol=:'symbol';
SQL
    if database_exists binance_2025; then
      pg binance_2025 -v kline_table="futures_klines_${lower}_1m" -v funding_table="futures_funding_rates_${lower}" \
        >/dev/null <<'SQL' || cleanup_ok=false
DROP TABLE IF EXISTS :"kline_table";
DROP TABLE IF EXISTS :"funding_table";
SQL
      local owned_database_count
      owned_database_count="$(pg postgres -At -v source="${source}" <<'SQL'
SELECT count(*) FROM pg_database WHERE datname='binance_2025'
  AND COALESCE(shobj_description(oid,'pg_database'),'')=:'source';
SQL
)"
      if [[ "${database_created}" == "true" && "${owned_database_count}" == "1" ]]; then
        pg postgres -c "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname='binance_2025' AND pid <> pg_backend_pid()" >/dev/null || cleanup_ok=false
        pg postgres -c "DROP DATABASE binance_2025" >/dev/null || cleanup_ok=false
      fi
    fi
  fi
  rm -f -- "${STATE_DIR}"/credential-*.json "${STATE_DIR}"/api.*
  [[ -z "$(docker ps -aq --filter "label=hushine.acceptance.runtime-restart=${owner}")" ]] || cleanup_ok=false
  if (( user > 0 )); then
    local remaining
    remaining="$(pg portfolio -At -v user_id="${user}" <<'SQL'
SELECT count(*) FROM users WHERE id=:'user_id'::bigint;
SQL
)"
    [[ "${remaining}" == "0" ]] || cleanup_ok=false
    remaining="$(pg control_panel -At -v user_id="${user}" <<'SQL'
SELECT (SELECT count(*) FROM runtime_credentials WHERE user_id=:'user_id'::bigint)
     + (SELECT count(*) FROM runtime_registry WHERE user_id=:'user_id'::bigint)
     + (SELECT count(*) FROM runtime_admission_failures WHERE user_id=:'user_id'::bigint);
SQL
)"
    [[ "${remaining}" == "0" ]] || cleanup_ok=false
  fi
  if [[ -n "${source}" ]]; then
    [[ "$(pg control_panel -At -v source="${source}" <<'SQL'
SELECT count(*) FROM market_data_coverage_segments WHERE source=:'source';
SQL
)" == "0" ]] || cleanup_ok=false
  fi
  jq -nc --argjson ok "${cleanup_ok}" '{ownership_validated:true,owned_only:true,artifacts_removed:$ok}'
  [[ "${cleanup_ok}" == "true" ]]
}

live_action() {
  local action="$1" payload="${2:-}" runtime container key token result before after correlation
  case "${action}" in
    preflight)
      for command in curl docker jq make openssl python3 rg sed; do require_command "${command}"; done
      docker inspect "${PG_CONTAINER}" >/dev/null 2>&1 || die "local TimescaleDB container is unavailable: ${PG_CONTAINER}"
      docker inspect "${KAFKA_CONTAINER}" >/dev/null 2>&1 || die "local Kafka container is unavailable: ${KAFKA_CONTAINER}"
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
          --argjson pid "$(<"${SOURCE_ROOT}/control-panel-service/.run.pid")" \
          '{schema:2,mode:"live",owner_token:$owner,generation:$generation,
            service_baseline:{was_running:true,config:"./config.local.yaml",ready_http:200,pid:$pid},
            control_panel_stopped:false,fast_control:false}' >"${STATE_DIR}/live-state.json"
        chmod 0600 "${STATE_DIR}/live-state.json"
      fi
      start_kafka_hold_proxy
      state_update '.control_panel_stopped=true'
      control_stop
      control_start "$(control_runtime_config)"
      state_update '.control_panel_stopped=false'
      jq -nc '{ok:true}'
      ;;
    create-normal) create_normal_fixture ;;
    snapshot-before|snapshot-disconnected|snapshot-after) snapshot_normal ;;
    start-pending-platform-rpc)
      local owner barrier root hold started_file result_file observation held_file proxy_count broker_count worker_pid
      owner="$(state_get .owner_token)"; root="$(state_get .normal.runtime_root)"
      barrier="${root}/runtime-restart-barrier.json"
      correlation="rpc-${owner:0:24}"
      hold="${STATE_DIR}/kafka-proxy/hold.json"
      started_file="${root}/pending-call-started.json"; result_file="${root}/pending-call-result.json"
      rm -f -- "${started_file}" "${result_file}" "${STATE_DIR}/kafka-proxy/produce-observation.json" "${STATE_DIR}/kafka-proxy/response-held.json"
      atomic_json "${hold}" -nc --arg correlation_id "${correlation}" '{schema:1,correlation_id:$correlation_id}'
      atomic_json "${barrier}" --arg correlation_id "${correlation}" \
        '.pending_call={correlation_id:$correlation_id,started_file:"/coverage/pending-call-started.json",result_file:"/coverage/pending-call-result.json"}' "${barrier}"
      wait_for 15 "Worker pending platform call start" json_file_matches "${started_file}" ".correlation_id == \"${correlation}\" and .method == \"notification.Publish\""
      observation="${STATE_DIR}/kafka-proxy/produce-observation.json"; held_file="${STATE_DIR}/kafka-proxy/response-held.json"
      wait_for 15 "correlated Kafka Produce request" json_file_matches "${observation}" ".correlation_id == \"${correlation}\" and .produce_request_count == 1"
      wait_for 15 "correlated Kafka Produce response hold" test -s "${held_file}"
      wait_for 15 "one durable correlated notification" kafka_notification_count_is "${correlation}" 1
      proxy_count="$(jq -er .produce_request_count "${observation}")"; broker_count="$(kafka_notification_count "${correlation}")"
      worker_pid="$(jq -er .worker_pid "${started_file}")"
      state_update --arg correlation "${correlation}" '.pending_rpc={correlation_id:$correlation}'
      jq -nc --arg correlation_id "${correlation}" --argjson proxy_count "${proxy_count}" \
        --argjson broker_count "${broker_count}" --argjson worker_pid "${worker_pid}" \
        '{correlation_id:$correlation_id,caller:"python-worker",method:"notification.Publish",worker_started:true,worker_pid:$worker_pid,proxy_produce_count:$proxy_count,platform_execution_count:$broker_count}'
      ;;
    stop-control-panel)
      runtime="$(state_get .normal.runtime_id)"
      result="$(pg control_panel -At -v runtime_id="${runtime}" <<'SQL'
SELECT json_build_object(
  'lease',json_build_object('issued_at',issued_at::text,'updated_at',updated_at::text,'row_count',count(*) OVER()),
  'connection_owner',json_build_object('instance_id',r.connection_owner_instance_id,'acquired_at',r.connection_owner_acquired_at::text)
) FROM runtime_channel_leases l JOIN runtime_registry r USING(runtime_id) WHERE l.runtime_id=:'runtime_id';
SQL
)"
      jq -e '.lease.row_count == 1 and (.connection_owner.instance_id | length > 0)' <<<"${result}" >/dev/null \
        || die "pre-restart RuntimeChannel server facts are incomplete"
      state_update --argjson raw "${result}" '.normal.lease_before=$raw.lease | .normal.connection_owner_before=$raw.connection_owner'
      control_stop
      wait_for 15 "agent readiness cleared" agent_ready_is "$(state_get .normal.container_name)" 503
      jq -nc '{stopped:true,only_control_panel:true}'
      ;;
    observe-pending-platform-rpc)
      local root result_file proxy_count broker_count
      root="$(state_get .normal.runtime_root)"; correlation="$(state_get .pending_rpc.correlation_id)"
      result_file="${root}/pending-call-result.json"
      wait_for 10 "pending Worker caller completion" json_file_matches "${result_file}" ".correlation_id == \"${correlation}\" and .caller_completed == true"
      rm -f -- "${STATE_DIR}/kafka-proxy/hold.json"
      proxy_count="$(jq -er .produce_request_count "${STATE_DIR}/kafka-proxy/produce-observation.json")"
      broker_count="$(kafka_notification_count "${correlation}")"
      jq -nc --argjson result "$(<"${result_file}")" --argjson proxy_count "${proxy_count}" --argjson broker_count "${broker_count}" \
        '{correlation_id:$result.correlation_id,caller_completed:$result.caller_completed,
          caller_grpc_code:$result.caller_grpc_code,caller_elapsed_ms:$result.caller_elapsed_ms,
          caller_completion_count:$result.caller_completion_count,worker_pid:$result.worker_pid,
          proxy_produce_count:$proxy_count,platform_execution_count:$broker_count}'
      ;;
    start-control-panel)
      control_start "$(control_runtime_config)"
      state_update '.control_panel_stopped=false'
      jq -nc '{started:true}'
      ;;
    wait-resume)
      container="$(state_get .normal.container_name)"; runtime="$(state_get .normal.runtime_id)"
      wait_for 30 "normal runtime RESUME readiness" agent_ready_is "${container}" 200
      wait_for 30 "normal runtime active after RESUME" runtime_status_is "${runtime}" active
      before="$(state_get .normal.lease_before)"
      result="$(pg control_panel -At -v runtime_id="${runtime}" <<'SQL'
SELECT json_build_object(
  'credential',json_build_object('status',c.status,'consumed_runtime_id',COALESCE(c.consumed_runtime_id,'')),
  'lease_after',json_build_object('issued_at',l.issued_at::text,'updated_at',l.updated_at::text,'row_count',(SELECT count(*) FROM runtime_channel_leases WHERE runtime_id=:'runtime_id')),
  'connection_owner_after',json_build_object('instance_id',r.connection_owner_instance_id,'acquired_at',r.connection_owner_acquired_at::text),
  'runtime_status',r.status,
  'admission_failures',(SELECT count(*) FROM runtime_admission_failures WHERE requested_runtime_id=:'runtime_id')
) FROM runtime_registry r JOIN runtime_credentials c ON c.key_id=r.credential_key_id
JOIN runtime_channel_leases l USING(runtime_id) WHERE r.runtime_id=:'runtime_id';
SQL
)"
      jq -nc --arg observed_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        --argjson before "${before}" --argjson owner_before "$(state_get .normal.connection_owner_before)" \
        --argjson raw "${result}" \
        '{observed_at:$observed_at,agent_ready_http:200,runtime_status:$raw.runtime_status,
          credential:$raw.credential,lease_before:$before,lease_after:$raw.lease_after,
          connection_owner_before:$owner_before,connection_owner_after:$raw.connection_owner_after,
          admission_failures:$raw.admission_failures}'
      ;;
    observe-pending-after-resume)
      correlation="$(state_get .pending_rpc.correlation_id)"
      kafka_notification_count_stays_one "${correlation}" \
        || die "pending platform call was replayed after RESUME"
      jq -nc --arg correlation_id "${correlation}" \
        --argjson platform_execution_count "$(kafka_notification_count "${correlation}")" \
        --argjson caller_completion_count "$(jq -er .caller_completion_count "$(state_get .normal.runtime_root)/pending-call-result.json")" \
        '{correlation_id:$correlation_id,platform_execution_count:$platform_execution_count,caller_completion_count:$caller_completion_count}'
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
      state_update '.control_panel_stopped=true'
      control_stop
      local fast_config; fast_config="$(make_fast_control_config)"
      state_update '.fast_control=true'
      control_start "${fast_config}"
      state_update '.control_panel_stopped=false'
      wait_for 20 "runtime terminalized after grace" runtime_status_is "${runtime}" heartbeat_stale
      result="$(pg control_panel -At -v runtime_id="${runtime}" <<'SQL'
SELECT ended_at::text FROM runtime_registry WHERE runtime_id=:'runtime_id' AND status='heartbeat_stale';
SQL
)"
      [[ -n "${result}" ]] || die "terminal grace timestamp was not persisted"
      state_update --arg terminalized_at "${result}" '.terminal_grace.terminalized_at=$terminalized_at'
      docker unpause "${container}" >/dev/null
      jq -nc --arg terminalized_at "${result}" '{terminalized:true,grace_seconds:3,terminalized_at:$terminalized_at}'
      ;;
    assert-terminal-resume-rejected)
      container="$(state_get .terminal_grace.container_name)"; runtime="$(state_get .terminal_grace.runtime_id)"
      wait_for_terminal_exit 30 "terminal RESUME rejection safe stop" terminal_grace
      local failure exit_code attempts terminalized_at rows
      terminalized_at="$(state_get .terminal_grace.terminalized_at)"
      failure="$(pg control_panel -At -v runtime_id="${runtime}" -v terminalized_at="${terminalized_at}" <<'SQL'
SELECT json_build_object(
  'attempts',COALESCE(sum(attempt_count),0),
  'rows',COALESCE(json_agg(json_build_object('failure_code',failure_code,'attempt_count',attempt_count,'last_seen_at',last_seen_at::text) ORDER BY last_seen_at) FILTER (WHERE failure_code IS NOT NULL),'[]'::json)
) FROM runtime_admission_failures WHERE requested_runtime_id=:'runtime_id' AND last_seen_at >= :'terminalized_at'::timestamptz;
SQL
)"
      attempts="$(jq -er .attempts <<<"${failure}")"; rows="$(jq -c .rows <<<"${failure}")"
      jq -e 'length > 0 and all(.[]; .failure_code == "failed_precondition")' <<<"${rows}" >/dev/null \
        || die "terminal RESUME rejection did not consist only of failed_precondition rows"
      (( attempts <= 1 )) || die "terminal RESUME rejection caused reconnect storm: ${attempts} attempts"
      exit_code="$(docker inspect -f '{{.State.ExitCode}}' "${container}")"
      jq -nc --argjson attempts "${attempts}" --argjson exit "${exit_code}" --argjson rows "${rows}" '{resume_rejected:true,grpc_code:"FailedPrecondition",safe_stop:true,reconnect_storm:false,reconnect_attempts:$attempts,agent_exit_code:$exit,matching_failure_rows:$rows}'
      ;;
    restore-control-panel) restore_control_panel_baseline ;;
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

derive_pending_evidence() {
  local started="$1" failed="$2" after_resume="$3"
  jq -e --argjson failed "${failed}" --argjson after "${after_resume}" '
    .caller == "python-worker" and .method == "notification.Publish"
    and .worker_started == true and .platform_execution_count == 1
    and .proxy_produce_count == 1 and .worker_pid > 1
    and (.correlation_id | type == "string" and length > 0)
    and $failed.correlation_id == .correlation_id
    and $failed.caller_completed == true and $failed.caller_grpc_code == "Unavailable"
    and $failed.caller_elapsed_ms > 0 and $failed.caller_elapsed_ms <= 2000
    and $failed.platform_execution_count == 1
    and $failed.proxy_produce_count == 1 and $failed.caller_completion_count == 1
    and $failed.worker_pid == .worker_pid
    and $after.correlation_id == .correlation_id
    and $after.platform_execution_count == 1 and $after.caller_completion_count == 1
  ' <<<"${started}" >/dev/null || die "raw pending RuntimeChannel call observations are inconsistent or replayed"
  jq -nc --argjson started "${started}" --argjson failed "${failed}" --argjson after "${after_resume}" '{
    status:"failed",grpc_code:$failed.caller_grpc_code,elapsed_ms:$failed.caller_elapsed_ms,
    replay_count:($after.platform_execution_count - 1),correlation_id:$started.correlation_id,
    platform_execution_count:$after.platform_execution_count,observation_source:"worker+kafka"
  }'
}

derive_resume_evidence() {
  local raw="$1" runtime_id="$2"
  jq -e --arg runtime "${runtime_id}" '
    .agent_ready_http == 200 and .runtime_status == "active"
    and .credential.status == "consumed" and .credential.consumed_runtime_id == $runtime
    and .lease_before.row_count == 1 and .lease_after.row_count == 1
    and .lease_before.issued_at == .lease_after.issued_at
    and .lease_after.updated_at > .lease_before.updated_at
    and .connection_owner_before.instance_id != .connection_owner_after.instance_id
    and (.connection_owner_after.instance_id | length > 0)
    and .connection_owner_after.acquired_at > .connection_owner_before.acquired_at
    and .admission_failures == 0
  ' <<<"${raw}" >/dev/null || die "raw server facts do not prove a single-lease RESUME"
  jq -nc --argjson raw "${raw}" '{
    resumed:true,first_frame:"RESUME",agent_ready_http:$raw.agent_ready_http,
    resume_observed_at:$raw.observed_at,
    proof:{credential_status:$raw.credential.status,consumed_runtime_id:$raw.credential.consumed_runtime_id,
      lease_row_count:$raw.lease_after.row_count,same_lease_issued_at:true,
      lease_before:$raw.lease_before,lease_after:$raw.lease_after,
      connection_owner_before:$raw.connection_owner_before,connection_owner_after:$raw.connection_owner_after,
      admission_failures:$raw.admission_failures}
  }'
}

derive_funding_evidence() {
  local before="$1" after="$2"
  python3 - "${before}" "${after}" <<'PY'
import json
import sys
from decimal import Decimal

before = json.loads(sys.argv[1])
after = json.loads(sys.argv[2])
income = after.get("income") or {}
expected = Decimal(str(income.get("applied_amount", "NaN")))
fields = ("wallet_balance", "available_balance", "total_value")
deltas = {
    field: Decimal(str(after["wallet"][field])) - Decimal(str(before["wallet"][field]))
    for field in fields
}
valid = (
    before.get("wallet_effect_count") == 0
    and before.get("income_cursor") == before["wallet"].get("last_applied_income_entry_id")
    and after.get("income_cursor", 0) > before.get("income_cursor", 0)
    and after.get("wallet_effect_count") == 1
    and int(income.get("income_entry_id", 0)) > 0
    and after.get("income_cursor") == income.get("income_entry_id")
    and after["wallet"].get("last_applied_income_entry_id") == income.get("income_entry_id")
    and all(delta == expected for delta in deltas.values())
)
if not valid:
    raise SystemExit("wallet fields do not equal one exact Income application")
print(json.dumps({
    "income_entry_id": income["income_entry_id"],
    "asset": income.get("asset", ""),
    "expected_wallet_delta": format(expected, "f"),
    "actual_wallet_delta": format(deltas["wallet_balance"], "f"),
    "actual_available_delta": format(deltas["available_balance"], "f"),
    "actual_total_value_delta": format(deltas["total_value"], "f"),
    "cursor_before": before["wallet"]["last_applied_income_entry_id"],
    "cursor_after": after["wallet"]["last_applied_income_entry_id"],
    "application_count": after["wallet_effect_count"],
}, separators=(",", ":"), sort_keys=True))
PY
}

cleanup_once() {
  local restored
  [[ "${CLEANED_UP}" == "false" ]] || return 0
  CLEANED_UP=true
  validate_cleanup_manifest
  validate_cleanup_ownership
  restored="$(run_action restore-control-panel)" || die "control-panel baseline restoration failed"
  jq -e '.baseline_restored == true' <<<"${restored}" >/dev/null \
    || die "control-panel baseline restoration evidence is invalid"
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

capture_action pending_started start-pending-platform-rpc "${normal_fixture}"
require_json pending-started '
  .worker_started == true and .caller == "python-worker"
  and .method == "notification.Publish" and .platform_execution_count == 1
  and (.correlation_id | type == "string" and length > 0)
' "${pending_started}"

state_update '.control_panel_stopped=true'
capture_action stopped stop-control-panel "${normal_fixture}"
require_json stop-control-panel '.stopped == true and .only_control_panel == true' "${stopped}"

capture_action disconnected snapshot-disconnected "${normal_fixture}"
require_json disconnected '
  .session_status == "running"
  and .agent_health_http == 200 and .agent_ready_http == 503
' "${disconnected}"
same_identity "${before}" "${disconnected}" \
  || die "runtime/Agent/Worker identity changed while control-panel was stopped"

capture_action pending_failed observe-pending-platform-rpc "${normal_fixture}"
require_json pending-failed '
  .caller_completed == true and .caller_grpc_code == "Unavailable"
  and .caller_elapsed_ms > 0 and .caller_elapsed_ms <= 2000
  and .platform_execution_count == 1
' "${pending_failed}"

capture_action started start-control-panel "${normal_fixture}"
require_json start-control-panel '.started == true' "${started}"
state_update '.control_panel_stopped=false'
capture_action resume_raw wait-resume "${normal_fixture}"
resume="$(derive_resume_evidence "${resume_raw}" "$(jq -er .runtime_id <<<"${normal_fixture}")")"
capture_action pending_after_resume observe-pending-after-resume "${normal_fixture}"
pending="$(derive_pending_evidence "${pending_started}" "${pending_failed}" "${pending_after_resume}")"

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
funding_exactly_once="$(derive_funding_evidence "${before}" "${after}")" \
  || die "Funding wallet was not updated by exactly one Income fact"

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
state_update '.control_panel_stopped=true | .fast_control=true'
capture_action grace exceed-terminal-grace "${grace_fixture}"
require_json terminal-grace '.terminalized == true and .grace_seconds > 0' "${grace}"
state_update '.control_panel_stopped=false'
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
  --argjson funding "${funding_exactly_once}" \
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
      after:$after,
      funding_exactly_once:$funding
    },
    negative:{credential_revoke:$revoke,terminal_grace:$grace},
    cleanup:$cleanup
  }' >"${EVIDENCE_FILE}"
chmod 0600 "${EVIDENCE_FILE}"

trap - EXIT INT TERM
echo "runtime-channel restart acceptance: PASS"
echo "evidence_file=${EVIDENCE_FILE}"
