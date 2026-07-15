# Binance Spot USDT End-to-End Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Deliver Binance-standard Spot USDT support through Backtest, Demo, offline debugger, and the real UI while preserving Futures behavior and keeping Live Spot rollout-guarded.

**Architecture:** Core-service remains the only exchange and order authority. Route-aware Binance adapters read `/api/v3/account` and `/api/v3/exchangeInfo`, use the authenticated Spot WebSocket API user-data subscription, preserve exact decimal rules, and expose canonical asset balances plus immutable risk snapshots to preflight, execution, stop-and-close, and repair-capable reconciliation. Four default-off product capability gates keep every additive layer dark until its own acceptance passes; strategy workers and offline replay consume frozen contracts without credentials or exchange access; control-panel only proxies authenticated RuntimeChannel calls; quant-handler maps identity and capability discovery without inventing exchange semantics; quant-frontend presents only effective capabilities and structured failures.

**Tech Stack:** Go 1.26.1, Protocol Buffers/gRPC, Python 3.13 with `uv`/pytest, TypeScript/React/Vite, Binance Spot REST plus WebSocket API Demo/Testnet, TimescaleDB JSON snapshots, Bash, Docker coverage images, and the installed Browser skill plus `browser-client` raw-CDP acceptance handoff.

## Global Constraints

- Work only in `/Users/xdy/Workplace/hushine-worktrees/medium-cleanup`.
- Target branch `cleanup/medium-baseline-20260710` in every affected repository. The workspace root is not a Git repository. If an isolated worktree is detached because that branch is already attached elsewhere, commit on the verified detached base, record its HEAD for handoff, and do not attach one branch to two worktrees. Remote pushes belong to the separate full-system acceptance gate.
- The approved source of truth is `hushine-deploy/docs/superpowers/specs/2026-07-14-binance-spot-usdt-end-to-end-design.md`; do not create or modify OpenSpec artifacts.
- Preserve dirty work, stage only owned hunks, and commit each repository independently with the repository-scoped commands in this plan. Every `git add` block is an owned-file inventory, not permission to stage a pre-existing dirty path wholesale: capture `git status --short` before each task, use `git add -p` for any already-dirty path, stage generated artifacts by exact filename, and inspect `git diff --cached --check` plus `git diff --cached` before committing.
- Use red-green-refactor for every behavior. Run each stated RED command before production edits and record the expected named failure.
- Every intermediate commit must compile across its entire repository, not only the focused package. Immediately before each `git commit` below, run the exact repository gate from the pre-commit matrix in this section; a focused GREEN is not permission to commit a repository-wide compile or generated-code failure.
- Route sessions only by `runtime_id`; route wallets by `(venue_id, exchange, market)` and orders by `(venue_id, exchange, market, symbol)`.
- All exchange I/O and all order execution remain in core-service. Runtime-agent and workers never receive credentials and never call Binance directly.
- Spot account assets are Binance asset codes (`BTC`, `USDT`, `BNB`). `BTCUSDT` is a trading symbol only. Metadata is the only permitted symbol-to-asset mapping; suffix slicing is forbidden.
- The supported order-target universe is Binance Spot with `quoteAsset=USDT`. Account snapshots still retain all real non-zero assets returned by Binance.
- Use decimal strings and exact decimal arithmetic from protocol ingress through risk and Binance request construction. Existing doubles remain read-compatible display fields only during rolling deployment.
- Spot metadata cache keys include endpoint, environment, and symbol, use a five-minute TTL, and never serve expired data after refresh failure. One preflight uses one immutable snapshot.
- Product capabilities are exactly `backtest_spot_usdt`, `demo_spot_usdt`, `offline_spot_usdt`, and `live_spot_usdt`. All four configured values and all four effective values default to `false`. `live_spot_usdt=true` never overrides the independent `environment=2 && market=spot` rollout guard; effective Live Spot remains false until a separate compatibility decision changes that invariant.
- `environment=2 && market=spot` fails closed in core-service admission, order service, and stop-and-close. UI hiding is supplementary, not the security boundary.
- Spot stop-only never trades. Spot stop-and-close plans every declared Spot `ORDER_TARGET` from a fresh authoritative snapshot before sending the first order; any open order, locked balance, invalid rule, unavailable price, or unavoidable dust aborts the entire plan. A mid-flight exchange failure leaves the Session `stop_failed` and triggers reconciliation.
- Preserve Portfolio, Venue, order, fill, wallet, snapshot, and reconciliation history. This Spot plan's fields/migrations are additive and rolling-compatible; do not rewrite or delete historical rows. If it is executed with the Runtime Indicator V2 plan, that plan's destructive V1 cutover remains a coordinated, non-rolling boundary and the combined rollout must not be described as wholly rolling-compatible.
- Futures account, risk, execution, stop, replay, and UI behavior must remain unchanged. Same-name Spot/Futures symbols must remain isolated.
- Binance Spot User Data Stream must use `wss://ws-api.binance.com:443/ws-api/v3` (or the configured official Demo/Testnet WebSocket API endpoint) and `userDataStream.subscribe.signature`; production and mock Spot code must not call `POST|PUT|DELETE /api/v3/userDataStream`. Binance USD-M Futures keeps its existing `/fapi/v1/listenKey` create/keepalive/delete and `/ws/<listenKey>` transport unchanged.
- Never print, persist, commit, or include Binance keys/secrets in test evidence. The full-system acceptance runner's dedicated provisioning helper accepts them only through approved inherited secure FDs long enough to create an encrypted Demo Venue through quant-handler, then closes/unlinks every transient input. Runtime-agent, workers, strategy code, Spot smoke calls, process argv, and evidence receive only the public `VENUE_ID`, never raw credentials.
- Before each commit run the task's focused tests. Before completion run repository-local regressions and publish the reusable Demo/Browser/coverage handoff consumed by the separate full-system acceptance gate.

Repository-wide pre-commit compile matrix (run the applicable block immediately before every commit in this plan):

```bash
# core-service, control-panel-service, gateway/quant-handler, or another Go-only repository
go test ./... && go vet ./...

# strategy-service
PYTHONPATH=.:../strategy-library uv run --frozen --extra dev python -m compileall -q strategy_service tests
go test ./... && go vet ./...

# strategy-library
uv run --isolated --no-project --with-editable '.[test]' python -m compileall -q hushine_strategy tests

# strategy-debugger-cli (the wrapper is mandatory after the dependency-contract plan)
./scripts/with-local-strategy-library-git.sh ../strategy-library \
  uv run --frozen --extra test python -m compileall -q src tests

# gateway/quant-frontend
npm run build

# hushine-deploy shell/Python artifacts
bash -n scripts/verify_spot_usdt.sh scripts/smoke_spot_demo.sh scripts/lib/runtime_coverage.sh
python3 -m compileall -q scripts/fixtures scripts/acceptance
```

## Cross-Plan Execution Order

Complete the Runtime Python Dependency Contract plan first, then complete the entire Runtime Indicator V2 Lifecycle plan, and only then execute this Spot plan against that post-Indicator source tree. Keep the `AGENTS.md`-mandated `PYTHONPATH=.:../strategy-library` repository suite as a source-worktree regression, and separately require the frozen installed/image gate; source shadowing alone is never production evidence. Each companion plan regenerates from the current combined descriptors when its task requires generated code; Spot never replays an earlier descriptor or overwrites Indicator fields. The final full-system acceptance gate performs one clean deterministic regeneration/check over the combined dependency + Indicator + Spot tree and fails on any drift. Spot Task 9 therefore extends the already-complete Indicator Task 7 Agent-owned lifecycle coordinator rather than creating a competing owner.

For deployment, first publish the additive Spot database/core/control/handler reader-writer compatibility path with every configured and effective Spot capability still disabled. Do not deploy the Spot Task 9 strategy-service/runtime-agent terminal behavior on a V1 worker: publish it only in the coordinated Indicator protocol-2 Runtime/worker cutover after the additive mixed-version checks pass. Then publish debugger/UI consumers and enable only the separately accepted Backtest, Demo, and offline flags. Spot terminal results must enter the Agent coordinator before Session status is durable. Roll back the additive Spot layers by disabling capability and reversing consumers while retaining history, but never roll an Indicator consumer independently across its V1/V2 boundary.

Execute and deploy cross-repository changes in this atomic order; do not reorder a consumer ahead of its producer:

| Order | Producer/consumer cut | Required state before advancing |
|---|---|---|
| 1 | Tasks 1-3 core protobuf/domain/readers | Additive generated code committed; `core-service` repository-wide test/vet green; Futures readers still use `/fapi/*`. |
| 2 | Task 4A capability policy/RPC, then Task 4B preflight | All four flags default/effective false; old readers still work; no Spot Session can start. |
| 3 | Tasks 5-6 core risk, WebSocket lifecycle, repair coordinator | Core repository-wide test/vet and real-DB migrations green; Spot remains disabled; Futures listenKey controls green. |
| 4 | Task 7 worker consumer, then Task 8 core close producer | Worker consumes only already-generated additive fields; neither commit is deployed until both repository gates pass. |
| 5 | Task 9 control-panel proxy commit, then strategy-service protocol/Agent commit | Core RPC already exists; control-panel repository gate passes before the Runtime image is built; protocol-2 coordinator remains sole terminal owner. |
| 6 | Task 10 strategy-library, then Task 11 handler package exporter, then debugger repin/importer | Library HEAD is final before debugger lock pin; handler package-v2 writer is deployed before the new importer is offered. |
| 7 | Task 12 handler capability discovery/admission, then Task 13 frontend | Handler returns effective flags and blocks disabled actions before UI consumes them; direct HTTP controls pass. |
| 8 | Task 14 all-local, release-smoke handoff, and later full-system acceptance | Enable only one accepted flag at a time; no capability enable, push, or rollout occurs in this focused plan. |

---

## File Map

| Repository | Files | Responsibility |
|---|---|---|
| `core-service` | `proto/portfolio_service.proto`, `gen/portfoliov1/*`, `internal/domain/model.go`, new `internal/domain/spot_wallet.go` | Add canonical asset balances and Spot metadata while reading legacy `symbol/qty` JSON and protobuf fields. |
| `core-service` | `proto/order_service.proto`, `gen/orderv1/*` | Add exact decimal order fields and the core-authoritative `CloseSpotTargets` RPC. |
| `core-service` | `internal/config/config.go`, `internal/capability/{policy,policy_test}.go`, `proto/portfolio_service.proto`, `internal/service/grpc.go`, `cmd/core-service/main.go` | Default-off four-flag capability truth, effective capability discovery, and fail-closed admission/drain policy. |
| `core-service` | `internal/exchange/adapter/capabilities.go`, `errors.go`, `internal/exchange/binance/{factory,portfolio_snapshot,symbol_rules,endpoints}.go`, new `spot_account.go`, `spot_metadata.go`, `spot_metadata_cache.go` | Route-aware official Spot account/rules readers, typed filters, exact values, five-minute cache, structured failures. |
| `core-service` | `internal/exchange/binance/mockserver/{rest_spot,exchange_info,fixtures,scenario,server}.go` | Official Binance-shaped deterministic fixtures; remove proof based on `/api/v3/portfolio`. |
| `core-service` | `internal/service/grpc.go`, `cmd/core-service/exchange_registry.go` | Preflight/admission, immutable metadata snapshot mapping, and Live Spot guard. |
| `core-service` | `internal/order/risk/{types,balance,gate,pending,symbol_rules}.go`, new `decimal.go`, `spot_filters.go` | Exact Spot balance and filter validation without suffix inference. |
| `core-service` | `internal/order/executor/{executor,adapter_router}.go`, `internal/exchange/binance/{order_executor,order_state_reader,order_capability}.go`, new `spot_user_data_wsapi.go`, `internal/order/{service,lifecycle,repository}/*` | Exact request construction, Spot WebSocket API/Futures-listenKey transport split, fee asset propagation, monotonic/idempotent lifecycle, and persisted fills. |
| `core-service` | new `internal/order/spotclose/{types,planner}.go`, new `internal/reconciliation/spot_coordinator.go`, modify `internal/reconciliation/{diff,service}.go` | Atomic preplan for declared Spot targets and authoritative lifecycle repair, canonical snapshot persistence, and recoverable-state reconciliation. |
| `strategy-service` | `generate_proto.sh`, generated `strategy_service/gen/{order,portfolio}_service_pb2*.py` and `gen/portfoliov1/*` | Consume additive core protocol. |
| `strategy-service` | `strategy_service/wallet/{canonical,spot,binance,portfolio,portfolio_adapter,order_types}.py`, `order_client.py`, `platform_proxy.py`, `grpc_server.py` | Canonical Spot wallet, exact order/fill application, preflight metadata, mixed routes, and stop semantics. |
| `control-panel-service` | `internal/runtimechannel/platform_proxy.go`, `platform_proxy_test.go`, `auth.go`, `auth_test.go` | Authenticated RuntimeChannel proxy for `CloseSpotTargets`, with no exchange logic. |
| `strategy-library` | new `hushine_strategy/wallet/spot.py`, `hushine_strategy/wallet/portfolio.py`, `hushine_strategy/replay/spot_filters.py`, modify `wallet/__init__.py`, `replay/engine.py` | Hosted-equivalent offline Spot filter admission, wallet, and mixed-route replay from frozen facts. |
| `strategy-debugger-cli` | `src/hushine_debugger/{import_package,config,replay,integrity}.py`, `data/manifest.py`, `templates/{hushine-debug.yaml,wallet.yaml}` | Versioned, offline-only package v2 with multiple streams, canonical wallet, and metadata snapshot. |
| `gateway/quant-handler` | `internal/app/{capabilities,venues,wallet_bootstrap,portfolios_ext,strategy,debug_package,debug_package_parquet,order_history,session_history,enum_labels}.go` | Core-backed effective capability discovery, identity/authorization mapping, canonical Spot payloads, exact order-history decimals, server-side admission, and debug package v2. |
| `gateway/quant-frontend` | `src/api/client.ts`, `src/pages/{VenueManagement,PortfolioDetail,SessionDetailPage}.tsx`, `src/components/{StopSessionDialog,SymbolPicker}.tsx`, new tracked `scripts/spot-*.test.mjs` | Capability-driven Spot asset UI, route-aware start/debug/stop, structured errors, and visible Live guard. |
| `hushine-deploy` | new `scripts/verify_spot_usdt.sh`, `scripts/verify_spot_usdt.test.sh`, `scripts/smoke_spot_demo.sh`, `scripts/smoke_spot_demo.test.sh`, `scripts/acceptance/{observe_spot_demo.py,observe_spot_demo.test.sh}`, `scripts/fixtures/{spot_demo_fake_server.py,spot_demo_evidence.schema.json}`, `scripts/lib/runtime_coverage.sh`, `docs/spot-usdt.md`, `docs/acceptance/2026-07-14-binance-spot-demo.md`; modify `scripts/smoke_hosted_runtime_coverage.sh`, `scripts/smoke_hosted_runtime_coverage.test.sh`, generated `db/generated/{order,portfolio}.sql`, `db/generated/README.md`, `db/README.md`, and `docs/{runtime-operator-flow,strategy-debugger-cli-smoke,production-deploy-checklist}.md` | Reproducible Backtest/Demo/offline/UI/filter/stop/Futures gates, behavior-driven official-shape fake exchange, credential-free raw evidence, regenerated schema, shared safe coverage finalization, Browser-skill handoff, operator/user documentation, and rollback instructions. |

---

## Immutable Core Baseline Evidence

Before Task 1, record and verify this immutable core-service base. The branch may advance; these values must not:

```bash
cd /Users/xdy/Workplace/hushine-worktrees/medium-cleanup/core-service
CORE_SPOT_BASE_SHA=1b92b40c8337bd8a2c31871ef488b344e5d518a6
PORTFOLIO_0001_BASE_SHA256=5b2bf5a34e9a65e7f2c6fca69a71553dac4c1b00f8b720e5cde3f71eaec5cafe
ORDER_0001_BASE_SHA256=6e2d179b9ecf706de8461ca6443efacfd22cb084ef6b49a0e2c94f2e49881b60
test "${#CORE_SPOT_BASE_SHA}" -eq 40
git cat-file -e "$CORE_SPOT_BASE_SHA^{commit}"
test "$PORTFOLIO_0001_BASE_SHA256" = "$(git show "$CORE_SPOT_BASE_SHA:internal/storage/migrations/0001_current_schema_baseline.sql" | shasum -a 256 | awk '{print $1}')"
test "$ORDER_0001_BASE_SHA256" = "$(git show "$CORE_SPOT_BASE_SHA:internal/order/storage/migrations/0001_current_schema_baseline.sql" | shasum -a 256 | awk '{print $1}')"
test "$PORTFOLIO_0001_BASE_SHA256" = "$(shasum -a 256 internal/storage/migrations/0001_current_schema_baseline.sql | awk '{print $1}')"
test "$ORDER_0001_BASE_SHA256" = "$(shasum -a 256 internal/order/storage/migrations/0001_current_schema_baseline.sql | awk '{print $1}')"
```

Every Task 5/6/8 migration test and Task 14 bundle check receives the literal 40-character `CORE_SPOT_BASE_SHA` and the two SHA-256 constants above. A moving branch/ref, current `HEAD`, or newly committed copy is never accepted as baseline evidence.

---

### Task 1: Add the canonical Spot wallet and metadata wire contract

**Files:**
- Modify: `core-service/proto/portfolio_service.proto`
- Modify: `core-service/internal/domain/model.go`
- Create: `core-service/internal/domain/spot_wallet.go`
- Create: `core-service/internal/domain/spot_wallet_test.go`
- Modify: `core-service/internal/service/grpc.go`
- Modify: `core-service/internal/service/wallet_state_proto_test.go`
- Modify: `core-service/internal/service/portfolio_snapshot_test.go`
- Regenerate: `core-service/gen/portfoliov1/portfolio_service.pb.go`
- Regenerate: `core-service/gen/portfoliov1/portfolio_service_grpc.pb.go`

**Interfaces:**
- Canonical domain:

```go
type SpotAsset struct {
    Asset         string  `json:"asset"`
    Free          float64 `json:"free"`
    Locked        float64 `json:"locked"`
    FreeDecimal   string  `json:"free_decimal,omitempty"`
    LockedDecimal string  `json:"locked_decimal,omitempty"`
    AvgEntryPrice float64 `json:"avg_entry_price,omitempty"`
    Price         float64 `json:"price,omitempty"`
}

type SpotWallet struct {
    Assets []SpotAsset `json:"assets"`
}
```

- Add protobuf messages `SpotSymbolMetadata`, `SpotSymbolFilter`, `SpotAccountCapability`, and `SymbolCatalogEntry`; add `repeated SpotSymbolMetadata spot_symbols = 12` and `SpotAccountCapability spot_account = 13` to `VenueSnapshot`. Add `repeated SymbolCatalogEntry entries = 3` to `ListSymbolsResponse` while preserving legacy `symbols` and `stale` fields.
- Add exact balance strings `available_decimal = 6`, `locked_decimal = 7`, and `wallet_decimal = 8` to `BalanceEntry`; doubles remain display-only compatibility values.
- Keep `SpotWallet.free`, `SpotWallet.locked`, `SpotAsset.symbol`, and `SpotAsset.qty` with `[deprecated=true]`; add `SpotAsset.asset`, `free`, `free_decimal`, and `locked_decimal` on new field numbers. Canonical writers include USDT as an ordinary asset and leave deprecated wallet-level USDT fields unset.
- `UnmarshalJSON` accepts either canonical fields or the legacy `symbol/qty` plus wallet-level USDT representation. It rejects one payload that represents the same asset in both forms with conflicting values. `MarshalJSON` emits canonical form only.

- [ ] **Step 1: Write RED compatibility and canonicalization tests**

```go
func TestSpotWalletReadsLegacyAndWritesCanonicalAssets(t *testing.T) {
    raw := []byte(`{"free":100,"locked":2,"assets":[{"symbol":"BTC","qty":0.25,"locked":0.01}]}`)
    var wallet domain.SpotWallet
    if err := json.Unmarshal(raw, &wallet); err != nil {
        t.Fatal(err)
    }
    got := assetMap(wallet.Assets)
    if got["USDT"].Free != 100 || got["USDT"].Locked != 2 || got["BTC"].Free != 0.25 {
        t.Fatalf("canonical assets = %#v", got)
    }
    encoded, err := json.Marshal(wallet)
    if err != nil {
        t.Fatal(err)
    }
    if bytes.Contains(encoded, []byte(`"symbol"`)) || bytes.Contains(encoded, []byte(`"qty"`)) {
        t.Fatalf("legacy fields leaked into canonical JSON: %s", encoded)
    }
}

func TestSpotWalletRejectsConflictingCanonicalAndLegacyAsset(t *testing.T) {
    raw := []byte(`{"free":100,"assets":[{"asset":"USDT","free":99}]}`)
    var wallet domain.SpotWallet
    if err := json.Unmarshal(raw, &wallet); err == nil {
        t.Fatal("expected conflicting USDT representations to fail")
    }
}
```

Run:

```bash
cd /Users/xdy/Workplace/hushine-worktrees/medium-cleanup/core-service
go test ./internal/domain ./internal/service -run 'TestSpotWallet|TestVenueSnapshotSpot' -count=1
```

Expected RED: compile errors for canonical fields and metadata, followed by the conflict/canonical-write assertions failing until the custom codec and mappings exist.

- [ ] **Step 2: Add additive protobuf fields and canonical domain conversion**

Use distinct asset and symbol types in protobuf:

```protobuf
message SpotAsset {
  string symbol = 1 [deprecated = true];
  double qty = 2 [deprecated = true];
  double locked = 3 [deprecated = true];
  double avg_entry_price = 4;
  optional double price = 5;
  string asset = 6;
  double free = 7;
  string free_decimal = 8;
  string locked_decimal = 9;
}

message SpotSymbolMetadata {
  string symbol = 1;
  string status = 2;
  string base_asset = 3;
  string quote_asset = 4;
  int32 base_asset_precision = 5;
  int32 quote_asset_precision = 6;
  bool spot_trading_allowed = 7;
  repeated SpotSymbolPermissionSet permission_sets = 8;
  repeated string order_types = 9;
  repeated SpotSymbolFilter filters = 10;
  int64 snapshot_time_ms = 11;
}

message SpotSymbolPermissionSet {
  repeated string alternatives = 1;
}

message SpotSymbolFilter {
  string filter_type = 1;
  string min_price = 2;
  string max_price = 3;
  string tick_size = 4;
  string min_qty = 5;
  string max_qty = 6;
  string step_size = 7;
  string min_notional = 8;
  string max_notional = 9;
  bool apply_to_market = 10;
  bool apply_min_to_market = 11;
  bool apply_max_to_market = 12;
  int32 avg_price_mins = 13;
  int64 limit = 14;
  string multiplier_up = 15;
  string multiplier_down = 16;
  string bid_multiplier_up = 17;
  string bid_multiplier_down = 18;
  string ask_multiplier_up = 19;
  string ask_multiplier_down = 20;
  string raw_json = 21;
  string max_position = 22;
  int64 max_num_orders = 23;
  int64 max_num_algo_orders = 24;
  int64 max_num_iceberg_orders = 25;
  int64 max_num_order_amends = 26;
  int64 max_num_order_lists = 27;
}

message SpotAccountCapability {
  bool can_trade = 1;
  string account_type = 2;
  repeated string permissions = 3;
}

message SymbolCatalogEntry {
  string symbol = 1;
  string base_asset = 2;
  string quote_asset = 3;
  string status = 4;
  bool spot_trading_allowed = 5;
}
```

`SpotSymbolFilter` keeps every Binance numeric field as a string and every market-application flag as an explicit boolean. Never reconstruct decimals from doubles. `permission_sets` preserves Binance's outer-AND/inner-OR structure: an account is eligible only when, for every outer set, its account permissions contain at least one alternative. Never read the deprecated/empty symbol-level `permissions` field as a substitute. Account permissions in `SpotAccountCapability` remain the flat permissions actually granted to that account.

- [ ] **Step 3: Generate protocol code and make focused tests GREEN**

```bash
cd /Users/xdy/Workplace/hushine-worktrees/medium-cleanup/core-service
make proto
gofmt -w internal/domain/model.go internal/domain/spot_wallet.go internal/domain/spot_wallet_test.go internal/service/grpc.go internal/service/wallet_state_proto_test.go internal/service/portfolio_snapshot_test.go
go test ./internal/domain ./internal/service -run 'TestSpotWallet|TestVenueSnapshotSpot' -count=1
```

Expected GREEN: legacy JSON is accepted, canonical JSON/protobuf contains assets `BTC` and `USDT`, metadata maps without loss, and no pseudo asset `BTCUSDT` appears.

- [ ] **Step 4: Verify and commit core-service only**

```bash
cd /Users/xdy/Workplace/hushine-worktrees/medium-cleanup/core-service
go test ./internal/domain ./internal/service -count=1
git add proto/portfolio_service.proto gen/portfoliov1/portfolio_service.pb.go gen/portfoliov1/portfolio_service_grpc.pb.go internal/domain/model.go internal/domain/spot_wallet.go internal/domain/spot_wallet_test.go internal/service/grpc.go internal/service/wallet_state_proto_test.go internal/service/portfolio_snapshot_test.go
git commit -m "feat(spot): add canonical wallet and metadata contract"
```

Expected: focused packages pass and the commit contains no database rewrite or unrelated generated files.

---

### Task 2: Replace the custom Spot portfolio endpoint with official account reading

**Files:**
- Modify: `core-service/internal/exchange/adapter/capabilities.go`
- Modify: `core-service/internal/exchange/binance/endpoints.go`
- Modify: `core-service/internal/exchange/adapter/errors.go`
- Modify: `core-service/internal/exchange/adapter/factory.go`
- Modify: `core-service/internal/exchange/adapter/registry.go`
- Modify: `core-service/internal/exchange/adapter/registry_test.go`
- Modify: `core-service/internal/exchange/binance/factory.go`
- Modify: `core-service/internal/exchange/binance.go`
- Modify: `core-service/internal/exchange/binance_test.go`
- Modify: `core-service/internal/exchange/binance/portfolio_snapshot.go`
- Create: `core-service/internal/exchange/binance/spot_account.go`
- Create: `core-service/internal/exchange/binance/spot_account_test.go`
- Create: `core-service/internal/exchange/binance/redaction.go`
- Create: `core-service/internal/exchange/binance/redaction_test.go`
- Modify: `core-service/internal/exchange/binance/order_executor.go`
- Modify: `core-service/internal/exchange/binance/order_state_reader.go`
- Modify: `core-service/internal/exchange/binance/order_canceller.go`
- Modify: `core-service/internal/exchange/binance/leverage.go`
- Modify: `core-service/internal/exchange/binance/mockserver/rest_spot.go`
- Modify: `core-service/internal/exchange/binance/mockserver/fixtures.go`
- Modify: `core-service/internal/exchange/binance/mockserver/scenario.go`
- Modify: `core-service/internal/exchange/binance/mockserver/server_test.go`
- Modify: `core-service/internal/exchange/binance/mockserver_integration_test.go`
- Modify: `core-service/internal/service/grpc.go`
- Modify: `core-service/internal/service/portfolio_snapshot_test.go`
- Modify: `core-service/cmd/core-service/main.go`
- Create: `core-service/cmd/core-service/main_test.go`

