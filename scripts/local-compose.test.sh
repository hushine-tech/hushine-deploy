#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

compose="deploy/local/docker-compose.yml"

if ! grep -Fq 'KAFKA_ADVERTISED_LISTENERS: INTERNAL://kafka:29092,HOST://${KAFKA_HOST:-localhost}:9092' "$compose"; then
  echo "local compose Kafka HOST listener must be configurable through KAFKA_HOST" >&2
  exit 1
fi

if grep -Fq 'HOST://localhost:9092' "$compose"; then
  echo "local compose Kafka HOST listener is still hard-coded to localhost" >&2
  exit 1
fi

if grep -Fq '$(LOCAL_COMPOSE) up -d --build' Makefile; then
  echo "local infra startup must not rebuild an already available bridge image" >&2
  exit 1
fi
grep -Fq 'docker image inspect elk-kafka-es-bridge:latest' Makefile
grep -Fq '$(LOCAL_COMPOSE) build kafka-es-bridge' Makefile
