# AGENTS.md

This file provides guidance to Codex (Codex.ai/code) when working with code in this repository.

## Project Overview

Quantitative cryptocurrency trading platform (codename **Hushine**). Monorepo with Go microservices, a Python strategy engine, and a React frontend. All services use TimescaleDB for storage and communicate via gRPC. Logs flow through Kafka → Elasticsearch via a shared `golang-lib` logging framework (internally called **Elemental**).

Language: Chinese is the working language for comments, docs, and commit messages.

## Project Stage

**Current: Stage 1 complete; `pre_C3` is complete; `Phase C / C3` is accepted as closed. The next main phase is product iteration around remote debug mode and strategy authoring.**

- **Stage 1 (complete)** — End-to-end happy path is wired up. `quant-frontend` → `quant-handler` → `core-service` → `strategy-service` → `core-service/order.v1` → back. Backtests run, orders flow through the real order module, and wallets update through the full chain.
- **Stage 2 (active)** — Wallet/account hardening for exchange-backed modes.
  - `Phase A` is complete and archived in `core-service`: exchange-backed fetch routes by `account.mode`, uses per-account credentials, and returns Binance v3-backed canonical snapshots.
  - `Phase B1` / `B2` / `B3` are complete in `strategy-service`: runtime split, strict canonical contract, backtest bootstrap, metadata-backed risk fields, futures open-order lifecycle, ledger events, isolated-wallet/break-even parity, spot locked lifecycle, and unsupported Binance margin modes fail-closed.
  - Post-`B3` code review fixes are already landed: lifecycle events now require explicit `order_id`, futures open prechecks read `available_balance`, and spot sell prechecks read unlocked quantity (`qty - locked`).
- **Stage 2 priorities from here**, in recommended order:
  1. **Remote debug / strategy authoring product phase** — support remotely editing, debugging, starting, stopping, and observing strategy sessions without relying on local-only workflows.
  2. **Partial-fill and execution-state hardening** — define and implement behavior for half-filled orders, fill-pending orders, rejections, insufficient margin, rate limits, network timeouts, and rollback/blocking semantics.
  3. **Reconciliation follow-up observation** — keep collecting `mode=2` samples, especially break-even advisory drift and funding-fee wallet movements at settlement times; this is no longer a C3 gate.
  4. **Session lifecycle hardening** — explicit stop-session UX exists in pieces; `Stop + close positions` still needs a real implementation.
  5. **Real-time market data pipeline** — scraper → Kafka → strategy-service live loop still needs a proven end-to-end Kafka market-data session.
- **Later** — OKX exchange, broader user-facing features, multi-user, and production live-mode rollout.

**Rule of thumb when working on this repo**: if the task is in the "later" bucket, ask whether it should wait for Stage 2 to land first. Adding features to an unhardened core is the main failure pattern for early quant platforms.

## Wallet Refactor Snapshot (2026-04-20)

- **`core-service` Phase A is complete and archived.**
  - Archived change: `openspec/changes/archive/2026-04-16-core-service-exchange-adapter-phase-a/`
  - Exchange-backed fetch now routes by `account.mode`, uses per-account `api_key/api_secret`, and standardizes Binance futures snapshots from `/fapi/v3/account` + `/fapi/v3/balance` + `/fapi/v3/positionRisk`.
- **`strategy-service` Phase B is complete through `B3`.**
  - Active changes:
    - `openspec/changes/strategy-wallet-abstraction-phase-b/`
    - `openspec/changes/strategy-wallet-abstraction-phase-b2/`
    - `openspec/changes/strategy-wallet-abstraction-phase-b3/`
