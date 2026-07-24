#!/usr/bin/env bash
set -euo pipefail

# The fixture is always loopback; do not let a developer-machine proxy intercept it.
export NO_PROXY="127.0.0.1,localhost"
export no_proxy="${NO_PROXY}"

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)"
OBSERVER="${ROOT}/scripts/acceptance/observe_spot_demo.py"
FAKE_SERVER="${ROOT}/scripts/fixtures/spot_demo_fake_server.py"
SCHEMA="${ROOT}/scripts/fixtures/spot_demo_evidence.schema.json"

fail() {
  echo "Spot Demo observer contract failed: $*" >&2
  exit 1
}

test -x "${OBSERVER}" || fail "observer is missing or not executable"
test -x "${FAKE_SERVER}" || fail "fake exchange is missing or not executable"
test -f "${SCHEMA}" || fail "evidence schema is missing"
python3 -m py_compile "${OBSERVER}" "${FAKE_SERVER}"
grep -Fq '"https://demo-api.binance.com"' "${OBSERVER}" || fail "default REST endpoint is not Binance Demo Mode"
grep -Fq '"wss://demo-ws-api.binance.com/ws-api/v3"' "${OBSERVER}" || fail "default WebSocket endpoint is not Binance Demo Mode"
if grep -Fq '"wss://ws-api.testnet.binance.vision/ws-api/v3"' "${OBSERVER}"; then
  fail "Spot Testnet WebSocket cannot be paired with a Demo Mode REST key"
fi

tmp="$(mktemp -d)"
tmp="$(cd -- "${tmp}" && pwd -P)"
server_pid=''
cleanup() {
  if [[ -n "${server_pid}" ]]; then
    kill "${server_pid}" 2>/dev/null || true
    wait "${server_pid}" 2>/dev/null || true
  fi
  rm -rf -- "${tmp}"
}
trap cleanup EXIT INT TERM

start_server() {
  local scenario="$1"
  state_file="${tmp}/server-${scenario}.json"
  rm -f -- "${state_file}"
  python3 "${FAKE_SERVER}" --port 0 --scenario "${scenario}" --state-file "${state_file}" \
    >"${tmp}/server-${scenario}.out" 2>"${tmp}/server-${scenario}.err" &
  server_pid=$!
  for _ in $(seq 1 100); do
    [[ -s "${state_file}" ]] && break
    kill -0 "${server_pid}" 2>/dev/null || fail "fake exchange exited before ready"
    sleep 0.05
  done
  [[ -s "${state_file}" ]] || fail "fake exchange did not publish readiness"
  port="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["port"])' "${state_file}")"
}

stop_server() {
  kill "${server_pid}" 2>/dev/null || true
  wait "${server_pid}" 2>/dev/null || true
  server_pid=''
}

make_root() {
  local path="$1"
  mkdir -m 0700 "${path}"
}

run_observer() {
  local coverage_root="$1" run_id="$2" handoff_run_id="$3" timeout="${4:-5}"
  printf '{"run_id":"%s","session_id":"session-spot-1"}\n' "${handoff_run_id}" \
    | HUSHINE_SPOT_DEMO_HTTP_BASE="http://127.0.0.1:${port}" \
      HUSHINE_SPOT_DEMO_WS_URL="ws://127.0.0.1:${port}/ws-api/v3" \
      python3 "${OBSERVER}" \
        --run-id "${run_id}" --user-id 7 --portfolio-id 11 --venue-id 13 \
        --coverage-root "${coverage_root}" --credential-fd 3 --timeout-seconds "${timeout}" \
        3< <(printf '%s\n' '{"api_key":"demo-key","api_secret":"demo-secret"}')
}

start_server success
coverage_root="${tmp}/coverage-success"
make_root "${coverage_root}"
run_observer "${coverage_root}" run-success run-success
evidence="${coverage_root}/exchange-evidence.json"
[[ -f "${evidence}" && ! -L "${evidence}" ]] || fail "complete evidence was not published"
[[ ! -e "${coverage_root}/exchange-evidence.json.tmp" ]] || fail "temporary evidence remains"
[[ "$(stat -f '%Lp' "${evidence}")" == "600" ]] || fail "evidence mode is not 0600"