**Interfaces:**
- Replace the implementation-only route with a bound route:

```go
type Route struct {
    VenueID     int64
    Exchange    domain.Exchange
    Environment domain.Environment
    Market      domain.Market
}

type ImplementationRoute struct {
    Exchange    domain.Exchange
    Environment domain.Environment
    Market      domain.Market
}
```

- Registry stores reusable implementations by `ImplementationRoute`, but every public capability resolution takes a full `Route`, returns a venue-bound capability, and validates that each request's venue/exchange/environment/market matches that binding. This permits static registration without sharing mutable account state or credentials across venues.
- Preserve `PortfolioSnapshotReader.ReadPortfolioSnapshot(context.Context, adapter.PortfolioSnapshotRequest)` but choose the implementation from the factory's full `adapter.Route`.
- Add `VenueID`, `Exchange`, `Environment`, and `Market` to `SymbolRulesRequest`; credentials remain request-scoped. Reader/cache state never stores credential material.
- `adapter.BalanceEntry` gains `AvailableDecimal` and `LockedDecimal`; display doubles are derived once after validating decimal strings.
- `adapter.PortfolioSnapshot` gains `SpotAccount *SpotAccountCapability` with `CanTrade`, `AccountType`, and copied `Permissions`; preflight consumes this field and proto mapping exposes it without credential material.
- Produce structured adapter errors `SPOT_ACCOUNT_NETWORK`, `SPOT_ACCOUNT_SIGNATURE`, `SPOT_ACCOUNT_PERMISSION`, `SPOT_ACCOUNT_TRADING_DISABLED`, and `SPOT_ACCOUNT_SCHEMA`.
- `spotAccountReader` sends exactly one signed `GET /api/v3/account`; it never calls `/fapi/*` or `/api/v3/portfolio`.
- Every signed Binance reader/executor wraps transport/status errors through one sanitizer that strips query strings, form bodies, `signature`, API key/secret values, and Authorization/header values before constructing adapter errors or logs. Safe errors retain method, endpoint path, HTTP status, Binance code, and a bounded redacted message only.
- `PortfolioGRPCService.GetVenueOnlineInfo` resolves active Binance Spot Demo Venues through the same venue-bound adapter capability and maps the canonical account snapshot; it no longer rejects every non-Futures online Venue. The legacy top-level `BinanceAdapter.GetOnlineInfo` becomes explicitly Futures-only: remove its Spot fetch/valuation leg and delete `fetchSpotPortfolio`, so no executable fallback can retain `/api/v3/portfolio`. `cmd/core-service/main.go` continues wiring that legacy router only for the existing Futures Venue path and wires the route-aware registry for Spot; a startup wiring test proves Spot online info selects the registry rather than the legacy aggregate fetcher.

- [ ] **Step 1: Write RED official-shape and route-isolation tests**

```go
func TestSpotSnapshotUsesOfficialAccountEndpointOnly(t *testing.T) {
    server := mockserver.New(t, mockserver.Scenario{
        SpotAccount: mockserver.SpotAccountFixture{
            CanTrade: true,
            AccountType: "SPOT",
            Permissions: []string{"SPOT"},
            Balances: []mockserver.SpotBalanceFixture{
                {Asset: "USDT", Free: "100.01000000", Locked: "0.00000000"},
                {Asset: "BTC", Free: "0.25000000", Locked: "0.01000000"},
                {Asset: "BNB", Free: "1.00000000", Locked: "0.00000000"},
            },
        },
    })
    reader := newSpotReaderForTest(t, server.URL())
    snapshot, err := reader.ReadPortfolioSnapshot(context.Background(), spotSnapshotRequest())
    if err != nil {
        t.Fatal(err)
    }
    if server.Count("GET", "/api/v3/account") != 1 || server.CountPrefix("/fapi/") != 0 {
        t.Fatalf("requests = %#v", server.Requests())
    }
    assertBalanceDecimal(t, snapshot.Balances, "USDT", "100.01000000", "0.00000000")
    assertBalanceDecimal(t, snapshot.Balances, "BTC", "0.25000000", "0.01000000")
}
```

Add table cases for `canTrade=false`, missing `balances`, Binance `-1022` signature failure, HTTP timeout, and a Spot-only credential whose Futures endpoint returns 403.
Add a registry test with two Spot Venue IDs that share one implementation endpoint but use different credentials and account fixtures; each bound reader must return only its own venue/account facts, and a mismatched request VenueID must fail before network I/O.
Add `GetVenueOnlineInfo` tests for an owned active Binance Spot Demo Venue, wrong owner, inactive Venue, invalid Spot credentials, and the existing Futures path. The Spot success case must observe `/api/v3/account`, canonical `BTC`/`USDT` assets, and zero calls to the retired endpoint or legacy aggregate router. Add startup wiring coverage in `cmd/core-service/main_test.go`.
Add sentinel redaction tests that force network/status/decode failures containing a fake API key, secret, signature query, form body, and Authorization header through account, order placement, state read, cancel, and leverage paths; assert none of the sentinel values or `signature=` appears in returned errors, logs, gRPC details, or mock evidence.

Run:

```bash
cd /Users/xdy/Workplace/hushine-worktrees/medium-cleanup/core-service
go test ./internal/exchange/... ./internal/service -run 'TestSpotSnapshot|TestSpotAccount|TestMockServerSpotAccount|TestGetVenueOnlineInfo.*Spot|TestBinance.*Redact' -count=1
```

Expected RED: mock server has no `/api/v3/account` contract and factory still rejects Spot through the perpetual-futures guard.

- [ ] **Step 2: Implement the official reader and delete the custom proof path**

Decode Binance strings without changing them:

```go
type spotAccountResponse struct {
    CanTrade    bool          `json:"canTrade"`
    AccountType string        `json:"accountType"`
    Permissions []string      `json:"permissions"`
    Balances    []spotBalance `json:"balances"`
}

type spotBalance struct {
    Asset  string `json:"asset"`
    Free   string `json:"free"`
    Locked string `json:"locked"`
}
```

Retain every asset whose exact free or locked value is non-zero. Record account capability separately; never synthesize a top-level USDT balance. Remove `/api/v3/portfolio` from mocks, `internal/exchange/binance.go`, and production/service usage in the same commit so no test can prove compatibility through the retired endpoint. Preserve `/fapi/v3/portfolio` because it is a distinct approved Futures endpoint.

- [ ] **Step 3: Make official account contract tests GREEN**

```bash
cd /Users/xdy/Workplace/hushine-worktrees/medium-cleanup/core-service
gofmt -w internal/exchange/adapter internal/exchange/binance
go test ./internal/exchange/... ./internal/service -run 'TestSpotSnapshot|TestSpotAccount|TestMockServerSpotAccount|TestGetVenueOnlineInfo.*Spot|TestBinance.*Redact' -count=1
if rg -n '/api/v3/portfolio' internal --glob '!**/*_test.go'; then
  echo 'retired Binance Spot portfolio endpoint remains in executable core code' >&2
  exit 1
fi
rg -n 'requirePerpetualFutures' internal/exchange/binance
```

Expected GREEN: all named tests pass; `rg` finds no `/api/v3/portfolio`, and any remaining `requirePerpetualFutures` use is confined to genuinely Futures-only capabilities.

- [ ] **Step 4: Commit core-service only**

```bash
cd /Users/xdy/Workplace/hushine-worktrees/medium-cleanup/core-service
go test ./internal/exchange/adapter ./internal/exchange/binance/... -count=1
test -e internal/exchange/binance/endpoints.go
git add internal/exchange/adapter/capabilities.go internal/exchange/binance/endpoints.go internal/exchange/adapter/errors.go internal/exchange/adapter/factory.go internal/exchange/adapter/registry.go internal/exchange/adapter/registry_test.go internal/exchange/binance/factory.go internal/exchange/binance.go internal/exchange/binance_test.go internal/exchange/binance/portfolio_snapshot.go internal/exchange/binance/spot_account.go internal/exchange/binance/spot_account_test.go internal/exchange/binance/redaction.go internal/exchange/binance/redaction_test.go internal/exchange/binance/order_executor.go internal/exchange/binance/order_state_reader.go internal/exchange/binance/order_canceller.go internal/exchange/binance/leverage.go internal/exchange/binance/mockserver/rest_spot.go internal/exchange/binance/mockserver/fixtures.go internal/exchange/binance/mockserver/scenario.go internal/exchange/binance/mockserver/server_test.go internal/exchange/binance/mockserver_integration_test.go internal/service/grpc.go internal/service/portfolio_snapshot_test.go cmd/core-service/main.go cmd/core-service/main_test.go
git diff --cached --name-only | grep -Fx internal/exchange/binance/endpoints.go
git diff --cached --check
git commit -m "feat(spot): read official Binance account snapshot"
test -z "$(git status --short -- internal/exchange/binance/endpoints.go)"
```

---

### Task 3: Add typed exchangeInfo metadata and the strict five-minute cache

**Files:**
- Modify: `core-service/internal/exchange/adapter/capabilities.go`
- Modify: `core-service/internal/exchange/binance/factory.go`
- Modify: `core-service/internal/exchange/binance/symbol_rules.go`
- Create: `core-service/internal/exchange/binance/spot_metadata.go`
- Create: `core-service/internal/exchange/binance/spot_metadata_test.go`
- Create: `core-service/internal/exchange/binance/spot_metadata_cache.go`
- Create: `core-service/internal/exchange/binance/spot_metadata_cache_test.go`
- Modify: `core-service/internal/exchange/binance/mockserver/exchange_info.go`
- Modify: `core-service/internal/exchange/binance/mockserver/fixtures.go`
- Modify: `core-service/internal/exchange/binance/mockserver/server_test.go`
- Modify: `core-service/internal/catalog/catalog.go`
- Modify: `core-service/internal/catalog/binance_public.go`
- Modify: `core-service/internal/catalog/catalog_test.go`
- Modify: `core-service/internal/service/grpc.go`

**Interfaces:**
- Keep the existing Futures `adapter.SymbolRule` shape and every current consumer unchanged in this commit. Add a distinct exact Spot contract instead of replacing shared fields before their consumers migrate:

```go
type SpotSymbolRule struct {
    Symbol              string
    Status              string
    BaseAsset           string
    QuoteAsset          string
    BaseAssetPrecision  int32
    QuoteAssetPrecision int32
    SpotTradingAllowed  bool
    PermissionSets      [][]string
    OrderTypes          []string
    Filters             []SymbolFilter
}

type SymbolFilter struct {
    FilterType                                      string
    MinPrice, MaxPrice, TickSize                    string
    MinQty, MaxQty, StepSize                        string
    MinNotional, MaxNotional                        string
    MultiplierUp, MultiplierDown                    string
    BidMultiplierUp, BidMultiplierDown              string
    AskMultiplierUp, AskMultiplierDown              string
    ApplyToMarket, ApplyMinToMarket, ApplyMaxToMarket bool
    AvgPriceMins                                    int32
    Limit                                           int64
    MaxPosition                                     string
    MaxNumOrders, MaxNumAlgoOrders                  int64
    MaxNumIcebergOrders, MaxNumOrderAmends          int64
    MaxNumOrderLists                                int64
    RawJSON                                         string
}

type AccountFilterSnapshot struct {
    ExchangeFilters []SymbolFilter
    SymbolFilters   []SymbolFilter
    AssetFilters    []AssetFilter
}

type AssetFilter struct {
    FilterType string
    Asset      string
    Limit      string
}
```

- Add `ReadSpotSymbolRulesSnapshot(ctx, req) (SpotSymbolRulesSnapshot, error)` where `RulesBySymbol` is `map[string]SpotSymbolRule` and the snapshot has `ReadAt`, endpoint, and environment identity. Preserve `permissionSets` exactly as nested sets and reject empty inner sets or malformed members. The existing Futures `ReadSymbolRules` interface, `SymbolRule.Market/MinQty/StepSize/MinNotional/TickSize` fields, `/fapi/v1/exchangeInfo` parser, and risk consumers remain present and compile throughout Tasks 3-4B; Spot consumers use only the new type.
- Cache key is `{Endpoint, Environment, Symbol}`; TTL is exactly `5*time.Minute`; inject `Clock` for deterministic tests; singleflight concurrent refreshes; expired entries are never returned when refresh fails.
- Extend the public display catalog to return Binance-provided base/quote/status/Spot flags in `SymbolCatalogEntry`; its existing stale/display policy does not enter preflight or risk. UI may use it to name an asset, but core always revalidates the target through the strict five-minute risk snapshot.

- [ ] **Step 1: Write RED metadata parsing and cache-boundary tests**

```go
func TestSpotMetadataPreservesOfficialFiltersExactly(t *testing.T) {
    fixture := officialSpotExchangeInfoFixture("BTCUSDT")
    rule, err := parseSpotSymbolRule(fixture.Symbols[0])
    if err != nil {
        t.Fatal(err)
    }
    if rule.BaseAsset != "BTC" || rule.QuoteAsset != "USDT" || !rule.SpotTradingAllowed {
        t.Fatalf("metadata = %#v", rule)
    }
    lot := requireFilter(t, rule.Filters, "LOT_SIZE")
    if lot.StepSize != "0.00001000" || lot.MinQty != "0.00001000" {
        t.Fatalf("LOT_SIZE = %#v", lot)
    }
}

func TestSpotMetadataCacheDoesNotServeExpiredRulesAfterRefreshFailure(t *testing.T) {
    clock := newFakeClock(time.Unix(100, 0))
    upstream := newScriptedMetadataSource(successfulRules(), errors.New("exchange unavailable"))
    cache := newSpotMetadataCache(upstream, clock.Now, 5*time.Minute)
    if _, err := cache.Read(context.Background(), demoSpotKey("BTCUSDT")); err != nil {
        t.Fatal(err)
    }
    clock.Advance(5*time.Minute + time.Nanosecond)
    if _, err := cache.Read(context.Background(), demoSpotKey("BTCUSDT")); err == nil {
        t.Fatal("expired metadata must not be used after refresh failure")
    }
}
```

Also test endpoint/environment/symbol isolation, `4m59.999s` cache hit, exactly `5m` refresh, concurrent singleflight, disabled filter zero values, exact `maxPosition` and order-count fields, preservation of an unknown filter type, and a catalog response whose `BTCUSDT` entry exposes `base_asset=BTC` without string slicing. Use official permission fixtures for `[["SPOT","MARGIN"]]`, `[["SPOT"],["TRD_GRP_004","TRD_GRP_005"]]`, empty legacy `permissions`, and malformed/empty sets; assert the nested AND-of-OR structure survives domain, protobuf, cache copy, and preflight evaluation. Add `TestFuturesSymbolRuleContractUnchanged` and `TestFuturesExchangeInfoAndRiskControl`: the first compiles every existing field consumer, and the second records only `/fapi/v1/exchangeInfo` while validating current Futures min-qty/step/notional/tick behavior for MARKET and LIMIT.

Run:

```bash
cd /Users/xdy/Workplace/hushine-worktrees/medium-cleanup/core-service
go test ./internal/exchange/binance ./internal/catalog ./internal/service ./internal/order/risk -run 'TestSpotMetadata|TestSpotExchangeInfo|TestListSymbols.*Spot|TestFuturesSymbolRuleContractUnchanged|TestFuturesExchangeInfoAndRiskControl' -count=1
```

Expected RED: current reader calls `/fapi/v1/exchangeInfo`, loses official fields to floats, and has no strict TTL behavior.

- [ ] **Step 2: Implement `/api/v3/exchangeInfo` batching, parsing, and immutable snapshots**

Request all unique declared Spot symbols in one query using Binance's `symbols` JSON parameter. Validate that each requested symbol has exactly one response. Decode official `permissionSets` as nested arrays; the deprecated flat `permissions` field may be empty and is never used for admission. Deep-copy nested permission sets, filters, slices, and maps when constructing a snapshot so later refresh cannot mutate an in-flight preflight. Treat malformed decimals, duplicate filters, missing symbols, empty permission alternatives/sets, and unknown schema as structured metadata errors. Do not delete or rename a Futures field or migrate a shared risk consumer in this task; the additive Spot reader makes the Task 3 commit independently buildable.

- [ ] **Step 3: Make parsing and cache tests GREEN**

```bash
cd /Users/xdy/Workplace/hushine-worktrees/medium-cleanup/core-service
gofmt -w internal/exchange/adapter/capabilities.go internal/exchange/binance internal/catalog internal/service/grpc.go
go test ./internal/exchange/binance ./internal/catalog ./internal/service ./internal/order/risk -run 'TestSpotMetadata|TestSpotExchangeInfo|TestListSymbols.*Spot|TestFuturesSymbolRuleContractUnchanged|TestFuturesExchangeInfoAndRiskControl' -count=1
go test ./... && go vet ./...
```

Expected GREEN: Spot calls only `/api/v3/exchangeInfo`, exact filter strings survive, the five-minute boundary is deterministic, and an expired refresh failure is returned.

- [ ] **Step 4: Commit core-service only**

```bash
cd /Users/xdy/Workplace/hushine-worktrees/medium-cleanup/core-service
go test ./... && go vet ./...
git add internal/exchange/adapter/capabilities.go internal/exchange/binance/factory.go internal/exchange/binance/symbol_rules.go internal/exchange/binance/spot_metadata.go internal/exchange/binance/spot_metadata_test.go internal/exchange/binance/spot_metadata_cache.go internal/exchange/binance/spot_metadata_cache_test.go internal/exchange/binance/mockserver/exchange_info.go internal/exchange/binance/mockserver/fixtures.go internal/exchange/binance/mockserver/server_test.go internal/catalog/catalog.go internal/catalog/binance_public.go internal/catalog/catalog_test.go internal/service/grpc.go
git commit -m "feat(spot): add typed Binance metadata cache"
```

---

### Task 4A: Add the default-off Spot capability truth and drain policy

**Files:**
- Modify: `core-service/proto/portfolio_service.proto`
- Regenerate: `core-service/gen/portfoliov1/portfolio_service.pb.go`
- Regenerate: `core-service/gen/portfoliov1/portfolio_service_grpc.pb.go`
- Modify: `core-service/internal/config/config.go`
- Modify: `core-service/internal/config/config_test.go`
- Create: `core-service/internal/capability/policy.go`
- Create: `core-service/internal/capability/policy_test.go`
- Modify: `core-service/internal/service/grpc.go`
- Create: `core-service/internal/service/product_capabilities_test.go`
- Modify: `core-service/cmd/core-service/main.go`
- Modify: `core-service/cmd/core-service/main_test.go`
- Modify: `core-service/config.yaml`

**Interfaces:**
- Add one core-owned immutable policy object. No consumer reads environment variables directly:

```go
type SpotUSDTFlags struct {
    Backtest bool `yaml:"backtest_spot_usdt"`
    Demo     bool `yaml:"demo_spot_usdt"`
    Offline  bool `yaml:"offline_spot_usdt"`
    Live     bool `yaml:"live_spot_usdt"`
}

type SpotAction string

const (
    SpotActionStart     SpotAction = "start"
    SpotActionOrder     SpotAction = "order"
    SpotActionClose     SpotAction = "close"
    SpotActionDebug     SpotAction = "debug_package"
    SpotActionReconcile SpotAction = "reconcile"
)

type Decision struct {
    Capability string
    Configured bool
    Effective  bool
    DrainOnly  bool
    Code       string
}

func (p Policy) Check(environment domain.Environment, action SpotAction, activeSession bool) Decision
```

- Config section is exactly `product_capabilities.spot_usdt` and environment overrides are exactly `BACKTEST_SPOT_USDT_ENABLED`, `DEMO_SPOT_USDT_ENABLED`, `OFFLINE_SPOT_USDT_ENABLED`, and `LIVE_SPOT_USDT_ENABLED`. Missing values are false. Invalid booleans fail config load; they do not silently enable or disable a flag.
- Add `GetProductCapabilities` to `portfolio.v1`. The response contains one entry per exact capability name with `configured`, `effective`, and a stable `reason`. The service reports `live_spot_usdt.configured=true` when misconfigured that way but always reports `effective=false` and `reason=SPOT_LIVE_ROLLOUT_GUARD`.
- `start`, `order`, and `debug_package` require the matching effective flag. A disabled flag returns `SPOT_CAPABILITY_DISABLED` and the exact capability name before credentials, repository mutation, Runtime dispatch, risk, or network I/O.
- Disabling Demo while a Session is running is a drain, not abandonment: new start and ordinary PlaceOrder fail; lifecycle ingestion, queries, authoritative reconciliation, STOP_ONLY, and `CloseSpotTargets` for an already-active owned Session remain admitted with `DrainOnly=true`. A disabled close request for a nonexistent, terminal, or unowned Session fails. A drain never enables a new Session or a new ordinary order.
- Futures routes bypass this Spot policy and retain their existing gates. The Live rollout guard is checked independently after capability evaluation so no flag value can enable Live Spot.

Use these additive messages and field numbers:

```protobuf
message ProductCapabilityState {
  string name = 1;
  bool configured = 2;
  bool effective = 3;
  string reason = 4;
}

message GetProductCapabilitiesRequest {}

message GetProductCapabilitiesResponse {
  repeated ProductCapabilityState capabilities = 1;
}
```

- [ ] **Step 1: Write RED config, policy, and discovery tests**

```go
func TestSpotUSDTCapabilitiesDefaultFalseAndLiveCannotBeEnabled(t *testing.T) {
    cfg := config.Default()
    policy := capability.NewPolicy(cfg.ProductCapabilities.SpotUSDT)
    got := policy.Snapshot()
    for _, name := range []string{
        "backtest_spot_usdt", "demo_spot_usdt", "offline_spot_usdt", "live_spot_usdt",
    } {
        if got[name].Configured || got[name].Effective {
            t.Fatalf("%s unexpectedly enabled: %#v", name, got[name])
        }
    }
    policy = capability.NewPolicy(config.SpotUSDTFlags{Live: true})
    if got := policy.Snapshot()["live_spot_usdt"]; !got.Configured || got.Effective || got.Reason != "SPOT_LIVE_ROLLOUT_GUARD" {
        t.Fatalf("live decision = %#v", got)
    }
}

func TestDisabledDemoAllowsOnlyOwnedActiveSessionDrain(t *testing.T) {
    policy := capability.NewPolicy(config.SpotUSDTFlags{})
    if got := policy.Check(domain.EnvironmentDemo, capability.SpotActionOrder, true); got.Effective {
        t.Fatalf("ordinary order admitted: %#v", got)
    }
    if got := policy.Check(domain.EnvironmentDemo, capability.SpotActionClose, true); !got.Effective || !got.DrainOnly {
        t.Fatalf("active close drain rejected: %#v", got)
    }
    if got := policy.Check(domain.EnvironmentDemo, capability.SpotActionClose, false); got.Effective {
        t.Fatalf("non-session close admitted: %#v", got)
    }
}
```

Add table tests for each flag independently enabled, invalid env boolean, effective discovery ordering, config reload from true to false, disabled Backtest/Demo/offline start/debug, Live misconfiguration, reconciliation during drain, terminal Session close rejection, and a Futures Backtest/Demo/Live matrix that is byte-for-byte unchanged.

Run:

```bash
cd /Users/xdy/Workplace/hushine-worktrees/medium-cleanup/core-service
make proto
go test ./internal/config ./internal/capability ./internal/service ./cmd/core-service -run 'TestSpotUSDTCapabilit|TestDisabledDemo|TestGetProductCapabilities|TestFuturesCapabilityPolicy' -count=1
```

Expected RED: config and protobuf fields do not exist and there is no centralized policy or discovery RPC.

- [ ] **Step 2: Implement the immutable policy and core discovery RPC**

Parse overrides once at startup and inject one policy instance into portfolio service, order service, close planner, and later reconciliation wiring. Sort discovery entries by name. Return no endpoint, credential, or internal address. The policy API must be pure and race-free so tests can construct old/new snapshots to model a config rollout without mutable global state.

- [ ] **Step 3: Make policy and discovery tests GREEN**

```bash
cd /Users/xdy/Workplace/hushine-worktrees/medium-cleanup/core-service
make proto
gofmt -w internal/config internal/capability internal/service/product_capabilities_test.go internal/service/grpc.go cmd/core-service
go test ./internal/config ./internal/capability ./internal/service ./cmd/core-service -run 'TestSpotUSDTCapabilit|TestDisabledDemo|TestGetProductCapabilities|TestFuturesCapabilityPolicy' -count=1
go test ./... && go vet ./...
```

Expected GREEN: all configured/effective values default false, Live stays ineffective under misconfiguration, drain-only semantics are explicit, and every Futures control is unchanged.

- [ ] **Step 4: Commit core-service only**

```bash
cd /Users/xdy/Workplace/hushine-worktrees/medium-cleanup/core-service
test -e config.yaml
git add proto/portfolio_service.proto gen/portfoliov1/portfolio_service.pb.go gen/portfoliov1/portfolio_service_grpc.pb.go internal/config/config.go internal/config/config_test.go internal/capability/policy.go internal/capability/policy_test.go internal/service/grpc.go internal/service/product_capabilities_test.go cmd/core-service/main.go cmd/core-service/main_test.go config.yaml
git diff --cached --check
git commit -m "feat(spot): add default-off product capability policy"
test -z "$(git status --short -- proto/portfolio_service.proto gen/portfoliov1/portfolio_service.pb.go gen/portfoliov1/portfolio_service_grpc.pb.go internal/config internal/capability internal/service/grpc.go internal/service/product_capabilities_test.go cmd/core-service/main.go cmd/core-service/main_test.go config.yaml)"
```

---

### Task 4B: Enforce Spot preflight and Live admission with one metadata snapshot

**Files:**
- Modify: `core-service/proto/portfolio_service.proto`
- Regenerate: `core-service/gen/portfoliov1/portfolio_service.pb.go`
- Regenerate: `core-service/gen/portfoliov1/portfolio_service_grpc.pb.go`
- Modify: `core-service/cmd/core-service/exchange_registry.go`
- Modify: `core-service/cmd/core-service/exchange_registry_test.go`
- Modify: `core-service/internal/service/grpc.go`
- Modify: `core-service/internal/service/grpc_portfolio_meta_test.go`
- Modify: `core-service/internal/service/portfolio_snapshot_test.go`
- Modify: `core-service/internal/exchange/binance/factory_test.go`