- **What is landed now**
  - Canonical wallet naming between `core-service -> strategy-service`
  - Runtime selection by `account.mode`: `0 -> BinanceWalletRuntime`, `2 -> BinanceWalletRuntime`, `1 -> fail-closed`. Phase C2b legacy harness removal (`future.py` / `account.py` / `BinanceParityWallet` alias / legacy CLI scripts / 5 legacy test-fixture entry points) is complete; all wallet construction now flows through `build_wallet_from_account → BinanceWalletRuntime`.
  - Strict canonical ingress: no `qty -> position_qty`, `margin_type -> margin_mode`, or `total_* -> canonical` fallback in `strategy-service`
  - Backtest bootstrap rules:
    - `cross`: `wallet_balance_0 = futures.initial_balance + deposit_sum - withdrawal_sum`
    - `isolated`: `wallet_balance_0 = Σ position.initial_balance + deposit_sum - withdrawal_sum`
  - `mode=2` hydration of real exchange-backed runtime state (`position_qty`, `entry_price`, `mark_price`, `wallet_balance`, `available_balance`, `margin_balance`, `risk_metadata`, etc.)
  - Binance parity formulas for `unrealized_pnl`, `margin_balance`, `available_balance`, `initial_margin`, `position_initial_margin`, metadata-backed `maint_margin` and `liquidation_price`
  - Futures open-order lifecycle (`open_order_initial_margin`, `total_open_order_initial_margin`), ledger events (`funding_fee`, `transfer`, `deposit`, `withdrawal`), local `isolated_wallet` / `break_even_price`, and spot `locked` lifecycle
  - Unsupported Binance account modes (`multi_assets_mode`, `portfolio_margin`) fail-closed in `mode=2`
  - Post-review hardening:
    - lifecycle order events require explicit `order_id`
    - futures open checks use `available_balance`
    - spot sell checks use unlocked quantity (`qty - locked`)
- **Verification / runtime status as of 2026-04-20**
  - `cd core-service && go test ./...` — passed
  - `cd strategy-service && PYTHONPATH=.:../strategy-library pytest tests/ -q` — passed (`89 passed`)
  - `mode=2` testnet session + reconciliation have been started for real; the project is no longer blocked at preflight-only or UI-only validation.
- **Important remaining scope limit**
  - `mode=1` live runtime remains intentionally fail-closed.
  - `C3` is accepted as closed; remaining `mode=2` observations are operational follow-up, not a blocker for moving into the remote-debug product phase.
  - The next hardening targets are partial fills / fill-pending state, execution recovery semantics, and `Stop + close positions`.

## pre_C3 Snapshot (2026-04-20)

- `pre_C3` is considered complete.
- The core contracts are now frozen:
  - Strategy input universe must be declared explicitly as `(market, symbol, interval)`.
  - `mode` is a runtime source profile, not a strategy-compatibility business rule.
  - Internal runtime state uses canonical wallet only; exchange display wallet is UI-only and does not feed runtime logic.
- The implementation plan is split into three specs:
  - `strategy-input-universe`
  - `runtime-source-profile-preflight`
  - `canonical-wallet-display-boundary`

## C3 Runtime Snapshot (2026-04-20)

- `C3` main path is considered complete enough to run:
  - `mode=2` session startup works
  - reconciliation runs are being produced
  - the work has shifted from "make C3 exist" to "correct C3 runtime behavior"
- Two concrete runtime issues were identified today:
  1. **Order execution mismatch**
     - strategy-side futures decisions use `LONG / SHORT`
     - Binance futures REST expects `BUY / SELL`
     - this produced `HTTP 400 {"code":-1117,"msg":"Invalid side."}` and left only a local `FAILED` audit row
     - the code path has been fixed for one-way mode in the order module, but runtime verification still depends on restarting `core-service` and rerunning smoke
  2. **Session stop is only half-designed**
     - backend `StopStrategy` exists
     - gateway exposes `/api/strategy-sessions/:id/stop`
     - frontend account page does not expose stop
     - `close_positions=true` is still TODO, so current stop is only a soft stop

## Next Phase Focus (2026-04-29)

1. Build remote debug mode as the main product iteration path:
   - support strategy editing/debugging from the remote frontend
   - make session start/stop/log/reconciliation/fill state observable enough for strategy development
   - avoid adding product features that bypass the existing `quant-frontend -> quant-handler -> services` chain
