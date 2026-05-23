# Hushine Deploy

Deployment, database, smoke-test, and operator documentation for the Hushine
multi-repository system.

This repository does not contain service source code. Clone it beside the
service repositories and keep the directory names below. The `core-service`
repository is checked out as `account-service` because current scripts and
runtime configs still use that service directory/name while the Go module and
GitHub repository have moved to `core-service`.

## Repository Layout

```bash
mkdir hushine
cd hushine

git clone git@github.com:hushine-tech/hushine-deploy.git .
git clone git@github.com:hushine-tech/core-service.git account-service
git clone git@github.com:hushine-tech/control-panel-service.git control-panel-service
git clone git@github.com:hushine-tech/quant-handler.git gateway/quant-handler
git clone git@github.com:hushine-tech/quant-frontend.git gateway/quant-frontend
git clone git@github.com:hushine-tech/scraper.git scraper
git clone git@github.com:hushine-tech/strategy-service.git strategy-service
git clone git@github.com:hushine-tech/strategy-library.git strategy-library
git clone git@github.com:hushine-tech/golang-lib.git golang-lib
```

Expected tree:

```text
hushine/
  Makefile
  restart.sh
  deploy/
  docs/
  db/
  scripts/
  account-service/          # GitHub: hushine-tech/core-service
  control-panel-service/
  gateway/
    quant-handler/
    quant-frontend/
  scraper/
  strategy-service/
  strategy-library/
  golang-lib/
```

## Services

| Directory | GitHub repo | Language | Port(s) |
|---|---|---|---|
| `account-service` | `hushine-tech/core-service` | Go | HTTP `:8080`, gRPC `:50051`; serves `account.v1` and `order.v1` |
| `control-panel-service` | `hushine-tech/control-panel-service` | Go | gRPC `:50054`, HTTP `:8082` |
| `gateway/quant-handler` | `hushine-tech/quant-handler` | Go | HTTP `:8090` |
| `gateway/quant-frontend` | `hushine-tech/quant-frontend` | React | `:5173` |
| `scraper` | `hushine-tech/scraper` | Go | market-data collector |
| `strategy-service` | `hushine-tech/strategy-service` | Python + Go proto stubs | gRPC `:50053`, HTTP `:8000` |
| `strategy-library` | `hushine-tech/strategy-library` | Python | shared strategy utilities |
| `golang-lib` | `hushine-tech/golang-lib` | Go | shared logging/middleware |

## Quick Start

Default source development uses shared remote infrastructure on
`192.168.88.10`:

- TimescaleDB: `192.168.88.10:5432`
- Kafka external listener: `192.168.88.10:19092`
- Elasticsearch: `http://192.168.88.10:9200`
- Kibana: `http://192.168.88.10:5601`
- Jaeger: `http://192.168.88.10:16686`, OTLP HTTP `http://192.168.88.10:4318`

Run services from source:

```bash
make dev
```

For an isolated local-only stack:

```bash
make local-bootstrap  # infra + databases + migrations
make local-dev        # foreground services
make local-start      # background services
make local-stop
```

Details: [docs/local-docker.md](docs/local-docker.md).

## Build And Start

```bash
make ensure-dbs
make build
make start
make stop
```

Each service repository also has its own Makefile:

```bash
cd <service-dir>
make build
make dev
make start
make stop
make test
make clean
```

## Configuration

- Each service repo owns its `config.yaml`.
- Local machine overrides should use `config.local.yaml`, `.env.local`, or
  environment variables; local configs are intentionally git-ignored by service
  repositories.
- Log, Kafka, and tracing settings live under each service's `log:` section.
- `order.v1` is served by `account-service`/`core-service` on gRPC `:50051`;
  there is no independent order-service in the deployment.

## Databases And Infra

- Schema inventory: [db/README.md](db/README.md)
- Production deploy checklist: [docs/production-deploy-checklist.md](docs/production-deploy-checklist.md)
- Local Docker infra: [deploy/local/docker-compose.yml](deploy/local/docker-compose.yml)
- Tracing verification: `bash scripts/verify_tracing.sh`
- Full local flow smoke: `bash scripts/e2e_full_flow.sh`

## Runtime Smoke

```bash
USER_ID=<account.users.id> make smoke-hosted-runtime
```

Self-hosted runtime:

```bash
CREDENTIAL_FILE=$HOME/.hushine/runtime.cred \
CONTROL_PANEL_ADDR=host.docker.internal:50054 \
make smoke-self-hosted-runtime
```