**Interfaces:**
- `PreflightStrategySession` batches `INPUTS ∪ ORDER_TARGETS` per route, validates every Spot symbol from one `SymbolRulesSnapshot`, and returns all target-specific `PreflightIssue`s while making the overall result false if any target fails.
- Add stable codes: `SPOT_LIVE_ROLLOUT_GUARD`, `SPOT_SYMBOL_MISSING`, `SPOT_QUOTE_UNSUPPORTED`, `SPOT_SYMBOL_NOT_TRADING`, `SPOT_TRADING_DISABLED`, `SPOT_ACCOUNT_PERMISSION`, `SPOT_ORDER_TYPE_UNSUPPORTED`, and `SPOT_METADATA_UNAVAILABLE`.
- Add `int64 venue_id = 6` and `string filter_type = 7` to `PreflightIssue` so callers never infer route/filter identity from message text.
- Extend `RequiredSymbol` additively with the currently unused immutable numbers `bool order_target = 4` and `repeated string required_order_types = 5`; strategy-service fills `MARKET` and `LIMIT` for declared targets because those are the two platform-supported dynamic decisions. `TestRequiredSymbolDescriptorFieldNumbers` asserts fields 1-3 remain unchanged and the new fields are exactly 4/5; Task 7's Python consumer adds the same descriptor assertion before using either field.
- Snapshot and preflight responses use the same immutable metadata instance for all symbols in a route.
- Before metadata, credentials, or network I/O, call the Task 4A policy with `SpotActionStart`: Backtest requires effective `backtest_spot_usdt`, Demo requires effective `demo_spot_usdt`, and Live always returns `SPOT_LIVE_ROLLOUT_GUARD`. Tests that exercise later validation explicitly enable the matching flag; no test relies on a permissive default.

- [ ] **Step 1: Write RED admission and preflight matrix tests**

```go
func TestPreflightSpotUsesOneSnapshotAndValidatesEveryTarget(t *testing.T) {
    reader := &countingRulesReader{snapshot: spotRulesSnapshot(
        tradingSpotRule("BTCUSDT", "BTC", "USDT", "MARKET", "LIMIT"),
        tradingSpotRule("ETHBTC", "ETH", "BTC", "MARKET", "LIMIT"),
    )}
    svc := newPreflightServiceWithRules(t, reader)
    resp, err := svc.PreflightStrategySession(context.Background(), spotPreflightRequest(
        requiredTarget("BTCUSDT", "MARKET"),
        requiredTarget("ETHBTC", "MARKET"),
        requiredTarget("MISSINGUSDT", "LIMIT"),
    ))
    if err != nil {
        t.Fatal(err)
    }
    if resp.Ok || reader.Calls != 1 {
        t.Fatalf("response=%#v calls=%d", resp, reader.Calls)
    }
    assertIssueCode(t, resp.Issues, "ETHBTC", "SPOT_QUOTE_UNSUPPORTED")
    assertIssueCode(t, resp.Issues, "MISSINGUSDT", "SPOT_SYMBOL_MISSING")
}

func TestRegistryRejectsLiveSpotButKeepsLiveFutures(t *testing.T) {
    registry := buildExchangeRegistry(testConfig())
    requireRouteErrorCode(t, registry, liveSpotRoute(), "SPOT_LIVE_ROLLOUT_GUARD")
    requireRouteAvailable(t, registry, liveFuturesRoute())
}
```

Add all-four-flags-disabled, Backtest-only enabled, Demo-only enabled, capability-policy-unavailable, account permission, status, spotTradingAllowed, required order type, Spot-only key, Backtest no-network, Demo route, and same-symbol Spot/Futures isolation cases. Cover official permission semantics explicitly: `[[SPOT,MARGIN]]` admits an account with either permission; `[[SPOT],[TRD_GRP_004,TRD_GRP_005]]` requires SPOT plus at least one trading-group permission; an account with only one outer set fails. The old symbol `permissions=[]` must neither reject nor admit when valid `permissionSets` are present.

Run:

```bash
cd /Users/xdy/Workplace/hushine-worktrees/medium-cleanup/core-service
make proto
go test ./cmd/core-service ./internal/service ./internal/exchange/binance -run 'TestPreflightSpot|TestRegistryRejectsLiveSpot|TestSpotOnlyCredential|TestRequiredSymbolDescriptorFieldNumbers' -count=1
```

Expected RED: Live Spot is registered, Spot preflight is rejected by the Futures guard or reduced to a symbol-presence check, and route batching is absent.

- [ ] **Step 2: Implement route admission and snapshot-consistent preflight**

Validate route facts before credentials or network calls. Restrict leverage setup to Futures routes. Attach the exact metadata snapshot used by preflight to each Spot `VenueSnapshot`, and make portfolio snapshot reuse that metadata instead of initiating a second refresh inside the same call.

- [ ] **Step 3: Make the complete preflight matrix GREEN**

```bash
cd /Users/xdy/Workplace/hushine-worktrees/medium-cleanup/core-service
make proto
gofmt -w cmd/core-service/exchange_registry.go cmd/core-service/exchange_registry_test.go internal/service
go test ./cmd/core-service ./internal/service ./internal/exchange/binance -run 'TestPreflightSpot|TestRegistryRejectsLiveSpot|TestSpotOnlyCredential|TestRequiredSymbolDescriptorFieldNumbers' -count=1
```

Expected GREEN: disabled capabilities fail before side effects, an enabled Backtest performs no network I/O, enabled Demo Spot-only credentials pass, invalid targets produce exact codes in a single response, Live Spot fails before exchange I/O, and Futures remains available.

- [ ] **Step 4: Commit core-service only**

```bash
cd /Users/xdy/Workplace/hushine-worktrees/medium-cleanup/core-service
go test ./cmd/core-service ./internal/service ./internal/exchange/binance/... -count=1
git add proto/portfolio_service.proto gen/portfoliov1/portfolio_service.pb.go gen/portfoliov1/portfolio_service_grpc.pb.go cmd/core-service/exchange_registry.go cmd/core-service/exchange_registry_test.go internal/service/grpc.go internal/service/grpc_portfolio_meta_test.go internal/service/portfolio_snapshot_test.go internal/exchange/binance/factory_test.go
for path in proto/portfolio_service.proto gen/portfoliov1/portfolio_service.pb.go gen/portfoliov1/portfolio_service_grpc.pb.go; do
  test -e "$path"
  git diff --cached --name-only | grep -Fx "$path"
done
git diff --cached --check
git commit -m "feat(spot): enforce route-aware preflight admission"
commit_sha="$(git rev-parse HEAD)"
workspace_root=/Users/xdy/Workplace/hushine-worktrees/medium-cleanup
test -f "$workspace_root/golang-lib/go.mod"
grep -Fq 'replace github.com/hushine-tech/golang-lib => ../golang-lib' go.mod
clean_tree="$(mktemp -d "$workspace_root/.spot-clean-core.XXXXXX")"
case "$clean_tree" in "$workspace_root"/.spot-clean-core.*) ;; *) exit 1 ;; esac
git worktree add --detach "$clean_tree" "$commit_sha"
trap 'git worktree remove --force "$clean_tree"; rm -rf "$clean_tree"' EXIT
(cd "$clean_tree" && test -f ../golang-lib/go.mod)
(cd "$clean_tree" && go test ./... && go vet ./...)
git worktree remove "$clean_tree"
rm -rf "$clean_tree"
trap - EXIT
test -z "$(git status --short -- proto/portfolio_service.proto gen/portfoliov1/portfolio_service.pb.go gen/portfoliov1/portfolio_service_grpc.pb.go cmd/core-service/exchange_registry.go cmd/core-service/exchange_registry_test.go internal/service/grpc.go internal/service/grpc_portfolio_meta_test.go internal/service/portfolio_snapshot_test.go internal/exchange/binance/factory_test.go)"
```

---
### Task 5: Apply exact Spot risk rules and construct exact Binance orders

**Files:**
- Modify: `core-service/proto/portfolio_service.proto`
- Regenerate: `core-service/gen/portfoliov1/portfolio_service.pb.go`
- Regenerate: `core-service/gen/portfoliov1/portfolio_service_grpc.pb.go`
- Modify: `core-service/proto/order_service.proto`
- Regenerate: `core-service/gen/orderv1/order_service.pb.go`
- Regenerate: `core-service/gen/orderv1/order_service_grpc.pb.go`
- Modify: `core-service/internal/exchange/adapter/capabilities.go`
- Modify: `core-service/internal/order/risk/types.go`
- Create: `core-service/internal/order/risk/decimal.go`
- Create: `core-service/internal/order/risk/decimal_test.go`
- Create: `core-service/internal/order/risk/backtest_facts.go`
- Create: `core-service/internal/order/risk/backtest_facts_test.go`
- Create: `core-service/internal/order/risk/testdata/spot_filter_contract_v1.json`
- Create: `core-service/cmd/generate-spot-filter-vectors/main.go`
- Create: `core-service/cmd/generate-spot-filter-vectors/main_test.go`
- Modify: `core-service/internal/order/risk/balance.go`
- Modify: `core-service/internal/order/risk/gate.go`
- Modify: `core-service/internal/order/risk/pending.go`
- Modify: `core-service/internal/order/risk/symbol_rules.go`
- Create: `core-service/internal/order/risk/spot_filters.go`
- Create: `core-service/internal/order/risk/spot_filters_test.go`
- Modify: `core-service/internal/order/risk/gate_test.go`
- Modify: `core-service/internal/order/risk/adapter_readers_test.go`
- Modify: `core-service/internal/order/executor/executor.go`
- Modify: `core-service/internal/order/service/grpc.go`
- Modify: `core-service/internal/order/service/grpc_test.go`
- Modify: `core-service/internal/order/repository/repository.go`
- Modify: `core-service/internal/order/repository/timescale.go`
- Modify: `core-service/internal/order/repository/timescale_roundtrip_test.go`
- Create: `core-service/internal/order/metrics.go`
- Create: `core-service/internal/order/metrics_test.go`
- Modify: `core-service/internal/repository/repository.go`
- Modify: `core-service/internal/repository/timescale.go`
- Create: `core-service/internal/storage/migrations/0002_spot_risk_facts.sql`
- Create: `core-service/internal/storage/migrations/spot_risk_facts_migration_test.go`
- Modify: `core-service/internal/exchange/binance/order_executor.go`
- Modify: `core-service/internal/exchange/binance/order_executor_test.go`
- Create: `core-service/internal/exchange/binance/spot_reference_price.go`
- Create: `core-service/internal/exchange/binance/spot_reference_price_test.go`
- Create: `core-service/internal/exchange/binance/spot_account_filters.go`
- Create: `core-service/internal/exchange/binance/spot_account_filters_test.go`
- Modify: `core-service/internal/exchange/binance/order_capability.go`
- Create: `core-service/internal/exchange/binance/order_capability_test.go`
- Modify: `core-service/internal/exchange/binance/mockserver/rest_spot.go`

**Interfaces:**
- Add `string qty_decimal = 19`, `optional string price_decimal = 20`, and `string mark_price_decimal = 21` to `PlaceOrderRequest`. At ingress, choose one authoritative decimal value per field exactly once. If the exact field is present, parse it as an unsigned plain decimal and derive the compatibility `float64` once; the legacy double may be unset/zero or must be numerically equal to that derived display value. A disagreement returns stable `ORDER_DECIMAL_CONFLICT` before audit, repository, risk, executor, or exchange calls. Compare numeric values, not lexical forms (`1`, `1.0`, and `1.000` are equivalent). If the exact field is absent, an admitted legacy double is converted once with `strconv.FormatFloat(value, 'f', -1, 64)`. Risk, audit, repository, and Binance request construction consume only the resulting authoritative string; compatibility doubles are output/display fields and are never converted back into business values.
- Add `requested_qty_decimal = 21` and optional `requested_price_decimal = 22` to `OrderIntentEntry`; add `requested_qty_decimal = 28`, optional `requested_price_decimal = 29`, and `mark_price_decimal = 30` to `OrderAttemptEntry`. Core always emits these from lossless repository strings and derives the legacy doubles for old readers, never the reverse.
- Add `OrderErrorDetail error = 8` to `PlaceOrderResponse` and `ResolveOrderAttemptResponse`, preserving the legacy `error_message`. `OrderErrorDetail` fields are `code = 1`, `message = 2`, `venue_id = 3`, `exchange = 4`, `market = 5`, `symbol = 6`, `filter_type = 7`, `environment = 8`, `retryable = 9`, and `source = 10`. `source` is exactly one of `preflight`, `risk`, `adapter`, `exchange`, `reconciliation`, or `stop`.
- `risk.ReviewRequest` and `adapter.OrderRequest` carry exact decimal strings. `decimal.go` accepts only unsigned plain decimal syntax and uses `math/big.Rat`; exponent notation, negative zero, NaN, and infinity fail.
- Parsing is followed by one side-effect-free `numeric(38,18)` representability and Binance precision check. A value may have at most 20 integer digits and 18 fractional digits after removing insignificant leading integer zeros; exact quantity/base fill/base-or-quote fee fields also obey their official base/quote asset precision, and price/quote fields obey the quote precision plus the stricter filter scale. `ORDER_DECIMAL_OUT_OF_RANGE` or `SPOT_ASSET_PRECISION` returns before audit, repository, risk, executor, or exchange I/O. Repository writes never rely on PostgreSQL rounding or rejection to enforce this contract.
- Spot balance lookup takes explicit `BaseAsset` and `QuoteAsset` from metadata. Delete `baseAsset`, `quoteAsset`, and `quoteAssets` suffix helpers.
- Apply `PRICE_FILTER` to LIMIT, `LOT_SIZE` to LIMIT, `MARKET_LOT_SIZE` to MARKET when enabled, and `LOT_SIZE` as the documented fallback. Apply `MIN_NOTIONAL` and `NOTIONAL` only when their market flags require it. A zero-valued Binance bound disables only that bound.
- For Demo, fetch one signed official `GET /api/v3/myFilters?symbol=...` snapshot for the owned account and merge its exchange, symbol, and asset filters with the public `exchangeInfo` symbol filters; preserve filter scope and exact strings. Enforce the current account-specific `MAX_ASSET` base-asset limit against exact quantity and quote-asset limit against exact notional, plus applicable exchange/symbol order-count limits. Missing, malformed, permission-denied, or stale account-filter facts fail closed before order audit/send.
- Explicitly classify known non-applicable advanced filters for unsupported request features (iceberg, OCO, OTO, SOR). For `PERCENT_PRICE`, `PERCENT_PRICE_BY_SIDE`, `MIN_NOTIONAL`, and `NOTIONAL`, first call official `/api/v3/referencePrice`; use a non-null exact reference price, and only on documented null/`-2043` absence fall back to `/api/v3/avgPrice`, requiring its returned `mins` to match `avgPriceMins` (or documented last-price semantics for zero). Enforce `MAX_POSITION` for BUY as exact base `free + locked + sum(remaining quantity of every open BUY order) + requested quantity`; enforce `MAX_NUM_ORDERS` and other admitted count filters from the same open-order/account-filter snapshot. Any unclassified applicable filter returns `SPOT_FILTER_UNSUPPORTED:<filterType>`.
- `order.v1.PlaceOrder` independently resolves the owned Venue route and rejects `environment=2 && market=spot` with `SPOT_LIVE_ROLLOUT_GUARD` before risk, credentials, or exchange I/O. Preflight/registry/handler/UI guards are defense in depth and cannot substitute for this direct order boundary.
- `order.v1.PlaceOrder` also calls the Task 4A capability policy. A disabled Backtest/Demo flag blocks a new ordinary order even for a still-running Session; Futures is unchanged. STOP_AND_CLOSE does not spoof this path: only the unexported fenced owner from Task 8 can use drain admission for an already-active Session.
- Add exact string fields to `repository.OrderIntent` and `repository.OrderAttempt` (`RequestedQtyDecimal`, optional `RequestedPriceDecimal`, and `MarkPriceDecimal` where applicable). Bind those strings directly to existing `numeric(38,18)` columns and scan numeric values back as text. No schema type change is needed for these columns. Existing repository doubles remain derived display compatibility only and must not be used for inserts, risk replay, recovery, or audit decisions.
- Backtest performs zero Binance I/O. Add additive `SpotRiskFactSnapshot` wire/domain facts containing `snapshot_id`, route, captured time, exact Spot metadata, exchange/symbol/asset filters, and exact reference/average price. Add `repeated SpotRiskFactSnapshot spot_risk_snapshots = 4` to `PreflightStrategySessionResponse`, `SpotRiskFactSnapshot spot_risk_snapshot = 14` to `VenueSnapshot`, and `string spot_risk_snapshot_id = 22` to `PlaceOrderRequest`. Core preflight persists a trusted server-side immutable snapshot in `spot_session_risk_facts`, keyed by `(session_id, venue_id, exchange, market, symbol)`; Backtest risk resolves it by owned Session and ID and ignores caller-authored filter payloads. Missing, stale, mismatched, or mutable facts fail with `SPOT_BACKTEST_FACTS_UNAVAILABLE`. Offline package v2 carries the same fields, not the database identity.
- `cmd/generate-spot-filter-vectors` is the only writer for `internal/order/risk/testdata/spot_filter_contract_v1.json`. Its deterministic JSON contains MARKET/LIMIT accept/reject cases for price tick, quantity step, min/max notional, percent-price and side-percent-price, `MAX_POSITION`, base/quote `MAX_ASSET`, order counts, unknown applicable filter, disabled zero bounds, balances, and 38/18 precision boundaries. It supports `-out <absolute-path>` and `-check <absolute-path>` so Tasks 7 and 10 generate byte-identical committed copies. Every evaluator returns the vector's exact stable code and no network client is constructible in Backtest/offline tests.
- Emit one ELK counter for each rejected Spot request with exact labels `{exchange, market, environment, code, source, retryable}`. Network transport, HTTP 429, and HTTP 5xx are retryable; malformed schema/decimal, permission, capability, and filter violations are not. An ambiguous accepted-timeout remains retryable but also carries the recovery-required code; retry classification never authorizes a blind second order.

- [ ] **Step 1: Write RED decimal and filter tables**

```go
func TestDecimalStepAlignmentIsExact(t *testing.T) {
    cases := []struct {
        value string
        step  string
        ok    bool
    }{
        {value: "0.00003000", step: "0.00001000", ok: true},
        {value: "0.00003001", step: "0.00001000", ok: false},
        {value: "9007199254740993.00000000", step: "0.00000001", ok: true},
    }
    for _, tc := range cases {
        got, err := decimalAligned(tc.value, tc.step)
        if err != nil || got != tc.ok {
            t.Fatalf("decimalAligned(%q,%q)=(%v,%v), want %v", tc.value, tc.step, got, err, tc.ok)
        }
    }
}

func TestSpotRiskUsesMetadataAssetsAndMarketFilters(t *testing.T) {
    req := spotReviewRequest("BUY", "BTCUSDT", "0.00020000", "50000.00")
    req.Metadata = spotMetadata("BTCUSDT", "BTC", "USDT", officialFilterSet())
    req.Snapshot.Balances = map[string]risk.Balance{
        "USDT": {AvailableDecimal: "10.00000000"},
    }
    decision := reviewSpot(t, req)
    if !decision.Allowed {
        t.Fatalf("decision = %#v", decision)
    }
}
```

Add named cases for min/max/tick, LOT_SIZE, MARKET_LOT_SIZE precedence, disabled zero bounds, `applyToMarket`, `applyMinToMarket`, `applyMaxToMarket`, insufficient USDT BUY, insufficient BTC SELL, locked balance, an unknown filter, and a `BTCUSDT` pseudo balance that must not satisfy BTC. Add official-shape cases for non-null reference-price precedence, null/`-2043` fallback with exact `avgPriceMins`, malformed reference-price failure, `MAX_POSITION` including base free + locked + all open BUY remaining quantities, `MAX_ASSET` for base and USDT quote, and exchange/symbol count filters returned by `/api/v3/myFilters`.
Add a direct gRPC test that calls `order.v1.PlaceOrder` for an owned Live Spot Venue and asserts exact code `SPOT_LIVE_ROLLOUT_GUARD` plus zero risk/executor/network calls; a Live Futures control case remains admitted.
Add table cases for exact-only, legacy-only, numerically equivalent exact/legacy spellings, and conflicting quantity/price/mark fields. Every conflict must return `ORDER_DECIMAL_CONFLICT` with zero audit/repository/risk/executor/network calls. Add 39 integer digits, 21 integer digits plus scale, 19 fractional digits, exact `99999999999999999999.999999999999999999`, `000001.230000000000000000`, trailing zeros, and fill/quote/fee fields at and past their asset precision. Every unrepresentable value fails before all side effects. Add a repository argument test that fails if any numeric bind receives `float64`. In `timescale_roundtrip_test.go`, use a real order database to persist and rescan `9007199254740993.00000000`, `0.00000001`, and a nullable price through intent and attempt rows; assert the exact numeric value survives without a `float64` round trip. That test may skip only when `TIMESCALEDB_DSN` is absent during an ordinary repository run; once the variable is present, connection, extension, schema, insert, and scan failures are fatal and never converted to `t.Skip`.
Generate the golden vectors, then run every vector through core risk. Add Backtest facts tests that inject one immutable snapshot, mutate the original caller object after preflight, and prove the persisted deep copy wins; a second order in the same Session uses the same snapshot ID and current wallet balance; a missing ID, other Session's ID, expired snapshot, caller filter payload, and any attempted network call fail before audit/send. Add error/metric tables for timeout, 429, 500, malformed JSON, permission, tick, notional, capability disabled, and Live guard; assert the exact environment/retryable/source fields and counter labels.
The Portfolio migration suite must expose exact tests `TestSpotRiskFactsMigrationFreshBootstrap` (`0000 -> 0001 -> 0002`) and `TestSpotRiskFactsMigrationPopulatedUpgrade` (historical `0001 -> 0002`), both acceptance-owned and fatal when `HUSHINE_TEST_PG_ADMIN_DSN` is set.

Run:

```bash
cd /Users/xdy/Workplace/hushine-worktrees/medium-cleanup/core-service
go run ./cmd/generate-spot-filter-vectors -out "$PWD/internal/order/risk/testdata/spot_filter_contract_v1.json"
go test ./internal/order/risk ./internal/order/service ./internal/order/repository ./internal/exchange/binance ./internal/repository ./internal/storage/migrations -run 'TestDecimal|TestSpotRisk|TestSpotFilterContract|TestSpotBacktestFacts|TestSpotOrderUsesExactDecimal|TestPlaceOrderRejectsLiveSpot|TestPlaceOrderRejectsDecimalConflict|TestOrderRepositoryExactDecimalBind|TestOrderErrorDetail|TestSpotRiskFactsMigration' -count=1
```

Expected RED: float modulo misclassifies at least one exact case, Spot rules are not loaded by the gate, and Binance order construction reads float fields.

- [ ] **Step 2: Add exact protocol fields, metadata-driven balance lookup, and filter application**

The alignment primitive must remain exact:

```go
func decimalAligned(value, step string) (bool, error) {
    v, err := parseUnsignedDecimal(value)
    if err != nil {
        return false, err
    }
    s, err := parseUnsignedDecimal(step)
    if err != nil {
        return false, err
    }
    if s.Sign() == 0 {
        return true, nil
    }
    return new(big.Rat).Quo(v, s).IsInt(), nil
}
```

Require the risk gate to load the same route's Spot rules before checking balances. Demo percent-price or market-notional checks fetch trusted reference/average prices inside core-service; Backtest checks use only its persisted immutable fact snapshot; neither trusts a worker mark as the exchange reference. Validate syntax, `numeric(38,18)`, asset precision, and filters in that order. Build Binance `quantity` and `price` URL parameters directly from validated strings; never round-trip through `float64`. Persist the same authoritative strings by passing them through intent, attempt, risk audit, and recovery models; SQL casts/binds them to `numeric(38,18)`, and reads use `numeric_column::text` (or an equivalent lossless numeric scanner), never `float64`.

- [ ] **Step 3: Make exact risk and executor tests GREEN**

```bash
cd /Users/xdy/Workplace/hushine-worktrees/medium-cleanup/core-service
make proto
gofmt -w internal/exchange/adapter/capabilities.go internal/order/risk internal/order/executor internal/order/service internal/order/repository internal/exchange/binance/order_executor.go internal/exchange/binance/order_executor_test.go internal/exchange/binance/spot_reference_price.go internal/exchange/binance/spot_reference_price_test.go internal/exchange/binance/spot_account_filters.go internal/exchange/binance/spot_account_filters_test.go internal/exchange/binance/order_capability.go internal/exchange/binance/order_capability_test.go
go test ./internal/order/risk ./internal/order/executor ./internal/order/service ./internal/order/repository ./internal/exchange/binance -run 'TestDecimal|TestSpotRisk|TestSpotOrderUsesExactDecimal|TestPlaceOrderRejectsLiveSpot|TestPlaceOrderRejectsDecimalConflict|TestOrderRepositoryExactDecimalBind' -count=1
go run ./cmd/generate-spot-filter-vectors -check "$PWD/internal/order/risk/testdata/spot_filter_contract_v1.json"
test -n "$TIMESCALEDB_DSN"
TIMESCALEDB_DSN="$TIMESCALEDB_DSN" go test ./internal/order/repository -run TestOrderRepositoryExactDecimalRoundTrip -count=1 -v
go test ./... && go vet ./...
```

Expected GREEN: every filter case yields its stable code, BUY/SELL use metadata assets, and the mock server sees the exact original decimal strings.

- [ ] **Step 4: Commit core-service only**

```bash
cd /Users/xdy/Workplace/hushine-worktrees/medium-cleanup/core-service
go test ./... && go vet ./...
git add proto/portfolio_service.proto gen/portfoliov1/portfolio_service.pb.go gen/portfoliov1/portfolio_service_grpc.pb.go proto/order_service.proto gen/orderv1/order_service.pb.go gen/orderv1/order_service_grpc.pb.go internal/exchange/adapter/capabilities.go internal/order/risk/types.go internal/order/risk/decimal.go internal/order/risk/decimal_test.go internal/order/risk/backtest_facts.go internal/order/risk/backtest_facts_test.go internal/order/risk/testdata/spot_filter_contract_v1.json cmd/generate-spot-filter-vectors/main.go cmd/generate-spot-filter-vectors/main_test.go internal/order/risk/balance.go internal/order/risk/gate.go internal/order/risk/pending.go internal/order/risk/symbol_rules.go internal/order/risk/spot_filters.go internal/order/risk/spot_filters_test.go internal/order/risk/gate_test.go internal/order/risk/adapter_readers_test.go internal/order/executor/executor.go internal/order/service/grpc.go internal/order/service/grpc_test.go internal/order/repository/repository.go internal/order/repository/timescale.go internal/order/repository/timescale_roundtrip_test.go internal/order/metrics.go internal/order/metrics_test.go internal/repository/repository.go internal/repository/timescale.go internal/storage/migrations/0002_spot_risk_facts.sql internal/storage/migrations/spot_risk_facts_migration_test.go internal/exchange/binance/order_executor.go internal/exchange/binance/order_executor_test.go internal/exchange/binance/spot_reference_price.go internal/exchange/binance/spot_reference_price_test.go internal/exchange/binance/spot_account_filters.go internal/exchange/binance/spot_account_filters_test.go internal/exchange/binance/order_capability.go internal/exchange/binance/order_capability_test.go internal/exchange/binance/mockserver/rest_spot.go
git commit -m "feat(spot): enforce exact Binance order filters"
```

