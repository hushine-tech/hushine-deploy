#!/usr/bin/env bash
set -euo pipefail

DEPLOY_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
SOURCE_ROOT="${HUSHINE_SOURCE_ROOT:-$(cd "${DEPLOY_ROOT}/.." && pwd -P)}"
PROXY="${DEPLOY_ROOT}/scripts/runtime-channel-kafka-hold-proxy.py"
HELPER="${DEPLOY_ROOT}/scripts/runtime-channel-kafka-proxy-integration.go"
KAFKA_CONTAINER="${HUSHINE_RUNTIME_RESTART_KAFKA_CONTAINER:-hushine-local-kafka-1}"
STATE="$(mktemp -d "${TMPDIR:-/tmp}/runtime-channel-kafka-proxy-integration.XXXXXX")"
proxy_pid=0
producer_pid=0

cleanup() {
  local rc="$?"
  trap - EXIT INT TERM
  rm -f -- "${STATE}/hold.json"
  for pid in "${producer_pid}" "${proxy_pid}"; do
    if [[ "${pid}" =~ ^[1-9][0-9]*$ ]] && kill -0 "${pid}" 2>/dev/null; then
      kill "${pid}" 2>/dev/null || true
      wait "${pid}" 2>/dev/null || true
    fi
  done
  rm -rf -- "${STATE}"
  exit "${rc}"
}
trap cleanup EXIT INT TERM

fail() {
  echo "runtime-channel Kafka proxy integration: $*" >&2
  exit 1
}

wait_file() {
  local timeout="$1" path="$2" deadline
  deadline=$((SECONDS + timeout))
  until [[ -s "${path}" ]]; do
    (( SECONDS < deadline )) || fail "timed out waiting for ${path}"
    sleep 0.1
  done
}

count_correlation() {
  local correlation="$1" output
  output="$(docker exec "${KAFKA_CONTAINER}" kafka-console-consumer \
    --bootstrap-server 127.0.0.1:9092 --topic notification.events \
    --from-beginning --timeout-ms 1500 2>/dev/null || true)"
  awk -v needle="${correlation}" 'index($0, needle) { count++ } END { print count + 0 }' <<<"${output}"
}

[[ -f "${HELPER}" ]] || fail "missing committed Sarama helper: ${HELPER}"
docker inspect "${KAFKA_CONTAINER}" >/dev/null 2>&1 || fail "Kafka container is unavailable"
chmod 0700 "${STATE}"
python3 "${PROXY}" --target-port 9092 --control-dir "${STATE}" \
  >"${STATE}/proxy.log" 2>&1 &
proxy_pid=$!
wait_file 10 "${STATE}/endpoint.json"
port="$(jq -er '.port' "${STATE}/endpoint.json")"
correlation="rpc-proxy-integration-$(openssl rand -hex 12)"
jq -nc --arg correlation_id "${correlation}" \
  '{schema:1,correlation_id:$correlation_id}' >"${STATE}/hold.json"
chmod 0600 "${STATE}/hold.json"

(cd "${SOURCE_ROOT}/control-panel-service" && go run "${HELPER}" \
  --broker "127.0.0.1:${port}" --topic notification.events --correlation "${correlation}") \
  >"${STATE}/producer.out" 2>"${STATE}/producer.err" &
producer_pid=$!
wait_file 30 "${STATE}/metadata-observation.json"
wait_file 30 "${STATE}/produce-observation.json"
wait_file 30 "${STATE}/response-held.json"
jq -e --arg endpoint "127.0.0.1:${port}" \
  '.api_key == 3 and .api_version == 7 and .advertised_endpoint == $endpoint' \
  "${STATE}/metadata-observation.json" >/dev/null \
  || fail "Sarama Metadata was not rewritten to the proxy"
jq -e --arg correlation "${correlation}" \
  '.correlation_id == $correlation and .produce_request_count == 1' \
  "${STATE}/produce-observation.json" >/dev/null \
  || fail "proxy did not observe exactly one correlated Produce"
[[ "$(count_correlation "${correlation}")" == "1" ]] \
  || fail "broker did not durably receive exactly one correlation"
kill -0 "${producer_pid}" 2>/dev/null \
  || fail "Sarama producer completed before held Produce response release"

rm -f -- "${STATE}/hold.json"
deadline=$((SECONDS + 15))
while kill -0 "${producer_pid}" 2>/dev/null; do
  (( SECONDS < deadline )) || fail "Sarama producer did not complete after release"
  sleep 0.1
done
wait "${producer_pid}" || fail "Sarama producer failed: $(tr '\n' ' ' <"${STATE}/producer.err")"
producer_pid=0
grep -Fq "sarama_proxy_publish=PASS correlation=${correlation}" "${STATE}/producer.out" \
  || fail "Sarama helper did not report its correlated publish"
[[ "$(count_correlation "${correlation}")" == "1" ]] \
  || fail "correlation was published more than once after release"

echo "runtime-channel Kafka proxy integration: PASS"