2. Harden partial fills and execution recovery in parallel:
   - define behavior when Binance fills only part of an order
   - keep incomplete fee/trade details in fill-pending/recoverable state instead of settling synthetic zero-fee fills
   - block further symbol execution until the fill state is resolved
3. Keep reconciliation as background runtime observation:
   - `break_even_price` stays `Advisory`
   - funding-fee wallet balance movement around 00:00 / 08:00 / 16:00 UTC must be separated from order-driven drift
   - long-session sample collection continues, but it no longer blocks C3 closure

## C3 Bugfix Snapshot (2026-04-24)

- Archived change: `openspec/changes/archive/2026-04-28-c3-reconciliation-bugfixes/`
- Code fixes landed:
  - one-way futures local export uses `position_side=BOTH` instead of `LONG / SHORT`
  - new local futures position slots use `risk_metadata.configured_leverage` when position leverage is missing/defaulted
  - Binance-backed account snapshots fetch risk metadata even when the symbol is currently flat
  - Binance order fills backfill `exchange_trade_id` / `fee` from `/fapi/v1/userTrades`
  - confirmed fills with missing fee data are persisted as `FEE_MISSING` instead of silent confirmed zero-fee
  - Account Detail displays futures position leverage
- Verified locally:
  - `strategy-service`: `PYTHONPATH=.:../strategy-library pytest -q tests/test_wallet_runtime.py tests/test_order_client.py tests/test_strategy_engine.py`
  - `core-service`: `go test ./internal/exchange ./internal/reconciliation`
  - `core-service` order module: `go test ./internal/order/executor ./internal/order/service`
  - `quant-handler`: `go test ./internal/app`
  - `quant-frontend`: `npm run build`
- Follow-up observation:
  - future `mode=2` sessions should confirm one-way `ETHUSDT/SHORT.exists` / `ETHUSDT/LONG.exists` hard fails stay gone
  - future sessions should confirm `wallet_balance` diff no longer grows by missing-fee steps

## C3 Break-even Correction Snapshot (2026-04-28)

- Archived change: `openspec/changes/archive/2026-04-28-align-binance-break-even-price/`
- Scope:
  - Align local futures `break_even_price` carry-cost lifecycle with observed Binance testnet partial-close behavior.
  - Keep formula documented as sample-inferred: Binance exposes `breakEvenPrice` / `bep` but does not publish the full formula.
  - Keep `break_even_price` as reconciliation `Advisory`; it must not affect `hard_pass` / `soft_pass`.
- Current inferred formula:
  - Export: `break_even_price = entry_price + sign(qty) * carry_cost / abs(qty)`
  - Same-direction add: add fill fee to `carry_cost`
  - Same-direction partial close: `carry_cost = previous_carry_cost - realized_pnl + close_fee`
  - Full close: reset `carry_cost` / `break_even_price`
  - Flip: start a new lifecycle with the open-segment fee only
  - Cross funding without position attribution changes wallet balance only, not break-even
- Rollback condition:
  - If later Binance samples disprove the partial-close allocation, revert only the `carry_cost` partial-close update rule; no API or DB migration is required.

## Verification Snapshot (2026-04-16)

- **Account flow: passed at service level**.
  - `core-service` local test suite passed: `cd core-service && go test ./...`
  - Existing integration coverage proves the service-level account happy path around portfolio context creation, venue wallet bootstrap, and portfolio snapshot sync.
  - order module tests passed under the then-current service layout; after the runtime merge, use `cd core-service && go test ./internal/order/...`
  - `strategy-service` targeted gRPC / data-loop tests passed with explicit path ordering:
    `PYTHONPATH=/Users/xdy/Workplace/hushine/strategy-service:/Users/xdy/Workplace/hushine/strategy-library pytest -q tests/test_grpc_server.py tests/test_data_loop.py`