---

### Task 6: Preserve Spot fills, fees, terminal states, and reconciliation

**Files:**
- Modify: `core-service/internal/exchange/adapter/capabilities.go`
- Modify: `core-service/internal/exchange/binance/order_executor.go`
- Modify: `core-service/internal/exchange/binance/order_executor_test.go`
- Modify: `core-service/internal/exchange/binance/order_state_reader.go`
- Modify: `core-service/internal/exchange/binance/order_state_reader_test.go`
- Modify: `core-service/internal/exchange/binance/user_data_events.go`
- Modify: `core-service/internal/exchange/binance/user_data_events_test.go`
- Modify: `core-service/internal/exchange/binance/user_data_stream_client.go`
- Modify: `core-service/internal/exchange/binance/user_data_stream_client_test.go`
- Create: `core-service/internal/exchange/binance/spot_user_data_wsapi.go`
- Create: `core-service/internal/exchange/binance/spot_user_data_wsapi_test.go`
- Create: `core-service/internal/exchange/binance/futures_user_data_listen_key_test.go`
- Modify: `core-service/internal/exchange/binance/mockserver/server.go`
- Create: `core-service/internal/exchange/binance/mockserver/ws_api.go`
- Create: `core-service/internal/exchange/binance/mockserver/ws_api_test.go`
- Modify: `core-service/internal/order/executor/executor.go`
- Modify: `core-service/internal/order/executor/adapter_recovery_client.go`
- Modify: `core-service/internal/order/executor/adapter_router.go`
- Modify: `core-service/internal/order/executor/adapter_router_test.go`
- Modify: `core-service/internal/order/service/grpc.go`
- Modify: `core-service/internal/order/service/grpc_test.go`
- Modify: `core-service/internal/order/lifecycle/events.go`
- Modify: `core-service/internal/order/lifecycle/ingestor.go`
- Modify: `core-service/internal/order/lifecycle/ingestor_test.go`
- Modify: `core-service/internal/order/lifecycle/user_data_ingestor.go`
- Modify: `core-service/internal/order/lifecycle/user_data_ingestor_test.go`
- Modify: `core-service/internal/order/repository/repository.go`
- Modify: `core-service/internal/order/repository/timescale.go`
- Modify: `core-service/internal/order/repository/timescale_roundtrip_test.go`
- Create: `core-service/internal/order/storage/migrations/0002_spot_order_route_identity.sql`
- Modify: `core-service/internal/order/storage/migrations/baseline_contract_test.go`
- Create: `core-service/internal/order/storage/migrations/spot_order_route_identity_migration_test.go`
- Create: `core-service/internal/order/storage/migrations/testdata/order_pre_spot_fixture.sql`
- Modify: `core-service/cmd/ensure-order-db/main.go`
- Create: `core-service/cmd/ensure-order-db/main_test.go`
- Modify: `core-service/proto/order_service.proto`
- Regenerate: `core-service/gen/orderv1/order_service.pb.go`
- Regenerate: `core-service/gen/orderv1/order_service_grpc.pb.go`
- Modify: `core-service/internal/reconciliation/diff.go`
- Modify: `core-service/internal/reconciliation/diff_test.go`
- Modify: `core-service/internal/reconciliation/service.go`
- Modify: `core-service/internal/reconciliation/service_test.go`
- Create: `core-service/internal/reconciliation/spot_coordinator.go`
- Create: `core-service/internal/reconciliation/spot_coordinator_test.go`
- Modify: `core-service/internal/repository/repository.go`
- Modify: `core-service/internal/repository/timescale.go`
- Modify: `core-service/internal/repository/session_test.go`
- Modify: `core-service/internal/domain/model.go`
- Create: `core-service/internal/storage/migrations/0003_spot_reconciliation_repair.sql`
- Create: `core-service/internal/storage/migrations/spot_reconciliation_repair_migration_test.go`
- Modify: `core-service/cmd/core-service/order_user_data_stream_test.go`

**Interfaces:**
- Split user-data transport by market before changing event parsing. Spot uses Binance's current WebSocket API endpoint and `userDataStream.subscribe.signature`; the retired Spot listenKey REST family is forbidden. The official contract is [WebSocket API user-data requests](https://github.com/binance/binance-spot-api-docs/blob/master/web-socket-api.md#user-data-stream-requests), and the retirement is recorded in the [2026-01-21 changelog entry](https://github.com/binance/binance-spot-api-docs/blob/master/CHANGELOG.md#2026-01-21). Futures remains on its existing `/fapi/v1/listenKey` transport.
- `SpotUserDataWSAPI.Start` connects to the configured official `.../ws-api/v3` endpoint, sends one JSON text request with a unique request ID, method `userDataStream.subscribe.signature`, and signed `apiKey/timestamp/recvWindow/signature` parameters, and does not report ready until a matching `status=200` response returns a `subscriptionId`. The configured credential signer supports the key type already accepted by Binance; no secret is logged or retained in evidence. Events must have the acknowledged `subscriptionId` and the official `{subscriptionId,event:{...}}` envelope before entering the existing `executionReport` parser.
- The Spot connection copies ping payloads into pong frames, proactively rotates before the documented 24-hour lifetime, and immediately replaces a connection after `serverShutdown`, `eventStreamTerminated`, read/write failure, or subscription error. A replacement first subscribes and buffers events, then REST-recovers every locally non-terminal order plus `/api/v3/myTrades`, ingests those facts idempotently, drains the buffer, and only then becomes ready; this closes the disconnect/recovery race. Backoff is bounded and context-cancelable. Spot never creates, refreshes, or deletes a listenKey.
- The existing Futures client continues to call `POST /fapi/v1/listenKey`, periodically `PUT /fapi/v1/listenKey`, optionally `DELETE /fapi/v1/listenKey`, and connect to `/ws/<listenKey>` with its existing cadence and payload parser. No Spot WebSocket API change is permitted to alter those requests, paths, or readiness semantics.
- `adapter.OrderResult`, `adapter.OrderState`, `adapter.FillDelta`, `executor.FillResult`, lifecycle events, and user-data events keep `FeeAsset`, exact original/executed/remaining quantity, exact fill price, exact last and cumulative quote quantity, exchange trade ID, order ID, and event time. Add `fee_asset = 22`, `qty_decimal = 23`, `fill_price_decimal = 24`, `fee_decimal = 25`, and `quote_qty_decimal = 26` to `OrderFillEntry`; add `orig_qty_decimal = 32`, `executed_qty_decimal = 33`, `remaining_qty_decimal = 34`, `avg_price_decimal = 35`, optional `price_decimal = 36`, and `cumulative_quote_qty_decimal = 37` to `ExchangeOrderEntry`; add corresponding exact strings to `FillDeltaEntry` and `OrderStateEntry` on new field numbers. The Binance POST response, REST recovery reader, user-data parser/client, adapter router/recovery client, service audit record, lifecycle event, notification, repository row, query/PlaceOrder response, handler JSON, and worker response must not drop these fields. Legacy doubles are derived display values only after exact validation.
- Order-state and fill idempotency are separate. Order state is keyed by `(venue_id, exchange, market, symbol, exchange_order_id)` and advances only by a non-regressive status/cumulative-execution transition. A fill is keyed by the same route/order identity plus a non-empty/non-negative `exchange_trade_id`. NEW/CANCELED/EXPIRED/REJECTED events never enter the fill-deduplication table, because Binance legitimately reports no trade ID for them. Duplicate state payloads and duplicate fills are no-ops; cumulative execution may increase monotonically, and terminal `FILLED`, `CANCELED`, `EXPIRED`, or `REJECTED` cannot regress to `NEW` or `PARTIALLY_FILLED`.
- Reconciliation compares each canonical Spot asset's exact free and locked balances for the same venue route. For Spot it is also a repair coordinator, not compare-only: recover missing non-terminal order/trade lifecycle through the same route-qualified ingestor; reread `/api/v3/account`; atomically persist the authoritative venue wallet/canonical Portfolio snapshot plus `repair_source`; and only then write the final reconciliation outcome. Missing account data, lifecycle ambiguity, permission errors, or persistence errors are hard failures; valuation-price absence is advisory only. Futures retains its current compare-only behavior.
- `SpotCoordinator.Reconcile(ctx, SpotRepairRequest) (SpotRepairResult, error)` is synchronous at its durability boundary and idempotent by `run_id`. It writes `repair_source` as one of `user_stream_reconnect`, `periodic`, `accepted_timeout`, or `stop_close`; records repaired route/order/trade identities; and never rewrites another Venue or Futures wallet. On hard failure it compare-and-swaps an affected `running` Session to `recoverable` with `SPOT_RECONCILIATION_FAILED:<run_id>` while preserving `runtime_id`; terminal Sessions never regress, and a successful later repair does not silently change `recoverable` back to `running`. Query/lifecycle/reconciliation continue when Demo capability is disabled so an existing Session can drain.
- `0003_spot_reconciliation_repair.sql` additively adds `repair_source`, `repair_status`, and repaired identity JSON to `reconciliation_runs`; deployed `0001` remains byte-identical. Repository `ApplySpotRepair` performs the venue-wallet/canonical-snapshot/reconciliation-run/session-CAS writes in one Portfolio database transaction. Order lifecycle repair is committed first in the order database and is safe to replay if the Portfolio transaction fails.
- `0002_spot_order_route_identity.sql` is a transactional, history-preserving additive migration. Keep the already-deployed `0001_current_schema_baseline.sql` byte-identical; both runners remain filename-ledgered, so rewriting it is forbidden. A fresh database executes `0000 -> 0001 -> 0002`, while a populated pre-Spot database executes its historical `0001 -> 0002`. Add `order_fills.quote_qty numeric(38,18)` and exact cumulative-quote storage on the order/lifecycle shape used by repository queries; backfill resolvable quote quantity exactly from existing numeric `qty * fill_price` and retain null plus an explicit unresolved marker where history cannot prove the value. Add/backfill `order_lifecycle_events.symbol` from fill/state JSON and the linked intent/order where available; enforce a non-empty symbol for new rows while retaining unresolvable historical rows. Replace the legacy venue-only conflict indexes with partial route-qualified unique indexes on `(venue_id, exchange, market, symbol, exchange_order_id, exchange_trade_id)` and `(venue_id, exchange, market, symbol, event_identity)`.
- Do not add a global trade-identity unique index directly to the Timescale `order_fills` hypertable: its uniqueness rules would require the time partition column and would not deduplicate a replay at another timestamp. Create an ordinary `order_fill_identities` table keyed by `(venue_id, exchange, market, symbol, exchange_order_id, exchange_trade_id)`, with `fill_id`, `order_id`, and timestamps for audit. Backfill every resolvable historical real trade by joining fills to intents/orders, and insert the identity plus `order_fills` row in the same repository transaction. A same-route conflict is an idempotent no-op; another symbol/market/exchange with the same Binance IDs remains distinct. State-only events with empty trade IDs never enter this table.

- [ ] **Step 1: Write RED fill propagation and monotonic lifecycle tests**

```go
func TestAdapterRouterPreservesSpotCommissionAsset(t *testing.T) {
    adapterExec := &fakeAdapterExecutor{result: adapter.OrderResult{
        Status: "FILLED",
        ExecutedQtyDecimal: "0.01000000",
        CumulativeQuoteQtyDecimal: "500.00000000",
        Fills: []adapter.FillDelta{{
            TradeID: "trade-7", QtyDecimal: "0.01000000",
            QuoteQtyDecimal: "500.00000000", FeeDecimal: "0.00001000", FeeAsset: "BNB",
        }},
    }}
    got, err := newRouter(adapterExec).PlaceOrder(context.Background(), spotExecutorRequest())
    if err != nil {
        t.Fatal(err)
    }
    if got.Fills[0].FeeAsset != "BNB" {
        t.Fatalf("fill = %#v", got.Fills[0])
    }
}

func TestSpotLifecycleIgnoresDuplicateAndLateNew(t *testing.T) {
    store := newLifecycleStore(t)
    ingest(t, store, spotFillEvent("PARTIALLY_FILLED", "trade-1", "0.004", "200", "BNB", "0.00001"))
    ingest(t, store, spotFillEvent("PARTIALLY_FILLED", "trade-1", "0.004", "200", "BNB", "0.00001"))
    ingest(t, store, spotFillEvent("FILLED", "trade-2", "0.010", "500", "USDT", "0.50"))
    ingest(t, store, spotOrderEvent("NEW"))
    assertOrderState(t, store, "FILLED", "0.010", "500")
    assertFillCount(t, store, 2)
}
```

Add NEW, partial, cancel, expire, rejected, out-of-order user-data stream, two non-trade terminal events with empty trade IDs on different orders, cancel/expire locked-balance release, base/quote/BNB commission, reconnect replay, and same Spot/Futures order ID route-isolation cases. Add three separate precision vectors covering (a) POST `/api/v3/order` FULL response, (b) websocket `executionReport`, and (c) REST `/api/v3/order` + `/api/v3/myTrades` recovery. Each uses a quantity beyond binary-float integer precision plus `0.00000001` price/fee/quote components and requires the exact strings to match through adapter, repository, protobuf, handler, and worker. The websocket fixture carries official `l`, `L`, `Y`, `z`, `Z`, `n`, and `N`; REST trade fixtures carry `qty`, `price`, `quoteQty`, `commission`, and `commissionAsset`; no Binance string may be parsed to `float64` before the exact field is stored.

Add Spot WebSocket API tests for signed subscription request shape, response-ID correlation, acknowledged `subscriptionId`, official event envelope, ping/pong payload, proactive 24-hour rotation, `serverShutdown`, `eventStreamTerminated`, reconnect backoff, cancellation, subscription 4xx/5xx, and subscribe-buffer→REST recovery→buffer drain ordering. Force a fill to arrive in POST FULL, then the same trade on WebSocket, then again through reconnect REST recovery and assert one route-qualified fill/fee identity. Add an executable source/mock guard that fails on any Spot `POST|PUT|DELETE /api/v3/userDataStream`. In the same test binary, assert the Futures client still records exactly POST/PUT/DELETE `/fapi/v1/listenKey` and `/ws/<listenKey>`, including keepalive and reconnect.

In real-DB tests, persist BTCUSDT and ETHUSDT rows under the same Venue with identical exchange order/trade IDs and require both; replay the identical BTCUSDT trade and require one row; prove an empty-trade-ID state event creates no fill identity. The integration test creates and owns a random `hushine_spot_order_acceptance_<suffix>` database from `HUSHINE_TEST_PG_ADMIN_DSN`, registers cleanup immediately, loads the checked-in pre-Spot fixture, seeds non-empty intent/attempt/order/fill/lifecycle history, applies `0002`, and requires every row/hash and exact numeric—including quote quantity—to survive, route indexes to replace legacy indexes, `0001`'s checked-in SHA-256 to remain unchanged, and exactly one committed `0002` ledger entry. It also applies the byte-identical `0000 -> 0001 -> 0002` sequence to a separate fresh owned database. Missing admin DSN may skip ordinary tests, but once `HUSHINE_TEST_PG_ADMIN_DSN` is present, connection, acceptance-database creation, Timescale extension, fixture, migration, and cleanup-registration failures are fatal and never converted to `t.Skip`; the focused acceptance command supplies the variable. Add reconciliation cases for free mismatch, locked mismatch, missing asset, and valuation-only differences.

Add coordinator tests for drift→missing trade recovery→canonical venue/Portfolio snapshot update→hard pass, duplicate run replay, authoritative account read after lifecycle repair, fee-asset balance repair, wrong-route isolation, disabled-Demo drain, and Futures untouched. For network/permission/schema/lifecycle/persistence failures, assert a durable failed run with its source when possible and an exact `running -> recoverable` CAS; terminal status and unrelated Session/Venue rows remain unchanged. The Portfolio migration suite exposes exact tests `TestSpotReconciliationRepairMigrationFreshBootstrap` (`0000 -> 0001 -> 0002 -> 0003`) and `TestSpotReconciliationRepairMigrationPopulatedUpgrade` (historical `0001 -> 0002 -> 0003`), with forced body/ledger rollback and byte-identical `0001`.

Make both migration entry points atomic. The repository runner already executes body plus ledger insert in one transaction; change `cmd/ensure-order-db` to do the same. Its test injects a failure after the migration body but before ledger insertion and requires both schema/data and ledger to roll back, then proves a successful rerun and a second idempotent invocation.

Run:

```bash
cd /Users/xdy/Workplace/hushine-worktrees/medium-cleanup/core-service
make proto
go test ./internal/order/executor ./internal/order/lifecycle ./internal/order/repository ./internal/reconciliation -run 'Test.*Spot|TestAdapterRouterPreservesSpotCommissionAsset' -count=1
go test ./internal/exchange/binance ./internal/exchange/binance/mockserver ./cmd/core-service -run 'TestSpotUserDataWSAPI|TestFuturesUserDataListenKeyUnchanged|TestNoRetiredSpotUserDataStreamEndpoint' -count=1
```

Expected RED: Spot still requests a retired listenKey, `FeeAsset` is lost by the adapter router/service path, late events can regress state, and reconciliation cannot repair canonical state or mark a Session recoverable.

- [ ] **Step 2: Carry exact fill facts end to end and compare canonical assets**

Use the existing repository transaction for order state plus fills. Add exact string fields for every numeric to `repository.Order` and `repository.OrderFill`; persist them directly to numeric columns and scan them losslessly as text, deriving old doubles only at response display boundaries. At each Binance ingress validate but retain the original decimal string; compute a missing per-fill quote only with exact decimal multiplication, never binary float. Preserve POST `cummulativeQuoteQty`, websocket `Y`/`Z`, and REST `/myTrades.quoteQty`; reject internally inconsistent exact totals instead of silently choosing a float-derived value. Persist a fill/dedup row only for a real trade with a non-empty/non-negative exchange trade ID; make that route-qualified trade identity idempotent at both application and the ordinary `order_fill_identities` database constraint. Persist exact fill quantity/price/fee/quote strings directly to numeric columns and scan them losslessly as text. Persist non-trade NEW/CANCELED/EXPIRED/REJECTED transitions through the order-state monotonic guard, so an empty trade ID cannot collapse different orders or prevent locked-balance release. Include exchange, market, and symbol in repository `ON CONFLICT` targets and in `ResolveOpenOrderByExchangeRef`; callers may not resolve by Venue plus exchange order ID alone. Do not synthesize a fill from requested quantity when Binance returns actual execution fields. Keep legacy Futures listenKey code in its own market-specific implementation. Route Spot repair through `SpotCoordinator`; only its authoritative account reread and transactional `ApplySpotRepair` may replace canonical Spot state.

- [ ] **Step 3: Make lifecycle and reconciliation tests GREEN**

```bash
cd /Users/xdy/Workplace/hushine-worktrees/medium-cleanup/core-service
gofmt -w internal/order/executor internal/order/service internal/order/lifecycle internal/order/repository internal/reconciliation internal/order/storage/migrations
test -n "$HUSHINE_TEST_PG_ADMIN_DSN"
CORE_SPOT_BASE_SHA=1b92b40c8337bd8a2c31871ef488b344e5d518a6 HUSHINE_TEST_PG_ADMIN_DSN="$HUSHINE_TEST_PG_ADMIN_DSN" go test -tags=integration ./internal/order/storage/migrations ./internal/storage/migrations ./cmd/ensure-order-db ./internal/order/repository ./internal/repository -run 'TestSpotOrderRouteIdentityMigration|TestSpotReconciliationRepairMigration|TestEnsureOrderMigrationAtomic|TestOrderRepositoryExactSpotRoundTrip|TestApplySpotRepair' -count=1 -v
go test ./internal/exchange/binance ./internal/exchange/binance/mockserver ./internal/order/executor ./internal/order/lifecycle ./internal/order/repository ./internal/reconciliation ./cmd/core-service -run 'Test.*Spot|TestAdapterRouterPreservesSpotCommissionAsset|TestFuturesUserDataListenKeyUnchanged|TestNoRetiredSpotUserDataStreamEndpoint' -count=1
if rg -n '/api/v3/userDataStream' internal/exchange/binance --glob '*.go' --glob '!**/*_test.go'; then
  echo 'retired Spot listenKey endpoint remains' >&2
  exit 1
fi
go test ./... && go vet ./...
```

Expected GREEN: Spot uses acknowledged WebSocket API subscriptions, Futures listenKey traffic is unchanged, exact fills/fees round-trip once across POST/WS/REST overlap, and Spot drift is repaired into the authoritative snapshot or leaves the Session durably recoverable.

- [ ] **Step 4: Commit core-service only**

```bash
cd /Users/xdy/Workplace/hushine-worktrees/medium-cleanup/core-service
go test ./... && go vet ./...
git add internal/exchange/adapter/capabilities.go internal/exchange/binance/endpoints.go internal/exchange/binance/order_executor.go internal/exchange/binance/order_executor_test.go internal/exchange/binance/order_state_reader.go internal/exchange/binance/order_state_reader_test.go internal/exchange/binance/user_data_events.go internal/exchange/binance/user_data_events_test.go internal/exchange/binance/user_data_stream_client.go internal/exchange/binance/user_data_stream_client_test.go internal/exchange/binance/spot_user_data_wsapi.go internal/exchange/binance/spot_user_data_wsapi_test.go internal/exchange/binance/futures_user_data_listen_key_test.go internal/exchange/binance/mockserver/server.go internal/exchange/binance/mockserver/ws_api.go internal/exchange/binance/mockserver/ws_api_test.go internal/order/executor/executor.go internal/order/executor/adapter_recovery_client.go internal/order/executor/adapter_router.go internal/order/executor/adapter_router_test.go internal/order/service/grpc.go internal/order/service/grpc_test.go internal/order/lifecycle/events.go internal/order/lifecycle/ingestor.go internal/order/lifecycle/ingestor_test.go internal/order/lifecycle/user_data_ingestor.go internal/order/lifecycle/user_data_ingestor_test.go internal/order/repository/repository.go internal/order/repository/timescale.go internal/order/repository/timescale_roundtrip_test.go internal/order/storage/migrations/0002_spot_order_route_identity.sql internal/order/storage/migrations/baseline_contract_test.go internal/order/storage/migrations/spot_order_route_identity_migration_test.go internal/order/storage/migrations/testdata/order_pre_spot_fixture.sql cmd/ensure-order-db/main.go cmd/ensure-order-db/main_test.go proto/order_service.proto gen/orderv1/order_service.pb.go gen/orderv1/order_service_grpc.pb.go internal/reconciliation/diff.go internal/reconciliation/diff_test.go internal/reconciliation/service.go internal/reconciliation/service_test.go internal/reconciliation/spot_coordinator.go internal/reconciliation/spot_coordinator_test.go internal/repository/repository.go internal/repository/timescale.go internal/repository/session_test.go internal/domain/model.go internal/storage/migrations/0003_spot_reconciliation_repair.sql internal/storage/migrations/spot_reconciliation_repair_migration_test.go cmd/core-service/order_user_data_stream_test.go
git commit -m "fix(spot): preserve fills fees and reconciliation"
```

---

### Task 7: Make the Session worker wallet canonical and mixed-route safe

**Files:**
- Regenerate: `strategy-service/strategy_service/gen/portfolio_service_pb2.py`
- Regenerate: `strategy-service/strategy_service/gen/portfolio_service_pb2_grpc.py`
- Regenerate: `strategy-service/strategy_service/gen/order_service_pb2.py`
- Regenerate: `strategy-service/strategy_service/gen/order_service_pb2_grpc.py`
- Regenerate: `strategy-service/gen/portfoliov1/portfolio_service.pb.go`
- Regenerate: `strategy-service/gen/portfoliov1/portfolio_service_grpc.pb.go`
- Modify: `strategy-service/strategy_service/wallet/canonical.py`
- Modify: `strategy-service/strategy_service/wallet/spot.py`
- Modify: `strategy-service/strategy_service/wallet/binance.py`
- Modify: `strategy-service/strategy_service/wallet/portfolio.py`
- Modify: `strategy-service/strategy_service/wallet/portfolio_adapter.py`
- Modify: `strategy-service/strategy_service/wallet/order_types.py`
- Create: `strategy-service/strategy_service/wallet/spot_filters.py`
- Modify: `strategy-service/strategy_service/order_client.py`
- Modify: `strategy-service/strategy_service/platform_proxy.py`
- Modify: `strategy-service/strategy_service/grpc_server.py`
- Modify: `strategy-service/internal/runtimeagent/session_lifecycle.go`
- Modify: `strategy-service/internal/runtimeagent/session_lifecycle_test.go`
- Modify: `strategy-service/internal/runtimeagent/agent_test.go`
- Modify: `strategy-service/tests/test_wallet_runtime.py`
- Modify: `strategy-service/tests/test_wallet_strict_rules.py`
- Modify: `strategy-service/tests/test_portfolio_wallet_runtime.py`
- Modify: `strategy-service/tests/test_order_client.py`
- Modify: `strategy-service/tests/test_platform_proxy.py`
- Modify: `strategy-service/tests/test_strategy_engine.py`
- Modify: `strategy-service/tests/test_grpc_server.py`
- Modify: `strategy-service/tests/test_preflight.py`
- Create: `strategy-service/tests/test_spot_end_to_end.py`
- Create: `strategy-service/tests/fixtures/spot_filter_contract_v1.json`
- Create: `strategy-service/tests/test_spot_filter_contract.py`

**Interfaces:**
- Add immutable Python `SpotSymbolMetadata` and `SpotSymbolFilter` dataclasses keyed by `(venue_id, exchange, market, symbol)`.
- `CanonicalSpotState.assets` is keyed only by asset code and includes USDT. `SpotWallet.on_market_data(symbol, price, metadata)` updates a symbol price index and an existing base-asset valuation; it never creates an asset.
- `apply_order_update` consumes cumulative executed base/quote amounts and each fill's actual commission asset. It applies only positive cumulative deltas and ignores duplicate or regressive events.
- Wallet amount progression and fee identity are separate. Maintain cumulative order state by full route/order identity, but debit each commission exactly once by `(venue_id, exchange, market, symbol, exchange_order_id, exchange_trade_id)`. A non-zero fill without a trade ID is held recovery-pending and never invents a fee key. POST FULL, WebSocket replay, and REST recovery of the same trade therefore update base/quote/fee only once; distinct trade IDs on one order each apply once.
- Hosted Backtest reads its Task 5 immutable risk facts and runs `spot_filters.py` before wallet/order mutation. Generate `tests/fixtures/spot_filter_contract_v1.json` with the core generator and require its SHA-256 to equal the core fixture; all golden MARKET/LIMIT cases return the same stable code with socket/network constructors disabled.
- `OrderClient` and `ProxyOrderClient` send exact decimal strings alongside legacy doubles, and their response model includes fee asset and exact quantities.
- Python structured errors preserve `environment`, `retryable`, and `source` without deriving them from message text.
- Preflight marks declared `ORDER_TARGETS` and includes required `MARKET`/`LIMIT` order types while preserving the existing union of inputs and targets.
- Task 7 regenerates the Task 5/6 additive fields with the existing generator, but `order_service.proto` does not import `portfolio_service.proto` until Task 8. Do not add the generated-import rewrite or its test here; Task 9 owns that consumer change after the real producer import exists.

