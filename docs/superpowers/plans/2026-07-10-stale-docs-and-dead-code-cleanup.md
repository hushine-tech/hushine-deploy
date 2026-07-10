# Hushine Stale Documentation and Dead Code Cleanup Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Remove proven-unreachable code, redundant source copies, broken legacy scripts, and misleading current-state documentation without changing any Notion-defined Hushine product behavior.

**Architecture:** Execute the cleanup as repository-scoped batches. Each batch starts from a recorded dirty-worktree baseline, proves the candidate is unreachable or superseded, applies only the approved deletion/documentation patch, and runs the owning repository's tests before any commit. Protocols, migrations, public library exports, RuntimeChannel/debugger compatibility, and user-authored dirty changes remain untouched.

**Tech Stack:** Go 1.25/1.26 services, Python 3.13 with `uv`, React 19/Vite, Bash, protobuf/gRPC, Markdown, multi-repository Git workspace.

## Global Constraints

- The workspace root `/Users/xdy/Workplace/hushine` is not a Git repository; every service repository has independent history and dirty state.
- Preserve every pre-existing user modification. Never use `git reset --hard`, `git checkout --`, whole-file restoration, or broad staging.
- Use `apply_patch` for source and documentation edits. Formatting tools may perform mechanical rewrites after the intended patch.
- Do not delete or change proto/RPC contracts, generated stubs, migrations, public Python library exports, DB read fallbacks, historical status compatibility, or internal debugger/bare-runtime paths.
- Keep `openspec/changes/archive/**`, dated audits, `docs/superpowers/plans/**`, `docs/superpowers/specs/**`, and `progress/discuss.md` as history.
- Do not edit the dirty `gateway/quant-frontend/src/features/charts/ChartsPlaceholder.tsx` candidate.
- Do not change `scripts/audit/census/config.yaml`; the current Python coverage wrapper cannot execute a Go runtime-agent command.
- Do not delete the broken `hushine-deploy`-local `audit` target in this change; only the approved root workspace audit entry is removed.
- `hushine-deploy` is the versioned deployment/documentation source of truth. Root operational files are wrappers or synchronized workspace copies.
- When an approved file was dirty at baseline, stage only this cleanup's hunk with `git add -p`; abort the commit if unrelated hunks cannot be isolated.
- A baseline failure remains a baseline failure. Report it explicitly and require that this cleanup introduces no new failures.

## File and Responsibility Map

| Area | Files | Responsibility |
|---|---|---|
| Unreachable BFF route | `gateway/quant-handler/internal/app/runtime_route.go`, `runtime_route_test.go`, `README.md` | Remove a handler that is not registered in the HTTP mux and its direct-only tests/documentation |
| Scraper logging copy | `scraper/internal/logger/vendor/**`, `scraper/Dockerfile` | Remove an unused Elemental source snapshot while retaining the active `golang-lib` wrapper |
| Strategy-service debris | `requirements.txt`, `generate_order_proto.sh`, `verify_algo_flow.py`, `strategy_service/cli/__init__.py`, `tests/hello` | Remove clean, tracked, zero-reference files already replaced by `pyproject.toml`, `generate_proto.sh`, and runtime-agent/session-worker entry points |
| Root stale entry points | `progress/roadmap.md`, `scripts/audit/run_audit.sh`, `Makefile` | Remove a misleading current roadmap and an audit command that references deleted tests |
| Canonical architecture docs | `AGENTS.md`, `hushine-deploy/AGENTS.md`, `hushine-deploy/README.md` | Describe the present Portfolio/Venue + RuntimeChannel + Go agent/Python worker architecture |
| Service docs | frontend/scraper/strategy-library/golang-lib READMEs, `core-service/config.yaml` comments | Correct current service capabilities and commands without changing runtime configuration |
| Runtime/deploy docs | root/deploy runtime docs, deploy checklist, restart message/test, debugger smoke scripts | Replace removed CLI commands and incorrect `:50054` self-hosted routing with current `:50055` RuntimeChannel usage |
| Canonical E2E | `hushine-deploy/scripts/e2e_full_flow.sh`, cutover test | Migrate the maintained full-flow smoke from Account APIs/schema to Portfolio/Venue APIs/schema |

---

### Task 1: Remove the Unregistered quant-handler Runtime Route

**Files:**
- Delete: `gateway/quant-handler/internal/app/runtime_route.go`
- Modify: `gateway/quant-handler/internal/app/runtime_route_test.go:3-178`
- Modify: `gateway/quant-handler/README.md:40-57`

**Interfaces:**
- Consumes: current mux registration in `internal/app/app.go`, where runtime selection is exposed only through `/api/runtimes*` and explicit `runtime_id`.
- Produces: no `handleResolveRuntimeRoute` symbol or `/api/_debug/runtime-route` documentation; all shared `fakeResolver` methods remain available to other test files.

- [ ] **Step 1: Record the dirty-file baseline and prove the route is unregistered**

Run from `gateway/quant-handler`:

```bash
git status --short -- README.md internal/app/runtime_route.go internal/app/runtime_route_test.go
rg -n 'handleResolveRuntimeRoute|/api/_debug/runtime-route' README.md internal/app
rg -n 'Handle(Func)?\(.*/api/_debug/runtime-route' internal/app/app.go
```

Expected: README and `runtime_route_test.go` are already modified; references occur only in the handler, its two direct tests, and README; the mux-registration scan prints nothing.

- [ ] **Step 2: Confirm the pre-cleanup test baseline**

```bash
go test ./internal/app -count=1
go test ./... -count=1
```

Expected: both commands exit 0 with `ok` package lines.

- [ ] **Step 3: Delete only the obsolete endpoint implementation and direct tests**

Delete `internal/app/runtime_route.go` completely. In `runtime_route_test.go`, delete the complete `TestRuntimeRouteByNameReturnsGone` function and the complete `TestRuntimeRoute_MethodNotAllowed` function, including the latter's two-line comment. Do not delete any code before `TestRuntimeRouteByNameReturnsGone`.

