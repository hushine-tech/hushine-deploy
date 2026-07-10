# Deployment Makefile for Hushine multi-repository source trees.
# Clone hushine-tech/core-service into ./core-service; current service
# scripts still use that local directory/name.
#
#   make ensure-dbs — create all databases + apply migrations (idempotent, run first on fresh deploy)
#   make build      — compile all Go services to their bin/ directories
#   make dev        — run all services in dev mode (foreground, Ctrl+C to stop)
#   make start      — build then background-start all services (logs in each service's logs/)
#   make stop       — stop background services started via 'make start'
#   make clean      — remove binaries and PID files

SERVICES := core-service control-panel-service strategy-service gateway/quant-handler gateway/quant-frontend scraper
LOCAL_COMPOSE := docker compose -f deploy/local/docker-compose.yml
DEV_NO_PROXY_HOSTS ?= 127.0.0.1,localhost,::1,192.168.88.10,host.docker.internal
DEV_NO_PROXY := NO_PROXY=$(DEV_NO_PROXY_HOSTS),$${NO_PROXY} no_proxy=$(DEV_NO_PROXY_HOSTS),$${no_proxy}
LOCAL_NO_PROXY := $(DEV_NO_PROXY)

.PHONY: build dev start stop clean test help ensure-dbs db-schema-bundle local-infra-up local-infra-down local-infra-reset local-infra-ps local-bootstrap local-ensure-dbs local-dev local-start local-stop runtime-image smoke-hosted-runtime smoke-self-hosted-runtime runtime-smoke-hosted runtime-smoke-self-hosted

help:
	@echo "Targets:"
	@echo "  ensure-dbs — create all databases + apply migrations (fresh deploy first step)"
	@echo "  db-schema-bundle — render versioned fresh-bootstrap SQL bundles"
	@echo "  build      — compile all Go services"
	@echo "  dev        — run all services in foreground (Ctrl+C to stop)"
	@echo "  start      — build and start all services in background"
	@echo "  stop       — stop background services"
	@echo "  clean      — remove binaries and PID files"
	@echo "  test       — run tests in all services"
	@echo "  local-infra-up     — start local Docker infra (TimescaleDB/Kafka/ELK/Jaeger)"
	@echo "  local-bootstrap    — start local infra, wait for DB, and apply migrations"
	@echo "  local-ensure-dbs   — create local databases + migrations"
	@echo "  local-dev          — run services against local Docker infra in foreground"
	@echo "  local-start        — run services against local Docker infra in background"
	@echo "  local-stop         — stop background services"
	@echo "  runtime-image      — build hushine/strategy-runtime image (IMAGE_TAG=dev)"
	@echo "  smoke-hosted-runtime      — EnsureHostedRuntime smoke (requires USER_ID)"
	@echo "  smoke-self-hosted-runtime — self-hosted RuntimeChannel smoke (requires CREDENTIAL_FILE)"

# Idempotent — safe to rerun. See db/README.md for the full table inventory
# and the PG* env vars the underlying scripts honor.
ensure-dbs:
	@bash scripts/ensure-all-dbs.sh

db-schema-bundle:
	@bash scripts/db/render-schema-bundle.sh

build:
	@for svc in $(SERVICES); do \
		echo "── Building $$svc ──"; \
		$(MAKE) -C $$svc build || exit 1; \
	done
	@echo "✓ All services built"

test:
	@for svc in $(SERVICES); do \
		echo "── Testing $$svc ──"; \
		$(MAKE) -C $$svc test || exit 1; \
	done

dev:
	@echo "Starting all services in dev mode (Ctrl+C to stop)..."
	@trap 'echo "Stopping..."; kill 0 2>/dev/null; exit 0' INT TERM EXIT; \
	$(DEV_NO_PROXY) $(MAKE) -C core-service dev & \
	sleep 2; \
	$(DEV_NO_PROXY) $(MAKE) -C control-panel-service dev & \
	$(DEV_NO_PROXY) $(MAKE) -C scraper dev & \
	sleep 1; \
	$(DEV_NO_PROXY) $(MAKE) -C gateway/quant-handler dev & \
	sleep 1; \
	$(DEV_NO_PROXY) $(MAKE) -C gateway/quant-frontend dev & \
	wait