- [ ] **Step 1: Write RED wallet asset and lifecycle scenarios**

```python
def test_spot_wallet_uses_asset_codes_and_never_creates_symbol_asset():
    wallet = SpotWallet.from_assets({"USDT": ("1000.00", "0"), "BTC": ("0.10", "0")})
    metadata = spot_metadata("BTCUSDT", base_asset="BTC", quote_asset="USDT")
    wallet.on_market_data("BTCUSDT", Decimal("50000"), metadata)
    assert set(wallet.assets) == {"USDT", "BTC"}
    assert "BTCUSDT" not in wallet.assets


def test_spot_buy_applies_actual_fill_and_bnb_commission_once():
    wallet = SpotWallet.from_assets({"USDT": ("1000", "0"), "BNB": ("1", "0")})
    metadata = spot_metadata("BTCUSDT", base_asset="BTC", quote_asset="USDT")
    update = order_update(
        order_id="o-1", status="FILLED", executed_qty="0.01",
        cumulative_quote_qty="500", commission="0.001", commission_asset="BNB",
    )
    wallet.apply_order_update(update, metadata)
    wallet.apply_order_update(update, metadata)
    assert wallet.assets["BTC"].free == Decimal("0.01")
    assert wallet.assets["USDT"].free == Decimal("500")
    assert wallet.assets["BNB"].free == Decimal("0.999")
```

Add SELL, base commission, quote commission, partial-to-filled, cancel/expire release, late NEW, insufficient USDT, metadata absence fail-closed, legacy snapshot import, same-symbol Spot/Futures, multiple symbols, and two intervals of one symbol. Add the exact overlap sequence POST FULL trade-7 → identical WebSocket trade-7 → reconnect REST trade-7 and assert one fee ledger entry and one wallet delta; trade-8 must apply independently. Run every generated filter vector with networking forbidden and assert parity with core. Add network/429/5xx versus schema/permission/filter error propagation tables for `environment/retryable/source`.
In `tests/test_preflight.py`, add `test_required_symbol_descriptor_field_numbers`: assert `exchange=1`, `market=2`, `symbol=3`, `order_target=4`, and `required_order_types=5` in the freshly generated Python descriptor before constructing any preflight payload.

Run:

```bash
cd /Users/xdy/Workplace/hushine-worktrees/medium-cleanup/strategy-service
uv sync --python 3.13 --frozen --extra dev
go run ../core-service/cmd/generate-spot-filter-vectors -out "$PWD/tests/fixtures/spot_filter_contract_v1.json"
PYTHONPATH=.:../strategy-library uv run --frozen --extra dev pytest tests/test_wallet_runtime.py tests/test_wallet_strict_rules.py tests/test_portfolio_wallet_runtime.py tests/test_order_client.py tests/test_platform_proxy.py tests/test_strategy_engine.py tests/test_grpc_server.py tests/test_preflight.py tests/test_spot_end_to_end.py tests/test_spot_filter_contract.py -q
```

Expected RED: the current wallet keys assets by `BTCUSDT`, market data creates pseudo assets, fee asset is unavailable, and exact decimal request fields do not exist.

- [ ] **Step 2: Regenerate protocol and implement canonical wallet transitions**

Regenerate the Task 5/6 additive fields without changing generated-import handling; do not hand-edit generated code. Use `Decimal` created from protocol strings. Keep a per-order cumulative state record under the full route key and a separate set of full trade identities for fees/fill application. For BUY subtract the previously unseen trade's quote amount, add its base amount, then subtract its commission from the actual asset; SELL mirrors those deltas. Use cumulative fields only to validate monotonic order state, not to manufacture fee deltas. Reject an event whose metadata route does not equal the order route.

- [ ] **Step 3: Make Hosted Backtest/Demo and mixed-route tests GREEN**

```bash
cd /Users/xdy/Workplace/hushine-worktrees/medium-cleanup/strategy-service
./generate_proto.sh
go run ../core-service/cmd/generate-spot-filter-vectors -check "$PWD/tests/fixtures/spot_filter_contract_v1.json"
PYTHONPATH=.:../strategy-library uv run --frozen --extra dev pytest tests/test_wallet_runtime.py tests/test_wallet_strict_rules.py tests/test_portfolio_wallet_runtime.py tests/test_order_client.py tests/test_platform_proxy.py tests/test_strategy_engine.py tests/test_grpc_server.py tests/test_preflight.py tests/test_spot_end_to_end.py tests/test_spot_filter_contract.py -q
go test ./... -count=1
```

Expected GREEN: canonical Backtest and Demo scenarios pass, golden filters match core, POST/WS/REST overlap applies each trade/fee identity once, two intervals do not duplicate wallet changes, structured errors survive, and Spot/Futures same-symbol orders stay isolated.

- [ ] **Step 4: Commit strategy-service only**

```bash
cd /Users/xdy/Workplace/hushine-worktrees/medium-cleanup/strategy-service
PYTHONPATH=.:../strategy-library uv run --frozen --extra dev python -m compileall -q strategy_service tests
go test ./... && go vet ./...
git add strategy_service/gen/portfolio_service_pb2.py strategy_service/gen/portfolio_service_pb2_grpc.py strategy_service/gen/order_service_pb2.py strategy_service/gen/order_service_pb2_grpc.py gen/portfoliov1/portfolio_service.pb.go gen/portfoliov1/portfolio_service_grpc.pb.go strategy_service/wallet/canonical.py strategy_service/wallet/spot.py strategy_service/wallet/binance.py strategy_service/wallet/portfolio.py strategy_service/wallet/portfolio_adapter.py strategy_service/wallet/order_types.py strategy_service/wallet/spot_filters.py strategy_service/order_client.py strategy_service/platform_proxy.py strategy_service/grpc_server.py internal/runtimeagent/session_lifecycle.go internal/runtimeagent/session_lifecycle_test.go internal/runtimeagent/agent_test.go tests/test_wallet_runtime.py tests/test_wallet_strict_rules.py tests/test_portfolio_wallet_runtime.py tests/test_order_client.py tests/test_platform_proxy.py tests/test_strategy_engine.py tests/test_grpc_server.py tests/test_preflight.py tests/test_spot_end_to_end.py tests/fixtures/spot_filter_contract_v1.json tests/test_spot_filter_contract.py
git commit -m "feat(spot): add canonical session wallet semantics"
```

---

### Task 8: Add core-authoritative Spot stop-and-close planning

**Files:**
- Modify: `core-service/proto/order_service.proto`
- Regenerate: `core-service/gen/orderv1/order_service.pb.go`
- Regenerate: `core-service/gen/orderv1/order_service_grpc.pb.go`
- Create: `core-service/internal/order/spotclose/types.go`
- Create: `core-service/internal/order/spotclose/planner.go`
- Create: `core-service/internal/order/spotclose/planner_test.go`
- Create: `core-service/internal/order/spotclose/operation_test.go`
- Modify: `core-service/internal/order/service/grpc.go`
- Modify: `core-service/internal/order/service/grpc_test.go`
- Modify: `core-service/internal/order/repository/repository.go`
- Modify: `core-service/internal/order/repository/timescale.go`
- Modify: `core-service/internal/order/repository/timescale_roundtrip_test.go`
- Create: `core-service/internal/order/storage/migrations/0003_spot_close_operations.sql`
- Modify: `core-service/internal/order/storage/migrations/baseline_contract_test.go`
- Create: `core-service/internal/order/storage/migrations/spot_close_operations_migration_test.go`
- Modify: `core-service/internal/reconciliation/service.go`
- Modify: `core-service/internal/reconciliation/service_test.go`
- Modify: `core-service/internal/repository/repository.go`
- Modify: `core-service/internal/repository/timescale.go`
- Modify: `core-service/internal/domain/model.go`
- Modify: `core-service/cmd/core-service/main.go`
- Modify: `core-service/cmd/core-service/main_test.go`
- Modify: `core-service/internal/exchange/binance/order_capability.go`
- Modify: `core-service/internal/exchange/binance/order_state_reader.go`
- Modify: `core-service/internal/exchange/binance/order_state_reader_test.go`

**Interfaces:**
- Add `rpc CloseSpotTargets(CloseSpotTargetsRequest) returns (CloseSpotTargetsResponse)` to `order.v1`.
- Request contains `user_id`, `portfolio_id`, `strategy_id`, `session_id`, required `operation_id`, and repeated target facts `{venue_id, exchange, market, symbol}`. Core re-resolves ownership, active Session, route, metadata, and declared targets; it never trusts a worker-supplied asset or quantity. `operation_id` is stable for one Session stop action across RPC retry and Runtime/worker restart; the strategy boundary derives it deterministically from Session ID plus stop action when an older caller omits it, then propagates the same value on every retry.
- Planner dependencies:

```go
type AccountReader interface {
    ReadPortfolioSnapshot(context.Context, adapter.PortfolioSnapshotRequest) (adapter.PortfolioSnapshot, error)
}

type OpenOrderReader interface {
    ListOpenOrders(context.Context, adapter.OpenOrdersRequest) ([]adapter.OpenOrder, error)
}

type OrderPlacer interface {
    PlaceOrder(context.Context, *orderv1.PlaceOrderRequest) (*orderv1.PlaceOrderResponse, error)
}

type TerminalOrderWaiter interface {
    WaitTerminal(context.Context, adapter.Route, string) (adapter.OrderState, error)
}

type Reconciler interface {
    BeginSpotCloseRun(context.Context, SpotCloseReconciliationRequest) (string, error)
    CompleteSpotCloseRun(context.Context, string, SpotCloseReconciliationResult) error
}
```

- Planning has an explicit fence-before-facts order. First validate ownership/declarations and use metadata only to canonicalize symbols into sorted unique `(venue_id, exchange, market, base_asset)` lease keys; do not read balances, open orders, account filters, reference prices, or compute quantities in this discovery phase. Persist the durable operation shell, then acquire the complete sorted lease set atomically/all-or-none. Only while all leases are held, reread one fresh strict metadata/rules snapshot and require its symbol-to-base mapping to equal the discovery keys, then read fresh account, `/api/v3/myFilters`, reference/average-price, and open-order facts. Merge duplicate targets before calculating any order, so two declarations cannot sell one balance twice. Compute the exact MARKET SELL quantity from that target asset's entire current `free` exposure, including pre-existing/manual holdings. Any open order or non-zero `locked` amount aborts the whole batch before orders; locked quantity is never added to a sell request. A target whose exact `free` value is zero is recorded as `already_closed` and contributes no order; it is not dust and does not fail the batch. For every non-zero target, rule misalignment, unavailable reference price, or unavoidable dust aborts the whole batch before the first order. No pre-lease snapshot may enter the persisted plan.
- Execution phase calls the normal audited `PlaceOrder` path once per deterministic sorted merged target, waits for its durable lifecycle state to become terminal, and requires `FILLED` with the full planned cumulative quantity before continuing. After all planned orders are terminal, it rereads the authoritative account once and requires every merged target asset to have exact `free=0` and `locked=0`; only that reread becomes `final_snapshots` and permits overall `stopped`. A NEW/PARTIALLY_FILLED response, waiter timeout, cancel/expire/reject, residual balance, or reread failure is `stop_failed`, stops further sends where applicable, records completed/failed/unattempted targets, and triggers reconciliation. Stop-only never calls this RPC.
- `0003_spot_close_operations.sql` additively creates durable `spot_close_operations`, `spot_close_targets`, and `spot_order_admission_leases`; it never rewrites deployed `0001`. Fresh bootstrap executes `0000 -> 0001 -> 0002 -> 0003`, and populated upgrade executes historical `0001 -> 0002 -> 0003`. Operations are unique by `(session_id, operation_id)` and store a canonical request hash, overall phase/status, redacted failure, reconciliation run ID, and final response JSON. Targets carry the same `session_id` and have a composite foreign key to their operation plus uniqueness on `(session_id, operation_id, venue_id, exchange, market, base_asset)`; they store symbol, exact planned quantity, status (`planned`, `sending`, `submitted`, `recovery_pending`, `terminal`, `failed`, `already_closed`, or `unattempted`), deterministic intent/client identity, Hushine attempt/order IDs, exchange order ID, and last recovery fact. Leases are keyed by `(venue_id, exchange, market, base_asset)`, store the composite owner `(session_id, operation_id)` plus generation/expiry fields, and the repository acquires the complete sorted requested set in one transaction; a conflict rolls back every newly acquired lease. Normal `PlaceOrder` admission and Spot close both use this repository lease; close renews it through terminal/reconciliation, and concurrent user/strategy orders cannot race the closing balance. TTL expiry is not authorization to trade: if the durable target is `sending`, `submitted`, or `recovery_pending`, only the same composite owner `(session_id, operation_id)` may atomically fence the old lease with a higher generation, and it must resolve the persisted intent/client/exchange identity plus complete required reconciliation before any new send. A different close operation—including another Session that supplied the same bare operation ID—or ordinary PlaceOrder fails closed with `SPOT_CLOSE_RECOVERY_PENDING` even after lease expiry. Release the fence only after recovery/reconciliation establishes either a terminal order plus authoritative residual state or authoritative proof that no order was accepted. An unresolved failure changes the lease to a durable operator-blocking state that all admissions continue to reject until an explicit reconciliation repair clears it; never infer authoritative absence from timeout alone.
- Compute the operation request hash from the validated user/Portfolio/strategy/Session facts plus sorted, deduplicated canonical `(venue_id, exchange, market, symbol)` targets; input ordering and exact duplicate target facts do not change it, but any ownership/route/symbol change does. Persist the fully validated merged target plan and its exact quantities in one transaction before the first send. Derive each deterministic `intent_id` and exchange client identity from a fixed namespace plus the composite owner `(session_id, operation_id)` and canonical target route/base asset, never from the bare operation ID alone. Transition one target with compare-and-swap `planned -> sending`; invoke the normal PlaceOrder path with those persisted identities; then store attempt/order/exchange IDs before advancing. If the exchange may have accepted a request but the response timed out, resolve/recover that same intent/client/exchange order and never create a second attempt until authoritative absence is proven. A retry or process restart loads and resumes the same composite `(session_id, operation_id)` operation. Replaying that owner and canonical request returns the stored/current result; reusing its ID with different facts in the same Session returns `SPOT_CLOSE_OPERATION_CONFLICT` without sending, while a different Session may independently use the same supplied bare ID and can neither read nor recover the first Session's operation.
- The production `OrderPlacer` calls the same audited internal PlaceOrder command with an unexported admission-owner capability containing the persisted composite close owner and generation. Lease acquisition is reentrant only for that exact fenced owner. The public gRPC request has no field that can supply or spoof this capability, so an ordinary order cannot borrow the close lease; tests cover both the same-owner internal success path and an external spoof attempt that remains blocked.
- Invoke the Task 4A close policy after Session ownership/state is resolved. When Demo is disabled, only an already-active owned Session may enter drain-only close; no new/terminal/unowned Session may use that exception. Capability disable never stops lifecycle recovery or reconciliation.
- Lease release is an explicit owner-and-generation CAS. Release every acquired lease after (a) a preplan failure that happened before any send and has authoritative proof of no acceptance, (b) an all-`already_closed` result, or (c) all orders are durably terminal and the final authoritative account reread/reconciliation has completed. After each safe release, an ordinary PlaceOrder for the same asset must be admitted by the lease layer (subject to normal capability/risk). Never release an accepted-timeout, `sending/submitted/recovery_pending`, ambiguous terminal, failed final reread, or incomplete repair. If a required release CAS fails, persist operator-blocking state and return `SPOT_CLOSE_LEASE_RELEASE_FAILED`; do not report success or silently permit an ordinary order.
- Failure reconciliation is synchronous at the durability boundary. `BeginSpotCloseRun` inserts a pending/tombstone row in the existing Portfolio `reconciliation_runs` table before a failed RPC response is returned; `CompleteSpotCloseRun` fills comparison/failure facts. An account-reread failure still completes that row as failed with a redacted stable code. Never return a non-empty `reconciliation_run_id` unless that exact row is already durable. If the row cannot be created, persist `reconciliation_persist_failed` on the close operation and return `SPOT_CLOSE_RECONCILIATION_PERSIST_FAILED` as an RPC error rather than claiming reconciliation was launched. The existing fire-and-forget `LaunchAsync` path remains for unrelated shadow comparisons but cannot satisfy this close contract.

Use these additive messages and field numbers:

```protobuf
message SpotCloseTarget {
  int64 venue_id = 1;
  int32 exchange = 2;
  int32 market = 3;
  string symbol = 4;
}

message CloseSpotTargetsRequest {
  int64 portfolio_id = 1;
  int64 strategy_id = 2;
  string session_id = 3;
  repeated SpotCloseTarget targets = 4;
  string operation_id = 5;
  int64 user_id = 100;
}

message SpotCloseTargetResult {
  SpotCloseTarget target = 1;
  string base_asset = 2;
  string planned_qty_decimal = 3;
  string order_id = 4;
  string status = 5;
  string code = 6;
  string message = 7;
}

message CloseSpotTargetsResponse {
  string status = 1;
  string code = 2;
  repeated SpotCloseTargetResult results = 3;
  repeated portfolio.v1.VenueSnapshot final_snapshots = 4;
  string reconciliation_run_id = 5;
  bool reconciliation_required = 6;
  string operation_id = 7;
}
```

Import `portfolio_service.proto` from `order_service.proto`; do not duplicate wallet types in order.v1.

- [ ] **Step 1: Write RED all-or-nothing planning and mid-flight tests**

```go
func TestPlannerSendsNoOrdersWhenAnySpotTargetCannotFullyClose(t *testing.T) {
    deps := closeDeps{
        account: accountWithAssets(asset("BTC", "0.01000000", "0"), asset("ETH", "1", "0.10")),
        rules: rulesForBTCAndETH(),
        openOrders: noOpenOrders(),
        placer: &recordingPlacer{},
    }
    result, err := newPlanner(deps).Close(context.Background(), closeRequest("BTCUSDT", "ETHUSDT"))
    if err == nil || result.Code != "SPOT_CLOSE_LOCKED_BALANCE" {
        t.Fatalf("result=%#v err=%v", result, err)
    }
    if deps.placer.Calls() != 0 {
        t.Fatalf("orders sent before plan completed: %#v", deps.placer.Requests())
    }
}

func TestPlannerReportsPartialExecutionAndRequiresReconciliation(t *testing.T) {
    placer := newScriptedPlacer(successfulFill("BTCUSDT"), errors.New("exchange unavailable"))
    result, err := newPlanner(validCloseDeps(placer)).Close(
        context.Background(), closeRequest("BTCUSDT", "ETHUSDT"),
    )
    if err == nil || !result.ReconciliationRequired || result.Status != "stop_failed" {
        t.Fatalf("result=%#v err=%v", result, err)
    }
    assertTargetStatus(t, result, "BTCUSDT", "FILLED")
    assertTargetStatus(t, result, "ETHUSDT", "FAILED")
}
```

Add tests for stop-only zero calls, an already-zero declared target succeeding as `already_closed` without an order, a mixed batch with one zero and one non-zero target, duplicate symbols and distinct symbols mapping to one Venue/base asset producing exactly one sell, PlaceOrder returning NEW then waiter reaching FILLED, waiter timeout, PARTIALLY_FILLED then CANCELED, final account reread with residual free/locked balance, undeclared target, wrong venue ownership, Live Spot, disabled-Demo active-Session drain, disabled-Demo terminal/new Session rejection, open order, dust, invalid/expired metadata, unavailable price, pre-existing asset inclusion, BNB/USDT untouched, deterministic ordering, and same Spot/Futures symbol. Add barrier-controlled initial-planning races: when ordinary PlaceOrder owns one lease first, close acquires none and sends nothing; when close owns all leases first, ordinary PlaceOrder fails before risk/audit/exchange side effects; a hook placed immediately after lease acquisition proves every account/rules/filter/reference/open-order read occurs after that hook, so the former stale-snapshot-before-acquire interleaving cannot exist. After a failed acquisition and later retry, assert all snapshots are freshly reread rather than reused.

For preplan failure, all-already-closed, and full-success/final-reread cases, assert the exact owner/generation lease is released and a subsequent ordinary PlaceOrder is no longer rejected as close-pending. Inject a release CAS failure in each safe terminal and require `SPOT_CLOSE_LEASE_RELEASE_FAILED`, durable operator blocking, and continued ordinary-order rejection. For accepted-timeout, unresolved partial/terminal, and reread/repair failure, assert the lease remains blocking until the Task 6 coordinator records authoritative resolution and the same owner performs the release CAS.

Add accepted-then-response-timeout recovery, two concurrent duplicate RPCs, conflicting request reuse within one Session, identical supplied operation IDs in two Sessions remaining independently readable/recoverable, process/service restart while `sending` and while `submitted`, replay after terminal, and database tests proving each scenario issues at most one exchange SELL. In one combined fence test, let an accepted-but-timeout target's lease expire, race a higher-generation resume of the same composite `(session_id, operation_id)` owner against both another Session using the same bare ID, a different close operation, and ordinary PlaceOrder, and require only the original composite owner to win; it queries the original identity before sending, while all three competitors receive `SPOT_CLOSE_RECOVERY_PENDING` and exchange call count stays one. Assert every returned failure reconciliation ID already has a row, including account-reread failure; injected reconciliation insert failure must return the persistence error and no fabricated ID. The integration migration test uses an acceptance-owned random database from `HUSHINE_TEST_PG_ADMIN_DSN`, verifies both populated `0001 -> 0002 -> 0003` and fresh `0000 -> 0001 -> 0002 -> 0003` paths, asserts the checked-in `0001` SHA-256 is unchanged, and proves a forced body/ledger failure rolls back. It may skip only when the admin DSN is absent in an ordinary run; when the variable is set, every connection, owned-database, extension, migration, persistence, and cleanup-registration failure is fatal, so focused acceptance cannot silently skip.

Run:

```bash
cd /Users/xdy/Workplace/hushine-worktrees/medium-cleanup/core-service
test -n "$HUSHINE_TEST_PG_ADMIN_DSN"
CORE_SPOT_BASE_SHA=1b92b40c8337bd8a2c31871ef488b344e5d518a6 HUSHINE_TEST_PG_ADMIN_DSN="$HUSHINE_TEST_PG_ADMIN_DSN" go test -tags=integration ./internal/order/storage/migrations ./internal/order/spotclose -run 'TestSpotCloseOperationsMigration|TestSpotCloseOperationPersistence' -count=1 -v
go test ./internal/order/spotclose ./internal/order/service ./internal/reconciliation ./cmd/core-service ./internal/exchange/binance -run 'TestPlanner|TestCloseSpotTargets|TestSpotCloseOperation|TestSpotCloseProductionWiring|TestSpotOpenOrders' -count=1
go test ./... && go vet ./...
```

Expected RED: the RPC and planner package do not exist, and current stop logic lives in the worker with a blanket Spot-not-supported response.

- [ ] **Step 2: Implement plan-before-send using the audited PlaceOrder path**

Never quantize downward and silently leave dust. A closeable quantity must already satisfy exact LOT_SIZE/MARKET_LOT_SIZE and notional rules for the full free balance; otherwise fail the plan. The RPC response must include operation ID, target symbol, base asset, planned quantity, order ID, final durable status, structured code, and final snapshot/reconciliation identity without exposing credentials. `final_snapshots` may be populated only from the post-terminal account reread, never from the preplan snapshot or immediate REST order response.

Wire this in production, not only planner tests. Extend the order-service constructor/configuration with explicit Spot-close planner/store, account/rules/open-order readers, terminal waiter, admission leaser, attempt resolver, and synchronous reconciler dependencies. `cmd/core-service/main.go` constructs them from the real exchange registry, order repository, Portfolio repository, and reconciliation service before registering gRPC. A production-shape `main_test.go` starts the server construction path and exercises the RPC; any nil/missing close dependency must fail startup with a named configuration error, not panic or return unimplemented on the first stop request.

- [ ] **Step 3: Make planner/service tests GREEN**

```bash
cd /Users/xdy/Workplace/hushine-worktrees/medium-cleanup/core-service
make proto
gofmt -w internal/order/spotclose internal/order/service internal/order/repository internal/order/storage/migrations internal/reconciliation internal/repository internal/domain cmd/core-service internal/exchange/binance/order_capability.go internal/exchange/binance/order_state_reader.go internal/exchange/binance/order_state_reader_test.go
test -n "$HUSHINE_TEST_PG_ADMIN_DSN"
CORE_SPOT_BASE_SHA=1b92b40c8337bd8a2c31871ef488b344e5d518a6 HUSHINE_TEST_PG_ADMIN_DSN="$HUSHINE_TEST_PG_ADMIN_DSN" go test -tags=integration ./internal/order/storage/migrations ./internal/order/spotclose -run 'TestSpotCloseOperationsMigration|TestSpotCloseOperationPersistence' -count=1 -v
go test ./internal/order/spotclose ./internal/order/service ./internal/reconciliation ./cmd/core-service ./internal/exchange/binance -run 'TestPlanner|TestCloseSpotTargets|TestSpotCloseOperation|TestSpotCloseProductionWiring|TestSpotOpenOrders' -count=1
```

Expected GREEN: every preplan failure sends zero orders; duplicate Venue/base targets sell once; successful targets use normal order.v1 auditing, reach durable FILLED, and reconcile to exact zero; mid-flight/terminal/reread failures are explicit and reconciliation-required.

- [ ] **Step 4: Commit core-service only**

```bash
cd /Users/xdy/Workplace/hushine-worktrees/medium-cleanup/core-service
go test ./... && go vet ./...
git add proto/order_service.proto gen/orderv1/order_service.pb.go gen/orderv1/order_service_grpc.pb.go internal/order/spotclose/types.go internal/order/spotclose/planner.go internal/order/spotclose/planner_test.go internal/order/spotclose/operation_test.go internal/order/service/grpc.go internal/order/service/grpc_test.go internal/order/repository/repository.go internal/order/repository/timescale.go internal/order/repository/timescale_roundtrip_test.go internal/order/storage/migrations/0003_spot_close_operations.sql internal/order/storage/migrations/baseline_contract_test.go internal/order/storage/migrations/spot_close_operations_migration_test.go internal/reconciliation/service.go internal/reconciliation/service_test.go internal/repository/repository.go internal/repository/timescale.go internal/domain/model.go cmd/core-service/main.go cmd/core-service/main_test.go internal/exchange/binance/order_capability.go internal/exchange/binance/order_state_reader.go internal/exchange/binance/order_state_reader_test.go
git commit -m "feat(spot): add atomic target close planning"
```

