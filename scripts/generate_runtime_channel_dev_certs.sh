#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CERT_DIR="${ROOT}/certs"
mkdir -p "${CERT_DIR}"

openssl req -x509 -newkey rsa:2048 -nodes -days 365 \
  -subj "/CN=runtime-channel.local" \
  -addext "subjectAltName=DNS:runtime-channel.local,IP:127.0.0.1" \
  -keyout "${CERT_DIR}/runtime-channel-server.key" \
  -out "${CERT_DIR}/runtime-channel-server.pem"
cp "${CERT_DIR}/runtime-channel-server.pem" "${CERT_DIR}/runtime-channel-ca.pem"

openssl req -x509 -newkey rsa:2048 -nodes -days 365 \
  -subj "/CN=hushine-runtime-client-ca" \
  -keyout "${CERT_DIR}/runtime-client-ca.key" \
  -out "${CERT_DIR}/runtime-client-ca.pem"

chmod 600 "${CERT_DIR}"/*.key
echo "runtime channel dev certs written to ${CERT_DIR}"