start:
	@$(DEV_NO_PROXY) $(MAKE) -C core-service start
	@sleep 2
	@$(DEV_NO_PROXY) $(MAKE) -C control-panel-service start
	@$(DEV_NO_PROXY) $(MAKE) -C scraper start
	@sleep 1
	@$(DEV_NO_PROXY) $(MAKE) -C gateway/quant-handler start
	@$(DEV_NO_PROXY) $(MAKE) -C gateway/quant-frontend start
	@echo "✓ All services started in background"

stop:
	@for svc in $(SERVICES); do \
		$(MAKE) -C $$svc stop 2>/dev/null || true; \
	done
	@echo "✓ All services stopped"

clean:
	@for svc in $(SERVICES); do \
		$(MAKE) -C $$svc clean 2>/dev/null || true; \
	done
	@echo "✓ Clean done"

local-infra-up:
	@$(LOCAL_COMPOSE) up -d --build

local-infra-down:
	@$(LOCAL_COMPOSE) down

local-infra-reset:
	@$(LOCAL_COMPOSE) down -v

local-infra-ps:
	@$(LOCAL_COMPOSE) ps

local-bootstrap: local-infra-up
	@bash scripts/local-bootstrap.sh

local-ensure-dbs:
	@PGHOST=127.0.0.1 PGPORT=5432 PGUSER=postgres PGPASSWORD=postgres PGDATABASE_ADMIN=postgres bash scripts/ensure-all-dbs.sh

local-dev: local-bootstrap
	@echo "Starting all services against local Docker infra (Ctrl+C to stop)..."
	@trap 'echo "Stopping..."; kill 0 2>/dev/null; exit 0' INT TERM EXIT; \
	$(LOCAL_NO_PROXY) $(MAKE) -C core-service CONFIG=./config.local.yaml dev & \
	sleep 2; \
	$(LOCAL_NO_PROXY) $(MAKE) -C control-panel-service CONFIG=./config.local.yaml dev & \
	$(LOCAL_NO_PROXY) $(MAKE) -C scraper CONFIG=./config.local.yaml LOG_CONFIG=./log-config.local.json dev & \
	sleep 1; \
	$(LOCAL_NO_PROXY) $(MAKE) -C gateway/quant-handler CONFIG=./config.local.yaml dev & \
	sleep 1; \
	$(LOCAL_NO_PROXY) $(MAKE) -C gateway/quant-frontend dev & \
	wait

local-start: local-bootstrap
	@$(LOCAL_NO_PROXY) $(MAKE) -C core-service CONFIG=./config.local.yaml start
	@sleep 2
	@$(LOCAL_NO_PROXY) $(MAKE) -C control-panel-service CONFIG=./config.local.yaml start
	@$(LOCAL_NO_PROXY) $(MAKE) -C scraper CONFIG=./config.local.yaml LOG_CONFIG=./log-config.local.json start
	@sleep 1
	@$(LOCAL_NO_PROXY) $(MAKE) -C gateway/quant-handler CONFIG=./config.local.yaml start
	@$(LOCAL_NO_PROXY) $(MAKE) -C gateway/quant-frontend start
	@echo "✓ All services started against local Docker infra"

local-stop:
	@for svc in $(SERVICES); do \
		$(MAKE) -C $$svc stop 2>/dev/null || true; \
	done
	@echo "✓ Local services stopped"

runtime-image:
	@bash strategy-service/scripts/build_strategy_runtime.sh "$${IMAGE_TAG:-dev}"

smoke-hosted-runtime runtime-smoke-hosted:
	@test -n "$${USER_ID:-}" || (echo "required: USER_ID=<account.users.id>"; exit 2)
	@bash scripts/smoke_d3_hosted_runtime.sh

smoke-self-hosted-runtime runtime-smoke-self-hosted:
	@test -n "$${CREDENTIAL_FILE:-}" || (echo "required: CREDENTIAL_FILE=/path/to/runtime.cred"; exit 2)
	@bash scripts/smoke_d3_self_hosted_runtime.sh
