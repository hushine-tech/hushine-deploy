# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Quantitative cryptocurrency trading platform (codename **Hushine**). Monorepo with Go microservices, a Python strategy engine, and a React frontend. All services use TimescaleDB for storage and communicate via gRPC. Logs flow through Kafka → Elasticsearch via a shared `golang-lib` logging framework (internally called **Elemental**).

Language: Chinese is the working language for comments, docs, and commit messages.

## Project Stage

**Current: Stage 1 complete; `Phase C / C3` closed. The next main phase is product iteration around remote debug mode and strategy authoring.**

- **Stage 1 (complete)** — End-to-end happy path: `quant-frontend` → `quant-handler` → `core-service` (`account.v1` + `order.v1`) → `strategy-service` → back. Backtests run, orders flow through the core-service order module, wallets update through the full chain.
- **Stage 2 (active)** — Wallet/account hardening for exchange-backed modes.
  - `Phase A` (core-service exchange adapter): complete and archived.
  - `Phase B1/B2/B3` (strategy-service): complete. Runtime split, strict canonical contract, backtest bootstrap, metadata-backed risk fields, futures open-order lifecycle, ledger events, isolated-wallet/break-even parity, spot locked lifecycle, unsupported Binance margin modes fail-closed.
  - `mode=0` and `mode=2` share `BinanceWalletRuntime`; `mode=1` remains intentionally fail-closed.
- **Stage 2 priorities from here**, in recommended order:
  1. **Phase D — Remote debug / strategy authoring**: D1 hosted runtime control plane complete (2026-05-04, 41/41); D2 market-data control-plane migration code-side 52/53 (2026-05-06 — sections 1-9 + 10.1-10.6 done; 10.7 operator manual smoke pending); D3 self-hosted RuntimeChannel/proxy code + docs are complete except operator smoke (2026-05-11, 34/36; remaining 4.5 and 8.4); D4 (IDE breakpoint debugging) not specced. See "Phase D Snapshot" below.
  2. **Partial-fill / execution-state hardening** — half-filled orders, fill-pending, rejections, insufficient margin, rate limits, network timeouts, rollback/blocking semantics.
  3. **Reconciliation follow-up observation** — keep collecting `mode=2` samples (break-even advisory drift, funding-fee wallet movement at settlement times). No longer a C3 gate.
  4. **Session lifecycle hardening** — `Stop + close positions` still needs real implementation.
  5. **Real-time market data pipeline** — scraper → Kafka → strategy-service live loop, end-to-end Kafka session not yet proven.
- **Later** — OKX exchange, broader user-facing features, multi-user, production live-mode rollout.

**Rule of thumb**: tasks in the "later" bucket should usually wait for Stage 2 to land. Adding features to an unhardened core is the main failure pattern for early quant platforms.

## Current Working Snapshot (2026-05-16)

Use this section as the first source of truth before starting the next requirement.

### Process documentation location

`/Users/xdy/Workplace/hushine` is the coordination workspace, not a code repository. Keep process documents at this root level:

- Root OpenSpec: `/Users/xdy/Workplace/hushine/openspec`
- Root Superpowers docs/plans: `/Users/xdy/Workplace/hushine/docs/superpowers`

Child repository OpenSpec folders were moved out of the code repositories and archived under:

- `/Users/xdy/Workplace/hushine-doc-archive/2026-05-16-openspec-superpowers-115238`

Do not recreate `openspec/` inside child code repositories such as `core-service`, `strategy-service`, `gateway/quant-handler`, or `gateway/quant-frontend` unless explicitly requested. Child repositories ignore `/openspec/`.

### Runtime identity and routing state

The runtime management/session binding work has been implemented in code, but its OpenSpec task files were archived before formal closeout.

Current intended model:

- `runtime_id` is the routing identity. Route resolution, session start, status, stop, resume, recovery, and RuntimeChannel proxying must use `user_id + runtime_id`.
- Runtime `name` is a user-visible label only. It must not be used as routing authority.
- Runtime names are unique per user, including ended runtimes, to avoid human mis-selection.
- `runtime_registry.service_name` has been migrated to `name`.
- Runtime lifecycle uses terminal `ended`, with `ended_at` and `ended_reason`.
- Strategy sessions persist runtime binding and runtime-originated updates must match the owning `runtime_id`.
- Account/session UI surfaces the selected runtime and links to Runtime Management.

Recent verification before document archive included:

- `control-panel-service`: `go test ./...`
- `gateway/quant-handler`: `go test ./...`
- `strategy-service`: targeted runtime-channel/platform-proxy/grpc tests
- `gateway/quant-frontend`: `npm run build`

Manual hosted+self-hosted smoke was partially exercised during local testing but the archived OpenSpec changes were not formally archived.

### Local stack status and fixes

`restart.sh` is the current local startup entrypoint. It starts core-service, control-panel-service, strategy-service, scraper, quant-handler, and quant-frontend against third-party dependencies on `192.168.88.10`. `order.v1` is served by core-service; `restart.sh` only cleans legacy `50052` listeners and does not start an independent order-service.

Important fixes already applied:

- `gateway/quant-frontend/Makefile` starts `vite preview` with `stdin=subprocess.DEVNULL` and `--strictPort`, preventing detached Node/Vite `read EIO` crashes.
- `control-panel-service/cmd/ensure-control-panel-db` now checks `schema_migrations` and skips already-applied migrations. This prevents replaying old migrations after `runtime_registry.service_name` was renamed to `name`.
- Child `.gitignore` files ignore `/openspec/` so process docs stay out of code repositories.

### Known next runtime gap

Hosted runtime cleanup is not fully correct yet.

Observed case:

- Runtime `rt-73a4970541c126a089b9bd86` was marked `ended` with `ended_reason=heartbeat_stale`.
- The local Docker container `hushine-runtime-rt-73a4970541c126a089b9bd86` kept running until manually removed.

Preferred design for the next fix:

- The primary path should be protocol-driven: when a hosted runtime heartbeats and control-panel sees its row is already `ended`, the heartbeat response/error must be treated as terminal by the runtime.
- The runtime should then stop its heartbeat loop, stop the gRPC server, and exit the process so Docker naturally stops.
- Transient heartbeat errors such as `Unavailable` / `DeadlineExceeded` should continue retrying.
- Terminal errors such as `runtime ended`, `NotFound`, `PermissionDenied`, or token mismatch should fail closed and terminate the runtime process.
- A later reconcile/cleanup path may remove already-exited or long-dead hosted containers, but Docker `rm -f` should not be the primary mechanism when the runtime is still able to communicate.

## Phase D Snapshot (D1 complete; D2 code-side complete; D3 code/docs complete pending smoke)

Phase D (runtime control plane / 用户隔离 / 容器化调试). Each phase = one OpenSpec change; journey log in `progress/phase-d-runtime-control-plane.md`.

| Phase | Topic | OpenSpec change | Status |
|---|---|---|---|
| **D1** | Hosted-only runtime control plane | `phase-d1-runtime-control-plane` | Complete (41/41) |
| **D2** | Market data control-plane migration out of `core-service` | `phase-d2-marketdata-control-plane` | **Code-side complete (52/53, 2026-05-06)** — sections 1-9 + 10.1-10.6 done; 10.7 operator manual smoke pending |
| **D3** | Self-hosted runtime ingress (RuntimeChannel + credentials + control-plane proxy) | `phase-d3-self-hosted-runtime` | **Code/docs complete except manual smoke (34/36, 2026-05-11)** — remaining: UI-downloaded credential + self-hosted mode=0 backtest, and remote/NAT-bound Docker runtime smoke |
| **D4** | IDE breakpoint debugging | not yet specced | depends on D3 |

### D1 architecture as shipped

