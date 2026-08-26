# AGENTS.md

## Project Overview

Hushine is a multi-repository quantitative cryptocurrency platform. The portal uses Portfolio + Venue terminology. quant-frontend talks only to quant-handler; trading state lives in core-service; runtime and market-data control state lives in control-panel-service; strategy execution uses a Go runtime-agent that launches an isolated Python session worker over RuntimeChannel.

## Source of Truth

- Current product behavior: Notion project overview, system architecture, Runtime Management, user manual.
- Database schema: `db/README.md` and service migrations.
- Historical decisions: OpenSpec archive and dated Superpowers specs/plans.
- Do not treat dated audits or archived Account-era documents as current operator instructions.

## Current Service Map

- quant-frontend `:5173` -> quant-handler `:8090` via HTTP/JWT.
- quant-handler -> core-service `portfolio.v1` + `order.v1` on `:50051`.
- quant-handler -> control-panel-service `:50054` for runtime/market-data and strategy proxy operations.
- hosted/self-hosted/bare runtime-agent -> RuntimeChannel `:50055` -> Python `hushine-session-worker`.
- scraper -> Binance REST/WebSocket -> `{exchange}_{year}` TimescaleDB and finalized live K-line Kafka topics.

## Product Invariants

- Route sessions only by `runtime_id`.
- Route orders only through core-service `order.v1` and explicit Portfolio/Venue facts.
- Self-hosted/bare runtimes do not receive internal DB, Kafka, account, or order addresses.
- User strategies declare `INPUTS` and `ORDER_TARGETS`; order side is BUY/SELL.
- Local offline package replay is not a current supported product capability; bare/debugger runtime remains an internal guarded capability.
- `environment=2` remains rollout-guarded.

## Build and Test

- Root orchestration: `make ensure-dbs`, `make build`, `make dev`, `make start`, `make stop`, `make test`.
- Go repositories: `go test ./...` and `go vet ./...` from each repository.
- strategy-service: `PYTHONPATH=.:../strategy-library uv run --frozen --extra dev pytest tests/ -q`, `go test ./...`, and both tracked shell tests.
- strategy-library: run its pytest suite in its managed environment.
- quant-frontend: `npm run build` and every `scripts/*.test.mjs` test.
- OpenSpec: `openspec validate --all --strict --no-interactive` from the workspace root.

## Working in This Workspace

- Root is not Git; each service is an independent repository.
- Preserve dirty work and stage only owned hunks.
- Use `rg`/`rg --files`, apply_patch, and repository-scoped verification.

## Known Boundaries

- OKX execution remains fail-closed.
- Exchange-backed confidence still requires operational smoke and reconciliation observation.
- Protocol/migration/history removal requires a separate compatibility decision.