python3 - "${evidence}" "${SCHEMA}" <<'PY'
import hashlib
import json
import re
import sys

evidence_path, schema_path = sys.argv[1:]
with open(evidence_path, encoding="utf-8") as handle:
    value = json.load(handle)
with open(schema_path, encoding="utf-8") as handle:
    schema = json.load(handle)
required = set(schema["required"])
assert required <= set(value)
assert value["complete"] is True
assert value["run_id"] == "run-success"
assert value["session_id"] == "session-spot-1"
assert value["subscription"]["status"] == "acknowledged"
assert len(value["orders"]) >= 1 and len(value["trades"]) >= 1
assert {item["symbol"] for item in value["orders"]} == {"BTCUSDT", "ETHUSDT"}
assert {item["symbol"] for item in value["trades"]} == {"BTCUSDT", "ETHUSDT"}
assert all(isinstance(item[key], str) for item in value["orders"] for key in ("origQty", "executedQty", "cummulativeQuoteQty"))
assert all(isinstance(item[key], str) for item in value["trades"] for key in ("qty", "price", "quoteQty", "commission", "commissionAsset"))
expected_hash = value.pop("canonical_payload_sha256")
canonical = json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode()
assert hashlib.sha256(canonical).hexdigest() == expected_hash
assert re.fullmatch(r"[0-9a-f]{64}", expected_hash)
lowered = json.dumps(value).lower()
for forbidden in ("demo-key", "demo-secret", "api_key", "api_secret", "signature", "x-mbx-apikey", "?"):
    assert forbidden not in lowered
paths = {item["path"] for item in value["requested_endpoints"]}
for required_path in ("/api/v3/account", "/api/v3/exchangeInfo", "/api/v3/myFilters", "/api/v3/avgPrice", "/api/v3/allOrders", "/api/v3/myTrades", "/ws-api/v3"):
    assert required_path in paths
assert "/api/v3/userDataStream" not in paths
PY

python3 "${OBSERVER}" \
  --validate-evidence "${evidence}" --session-id session-spot-1 \
  --run-id run-success --user-id 7 --portfolio-id 11 --venue-id 13 \
  --coverage-root "${coverage_root}" >"${tmp}/validate-success.out"
grep -Fxq 'evidence_valid=true' "${tmp}/validate-success.out" \
  || fail "validator did not acknowledge complete evidence"

cp "${evidence}" "${tmp}/evidence-backup.json"
python3 - "${evidence}" <<'PY'
import json, sys
path = sys.argv[1]
value = json.load(open(path))
value["orders"][0]["executedQty"] = "9.99900000"
with open(path, "w") as handle:
    json.dump(value, handle)
PY
chmod 0600 "${evidence}"
set +e
python3 "${OBSERVER}" \
  --validate-evidence "${evidence}" --session-id session-spot-1 \
  --run-id run-success --user-id 7 --portfolio-id 11 --venue-id 13 \
  --coverage-root "${coverage_root}" >"${tmp}/validate-hash.out" 2>"${tmp}/validate-hash.err"
status=$?
set -e
[[ "${status}" -ne 0 ]] || fail "validator accepted a mismatched canonical hash"
mv "${tmp}/evidence-backup.json" "${evidence}"
chmod 0600 "${evidence}"

cp "${evidence}" "${tmp}/tampered-evidence.json"
python3 - "${tmp}/tampered-evidence.json" <<'PY'
import json, sys
path = sys.argv[1]
value = json.load(open(path))
value["orders"][0]["executedQty"] = "9.99900000"
with open(path, "w") as handle:
    json.dump(value, handle)
PY
chmod 0600 "${tmp}/tampered-evidence.json"
set +e
python3 "${OBSERVER}" \
  --validate-evidence "${tmp}/tampered-evidence.json" --session-id session-spot-1 \
  --run-id run-success --user-id 7 --portfolio-id 11 --venue-id 13 \
  --coverage-root "${coverage_root}" >"${tmp}/validate-tampered.out" 2>"${tmp}/validate-tampered.err"
