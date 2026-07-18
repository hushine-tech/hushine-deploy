#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CERT_DIR="${ROOT}/certs"
mkdir -p "${CERT_DIR}"

certificates_are_current() {
  local path
  for path in \
    runtime-channel-server.key \
    runtime-channel-server.pem \
    runtime-channel-ca.pem \
    runtime-client-ca.key \
    runtime-client-ca.pem; do
    [[ -s "${CERT_DIR}/${path}" ]] || return 1
  done
  openssl x509 -checkend 86400 -noout \
    -in "${CERT_DIR}/runtime-channel-server.pem" >/dev/null 2>&1 || return 1
  openssl x509 -checkend 86400 -noout \
    -in "${CERT_DIR}/runtime-client-ca.pem" >/dev/null 2>&1 || return 1
  openssl pkey -check -noout \
    -in "${CERT_DIR}/runtime-channel-server.key" >/dev/null 2>&1 || return 1
  openssl pkey -check -noout \
    -in "${CERT_DIR}/runtime-client-ca.key" >/dev/null 2>&1 || return 1
}

if certificates_are_current; then
  chmod 600 "${CERT_DIR}"/*.key
  echo "runtime channel dev certs already current in ${CERT_DIR}"
  exit 0
fi

temporary="$(mktemp -d "${CERT_DIR}/.runtime-certs.XXXXXX")"
cleanup() {
  rm -rf -- "${temporary}"
}
trap cleanup EXIT HUP INT TERM

openssl req -x509 -newkey rsa:2048 -nodes -days 365 \
  -subj "/CN=runtime-channel.local" \
  -addext "subjectAltName=DNS:runtime-channel.local,DNS:host.docker.internal,IP:127.0.0.1" \
  -keyout "${temporary}/runtime-channel-server.key" \
  -out "${temporary}/runtime-channel-server.pem" >/dev/null 2>&1
cp "${temporary}/runtime-channel-server.pem" "${temporary}/runtime-channel-ca.pem"

openssl req -x509 -newkey rsa:2048 -nodes -days 365 \
  -subj "/CN=hushine-runtime-client-ca" \
  -keyout "${temporary}/runtime-client-ca.key" \
  -out "${temporary}/runtime-client-ca.pem" >/dev/null 2>&1

chmod 600 "${temporary}"/*.key
chmod 644 "${temporary}"/*.pem
for path in \
  runtime-channel-server.key \
  runtime-channel-server.pem \
  runtime-channel-ca.pem \
  runtime-client-ca.key \
  runtime-client-ca.pem; do
  mv -f -- "${temporary}/${path}" "${CERT_DIR}/${path}"
done
echo "runtime channel dev certs written to ${CERT_DIR}"
