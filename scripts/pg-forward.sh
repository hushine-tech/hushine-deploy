#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

LISTEN_HOST="${PG_FORWARD_LISTEN_HOST:-127.0.0.1}"
LISTEN_PORT="${PG_FORWARD_LISTEN_PORT:-15432}"
TARGET_HOST="${PG_FORWARD_TARGET_HOST:-192.168.88.10}"
TARGET_PORT="${PG_FORWARD_TARGET_PORT:-5432}"
LABEL="${PG_FORWARD_LABEL:-com.hushine.pg-forward-${LISTEN_PORT}}"
PLIST="${HOME}/Library/LaunchAgents/${LABEL}.plist"
FORWARDER="${SCRIPT_DIR}/pg-forward.py"
LOG_DIR="${ROOT_DIR}/logs"
STDOUT_LOG="${LOG_DIR}/pg-forward-${LISTEN_PORT}.log"
STDERR_LOG="${LOG_DIR}/pg-forward-${LISTEN_PORT}.err.log"
DOMAIN="gui/$(id -u)"

usage() {
  cat <<EOF
Usage: $0 <command>

Commands:
  install    Create/update LaunchAgent and start the forwarder
  start      Start the LaunchAgent
  stop       Stop the LaunchAgent
  restart    Stop, install, and start again
  status     Show LaunchAgent and listen-port status
  test       Test the local listen port
  logs       Tail forwarder logs
  uninstall  Stop and remove the LaunchAgent plist

Environment overrides:
  PG_FORWARD_LISTEN_HOST=${LISTEN_HOST}
  PG_FORWARD_LISTEN_PORT=${LISTEN_PORT}
  PG_FORWARD_TARGET_HOST=${TARGET_HOST}
  PG_FORWARD_TARGET_PORT=${TARGET_PORT}
  PG_FORWARD_LABEL=${LABEL}

DataGrip:
  Host=${LISTEN_HOST}
  Port=${LISTEN_PORT}
EOF
}

write_plist() {
  mkdir -p "${HOME}/Library/LaunchAgents" "${LOG_DIR}"
  cat > "${PLIST}" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>${LABEL}</string>
  <key>ProgramArguments</key>
  <array>
    <string>/usr/bin/python3</string>
    <string>${FORWARDER}</string>
    <string>--listen-host</string>
    <string>${LISTEN_HOST}</string>
    <string>--listen-port</string>
    <string>${LISTEN_PORT}</string>
    <string>--target-host</string>
    <string>${TARGET_HOST}</string>
    <string>--target-port</string>
    <string>${TARGET_PORT}</string>
  </array>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <true/>
  <key>StandardOutPath</key>
  <string>${STDOUT_LOG}</string>
  <key>StandardErrorPath</key>
  <string>${STDERR_LOG}</string>
</dict>
</plist>
EOF
}

is_loaded() {
  launchctl print "${DOMAIN}/${LABEL}" >/dev/null 2>&1
}

bootout_if_loaded() {
  if is_loaded; then
    launchctl bootout "${DOMAIN}/${LABEL}" >/dev/null 2>&1 || true
  fi
}

install_service() {
  write_plist
  bootout_if_loaded
  launchctl bootstrap "${DOMAIN}" "${PLIST}"
  launchctl enable "${DOMAIN}/${LABEL}"
  launchctl kickstart -k "${DOMAIN}/${LABEL}"
}

start_service() {
  if [[ ! -f "${PLIST}" ]]; then
    write_plist
    launchctl bootstrap "${DOMAIN}" "${PLIST}"
    launchctl enable "${DOMAIN}/${LABEL}"
  elif ! is_loaded; then
    launchctl bootstrap "${DOMAIN}" "${PLIST}"
  fi
  launchctl kickstart -k "${DOMAIN}/${LABEL}"
}

stop_service() {
  bootout_if_loaded
}

status_service() {
  if is_loaded; then
    launchctl print "${DOMAIN}/${LABEL}" | sed -n '1,80p'
  else
    echo "${LABEL} is not loaded"
  fi

  echo
  lsof -nP -iTCP:"${LISTEN_PORT}" -sTCP:LISTEN || true
}

test_service() {
  python3 - <<PY
import socket
host = "${LISTEN_HOST}"
port = int("${LISTEN_PORT}")
with socket.create_connection((host, port), timeout=5):
    print(f"ok: {host}:{port} is reachable")
PY
}

tail_logs() {
  mkdir -p "${LOG_DIR}"
  touch "${STDOUT_LOG}" "${STDERR_LOG}"
  tail -f "${STDOUT_LOG}" "${STDERR_LOG}"
}

uninstall_service() {
  stop_service
  rm -f "${PLIST}"
}

command="${1:-}"
case "${command}" in
  install)
    install_service
    status_service
    ;;
  start)
    start_service
    status_service
    ;;
  stop)
    stop_service
    ;;
  restart)
    stop_service
    install_service
    status_service
    ;;
  status)
    status_service
    ;;
  test)
    test_service
    ;;
  logs)
    tail_logs
    ;;
  uninstall)
    uninstall_service
    ;;
  -h|--help|help|"")
    usage
    ;;
  *)
    echo "unknown command: ${command}" >&2
    usage >&2
    exit 2
    ;;
esac