`control-panel-service` is the new Go microservice (HTTP `:8082`, gRPC `:50054`, RuntimeChannel gRPC `:50055`, DB `control_panel` on TimescaleDB).

- handler → control-panel `EnsureHostedRuntime` → DockerProvisioner runs `docker run -d` → strategy-runtime container starts → opens RuntimeChannel on `:50055` → first heartbeat flips to `active` → control-panel proxies strategy RPCs over the stream.
- hosted, self-hosted, and bare debug runtimes all use RuntimeChannel. Handler no longer dials strategy runtimes directly.
- Strategy RPCs Run/Preview use `Ensure` (lazy provision); Status/Stop use `Resolve` (read-only).
- Fail-closed throughout (NotFound / ResourceExhausted / Unhealthy / RegistrationTimeout / ProvisionerUnavailable surface as typed gRPC errors).
- D3 removed the D1 pairing scaffold (`PairRuntime`, `runtime_pairings`, pairing-code helpers). `RegisterRuntime` is hosted-only; self-hosted admission is signed RuntimeChannel HELLO with a user runtime credential.

### D3 local smoke defaults

`restart.sh` now starts all app services, including `control-panel-service`, against third-party dependencies on `192.168.88.10`. For local D3 smoke, `config.local.yaml` uses DockerProvisioner (`bridge` + `host.docker.internal`) and quant-handler points `dependencies.control_panel_service_grpc` at control-panel-service.

Smoke helpers:
- `USER_ID=<id> scripts/smoke_d3_hosted_runtime.sh` starts/proves the default hosted Docker runtime path.
- `CREDENTIAL_FILE=... RUNTIME_CHANNEL_ADDR=<mac-lan-ip>:50055 REMOTE_HOST=192.168.88.10 REMOTE_USER=hushine-tech SYNC_IMAGE=1 scripts/smoke_d3_self_hosted_runtime.sh` starts a remote self-hosted runtime that simulates a user's Docker runtime.

### D1 design decisions (in `design.md`)