Then reduce the import block to:

```go
import (
    "context"
    "testing"

    "github.com/hushine-tech/quant-handler/internal/controlpanel"
)
```

Delete only the now-unused field from `fakeResolver`:

```go
resolveCalls int
```

Keep `fakeResolver`, `resp`, `err`, `resolveByIDCalls`, and every Resolver method. Other test files reuse them.

- [ ] **Step 4: Remove the false README compatibility claim**

Delete this paragraph without replacement; the preceding paragraph already documents the current route:

```text
The old name-based debug endpoint `GET /api/_debug/runtime-route` remains
only as a removal marker and returns `410 Gone`; routing uses `runtime_id` only.
```

- [ ] **Step 5: Format and prove the old surface is gone**

```bash
gofmt -w internal/app/runtime_route_test.go
if rg -n 'handleResolveRuntimeRoute|/api/_debug/runtime-route' README.md internal/app; then exit 1; fi
gofmt -d internal/app/runtime_route_test.go
```

Expected: the negative reference scan and formatting check both exit 0 with no output.

- [ ] **Step 6: Run targeted and full quant-handler verification**

```bash
go test ./internal/app -run 'Test(RuntimeManagement|RunStrategy)' -count=1
go test ./internal/app -count=1
go test ./... -count=1
go vet ./...
```

Expected: every command exits 0.

- [ ] **Step 7: Stage only cleanup hunks and commit**

```bash
git add internal/app/runtime_route.go
git add -p README.md internal/app/runtime_route_test.go
git diff --cached --check
git diff --cached -- README.md internal/app/runtime_route.go internal/app/runtime_route_test.go
```

Reject every pre-existing Portfolio migration hunk. Before committing, this guard must exit 0 and print nothing:

```bash
if git diff --cached | rg 'api/(accounts|portfolios)|got(Account|Portfolio)ID|args\.(Account|Portfolio)ID'; then exit 1; fi
```

Commit only when the guard is empty:

```bash
git commit -m 'chore: 删除不可达的 Runtime 旧路由'
```

---

### Task 2: Remove scraper's Unused Elemental Source Snapshot

**Files:**
- Delete: `scraper/internal/logger/vendor/github.com/hushine-tech/elemental/pkg/log/**`
- Modify: `scraper/Dockerfile:9-17`
- Preserve: `scraper/internal/logger/logger.go`, `helpers.go`, `logger_test.go`

**Interfaces:**
- Consumes: `github.com/hushine-tech/golang-lib/pkg/log`, already imported by the active scraper logger wrapper.
- Produces: unchanged scraper logging behavior with no nested Elemental source/module copy.

- [ ] **Step 1: Prove the nested vendor is outside the build graph**

Run from `scraper`:

```bash
git status --short
go list -deps ./... | rg '(^|/)internal/logger/vendor(/|$)|github.com/hushine-tech/elemental'
go list -deps ./... | rg -x 'github.com/hushine-tech/golang-lib/pkg/log'
```

Expected: worktree is clean; the first dependency scan prints nothing; the second prints exactly `github.com/hushine-tech/golang-lib/pkg/log`.

- [ ] **Step 2: Run the scraper baseline**

```bash
go test ./... -count=1
go vet ./...
docker compose config -q
```

Expected: all commands exit 0. Compose may print the existing obsolete-version warning.

- [ ] **Step 3: Delete the 13 tracked Elemental files**

Remove the complete `internal/logger/vendor/` tree, including its nested `go.mod`, `go.sum`, demo, implementation, and tests. Do not edit the active wrapper files.

- [ ] **Step 4: Correct Dockerfile comments without changing commands**

Use these exact comments:

```dockerfile
# Copy Go module files
COPY go.mod go.sum ./
RUN go mod download

# Copy source code
COPY . .

# Build binary
RUN CGO_ENABLED=0 GOOS=linux go build -o /bin/scraper ./cmd/scraper/
```

Keep the existing healthcheck unchanged; it is outside this approved cleanup.

- [ ] **Step 5: Verify deletion and active dependency resolution**

```bash
test ! -e internal/logger/vendor
if rg -n 'internal/logger/vendor|github.com/hushine-tech/elemental|using vendor|files and vendor' Dockerfile internal/logger; then exit 1; fi
if go list -deps ./... | rg '(^|/)internal/logger/vendor(/|$)|github.com/hushine-tech/elemental'; then exit 1; fi
go list -deps ./... | rg -x 'github.com/hushine-tech/golang-lib/pkg/log'
go test ./... -count=1
go vet ./...
docker compose config -q
```

Expected: deletion checks pass, the active log package prints once, and all verification commands exit 0.

- [ ] **Step 6: Commit the clean-repository batch**

```bash
git add Dockerfile internal/logger/vendor
git diff --cached --check
git diff --cached -- Dockerfile internal/logger/vendor
git commit -m 'chore: 删除 scraper 旧日志源码副本'
```

---

### Task 3: Remove strategy-service Zero-Reference Legacy Files

**Files:**
- Delete: `strategy-service/requirements.txt`
- Delete: `strategy-service/generate_order_proto.sh`
- Delete: `strategy-service/verify_algo_flow.py`
- Delete: `strategy-service/strategy_service/cli/__init__.py`
- Delete: `strategy-service/tests/hello`
- Preserve: all generated stubs, `generate_proto.sh`, `pyproject.toml`, `uv.lock`, `strategy_service/grpc_server.py`

**Interfaces:**
- Consumes: `pyproject.toml + uv.lock` dependency contract, `generate_proto.sh` order-proto generation, `hushine-session-worker` entry point.
- Produces: the same runtime-agent/session-worker imports and test count, without duplicate/dead files.

- [ ] **Step 1: Capture status and reconfirm zero active references**

