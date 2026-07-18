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

make -C "${SOURCE_ROOT}" -f "${DEPLOY_ROOT}/Makefile" local-configs \
  LOCAL_RUNTIME_COVERAGE_IMAGE=hushine/strategy-runtime:test-coverage \
  >/dev/null

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

HUSHINE_SOURCE_ROOT="${fixture}" "${GENERATOR}"

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
    r"(?ms)^runtime_channel_server:\n.*?^  tls:\n    enabled: (true|false)$",
    control,
)
assert match and match.group(1) == "false"

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
HUSHINE_SOURCE_ROOT="${fixture}" "${GENERATOR}"
for path in "${generated[@]}"; do
  cmp "${snapshot}/${path}" "${fixture}/${path}"
done