---

### Task 9: Proxy and apply Spot stop actions without moving exchange logic into the worker

**Files:**
- Modify: `control-panel-service/internal/runtimechannel/platform_proxy.go`
- Modify: `control-panel-service/internal/runtimechannel/platform_proxy_test.go`
- Modify: `control-panel-service/internal/runtimechannel/auth.go`
- Modify: `control-panel-service/internal/runtimechannel/auth_test.go`
- Modify: `strategy-service/generate_proto.sh`
- Modify: `strategy-service/proto/strategy_service.proto`
- Regenerate: `strategy-service/strategy_service/gen/order_service_pb2.py`
- Regenerate: `strategy-service/strategy_service/gen/order_service_pb2_grpc.py`
- Regenerate: `strategy-service/strategy_service/gen/strategy_service_pb2.py`
- Regenerate: `strategy-service/strategy_service/gen/strategy_service_pb2_grpc.py`
- Regenerate: `strategy-service/gen/strategyv1/strategy_service.pb.go`
- Regenerate: `strategy-service/gen/strategyv1/strategy_service_grpc.pb.go`
- Modify: `strategy-service/strategy_service/order_client.py`
- Modify: `strategy-service/strategy_service/platform_proxy.py`
- Modify: `strategy-service/strategy_service/grpc_server.py`
- Modify: `strategy-service/tests/test_order_client.py`
- Modify: `strategy-service/tests/test_platform_proxy.py`
- Modify: `strategy-service/tests/test_grpc_server.py`
- Create: `strategy-service/tests/test_generated_proto_imports.py`
- Modify: `strategy-service/internal/runtimeagent/session_lifecycle.go` (created by the Indicator Task 7 prerequisite)
- Modify: `strategy-service/internal/runtimeagent/session_lifecycle_test.go` (created by the Indicator Task 7 prerequisite)
- Modify: `strategy-service/internal/runtimeagent/agent_test.go` (extended by the Indicator Task 7 prerequisite)

**Interfaces:**
- Prerequisite: Indicator Task 7 has created the generation-aware `SessionLifecycle` and its tests. If the two plans are implemented in one branch, finish that task first and stage the Spot-specific hunks separately; Spot Task 9 must not create a second terminal coordinator or be deployed on worker protocol V1.
- Extend control-panel's `OrderPlatformClient` with `CloseSpotTargets(context.Context, *orderv1.CloseSpotTargetsRequest)` and add canonical RuntimeChannel method `order.CloseSpotTargets`.
- Task 8 has now added the real `order_service.proto -> portfolio_service.proto` import. Extend `strategy-service/generate_proto.sh` on both GNU and BSD/macOS paths so generated `order_service_pb2.py` uses `from . import portfolio_service_pb2 as portfolio__service__pb2`; `tests/test_generated_proto_imports.py` must import `strategy_service.gen.order_service_pb2` from a subprocess whose cwd is outside the repository.
- RuntimeChannel validates worker token, runtime binding, Session ownership, user/Portfolio/strategy IDs, and that each requested route belongs to the active Session before forwarding. It does not calculate assets, quantities, filters, or orders.
- Add `close_spot_targets` to direct and proxy Python order clients with identical request/response behavior.
- Add `operation_id = 4` to `strategy.v1.StopStrategyRequest` and `operation_id = 6` to `StopStrategyResponse`. For `STOP_AND_CLOSE`, derive a UUID-format identifier deterministically from a fixed Hushine namespace plus `(session_id, stop_action)` when the field is empty; propagate it unchanged through Python, RuntimeChannel, and core, and echo core's value. The derivation uses no process-local counter, so a retried request and a reconstructed worker after Runtime restart address the same durable operation. A supplied non-empty value must round-trip unchanged.
- `StopStrategy(STOP_ONLY)` first closes new strategy-decision admission, then waits through the existing pending-order lifecycle reader until every already accepted order is terminal; it sends no close/cancel/new order and does not change wallet assets. A bounded wait timeout reports desired `stop_failed` with pending order identities instead of falsely reporting stopped. `StopStrategy(STOP_AND_CLOSE)` partitions declared targets by market: Futures keeps the existing close path; Spot starts one logical durable core operation and any transport retry reuses its operation ID, then applies the authoritative post-terminal final snapshot. Any failure reports desired terminal state `stop_failed` and exposes per-target codes.
- The Python worker never persists `stopped`, `stop_failed`, or `recoverable`. It returns the stop operation result and emits one typed desired `FinalStatus` carrying status/reason plus the already allocated `reconciliation_run_id=6`; `dependency_error=5` remains unchanged. The Indicator V2 `SessionLifecycle` in the Go Agent remains the sole external terminal publisher: it closes frame admission, finalizes the indicator tail, then persists the desired stop state. A successful exchange close cannot bypass or race indicator finalization.
- Before a Backtest Spot close call, the worker persists its current canonical wallet through the existing `UpdatePortfolioWalletState` RPC and waits for acknowledgement so core plans from the latest local state. Demo ignores that local copy for planning and rereads `/api/v3/account`; both environments use the returned final snapshot after execution.
- Extend `strategy.v1.StopStrategyResponse` additively with `status = 2`, `code = 3`, repeated `StopTargetResult target_results = 4`, `reconciliation_run_id = 5`, and `operation_id = 6`; keep `stopped = 1` for old clients. `StopTargetResult` contains exchange, market, symbol, status, code, and message but no credential or quantity invented by the worker.

- [ ] **Step 1: Write RED proxy authorization and worker stop tests**

```go
func TestCloseSpotTargetsProxyRequiresActiveSessionOwnership(t *testing.T) {
    platform := &fakeOrderPlatformClient{}
    svc := newRuntimeChannelService(t, platform)
    frame := closeSpotTargetsFrame("runtime-a", "session-owned-by-runtime-b")
    got := dispatchFrame(t, svc, authenticatedStream("runtime-a"), frame)
    if got.Code != "SESSION_RUNTIME_MISMATCH" {
        t.Fatalf("response = %#v", got)
    }
    if platform.CloseCalls != 0 {
        t.Fatalf("unauthorized call reached core: %d", platform.CloseCalls)
    }
}
```

```python
def test_stop_only_never_calls_spot_close_rpc():
    order_client = RecordingOrderClient()
    server = strategy_server(order_client=order_client, targets=[spot_target("BTCUSDT")])
    response = server.StopStrategy(stop_request(action=STOP_ONLY), FakeContext())
    assert response.status == "stopped"
    assert order_client.close_spot_calls == []


def test_stop_and_close_forwards_only_declared_spot_targets_and_applies_snapshot():
    order_client = RecordingOrderClient(close_response=successful_spot_close("BTCUSDT"))
    server = strategy_server(
        order_client=order_client,
        targets=[spot_target("BTCUSDT"), futures_target("BTCUSDT")],
    )
    response = server.StopStrategy(stop_request(action=STOP_AND_CLOSE), FakeContext())
    assert order_client.close_spot_calls[0].targets[0].symbol == "BTCUSDT"
    assert response.status == "stopped"
    assert server.wallet.route(spot_route()).assets["BTC"].free == Decimal("0")
```

Add stop-only cases for no pending orders, NEW→FILLED while waiting, an already terminal order, and a nonterminal order timing out to desired `stop_failed`; all assert zero cancel/close/new-order calls and unchanged assets. Add unavailable core, mismatched runtime, wrong Session user, undeclared target, Live Spot, target preplan failure, partial execution, reconciliation-required, and mixed Futures/Spot response cases. Invoke the same Session/action twice and through a newly constructed worker, assert all three calls carry the identical operation ID, and prove an explicitly supplied ID is preserved; a different Session or action must derive a different ID.
Add a Backtest ordering assertion that `UpdatePortfolioWalletState` completes before `CloseSpotTargets`, and a Demo assertion that core's fresh account response wins over stale worker state.
Add source/behavior assertions that Python makes zero terminal `UpdateSession` calls for both stop actions. In `session_lifecycle_test.go`, feed the worker's Spot stopped/stop_failed final status and require exact order `close-admission, finalize-indicator-tail, update-session`; a finalization failure must persist `recoverable`, retain the tail for retry, and must not report `stopped` merely because exchange close succeeded.

Run:

```bash
cd /Users/xdy/Workplace/hushine-worktrees/medium-cleanup/control-panel-service
go test ./internal/runtimechannel -run 'TestCloseSpotTargetsProxy' -count=1
cd /Users/xdy/Workplace/hushine-worktrees/medium-cleanup/strategy-service
# Consume the actual Task 8 producer proto before testing the still-unfixed import rewrite.
grep -Fq 'import "portfolio_service.proto";' ../core-service/proto/order_service.proto
./generate_proto.sh
grep -Eq '^import portfolio_service_pb2 as portfolio__service__pb2' strategy_service/gen/order_service_pb2.py
PYTHONPATH=.:../strategy-library uv run --frozen --extra dev pytest tests/test_order_client.py tests/test_platform_proxy.py tests/test_grpc_server.py tests/test_generated_proto_imports.py -q
```

Expected RED: the proxy method is unknown and current worker stop rejects Spot with `spot_liquidation_not_supported`; after regenerating from Task 8's real proto, the outside-cwd import fixture also fails on the demonstrated absolute `portfolio_service_pb2` import.

- [ ] **Step 2: Implement authenticated pass-through and worker state handling**

First implement the portable generated-import rewrite and rerun the exact same generator path from Task 8's current core proto; make the outside-cwd import fixture pass without hand-editing generated code. Reuse the same canonical protobuf JSON envelope and timeout/error mapping as `order.PlaceOrder`. Delete the worker's symbol-suffix liquidation builder for Spot. Do not emit desired `stopped` until core confirms all planned Spot targets and existing Futures close work succeeded; emit desired `stop_failed` plus the durable reconciliation identity in `FinalStatus.reconciliation_run_id=6` otherwise. Descriptor tests must prove fields 5 and 6 coexist and the Agent's `TerminalRequest.ReconciliationRunID` receives field 6 without inventing a value. Route both through the existing Agent terminal coordinator and keep Python's agent-managed terminal-persistence guard enabled for every stop outcome.

- [ ] **Step 3: Make proxy and stop matrices GREEN**

```bash
cd /Users/xdy/Workplace/hushine-worktrees/medium-cleanup/control-panel-service
gofmt -w internal/runtimechannel/platform_proxy.go internal/runtimechannel/platform_proxy_test.go internal/runtimechannel/auth.go internal/runtimechannel/auth_test.go
go test ./internal/runtimechannel -run 'TestCloseSpotTargetsProxy' -count=1
cd /Users/xdy/Workplace/hushine-worktrees/medium-cleanup/strategy-service
./generate_proto.sh
PYTHONPATH=.:../strategy-library uv run --frozen --extra dev pytest tests/test_order_client.py tests/test_platform_proxy.py tests/test_grpc_server.py tests/test_generated_proto_imports.py -q
go test ./... -count=1
go test ./internal/runtimeagent -run 'SessionLifecycle.*SpotStop|Agent.*SpotStop' -count=1
```

Expected GREEN: unauthorized calls never reach core, stop-only sends zero orders, successful close applies the returned wallet, partial failure reports `stop_failed`, and only the Agent persists stopped/stop_failed/recoverable after indicator finalization.

- [ ] **Step 4: Commit the two repositories independently**

```bash
cd /Users/xdy/Workplace/hushine-worktrees/medium-cleanup/control-panel-service
git add internal/runtimechannel/platform_proxy.go internal/runtimechannel/platform_proxy_test.go internal/runtimechannel/auth.go internal/runtimechannel/auth_test.go
git commit -m "feat(runtime): proxy authorized spot close requests"
cd /Users/xdy/Workplace/hushine-worktrees/medium-cleanup/strategy-service
git add generate_proto.sh proto/strategy_service.proto strategy_service/gen/order_service_pb2.py strategy_service/gen/order_service_pb2_grpc.py strategy_service/gen/strategy_service_pb2.py strategy_service/gen/strategy_service_pb2_grpc.py gen/strategyv1/strategy_service.pb.go gen/strategyv1/strategy_service_grpc.pb.go strategy_service/order_client.py strategy_service/platform_proxy.py strategy_service/grpc_server.py internal/runtimeagent/session_lifecycle.go internal/runtimeagent/session_lifecycle_test.go internal/runtimeagent/agent_test.go tests/test_order_client.py tests/test_platform_proxy.py tests/test_grpc_server.py tests/test_generated_proto_imports.py
git commit -m "feat(spot): apply core-authoritative stop results"
```

---

### Task 10: Add Spot and mixed-route replay to strategy-library

**Files:**
- Create: `strategy-library/hushine_strategy/wallet/spot.py`
- Create: `strategy-library/hushine_strategy/wallet/portfolio.py`
- Modify: `strategy-library/hushine_strategy/wallet/__init__.py`
- Modify: `strategy-library/hushine_strategy/replay/engine.py`
- Modify: `strategy-library/hushine_strategy/replay/__init__.py`
- Create: `strategy-library/hushine_strategy/replay/spot_filters.py`
- Modify: `strategy-library/tests/hushine_strategy/test_replay.py`
- Create: `strategy-library/tests/hushine_strategy/test_spot_wallet.py`
- Create: `strategy-library/tests/hushine_strategy/test_mixed_route_replay.py`
- Create: `strategy-library/tests/hushine_strategy/test_spot_filter_contract.py`
- Create: `strategy-library/tests/fixtures/spot_filter_contract_v1.json`

**Interfaces:**
- Add public `SpotWallet`, `SpotAssetBalance`, `SpotSymbolMetadata`, and route-aware `PortfolioWallet` types using `Decimal`.
- `ReplayEngine` accepts a wallet plus metadata snapshot and dispatches market data by the full identity `(stream_id, exchange, market, kind, symbol, interval)`. It allows only declared `INPUTS` and `ORDER_TARGETS`; Spot execution maps through metadata and applies the same BUY/SELL/commission transitions as Hosted Backtest. Neither `symbol+interval` nor `(exchange, market, symbol, interval)` is sufficient to deduplicate streams.
- `spot_filters.evaluate(order, immutable_facts, wallet, open_orders)` implements the exact Task 5 MARKET/LIMIT admission contract with `Decimal`, including percent/reference price, `MAX_POSITION`, `MAX_ASSET`, order counts, balance, unknown filters, and 38/18 bounds. It consumes package facts only and has no network fallback. Generate the committed fixture with core's deterministic generator and require byte-identical SHA parity in tests.
- Fill/wallet mutation uses the full `(venue_id, exchange, market, symbol, exchange_order_id, exchange_trade_id)` identity. The same POST/WS/REST trade representation applies base/quote/commission once; cumulative order state is not a fee idempotency key.
- The library performs no network I/O and contains no Binance credential or endpoint client.

- [ ] **Step 1: Write RED parity and route-isolation tests**

```python
def test_spot_replay_buy_sell_matches_canonical_wallet():
    wallet = SpotWallet.from_assets({"USDT": ("1000", "0"), "BNB": ("1", "0")})
    metadata = {spot_route_key("BTCUSDT"): spot_metadata("BTCUSDT", "BTC", "USDT")}
    engine = ReplayEngine(wallet=PortfolioWallet.spot(wallet), metadata=metadata)
    engine.apply_fill(spot_fill("BUY", "BTCUSDT", "0.01", "500", "0.001", "BNB"))
    engine.apply_fill(spot_fill("SELL", "BTCUSDT", "0.01", "510", "0.51", "USDT"))
    assert wallet.assets["BTC"].free == Decimal("0")
    assert wallet.assets["USDT"].free == Decimal("1009.49")
    assert wallet.assets["BNB"].free == Decimal("0.999")


def test_same_symbol_spot_and_futures_replay_are_isolated():
    engine = mixed_route_engine("BTCUSDT")
    engine.push_bar(route="binance/spot/BTCUSDT/1m", close="50000")
    engine.push_bar(route="binance/perpetual_futures/BTCUSDT/1m", close="50100")
    assert engine.last_price(spot_route_key("BTCUSDT")) == Decimal("50000")
    assert engine.last_price(futures_route_key("BTCUSDT")) == Decimal("50100")
```

Add multi-symbol, same-symbol two-interval, same route facts with distinct `stream_id`, same symbol with distinct `kind`, input-only no-order, undeclared route, metadata absence, USDT quote restriction, partial/cancel lifecycle, POST→same-trade WS→same-trade REST fee overlap, and Futures regression cases. Run every Task 5 golden filter vector with socket/network construction patched to fail.

Run:

```bash
cd /Users/xdy/Workplace/hushine-worktrees/medium-cleanup/strategy-library
go run ../core-service/cmd/generate-spot-filter-vectors -out "$PWD/tests/fixtures/spot_filter_contract_v1.json"
uv run --isolated --no-project --with-editable '.[test]' pytest tests/hushine_strategy/test_spot_wallet.py tests/hushine_strategy/test_mixed_route_replay.py tests/hushine_strategy/test_replay.py tests/hushine_strategy/test_spot_filter_contract.py -q
```

Expected RED: replay constructs only `FuturesWallet` and rejects non-Futures targets.

- [ ] **Step 2: Implement library-owned canonical Spot replay**

Do not import `strategy-service` from the library. Keep the contract parity explicit with the generated filter fixture plus shared fill scenario values, and add a contract test in `strategy-service/tests/test_strategy_engine.py` that runs the same filter/fill vectors through both engines and compares stable codes and canonical JSON.

- [ ] **Step 3: Make replay parity tests GREEN**

```bash
cd /Users/xdy/Workplace/hushine-worktrees/medium-cleanup/strategy-library
go run ../core-service/cmd/generate-spot-filter-vectors -check "$PWD/tests/fixtures/spot_filter_contract_v1.json"
uv run --isolated --no-project --with-editable '.[test]' pytest tests/ -q
cd /Users/xdy/Workplace/hushine-worktrees/medium-cleanup/strategy-service
PYTHONPATH=.:../strategy-library uv run --frozen --extra dev pytest tests/test_strategy_engine.py -q -k 'spot_replay_parity'
```

Expected GREEN: library and Hosted Backtest emit identical canonical wallet values for the shared Spot vectors, and the full library suite keeps Futures green.

- [ ] **Step 4: Commit strategy-library and the parity test independently**

```bash
cd /Users/xdy/Workplace/hushine-worktrees/medium-cleanup/strategy-library
uv run --isolated --no-project --with-editable '.[test]' python -m compileall -q hushine_strategy tests
git add hushine_strategy/wallet/spot.py hushine_strategy/wallet/portfolio.py hushine_strategy/wallet/__init__.py hushine_strategy/replay/engine.py hushine_strategy/replay/__init__.py hushine_strategy/replay/spot_filters.py tests/hushine_strategy/test_replay.py tests/hushine_strategy/test_spot_wallet.py tests/hushine_strategy/test_mixed_route_replay.py tests/hushine_strategy/test_spot_filter_contract.py tests/fixtures/spot_filter_contract_v1.json
git commit -m "feat(replay): support spot and mixed routes"
cd /Users/xdy/Workplace/hushine-worktrees/medium-cleanup/strategy-service
git add tests/test_strategy_engine.py
git commit -m "test(spot): assert hosted replay parity"
```

---

### Task 11: Produce and consume an offline debug package v2

**Files:**
- Modify: `gateway/quant-handler/internal/app/debug_package.go`
- Modify: `gateway/quant-handler/internal/app/debug_package_parquet.go`
- Modify: `gateway/quant-handler/internal/app/debug_package_test.go`
- Modify: `gateway/quant-handler/internal/app/debugger.go`
- Modify: `gateway/quant-handler/internal/app/debugger_test.go`
- Modify: `strategy-debugger-cli/pyproject.toml`
- Modify generated lock: `strategy-debugger-cli/uv.lock`
- Modify: `strategy-debugger-cli/src/hushine_debugger/data/manifest.py`
- Modify: `strategy-debugger-cli/src/hushine_debugger/import_package.py`
- Modify: `strategy-debugger-cli/src/hushine_debugger/config.py`
- Modify: `strategy-debugger-cli/src/hushine_debugger/replay.py`
- Modify: `strategy-debugger-cli/src/hushine_debugger/integrity.py`
- Modify: `strategy-debugger-cli/src/hushine_debugger/templates/hushine-debug.yaml`
- Modify: `strategy-debugger-cli/src/hushine_debugger/templates/wallet.yaml`
- Create: `strategy-debugger-cli/tests/test_import_package.py`
- Modify: `strategy-debugger-cli/tests/test_replay_cli.py`
- Create: `strategy-debugger-cli/tests/test_spot_package_v2.py`
- Create: `strategy-debugger-cli/tests/test_mixed_route_package_v2.py`
- Create: `strategy-debugger-cli/tests/test_spot_filter_contract.py`
- Create: `strategy-debugger-cli/tests/fixtures/spot_filter_contract_v1.json`

**Interfaces:**
- Prerequisite: execute this task after the approved Python dependency-contract plan has added `strategy-debugger-cli/uv.lock`. Task 10 has now created the final Spot-plan strategy-library commit, so this task must repin the debugger's canonical HTTPS Git requirement and lock to that exact full SHA before GREEN. Every pre-push debugger lock/sync/run goes through `scripts/with-local-strategy-library-git.sh`; the transport-only bare mirror never appears in `pyproject.toml`, `uv.lock`, docs, or direct-url expectations. `strategy-library` intentionally has no lock and runs through an isolated `--no-project --with-editable '.[test]'` environment that leaves the repository clean.
- Quant-handler takes `strategy_id`, `start_time_ms`, and `end_time_ms`; it loads the active strategy declaration server-side and does not trust caller-authored routes. Package v2 contains:

```yaml
schema_version: 2
inputs:
  - stream_id: spot-btc-1m
    exchange: binance
    market: spot
    kind: kline
    symbol: BTCUSDT
    interval: 1m
order_targets:
  - exchange: binance
    market: spot
    symbol: BTCUSDT
symbol_metadata_snapshot:
  generated_at_ms: 1784000000000
  symbols:
    - symbol: BTCUSDT
      base_asset: BTC
      quote_asset: USDT
data_files:
  - stream_id: spot-btc-1m
    route: binance/spot/kline/BTCUSDT/1m
    path: data/streams/spot-btc-1m/binance/spot/kline/BTCUSDT/1m.parquet
wallet:
  assets:
    - asset: USDT
      free: "1000.00000000"
      locked: "0.00000000"
```

- A package contains one Parquet file for every declared full stream identity `(stream_id, exchange, market, kind, symbol, interval)`, canonical wallet assets, exact metadata/filter strings for every Spot input/target, SHA-256 integrity entries, and no credential or endpoint. Duplicate stream IDs or duplicate full identities fail export/import; two identities that differ only by stream ID or kind remain distinct files/dispatch routes.
- Import is offline-only: missing stream, metadata, wallet asset, hash, or unsupported schema fails before replay. Existing package v1 Futures imports remain read-compatible; all newly exported packages are v2.
- Before exporting any package containing a Spot route, quant-handler obtains core's effective capability snapshot and requires `offline_spot_usdt=true`; an unavailable discovery RPC fails closed. The package embeds the immutable Task 5 filter/reference-price facts and their schema/hash, never a capability override. Once legitimately exported, replay remains fully offline and does not phone home; disabling the flag prevents new exports/downloads while preserving already downloaded artifacts and Futures-v1 import compatibility.
- Generate the debugger's `tests/fixtures/spot_filter_contract_v1.json` only with the Task 5 core generator. `test_spot_filter_contract.py` checks byte-identical SHA-256 against the core and strategy-library copies, evaluates every vector through the package-v2 replay path, asserts the exact stable code, and patches socket/HTTP constructors to fail on any network attempt.

- [ ] **Step 1: Write RED package shape, integrity, and no-network tests**

```go
func TestDebugPackageV2UsesStrategyRoutesAndCanonicalSpotFacts(t *testing.T) {
    app := newDebugPackageApp(t, mixedSpotFuturesStrategy())
    zipBytes := requestDebugPackage(t, app, debugPackageRequest{StrategyID: 42})
    manifest := readManifestFromZip(t, zipBytes)
    if manifest.SchemaVersion != 2 || len(manifest.Inputs) != 3 {
        t.Fatalf("manifest = %#v", manifest)
    }
    assertZipPath(t, zipBytes, "data/streams/spot-btc-1m/binance/spot/kline/BTCUSDT/1m.parquet")
    assertZipPath(t, zipBytes, "data/streams/spot-eth-5m/binance/spot/kline/ETHUSDT/5m.parquet")
    assertNoZipText(t, zipBytes, "api_key")
    assertNoZipText(t, zipBytes, "api_secret")
}
```

```python
def test_spot_package_v2_replays_with_network_disabled(monkeypatch, tmp_path):
    package = build_spot_package_v2(tmp_path)
    monkeypatch.setattr(socket, "create_connection", lambda *args, **kwargs: (_ for _ in ()).throw(AssertionError("network used")))
    workspace = import_package(package, tmp_path / "workspace")
    result = replay_workspace(workspace)
    assert result.wallet.assets["USDT"].free == Decimal("1000")
    assert "BTCUSDT" not in result.wallet.assets
```

Add default-disabled/offline-enabled/capability-RPC-unavailable export, tampered hash, absent Spot metadata/filter/reference facts, missing interval file, duplicate stream ID, duplicate full route, same route facts with distinct stream IDs, same symbol/interval with distinct kinds, undeclared data file, v1 Futures compatibility, same-symbol mixed-market, multi-symbol/multi-interval, golden filter parity, and package reproducibility cases.

Run:

```bash
cd /Users/xdy/Workplace/hushine-worktrees/medium-cleanup/gateway/quant-handler
go test ./internal/app -run 'TestDebugPackageV2|TestDebugPackage.*Spot' -count=1
cd /Users/xdy/Workplace/hushine-worktrees/medium-cleanup/strategy-debugger-cli
go run ../core-service/cmd/generate-spot-filter-vectors -out "$PWD/tests/fixtures/spot_filter_contract_v1.json"
./scripts/with-local-strategy-library-git.sh ../strategy-library \
  uv run --frozen --extra test pytest tests/test_import_package.py tests/test_replay_cli.py tests/test_spot_package_v2.py tests/test_mixed_route_package_v2.py tests/test_spot_filter_contract.py -q
```

Expected RED: handler writes one Futures-only `data.parquet`, manifest lacks Spot metadata, and debugger defaults/hardcodes Futures.