status=$?
set -e
[[ "${status}" -ne 0 ]] || fail "validator accepted evidence outside the coverage root"

python3 - "${state_file}" <<'PY'
import json, sys
state = json.load(open(sys.argv[1]))
assert state["subscription_method"] == "userDataStream.subscribe.signature"
assert state["credential_header_seen"] is True
paths = [item["path"] for item in state["requests"]]
assert paths.count("/api/v3/myFilters") == 2
assert paths.count("/api/v3/avgPrice") == 2
PY
stop_server

# Unsafe coverage roots and credential environment variables fail before network I/O.
unsafe_real="${tmp}/unsafe-real"
make_root "${unsafe_real}"
chmod 0755 "${unsafe_real}"
unsafe_link_target="${tmp}/unsafe-link-target"
make_root "${unsafe_link_target}"
ln -s "${unsafe_link_target}" "${tmp}/unsafe-link"
for case_name in wrong-mode symlink-root credential-env; do
  credential_env=''
  case "${case_name}" in
    wrong-mode) unsafe_root="${unsafe_real}" ;;
    symlink-root) unsafe_root="${tmp}/unsafe-link" ;;
    credential-env) unsafe_root="${tmp}/unsafe-credential"; make_root "${unsafe_root}"; credential_env='forbidden' ;;
  esac
  set +e
  printf '%s\n' '{"run_id":"unsafe-run","session_id":"unsafe-session"}' \
    | BINANCE_API_KEY="${credential_env}" \
      HUSHINE_SPOT_DEMO_HTTP_BASE="http://127.0.0.1:${port}" \
      HUSHINE_SPOT_DEMO_WS_URL="ws://127.0.0.1:${port}/ws-api/v3" \
      python3 "${OBSERVER}" --run-id unsafe-run --user-id 7 --portfolio-id 11 --venue-id 13 \
        --coverage-root "${unsafe_root}" --credential-fd 3 --timeout-seconds 1 \
        3< <(printf '%s\n' '{"api_key":"demo-key","api_secret":"demo-secret"}') \
        >"${tmp}/${case_name}.out" 2>"${tmp}/${case_name}.err"
  status=$?
  set -e
  [[ "${status}" -ne 0 ]] || fail "${case_name} was accepted"
  [[ ! -e "${unsafe_root}/exchange-evidence.json" && ! -e "${unsafe_root}/exchange-evidence.json.tmp" ]] \
    || fail "${case_name} left evidence"
  if [[ "${case_name}" == "credential-env" ]]; then
    chmod 0700 "${unsafe_root}"
  fi
done

# A mismatched or missing public Session handoff must fail without publishing.
start_server success
for case_name in mismatch missing; do
  root="${tmp}/coverage-${case_name}"
  make_root "${root}"
  set +e
  if [[ "${case_name}" == "mismatch" ]]; then
    run_observer "${root}" expected-run wrong-run >"${tmp}/${case_name}.out" 2>"${tmp}/${case_name}.err"
  else
    HUSHINE_SPOT_DEMO_HTTP_BASE="http://127.0.0.1:${port}" \
    HUSHINE_SPOT_DEMO_WS_URL="ws://127.0.0.1:${port}/ws-api/v3" \
      python3 "${OBSERVER}" --run-id expected-run --user-id 7 --portfolio-id 11 --venue-id 13 \
        --coverage-root "${root}" --credential-fd 3 --timeout-seconds 1 \
        3< <(printf '%s\n' '{"api_key":"demo-key","api_secret":"demo-secret"}') \
        </dev/null >"${tmp}/${case_name}.out" 2>"${tmp}/${case_name}.err"
  fi
  status=$?
  set -e
  [[ "${status}" -ne 0 ]] || fail "${case_name} handoff was accepted"
  [[ ! -e "${root}/exchange-evidence.json" && ! -e "${root}/exchange-evidence.json.tmp" ]] \
    || fail "${case_name} handoff left evidence"
done
stop_server

