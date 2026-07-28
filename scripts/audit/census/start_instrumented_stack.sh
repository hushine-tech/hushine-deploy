#!/usr/bin/env bash
# Launch the four Go services from census-generated covered binaries.  The
# launcher parses environment files as data and spawns every child with a
# service-specific allowlist; it never sources or globally exports the file.
set -euo pipefail

DEPLOY_ROOT="$(cd "$(dirname "$0")/../../.." && pwd -P)"
if [ -d "${DEPLOY_ROOT}/core-service" ]; then
  DEFAULT_SOURCE_ROOT="$DEPLOY_ROOT"
else
  DEFAULT_SOURCE_ROOT="$(cd "${DEPLOY_ROOT}/.." && pwd -P)"
fi
SOURCE_ROOT="${CODE_CENSUS_SOURCE_ROOT:-${DEFAULT_SOURCE_ROOT}}"
LAUNCHER="${DEPLOY_ROOT}/scripts/audit/census/census/launch_child.py"
DRY_RUN=0
STOP=0
SKIP_FRONTEND=0
RUN_ID=""
ENV_FILE_ARG=""
CERT_ROOT_ARG=""
COVERAGE_IMAGE=""
BROWSER_ID=""
TAB_ID=""
START_DELAY_SECONDS="${CODE_CENSUS_START_DELAY_SECONDS:-1}"
STOP_TIMEOUT_SECONDS="${CODE_CENSUS_STOP_TIMEOUT_SECONDS:-10}"
STOP_POLL_INTERVAL_SECONDS="${CODE_CENSUS_STOP_POLL_INTERVAL_SECONDS:-0.1}"

usage() {
  printf '%s\n' \
    'Usage:' \
    '  scripts/audit/census/start_instrumented_stack.sh [options] <RUN_ID>' \
    '' \
    'Options:' \
    '  --dry-run                 Validate inputs and write the start plan only.' \
    '  --stop                    Stop services previously started for RUN_ID.' \
    '  --skip-frontend           Do not start gateway/quant-frontend.' \
    '  --source-root PATH        Absolute multi-repository source root.' \
    '  --env-file PATH           Optional ignored environment file (parsed, not sourced).' \
    '  --cert-root PATH          RuntimeChannel certificate directory.' \
    '  --coverage-image IMAGE    Immutable coverage Runtime image ID or digest.' \
    '  --browser-id ID           Browser binding recorded for external coverage owner.' \
    '  --tab-id ID               Opaque retained-tab binding (requires --browser-id).' \
    '  -h, --help                Show this help.'
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --dry-run) DRY_RUN=1 ;;
    --stop) STOP=1 ;;
    --skip-frontend) SKIP_FRONTEND=1 ;;
    --source-root|--env-file|--cert-root|--coverage-image|--browser-id|--tab-id)
      option="$1"
      if [ "$#" -lt 2 ]; then
        echo "${option} requires a value" >&2
        exit 2
      fi
      case "$option" in
        --source-root) SOURCE_ROOT="$2" ;;
        --env-file) ENV_FILE_ARG="$2" ;;
        --cert-root) CERT_ROOT_ARG="$2" ;;
        --coverage-image) COVERAGE_IMAGE="$2" ;;
        --browser-id) BROWSER_ID="$2" ;;
        --tab-id) TAB_ID="$2" ;;
      esac
      shift
      ;;
    -h|--help) usage; exit 0 ;;
    -*) echo "unknown option: $1" >&2; usage >&2; exit 2 ;;
    *)
      if [ -n "$RUN_ID" ]; then
        echo "unexpected extra argument: $1" >&2
        exit 2
      fi
      RUN_ID="$1"
      ;;
  esac
  shift
done

if [ -z "$RUN_ID" ]; then
  echo "RUN_ID is required" >&2
  usage >&2
  exit 2
fi
if [[ ! "$RUN_ID" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$ ]]; then
  echo "RUN_ID contains unsupported characters" >&2
  exit 2