- [ ] **Step 2: Implement deterministic v2 export and strict offline import**

Sort routes and assets before serializing. Generate hashes after every file is finalized, reject any archive path traversal, and validate declaration-to-file equality in both exporter and importer. Keep the existing Binance Futures downloader only for explicitly non-package legacy workspaces; never invoke it for a v2 package.

After the Task 10 library commit and before running GREEN, repin with the dependency plan's transport-only wrapper:

```bash
cd /Users/xdy/Workplace/hushine-worktrees/medium-cleanup/strategy-debugger-cli
LIBRARY_COMMIT="$(git -C ../strategy-library rev-parse HEAD)"
test "${#LIBRARY_COMMIT}" -eq 40
./scripts/with-local-strategy-library-git.sh ../strategy-library \
  uv add --no-sync "hushine-strategy-library @ git+https://github.com/hushine-tech/strategy-library.git@${LIBRARY_COMMIT}"
./scripts/with-local-strategy-library-git.sh ../strategy-library uv lock --check
rg -n "https://github.com/hushine-tech/strategy-library.git.*${LIBRARY_COMMIT}" pyproject.toml uv.lock
if rg -n 'file:|\.\./strategy-library|insteadOf|mirror' pyproject.toml uv.lock; then exit 1; fi
bash scripts/bootstrap-standalone.test.sh --library-repo ../strategy-library
```

The standalone test runs every currently released debugger minor satisfying `>=3.12` (3.12, 3.13, and 3.14 for this release), checks installed `direct_url` metadata equals the canonical URL and `$LIBRARY_COMMIT`, and leaves no sibling-source dependency. No later Spot task may modify strategy-library; if review fixes do, repeat this repin and invalidate every debugger/image acceptance result.

- [ ] **Step 3: Make handler and debugger package suites GREEN**

```bash
cd /Users/xdy/Workplace/hushine-worktrees/medium-cleanup/gateway/quant-handler
gofmt -w internal/app/debug_package.go internal/app/debug_package_parquet.go internal/app/debug_package_test.go internal/app/debugger.go internal/app/debugger_test.go
go test ./internal/app -run 'TestDebugPackageV2|TestDebugPackage.*Spot|TestDebugger' -count=1
cd /Users/xdy/Workplace/hushine-worktrees/medium-cleanup/strategy-debugger-cli
go run ../core-service/cmd/generate-spot-filter-vectors -check "$PWD/tests/fixtures/spot_filter_contract_v1.json"
./scripts/with-local-strategy-library-git.sh ../strategy-library \
  uv run --frozen --extra test pytest tests/ -q
```

Expected GREEN: v2 packages are deterministic, complete, credential-free, and replay with networking disabled; v1 Futures compatibility still passes.

- [ ] **Step 4: Commit quant-handler and debugger independently**

```bash
cd /Users/xdy/Workplace/hushine-worktrees/medium-cleanup/gateway/quant-handler
git add internal/app/debug_package.go internal/app/debug_package_parquet.go internal/app/debug_package_test.go internal/app/debugger.go internal/app/debugger_test.go
git commit -m "feat(debug): export route-complete package v2"
cd /Users/xdy/Workplace/hushine-worktrees/medium-cleanup/strategy-debugger-cli
git add pyproject.toml uv.lock src/hushine_debugger/data/manifest.py src/hushine_debugger/import_package.py src/hushine_debugger/config.py src/hushine_debugger/replay.py src/hushine_debugger/integrity.py src/hushine_debugger/templates/hushine-debug.yaml src/hushine_debugger/templates/wallet.yaml tests/test_import_package.py tests/test_replay_cli.py tests/test_spot_package_v2.py tests/test_mixed_route_package_v2.py tests/test_spot_filter_contract.py tests/fixtures/spot_filter_contract_v1.json
git commit -m "feat(debugger): replay offline spot packages"
```

---

### Task 12: Make quant-handler preserve canonical Spot routes and assets

**Files:**
- Create: `gateway/quant-handler/internal/app/capabilities.go`
- Create: `gateway/quant-handler/internal/app/capabilities_test.go`
- Modify: `gateway/quant-handler/internal/app/app.go`
- Modify: `gateway/quant-handler/internal/app/venues.go`
- Modify: `gateway/quant-handler/internal/app/venues_test.go`
- Modify: `gateway/quant-handler/internal/app/wallet_bootstrap.go`
- Modify: `gateway/quant-handler/internal/app/portfolios_ext.go`
- Modify: `gateway/quant-handler/internal/app/portfolios_ext_test.go`
- Modify: `gateway/quant-handler/internal/app/strategy.go`
- Modify: `gateway/quant-handler/internal/app/strategy_test.go`
- Modify: `gateway/quant-handler/internal/app/strategy_cutover_test.go`
- Modify: `gateway/quant-handler/internal/app/order_history.go`
- Modify: `gateway/quant-handler/internal/app/order_history_test.go`
- Modify: `gateway/quant-handler/internal/app/session_history.go`
- Modify: `gateway/quant-handler/internal/app/session_history_test.go`
- Modify: `gateway/quant-handler/internal/app/enum_labels.go`
- Modify: `gateway/quant-handler/internal/walletagg/totalvalue.go`
- Modify: `gateway/quant-handler/internal/walletagg/totalvalue_test.go`

**Interfaces:**
- Add authenticated `GET /api/capabilities` as a transparent projection of core `GetProductCapabilities`; return exact names plus configured/effective/reason. Handler never upgrades a false or missing core value to true, and discovery failure returns 503/fail-closed rather than permissive cached data.
- Before Spot start/preview, require effective `backtest_spot_usdt` or `demo_spot_usdt`; before Spot debug-package export, require `offline_spot_usdt`. Live remains rejected even if configured true. A flag disabled after start blocks new run/order actions but still permits status/history, stop-only, drain close, lifecycle, and reconciliation for that existing Session. Futures paths do not depend on Spot flags.
- Spot wallet JSON is canonical:

```go
type spotAssetResponse struct {
    Asset         string `json:"asset"`
    Free          string `json:"free"`
    Locked        string `json:"locked"`
    AvgEntryPrice string `json:"avg_entry_price,omitempty"`
    Price         string `json:"price,omitempty"`
}

type spotWalletResponse struct {
    Assets []spotAssetResponse `json:"assets"`
}
```

- Backtest Spot bootstrap accepts asset codes and exact decimal strings. It rejects duplicate assets, `BTCUSDT` as an asset, negative values, unsupported precision, and a missing USDT asset. Handler reads legacy core wire fields only as a rolling fallback and always returns canonical JSON.
- Start/preview/stop requests preserve market enum `SPOT`; they never rewrite it to Futures. Handler rejects Live Spot with `SPOT_LIVE_ROLLOUT_GUARD` before proxying, while core remains the final guard.
- Valuation maps `metadata.baseAsset` to each USDT symbol price. It does not append `USDT` or strip symbol suffixes.
- Order/session history JSON exposes exact requested/original/executed/remaining/average/price/fill/quote/fee decimal strings and `fee_asset`. It prefers the new exact protobuf fields and uses legacy doubles only when an old core omitted them; it never formats a new exact value through `float64`.
- Structured errors preserve `environment`, `retryable`, and `source` with code/route/filter fields; handler never derives retryability or source from message text.

- [ ] **Step 1: Write RED HTTP contract and guard tests**

```go
func TestVenueSpotWalletReturnsCanonicalAssets(t *testing.T) {
    app := newAppWithSpotSnapshot(t, legacyAndCanonicalSpotFixture())
    response := getJSON(t, app, "/api/portfolios/7")
    assets := response.Path("venues.0.wallet.spot.assets").Array()
    requireAsset(t, assets, "USDT", "1000.00000000", "0.00000000")
    requireAsset(t, assets, "BTC", "0.01000000", "0.00100000")
    forbidAsset(t, assets, "BTCUSDT")
}

func TestStartSessionRejectsLiveSpotBeforeStrategyProxy(t *testing.T) {
    proxy := &recordingStrategyProxy{}
    app := newApp(t, withStrategyProxy(proxy), withPortfolioEnvironment(2))
    got := postJSON(t, app, "/api/strategies/run", liveSpotRunBody())
    if got.StatusCode != http.StatusPreconditionFailed || got.ErrorCode != "SPOT_LIVE_ROLLOUT_GUARD" {
        t.Fatalf("response = %#v", got)
    }
    if proxy.RunCalls != 0 {
        t.Fatalf("guarded request was proxied: %d", proxy.RunCalls)
    }
}
```

Add all-four-default-false discovery, one-flag-at-a-time discovery, discovery unavailable, Backtest/Demo/offline disabled admission, enabled admission, running-Session drain, Live misconfiguration, Futures zero-policy-call, canonical bootstrap validation, legacy read compatibility, Spot Demo pass-through, mixed route payload, same-symbol route isolation, structured preflight error propagation including environment/retryable/source, stop-only, stop-and-close, metadata-based valuation, and order/session-history cases that preserve `9007199254740993.00000000`, `0.00000001`, cumulative quote, and BNB fee strings without rounding.

Run:

```bash
cd /Users/xdy/Workplace/hushine-worktrees/medium-cleanup/gateway/quant-handler
go test ./internal/app ./internal/walletagg -run 'Test.*Spot|TestProductCapabilities|TestStartSessionRejectsLiveSpot' -count=1
```

Expected RED: handler still emits/accepts ambiguous `symbol/qty`, valuation relies on symbol text, and Live Spot is not guarded at the HTTP boundary.

- [ ] **Step 2: Implement canonical DTO mapping and server-side route guard**

Keep exact strings in request DTOs until protobuf mapping. Normalize asset codes to uppercase only after validating Binance asset syntax; do not convert an asset into a trading symbol. Map core structured error code, route, symbol, filter type, environment, retryable, source, and message unchanged to the HTTP error body.

- [ ] **Step 3: Make HTTP contract tests GREEN**

```bash
cd /Users/xdy/Workplace/hushine-worktrees/medium-cleanup/gateway/quant-handler
gofmt -w internal/app/capabilities.go internal/app/capabilities_test.go internal/app/app.go internal/app/venues.go internal/app/venues_test.go internal/app/wallet_bootstrap.go internal/app/portfolios_ext.go internal/app/portfolios_ext_test.go internal/app/strategy.go internal/app/strategy_test.go internal/app/strategy_cutover_test.go internal/app/order_history.go internal/app/order_history_test.go internal/app/session_history.go internal/app/session_history_test.go internal/app/enum_labels.go internal/walletagg
go test ./internal/app ./internal/walletagg -run 'Test.*Spot|TestProductCapabilities|TestStartSessionRejectsLiveSpot' -count=1
```

Expected GREEN: discovery mirrors effective flags, disabled actions fail before proxying, HTTP payloads contain asset codes only, exact values/errors survive, enabled Spot Demo is preserved, Live fails before proxying, running Sessions can drain, and Futures is unchanged.

- [ ] **Step 4: Commit quant-handler only**

```bash
cd /Users/xdy/Workplace/hushine-worktrees/medium-cleanup/gateway/quant-handler
go test ./... && go vet ./...
git add internal/app/capabilities.go internal/app/capabilities_test.go internal/app/app.go internal/app/venues.go internal/app/venues_test.go internal/app/wallet_bootstrap.go internal/app/portfolios_ext.go internal/app/portfolios_ext_test.go internal/app/strategy.go internal/app/strategy_test.go internal/app/strategy_cutover_test.go internal/app/order_history.go internal/app/order_history_test.go internal/app/session_history.go internal/app/session_history_test.go internal/app/enum_labels.go internal/walletagg/totalvalue.go internal/walletagg/totalvalue_test.go
git commit -m "feat(api): expose canonical spot routes and assets"
```

---

### Task 13: Expose honest Spot venue, Session, debug, order, and stop UI

**Files:**
- Modify: `gateway/quant-frontend/src/api/client.ts`
- Modify: `gateway/quant-frontend/src/components/SymbolPicker.tsx`
- Modify: `gateway/quant-frontend/src/components/StopSessionDialog.tsx`
- Modify: `gateway/quant-frontend/src/pages/VenueManagement.tsx`
- Modify: `gateway/quant-frontend/src/pages/PortfolioDetail.tsx`
- Modify: `gateway/quant-frontend/src/pages/SessionDetailPage.tsx`
- Create: `gateway/quant-frontend/scripts/spot-wallet-assets.test.mjs`
- Create: `gateway/quant-frontend/scripts/spot-live-guard.test.mjs`
- Create: `gateway/quant-frontend/scripts/spot-stop-dialog.test.mjs`
- Create: `gateway/quant-frontend/scripts/spot-debug-package.test.mjs`
- Create: `gateway/quant-frontend/scripts/spot-mixed-route.test.mjs`
- Create: `gateway/quant-frontend/scripts/spot-order-decimals.test.mjs`

**Interfaces:**
- `SpotAsset` uses `{asset, free, locked, avg_entry_price?, price?}` strings. `SpotSymbolMetadata` exposes symbol/base/quote/status/order types/filters. UI never models `BTCUSDT` as an asset.
- Spot Backtest venue editor always starts with an editable USDT asset row. Selecting a USDT symbol adds its metadata `base_asset`; it cannot add the symbol text or create duplicate assets.
- Portfolio run and local-debug package controls derive routes from the selected active strategy. Spot and Futures can appear together; market labels and route keys remain distinct.
- Live Spot start controls are disabled with visible rollout text, but display/read-only venue data remains visible.
- UI loads `/api/capabilities` and derives Backtest run, Demo run, offline package, and Live visibility from the exact effective flags. Missing/failed discovery renders every Spot action disabled; it never assumes support from a Venue's existence. Read-only history remains visible while a running disabled Session exposes only stop/drain actions. Futures controls ignore Spot flags.
- Stop dialog presents two explicit actions. For Spot stop-and-close it lists declared target symbols and warns that all current `free` corresponding base-asset holdings at that venue, including pre-existing/manual holdings, will be sold; it also explains that any open order, locked amount, or unavoidable dust aborts the entire batch before orders.
- Session detail groups wallet/order/fill/error rows by venue/exchange/market and shows filter/error code, environment, source, retryable classification, and fee asset. Order and fill cells render the exact decimal strings from the API; TypeScript types retain them as strings and never coerce them with `Number`, `parseFloat`, or arithmetic.

- [ ] **Step 1: Add RED source-contract tests for asset and route boundaries**

```javascript
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'

const venueSource = readFileSync('src/pages/VenueManagement.tsx', 'utf8')
assert.match(venueSource, /base_asset/)
assert.match(venueSource, /asset:\s*['"]USDT['"]/)
assert.doesNotMatch(venueSource, /selectedSymbol\s*\.\s*replace\([^)]*USDT/)
assert.doesNotMatch(venueSource, /asset:\s*selectedSymbol/)

const portfolioSource = readFileSync('src/pages/PortfolioDetail.tsx', 'utf8')
assert.match(portfolioSource, /SPOT_LIVE_ROLLOUT_GUARD/)
assert.match(portfolioSource, /environment\s*===\s*2/)
```

The live/capability test must cover all-four false, each independently true, discovery failure, disabled running-Session drain controls, Live configured-but-ineffective, and Futures unaffected. The stop test must assert both action constants, declared target rendering, the pre-existing holding warning, and fail-closed copy. The debug test must reject a hardcoded `perpetual_futures` request. The mixed-route test must assert route keys include market and interval where streams are keyed. The order-decimal test feeds values beyond binary-float precision and asserts the exact requested/executed/quote/fee strings, fee asset, environment, source, and retryable value remain in rendered output with no numeric coercion.

Run:

```bash
cd /Users/xdy/Workplace/hushine-worktrees/medium-cleanup/gateway/quant-frontend
for test_file in scripts/spot-wallet-assets.test.mjs scripts/spot-live-guard.test.mjs scripts/spot-stop-dialog.test.mjs scripts/spot-debug-package.test.mjs scripts/spot-mixed-route.test.mjs scripts/spot-order-decimals.test.mjs; do node "$test_file" || exit 1; done
```

Expected RED: files do not exist and current UI stores selected Spot symbols as pseudo assets, hardcodes Futures debug packages, and lacks the complete stop warning.

- [ ] **Step 2: Implement route-aware UI and structured error display**

Use metadata returned by the API for asset selection and display; no substring operations on symbols. Keep form decimals as strings. Disable submit when metadata is missing or stale, quote is not USDT, environment is Live, or the strategy route has no matching Venue. Render the server's structured code as the primary diagnostic and message as supporting text.

- [ ] **Step 3: Make Spot UI contracts and production build GREEN**

```bash
cd /Users/xdy/Workplace/hushine-worktrees/medium-cleanup/gateway/quant-frontend
for test_file in scripts/spot-wallet-assets.test.mjs scripts/spot-live-guard.test.mjs scripts/spot-stop-dialog.test.mjs scripts/spot-debug-package.test.mjs scripts/spot-mixed-route.test.mjs scripts/spot-order-decimals.test.mjs; do node "$test_file" || exit 1; done
npm run build
```

Expected GREEN: all six tracked contracts pass, TypeScript compiles, and Vite produces a production build without route/type casts that erase Spot. The final repository gate discovers every tracked `scripts/*.test.mjs`, so none of the six Spot contracts can be omitted by a hand-maintained count.

- [ ] **Step 4: Commit quant-frontend only**

```bash
cd /Users/xdy/Workplace/hushine-worktrees/medium-cleanup/gateway/quant-frontend
git add src/api/client.ts src/components/SymbolPicker.tsx src/components/StopSessionDialog.tsx src/pages/VenueManagement.tsx src/pages/PortfolioDetail.tsx src/pages/SessionDetailPage.tsx scripts/spot-wallet-assets.test.mjs scripts/spot-live-guard.test.mjs scripts/spot-stop-dialog.test.mjs scripts/spot-debug-package.test.mjs scripts/spot-mixed-route.test.mjs scripts/spot-order-decimals.test.mjs
git commit -m "feat(ui): expose guarded Binance spot workflows"
```

---
### Task 14: Package reusable Demo, Browser, coverage, compatibility, schema, and documentation gates

**Files:**
- Create: `hushine-deploy/scripts/smoke_spot_demo.sh`
- Create: `hushine-deploy/scripts/smoke_spot_demo.test.sh`
- Create: `hushine-deploy/scripts/verify_spot_usdt.sh`
- Create: `hushine-deploy/scripts/verify_spot_usdt.test.sh`
- Create: `hushine-deploy/scripts/acceptance/observe_spot_demo.py`
- Create: `hushine-deploy/scripts/acceptance/observe_spot_demo.test.sh`
- Create: `hushine-deploy/scripts/fixtures/spot_demo_fake_server.py`
- Create: `hushine-deploy/scripts/fixtures/spot_demo_evidence.schema.json`
- Create: `hushine-deploy/scripts/lib/runtime_coverage.sh`
- Modify: `hushine-deploy/scripts/smoke_hosted_runtime_coverage.sh`
- Modify: `hushine-deploy/scripts/smoke_hosted_runtime_coverage.test.sh`
- Regenerate: `hushine-deploy/db/generated/order.sql`
- Regenerate: `hushine-deploy/db/generated/portfolio.sql`
- Modify generated inventory: `hushine-deploy/db/generated/README.md`
- Modify: `hushine-deploy/db/README.md`
- Create: `hushine-deploy/docs/spot-usdt.md`
- Create: `hushine-deploy/docs/acceptance/2026-07-14-binance-spot-demo.md`
- Modify: `hushine-deploy/docs/runtime-operator-flow.md`
- Modify: `hushine-deploy/docs/strategy-debugger-cli-smoke.md`
- Modify: `hushine-deploy/docs/production-deploy-checklist.md`

**Interfaces:**
- `verify_spot_usdt.sh` accepts exactly one scope: `backtest`, `demo`, `offline`, `ui`, `filters`, `stop`, `futures`, `all-local`, or `release`. `all-local` always runs every non-Demo scope and never conditionally skips external work. `release` requires the absolute coverage directory plus run-owned Demo prerequisites, runs `all-local` then `demo`, and exits non-zero with a stable blocked reason when any prerequisite is absent. There is no ambiguous `all` scope. Every debugger invocation in `offline`, `all-local`, or `release` uses the local-library wrapper and final pin check.
- `smoke_spot_demo.sh` requires `USER_ID`, `PORTFOLIO_ID`, `SPOT_DEMO_RUN_ID`, `SPOT_DEMO_EVIDENCE_FILE`, an absolute coverage-output directory, and one already-created run-owned Demo `VENUE_ID`; it rejects every Binance key/secret environment variable. `SPOT_DEMO_EVIDENCE_FILE` is a credential-free, run-owned observation interface: an absolute, non-symlink, current-UID, mode-0600 JSON artifact under the coverage root, validated against `spot_demo_evidence.schema.json`. The full-system acceptance provisioning helper—not this smoke—owns authenticated encrypted Venue creation and ambiguous-response recovery.
- Spot Task 14 implements the observer at `hushine-deploy/scripts/acceptance/observe_spot_demo.py` with its executable fake-exchange contract at `observe_spot_demo.test.sh`. `docs/superpowers/plans/2026-07-14-full-system-real-page-acceptance.md` Task 3 owns the non-dispatchable `demo-exchange-observer-owner` that starts, waits, and stops this process; the Spot smoke never owns credentials. The observer accepts public `--run-id/--user-id/--portfolio-id/--venue-id/--coverage-root`, one inherited `--credential-fd`, and reads exactly one newline-delimited `{run_id,session_id}` handoff from stdin after the smoke creates the Session. It rejects a mismatched run, missing Session handoff, evidence path outside coverage root, symlink, or wrong ownership/mode.
- The observer receives Demo credentials only once over the inherited anonymous FD (never environment, argv, filesystem, logs, or output), reads and closes that FD before network I/O, and the parent closes/duplicates no further credential handle. It writes `<coverage-root>/exchange-evidence.json.tmp` with `O_EXCL` and mode 0600, then atomically publishes `<coverage-root>/exchange-evidence.json` only after `complete=true`; signal/normal cleanup removes the temporary file. Its redacted schema contains `schema_version`, exact `run_id/user_id/portfolio_id/venue_id/session_id`, capture timestamps, official subscription acknowledgement `{request_id,subscription_id,status}`, raw-string Binance orders `{symbol,side,type,status,orderId,clientOrderId,origQty,executedQty,cummulativeQuoteQty}`, trades `{symbol,orderId,id,qty,price,quoteQty,commission,commissionAsset,time}`, final account balances `{asset,free,locked}`, requested official endpoint paths/statuses, and a canonical-payload SHA-256. It contains no headers, signatures, API keys, secrets, URLs with queries, or credential-derived values.
- Immediately after creating the Session, `smoke_spot_demo.sh` writes exactly one `{run_id,session_id}` line to the inherited public control FD named by `SPOT_DEMO_OBSERVER_SESSION_FD`, closes that FD, and only then waits for exchange evidence. The FD number is not a credential; missing/broken handoff is a hard failure. `observe_spot_demo.test.sh` proves start-before-Session, one handoff, normal wait, signal cleanup, FD closure, and no output outside the supplied coverage root.
- The smoke proves core reached `/api/v3/account`, `/api/v3/exchangeInfo`, `/api/v3/myFilters`, reference/average price, and an acknowledged `userDataStream.subscribe.signature` WebSocket API subscription with no Spot listenKey request. It starts an instrumented Hosted Runtime, runs a deterministic two-symbol/two-interval strategy, and polls the run-owned evidence interface every 500 ms for at most 60 seconds. Hard pass requires schema/hash/ownership match, `complete=true`, at least one exact order and trade, exact route/order/trade identity, executed quantity, quote quantity, commission amount/asset, and trade ID equality against core orders/fills and worker wallet deltas, plus exact final account equality and a hard-pass repaired reconciliation snapshot. Timeout, missing raw exchange evidence, self-comparison of core projections, or any field mismatch fails. Assert undeclared assets and a pre-recorded Futures route snapshot are unchanged, then test stop-only/stop-and-close, offline package v2, and run-owned cleanup.
- The smoke inspects the Runtime container environment and fails if any Binance key/secret variable is present.
- The tracked acceptance document is a handoff/runbook, not execution evidence. The full-system acceptance gate writes real identifiers, redacted exchange results, Browser-skill screenshots/raw-CDP precise-coverage artifacts, and Runtime coverage outputs under `census-runs/spot-demo-20260714/`, which remains untracked.

- [ ] **Step 1: Write RED shell contracts before implementation**

`smoke_spot_demo.test.sh` must execute `scripts/fixtures/spot_demo_fake_server.py`, not only grep script text. The fake server implements official REST and WebSocket API envelopes, evolves account/order/trade state, records calls, emits a schema-valid credential-free evidence artifact with raw exchange strings, and injects subscription, timeout, 429, 5xx, schema, permission, ownership/hash, incomplete-evidence, and reconciliation failures; the shell test requires exact failure propagation. It also asserts strict mode, absence of `set -x`, mandatory
owned `VENUE_ID`, rejection of every key/secret input, Runtime environment
absence, Demo-only route validation, Venue-backed official endpoint proof,
metadata-derived quantities, BUY/SELL, two symbols/two intervals, same-symbol
Spot/Futures isolation, stop-only, stop-and-close, package-v2 offline replay,
field-by-field order/trade/fill/fee/account/wallet comparison, acknowledged Spot WebSocket API with no retired endpoint, bounded polling, reconciliation repair/hard-pass, Futures/undeclared-asset immutability, coverage finalization, run-ID ownership checks, and cleanup.

`verify_spot_usdt.test.sh` must assert the exact nine-scope allow-list and command mapping, prove `all-local` excludes Demo, prove `release` fails non-zero when Demo prerequisites are absent, require the local-library wrapper plus final pin check for every debugger subprocess, and reject `all` or any unknown scope before starting a subprocess.

Run:

```bash
cd /Users/xdy/Workplace/hushine-worktrees/medium-cleanup/hushine-deploy
bash scripts/smoke_spot_demo.test.sh
bash scripts/verify_spot_usdt.test.sh
bash scripts/acceptance/observe_spot_demo.test.sh
```

Expected RED: the verifier, smoke runner, Demo observer, evidence schema, and behavioral fake server do not exist, and each contract test reports the first missing required behavior.

- [ ] **Step 2: Implement the reusable gates and tracked handoff documentation**

Create the two new parent directories before adding files:

```bash
cd /Users/xdy/Workplace/hushine-worktrees/medium-cleanup
mkdir -p hushine-deploy/scripts/lib hushine-deploy/scripts/fixtures hushine-deploy/scripts/acceptance hushine-deploy/docs/acceptance
```

Extract the already-tested ownership checks, no-follow staging, locked coverage validation, merge/report, and finalization-marker functions from `scripts/smoke_hosted_runtime_coverage.sh` into `scripts/lib/runtime_coverage.sh`; make the existing hosted smoke and new Spot smoke both call that library. Preserve the existing hosted smoke's behavior and keep its contract tests green.

