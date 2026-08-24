#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

required_patterns=(
  './bin/core-service -config'
  './bin/control-panel-service -config'
  './bin/quant-handler -config'
  './bin/scraper -config'
)

required_literals=(
  'kill_listening_ports'
  'app_ports=('
  '50051:core-service'
  '50054:control-panel-service'
  '50055:control-panel-runtime-channel'
  '8090:quant-handler'
  '5173:quant-frontend'
  'assert_single_listener'
  'DEPLOY_ROOT="$(pwd -P)"'
  'SOURCE_ROOT="${DEPLOY_ROOT}"'
  'SOURCE_ROOT="$(cd "${DEPLOY_ROOT}/.." && pwd -P)"'
  'make -C "${SOURCE_ROOT}" ensure-dbs'
  'make -C "${SOURCE_ROOT}/core-service" start CONFIG="${APP_CONFIG}"'
  'CORE_CREDENTIAL_ENCRYPTION_KEY="${CORE_CREDENTIAL_ENCRYPTION_KEY:-0123456789abcdef0123456789abcdef}"'
  'CORE_CREDENTIAL_KEY_VERSION="${CORE_CREDENTIAL_KEY_VERSION:-dev-v1}"'
  'RUNTIME_PLATFORM_DEBUG_BARE_RUNTIME_ENABLED="${RUNTIME_PLATFORM_DEBUG_BARE_RUNTIME_ENABLED:-true}"'
  'RUNTIME_CHANNEL_SERVER_TLS_CLIENT_CA_FILE'
  'RUNTIME_CHANNEL_SERVER_TLS_CLIENT_CA_KEY_FILE'
  'RUNTIME_CHANNEL_SERVER_TLS_SERVER_NAME'
  'RUNTIME_PLATFORM_BARE_BOOTSTRAP_IP_ALLOWLIST'
  'Bare local: cd strategy-service && make build && DEBUG_WAIT=0 scripts/start-bare-runtime-debugpy.sh --user-id <users.id> --platform-host 127.0.0.1'
)

forbidden_literals=(
  'make -C '"strategy-service"' start'
  'strategy-service/'"logs/strategy-service.out"
  'make -C '"order-service"' start'
  'order-service/'"logs/order-service.out"
)

for pattern in "${required_patterns[@]}"; do
  if ! grep -Fq "$pattern" restart.sh; then
    echo "missing restart cleanup pattern: $pattern" >&2
    exit 1
  fi
done

for literal in "${forbidden_literals[@]}"; do
  if grep -Fq "$literal" restart.sh; then
    echo "obsolete independent order-service pattern still present: $literal" >&2
    exit 1
  fi
done

for literal in "${required_literals[@]}"; do
  if ! grep -Fq "$literal" restart.sh; then
    echo "missing restart port cleanup literal: $literal" >&2
    exit 1
  fi
done

test_root="$(mktemp -d)"
trap 'rm -rf -- "${test_root}"' EXIT
fake_bin="${test_root}/bin"
command_log="${test_root}/commands.log"
started_file="${test_root}/started"
mkdir -p "${fake_bin}"

cat >"${fake_bin}/make" <<'FAKE_MAKE'
#!/usr/bin/env bash
set -euo pipefail
printf 'make %s\n' "$*" >>"${COMMAND_LOG}"
case "$*" in
  *'/core-service start CONFIG='*)
    : >"${STARTED_FILE}"
    ;;
esac
FAKE_MAKE

cat >"${fake_bin}/nc" <<'FAKE_NC'
#!/usr/bin/env bash
exit 0
FAKE_NC

cat >"${fake_bin}/docker" <<'FAKE_DOCKER'
#!/usr/bin/env bash
set -euo pipefail
printf 'docker %s\n' "$*" >>"${COMMAND_LOG}"
FAKE_DOCKER

cat >"${fake_bin}/pkill" <<'FAKE_PKILL'
#!/usr/bin/env bash
set -euo pipefail
printf 'pkill %s\n' "$*" >>"${COMMAND_LOG}"
FAKE_PKILL

cat >"${fake_bin}/sleep" <<'FAKE_SLEEP'
#!/usr/bin/env bash
exit 0
FAKE_SLEEP

cat >"${fake_bin}/lsof" <<'FAKE_LSOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'lsof %s\n' "$*" >>"${COMMAND_LOG}"
if [[ -f "${STARTED_FILE}" ]]; then
  printf '%s\n' 43210
fi
FAKE_LSOF

cat >"${fake_bin}/pgrep" <<'FAKE_PGREP'
#!/usr/bin/env bash
set -euo pipefail
printf 'pgrep %s\n' "$*" >>"${COMMAND_LOG}"
if [[ -f "${STARTED_FILE}" && "$*" == *control-panel-service* ]]; then
  printf '%s\n' 43210
fi
FAKE_PGREP

chmod 0700 "${fake_bin}"/*
: >"${command_log}"

PATH="${fake_bin}:${PATH}" \
COMMAND_LOG="${command_log}" \
STARTED_FILE="${started_file}" \
  bash restart.sh >/dev/null

expected_source_root="$(pwd -P)"
if [[ ! -d "${expected_source_root}/core-service" \
  && -d "${expected_source_root}/../core-service" ]]; then
  expected_source_root="$(cd .. && pwd -P)"
fi

for obsolete_call in \
  'docker rm -f hushine-strategy-service' \
  '50052' \
  '50053' \
  'order-service' \
  'run_grpc_server.py'; do
  if grep -Fq -- "${obsolete_call}" "${command_log}"; then
    echo "restart invoked obsolete cleanup: ${obsolete_call}" >&2
    exit 1
  fi
done

for current_call in \
  'lsof -nP -tiTCP:50051 -sTCP:LISTEN' \
  'lsof -nP -tiTCP:50055 -sTCP:LISTEN' \
  'make -C '"${expected_source_root}"'/core-service start CONFIG=./config.local.yaml'; do
  if ! grep -Fq -- "${current_call}" "${command_log}"; then
    echo "restart skipped current startup/cleanup behavior: ${current_call}" >&2
    exit 1
  fi
done

for smoke_script in scripts/smoke_d3_hosted_runtime.sh scripts/smoke_d3_self_hosted_runtime.sh; do
  for literal in \
    'DEPLOY_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"' \
    'SOURCE_ROOT="${DEPLOY_ROOT}"' \
    'SOURCE_ROOT="$(cd "${DEPLOY_ROOT}/.." && pwd -P)"'; do
    if ! grep -Fq -- "$literal" "$smoke_script"; then
      echo "missing source-root smoke literal in ${smoke_script}: $literal" >&2
      exit 1
    fi
  done
done

if ! grep -Fq 'go run scripts/smoke_ensure_runtime.go' scripts/smoke_d3_hosted_runtime.sh; then
  echo "hosted runtime smoke no longer calls smoke_ensure_runtime.go" >&2
  exit 1
fi

for literal in \
  'build_args=()' \
  'build_args+=(--allow-dirty)' \
  '"${build_args[@]}" "${IMAGE_TAG}"'; do
  if ! grep -Fq -- "$literal" scripts/smoke_d3_hosted_runtime.sh; then
    echo "hosted runtime dev smoke does not preserve dirty-source provenance: $literal" >&2
    exit 1
  fi
done
