#!/usr/bin/env bash
set -euo pipefail

DEPLOY_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
SOURCE_ROOT="$(cd -- "${DEPLOY_ROOT}/.." && pwd -P)"
GENERATOR="${DEPLOY_ROOT}/scripts/prepare-local-configs.py"

[[ -x "${GENERATOR}" ]] || {
  echo "missing executable local config generator" >&2
  exit 1
}
grep -Fq 'local-bootstrap: local-configs local-infra-up' "${DEPLOY_ROOT}/Makefile"
grep -Fq 'RUNTIME_COVERAGE_ENABLED=true' "${DEPLOY_ROOT}/Makefile"
grep -Fq 'RUNTIME_COVERAGE_OUTPUT_DIR=' "${DEPLOY_ROOT}/Makefile"
grep -Fq 'RUNTIME_COVERAGE_IMAGE=' "${DEPLOY_ROOT}/Makefile"
grep -Fq 'build_strategy_runtime.sh --all "$${IMAGE_TAG:-dev}"' \
  "${DEPLOY_ROOT}/Makefile"
grep -Fq 'generate_runtime_channel_dev_certs.sh' "${DEPLOY_ROOT}/Makefile"
grep -Fq 'COMPOSE_FILE="${ROOT_DIR}/deploy/local/docker-compose.yml"' \
  "${DEPLOY_ROOT}/scripts/wait-for-postgres.sh"
grep -Fq 'docker compose -f "$COMPOSE_FILE" exec -T timescaledb' \
  "${DEPLOY_ROOT}/scripts/wait-for-postgres.sh"

make -C "${SOURCE_ROOT}" -f "${DEPLOY_ROOT}/Makefile" local-configs \
  LOCAL_RUNTIME_COVERAGE_IMAGE=hushine/strategy-runtime:test-coverage \
  >/dev/null

for cert in \
  runtime-channel-server.key \
  runtime-channel-server.pem \
  runtime-channel-ca.pem \
  runtime-client-ca.key \
  runtime-client-ca.pem; do
  [[ -s "${DEPLOY_ROOT}/certs/${cert}" ]] || {
    echo "missing generated local RuntimeChannel certificate: ${cert}" >&2
    exit 1
  }
done
for key in runtime-channel-server.key runtime-client-ca.key; do
  [[ "$(stat -f '%Lp' "${DEPLOY_ROOT}/certs/${key}")" == "600" ]] || {
    echo "unsafe permissions on local RuntimeChannel key: ${key}" >&2
    exit 1
  }
done

fixture="$(mktemp -d "${TMPDIR:-/tmp}/hushine-local-configs.XXXXXX")"
cleanup() {
  rm -rf -- "${fixture}"
}
trap cleanup EXIT HUP INT TERM

for path in \
  core-service/config.yaml \
  control-panel-service/config.yaml \
  gateway/quant-handler/config.yaml \
  scraper/config.yaml \
  scraper/log-config.json; do
  mkdir -p "${fixture}/$(dirname -- "${path}")"
  cp "${SOURCE_ROOT}/${path}" "${fixture}/${path}"
done

HUSHINE_SOURCE_ROOT="${fixture}" \
HUSHINE_LOCAL_CERT_DIR="${fixture}/local-certs" \
  "${GENERATOR}"

generated=(
  core-service/config.local.yaml
  control-panel-service/config.local.yaml
  gateway/quant-handler/config.local.yaml
  scraper/config.local.yaml
  scraper/log-config.local.json
)
for path in "${generated[@]}"; do
  [[ -f "${fixture}/${path}" ]] || {
    echo "missing generated ${path}" >&2
    exit 1
  }
  [[ "$(stat -f '%Lp' "${fixture}/${path}")" == "600" ]] || {
    echo "unsafe permissions on ${path}" >&2
    exit 1
  }
done

if grep -ERn '192\.168\.88\.10|:19092' \
  "${generated[@]/#/${fixture}/}"; then
  echo "generated local config still references shared infrastructure" >&2
  exit 1
fi

python3 - "${fixture}" <<'PY'
import json
from pathlib import Path
import re
import sys

root = Path(sys.argv[1])
control = (root / "control-panel-service/config.local.yaml").read_text()
match = re.search(
    r"(?ms)^runtime_channel_server:\n.*?^  tls:\n"
    r"    enabled: (true|false)\n"
    r'    cert_file: "([^"]+)"\n'
    r'    key_file: "([^"]+)"\n'
    r'    server_name: "runtime-channel\.local"\n'
    r'    client_ca_file: "([^"]+)"\n'
    r'    client_ca_key_file: "([^"]+)"$',
    control,
)
assert match and match.group(1) == "true"
cert_dir = (root / "local-certs").resolve()
assert match.group(2) == str(cert_dir / "runtime-channel-server.pem")
assert match.group(3) == str(cert_dir / "runtime-channel-server.key")
assert match.group(4) == str(cert_dir / "runtime-client-ca.pem")
assert match.group(5) == str(cert_dir / "runtime-client-ca.key")

log = json.loads((root / "scraper/log-config.local.json").read_text())
assert log["kafka"] == {
    "enabled": True,
    "brokers": ["127.0.0.1:9092"],
    "topic": "app-logs",
    "topic_prefix": "app-logs",
}
assert log["tracing"] == {
    "enabled": True,
    "endpoint": "http://127.0.0.1:4318",
    "service_name": "scraper",
}
PY

snapshot="${fixture}/snapshot"
mkdir -p "${snapshot}"
for path in "${generated[@]}"; do
  mkdir -p "${snapshot}/$(dirname -- "${path}")"
  cp "${fixture}/${path}" "${snapshot}/${path}"
done
HUSHINE_SOURCE_ROOT="${fixture}" \
HUSHINE_LOCAL_CERT_DIR="${fixture}/local-certs" \
  "${GENERATOR}"
for path in "${generated[@]}"; do
  cmp "${snapshot}/${path}" "${fixture}/${path}"
done