The scope runner maps exactly as follows:

| Scope | Exact implementation target |
|---|---|
| `backtest` | Core generator `-check` + core `TestSpotFilterContract`, then `strategy-service/tests/test_spot_filter_contract.py` and `test_spot_end_to_end.py`; this scope verifies core/Hosted fixture SHA, exact codes, and no-network behavior. |
| `demo` | `hushine-deploy/scripts/smoke_spot_demo.sh` |
| `offline` | Core generator `-check` for both offline fixture copies, `strategy-library/tests/hushine_strategy/test_spot_filter_contract.py`, then debugger `tests/test_spot_filter_contract.py`, `test_spot_package_v2.py`, and `test_mixed_route_package_v2.py` through the local-library wrapper; this scope verifies library/debugger SHA, exact codes, and no-network behavior. |
| `ui` | every `gateway/quant-frontend/scripts/spot-*.test.mjs` followed by `npm run build` |
| `filters` | The exact four-evaluator parity block below: core, Hosted Backtest, strategy-library, and debugger, including a single fixture SHA and no-network assertions. |
| `stop` | `core-service/internal/order/spotclose/planner_test.go`, `control-panel-service/internal/runtimechannel/platform_proxy_test.go`, and Spot stop cases in `strategy-service/tests/test_grpc_server.py` |
| `futures` | The exact repository/package/test commands below, covering shared boundaries changed by Tasks 3, 5, 6, 7, and 9. |
| `all-local` | `backtest`, `offline`, `ui`, `filters`, `stop`, and `futures`, always; never Demo |
| `release` | `all-local` followed by mandatory `demo`; absent Demo prerequisites are blocked/non-zero |

`verify_spot_usdt.test.sh` asserts these commands as exact ordered arrays, not descriptive labels. The `backtest` and `offline` arrays each execute their named half of the following parity block; `filters` executes the whole block, and `all-local` therefore cannot pass without both halves:

```bash
core_fixture=/Users/xdy/Workplace/hushine-worktrees/medium-cleanup/core-service/internal/order/risk/testdata/spot_filter_contract_v1.json
hosted_fixture=/Users/xdy/Workplace/hushine-worktrees/medium-cleanup/strategy-service/tests/fixtures/spot_filter_contract_v1.json
library_fixture=/Users/xdy/Workplace/hushine-worktrees/medium-cleanup/strategy-library/tests/fixtures/spot_filter_contract_v1.json
debugger_fixture=/Users/xdy/Workplace/hushine-worktrees/medium-cleanup/strategy-debugger-cli/tests/fixtures/spot_filter_contract_v1.json
golden_sha="$(shasum -a 256 "$core_fixture" | awk '{print $1}')"
for fixture in "$hosted_fixture" "$library_fixture" "$debugger_fixture"; do
  test "$golden_sha" = "$(shasum -a 256 "$fixture" | awk '{print $1}')"
done
cd /Users/xdy/Workplace/hushine-worktrees/medium-cleanup/core-service
go run ./cmd/generate-spot-filter-vectors -check "$core_fixture"
go test ./internal/order/risk -run '^TestSpotFilterContract$' -count=1
cd /Users/xdy/Workplace/hushine-worktrees/medium-cleanup/strategy-service
PYTHONPATH=.:../strategy-library uv run --frozen --extra dev pytest tests/test_spot_filter_contract.py tests/test_spot_end_to_end.py -q
cd /Users/xdy/Workplace/hushine-worktrees/medium-cleanup/strategy-library
uv run --isolated --no-project --with-editable '.[test]' pytest tests/hushine_strategy/test_spot_filter_contract.py tests/hushine_strategy/test_mixed_route_replay.py -q
cd /Users/xdy/Workplace/hushine-worktrees/medium-cleanup/strategy-debugger-cli
./scripts/with-local-strategy-library-git.sh ../strategy-library \
  uv run --frozen --extra test pytest tests/test_spot_filter_contract.py tests/test_spot_package_v2.py tests/test_mixed_route_package_v2.py -q
```

The `futures` array is exactly:

```bash
cd /Users/xdy/Workplace/hushine-worktrees/medium-cleanup/core-service
go test ./internal/exchange/binance -run '^(TestFuturesSymbolRuleContractUnchanged|TestFuturesExchangeInfoAndRiskControl|TestFuturesUserDataListenKeyUnchanged)$' -count=1
go test ./internal/order/service -run '^TestFuturesMarketLimitRiskLifecycleControlUnchanged$' -count=1
cd /Users/xdy/Workplace/hushine-worktrees/medium-cleanup/strategy-service
PYTHONPATH=.:../strategy-library uv run --frozen --extra dev pytest tests/test_wallet_runtime.py tests/test_grpc_server.py -q -k 'futures_control_unchanged or futures_stop_paths_unchanged'
cd /Users/xdy/Workplace/hushine-worktrees/medium-cleanup/control-panel-service
go test ./internal/runtimechannel -run '^TestFuturesRuntimeChannelOrderAndStopProxyUnchanged$' -count=1
```

Tasks 5, 7, and 9 must add/update the three exact named Futures controls referenced above in their already-listed shared test files. The verifier contract first lists/collects each exact name and fails if any selection is empty, then runs the commands; a zero-test Go or pytest selection is not a pass.

`docs/spot-usdt.md` must document:

- asset-versus-symbol terminology with `BTC`, `USDT`, and `BTCUSDT`;
- official account/rules endpoints and route-aware service ownership;
- five-minute immutable metadata snapshots and exact filter semantics;
- BUY/SELL/fill/commission/reconciliation lifecycle;
- stop-only and declared-target stop-and-close, including entire current `free` exposure and whole-batch failure for any open order or locked amount;
- Backtest, Demo, debugger, UI, multi-stream, mixed-route support, and Live fail-closed behavior;
- all four default-off capability gates, running-Session drain, independent rollback, Spot WebSocket API, unchanged Futures listenKey, and repair-source/recoverable reconciliation;
- the one-time encrypted Venue credential path and the prohibition on Runtime/worker credentials;
- operator diagnostics and evidence redaction.

Run `make db-schema-bundle` after Tasks 6 and 8. The generated order bundle must contain `0000`, byte-identical order `0001`, `0002_spot_order_route_identity.sql`, and `0003_spot_close_operations.sql`; the Portfolio/core bundle must contain byte-identical Portfolio `0001`, `0002_spot_risk_facts.sql`, and `0003_spot_reconciliation_repair.sql`. Each appears exactly once and in order. Record both source `0001` SHA-256 values before work; any change is a hard failure. A second generation must produce identical checksums. Update `db/README.md` with both additive migration orders, pre/post row-count and identity checks, rollback-by-disabling-Spot rule, and the prohibition on deleting order/fill/close-operation/wallet/snapshot/reconciliation history.

`docs/acceptance/2026-07-14-binance-spot-demo.md` must name the exact smoke/verify commands, untracked evidence root, nine Browser checks and same-tab precise-coverage procedure in Step 6, compatibility/rollback handoff, and four current Notion destinations from `AGENTS.md`. It only tells the full-system acceptance gate what to synchronize after real evidence passes; this Spot plan does not mutate Notion.

- [ ] **Step 3: Run repository-local ordinary regressions**

```bash
cd /Users/xdy/Workplace/hushine-worktrees/medium-cleanup/core-service
go test ./... && go vet ./...
cd /Users/xdy/Workplace/hushine-worktrees/medium-cleanup/control-panel-service
go test ./... && go vet ./...
cd /Users/xdy/Workplace/hushine-worktrees/medium-cleanup/strategy-service
PYTHONPATH=.:../strategy-library uv run --frozen --extra dev pytest tests/ -q
go test ./... && go vet ./...
make test
cd /Users/xdy/Workplace/hushine-worktrees/medium-cleanup/strategy-library
uv run --isolated --no-project --with-editable '.[test]' pytest tests/ -q
cd /Users/xdy/Workplace/hushine-worktrees/medium-cleanup/strategy-debugger-cli
./scripts/with-local-strategy-library-git.sh ../strategy-library \
  uv run --frozen --extra test pytest tests/ -q
cd /Users/xdy/Workplace/hushine-worktrees/medium-cleanup/gateway/quant-handler
go test ./... && go vet ./...
cd /Users/xdy/Workplace/hushine-worktrees/medium-cleanup/gateway/quant-frontend
npm run build
bash -euo pipefail -c '
  tests="$(git ls-files "scripts/*.test.mjs" | LC_ALL=C sort)"
  test -n "$tests"
  while IFS= read -r test_file; do node "$test_file"; done <<<"$tests"
'
cd /Users/xdy/Workplace/hushine-worktrees/medium-cleanup/scraper
go test ./... && go vet ./...
cd /Users/xdy/Workplace/hushine-worktrees/medium-cleanup/golang-lib
go test ./... && go vet ./...
cd log-shipper
go test ./... && go vet ./...
cd ../elk/kafka-es-bridge
go test ./... && go vet ./...
cd ../../py_log
test ! -e uv.lock
uv run --isolated --no-project --with-editable '.[dev]' pytest -q
test ! -e uv.lock
cd /Users/xdy/Workplace/hushine-worktrees/medium-cleanup
set +e
openspec_output="$(openspec validate --all --strict --no-interactive 2>&1)"
openspec_status=$?
set -e
printf '%s\n' "$openspec_output"
if [ "$openspec_status" -ne 0 ]; then exit "$openspec_status"; fi
if grep -Fq 'No items found to validate' <<<"$openspec_output"; then exit 1; fi
```

Expected GREEN: all commands exit 0 across the complete eight-module Go matrix, every managed Python suite, frontend, and strict OpenSpec validation; Spot additions do not regress Futures, notifications, RuntimeChannel, custom indicators, worker restart, or Backtest liquidation. Root orchestration and shared-database bootstrap remain owned by the full-system acceptance plan's isolated source-root/database repair.

- [ ] **Step 4: Run focused official-shape, mixed-route, and scope gates**

```bash
cd /Users/xdy/Workplace/hushine-worktrees/medium-cleanup/core-service
go test ./internal/exchange/binance/... ./internal/order/... ./internal/reconciliation -count=1
test -n "$HUSHINE_TEST_PG_ADMIN_DSN"
CORE_SPOT_BASE_SHA=1b92b40c8337bd8a2c31871ef488b344e5d518a6 \
PORTFOLIO_0001_BASE_SHA256=5b2bf5a34e9a65e7f2c6fca69a71553dac4c1b00f8b720e5cde3f71eaec5cafe \
ORDER_0001_BASE_SHA256=6e2d179b9ecf706de8461ca6443efacfd22cb084ef6b49a0e2c94f2e49881b60 \
HUSHINE_TEST_PG_ADMIN_DSN="$HUSHINE_TEST_PG_ADMIN_DSN" \
  go test -tags=integration ./internal/storage/migrations ./internal/repository ./internal/order/storage/migrations ./internal/order/spotclose ./internal/order/repository ./cmd/ensure-order-db \
  -run 'TestSpotRiskFactsMigrationFreshBootstrap|TestSpotRiskFactsMigrationPopulatedUpgrade|TestSpotReconciliationRepairMigrationFreshBootstrap|TestSpotReconciliationRepairMigrationPopulatedUpgrade|TestApplySpotRepair|TestSpotOrderRouteIdentityMigration|TestSpotCloseOperationsMigration|TestSpotCloseOperationPersistence|TestOrderRepositoryExactSpotRoundTrip|TestEnsureOrderMigrationAtomic' -count=1 -v
cd /Users/xdy/Workplace/hushine-worktrees/medium-cleanup/strategy-service
PYTHONPATH=.:../strategy-library uv run --frozen --extra dev pytest tests/test_spot_end_to_end.py tests/test_strategy_engine.py tests/test_grpc_server.py tests/test_portfolio_wallet_runtime.py -q
cd /Users/xdy/Workplace/hushine-worktrees/medium-cleanup/hushine-deploy
bash scripts/smoke_hosted_runtime_coverage.test.sh
bash scripts/smoke_spot_demo.test.sh
bash scripts/verify_spot_usdt.test.sh
bash scripts/acceptance/observe_spot_demo.test.sh
./scripts/verify_spot_usdt.sh backtest
./scripts/verify_spot_usdt.sh offline
./scripts/verify_spot_usdt.sh ui
./scripts/verify_spot_usdt.sh filters
./scripts/verify_spot_usdt.sh stop
./scripts/verify_spot_usdt.sh futures
./scripts/verify_spot_usdt.sh all-local
make db-schema-bundle
order_0001=../core-service/internal/order/storage/migrations/0001_current_schema_baseline.sql
portfolio_0001=../core-service/internal/storage/migrations/0001_current_schema_baseline.sql
CORE_SPOT_BASE_SHA=1b92b40c8337bd8a2c31871ef488b344e5d518a6
PORTFOLIO_0001_BASE_SHA256=5b2bf5a34e9a65e7f2c6fca69a71553dac4c1b00f8b720e5cde3f71eaec5cafe
ORDER_0001_BASE_SHA256=6e2d179b9ecf706de8461ca6443efacfd22cb084ef6b49a0e2c94f2e49881b60
test "${#CORE_SPOT_BASE_SHA}" -eq 40
git -C ../core-service cat-file -e "$CORE_SPOT_BASE_SHA^{commit}"
test "$ORDER_0001_BASE_SHA256" = "$(git -C ../core-service show "$CORE_SPOT_BASE_SHA:internal/order/storage/migrations/0001_current_schema_baseline.sql" | shasum -a 256 | awk '{print $1}')"
test "$PORTFOLIO_0001_BASE_SHA256" = "$(git -C ../core-service show "$CORE_SPOT_BASE_SHA:internal/storage/migrations/0001_current_schema_baseline.sql" | shasum -a 256 | awk '{print $1}')"
test "$ORDER_0001_BASE_SHA256" = "$(shasum -a 256 "$order_0001" | awk '{print $1}')"
test "$PORTFOLIO_0001_BASE_SHA256" = "$(shasum -a 256 "$portfolio_0001" | awk '{print $1}')"
assert_bundle_sources() {
  bundle="$1"; shift
  previous=0
  for source in "$@"; do
    test "$(grep -Fc -- "-- Source: $source" "$bundle")" -eq 1
    line="$(grep -nF -- "-- Source: $source" "$bundle" | cut -d: -f1)"
    test "$line" -gt "$previous"
    previous="$line"
  done
}
assert_bundle_sources db/generated/order.sql \
  core-service/internal/order/storage/migrations/0000_create_schema_migrations.sql \
  core-service/internal/order/storage/migrations/0001_current_schema_baseline.sql \
  core-service/internal/order/storage/migrations/0002_spot_order_route_identity.sql \
  core-service/internal/order/storage/migrations/0003_spot_close_operations.sql
assert_bundle_sources db/generated/portfolio.sql \
  core-service/internal/storage/migrations/0000_create_schema_migrations.sql \
  core-service/internal/storage/migrations/0001_current_schema_baseline.sql \
  core-service/internal/storage/migrations/0002_spot_risk_facts.sql \
  core-service/internal/storage/migrations/0003_spot_reconciliation_repair.sql
bundle_before="$(shasum -a 256 db/generated/order.sql db/generated/portfolio.sql db/generated/README.md)"
make db-schema-bundle
test "$bundle_before" = "$(shasum -a 256 db/generated/order.sql db/generated/portfolio.sql db/generated/README.md)"
```

From the workspace root, also run the dependency-contract installed/frozen gate completed by the prerequisite dependency plan, while retaining the AGENTS-mandated source-shadowing suite above:

```bash
make -C strategy-service dependency-contract
test "${#RUNTIME_DEPENDENCY_BASE_SHA}" -eq 40
git -C strategy-library cat-file -e "$RUNTIME_DEPENDENCY_BASE_SHA^{commit}"
make -f hushine-deploy/Makefile runtime-dependency-acceptance \
  RUNTIME_DEPENDENCY_BASE_SHA="$RUNTIME_DEPENDENCY_BASE_SHA"
if rg -n '(^|[[:space:]])PYTHONPATH=' \
  hushine-deploy/scripts/smoke_spot_demo.sh \
  strategy-service/scripts/build_strategy_runtime.sh \
  strategy-service/scripts/verify_runtime_image.sh \
  strategy-service/scripts/smoke_strategy_runtime.sh; then
  echo 'production acceptance must use the frozen installed environment, not PYTHONPATH shadowing' >&2
  exit 1
fi
```

Expected GREEN: official-shape fixtures pass without `/api/v3/portfolio`, same-symbol Spot/Futures and multi-stream scenarios stay isolated, every secret-free scope passes, the existing hosted coverage contract remains unchanged, and both final Runtime images prove installed dependency closure without source-path shadowing. `PYTHONPATH=.:../strategy-library` remains required only for the repository suite mandated by `AGENTS.md`; it is not image or production acceptance evidence.

- [ ] **Step 5: Build and inspect the instrumented Runtime image**

```bash
cd /Users/xdy/Workplace/hushine-worktrees/medium-cleanup
./strategy-service/scripts/build_strategy_runtime.sh \
  --coverage --no-cache --verify spot-acceptance
docker image inspect hushine/strategy-runtime:executor-coverage-spot-acceptance
```

Expected GREEN: the image builds from the current strategy-service/strategy-library sources, contains both Go and Python coverage tooling, and is tagged `hushine/strategy-runtime:executor-coverage-spot-acceptance`. Do not inject Demo credentials or run the external Demo here.

- [ ] **Step 6: Publish the exact full-system Browser-skill and same-tab precise-coverage handoff**

The separate full-system acceptance plan invokes the real Demo scope and stores all outputs outside Git:

```bash
cd /Users/xdy/Workplace/hushine-worktrees/medium-cleanup
coverage_root="$PWD/census-runs/spot-demo-20260714/coverage/runtime-agent"
evidence_file="$coverage_root/exchange-evidence.json"
install -d -m 0700 "$coverage_root"
credential_fd="${BINANCE_SPOT_DEMO_CREDENTIAL_FD:?acceptance harness must provide inherited credential FD}"
case "$credential_fd" in (*[!0-9]*|'') exit 1;; esac
test -r "/dev/fd/$credential_fd"
coproc SPOT_OBSERVER {
  python3 hushine-deploy/scripts/acceptance/observe_spot_demo.py \
    --run-id spot-demo-20260714 \
    --user-id "$USER_ID" --portfolio-id "$PORTFOLIO_ID" --venue-id "$VENUE_ID" \
    --coverage-root "$coverage_root" --credential-fd 3 \
    3<&$credential_fd >"$coverage_root/observer.log" 2>&1
}
observer_pid="$SPOT_OBSERVER_PID"
exec {credential_fd}<&-
exec 8>&"${SPOT_OBSERVER[1]}"
observer_pipe_fd="${SPOT_OBSERVER[1]}"
exec {observer_pipe_fd}>&-
cleanup_observer() {
  exec 8>&- 2>/dev/null || true
  kill "$observer_pid" 2>/dev/null || true
  wait "$observer_pid" 2>/dev/null || true
  rm -f "$coverage_root/exchange-evidence.json.tmp"
}
trap cleanup_observer EXIT INT TERM
USER_ID="$USER_ID" \
PORTFOLIO_ID="$PORTFOLIO_ID" \
VENUE_ID="$VENUE_ID" \
SPOT_DEMO_RUN_ID=spot-demo-20260714 \
SPOT_DEMO_EVIDENCE_FILE="$evidence_file" \
SPOT_DEMO_OBSERVER_SESSION_FD=8 \
COVERAGE_IMAGE=hushine/strategy-runtime:executor-coverage-spot-acceptance \
./hushine-deploy/scripts/verify_spot_usdt.sh release \
  "$coverage_root" 8>&8
exec 8>&-
set +e
wait "$observer_pid"
observer_status=$?
set -e
trap - EXIT INT TERM
test "$observer_status" -eq 0
test -f "$evidence_file"
test ! -e "$coverage_root/exchange-evidence.json.tmp"
```

After that command succeeds, the full-system acceptance plan—not this Spot plan—uses the installed Browser skill. It initializes the runtime from the skill's absolute `<browser-plugin-root>/scripts/browser-client.mjs`, selects the product URL with `agent.browsers.getForUrl`, reads the selected browser documentation, and obtains one fresh product tab. It performs all nine checks below in that same tab using Browser locators/screenshots; no separate browser-control surface is part of this handoff.

The full-system plan's non-dispatchable `browser-coverage-owner` is the only
Profiler/Network owner. It retains one agent, persistent Node kernel, Browser
binding, browser ID, opaque tab ID, random nonce, and the one documented
`await tab.capabilities.get("cdp")` capability from owner-start through
finalization. It starts on the inert same-origin coverage page before
application navigation, drains cursor-based network events after every action,
and writes an `O_EXCL` owner-start artifact referenced by every browser
envelope. Exercise all nine flows without replacing that owner/tab/origin; in
`finally`, the same capability takes/stops precise coverage and disables
Network/Profiler. The full-system `frontend_coverage` stage may only normalize
the owner-written raw result. A second owner, copied tab ID, generic CDP client,
or Profiler start after application actions does not satisfy the gate.

1. Venue Management shows asset rows `USDT`, `BTC`, and other real assets, with no `BTCUSDT` asset.
2. A Spot-only two-input/two-interval strategy starts and shows separate chart streams and custom indicators.
3. Spot and Futures `BTCUSDT` in one strategy remain separate routes, wallets, orders, and streams.
4. Order History shows actual executed/cumulative quantities and commission asset.
5. Stop-only changes Session state without creating an order.
6. Stop-and-close shows the approved warning, targets declared symbols only, and reaches stopped only after the authoritative response.
7. Invalid tick/step/notional input shows the exact structured filter code.
8. Live Spot is disabled in UI and a direct HTTP replay still returns `SPOT_LIVE_ROLLOUT_GUARD`.
9. Package-v2 download/import/replay succeeds with debugger networking disabled.

All Browser screenshots, same-tab raw-CDP precise-coverage data, product IDs, Runtime coverage outputs, and redacted API records go under `census-runs/spot-demo-20260714/`. Nothing from that evidence root is staged by this plan.

- [ ] **Step 7: Verify local rolling compatibility and document deployment/rollback order**

Run the old-reader/new-writer and new-reader/legacy-snapshot fixtures introduced in Tasks 1 and 7. Assert existing Futures Sessions remain readable and that new Spot admission can be disabled independently.

Document this full-system deployment handoff: core-service, control-panel-service, instrumented strategy Runtime image, quant-handler, then quant-frontend. Document rollback in reverse UI-to-core order, but retain additive protobuf fields and canonical JSON history; rollback disables new Spot admission rather than deleting order/fill/wallet/snapshot records. Actual deployment and rollback rehearsal belong to full-system acceptance.

- [ ] **Step 8: Commit hushine-deploy gates and docs only**

```bash
cd /Users/xdy/Workplace/hushine-worktrees/medium-cleanup/hushine-deploy
git add scripts/verify_spot_usdt.sh scripts/verify_spot_usdt.test.sh scripts/smoke_spot_demo.sh scripts/smoke_spot_demo.test.sh scripts/acceptance/observe_spot_demo.py scripts/acceptance/observe_spot_demo.test.sh scripts/fixtures/spot_demo_fake_server.py scripts/fixtures/spot_demo_evidence.schema.json scripts/lib/runtime_coverage.sh scripts/smoke_hosted_runtime_coverage.sh scripts/smoke_hosted_runtime_coverage.test.sh db/generated/order.sql db/generated/portfolio.sql db/generated/README.md db/README.md docs/spot-usdt.md docs/acceptance/2026-07-14-binance-spot-demo.md docs/runtime-operator-flow.md docs/strategy-debugger-cli-smoke.md docs/production-deploy-checklist.md
for path in db/generated/order.sql db/generated/portfolio.sql db/generated/README.md; do
  test -e "$path"
  git diff --cached --name-only | grep -Fx "$path"
done
git diff --cached --check
git commit -m "test(spot): add reusable demo gates and docs"
test -z "$(git status --short -- db/generated/order.sql db/generated/portfolio.sql db/generated/README.md)"
```

Expected: only reusable scripts, regenerated schema, and tracked documentation are committed in hushine-deploy. This task does not push repositories, stage `census-runs`, update Notion, or commit Browser evidence; the full-system acceptance gate owns those actions after all product evidence passes.

---

## Completion Gate

### Implementation complete

The code implementation may be reported complete only when all of the following are true. This state must never be described as “Spot 可用” or “release accepted”:

- Official `/api/v3/account`, `/api/v3/exchangeInfo`, and signed Spot WebSocket API contract tests pass; no production or mock Spot flow uses `/api/v3/portfolio`, `/api/v3/userDataStream`, or `/fapi/*`, while focused Futures controls prove `/fapi/v1/listenKey` remains unchanged.
- Canonical wallets contain asset codes only and retain exact free/locked values; `BTCUSDT` never appears as an asset.
- Exact request/order/fill decimals survive protocol, `numeric(38,18)`/asset-precision admission, persistence, handler JSON, and UI rendering; conflict/out-of-range cases fail before side effects with environment/retryable/source intact.
- Acceptance-owned fresh/upgrade order databases prove `0002`/`0003`, atomic migration ledgers, route-qualified identities, durable close operations, and regenerated `order.sql` without losing history.
- One machine-generated golden vector set passes in core, Hosted Backtest, strategy-library, and offline debugger with zero network access; MARKET/LIMIT, balance, tick/step/notional/percent/MAX_POSITION/MAX_ASSET/unknown filters match exactly.
- BUY/SELL fills, route/trade-qualified fee idempotency, lifecycle, authoritative repair/snapshot/recoverable reconciliation, and approved stop/lease-release matrices pass; accepted-timeout/restart/lease-expiry races issue at most one SELL and block unrelated orders until authoritative recovery.
- Hosted Backtest, offline debugger, all six UI contracts, multi-symbol, multi-interval, mixed Spot/Futures, and the focused Futures matrix pass.
- All four capabilities default/effective false; each can be disabled independently; running Sessions drain safely; Live Spot remains fail-closed at core, handler, and UI boundaries even when configured true.
- The coverage image, nine-scope verifier with unambiguous `all-local`/`release`, behavior-driven official-shape smoke, tracked handoff/runbook, rolling compatibility tests, and rollback instructions are ready for full-system acceptance.
- No Runtime/worker receives exchange credentials, no shared database bootstrap is run by this focused plan, no `census-runs` evidence is committed, and no unrelated dirty file is staged.

### Release acceptance complete

“Spot 可用” may be reported only after the separate full-system gate additionally completes real Demo execution with field-by-field Binance/core/worker/account reconciliation, same-tab Browser raw-CDP evidence, shared-infrastructure/fresh-bootstrap validation, Notion synchronization, remote pushes, and the approved flag enable sequence. Until then, release acceptance is explicitly incomplete even when every implementation item above is green.