- **Important scope limit**: this does **not** prove real Binance live/testnet end-to-end. It proves the current service-layer happy path and mock-backed account flow are runnable.
- **Real live/testnet is still not considered runnable end-to-end**. Current known blockers:
  1. ~~`core-service` exchange fetch uses process-level env credentials, while the order path places orders with per-account credentials from DB.~~ **Resolved by Phase A**: exchange-backed fetch now uses per-account credentials from the `accounts` row; `accounts.api_key` is constrained unique.
  2. ~~`strategy-service` drops live futures runtime state during wallet hydration.~~ **Resolved for `mode=2` by Phase B1**: canonical hydration now restores `qty`, `entry_price`, `mark_price`, `wallet_balance`, and balance context into `BinanceWalletRuntime`. `mode=1` remains intentionally fail-closed.
  3. The order module live executor is futures-only (`/fapi/v1/order`, market order path). Spot live/testnet is not wired, and limit-order semantics are not implemented in the real executor path.
  4. `scripts/e2e_full_flow.sh` is still a **mode=0 backtest** script and starts `core-service` with `MOCK_BINANCE=1`, so it is not evidence for real exchange readiness.

## Wallet Algorithm Assessment (2026-04-18)

- **Current implementation model**
  - The repo now routes both active modes through the Binance runtime:
    - `mode=0 -> BinanceWalletRuntime`
    - `mode=2 -> BinanceWalletRuntime`
    - `mode=1 -> fail-closed`
  - `LegacyWalletAdapter` + `FutureWallet` + `Position` + `Account` + `BinanceParityWallet` alias + the `run_backtest.py` / `run_debug.py` / `backtest_runner.py` legacy entry scripts have all been removed (Phase C2b cleanup, archived change `strategy-wallet-legacy-cleanup`).
- **What is already parity-backed in `mode=2`**
  - strict canonical hydration
  - `wallet_balance`, `unrealized_pnl`, `margin_balance`, `available_balance`
  - `notional`, `initial_margin`, `position_initial_margin`
  - metadata-backed `maint_margin`, `liquidation_price`
  - futures `open_order_initial_margin` / `total_open_order_initial_margin`
  - ledger events (`funding_fee`, `transfer`, `deposit`, `withdrawal`)
  - local `isolated_wallet`, `break_even_price`
  - spot `locked` lifecycle
- **What is still intentionally out of scope / fail-closed**
  - `mode=1` live runtime
  - `multi_assets_mode`
  - `portfolio_margin`
  - full testnet-sampled drift calibration and long-session reconciliation observations
- **Direction from here**
  - Wallet C3 is closed enough to leave the critical path; new wallet work should be treated as targeted bugfix or runtime observation, not a reopened Phase B/C scope.
  - The next main workstream is remote debug / strategy authoring, with partial-fill handling and reconciliation observation running in parallel.

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
        → strategy-service (gRPC :50053)

scraper (Go)
    → Binance REST + WebSocket
    → TimescaleDB ({exchange}_{year} market-data DBs)
    → Kafka market data topics (live delivery when streams are active)

strategy-service (Python gRPC :50053)
    → TimescaleDB (backtest reads)
    → core-service (gRPC, wallet sync)
    → core-service/order.v1 (gRPC, place/cancel/query orders)
    → [Stage 2] Kafka live data via LiveDataLoop (consumer loop not wired)