fi
case "$SOURCE_ROOT" in
  /*) ;;
  *) echo "--source-root must be absolute: ${SOURCE_ROOT}" >&2; exit 2 ;;
esac
if [ ! -d "$SOURCE_ROOT" ]; then
  echo "source root not found: ${SOURCE_ROOT}" >&2
  exit 1
fi
SOURCE_ROOT="$(cd "$SOURCE_ROOT" && pwd -P)"

RUN_DIR="${SOURCE_ROOT}/census-runs/${RUN_ID}"
COVERAGE_DIR="${RUN_DIR}/coverage"
PLAN_FILE="${COVERAGE_DIR}/instrumented-stack.json"
PID_FILE="${COVERAGE_DIR}/instrumented-stack-pids.tsv"
STOP_STATUS_FILE="${COVERAGE_DIR}/instrumented-stack-stop.json"
HOSTED_COVERAGE_OUTPUT_DIR="${COVERAGE_DIR}/runtime-agent"

if [ ! -d "$RUN_DIR" ]; then
  echo "run directory not found: ${RUN_DIR}" >&2
  exit 1
fi

terminate_process_tree() {
  local pid="$1" signal="$2" child
  while IFS= read -r child; do
    [ -n "$child" ] || continue
    terminate_process_tree "$child" "$signal"
  done < <(pgrep -P "$pid" 2>/dev/null || true)
  kill "-${signal}" "$pid" 2>/dev/null || true
}

stop_stack() {
  local service pid log state_file result_file
  if [ ! -f "$PID_FILE" ]; then
    echo "pid file not found: ${PID_FILE}" >&2
    exit 1
  fi
  if ! python3 - "$STOP_TIMEOUT_SECONDS" "$STOP_POLL_INTERVAL_SECONDS" <<'PY'
import math
import sys

try:
    timeout = float(sys.argv[1])
    poll = float(sys.argv[2])
except ValueError:
    raise SystemExit(1)
if (
    not math.isfinite(timeout)
    or not math.isfinite(poll)
    or timeout <= 0
    or timeout > 600
    or poll <= 0
    or poll > 1
):
    raise SystemExit(1)
PY
  then
    echo "CODE_CENSUS_STOP_TIMEOUT_SECONDS must be in (0, 600] and CODE_CENSUS_STOP_POLL_INTERVAL_SECONDS must be in (0, 1]" >&2
    exit 2
  fi

  state_file="$(mktemp "${COVERAGE_DIR}/.instrumented-stop-state.XXXXXX")"
  result_file="$(mktemp "${COVERAGE_DIR}/.instrumented-stop-result.XXXXXX")"
  while IFS=$'\t' read -r service pid log; do
    [ -n "$service" ] || continue
    if [[ ! "$service" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$ ]] || [[ ! "$pid" =~ ^[0-9]+$ ]] || [ "$pid" -le 1 ]; then
      rm -f "$state_file" "$result_file"
      echo "invalid instrumented stack pid entry" >&2
      exit 1
    fi
    if kill -0 "$pid" >/dev/null 2>&1; then
      printf '%s\t%s\tpending\n' "$service" "$pid" >> "$state_file"
    else
      printf '%s\t%s\talready-stopped\n' "$service" "$pid" >> "$state_file"
    fi
    : "${log:=}"
  done < "$PID_FILE"

  while IFS=$'\t' read -r service pid status; do
    if [ "$status" = pending ]; then
      echo "stopping ${service} pid=${pid}"
      terminate_process_tree "$pid" TERM
    fi
  done < "$state_file"

  python3 - \
    "$state_file" "$result_file" \
    "$STOP_TIMEOUT_SECONDS" "$STOP_POLL_INTERVAL_SECONDS" <<'PY'
import os
import sys
import time
from pathlib import Path

state_path = Path(sys.argv[1])
result_path = Path(sys.argv[2])
timeout = float(sys.argv[3])
poll = float(sys.argv[4])
rows = []
for line in state_path.read_text(encoding="utf-8").splitlines():
    service, raw_pid, initial = line.split("\t", 2)
    rows.append((service, int(raw_pid), initial))


def alive(pid):
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    return True


deadline = time.monotonic() + timeout
pending = {
    pid
    for _service, pid, initial in rows
    if initial == "pending" and alive(pid)
}
while pending:
    remaining = deadline - time.monotonic()
    if remaining <= 0:
        break
    time.sleep(min(poll, remaining))
    pending = {pid for pid in pending if alive(pid)}

with result_path.open("w", encoding="utf-8") as handle:
    for service, pid, initial in rows:
        if initial == "already-stopped":
            status = initial
        elif alive(pid):
            status = "forced"
        else:
            status = "graceful"
        handle.write(f"{service}\t{pid}\t{status}\n")
PY

  while IFS=$'\t' read -r service pid status; do
    case "$status" in
      forced)
        echo "forced ${service} pid=${pid}"
        terminate_process_tree "$pid" KILL
        ;;
      graceful)
        echo "graceful ${service} pid=${pid}"
        ;;
      already-stopped)
        echo "already stopped ${service} pid=${pid}"
        ;;
    esac
  done < "$result_file"

  python3 - \
    "$result_file" "$STOP_STATUS_FILE" "$RUN_ID" \
    "$STOP_TIMEOUT_SECONDS" <<'PY'
import json
import os
import sys
from pathlib import Path

result_path = Path(sys.argv[1])
output = Path(sys.argv[2])
services = []
for line in result_path.read_text(encoding="utf-8").splitlines():
    service, raw_pid, status = line.split("\t", 2)
    services.append(
        {"service": service, "pid": int(raw_pid), "status": status}
    )
payload = {
    "schema_version": 1,
    "run_id": sys.argv[3],
    "timeout_seconds": float(sys.argv[4]),
    "services": services,
}
temporary = output.with_name(f".{output.name}.{os.getpid()}.tmp")
with temporary.open("x", encoding="utf-8") as handle:
    handle.write(json.dumps(payload, indent=2, sort_keys=True) + "\n")
    handle.flush()
    os.fsync(handle.fileno())
os.replace(temporary, output)
PY

  rm -f "$state_file" "$result_file"
  rm -f "$PID_FILE"
  echo "instrumented stack stopped: ${RUN_ID}"
}

if [ "$STOP" -eq 1 ]; then
  stop_stack
  exit 0
fi

if [ -z "$COVERAGE_IMAGE" ]; then
  echo "--coverage-image is required" >&2
  exit 2
fi
if [[ ! "$COVERAGE_IMAGE" =~ ^sha256:[0-9a-f]{64}$ && ! "$COVERAGE_IMAGE" =~ @sha256:[0-9a-f]{64}$ ]]; then
  echo "--coverage-image must be an immutable image ID or digest" >&2
  exit 2
fi
if { [ -n "$BROWSER_ID" ] && [ -z "$TAB_ID" ]; } || { [ -z "$BROWSER_ID" ] && [ -n "$TAB_ID" ]; }; then
  echo "--browser-id and --tab-id must be supplied together" >&2
  exit 2
fi
if [[ ! "$START_DELAY_SECONDS" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
  echo "CODE_CENSUS_START_DELAY_SECONDS must be a non-negative number" >&2
  exit 2
fi

canonical_file() {
  local path="$1" dir base
  if [ -L "$path" ]; then
    echo "symbolic links are not accepted: ${path}" >&2
    exit 1
  fi
  dir="$(cd "$(dirname "$path")" && pwd -P)"
  base="$(basename "$path")"
  printf '%s/%s' "$dir" "$base"
}

ENV_FILE=""
if [ -n "$ENV_FILE_ARG" ]; then
  ENV_FILE="$ENV_FILE_ARG"
elif [ -n "${CODE_CENSUS_ENV_FILE:-}" ]; then
  ENV_FILE="$CODE_CENSUS_ENV_FILE"
elif [ -f "${SOURCE_ROOT}/.env.local" ]; then
  ENV_FILE="${SOURCE_ROOT}/.env.local"
elif [ -f "${DEPLOY_ROOT}/.env.local" ]; then
  ENV_FILE="${DEPLOY_ROOT}/.env.local"
fi
if [ -n "$ENV_FILE" ]; then
  case "$ENV_FILE" in
    /*) ;;
    *) echo "--env-file must be absolute: ${ENV_FILE}" >&2; exit 2 ;;
  esac
  if [ ! -f "$ENV_FILE" ]; then
    echo "environment file not found: ${ENV_FILE}" >&2
    exit 1
  fi
  ENV_FILE="$(canonical_file "$ENV_FILE")"
  python3 "$LAUNCHER" --check-env-file "$ENV_FILE"
fi

complete_cert_root() {
  local root="$1" name
  for name in runtime-channel-server.pem runtime-channel-server.key runtime-client-ca.pem runtime-client-ca.key; do
    [ -f "${root}/${name}" ] || return 1
  done
}

CERT_ROOT=""
if [ -n "$CERT_ROOT_ARG" ]; then
  CERT_ROOT="$CERT_ROOT_ARG"
elif [ -n "${CODE_CENSUS_CERT_ROOT:-}" ]; then
  CERT_ROOT="$CODE_CENSUS_CERT_ROOT"
elif complete_cert_root "${SOURCE_ROOT}/hushine-deploy/certs"; then
  CERT_ROOT="${SOURCE_ROOT}/hushine-deploy/certs"
elif complete_cert_root "${DEPLOY_ROOT}/certs"; then
  CERT_ROOT="${DEPLOY_ROOT}/certs"
fi
if [ -n "$CERT_ROOT" ]; then
  case "$CERT_ROOT" in
    /*) ;;
    *) echo "--cert-root must be absolute: ${CERT_ROOT}" >&2; exit 2 ;;
  esac
  if ! complete_cert_root "$CERT_ROOT"; then
    echo "certificate root is incomplete: ${CERT_ROOT}" >&2
    exit 1
  fi
  CERT_ROOT="$(cd "$CERT_ROOT" && pwd -P)"
fi

services=(core-service control-panel-service scraper quant-handler)

service_repo_path() {
  case "$1" in
    core-service) printf '%s/core-service' "$SOURCE_ROOT" ;;
    control-panel-service) printf '%s/control-panel-service' "$SOURCE_ROOT" ;;
    scraper) printf '%s/scraper' "$SOURCE_ROOT" ;;
    quant-handler) printf '%s/gateway/quant-handler' "$SOURCE_ROOT" ;;
  esac
}

runtime_script_for() {
  printf '%s/coverage/%s/runtime/run-instrumented.sh' "$RUN_DIR" "$1"
}

validate_runtime_scripts() {
  local service script repo_line embedded expected
  for service in "${services[@]}"; do
    script="$(runtime_script_for "$service")"
    if [ ! -x "$script" ]; then
      echo "instrumented script missing or not executable: ${script}" >&2
      exit 1
    fi
    repo_line="$(grep -m 1 '^REPO=".*"$' "$script" || true)"
    if [ -n "$repo_line" ]; then
      embedded="${repo_line#REPO=\"}"
      embedded="${embedded%\"}"
      expected="$(service_repo_path "$service")"
      if [ "$embedded" != "$expected" ]; then
        echo "source root mismatch for ${service}" >&2
        exit 1
      fi
    fi
  done
}

service_arguments() {
  case "$1" in
    core-service|control-panel-service|quant-handler)
      SERVICE_ARGUMENTS=(-config ./config.local.yaml)
      ;;
    scraper)
      SERVICE_ARGUMENTS=(-config ./config.local.yaml -log-config ./log-config.local.json)
      ;;
  esac
}

start_service() {
  local service="$1" script log pid
  local -a command
  script="$(runtime_script_for "$service")"
  log="${COVERAGE_DIR}/${service}/runtime/${service}.out"
  service_arguments "$service"
  if [ "$DRY_RUN" -eq 1 ]; then
    printf 'dry-run: %s %q' "$service" "$script"
    printf ' %q' "${SERVICE_ARGUMENTS[@]}"
    printf '\n'
    return
  fi
  command=(python3 "$LAUNCHER" --service "$service")
  if [ -n "$ENV_FILE" ]; then
    command+=(--env-file "$ENV_FILE")
  fi
  if [ "$service" = control-panel-service ]; then
    command+=(
      --coverage-output "$HOSTED_COVERAGE_OUTPUT_DIR"
      --coverage-image "$COVERAGE_IMAGE"
    )
  fi
  command+=(
    --spawn
    --cwd "$(service_repo_path "$service")"
    --log "$log"
    -- "$script" "${SERVICE_ARGUMENTS[@]}"
  )
  mkdir -p "$(dirname "$log")"
  pid="$("${command[@]}")"
  if [[ ! "$pid" =~ ^[0-9]+$ ]]; then
    echo "failed to obtain child pid for ${service}" >&2
    exit 1
  fi
  printf '%s\t%s\t%s\n' "$service" "$pid" "$log" >> "$PID_FILE"
}

start_frontend() {
  local log pid
  local -a command
  [ "$SKIP_FRONTEND" -eq 0 ] || return
  log="${COVERAGE_DIR}/quant-frontend/runtime/quant-frontend.out"
  if [ "$DRY_RUN" -eq 1 ]; then
    echo "dry-run: quant-frontend npm run dev"
    return
  fi
  command=(python3 "$LAUNCHER" --service quant-frontend)
  if [ -n "$ENV_FILE" ]; then
    command+=(--env-file "$ENV_FILE")
  fi
  command+=(
    --spawn
    --cwd "${SOURCE_ROOT}/gateway/quant-frontend"
    --log "$log"
    -- npm run dev -- --host 127.0.0.1 --port 5173
  )
  mkdir -p "$(dirname "$log")"
  pid="$("${command[@]}")"
  if [[ ! "$pid" =~ ^[0-9]+$ ]]; then
    echo "failed to obtain child pid for quant-frontend" >&2
    exit 1
  fi
  printf '%s\t%s\t%s\n' quant-frontend "$pid" "$log" >> "$PID_FILE"
}

write_plan() {
  local dry="$1"
  PYTHONPATH="${DEPLOY_ROOT}/scripts/audit/census" python3 - \
    "$PLAN_FILE" "$RUN_ID" "$SOURCE_ROOT" "$ENV_FILE" "$CERT_ROOT" \
    "$COVERAGE_IMAGE" "$BROWSER_ID" "$TAB_ID" "$PID_FILE" "$dry" \
    "$SKIP_FRONTEND" <<'PY'
import json
import os
import sys
from pathlib import Path

from census.launch_child import build_child_environment, load_environment_file

(
    plan_file,
    run_id,
    source_root,
    env_file,
    cert_root,
    coverage_image,
    browser_id,
    tab_id,
    pid_file,
    dry_run,
    skip_frontend,
) = sys.argv[1:]
file_values = load_environment_file(Path(env_file)) if env_file else {}
pids = {}
if Path(pid_file).is_file():
    for line in Path(pid_file).read_text(encoding="utf-8").splitlines():
        service, pid, _log = line.split("\t", 2)
        pids[service] = int(pid)
services = []
for service in ("core-service", "control-panel-service", "scraper", "quant-handler"):
    fixed = {}
    if service == "control-panel-service":
        fixed = {
            "RUNTIME_COVERAGE_ENABLED": "true",
            "RUNTIME_COVERAGE_OUTPUT_DIR": "redacted-path-placeholder",
            "RUNTIME_COVERAGE_IMAGE": coverage_image,
        }
    names = sorted(build_child_environment(service, os.environ, file_values, fixed=fixed))
    services.append({"service": service, "pid": pids.get(service), "environment_names": names})
frontend = None
if skip_frontend == "0":
    frontend = {
        "service": "quant-frontend",
        "pid": pids.get("quant-frontend"),
        "environment_names": sorted(
            build_child_environment("quant-frontend", os.environ, file_values)
        ),
    }
payload = {
    "schema_version": 1,
    "run_id": run_id,
    "dry_run": dry_run == "1",
    "source_root": source_root,
    "env_file": env_file or None,
    "cert_root": cert_root or None,
    "coverage_image": coverage_image,
    "browser_binding": (
        {"browser_id": browser_id, "tab_id": tab_id}
        if browser_id and tab_id
        else None
    ),
    "services": services,
    "frontend": frontend,
}
Path(plan_file).write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")
PY
}

validate_runtime_scripts
mkdir -p "$HOSTED_COVERAGE_OUTPUT_DIR"
if [ "$DRY_RUN" -eq 0 ]; then
  : > "$PID_FILE"
fi
for service in "${services[@]}"; do
  start_service "$service"
  if [ "$DRY_RUN" -eq 0 ] && { [ "$service" = core-service ] || [ "$service" = scraper ]; }; then
    sleep "$START_DELAY_SECONDS"
  fi
done
start_frontend
write_plan "$DRY_RUN"

if [ "$DRY_RUN" -eq 1 ]; then
  echo "instrumented stack dry-run complete: ${PLAN_FILE}"
else
  echo "instrumented stack started: ${RUN_ID}"
  echo "stop with: ${DEPLOY_ROOT}/scripts/audit/census/start_instrumented_stack.sh --source-root ${SOURCE_ROOT} --stop ${RUN_ID}"
fi