Run from `strategy-service`:

```bash
git status --short -- requirements.txt generate_order_proto.sh verify_algo_flow.py strategy_service/cli/__init__.py tests/hello strategy_service/grpc_server.py
rg -n -F 'generate_order_proto.sh' . --hidden -g '!.git/**' -g '!docs/superpowers/**' -g '!census-runs/**'
rg -n -F 'verify_algo_flow.py' . --hidden -g '!.git/**' -g '!docs/superpowers/**' -g '!census-runs/**'
```

Expected: the five candidates are clean, `grpc_server.py` is already modified, and each reference scan finds only the candidate itself.

- [ ] **Step 2: Prove the replacement dependency and generation contracts**

```bash
uv lock --check
rg -n 'order_service\.proto|order_service_pb2_grpc\.py' generate_proto.sh
rg -n 'grpcio|psycopg2-binary|cryptography|kafka-python|PyYAML|opentelemetry' pyproject.toml
PYTHONPATH=.:../strategy-library uv run --frozen --extra dev python -c 'from strategy_service import session_worker_entry; from strategy_service.gen import order_service_pb2; print("imports-ok")'
```

Expected: lock check succeeds, generator/dependency scans find their replacements, and Python prints `imports-ok`.

- [ ] **Step 3: Run the pre-cleanup strategy-service baseline**

```bash
PYTHONPATH=.:../strategy-library uv run --frozen --extra dev pytest tests/ -q
go test ./...
bash scripts/start-bare-runtime-debugpy.test.sh
bash scripts/runtime-agent-platform.test.sh
```

Expected baseline: `464 passed`; all Go and shell commands exit 0.

- [ ] **Step 4: Delete only the five approved files**

Use `apply_patch` file deletions. Do not run proto generation, modify stubs, edit `pyproject.toml`, or touch the dirty `grpc_server.py`.

- [ ] **Step 5: Verify current entry points after deletion**

```bash
test ! -e requirements.txt
test ! -e generate_order_proto.sh
test ! -e verify_algo_flow.py
test ! -e strategy_service/cli/__init__.py
test ! -e tests/hello
uv lock --check
PYTHONPATH=.:../strategy-library uv run --frozen --extra dev python -c 'from strategy_service import session_worker_entry; from strategy_service.gen import order_service_pb2; print("imports-ok")'
PYTHONPATH=.:../strategy-library uv run --frozen --extra dev pytest tests/ -q
go test ./...
bash scripts/start-bare-runtime-debugpy.test.sh
bash scripts/runtime-agent-platform.test.sh
git diff --check
```

Expected: imports succeed, pytest remains `464 passed`, and every remaining command exits 0.

- [ ] **Step 6: Commit only the clean candidate deletions**

```bash
git add requirements.txt generate_order_proto.sh verify_algo_flow.py strategy_service/cli/__init__.py tests/hello
git diff --cached --check
git diff --cached --name-status
```

Expected staged names: exactly the five deletions. Commit:

```bash
git commit -m 'chore: 删除 strategy-service 零引用遗留文件'
```

---

### Task 4: Remove Root-Workspace Stale Current-State Entries

**Files:**
- Delete: `progress/roadmap.md`
- Delete: `scripts/audit/run_audit.sh`
- Modify: `Makefile:17,29,66-67`
- Preserve: `progress/discuss.md`, `docs/audit/**`, `hushine-deploy/scripts/audit/run_audit.sh`, `hushine-deploy/Makefile` audit target

**Interfaces:**
- Consumes: current Notion/feature-data-flow documentation, root `make test`, and code-census targets.
- Produces: no root `make audit` entry that deterministically invokes deleted tests; historical progress remains available.

- [ ] **Step 1: Demonstrate the root audit target is broken for the documented reason**

Run from the workspace root:

```bash
test ! -e strategy-library/tests/test_cross_margin.py
test ! -e strategy-library/tests/test_hedge_mode.py
rg -n 'test_cross_margin|test_hedge_mode|test_liquidation_risk|test_wallet_hierarchy|test_binance_wallet' scripts/audit/run_audit.sh
```

Expected: missing-test checks pass and the script scan shows obsolete test references.

- [ ] **Step 2: Delete the misleading roadmap and broken root audit script**

Delete `progress/roadmap.md` and `scripts/audit/run_audit.sh`. Keep the explicit historical `progress/discuss.md`.

- [ ] **Step 3: Remove only the root Makefile audit wiring**

Replace the root `.PHONY` declaration with the same current target list minus `audit`:

```make
.PHONY: build dev start stop clean test help ensure-dbs db-schema-bundle local-infra-up local-infra-down local-infra-reset local-infra-ps local-bootstrap local-ensure-dbs local-dev local-start local-stop runtime-image smoke-hosted-runtime smoke-self-hosted-runtime runtime-smoke-hosted runtime-smoke-self-hosted code-census-static code-census-snapshot code-census-session-start code-census-session-stop code-census-full
```

Delete:

```make
	@echo "  audit      — run hardening audit gate across compatibility / wallet / optional e2e"

audit:
	@bash scripts/audit/run_audit.sh all
```

Do not change `test` or any `code-census-*` target.

- [ ] **Step 4: Validate root entry-point cleanup**

```bash
test ! -e progress/roadmap.md
test ! -e scripts/audit/run_audit.sh
if rg -n 'scripts/audit/run_audit\.sh|^audit:' Makefile scripts --glob '!scripts/audit/census/**'; then exit 1; fi
make help
make -n test
test -e progress/discuss.md
```

Expected: stale files are absent, scans are empty, `make help` omits `audit`, and the test target still expands normally.

- [ ] **Step 5: Record the non-Git workspace checkpoint**

The root is not versioned, so do not invent a commit. Save the exact changed-file list in the final handoff and confirm that the nested repository statuses are unchanged by running:

```bash
for repo in core-service control-panel-service gateway/quant-handler gateway/quant-frontend scraper strategy-service strategy-library strategy-debugger-cli golang-lib hushine-deploy; do
  git -C "$repo" status --short
done
```

---

### Task 5: Replace Dated Architecture Guidance with a Canonical Current Guide

**Files:**
- Modify: `hushine-deploy/AGENTS.md`
- Modify: `AGENTS.md`
- Modify: `hushine-deploy/README.md`

**Interfaces:**
- Consumes: Notion's current feature boundary and the code-level `portfolio.v1`, `order.v1`, `controlpanel.v1`, RuntimeChannel, runtime-agent, and session-worker entry points.
- Produces: byte-identical root/deploy AGENTS guides and a current deploy repository overview.

- [ ] **Step 1: Replace the deploy AGENTS guide with the current contract**

Write a concise guide with these exact sections and facts:

```markdown
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
- Local user debugging uses strategy-debugger-cli offline replay; bare/debugger runtime is an internal guarded capability.
- environment=2 remains rollout-guarded.

## Build and Test
- Root orchestration: `make ensure-dbs`, `make build`, `make dev`, `make start`, `make stop`, `make test`.
- Go repositories: `go test ./...` and `go vet ./...` from each repository.
- strategy-service: `PYTHONPATH=.:../strategy-library uv run --frozen --extra dev pytest tests/ -q`, `go test ./...`, and both tracked shell tests.
- strategy-library and strategy-debugger-cli: run each repository's pytest suite in its managed environment.
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
```

Delete all April Stage/C3 snapshots and old `account.v1`, Python `:50053`, and `hushine-runtime` command descriptions. Do not copy historical rollout narratives into the new current guide.

- [ ] **Step 2: Synchronize the root AGENTS guide**

Apply the same content to root `AGENTS.md`, then verify:

```bash
cmp -s AGENTS.md hushine-deploy/AGENTS.md
```

Expected: exit 0.

- [ ] **Step 3: Correct the deploy README service and configuration facts**

Update the service table to state:

```markdown
| `core-service` | Go | HTTP `:18080` under `restart.sh`, gRPC `:50051`; serves `portfolio.v1` and `order.v1` |
| `strategy-service` | Go runtime-agent + Python session worker | connects outbound to RuntimeChannel `:50055`; no product `:50053` listener |
| `strategy-debugger-cli` | Python | local offline strategy import/replay and IDE debugging |
```

In Configuration, state that normal Go services use `config.yaml` log sections while scraper still uses `config.yaml` plus `log-config.json`. Remove the Chrome DevTools smoke link only in Task 7 when its target is deleted.

- [ ] **Step 4: Validate canonical terminology and commands**

```bash
cmp -s AGENTS.md hushine-deploy/AGENTS.md
if rg -n 'account\.v1|account_service\.proto|:50053|uv run hushine-runtime|run_grpc_server\.py' AGENTS.md hushine-deploy/AGENTS.md hushine-deploy/README.md; then exit 1; fi
rg -n 'portfolio\.v1|RuntimeChannel|runtime-agent|hushine-session-worker|strategy-debugger-cli' AGENTS.md hushine-deploy/AGENTS.md hushine-deploy/README.md
git -C hushine-deploy diff --check
```

Expected: obsolete scan is empty; every required current term is present.

- [ ] **Step 5: Commit only versioned documentation**

```bash
git -C hushine-deploy add AGENTS.md README.md
git -C hushine-deploy diff --cached --check
git -C hushine-deploy commit -m 'docs: 更新当前 Hushine 架构说明'
```

Root `AGENTS.md` remains an unversioned synchronized copy and must be listed in the final handoff.

---

### Task 6: Refresh Current Service README and Configuration Documentation

**Files:**
- Modify: `gateway/quant-frontend/README.md`
- Modify: `scraper/README.md`
- Modify: `strategy-library/README.md`
- Modify: `golang-lib/README.md`
- Modify: `golang-lib/docs/jaeger-deployment.md:202-233`
- Modify: `core-service/config.yaml:21-32` comments only

**Interfaces:**
- Consumes: actual package exports, configuration defaults, and current runtime commands.
- Produces: service documentation that matches the code without changing behavior or configuration values.

- [ ] **Step 1: Update quant-frontend README terminology and chart status**

Replace the opening description with:

```markdown
React 19 + Vite portal for Hushine. The application authenticates through quant-handler and exposes Quick Start, Portfolio, Venue, Strategy, Market Data, Runtime, Session, Order, Notification, and Profile workflows. Session charts are implemented with `lightweight-charts` under the current session-detail components.
```

Rename the wallet wizard check to `Manual UI check (Portfolio/Venue flow)` and describe creating a backtest Portfolio, creating/binding a Venue, opening Portfolio Detail, and checking the venue-backed snapshot. Keep existing build/configuration and responsive-layout rules.

Do not touch `src/features/charts/ChartsPlaceholder.tsx`.

- [ ] **Step 2: Rewrite scraper capability/default sections**

Document these exact facts:

```markdown
- Supported collectors include spot/futures K-line and order book, futures funding rate, and open interest.
- Funding rate is REST polling; open interest supports the current WebSocket path with REST fallback where configured.
- Static forward collectors are disabled by default in `config.yaml`; control-panel demand currently manages K-line streams.
- All current writes use `{exchange}_{year}` databases and symbol/interval tables.
- Finalized live K-lines may publish to Kafka when effective live delivery is enabled.
- Runtime logging is configured separately in `log-config.json`; repository defaults enable local files and disable Kafka.
- `docker compose up -d` is valid, but the external `app-logs-net` network and referenced infrastructure must already exist.
```

Remove the fixed “six data types/nine symbols are always collected” claim and the claim that logs never write local files.

- [ ] **Step 3: Rewrite strategy-library module and status sections**

Describe both compatibility/top-level modules and the published SDK:

```markdown
- `hushine_strategy.types`: strategy declarations, `OrderDecision`, enums and callbacks.
- `hushine_strategy.validator`: declaration/code validation shared by platform and local tooling.
- `hushine_strategy.replay`: deterministic local replay used by strategy-debugger-cli.
- `hushine_strategy.wallet`: strategy-visible wallet types/helpers; the production accounting runtime remains in strategy-service.
- `market_data`: backtest/live data models and readers.
- `algo`: indicators and bundles.
- `utils.log`: Python Elemental-compatible logging and tracing.
```

Delete the “wallet fully removed” and “real Broker order service not developed” claims. State that order execution belongs to core-service `order.v1`, not this library.

- [ ] **Step 4: Correct golang-lib README examples and inventory**

Remove nonexistent `py_log` from the current directory/component inventory. Replace the HTTP example with:

```go
req, err := http.NewRequestWithContext(ctx, http.MethodGet, url, nil)
if err != nil {
    return err
}
client := httpclient.New(http.DefaultClient, loggerAdapter, "binance")
resp, err := client.Do(ctx, req)
```

Replace the gRPC example with:

```go
grpcServer := grpc.NewServer(
    grpc.UnaryInterceptor(grpcmw.UnaryServerInterceptor(loggerAdapter)),
)
```

State Go `1.25.0`, matching `go.mod`.

- [ ] **Step 5: Correct the Jaeger strategy-runtime section**

Replace the deleted `hushine-runtime start`/`strategy_service.cli.hushine_runtime` description with the current split:

```markdown
The Go runtime-agent owns RuntimeChannel and launches one Python `hushine-session-worker` per session. Python tracing/logging initialization happens in the worker process before it serves local worker RPCs. Start the platform runtime with `make build` followed by `scripts/start-runtime-agent.sh -- --config ./config.yaml`; use `scripts/start-bare-runtime-debugpy.sh` for guarded local breakpoint debugging.
```

Keep the current tracer/interceptor file references that still exist.

- [ ] **Step 6: Correct only core-service config comments**

Replace lines 22-32 comments with:

```yaml
  # Demo/live exchange access uses the real adapter selected by the bound venue.
  # API credentials are stored and decrypted at the venue boundary; portfolios
  # do not carry a fallback exchange credential.
  mock_binance: false
  symbol_cache_ttl: "6h"

  # Asynchronous, non-blocking reconciliation for exchange-backed sessions.
  # Thresholds control hard/soft/advisory diff classification; configuration
  # values below are runtime defaults and are unchanged by documentation cleanup.
```

Do not change any YAML value.

- [ ] **Step 7: Run documentation and repository verification**

```bash
if rg -n 'future \*\*TradingView\*\*|真实 Broker 订单服务|httpclient\.NewClient|WithBaseURL|ServerInterceptor\(\)|Go\*\*: 1\.21|strategy_service/cli/hushine_runtime\.py' gateway/quant-frontend/README.md strategy-library/README.md golang-lib/README.md golang-lib/docs/jaeger-deployment.md; then exit 1; fi
git -C gateway/quant-frontend diff --check
git -C scraper diff --check
git -C strategy-library diff --check
git -C golang-lib diff --check
git -C core-service diff --check
npm --prefix gateway/quant-frontend run build
go -C scraper test ./...
PYTHONPATH=strategy-library strategy-library/.venv/bin/python -m pytest strategy-library/tests -q
go -C golang-lib test ./...
go -C core-service test ./...
```

Expected: obsolete scan is empty, all diff checks pass, frontend builds, and all repository tests exit 0.

- [ ] **Step 8: Commit each clean repository independently**

```bash
git -C gateway/quant-frontend add README.md
git -C gateway/quant-frontend commit -m 'docs: 更新前端功能说明'
git -C scraper add README.md
git -C scraper commit -m 'docs: 更新行情采集说明'
git -C strategy-library add README.md
git -C strategy-library commit -m 'docs: 更新策略库能力说明'
git -C golang-lib add README.md docs/jaeger-deployment.md
git -C golang-lib commit -m 'docs: 修正日志库使用示例'
git -C core-service add config.yaml
git -C core-service commit -m 'docs: 修正交易所配置注释'
```

Do not combine repositories into one commit.

---

### Task 7: Update Runtime and Deployment Instructions and Remove the Superseded UI Smoke Document

**Files:**
- Delete: `hushine-deploy/docs/chrome-devtools-smoke-test.md`
- Modify: `hushine-deploy/README.md`
- Modify: `hushine-deploy/docs/production-deploy-checklist.md`
- Modify: `hushine-deploy/docs/local-docker.md`
- Modify: `hushine-deploy/docs/runtime-operator-flow.md`
- Modify: `docs/local-docker.md`
- Modify: `docs/runtime-operator-flow.md`
- Modify: `docs/user-runbook.md`
- Modify: `docs/audit/coverage-audit-checklist.md`
- Modify: `hushine-deploy/docs/strategy-debugger-cli-smoke.md`
- Modify: `hushine-deploy/restart.sh`
- Modify: `hushine-deploy/scripts/restart-patterns.test.sh`
- Modify: `hushine-deploy/scripts/smoke_debugger_runtime.sh`
- Modify: `scripts/smoke_debugger_runtime.sh`

**Interfaces:**
- Consumes: `RUNTIME_CHANNEL_ADDR` used by `smoke_d3_self_hosted_runtime.sh`, Go runtime-agent launchers, bare debugpy launcher, Portfolio debug-dataset REST path.
- Produces: one canonical deploy implementation plus synchronized/root wrapper documentation; no removed CLI or product `:50053` instructions.

- [ ] **Step 1: Delete the superseded Chrome smoke guide and remove links**

Delete `hushine-deploy/docs/chrome-devtools-smoke-test.md`. Remove its bullet from deploy README. In production checklist, replace the deleted link paragraph with:

```markdown
UI smoke must cover the current Portfolio flow: login, Portfolio and Venue creation/binding, Strategy activation, executor Runtime selection, backtest start, Session Detail, Orders, Reconciliation, Market Data, and Notification Management. Record IDs and trace evidence using the current code-census session runbook; the command probes below are prerequisites, not a substitute for UI smoke.
```

- [ ] **Step 2: Remove obsolete listener and database claims from deploy checklist**

Use listener commands without `:50053`. Expected services are core `:50051`, control-panel `:50054/:50055/:8082`, handler `:8090`, and frontend `:5173`; strategy runtime connects outbound and has no product listener. Change database success text from `account` to `portfolio`. Update the E2E description to Portfolio/Venue and the assertions in Task 8.

- [ ] **Step 3: Fix self-hosted RuntimeChannel instructions in both doc copies**

Use this exact command in both local-docker docs:

```bash
CREDENTIAL_FILE=$HOME/.hushine/runtime.cred \
RUNTIME_CHANNEL_ADDR=host.docker.internal:50055 \
make smoke-self-hosted-runtime
```

Use `RUNTIME_CHANNEL_ADDR=$MAC_LAN_IP:50055` for remote Docker. In both runtime-operator docs, say `Portfolio Detail`, not `Account Detail`, and retain the legacy unbound-session fail-closed section.

After editing, require:

```bash
cmp -s docs/local-docker.md hushine-deploy/docs/local-docker.md
cmp -s docs/runtime-operator-flow.md hushine-deploy/docs/runtime-operator-flow.md
```

- [ ] **Step 4: Replace removed bare-runtime commands in user/audit docs**

Use this internal workflow instead of `uv run hushine-runtime`:

```bash
cd strategy-service
make build
DEBUG_WAIT=0 scripts/start-bare-runtime-debugpy.sh --user-id "$USER_ID" --platform-host "$PLATFORM_HOST"
```

Apply it to `docs/user-runbook.md`, the bare-runtime section of `docs/audit/coverage-audit-checklist.md`, and `hushine-deploy/docs/strategy-debugger-cli-smoke.md`. The debugger smoke doc must use Portfolio terminology, `market=perpetual_futures`, explicit `exchange`, and explicit `ORDER_TARGETS`.

- [ ] **Step 5: Update the dirty restart instruction with a matching test hunk**

Change only the existing bare-local message in `hushine-deploy/restart.sh` to:

```bash
echo "  Bare local: cd strategy-service && make build && DEBUG_WAIT=0 scripts/start-bare-runtime-debugpy.sh --user-id <users.id> --platform-host 127.0.0.1"
```

Change the exact expected literal in `scripts/restart-patterns.test.sh`. Preserve all other pre-existing `restart.sh` changes.

- [ ] **Step 6: Make deploy debugger smoke canonical and root a thin wrapper**

In deploy smoke script, rename `ACCOUNT_ID` to `PORTFOLIO_ID` and use this request:

```bash
curl -fsS \
  "${auth_header[@]}" \
  -X POST "${BASE_URL}/api/portfolios/${PORTFOLIO_ID}/debug-dataset" \
  -d "$(printf '{\"runtime_id\":\"%s\",\"market\":\"%s\",\"symbol\":\"%s\",\"interval\":\"%s\",\"start_time_ms\":%s,\"end_time_ms\":%s}' \
    "${RUNTIME_ID}" "${MARKET}" "${SYMBOL}" "${INTERVAL}" "${START_TIME_MS}" "${END_TIME_MS}")"
```

Replace the root copy with:

```bash
#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
exec bash "${ROOT}/hushine-deploy/scripts/smoke_debugger_runtime.sh" "$@"
```

- [ ] **Step 7: Validate runtime/deploy documentation and scripts**

```bash
test ! -e hushine-deploy/docs/chrome-devtools-smoke-test.md
cmp -s docs/local-docker.md hushine-deploy/docs/local-docker.md
cmp -s docs/runtime-operator-flow.md hushine-deploy/docs/runtime-operator-flow.md
bash -n scripts/smoke_debugger_runtime.sh
bash -n hushine-deploy/scripts/smoke_debugger_runtime.sh
bash hushine-deploy/scripts/restart-patterns.test.sh
if rg -n 'uv run hushine-runtime|/api/accounts|ACCOUNT_ID|:50053|chrome-devtools-smoke-test' docs/user-runbook.md docs/runtime-operator-flow.md docs/local-docker.md hushine-deploy/README.md hushine-deploy/docs/production-deploy-checklist.md hushine-deploy/docs/strategy-debugger-cli-smoke.md hushine-deploy/scripts/smoke_debugger_runtime.sh; then exit 1; fi
git -C hushine-deploy diff --check
```

Expected: all comparisons/tests pass and obsolete scan is empty.

- [ ] **Step 8: Stage only owned deploy hunks and commit**

```bash
git -C hushine-deploy add README.md docs/chrome-devtools-smoke-test.md docs/production-deploy-checklist.md docs/local-docker.md docs/runtime-operator-flow.md docs/strategy-debugger-cli-smoke.md scripts/restart-patterns.test.sh scripts/smoke_debugger_runtime.sh
git -C hushine-deploy add -p restart.sh
git -C hushine-deploy diff --cached --check
git -C hushine-deploy diff --cached -- restart.sh
git -C hushine-deploy commit -m 'docs: 更新 Runtime 与部署操作说明'
```

Stage only the single restart instruction hunk. Root synchronized docs/wrapper remain unversioned and must appear in the final handoff.

---

### Task 8: Migrate the Canonical Full-Flow E2E to Portfolio/Venue

**Files:**
- Modify: `hushine-deploy/scripts/e2e_full_flow.sh`
- Modify: `hushine-deploy/scripts/e2e-runtime-channel-cutover.test.sh`
- Preserve: root `scripts/e2e_full_flow.sh` thin wrapper