```

## Build & Run Commands

Each backend service has a `config.yaml` with development defaults. Env vars override
specific fields (`<SECTION>_<KEY>` convention, plus legacy names like `TIMESCALEDB_DSN`,
`ACCOUNT_SERVICE_GRPC_ADDR`, `QUANT_HANDLER_JWT_SECRET`).

### Root Makefile (all services)
```bash
make ensure-dbs  # create all DBs (account / order / control_panel / {exchange}_{year}) + migrations — fresh-deploy first step
make dev         # run all backend services in foreground (Ctrl+C stops everything)
make build       # compile all Go services to <service>/bin/
make start       # build + start all services in background (logs in <service>/logs/)
make stop        # stop background services
make test        # run tests in all services
```

### Database schema inventory
Every table and its owning service is listed in `db/README.md`. When adding a new migration:
1. Put the `*.sql` in the owning module's migration directory (usually `internal/storage/migrations/`; the order module uses `core-service/internal/order/storage/migrations/`).
2. Update `db/README.md`'s table list so deploys stay reproducible.
3. Re-run `make ensure-dbs` — idempotent, picks up the new migration automatically.

### Per-service Makefile
Each service Makefile has: `build`, `dev`, `start`, `stop`, `test`, `clean`.

```bash
cd core-service
make proto          # Generate gRPC stubs → gen/accountv1/
make ensure-db      # Create TimescaleDB schema
make ensure-order-db # Create order DB schema for core-service/order module
make test-integration  # Integration tests (requires TimescaleDB)
make dev            # go run ./cmd/core-service -config ./config.yaml
```

```bash
cd strategy-service
pip install -r requirements.txt
./generate_proto.sh              # Regenerate stubs from core-service proto
make dev                          # PYTHONPATH=... python run_grpc_server.py -config config.yaml
pytest tests/                     # All tests
pytest tests/test_strategy_engine.py  # Single file
# Optional HTTP entry (legacy FastAPI wrapper used by a few local flows):
python run_http_server.py        # FastAPI on :8000
```

After Phase C2b legacy cleanup, `run_backtest.py` / `run_debug.py` /
`backtest_runner.py` no longer exist — backtests run through the gRPC
`RunStrategy` call (`strategy-service`'s normal production path). Use
`make dev` at the repo root to start the full local stack.

### scraper (Go)
```bash
cd scraper
go build -o bin/scraper ./cmd/scraper
go run ./cmd/scraper          # Uses config.yaml (scraper's own format)
docker compose up -d          # Docker deployment
```

### gateway/quant-frontend (React 19 + Vite)
```bash
cd gateway/quant-frontend
npm install
npm run dev       # :5173, proxies to VITE_API_BASE_URL (default http://localhost:8090)
npm run build     # Type-check + production build
```

### strategy-library (Python, not standalone)
```bash
cd strategy-library
pip install -r algo/requirements.txt
pytest tests/
```
Symlinked into strategy-service root as `strategy-library/`.

### golang-lib (Go shared library)
```bash
cd golang-lib
go test ./...
go test -race ./...
go test ./middleware/httpserver/... -run TestMiddleware_BasicGET  # Single test
go run ./examples/e2e-all-types/main.go  # E2E demo
```

## Architecture

### Account Modes
Account mode (stored in `accounts.mode`) determines data authority:
- **0 (backtest)**: strategy-service wallet is authoritative → saved as-is in DB
- **1 (live)**: Binance API is authoritative → strategy-service wallet ignored, exchange data fetched
- **2 (testnet)**: Same as live but uses `testnet.binancefuture.com`

Routing logic: `core-service/internal/exchange/router.go` and `core-service/internal/service/grpc.go`

### Strategy Execution Flow (4 steps per market data tick)
Defined in `strategy-service/strategy_service/strategy/base.py`:
1. `wallet.on_market_data(symbol, symbol_type, price)` — update mark prices
2. `user_strategy.on_market_data(data, wallet)` — returns `OrderDecision` or None
3. `place_order(decision, mark_price)` — routed to `order.v1` served by core-service over gRPC (no longer a mock). In Stage 1 the fill model is still idealized (no slippage, instant fill at mark price); real Binance / testnet execution lands in Stage 2.
4. `wallet.on_order(symbol, symbol_type, order_response)` — settle position

⚠️ **Stage 1 caveat**: the happy path is wired, but rollback on order rejection / partial fill / network failure is not. Stage 2 will harden this.

### Wallet System
`strategy-service/strategy_service/wallet/` (also in `strategy-library/wallet/`):
- **Account** = root, routes by `symbol_type` to FutureWallet or SpotWallet
- **FutureWallet**: `margin_mode` ∈ {isolated, cross}, `position_mode` ∈ {one_way, hedge}
- **Position**: Single USDT-M contract with Binance formulas (WB, IM, MM, MMR tier lookup, liquidation price)
- Cross-margin positions raise `RuntimeError` on per-position WB/equity calls — must use FutureWallet-level methods

### TimescaleDB Table Naming
Scraper currently separates live vs historical by database and symbol/interval by table:
```
{market}_klines_{symbol_lower}_{interval_lower}
{market}_{datatype}_{symbol_lower}
# e.g. futures_klines_ethusdt_1m, futures_funding_rates_ethusdt
```
Live collectors and historical backfill both write by event time to `{exchange}_{year}` databases such as `binance_2026` using the same table naming. Legacy `{market}_{datatype}_{SYMBOL}_{YEAR}` tables may exist in old environments as read fallback only.

### Logging (golang-lib)
All Go services use `golang-lib/pkg/log` with middleware auto-collection. Config lives in each service's `config.yaml` under the `log:` section (formerly a separate `log-config.json` — removed during the unified-config refactor):
- Local files + Kafka (`app-logs-{log_type}` topics) + optional Elasticsearch
- 10 log types: system, access, ext_api, websocket, sql, root, grpc_access, grpc_ext, kafka_sent, kafka_recv
- Session ID propagation via `X-Session-ID` header and context
- Go services call `logger.InitWithConfig(&cfg.Log)` which forwards to `golang-lib/pkg/log.InitLogWithConfig(cfg)` (in-memory struct, no file read)

Python logging in `strategy-library/utils/log` aligns with the same JSON format (Elemental). `strategy-service/run_grpc_server.py` calls `utils.log.init_log_with_kafka(...)` when `cfg.log.kafka.enabled=true`.

### Notification Management
通知是用户级附加能力，不阻断交易主链路。统一事件 topic 是 `notification.events`：
- `control-panel-service` 生产 runtime/session/custom 事件；hosted 和 self-hosted 都必须从 control-plane 入口进入。
- core-service/order module 在订单状态落库后生产订单通知事件；Kafka 失败只打日志，不改变订单结果。
- `core-service` 是唯一通知消费者和 Telegram 发送方，负责读取用户 plan、偏好、通道绑定和自定义消息限频。
- `strategy-service` 只给用户策略注入 `self.notify.info/warn/error`，不直接访问 Kafka、DB、account/order 内部服务。
- Telegram 绑定/发送需要 `TELEGRAM_BOT_TOKEN` 和 `TELEGRAM_BOT_USERNAME`；消息正文暂不入库，只更新用户级 delivery status/error。

### Distributed tracing (OpenTelemetry → Jaeger)
All backend services propagate W3C traceparent via gRPC metadata, producing a single Jaeger trace per business request that spans quant-handler / strategy-service / core-service, including core-service's `order.v1` API. Jaeger UI lives at http://192.168.88.10:16686, OTLP HTTP receiver at :4318.
- Go services wire via `golang-lib/middleware/grpc` (server) + `middleware/grpcclient` (client) + `elog.InitTracerFromConfig(cfg.Log.Tracing)` in main.
- Python strategy-service wires via `strategy-library/utils/log/grpc_interceptors.py` (`ServerAccessInterceptor` + `ClientExtInterceptor`); `run_grpc_server.py` calls `utils.log.tracer.init_tracer(...)` when `cfg.log.tracing.enabled=true`.
- Every log entry carries `trace_id` / `span_id` fields so ES / Kibana queries can filter by trace.
- Regression test: `bash scripts/verify_tracing.sh` fires a signup call and asserts the resulting trace covers the expected service set + trace_id appears in ES.

### gRPC Proto
Single proto: `core-service/proto/account_service.proto` (package `account.v1`)
- Strategy-service generates Python stubs via `strategy-service/generate_proto.sh`
- quant-handler imports Go stubs from `core-service/gen/accountv1/`

## Key Environment Variables

| Service | Variable | Default | Notes |
|---------|----------|---------|-------|
| core-service | `TIMESCALEDB_DSN` | `host=192.168.88.10 ...` | PostgreSQL DSN |
| core-service | `MOCK_BINANCE` | unset | Set `1` for testing without Binance API |
| core-service | `SYMBOL_CACHE_TTL` | `6h` | Go duration format |
| core-service | `NOTIFICATION_KAFKA_BROKERS` | `192.168.88.10:19092` | Consumes `notification.events` |
| core-service | `TELEGRAM_BOT_TOKEN` | unset | Required for Telegram send/bind |
| core-service | `TELEGRAM_BOT_USERNAME` | unset | Displayed in Notification Management |
| control-panel-service / core-service order module | `NOTIFICATION_KAFKA_BROKERS` | `192.168.88.10:19092` | Produces `notification.events` |
| quant-handler | `CORE_SERVICE_GRPC_ADDR` / `ACCOUNT_SERVICE_GRPC_ADDR` | **required** | e.g. `127.0.0.1:50051`; old name remains compatible |
| quant-handler | `QUANT_HANDLER_JWT_SECRET` | **required** | HMAC signing key |
| quant-handler | `HTTP_ADDR` | `:8090` | |
| quant-handler | `HANDLER_CORS_ORIGINS` | `http://localhost:5173` | |
| quant-frontend | `VITE_API_BASE_URL` | `http://localhost:8090` | |

