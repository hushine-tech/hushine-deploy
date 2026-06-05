#!/usr/bin/env bash
# Source this file when manually running commands against the local Docker infra:
#
#   source scripts/local-env.sh
#   make ensure-dbs
#
# Service Makefiles should prefer CONFIG=./config.local.yaml because log Kafka
# and tracing endpoints are config-file fields, not global env-only fields.

export PGHOST="${PGHOST:-127.0.0.1}"
export PGPORT="${PGPORT:-5432}"
export PGUSER="${PGUSER:-postgres}"
export PGPASSWORD="${PGPASSWORD:-postgres}"
export PGDATABASE_ADMIN="${PGDATABASE_ADMIN:-postgres}"

export DATABASE_HOST="${DATABASE_HOST:-127.0.0.1}"
export DATABASE_PORT="${DATABASE_PORT:-5432}"
export DATABASE_USER="${DATABASE_USER:-postgres}"
export DATABASE_PASSWORD="${DATABASE_PASSWORD:-postgres}"
export DATABASE_SSLMODE="${DATABASE_SSLMODE:-disable}"

export TIMESCALE_HOST="${TIMESCALE_HOST:-127.0.0.1}"
export TIMESCALE_PORT="${TIMESCALE_PORT:-5432}"
export TIMESCALE_USER="${TIMESCALE_USER:-postgres}"
export TIMESCALE_PASSWORD="${TIMESCALE_PASSWORD:-postgres}"

export KAFKA_BROKERS="${KAFKA_BROKERS:-127.0.0.1:9092}"
export LOG_TRACING_ENDPOINT="${LOG_TRACING_ENDPOINT:-http://127.0.0.1:4318}"

# Local gRPC/HTTP calls must not go through a developer machine proxy.
export NO_PROXY="${NO_PROXY:-127.0.0.1,localhost,::1}"
export no_proxy="${no_proxy:-127.0.0.1,localhost,::1}"

export CORE_SERVICE_GRPC_ADDR="${CORE_SERVICE_GRPC_ADDR:-127.0.0.1:50051}"
export ACCOUNT_SERVICE_GRPC_ADDR="${ACCOUNT_SERVICE_GRPC_ADDR:-${CORE_SERVICE_GRPC_ADDR}}"
# Compatibility var: order.v1 is served by core-service on :50051.
export ORDER_SERVICE_GRPC_ADDR="${ORDER_SERVICE_GRPC_ADDR:-127.0.0.1:50051}"
export HANDLER_CORS_ORIGINS="${HANDLER_CORS_ORIGINS:-http://localhost:5173}"
export QUANT_HANDLER_JWT_SECRET="${QUANT_HANDLER_JWT_SECRET:-dev-secret-change-me}"