**Interfaces:**
- Consumes: current BFF `/api/portfolios`, `/api/venues`, Portfolio strategy mount/activate/run endpoints, `portfolio.v1`, order `portfolio_id`, and `portfolio_snapshots`.
- Produces: the same hosted RuntimeChannel backtest smoke using current API/schema names.

- [ ] **Step 1: Strengthen the static cutover test before changing the E2E**

Add these entries to `required_literals`:

```bash
'/api/portfolios'
'/api/venues'
'portfolio_service_grpc:'
'portfolio_snapshots'
'i.portfolio_id'
```

Add these entries to the forbidden-literal loop:

```bash
'/api/accounts'
'account_service_grpc:'
'account_service_pb2'
'account_snapshots'
'i.account_id'
```

Run:

```bash
bash scripts/e2e-runtime-channel-cutover.test.sh
```

Expected: FAIL because the current E2E still contains Account-era literals.

- [ ] **Step 2: Migrate configuration and readiness probe names**

Use `PORTFOLIO_DB_NAME="${E2E_PORTFOLIO_DB:-portfolio}"`, `CORE_HTTP`, and `CORE_GRPC`. Point core `TIMESCALEDB_DSN` at the portfolio DB. In generated control-panel config use:

```yaml
dependencies:
  portfolio_service_grpc: "127.0.0.1:${CORE_GRPC}"
  order_service_grpc: "127.0.0.1:${CORE_GRPC}"
```

Probe `GET /api/portfolios`, and describe the core process as `portfolio.v1 + order.v1`.

- [ ] **Step 3: Replace Account creation and direct wallet RPC with Portfolio + Venue REST creation**

Create the Portfolio:

```bash
PORTFOLIO_RESP=$(curl -s -X POST "${API}/api/portfolios" \
  -H "$AUTH" -H 'Content-Type: application/json' \
  -d '{"name":"e2e-full-flow","description":"E2E portfolio context","environment":0}')
PORTFOLIO_ID=$(echo "$PORTFOLIO_RESP" | jq -r '.portfolio_id')
```

Create and bind the backtest Venue in the same request:

```bash
VENUE_RESP=$(curl -s -X POST "${API}/api/venues" \
  -H "$AUTH" -H 'Content-Type: application/json' \
  -d "{
    \"portfolio_id\": ${PORTFOLIO_ID},
    \"exchange\": \"binance\",
    \"market\": \"perpetual_futures\",
    \"environment\": \"backtest\",
    \"status\": \"active\",
    \"display_name\": \"e2e-binance-futures\",
    \"margin_mode\": \"cross\",
    \"position_mode\": \"one_way\",
    \"futures\": {
      \"margin_mode\": \"cross\",
      \"position_mode\": \"one_way\",
      \"initial_balance\": 10000,
      \"positions\": [{
        \"symbol\": \"TESTUSDT\",
        \"direction\": 0,
        \"initial_balance\": 10000,
        \"leverage\": 20,
        \"fee_rate\": 0.0004
      }]
    }
  }")
VENUE_ID=$(echo "$VENUE_RESP" | jq -r '.venue_id')
```

Delete the complete Python `account_service_pb2`/`UpdateAccountWalletState` block; the Venue bootstrap replaces it.

- [ ] **Step 4: Migrate strategy mount, list, and run endpoints**

Use these concrete requests:

```bash
MOUNT_RESP=$(curl -s -X POST "${API}/api/portfolios/${PORTFOLIO_ID}/strategies/${STRATEGY_ID}" -H "$AUTH")
ACTIVATE_RESP=$(curl -s -X POST "${API}/api/portfolios/${PORTFOLIO_ID}/strategies/${STRATEGY_ID}/activate" -H "$AUTH")
PORTFOLIO_STRATEGIES=$(curl -s "${API}/api/portfolios/${PORTFOLIO_ID}/strategies" -H "$AUTH")
RUN_RESP=$(curl -s -X POST "${API}/api/portfolios/${PORTFOLIO_ID}/run-strategy" \
  -H "$AUTH" -H 'Content-Type: application/json' \
  -d "{\"strategy_path\":\"\",\"interval\":\"1m\",\"start_time_ms\":1735689600000,\"end_time_ms\":1735701600000,\"runtime_id\":\"${RUNTIME_ID}\"}")
```

Keep explicit `runtime_id`, time bounds, hosted runtime provisioning, and session polling unchanged.

- [ ] **Step 5: Migrate DB verification to current schema**

Order query and JSON keys must use `i.portfolio_id`. Snapshot verification must query:

```sql
SELECT COUNT(*)
FROM portfolio_snapshots
WHERE portfolio_id = %s AND strategy_id = %s AND session_id = %s;
```

Session verification must select `portfolio_id, strategy_id, status, bars_processed` from `strategy_sessions`. Rename shell/JQ variables and messages from `ACCOUNT_*`/`acct` to `PORTFOLIO_*`/`portfolio`.

- [ ] **Step 6: Run static E2E contract tests**

```bash
bash -n scripts/e2e_full_flow.sh
bash scripts/e2e-runtime-channel-cutover.test.sh
if rg -n '/api/accounts|account_service_grpc|account_service_pb2|account_snapshots|i\.account_id|ACCOUNT_ID' scripts/e2e_full_flow.sh; then exit 1; fi
rg -n '/api/portfolios|/api/venues|portfolio_service_grpc|portfolio_snapshots|i\.portfolio_id|PORTFOLIO_ID' scripts/e2e_full_flow.sh
```

Expected: syntax and cutover tests pass, obsolete scan is empty, and current terms are present.

- [ ] **Step 7: Run the infra-backed E2E when prerequisites are available**

```bash
bash scripts/e2e_full_flow.sh
```