## What's Not Yet Implemented

See **Project Stage** at the top of this file for the "where are we" narrative. This section is the concrete backlog.

### Stage 2 — next up, hardening for real trading

- **Wallet reconciliation / invariants**: C3 compare path, diff persistence, and ELK metric logs are in code and archived; remaining work is runtime observation and threshold calibration, not feature construction.
- **Remote debug / strategy authoring**: the next product phase should make remote strategy editing, debugging, session control, and runtime inspection usable from the frontend.
- **Exchange-backed end-to-end proof gap**: `mode=2` has run and produced reconciliation samples, but long-run operational confidence still depends on repeated sessions spanning Binance testnet account fetch → strategy loop → order flow → post-fill reconciliation.
- **Live wallet execution boundary**: `mode=0` and `mode=2` now share `BinanceWalletRuntime`, but `mode=1` remains intentionally fail-closed. This is a rollout guardrail, not an accidental gap.
- **Order failure paths**: `strategy-service` handles only the happy path. Rejections, insufficient margin, rate limits, network timeouts, partial fills — none have rollback logic. core-service's order module places orders, but the end-to-end error contract (what does strategy do when place_order fails?) is not defined.
- **Kafka market data pipeline**:
  - `scraper` has Kafka publisher and live-delivery gating for canonical market-data topics, but end-to-end delivery into live sessions still needs repeated proof.
  - `strategy-service` has a `LiveDataLoop` scaffold; the live consumer/session path still needs hardening and proven operation with real topics.
  - Net effect: live market data is partially wired, but not production-proven end-to-end.
- **Real Binance / testnet execution**: core-service's order module is partially wired for Binance futures REST, but the real path is not production-ready yet: spot execution is missing, limit-order semantics are incomplete, and long-run exchange-backed confidence still depends on repeated sessions.
- **Live / testnet end-to-end run**: `mode=2` has run and produced reconciliation samples; `mode=1` remains intentionally fail-closed until the execution/fill recovery contract is hardened.
- **C3 follow-up observation**: C3 is closed, but real reconciliation samples across `checkpoint / event / sampled`, break-even advisory drift, funding-fee movement, and threshold calibration should continue during the next phase.
- **Fault injection + production observability**: no chaos tests, no invariant assertions wired into runtime, no alerting on reconciliation mismatches.

### Later

- **OKX exchange**: placeholder in `scraper`, not implemented.
- **Frontend depth**: `StrategyList` and `OrderHistory` pages exist but are basic. Missing: strategy editor UI, backtest result visualization (equity curve, trade chart), account / P&L dashboards, real-time session progress, market data view.
- **Multi-user**: user/password login exists, but permissions and API-key management are still minimal.
- **OpenAPI / external API**: nothing is exposed outside `quant-frontend`. No public REST surface, no SDK.