- **D1 is hosted-only**; self-hosted moved to D3 because NAT-bound deployments require a runtime-initiated channel.
- **handler→runtime network access was removed after D3**; control-panel is now in the strategy RPC data path for hosted, self-hosted, and bare runtimes.
- **handler↔control-panel trusts internal network** (no service-level token in D1; D3's mTLS replaces the trust boundary anyway).
- `users.plan_code` lives in `account` DB; control-panel reads via `core-service.GetUser` RPC.
- Hosted default runtime is **lazy** — created on first strategy run, not eagerly at user creation.
- Runtime auth in D1 used gRPC metadata tokens; current runtime admission is RuntimeChannel HELLO verification.
- Runtime plans are config-file-driven (`runtime_plans:` in `control-panel-service/config.yaml`); debug default `pro`. Plan/platform limits use `0=forbid, -1=unlimited, >0=real cap`.

### D2 progress (code-side complete 2026-05-06, 46/53)

Migrates the **market-data control plane** (4 tables + 10 RPCs) out of `core-service` into `control-panel-service`. Hard-cut migration; 3 callers (scraper, quant-handler, strategy-service) flip in the same PR.

**Done (sections 1–9, 46 tasks):**
- Schema: migrations `0003-0006_*.sql` in `control-panel-service/internal/storage/migrations/`. Cross-DB FK to `account.users(id)` dropped — documented as known orphan-on-delete behavior change (S1 review fix); revisit when a real user-deletion path lands.
- Proto: `proto/marketdata_service.proto`, package `controlpanel.marketdata.v1`, 10 RPCs + 5 message types, field numbers preserved from `account.v1`.
- Package reorg: `internal/service/` → `internal/runtime/`; new `internal/marketdata/` subdomain (service + repository + `activeLeaseCount` helper that documents the swallow). Single shared `*sql.DB` pool via `repository.TimescaleRepository.DB()`. 22 unit tests cover all 10 RPCs.
- `cmd/control-panel-service/main.go` registers both runtime + marketdata services on `:50054`.
- Migration tool `scripts/migrate_market_data/main.go` — idempotent per-row INSERT + `ON CONFLICT DO NOTHING`, row-count parity check, automatic `setval()` resync of all 3 BIGSERIAL sequences (M1 review fix), `pg_dump` warning + 5s pause.
- Scraper repointed: `accountv1.AccountServiceClient` → `mdv1.MarketDataControlPlaneServiceClient`; config `account_service_grpc` → `market_data_control_panel_grpc`; default `127.0.0.1:50051` → `127.0.0.1:50054`. `go.mod` replace flipped from core-service to control-panel-service.
- quant-handler repointed: `s.accounts.X` → `s.marketData.X`; `handleMarketData` returns 503 if `s.marketData == nil`. Test fake renamed `fakeAccountsClient` → `fakeMarketDataClient` (S3 review fix).
- strategy-service split: new `marketdata_client.py` with the 3 RPCs strategy-service actually calls (`GetMarketDataStreamStatus`, `CreateOrRenewMarketDataLease`, `ReleaseMarketDataLease`); `account_client.py` slimmed; `grpc_server.py` rewired with new constructor param `market_data_control_panel_addr` and a `MarketDataClient` per `RunStrategy`/`PreviewRunStrategy` invocation; `config.py` adds `dependencies.market_data_control_panel_grpc` with auto-fallback to `control_panel_service_grpc`. 3 tests updated (`monkeypatch.setattr(grpc_server, "MarketDataClient", FakeMarketDataClient)`).
- core-service cleanup: migration `0012_drop_market_data_control_plane.sql` (CASCADE drop on all 4 tables); 10 RPCs + 5 message types removed from `account_service.proto`; `grpc_market_data.go` / `market_data_control_plane.go` / `market_data_history.go` deleted; `Repository` interface block trimmed; ~22 stub methods removed from `grpc_account_meta_test.go` and `tests/repository_test.go`; marketdata domain types removed from `internal/domain/model.go`. Historical migrations `0009`/`0010` deleted.
- Docs: `db/README.md` table-ownership move; control-panel `README.md` extended with the 7-step D2 cutover sequence (`pg_dump` → migrate-script → flip callers → drop source); this snapshot + `progress/phase-d-runtime-control-plane.md` updated.

**Remaining (section 10, 7 tasks):**
- Cross-service `go test ./...` for all 5 Go services + `pytest tests/` for strategy-service (must remain green); `openspec validate phase-d2-marketdata-control-plane`; operator-driven full-stack smoke (scraper reconcile loop, mode=2 preflight + lease, frontend market-data CRUD).

**Key D2 decisions**: destination is `control-panel-service` (not a third service); hard cut, no transition window; cross-DB FKs become service-layer logical references; operator runs migration once after `pg_dump`; subdomain `internal/marketdata/` parallels `internal/runtime/`; shared `*sql.DB` pool; proto field numbers preserved.

**Review fixes landed (2026-05-05, before sections 7-10)**: M1 sequence resync automated; S1 FK semantics documented in migrations 0004/0005/0006; S2 lease-TTL comment matches code (clamp, not reject); S3 test fake renamed; S4 `CountActiveLeasesForStream` swallow consolidated into a single documented helper.

### D3 design review (2026-05-06)

D3 (`phase-d3-self-hosted-runtime`) was specced 2026-05-03 and sat at 0/34 awaiting implementation. Pre-implementation design review surfaced 6 issues that needed answering before any code, formalized as `phase-d3-self-hosted-runtime-design-fixes`:

- **C1** — Decision 4 (runtime caller token removal) and Decision 6 (hosted migrate to stream model, gated) were in tension. The current runtime cutover uses RuntimeChannel for hosted too.
- **C2** — RuntimeChannel had no wire format. **Fix**: `RuntimeFrame` envelope + 7-value `FrameType` enum (`HELLO`/`REQUEST`/`RESPONSE`/`PROGRESS`/`ABORT`/`HEARTBEAT`/`ERROR`) + `deadline_unix_ms` propagation (gRPC deadlines don't auto-cross multiplexed streams) + disconnect semantics (proxy fails Unavailable + runtime aborts execution to prevent phantom sessions) + 30s/90s heartbeat (matches D1 lease cadence).
- **C3** — Decision 8 (revocation) didn't specify stream-registry indexing. **Fix**: double-index `runtime_id → *stream` + `key_id → set<runtime_id>`, both maintained at open/close. Revocation is O(1) average.
- **C4** — D2 had a 7-step operator rollout doc; D3 was missing the equivalent. **Fix**: explicit task to add "D3 self-hosted runtime onboarding" section to `control-panel-service/README.md`.
- **C5** — `strategy-runtime` no longer has an inbound/outbound switch. Runtime startup is RuntimeChannel-only.
- **C6** — Credential file contract was underspecified. **Fix**: default mount path `/etc/hushine/runtime.cred` (override via `RUNTIME_CREDENTIAL_PATH`), permission `0600` (warn-not-reject for CI compat), schema `{version: 1, key_id, private_key_pem}` with reserved `version`, fail-closed startup on missing/malformed.

C7 (phishing scenario polish) and C8 (per-session attestation re-entry note) intentionally informational, not in the proposal.

### D3 current outcome (2026-05-11)

- Runtime credentials: UI/handler/control-panel issue/list/revoke flow; private key returned once; runtime credential file contract is `/etc/hushine/runtime.cred` with `version/key_id/private_key_pem`.
- RuntimeChannel: signed HELLO, replay protection, double-index stream registry, heartbeat, disconnect abort semantics, request multiplexing and deadline propagation.
- Strategy runtime: RuntimeChannel-only; no public strategy gRPC port or ingress mode switch.
- Handler: all strategy session RPCs go through control-panel strategy proxy RPCs with no silent fallback.
- D1 scaffold removed: `PairRuntime` proto/RPC and `runtime_pairings` final table are gone; historical migration `0002` remains replayable and `0009_drop_runtime_pairings.sql` drops the table.
- Docs: `control-panel-service/README.md` has D3 onboarding and threat-model review; `db/README.md` records `runtime_credentials`.
- Verification run so far: `control-panel-service go test ./...`, `quant-handler go test ./...`, and strategy-service targeted D3 runtime tests. Manual cross-service self-hosted smoke remains pending until services/credential/remote runtime are started.

## Service Map

```
quant-frontend (React :5173)
    → quant-handler (Go BFF :8090, JWT auth)
        → core-service (gRPC :50051, HTTP :8080)
            → account.v1 (account/session/wallet APIs)
            → order.v1 (order placement/query APIs)
            → TimescaleDB (account DB)
            → TimescaleDB (order DB)
            → Binance REST API (live/testnet)
        → control-panel-service (gRPC :50054, RuntimeChannel :50055)
              EnsureHostedRuntime / ResolveRuntimeRoute / RuntimeChannel proxy

control-panel-service (Go gRPC :50054, RuntimeChannel gRPC :50055, HTTP :8082)
    → TimescaleDB (control_panel DB)
    → core-service (gRPC, GetUser → users.plan_code)
    → docker daemon (DockerProvisioner via os/exec)
    Owns runtime registry / route resolution / per-user plan/quota /
    hosted runtime provisioning / RuntimeChannel admission.

scraper (Go)
    → Binance REST + WebSocket
    → TimescaleDB ({exchange}_{year} market-data DBs)
    → control-panel-service (gRPC :50054, market-data control plane after D2)
    → Kafka market data topics (live delivery when streams are active)

strategy-service / strategy-runtime (Python gRPC :50053)
    → TimescaleDB (backtest reads)
    → core-service (gRPC, wallet sync)
    → core-service/order.v1 (gRPC, place/cancel/query orders)
    → control-panel-service (gRPC, RegisterRuntime + Heartbeat +
       ValidateCallerToken, when RUNTIME_REGISTER_WITH_CONTROL_PANEL=1)
    → [Stage 2] Kafka live data via LiveDataLoop (consumer/session path not production-proven)
    Phase D1: ships as `hushine/strategy-runtime:dev` container image;
    self-registers, heartbeats, runs CallerTokenInterceptor at server
    level; bound to one user_id at registration.

core-service/internal/order
    → TimescaleDB (order history / fills)
    → core-service repository via in-process adapter
    → [Stage 2] Binance / testnet REST for real order placement
```

## Build & Run Commands

Each backend service has `config.yaml` with development defaults. Env vars override fields (`<SECTION>_<KEY>` convention, plus selected shorthand names like `CORE_SERVICE_GRPC_ADDR` and `QUANT_HANDLER_JWT_SECRET`).

### Root Makefile
```bash
make ensure-dbs  # create all DBs + migrations — fresh-deploy first step
make dev         # run all backend services in foreground
make build       # compile all Go services to <service>/bin/
make start       # build + start all services in background (logs in <service>/logs/)
make stop        # stop background services
make test        # run tests in all services
```

### Per-service
Each service Makefile has: `build`, `dev`, `start`, `stop`, `test`, `clean`.

```bash
cd core-service
make proto              # → gen/accountv1/
make ensure-db          # create TimescaleDB schema
make test-integration   # requires TimescaleDB
make dev                # go run ./cmd/core-service -config ./config.yaml
```

```bash
cd control-panel-service        # Phase D1
make proto              # → gen/controlpanelv1/
make ensure-db          # create control_panel DB + apply migrations
make dev                # go run ./cmd/control-panel-service -config ./config.yaml
make test               # unit tests (auth / plan / service)
```

```bash
cd strategy-service
pip install -r requirements.txt
./generate_proto.sh
make dev                                # PYTHONPATH=... python run_grpc_server.py -config config.yaml
pytest tests/                           # all
pytest tests/test_strategy_engine.py    # single
```

Backtests run through the gRPC `RunStrategy` call (the production path); legacy `run_backtest.py` / `run_debug.py` / `backtest_runner.py` were removed in Phase C2b.

```bash
cd scraper
go build -o bin/scraper ./cmd/scraper
go run ./cmd/scraper          # uses scraper config.yaml
docker compose up -d
```

```bash
cd gateway/quant-frontend
npm install
npm run dev       # :5173, proxies VITE_API_BASE_URL (default http://localhost:8090)
npm run build     # type-check + production build
```

```bash
cd strategy-library                # Python, not standalone (symlinked into strategy-service)
pip install -r algo/requirements.txt
pytest tests/
```

```bash
cd golang-lib                      # Go shared library
go test ./...
go test -race ./...
go run ./examples/e2e-all-types/main.go
```

### Database schema inventory
Every table and its owning service is listed in `db/README.md`. New migrations:
1. Put `*.sql` in the owning service's `internal/storage/migrations/`.
2. Update `db/README.md`.
3. Re-run `make ensure-dbs` (idempotent).

## Architecture

### Account Modes
`accounts.mode` determines data authority:
- **0 (backtest)**: strategy-service wallet authoritative → saved as-is.
- **1 (live)**: Binance API authoritative → strategy wallet ignored. **Currently fail-closed.**
- **2 (testnet)**: Same as live but uses `testnet.binancefuture.com`.

Routing: `core-service/internal/exchange/router.go` and `core-service/internal/service/grpc.go`.

### Strategy Execution Flow
4 steps per market data tick (`strategy-service/strategy_service/strategy/base.py`):
1. `wallet.on_market_data(symbol, symbol_type, price)` — update mark prices.
2. `user_strategy.on_market_data(data, wallet)` — returns `OrderDecision` or None.
3. `place_order(decision, mark_price)` — routed to `core-service/order.v1` via gRPC. Stage 1 fill model is idealized (no slippage, instant fill at mark price); real Binance / testnet execution lands in Stage 2.
4. `wallet.on_order(symbol, symbol_type, order_response)` — settle position.

⚠️ Stage 1 caveat: rollback on order rejection / partial fill / network failure is not implemented yet.

### Wallet System
`strategy-service/strategy_service/wallet/` (also in `strategy-library/wallet/`):
- **Account** = root, routes by `symbol_type` to FutureWallet or SpotWallet.
- **FutureWallet**: `margin_mode` ∈ {isolated, cross}, `position_mode` ∈ {one_way, hedge}.
- **Position**: USDT-M contract with Binance formulas (WB, IM, MM, MMR tier lookup, liquidation price).
- Cross-margin positions raise `RuntimeError` on per-position WB/equity calls — must use FutureWallet-level methods.

`mode=0` and `mode=2` both use `BinanceWalletRuntime` (Binance parity formulas, ledger events, isolated-wallet / break-even, spot locked lifecycle, futures open-order lifecycle). `mode=1`, `multi_assets_mode`, `portfolio_margin` all fail-closed.

`break_even_price` is Advisory in reconciliation (sample-inferred carry-cost lifecycle aligned with observed Binance testnet partial-close behavior; archived change `2026-04-28-align-binance-break-even-price`).

### TimescaleDB Table Naming
Scraper currently separates live vs historical by database and symbol/interval by table:
```
{market}_klines_{symbol_lower}_{interval_lower}
{market}_{datatype}_{symbol_lower}
# e.g. futures_klines_ethusdt_1m, futures_funding_rates_ethusdt
```
Live collectors and historical backfill both write by event time to `{exchange}_{year}` databases such as `binance_2026` using the same table naming. Legacy `{market}_{datatype}_{SYMBOL}_{YEAR}` tables may exist in old environments as read fallback only.

### Logging (golang-lib)
All Go services use `golang-lib/pkg/log` with middleware auto-collection. Config in each service's `config.yaml` under `log:`.
- Local files + Kafka (`app-logs-{log_type}` topics) + optional Elasticsearch.
- 10 log types: system, access, ext_api, websocket, sql, root, grpc_access, grpc_ext, kafka_sent, kafka_recv.
- Session ID propagation via `X-Session-ID` header and context.
- Go services call `logger.InitWithConfig(&cfg.Log)` → `golang-lib/pkg/log.InitLogWithConfig(cfg)`.

Python logging (`strategy-library/utils/log`) aligns with the same JSON format (Elemental). `strategy-service/run_grpc_server.py` calls `utils.log.init_log_with_kafka(...)` when `cfg.log.kafka.enabled=true`.

### Distributed tracing (OpenTelemetry → Jaeger)
W3C traceparent propagated via gRPC metadata across all backend services. Jaeger UI: http://192.168.88.10:16686, OTLP HTTP receiver `:4318`.
- Go: `golang-lib/middleware/grpc` (server) + `middleware/grpcclient` (client) + `elog.InitTracerFromConfig(cfg.Log.Tracing)` in main.
- Python strategy-service: `strategy-library/utils/log/grpc_interceptors.py` (`ServerAccessInterceptor` + `ClientExtInterceptor`); `run_grpc_server.py` calls `utils.log.tracer.init_tracer(...)`.
- Every log entry carries `trace_id` / `span_id`.
- Regression: `bash scripts/verify_tracing.sh`.

### gRPC Proto
- `core-service/proto/account_service.proto` (package `account.v1`) — users / accounts / wallet / strategy sessions.
- `control-panel-service/proto/control_panel_service.proto` — D3 runtime control plane, routing, credentials, and RuntimeChannel proxy.
- `control-panel-service/proto/marketdata_service.proto` (package `controlpanel.marketdata.v1`) — D2 market-data control plane.
- Strategy-service generates Python stubs via `strategy-service/generate_proto.sh`.

## Key Environment Variables

| Service | Variable | Default | Notes |
|---------|----------|---------|-------|
| core-service | `TIMESCALEDB_DSN` | `host=192.168.88.10 ...` | PostgreSQL DSN |
| core-service | `MOCK_BINANCE` | unset | `1` for testing without Binance API |
| core-service | `SYMBOL_CACHE_TTL` | `6h` | Go duration |
| control-panel-service | `TIMESCALEDB_DSN` | `host=192.168.88.10 ... dbname=control_panel` | DSN |
| control-panel-service | `HTTP_ADDR` | `:8082` | health / readyz |
| control-panel-service | `GRPC_ADDR` | `:50054` | gRPC |
| control-panel-service | `CORE_SERVICE_GRPC_ADDR` | `127.0.0.1:50051` | for `GetUser` plan lookup |
| control-panel-service | `RUNTIME_PLATFORM_DEFAULT_PLAN_CODE` | `pro` | overrides config default plan |
| quant-handler | `CORE_SERVICE_GRPC_ADDR` | **required** | e.g. `127.0.0.1:50051` |
| quant-handler | `QUANT_HANDLER_JWT_SECRET` | **required** | HMAC signing key |
| quant-handler | `HTTP_ADDR` | `:8090` | |
| quant-handler | `HANDLER_CORS_ORIGINS` | `http://localhost:5173` | |
| quant-handler | `CONTROL_PANEL_SERVICE_GRPC_ADDR` | **required** | strategy RPC routing always goes through control-panel-service |
| quant-frontend | `VITE_API_BASE_URL` | `http://localhost:8090` | |

## What's Not Yet Implemented

### Stage 2 — next up

- **Phase D continuation**: D2 10.7 operator manual smoke (1 task); then apply `phase-d3-self-hosted-runtime-design-fixes` (25 tasks, openspec edits only) → D3 implementation `phase-d3-self-hosted-runtime` (34 tasks, self-hosted runtime via reverse-tunnel + user certs + control-plane proxy); D4 (IDE breakpoint debugging) not specced.
- **Order failure paths**: strategy-service handles only the happy path. Rejections, insufficient margin, rate limits, network timeouts, partial fills — none have rollback logic.
- **Live wallet runtime**: `mode=1` is intentionally fail-closed (rollout guardrail).
- **Exchange-backed end-to-end proof gap**: `mode=2` has run and produced reconciliation samples, but long-run operational confidence still requires repeated full sessions (testnet account fetch → strategy loop → order flow → post-fill reconciliation).
- **Real Binance / testnet execution**: core-service's order module is partially wired for Binance futures REST. Spot execution missing, limit-order semantics incomplete, and long-run exchange-backed confidence still depends on repeated sessions.
- **Kafka market data pipeline**: `scraper` has Kafka publisher and live-delivery gating for canonical market-data topics, but the strategy-service live consumer/session path is not production-proven end-to-end.
- **Session lifecycle**: backend `StopStrategy` and gateway `/api/strategy-sessions/:id/stop` use explicit stop `action`; `stop_and_close` issues close orders and fail-closes when open orders or unsupported spot exits are present.
- **C3 follow-up observation**: real reconciliation samples across `checkpoint / event / sampled`, break-even advisory drift, funding-fee movement, threshold calibration.
- **Fault injection + production observability**: no chaos tests, no invariant assertions wired into runtime, no alerting on reconciliation mismatches.

### Later

- **OKX exchange**: placeholder in `scraper`, not implemented.
- **Frontend depth**: `StrategyList` and `OrderHistory` are basic. Missing: strategy editor UI, backtest result visualization (equity curve, trade chart), account / P&L dashboards, real-time session progress, market data view.
- **Multi-user**: user/password login exists, but permissions and API-key management are still minimal.
- **OpenAPI / external API**: nothing exposed outside `quant-frontend`. No public REST surface, no SDK.