Expected: Portfolio and Venue creation succeed, hosted runtime becomes active, the backtest finishes with 200 bars, order fills carry the correct `portfolio_id`, and `portfolio_snapshots`/`strategy_sessions` assertions pass. If Docker or shared infrastructure is unavailable, record the exact prerequisite failure and retain the passing static cutover test as the required local gate.

- [ ] **Step 8: Commit the canonical E2E migration**

```bash
git add scripts/e2e_full_flow.sh scripts/e2e-runtime-channel-cutover.test.sh
git diff --cached --check
git commit -m 'test: 迁移全链路 E2E 到 Portfolio'
```

---

### Task 9: Run Full Regression, Stale-Term Scan, and Final Scope Audit

**Files:**
- Verify all files modified or deleted in Tasks 1-8
- Do not create additional behavior changes while resolving verification output

**Interfaces:**
- Consumes: all repository-scoped cleanup deliverables.
- Produces: an evidence-backed final report of removals, preserved features, tests, baseline failures, and deferred contract candidates.

- [ ] **Step 1: Re-run all deletion and synchronization assertions**

```bash
test ! -e progress/roadmap.md
test ! -e scripts/audit/run_audit.sh
test ! -e hushine-deploy/docs/chrome-devtools-smoke-test.md
test ! -e scraper/internal/logger/vendor
test ! -e strategy-service/requirements.txt
test ! -e strategy-service/generate_order_proto.sh
test ! -e strategy-service/verify_algo_flow.py
test ! -e strategy-service/strategy_service/cli/__init__.py
test ! -e strategy-service/tests/hello
cmp -s AGENTS.md hushine-deploy/AGENTS.md
cmp -s docs/runtime-operator-flow.md hushine-deploy/docs/runtime-operator-flow.md
cmp -s docs/local-docker.md hushine-deploy/docs/local-docker.md
```

Expected: every assertion exits 0.

- [ ] **Step 2: Scan only current-state surfaces for stale product instructions**

```bash
if rg -n 'uv run hushine-runtime|/api/accounts|account_service_grpc|account_snapshots|:50053|handleResolveRuntimeRoute|internal/logger/vendor' \
  AGENTS.md docs/user-runbook.md docs/runtime-operator-flow.md docs/local-docker.md \
  hushine-deploy/AGENTS.md hushine-deploy/README.md hushine-deploy/docs/production-deploy-checklist.md \
  hushine-deploy/scripts/e2e_full_flow.sh hushine-deploy/scripts/smoke_debugger_runtime.sh \
  gateway/quant-handler/README.md gateway/quant-handler/internal/app \
  scraper/Dockerfile scraper/README.md; then exit 1; fi
```

Expected: no output. Do not scan archives, dated audits, migration compatibility docs, or approved design history with this gate.

- [ ] **Step 3: Run Go repository tests and vet**

```bash
go -C core-service test ./...
go -C core-service vet ./...
go -C control-panel-service test ./...
go -C control-panel-service vet ./...
go -C gateway/quant-handler test ./...
go -C gateway/quant-handler vet ./...
go -C scraper test ./...
go -C scraper vet ./...
go -C golang-lib test ./...
go -C golang-lib vet ./...
```

Expected: all commands exit 0.

- [ ] **Step 4: Run Python repository tests**

```bash
cd strategy-service
PYTHONPATH=.:../strategy-library uv run --frozen --extra dev pytest tests/ -q
go test ./...
bash scripts/start-bare-runtime-debugpy.test.sh
bash scripts/runtime-agent-platform.test.sh

cd ../strategy-library
PYTHONPATH=. .venv/bin/python -m pytest tests/ -q

cd ../strategy-debugger-cli
.venv/bin/python -m pytest tests/ -q
```

Expected baseline: strategy-service `464 passed`, strategy-library `223 passed`, debugger CLI `39 passed`; Go and shell tests exit 0.

- [ ] **Step 5: Run frontend build and every tracked script test**

```bash
cd gateway/quant-frontend
npm run build
for test_file in scripts/*.test.mjs; do node "$test_file"; done
```

Expected: build exits 0 and all 34 script tests pass.

- [ ] **Step 6: Run deploy/root script gates and OpenSpec validation**

```bash
bash hushine-deploy/scripts/e2e-runtime-channel-cutover.test.sh
bash hushine-deploy/scripts/restart-patterns.test.sh
bash scripts/self-hosted-runtime-script.test.sh
openspec validate --all --strict --no-interactive
```

Expected: E2E cutover, restart patterns, and all 39 strict OpenSpec validations pass. The self-hosted script test had a known pre-cleanup baseline failure around the credential-path literal; compare its exact output and require no new failure. If the baseline issue is still present, report it rather than changing unrelated runtime behavior.

- [ ] **Step 7: Audit every Git repository for accidental staging or unrelated edits**

For each nested repository, run:

```bash
git status --short
git diff --check
git diff --cached --check
```

Expected: no accidental staged files; every change maps to an approved task or the recorded pre-existing baseline. Never clean unrelated user changes.

- [ ] **Step 8: Write the final handoff**

Report:

1. Deleted files/directories and the evidence that made each deletion safe.
2. A per-file deletion ledger with three numeric columns: whole-file lines deleted, lines removed from retained files, and total removed lines.
3. A grand total of removed lines. Compute Git-repository counts only from this cleanup's implementation commits (`git show --numstat`); compute root non-Git counts from the captured pre-edit contents versus final contents. Exclude pre-existing dirty hunks, generated caches, design/plan additions, and newly added documentation lines.
4. Documentation rewritten and the current architecture it now describes.
5. Notion-defined features explicitly preserved.
6. Repository test/build commands with actual pass counts and any unchanged baseline failure.
7. Commits created per repository.
8. Root non-Git files changed.
9. Deferred candidates: four RPC surfaces, old DataLoop exports, StartDebugReplay compatibility, deploy-local audit target, and hybrid code-census coverage.

Do not claim the cleanup is complete until every required local gate above has an observed result.