# A second byte after the newline is rejected immediately, while the complete
# smoke contract separately proves the observer does not require pipe EOF.
start_server success
root="${tmp}/coverage-extra-handoff"
make_root "${root}"
set +e
printf '%s\n%s\n' \
  '{"run_id":"extra-run","session_id":"session-spot-1"}' \
  '{"run_id":"extra-run","session_id":"session-spot-2"}' \
  | HUSHINE_SPOT_DEMO_HTTP_BASE="http://127.0.0.1:${port}" \
    HUSHINE_SPOT_DEMO_WS_URL="ws://127.0.0.1:${port}/ws-api/v3" \
    python3 "${OBSERVER}" \
      --run-id extra-run --user-id 7 --portfolio-id 11 --venue-id 13 \
      --coverage-root "${root}" --credential-fd 3 --timeout-seconds 1 \
      3< <(printf '%s\n' '{"api_key":"demo-key","api_secret":"demo-secret"}') \
      >"${tmp}/extra-handoff.out" 2>"${tmp}/extra-handoff.err"
status=$?
set -e
[[ "${status}" -ne 0 ]] || fail "multiple Session handoff lines were accepted"
grep -Fq 'Session handoff must contain exactly one line' "${tmp}/extra-handoff.err" \
  || fail "multiple-line Session handoff rejection was not explicit"
[[ ! -e "${root}/exchange-evidence.json" && ! -e "${root}/exchange-evidence.json.tmp" ]] \
  || fail "multiple-line Session handoff left evidence"
stop_server

# Official-shape failures propagate and never publish incomplete evidence.
for scenario in subscription 429 5xx schema permission timeout; do
  start_server "${scenario}"
  root="${tmp}/coverage-${scenario}"
  make_root "${root}"
  set +e
  run_observer "${root}" "run-${scenario}" "run-${scenario}" 1 >"${tmp}/${scenario}.out" 2>"${tmp}/${scenario}.err"
  status=$?
  set -e
  [[ "${status}" -ne 0 ]] || fail "scenario ${scenario} unexpectedly passed"
  [[ ! -e "${root}/exchange-evidence.json" && ! -e "${root}/exchange-evidence.json.tmp" ]] \
    || fail "scenario ${scenario} published incomplete evidence"
  stop_server
done

# Signal cleanup removes the O_EXCL temporary artifact while waiting for Session.
start_server success
signal_root="${tmp}/coverage-signal"
make_root "${signal_root}"
HUSHINE_SPOT_DEMO_HTTP_BASE="http://127.0.0.1:${port}" \
HUSHINE_SPOT_DEMO_WS_URL="ws://127.0.0.1:${port}/ws-api/v3" \
  python3 "${OBSERVER}" --run-id signal-run --user-id 7 --portfolio-id 11 --venue-id 13 \
    --coverage-root "${signal_root}" --credential-fd 3 --timeout-seconds 30 \
    3< <(printf '%s\n' '{"api_key":"demo-key","api_secret":"demo-secret"}') \
    < <(sleep 30) >"${tmp}/signal.out" 2>"${tmp}/signal.err" &
observer_pid=$!
for _ in $(seq 1 100); do
  [[ -e "${signal_root}/exchange-evidence.json.tmp" ]] && break
  sleep 0.02
done
[[ -e "${signal_root}/exchange-evidence.json.tmp" ]] || fail "observer did not reserve temporary artifact"
if lsof -a -p "${observer_pid}" -d 3 -Fn 2>/dev/null | grep -q '^f3$'; then
  fail "credential FD remained open while waiting for Session"
fi
python3 - "${state_file}" <<'PY'
import json, sys
assert json.load(open(sys.argv[1]))["requests"] == []
PY
kill -TERM "${observer_pid}"
set +e
wait "${observer_pid}"
status=$?
set -e
[[ "${status}" -ne 0 ]] || fail "signal termination returned success"
[[ ! -e "${signal_root}/exchange-evidence.json.tmp" && ! -e "${signal_root}/exchange-evidence.json" ]] \
  || fail "signal cleanup left observer artifacts"
stop_server

echo "Spot Demo observer contracts passed"
