# Strategy Multi-Venue Runtime Phase 3 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Hard-cut the strategy runtime to a multi-venue portfolio model where strategies declare explicit data inputs and order targets, read wallets through `wallet.get(exchange, market)`, place venue-routed ordinary orders, and write portfolio snapshots through the portfolio API.

**Architecture:** `strategy-library` defines the public strategy API constants and data/order types. `strategy-service` parses declarations, builds `PortfolioWalletRuntime` from `core-service.GetPortfolioSnapshot`, validates ordinary orders against `ORDER_TARGETS`, processes each decision independently, and writes runtime state with `UpdatePortfolioSnapshot`. `core-service` remains the authority for account/venue resolution, preflight persistence, symbol filters, execution constraints, lifecycle events, and session audit records.

**Tech Stack:** Python strategy runtime and tests, Go gRPC/proto services, TimescaleDB migrations, React/Vite frontend, debugger CLI templates, existing Browser smoke path.

---

## Scope Check

This plan intentionally spans multiple repositories because Phase 3 is a vertical slice across strategy API, strategy runtime, core-service preflight/snapshot contracts, gateway mapping, frontend visibility, and debugger templates.

This plan does not implement OKX execution, cross-exchange atomic arbitrage, canonical symbol mapping, or same-account duplicate active venues for one `(exchange, market)`.

Execution order is strict:

1. Phase 2 residual audit and baseline.
2. Public strategy API hard cut.
3. Declaration parsing and required target extraction.
4. Portfolio wallet runtime and snapshot adapter.
5. Runtime order processing and lifecycle isolation.
6. Core-service preflight/session/snapshot hardening.
7. Gateway/frontend/debugger templates.
8. Full verification and browser smoke.

## Phase 2 Residual Audit

The current code still contains Phase 2 / pre-Phase-3 leftovers that must be removed from the normal strategy path:

1. `strategy-service/strategy_service/account_client.py` and `strategy-service/strategy_service/platform_proxy.py` still expose `GetOnlineAccountInfo` / `UpdateAccountWalletState`.
2. `strategy-service/strategy_service/strategy/base.py` still has `VenueWalletView`, which wraps one default wallet.
3. `strategy-service/strategy_service/strategy/base.py` still derives the order universe from `INPUTS`.
4. `strategy-library/hushine_strategy/inputs.py` still aliases `futures` to `perpetual_futures` and exposes `data.market[...]`.
5. `strategy-library/hushine_strategy/types.py` still uses `qty: float`, `price: float | None`, and default `MarketData.market = "futures"`.
6. `strategy-debugger-cli/README.md`, `strategy-debugger-cli/src/hushine_debugger/templates/strategy.py.template`, and debugger CLI tests still use `market="futures"` and `data.market[...]`.
7. `strategy-service/strategy_templates/eth_pyramid_futures.py` and seed scripts still use old strategy API examples.
8. `gateway/quant-handler/README.md` still documents `mode`, `GetOnlineAccountInfo`, and `UpdateAccountWalletState`.
9. `gateway/quant-frontend/src/pages/AccountDetail.tsx` still sends legacy `market: "futures"` in at least one path and carries many mode-based run labels.

Generated code and old historical docs may still contain strings like `mode=0` or `futures`; normal Phase 3 runtime code, templates, tests, and user-facing docs must not rely on them.

## File Structure

### strategy-library

- Modify: `strategy-library/hushine_strategy/types.py`
- Modify: `strategy-library/hushine_strategy/inputs.py`
- Modify: `strategy-library/tests/hushine_strategy/test_types_inputs.py`

Responsibilities:

- Define strategy-facing constants.
- Hard-cut `OrderDecision` field types.
- Parse `INPUTS` and `ORDER_TARGETS`.
- Remove default Binance market accessor.

### strategy-service

- Modify: `strategy-service/strategy_service/types.py`
- Modify: `strategy-service/strategy_service/inputs.py`
- Modify: `strategy-service/strategy_service/strategy/base.py`
- Modify: `strategy-service/strategy_service/account_client.py`
- Modify: `strategy-service/strategy_service/platform_proxy.py`
- Modify: `strategy-service/strategy_service/grpc_server.py`
- Modify: `strategy-service/strategy_service/data_loop.py`
- Modify: `strategy-service/strategy_service/order_client.py`
- Create: `strategy-service/strategy_service/wallet/portfolio.py`
- Create: `strategy-service/strategy_service/wallet/portfolio_adapter.py`
- Modify: `strategy-service/strategy_service/wallet/__init__.py`
- Modify: `strategy-service/strategy_service/debug_replay.py`
- Modify: `strategy-service/strategy_service/debug_workspace.py`
- Modify: `strategy-service/strategy_service/cli/hushine_debug.py`
- Modify: `strategy-service/strategy_templates/eth_pyramid_futures.py`
- Modify tests under `strategy-service/tests/`.

Responsibilities:

- Expose strategy constants through `strategy_service.types`.
- Parse strategy declarations into inputs, order targets, required venues, and required symbols.
- Build `PortfolioWalletRuntime` from `PortfolioSnapshot.VenueSnapshots`.
- Switch normal strategy state read/write to portfolio snapshot APIs.
- Process multi-order returns.
- Apply lifecycle fills to the correct venue wallet.

### core-service

- Modify: `core-service/proto/account_service.proto`
- Regenerate: `core-service/gen/accountv1/*`
- Modify: `core-service/internal/service/grpc.go`
- Modify: `core-service/internal/repository/repository.go`
- Modify: `core-service/internal/repository/timescale.go`
- Create migration if needed: `core-service/internal/storage/migrations/0023_strategy_session_preflight_errors.sql`
- Modify tests under `core-service/internal/service/`, `core-service/internal/repository/`, and `core-service/tests/`.

Responsibilities:

- Accept symbol-aware preflight requirements.
- Persist `preflight_failed` sessions with structured error fields.
- Ensure `UpdatePortfolioSnapshot` is the normal strategy write path.
- Keep `session_venues` as factual account-bound venue snapshots.

### gateway/quant-handler

- Regenerate core-service proto bindings if local generated files exist.
- Modify: `gateway/quant-handler/internal/app/strategy.go`
- Modify: `gateway/quant-handler/internal/app/accounts_ext.go`
- Modify: `gateway/quant-handler/internal/app/session_history.go`
- Modify: `gateway/quant-handler/internal/app/debug_package.go`
- Modify tests under `gateway/quant-handler/internal/app/`.

Responsibilities:

- Surface parsed strategy declarations.
- Map preflight failures and `preflight_failed` sessions.
- Generate Phase 3 debugger package templates.
- Remove old account wallet API assumptions from normal run flow.

### gateway/quant-frontend

- Modify: `gateway/quant-frontend/src/api/client.ts`
- Modify: `gateway/quant-frontend/src/pages/AccountDetail.tsx`
- Modify: `gateway/quant-frontend/src/pages/StrategyManagement.tsx`
- Modify: `gateway/quant-frontend/src/pages/SessionDetailPage.tsx`
- Modify: `gateway/quant-frontend/src/pages/OrderHistory.tsx`
- Modify components used by runtime selection and strategy run dialogs.

Responsibilities:

- Show strategy `INPUTS` and `ORDER_TARGETS`.
- Show preflight missing venues/symbols.
- Avoid legacy `market: "futures"` payloads.
- Keep route facts visible in Session Detail and Order History.

### strategy-debugger-cli

- Modify: `strategy-debugger-cli/src/hushine_debugger/templates/strategy.py.template`
- Modify: `strategy-debugger-cli/src/hushine_debugger/config.py`
- Modify: `strategy-debugger-cli/src/hushine_debugger/demo_data.py`
- Modify: `strategy-debugger-cli/src/hushine_debugger/import_package.py`
- Modify: `strategy-debugger-cli/src/hushine_debugger/replay.py`
- Modify: `strategy-debugger-cli/README.md`
- Modify tests under `strategy-debugger-cli/tests/`.

Responsibilities:

- Generate Phase 3 strategy template.
- Use `perpetual_futures` instead of `futures`.
- Use explicit `data.exchange[...]`.
- Keep local replay aligned with strategy-service runtime API.

## Task 0: Baseline and Phase 2 Residual Gate

**Files:**
- Inspect: all affected repositories.
- No source changes in this task.

- [ ] **Step 1: Check repository cleanliness**

Run:

```bash
for d in core-service strategy-library strategy-service gateway/quant-handler gateway/quant-frontend strategy-debugger-cli hushine-deploy; do
  echo "## $d"
  git -C "$d" status --short --branch
done
```

Expected:

- No uncommitted code changes except docs/plans that are being intentionally written.
- If a repo is dirty, inspect before editing and do not overwrite user work.

- [ ] **Step 2: Run current baseline tests**

Run:

```bash
cd strategy-library && pytest -q tests/
cd ../strategy-service && PYTHONPATH=.:../strategy-library pytest -q tests/
cd ../core-service && go test ./...
cd ../gateway/quant-handler && go test ./...
cd ../gateway/quant-frontend && npm run build
cd ../../strategy-debugger-cli && pytest -q
```

Expected:

- Baseline failures, if any, are recorded before Phase 3 changes.
- Do not start implementation while unrelated baseline failures are unexplained.

- [ ] **Step 3: Capture residual scan before changes**

Run:

```bash
rg -n 'GetOnlineAccountInfo|UpdateAccountWalletState|ACCOUNT_GET_ONLINE|ACCOUNT_UPDATE_WALLET|VenueWalletView|data\\.market\\[|self\\.market = _MarketNode|market="futures"|market='"'"'futures'"'"'|MarketData\\(.+market="futures"|wallet\\.futures|wallet\\.spot|get_wallet_balance\\(|get_available_balance\\(' \
  strategy-service strategy-library gateway/quant-handler gateway/quant-frontend strategy-debugger-cli \
  -g '!**/.git/**'
```

Expected:

- The output is used as the cleanup checklist.
- After Phase 3 implementation, normal runtime code, templates, and tests should no longer contain these patterns except explicit negative tests and historical docs.

- [ ] **Step 4: Commit baseline note if needed**

If baseline failures are recorded in this plan, commit the plan update in `hushine-deploy` after copying the plan there:

```bash
mkdir -p hushine-deploy/docs/superpowers/plans
cp docs/superpowers/plans/2026-05-30-strategy-multi-venue-runtime-phase-3.md \
  hushine-deploy/docs/superpowers/plans/2026-05-30-strategy-multi-venue-runtime-phase-3.md
git -C hushine-deploy add docs/superpowers/plans/2026-05-30-strategy-multi-venue-runtime-phase-3.md
git -C hushine-deploy commit -m "docs: record phase 3 baseline"
```

Expected:

- Baseline state is auditable.

**Baseline Result (2026-05-30):**

- Repository cleanliness: all affected repositories were clean before Phase 3 code changes. `hushine-deploy` was clean and `main` was ahead of `origin/main` by existing documentation commits.
- Passed:
  - `strategy-library`: `pytest -q tests/` — `69 passed`
  - `strategy-service`: `PYTHONPATH=.:../strategy-library pytest -q tests/` — `349 passed`
  - `core-service`: `go test ./...`
  - `gateway/quant-handler`: `go test ./...`
  - `gateway/quant-frontend`: `npm run build`
- Failed baseline:
  - `strategy-debugger-cli`: `pytest -q` failed during collection with `ModuleNotFoundError: No module named 'hushine_debugger'`.
  - This does not block Task 1 because Task 1 only modifies `strategy-library`.
  - This must be resolved before claiming full Phase 3 verification is green.
- Confirmed Phase 2 residuals:
  - legacy account wallet APIs: `GetOnlineAccountInfo`, `UpdateAccountWalletState`
  - single-wallet facade: `VenueWalletView`
  - old data API: `data.market[...]`, `_MarketNode`
  - old market literal: `market="futures"` / `market='futures'`
  - direct wallet shortcuts: `wallet.futures`, `wallet.spot`, `get_wallet_balance`, `get_available_balance`

## Task 1: Hard-Cut strategy-library Public API

**Files:**
- Modify: `strategy-library/hushine_strategy/types.py`
- Modify: `strategy-library/hushine_strategy/inputs.py`
- Modify: `strategy-library/tests/hushine_strategy/test_types_inputs.py`

- [ ] **Step 1: Write failing tests for constants and strict market parsing**

Add tests to `strategy-library/tests/hushine_strategy/test_types_inputs.py`:

```python
import pytest

from hushine_strategy.inputs import parse_declared_inputs, parse_order_targets
from hushine_strategy.types import Exchange, Market, OrderDecision, OrderSide, OrderType, PositionSide


def test_strategy_constants_are_string_values():
    assert Exchange.BINANCE == "binance"
    assert Market.PERPETUAL_FUTURES == "perpetual_futures"
    assert OrderSide.BUY == "BUY"
    assert OrderType.MARKET == "MARKET"
    assert PositionSide.BOTH == "BOTH"


def test_declared_inputs_reject_old_futures_alias():
    with pytest.raises(ValueError, match="unsupported market"):
        parse_declared_inputs([
            {"exchange": Exchange.BINANCE, "market": "futures", "symbol": "ETHUSDT", "interval": "1m"}
        ])


def test_order_targets_required_and_symbol_scoped():
    targets = parse_order_targets([
        {"exchange": Exchange.BINANCE, "market": Market.PERPETUAL_FUTURES, "symbol": "ETHUSDT"}
    ])
    assert targets[0].key == ("binance", "perpetual_futures", "ETHUSDT")
```

- [ ] **Step 2: Run tests and verify failure**

Run:

```bash
cd strategy-library && pytest -q tests/hushine_strategy/test_types_inputs.py
```

Expected:

- FAIL because constants and `parse_order_targets` are not implemented and `futures` alias is still accepted.

- [ ] **Step 3: Implement constants and string Decimal API types**

Modify `strategy-library/hushine_strategy/types.py`:

```python
from __future__ import annotations

from dataclasses import dataclass
from typing import Any, ClassVar


class Exchange:
    BINANCE: ClassVar[str] = "binance"
    OKX: ClassVar[str] = "okx"


class Market:
    SPOT: ClassVar[str] = "spot"
    PERPETUAL_FUTURES: ClassVar[str] = "perpetual_futures"
    DELIVERY_FUTURES: ClassVar[str] = "delivery_futures"


class OrderSide:
    BUY: ClassVar[str] = "BUY"
    SELL: ClassVar[str] = "SELL"


class OrderType:
    MARKET: ClassVar[str] = "MARKET"
    LIMIT: ClassVar[str] = "LIMIT"


class PositionSide:
    BOTH: ClassVar[str] = "BOTH"
    LONG: ClassVar[str] = "LONG"
    SHORT: ClassVar[str] = "SHORT"


@dataclass(frozen=True)
class OrderDecision:
    exchange: str
    market: str
    symbol: str
    side: str
    qty: str
    order_type: str
    price: str | None = None
    position_side: str | None = None
    time_in_force: str | None = None
```

Keep existing `OrderFill`, `OrderUpdateFill`, `OrderUpdateEvent`, and `MarketData`, but update `MarketData.market` default to `Market.PERPETUAL_FUTURES`.

- [ ] **Step 4: Implement strict declarations**

Modify `strategy-library/hushine_strategy/inputs.py`:

```python
@dataclass(frozen=True)
class StrategyOrderTarget:
    exchange: str
    market: str
    symbol: str

    @property
    def key(self) -> tuple[str, str, str]:
        return (self.exchange, self.market, self.symbol)


def _normalize_market(value: Any) -> str:
    market = str(value or "").strip().lower()
    if market not in {"spot", "perpetual_futures", "delivery_futures"}:
        raise ValueError(f"unsupported market: {market or '<empty>'}")
    return market


def parse_order_targets(raw: Any) -> list[StrategyOrderTarget]:
    if raw is None:
        raise ValueError("ORDER_TARGETS must be declared, use [] for read-only strategies")
    out: list[StrategyOrderTarget] = []
    for item in list(raw):
        if isinstance(item, StrategyOrderTarget):
            exchange, market, symbol = item.exchange, item.market, item.symbol
        elif isinstance(item, dict):
            exchange = item.get("exchange")
            market = item.get("market")
            symbol = item.get("symbol")
        else:
            raise ValueError("each ORDER_TARGETS item must be a dict with exchange, market, and symbol")
        if exchange is None or market is None or symbol is None:
            raise ValueError("ORDER_TARGETS exchange, market, and symbol are required")
        normalized = StrategyOrderTarget(
            exchange=_normalize_exchange(exchange),
            market=_normalize_market(market),
            symbol=str(symbol).strip().upper(),
        )
        if not normalized.symbol:
            raise ValueError("ORDER_TARGETS symbol is required")
        out.append(normalized)
    return out
```

Remove `self.market = _MarketNode(self._values)` from `InputView.__init__`.

- [ ] **Step 5: Run strategy-library tests**

Run:

```bash
cd strategy-library && pytest -q tests/hushine_strategy/test_types_inputs.py
```

Expected:

- PASS for updated input/type tests.

- [ ] **Step 6: Commit strategy-library API cut**

Run:

```bash
cd strategy-library
git add hushine_strategy/types.py hushine_strategy/inputs.py tests/hushine_strategy/test_types_inputs.py
git commit -m "feat: hard cut strategy api for venue targets"
```

## Task 2: Re-export Phase 3 Strategy Types in strategy-service

**Files:**
- Modify: `strategy-service/strategy_service/types.py`
- Modify: `strategy-service/strategy_service/inputs.py`
- Test: `strategy-service/tests/test_strategy_phase3_declarations.py`

- [ ] **Step 1: Add failing import and declaration tests**

Create `strategy-service/tests/test_strategy_phase3_declarations.py`:

```python
import pytest

from strategy_service.inputs import extract_declarations
from strategy_service.types import Exchange, Market, OrderDecision, OrderSide, OrderType


def test_types_reexport_strategy_constants():
    assert Exchange.BINANCE == "binance"
    assert Market.PERPETUAL_FUTURES == "perpetual_futures"
    decision = OrderDecision(
        exchange=Exchange.BINANCE,
        market=Market.PERPETUAL_FUTURES,
        symbol="ETHUSDT",
        side=OrderSide.BUY,
        qty="0.01",
        order_type=OrderType.MARKET,
    )
    assert decision.qty == "0.01"


def test_extract_declarations_requires_order_targets():
    class Strategy:
        INPUTS = [{"exchange": Exchange.BINANCE, "market": Market.PERPETUAL_FUTURES, "symbol": "ETHUSDT", "interval": "1m"}]

    with pytest.raises(ValueError, match="ORDER_TARGETS"):
        extract_declarations(Strategy())


def test_required_routes_union_inputs_and_order_targets():
    class Strategy:
        INPUTS = [{"exchange": Exchange.BINANCE, "market": Market.PERPETUAL_FUTURES, "symbol": "ETHUSDT", "interval": "1m"}]
        ORDER_TARGETS = [{"exchange": Exchange.BINANCE, "market": Market.SPOT, "symbol": "ETHUSDT"}]

    decl = extract_declarations(Strategy())
    assert decl.required_routes == {("binance", "perpetual_futures"), ("binance", "spot")}
```

- [ ] **Step 2: Run tests and verify failure**

Run:

```bash
cd strategy-service && PYTHONPATH=.:../strategy-library pytest -q tests/test_strategy_phase3_declarations.py
```

Expected:

- FAIL because `extract_declarations` and re-exported constants are missing.

- [ ] **Step 3: Re-export constants and types**

Modify `strategy-service/strategy_service/types.py`:

```python
from hushine_strategy.types import (
    Exchange,
    Market,
    MarketData,
    OrderDecision,
    OrderFill,
    OrderSide,
    OrderType,
    OrderUpdateEvent,
    OrderUpdateFill,
    PositionSide,
)
```

Ensure all old local duplicate `OrderDecision` definitions are removed or replaced by imports from `hushine_strategy.types`.

- [ ] **Step 4: Add declaration extraction wrapper**

Modify `strategy-service/strategy_service/inputs.py`:

```python
from dataclasses import dataclass

from hushine_strategy.inputs import (
    StrategyInput,
    StrategyOrderTarget,
    parse_declared_inputs,
    parse_order_targets,
)


@dataclass(frozen=True)
class StrategyDeclarations:
    inputs: list[StrategyInput]
    order_targets: list[StrategyOrderTarget]

    @property
    def input_keys(self) -> set[tuple[str, str, str, str]]:
        return {i.key for i in self.inputs}

    @property
    def order_target_keys(self) -> set[tuple[str, str, str]]:
        return {t.key for t in self.order_targets}

    @property
    def required_routes(self) -> set[tuple[str, str]]:
        routes = {(i.exchange, i.market) for i in self.inputs}
        routes.update((t.exchange, t.market) for t in self.order_targets)
        return routes


def extract_declarations(strategy_instance: object) -> StrategyDeclarations:
    inputs = parse_declared_inputs(getattr(strategy_instance, "INPUTS", None))
    targets = parse_order_targets(getattr(strategy_instance, "ORDER_TARGETS", None))
    return StrategyDeclarations(inputs=inputs, order_targets=targets)
```

- [ ] **Step 5: Run declaration tests**

Run:

```bash
cd strategy-service && PYTHONPATH=.:../strategy-library pytest -q tests/test_strategy_phase3_declarations.py
```

Expected:

- PASS.

- [ ] **Step 6: Commit strategy-service type bridge**

Run:

```bash
cd strategy-service
git add strategy_service/types.py strategy_service/inputs.py tests/test_strategy_phase3_declarations.py
git commit -m "feat: add phase 3 strategy declaration contract"
```

## Task 3: Add Core Portfolio Preflight Proto Fields

**Files:**
- Modify: `core-service/proto/account_service.proto`
- Regenerate: `core-service/gen/accountv1/account_service.pb.go`
- Regenerate: `core-service/gen/accountv1/account_service_grpc.pb.go`
- Regenerate: `strategy-service/strategy_service/gen/account_service_pb2.py`
- Regenerate: `strategy-service/strategy_service/gen/account_service_pb2_grpc.py`
- Modify generated bindings in `gateway/quant-handler` if the repository keeps local generated stubs.
- Test: `core-service/internal/service/grpc_account_meta_test.go`

- [ ] **Step 1: Write failing preflight symbol tests**

Add to `core-service/internal/service/grpc_account_meta_test.go`:

```go
func TestPreflightStrategySessionReportsMissingSymbolRules(t *testing.T) {
    svc, repo := newAccountMetaTestService(t)
    repo.accounts[1] = domain.Account{ID: 1, UserID: 7, Environment: domain.EnvironmentBacktest, Status: domain.AccountStatusActive}
    repo.venues = append(repo.venues, domain.Venue{
        ID: 10, UserID: 7, AccountID: sql.NullInt64{Int64: 1, Valid: true},
        Exchange: domain.ExchangeBinance, Market: domain.MarketPerpetualFutures,
        Environment: domain.EnvironmentBacktest, Status: domain.VenueStatusActive,
    })

    resp, err := svc.PreflightStrategySession(context.Background(), &accountv1.PreflightStrategySessionRequest{
        UserId: 7,
        AccountId: 1,
        RequiredRoutes: []*accountv1.RequiredRoute{{Exchange: int32(domain.ExchangeBinance), Market: int32(domain.MarketPerpetualFutures)}},
        RequiredSymbols: []*accountv1.RequiredSymbol{{Exchange: int32(domain.ExchangeBinance), Market: int32(domain.MarketPerpetualFutures), Symbol: "NOPEUSDT"}},
    })
    if err != nil {
        t.Fatalf("PreflightStrategySession: %v", err)
    }
    if resp.GetOk() {
        t.Fatalf("preflight ok = true, want false")
    }
    if got := resp.GetIssues()[0].GetCode(); got != "symbol_rules_missing" {
        t.Fatalf("issue code = %s, want symbol_rules_missing", got)
    }
}
```

- [ ] **Step 2: Run test and verify failure**

Run:

```bash
cd core-service && go test ./internal/service -run TestPreflightStrategySessionReportsMissingSymbolRules -count=1
```

Expected:

- FAIL because `RequiredRoute` / `RequiredSymbol` do not exist.

- [ ] **Step 3: Update proto**

Modify `core-service/proto/account_service.proto`:

```proto
message RequiredRoute {
  int32 exchange = 1;
  int32 market = 2;
}

message RequiredSymbol {
  int32 exchange = 1;
  int32 market = 2;
  string symbol = 3;
}

message PreflightStrategySessionRequest {
  int64 user_id = 1;
  int64 account_id = 2;
  repeated RequiredRoute required_routes = 3;
  repeated RequiredSymbol required_symbols = 4;
}

message PreflightIssue {
  string code = 1;
  string message = 2;
  int32 exchange = 3;
  int32 market = 4;
  string symbol = 5;
}
```

Remove or stop using `RequiredVenue` in new code. If the generated old type remains in historical generated files during transition, do not call it from Phase 3 runtime.

- [ ] **Step 4: Regenerate proto stubs**

Run:

```bash
cd core-service && make proto
cd ../strategy-service && ./generate_proto.sh
```

If `gateway/quant-handler` imports generated stubs from `core-service/gen/accountv1`, no separate generation is needed. If it has vendored generated files, regenerate them with the repository's existing command.

- [ ] **Step 5: Implement preflight symbol issue path**

Modify `core-service/internal/service/grpc.go` `PreflightStrategySession` to iterate `req.GetRequiredSymbols()` and call the existing symbol rules adapter/cache:

```go
for _, sym := range req.GetRequiredSymbols() {
    route := adapter.Route{
        Exchange: domain.Exchange(sym.GetExchange()),
        Environment: account.Environment,
        Market: domain.Market(sym.GetMarket()),
    }
    reader, err := s.exchangeRegistry.SymbolRulesReader(route)
    if err != nil {
        issues = append(issues, preflightIssue("symbol_rules_missing", err.Error(), route.Exchange, route.Market, sym.GetSymbol()))
        continue
    }
    if _, err := reader.ReadSymbolRules(ctx, adapter.SymbolRulesRequest{Symbol: strings.ToUpper(sym.GetSymbol())}); err != nil {
        issues = append(issues, preflightIssue("symbol_rules_missing", err.Error(), route.Exchange, route.Market, sym.GetSymbol()))
    }
}
```

- [ ] **Step 6: Run core-service preflight tests**

Run:

```bash
cd core-service && go test ./internal/service -run 'TestPreflightStrategySession' -count=1
```

Expected:

- PASS.

- [ ] **Step 7: Commit proto preflight contract**

Run:

```bash
cd core-service
git add proto/account_service.proto gen/accountv1 internal/service/grpc.go internal/service/grpc_account_meta_test.go
git commit -m "feat: add symbol-aware session preflight"
```

Commit regenerated strategy-service proto files with the task that first uses them.

## Task 4: Build PortfolioWalletRuntime

**Files:**
- Create: `strategy-service/strategy_service/wallet/portfolio.py`
- Modify: `strategy-service/strategy_service/wallet/__init__.py`
- Test: `strategy-service/tests/test_portfolio_wallet_runtime.py`

- [ ] **Step 1: Write failing portfolio wallet tests**

Create `strategy-service/tests/test_portfolio_wallet_runtime.py`:

```python
import pytest

from strategy_service.wallet.portfolio import PortfolioWalletRuntime


class StubWallet:
    def __init__(self):
        self.market_updates = []
        self.orders = []

    def on_market_data(self, symbol, symbol_type, price):
        self.market_updates.append((symbol, symbol_type, price))

    def on_order(self, symbol, symbol_type, order_resp):
        self.orders.append((symbol, symbol_type, order_resp))


def test_get_returns_declared_route_wallet():
    futures = StubWallet()
    spot = StubWallet()
    runtime = PortfolioWalletRuntime(
        account_id=10,
        allowed_routes={("binance", "perpetual_futures"), ("binance", "spot")},
        wallets={
            ("binance", "perpetual_futures", 100): futures,
            ("binance", "spot", 101): spot,
        },
    )
    assert runtime.get("binance", "perpetual_futures") is futures
    assert runtime.get("binance", "spot") is spot


def test_get_rejects_undeclared_route():
    runtime = PortfolioWalletRuntime(
        account_id=10,
        allowed_routes={("binance", "perpetual_futures")},
        wallets={("binance", "spot", 101): StubWallet()},
    )
    with pytest.raises(ValueError, match="not declared"):
        runtime.get("binance", "spot")


def test_old_single_wallet_shortcuts_are_absent():
    runtime = PortfolioWalletRuntime(account_id=10, allowed_routes=set(), wallets={})
    with pytest.raises(AttributeError):
        _ = runtime.futures
    with pytest.raises(AttributeError):
        runtime.get_wallet_balance()
```

- [ ] **Step 2: Run tests and verify failure**

Run:

```bash
cd strategy-service && PYTHONPATH=.:../strategy-library pytest -q tests/test_portfolio_wallet_runtime.py
```

Expected:

- FAIL because `strategy_service.wallet.portfolio` does not exist.

- [ ] **Step 3: Implement PortfolioWalletRuntime**

Create `strategy-service/strategy_service/wallet/portfolio.py`:

```python
from __future__ import annotations

from dataclasses import dataclass
from typing import Any

from strategy_service.inputs import _normalize_exchange, _normalize_market


Route = tuple[str, str]
WalletKey = tuple[str, str, int]


@dataclass
class PortfolioWalletRuntime:
    account_id: int
    allowed_routes: set[Route]
    wallets: dict[WalletKey, Any]

    def _resolve_key(self, exchange: str, market: str) -> WalletKey:
        route = (_normalize_exchange(exchange), _normalize_market(market))
        if route not in self.allowed_routes:
            raise ValueError(f"wallet route is not declared: {route}")
        matches = [key for key in self.wallets if key[0] == route[0] and key[1] == route[1]]
        if len(matches) != 1:
            raise ValueError(f"wallet route is not uniquely available: {route}")
        return matches[0]

    def get(self, exchange: str, market: str) -> Any:
        return self.wallets[self._resolve_key(exchange, market)]

    def on_market_data(self, exchange: str, market: str, symbol: str, symbol_type: str, price: float) -> None:
        self.get(exchange, market).on_market_data(symbol, symbol_type, price)

    def on_order(self, exchange: str, market: str, venue_id: int, symbol: str, symbol_type: str, order_resp: object) -> None:
        wallet = self.wallets.get((_normalize_exchange(exchange), _normalize_market(market), int(venue_id)))
        if wallet is None:
            raise ValueError(f"wallet venue is not available: {(exchange, market, venue_id)}")
        wallet.on_order(symbol, symbol_type, order_resp)
```

- [ ] **Step 4: Export PortfolioWalletRuntime**

Modify `strategy-service/strategy_service/wallet/__init__.py`:

```python
from .portfolio import PortfolioWalletRuntime

__all__ = [
    # existing exports
    "PortfolioWalletRuntime",
]
```

- [ ] **Step 5: Run tests**

Run:

```bash
cd strategy-service && PYTHONPATH=.:../strategy-library pytest -q tests/test_portfolio_wallet_runtime.py
```

Expected:

- PASS.

- [ ] **Step 6: Commit portfolio wallet runtime**

Run:

```bash
cd strategy-service
git add strategy_service/wallet/portfolio.py strategy_service/wallet/__init__.py tests/test_portfolio_wallet_runtime.py
git commit -m "feat: add portfolio wallet runtime"
```

## Task 5: Build Portfolio Snapshot Adapter in strategy-service

**Files:**
- Create: `strategy-service/strategy_service/wallet/portfolio_adapter.py`
- Modify: `strategy-service/strategy_service/account_client.py`
- Modify: `strategy-service/strategy_service/platform_proxy.py`
- Test: `strategy-service/tests/test_portfolio_snapshot_adapter.py`

- [ ] **Step 1: Write failing adapter tests**

Create `strategy-service/tests/test_portfolio_snapshot_adapter.py`:

```python
from types import SimpleNamespace

from strategy_service.wallet.portfolio_adapter import build_portfolio_wallet_from_snapshot


def venue_snapshot(venue_id, exchange, market):
    return SimpleNamespace(
        venue_id=venue_id,
        exchange=exchange,
        market=market,
        wallet_balance=1000.0,
        available_balance=900.0,
        balances=[],
        positions=[],
    )


def test_build_portfolio_wallet_from_two_venues():
    snapshot = SimpleNamespace(
        account_id=7,
        venues=[
            venue_snapshot(10, "binance", "perpetual_futures"),
            venue_snapshot(11, "binance", "spot"),
        ],
    )
    wallet = build_portfolio_wallet_from_snapshot(
        snapshot,
        allowed_routes={("binance", "perpetual_futures"), ("binance", "spot")},
    )
    assert wallet.get("binance", "perpetual_futures") is not wallet.get("binance", "spot")
```

- [ ] **Step 2: Run test and verify failure**

Run:

```bash
cd strategy-service && PYTHONPATH=.:../strategy-library pytest -q tests/test_portfolio_snapshot_adapter.py
```

Expected:

- FAIL because `portfolio_adapter` does not exist.

- [ ] **Step 3: Add account client portfolio methods**

Modify `strategy-service/strategy_service/account_client.py`:

```python
def get_portfolio_snapshot(self, account_id: int, user_id: int = 0):
    req = account_service_pb2.GetPortfolioSnapshotRequest(account_id=account_id, user_id=user_id)
    return self._stub.GetPortfolioSnapshot(req).snapshot


def update_portfolio_snapshot(
    self,
    account_id: int,
    *,
    user_id: int = 0,
    snapshot_reason: int = 0,
    strategy_id: int = 0,
    session_id: str = "",
):
    req = account_service_pb2.UpdatePortfolioSnapshotRequest(
        account_id=account_id,
        user_id=user_id,
        snapshot_reason=snapshot_reason,
        strategy_id=strategy_id,
        session_id=session_id,
    )
    return self._stub.UpdatePortfolioSnapshot(req).snapshot
```

Keep old methods only for non-normal paths until they are removed in Task 9. Do not call old methods from new runtime path.

- [ ] **Step 4: Implement snapshot adapter**

Create `strategy-service/strategy_service/wallet/portfolio_adapter.py`:

```python
from __future__ import annotations

from typing import Any

from strategy_service.wallet.binance import BinanceWalletRuntime
from strategy_service.wallet.canonical import (
    CanonicalAccountState,
    CanonicalFuturesPositionState,
    CanonicalFuturesState,
    CanonicalSpotAssetState,
    CanonicalSpotState,
)
from strategy_service.wallet.portfolio import PortfolioWalletRuntime


_EXCHANGE_LABELS = {
    1: "binance",
    2: "okx",
}

_MARKET_LABELS = {
    1: "spot",
    2: "perpetual_futures",
    3: "delivery_futures",
}


def _enum_label(value: Any, labels: dict[int, str]) -> str:
    if isinstance(value, str):
        return value.strip().lower()
    try:
        return labels[int(value)]
    except (KeyError, TypeError, ValueError) as exc:
        raise ValueError(f"unsupported enum value: {value!r}") from exc


def _build_binance_wallet_from_venue_snapshot(snapshot: Any) -> BinanceWalletRuntime:
    market = _enum_label(getattr(snapshot, "market", 0), _MARKET_LABELS)
    if market == "spot":
        balances = list(getattr(snapshot, "balances", []) or [])
        state = CanonicalAccountState(
            spot=CanonicalSpotState(
                free=sum(float(getattr(item, "available_balance", 0.0) or 0.0) for item in balances if str(getattr(item, "asset", "")).upper() == "USDT"),
                locked=sum(float(getattr(item, "locked", 0.0) or 0.0) for item in balances if str(getattr(item, "asset", "")).upper() == "USDT"),
                assets=[
                    CanonicalSpotAssetState(
                        symbol=str(getattr(item, "asset", "")).upper(),
                        qty=float(getattr(item, "wallet_balance", 0.0) or 0.0),
                        locked=float(getattr(item, "locked", 0.0) or 0.0),
                        price=None,
                    )
                    for item in balances
                    if str(getattr(item, "asset", "")).upper() != "USDT"
                ],
            ),
            total_value=float(getattr(snapshot, "total_value", 0.0) or 0.0),
        )
        return BinanceWalletRuntime(state)

    positions = list(getattr(snapshot, "positions", []) or [])
    state = CanonicalAccountState(
        futures=CanonicalFuturesState(
            margin_mode="cross",
            position_mode="one_way",
            positions=[
                CanonicalFuturesPositionState(
                    symbol=str(getattr(pos, "symbol", "")).upper(),
                    position_side=str(getattr(pos, "position_side", "") or "BOTH"),
                    position_qty=float(getattr(pos, "qty", 0.0) or 0.0),
                    entry_price=float(getattr(pos, "entry_price", 0.0) or 0.0),
                    mark_price=float(getattr(pos, "mark_price", 0.0) or 0.0),
                    unrealized_pnl=float(getattr(pos, "unrealized_pnl", 0.0) or 0.0),
                    margin_mode="cross",
                    liquidation_price=float(getattr(pos, "liquidation_price", 0.0) or 0.0),
                )
                for pos in positions
            ],
            wallet_balance=float(getattr(snapshot, "wallet_balance", 0.0) or 0.0),
            available_balance=float(getattr(snapshot, "available_balance", 0.0) or 0.0),
            margin_balance=float(getattr(snapshot, "wallet_balance", 0.0) or 0.0),
        ),
        total_value=float(getattr(snapshot, "total_value", 0.0) or 0.0),
    )
    return BinanceWalletRuntime(state)


def build_portfolio_wallet_from_snapshot(snapshot: Any, allowed_routes: set[tuple[str, str]]) -> PortfolioWalletRuntime:
    wallets: dict[tuple[str, str, int], Any] = {}
    for venue in getattr(snapshot, "venues", []) or []:
        exchange = _enum_label(getattr(venue, "exchange", 0), _EXCHANGE_LABELS)
        market = _enum_label(getattr(venue, "market", 0), _MARKET_LABELS)
        venue_id = int(getattr(venue, "venue_id", 0) or 0)
        if exchange == "binance":
            wallets[(exchange, market, venue_id)] = _build_binance_wallet_from_venue_snapshot(venue)
        else:
            raise ValueError(f"unsupported portfolio wallet exchange: {exchange}")
    return PortfolioWalletRuntime(
        account_id=int(getattr(snapshot, "account_id", 0) or 0),
        allowed_routes=allowed_routes,
        wallets=wallets,
    )
```

During implementation, verify `_build_binance_wallet_from_venue_snapshot` against the actual `VenueSnapshot.balances` and `VenueSnapshot.positions` fields and reuse the existing canonical wallet conversion patterns from `strategy-service/strategy_service/wallet_adapter.py`.

- [ ] **Step 5: Run adapter tests**

Run:

```bash
cd strategy-service && PYTHONPATH=.:../strategy-library pytest -q tests/test_portfolio_snapshot_adapter.py
```

Expected:

- PASS.

- [ ] **Step 6: Commit snapshot adapter**

Run:

```bash
cd strategy-service
git add strategy_service/account_client.py strategy_service/platform_proxy.py strategy_service/wallet/portfolio_adapter.py tests/test_portfolio_snapshot_adapter.py
git commit -m "feat: build runtime wallets from portfolio snapshots"
```

## Task 6: Replace BaseStrategy Single-Wallet Flow

**Files:**
- Modify: `strategy-service/strategy_service/strategy/base.py`
- Test: `strategy-service/tests/test_strategy_engine.py`
- Test: `strategy-service/tests/test_strategy_phase3_runtime.py`

- [ ] **Step 1: Write failing runtime behavior tests**

Create `strategy-service/tests/test_strategy_phase3_runtime.py`:

```python
import pytest

from strategy_service.strategy.base import BaseStrategy
from strategy_service.types import Exchange, Market, MarketData, OrderDecision, OrderSide, OrderType
from strategy_service.wallet.portfolio import PortfolioWalletRuntime


class StubOrderClient:
    def __init__(self):
        self.orders = []

    def place_order(self, account_id, decision, mark_price, **kwargs):
        self.orders.append(decision)
        return type("Feedback", (), {"attempt_status": "FAILED", "error_message": "stub", "order": None, "fill_events": []})()


def test_order_must_be_declared_in_order_targets():
    code = '''
from strategy_service.types import Exchange, Market, OrderDecision, OrderSide, OrderType
class MyStrategy:
    INPUTS = [{"exchange": Exchange.BINANCE, "market": Market.PERPETUAL_FUTURES, "symbol": "ETHUSDT", "interval": "1m"}]
    ORDER_TARGETS = []
    def on_market_data(self, data, wallet):
        return OrderDecision(exchange=Exchange.BINANCE, market=Market.PERPETUAL_FUTURES, symbol="ETHUSDT", side=OrderSide.BUY, qty="0.01", order_type=OrderType.MARKET)
'''
    svc = BaseStrategy("inline.py", PortfolioWalletRuntime(1, {("binance", "perpetual_futures")}, {}), StubOrderClient(), account_id=1, strategy_code=code)
    with pytest.raises(ValueError, match="ORDER_TARGETS"):
        svc.running_strategy(MarketData(exchange="binance", market="perpetual_futures", symbol="ETHUSDT", interval="1m", price=2500, timestamp=1))


def test_list_order_decisions_are_processed_independently():
    code = '''
from strategy_service.types import Exchange, Market, OrderDecision, OrderSide, OrderType
class MyStrategy:
    INPUTS = [{"exchange": Exchange.BINANCE, "market": Market.PERPETUAL_FUTURES, "symbol": "ETHUSDT", "interval": "1m"}]
    ORDER_TARGETS = [
        {"exchange": Exchange.BINANCE, "market": Market.PERPETUAL_FUTURES, "symbol": "ETHUSDT"},
        {"exchange": Exchange.BINANCE, "market": Market.SPOT, "symbol": "ETHUSDT"},
    ]
    def on_market_data(self, data, wallet):
        wallet.get(Exchange.BINANCE, Market.PERPETUAL_FUTURES)
        wallet.get(Exchange.BINANCE, Market.SPOT)
        return [
            OrderDecision(exchange=Exchange.BINANCE, market=Market.PERPETUAL_FUTURES, symbol="ETHUSDT", side=OrderSide.BUY, qty="0.01", order_type=OrderType.MARKET),
            OrderDecision(exchange=Exchange.BINANCE, market=Market.SPOT, symbol="ETHUSDT", side=OrderSide.BUY, qty="1", order_type=OrderType.MARKET),
        ]
'''
    client = StubOrderClient()
    wallet = PortfolioWalletRuntime(
        1,
        {("binance", "perpetual_futures"), ("binance", "spot")},
        {
            ("binance", "perpetual_futures", 10): type("W", (), {"on_market_data": lambda *a: None})(),
            ("binance", "spot", 11): type("W", (), {"on_market_data": lambda *a: None})(),
        },
    )
    svc = BaseStrategy("inline.py", wallet, client, account_id=1, strategy_code=code)
    svc.running_strategy(MarketData(exchange="binance", market="perpetual_futures", symbol="ETHUSDT", interval="1m", price=2500, timestamp=1))
    assert len(client.orders) == 2
```

- [ ] **Step 2: Run tests and verify failure**

Run:

```bash
cd strategy-service && PYTHONPATH=.:../strategy-library pytest -q tests/test_strategy_phase3_runtime.py
```

Expected:

- FAIL because `BaseStrategy` still uses `VenueWalletView`, `INPUTS` as order universe, and single `OrderDecision`.

- [ ] **Step 3: Remove VenueWalletView from normal runtime path**

Modify `strategy-service/strategy_service/strategy/base.py`:

```python
from decimal import Decimal, InvalidOperation


def _normalize_decisions(signal: object) -> list[OrderDecision]:
    if signal is None:
        return []
    if isinstance(signal, OrderDecision):
        return [signal]
    if isinstance(signal, list) and all(isinstance(item, OrderDecision) for item in signal):
        return list(signal)
    raise ValueError("on_market_data must return None, OrderDecision, or list[OrderDecision]")


def _parse_positive_decimal(value: str, field: str) -> Decimal:
    if not isinstance(value, str):
        raise ValueError(f"OrderDecision.{field} must be a string")
    try:
        parsed = Decimal(value)
    except (InvalidOperation, ValueError) as exc:
        raise ValueError(f"OrderDecision.{field} must be a decimal string") from exc
    if parsed <= 0:
        raise ValueError(f"OrderDecision.{field} must be > 0")
    return parsed
```

Use `PortfolioWalletRuntime` directly as the user-facing wallet object. Do not wrap it in `VenueWalletView`.

- [ ] **Step 4: Validate decisions against ORDER_TARGETS**

In `BaseStrategy.__init__`, replace `_order_universe` with:

```python
self._decl = extract_declarations(self._strategy_instance)
self._inputs = self._decl.inputs
self._order_targets = self._decl.order_targets
self._input_keys = self._decl.input_keys
self._order_target_keys = self._decl.order_target_keys
self._required_routes = self._decl.required_routes
```

When processing each decision:

```python
target_key = (sig_exchange, sig_market, sig_sym)
if target_key not in self._order_target_keys:
    raise ValueError(f"strategy attempted to place order outside ORDER_TARGETS: {target_key}")
```

- [ ] **Step 5: Process each decision independently**

Replace single signal processing with:

```python
signals = _normalize_decisions(self._strategy_instance.on_market_data(self._view, self.wallet))
for signal in signals:
    self._process_order_decision(signal, market_data)
```

Move the old single-order logic into `_process_order_decision`.

- [ ] **Step 6: Run runtime tests**

Run:

```bash
cd strategy-service && PYTHONPATH=.:../strategy-library pytest -q tests/test_strategy_phase3_runtime.py tests/test_strategy_engine.py
```

Expected:

- Phase 3 tests PASS.
- Existing old-strategy tests will fail until updated in Task 11.

- [ ] **Step 7: Commit BaseStrategy Phase 3 runtime**

Run:

```bash
cd strategy-service
git add strategy_service/strategy/base.py tests/test_strategy_phase3_runtime.py tests/test_strategy_engine.py
git commit -m "feat: route strategy orders through portfolio wallet"
```

## Task 7: Switch Session Startup to Portfolio Snapshot

**Files:**
- Modify: `strategy-service/strategy_service/grpc_server.py`
- Modify: `strategy-service/strategy_service/session.py`
- Modify: `strategy-service/strategy_service/account_client.py`
- Test: `strategy-service/tests/test_grpc_server.py`

- [ ] **Step 1: Add failing startup test**

Add to `strategy-service/tests/test_grpc_server.py`:

```python
def test_run_strategy_builds_wallet_from_portfolio_snapshot(monkeypatch):
    calls = {"portfolio": 0, "online": 0}

    class AccountClient:
        def get_portfolio_snapshot(self, account_id, user_id=0):
            calls["portfolio"] += 1
            return make_portfolio_snapshot_with_binance_perp_and_spot(account_id)

        def get_online_account_info(self, account_id, user_id=0):
            calls["online"] += 1
            raise AssertionError("normal Phase 3 run must not call GetOnlineAccountInfo")

    # Use existing servicer test setup and inject AccountClient.
    # Assert calls["portfolio"] == 1 and calls["online"] == 0 after startup.
```

Add this local helper in the test file if there is no existing equivalent:

```python
from strategy_service.gen import account_service_pb2


def make_portfolio_snapshot_with_binance_perp_and_spot(account_id: int):
    return account_service_pb2.PortfolioSnapshot(
        account_id=account_id,
        user_id=17,
        total_value=2000.0,
        wallet_balance=2000.0,
        available_balance=1800.0,
        venues=[
            account_service_pb2.VenueSnapshot(
                venue_id=1001,
                exchange=1,
                environment=0,
                market=2,
                total_value=1000.0,
                wallet_balance=1000.0,
                available_balance=900.0,
            ),
            account_service_pb2.VenueSnapshot(
                venue_id=1002,
                exchange=1,
                environment=0,
                market=1,
                total_value=1000.0,
                wallet_balance=1000.0,
                available_balance=900.0,
                balances=[
                    account_service_pb2.BalanceEntry(asset="USDT", wallet_balance=1000.0, available_balance=900.0, locked=100.0),
                ],
            ),
        ],
    )
```

- [ ] **Step 2: Run test and verify failure**

Run:

```bash
cd strategy-service && PYTHONPATH=.:../strategy-library pytest -q tests/test_grpc_server.py::test_run_strategy_builds_wallet_from_portfolio_snapshot
```

Expected:

- FAIL because startup still calls old account wallet path.

- [ ] **Step 3: Build allowed routes during RunStrategy**

In `strategy-service/strategy_service/grpc_server.py`, after loading strategy code:

```python
decl = extract_strategy_declarations(strategy_code)
required_routes = sorted(decl.required_routes)
required_symbols = sorted({(i.exchange, i.market, i.symbol) for i in decl.inputs} | decl.order_target_keys)
```

Send `required_routes` and `required_symbols` into core-service preflight before runtime creation.

- [ ] **Step 4: Fetch PortfolioSnapshot and build PortfolioWalletRuntime**

Replace old wallet construction:

```python
snapshot = self._account_client.get_portfolio_snapshot(account_id, user_id=user_id)
wallet = build_portfolio_wallet_from_snapshot(snapshot, allowed_routes=decl.required_routes)
```

Do not fall back to `GetOnlineAccountInfo`.

- [ ] **Step 5: Switch snapshot write callback**

When `BaseStrategy` calls `on_order_callback`, bind it to:

```python
self._account_client.update_portfolio_snapshot(
    account_id,
    user_id=user_id,
    snapshot_reason=SNAPSHOT_REASON_EVENT,
    strategy_id=strategy_id,
    session_id=session_id,
)
```

Do not call `UpdateAccountWalletState` from normal strategy sessions.

- [ ] **Step 6: Run startup tests**

Run:

```bash
cd strategy-service && PYTHONPATH=.:../strategy-library pytest -q tests/test_grpc_server.py tests/test_account_client_runtime_binding.py
```

Expected:

- PASS after updating tests to Phase 3 expectations.

- [ ] **Step 7: Commit portfolio startup path**

Run:

```bash
cd strategy-service
git add strategy_service/grpc_server.py strategy_service/session.py strategy_service/account_client.py tests/test_grpc_server.py tests/test_account_client_runtime_binding.py
git commit -m "feat: start sessions from portfolio snapshots"
```

## Task 8: Core-Service Preflight Failed Session Persistence

**Files:**
- Modify: `core-service/proto/account_service.proto`
- Modify: `core-service/internal/storage/migrations/0019_portfolio_venue_hard_cut.sql` if fresh schema already includes fields.
- Create: `core-service/internal/storage/migrations/0023_strategy_session_preflight_errors.sql` if existing deployments need additive fields.
- Modify: `core-service/internal/domain/models.go`
- Modify: `core-service/internal/repository/timescale.go`
- Modify: `core-service/internal/service/grpc.go`
- Test: `core-service/internal/service/grpc_strategy_test.go`
- Test: `core-service/internal/repository/session_test.go`

- [ ] **Step 1: Write failing repository test**

Add to `core-service/internal/repository/session_test.go`:

```go
func TestSavePreflightFailedSessionPersistsStructuredError(t *testing.T) {
    repo := setupTestRepository(t)
    ctx := context.Background()
    sess := domain.StrategySession{
        SessionID: "preflight-failed-1",
        UserID: 7,
        AccountID: 1,
        StrategyID: 2,
        Status: domain.SessionStatusPreflightFailed,
        ErrorCode: "missing_venue",
        ErrorMessage: "no active binance perpetual_futures venue",
        ErrorDetailJSON: `{"exchange":"binance","market":"perpetual_futures"}`,
    }
    if err := repo.SaveSession(ctx, sess); err != nil {
        t.Fatalf("SaveSession: %v", err)
    }
    got, err := repo.GetSession(ctx, sess.SessionID)
    if err != nil {
        t.Fatalf("GetSession: %v", err)
    }
    if got.ErrorCode != "missing_venue" || got.StartedAt.Valid {
        t.Fatalf("unexpected preflight failure session: %+v", got)
    }
}
```

- [ ] **Step 2: Run test and verify failure**

Run:

```bash
cd core-service && go test ./internal/repository -run TestSavePreflightFailedSessionPersistsStructuredError -count=1
```

Expected:

- FAIL because structured fields are missing.

- [ ] **Step 3: Add DB fields**

If `0019_portfolio_venue_hard_cut.sql` is the fresh hard-cut schema source, add columns there:

```sql
error_code TEXT NOT NULL DEFAULT '',
error_message TEXT NOT NULL DEFAULT '',
error_detail_json JSONB NOT NULL DEFAULT '{}'::jsonb,
```

If existing local deployments need additive migration, create `0023_strategy_session_preflight_errors.sql`:

```sql
ALTER TABLE strategy_sessions
    ADD COLUMN IF NOT EXISTS error_code TEXT NOT NULL DEFAULT '',
    ADD COLUMN IF NOT EXISTS error_message TEXT NOT NULL DEFAULT '',
    ADD COLUMN IF NOT EXISTS error_detail_json JSONB NOT NULL DEFAULT '{}'::jsonb;
```

- [ ] **Step 4: Update domain and repository**

Add to `domain.StrategySession`:

```go
ErrorCode string
ErrorMessage string
ErrorDetailJSON string
```

Update `sessionSelectColumns`, `SaveSession`, and row scanners in `core-service/internal/repository/timescale.go`.

- [ ] **Step 5: Add service method for preflight failed sessions**

In `core-service/internal/service/grpc.go`, when preflight returns issues for a start request, save:

```go
sess := domain.StrategySession{
    SessionID: sessionID,
    UserID: userID,
    AccountID: accountID,
    StrategyID: strategyID,
    Status: domain.SessionStatusPreflightFailed,
    ErrorCode: firstIssue.Code,
    ErrorMessage: firstIssue.Message,
    ErrorDetailJSON: string(detailJSON),
    EndedAt: sql.NullTime{Time: time.Now().UTC(), Valid: true},
}
```

If session ID is generated by strategy-service today, add a core-service helper RPC or reuse `SaveSession` with status `preflight_failed` from strategy-service. The implementation must ensure a failed start is visible after UI refresh.

- [ ] **Step 6: Run repository and service tests**

Run:

```bash
cd core-service && go test ./internal/repository ./internal/service -run 'Preflight|Session' -count=1
```

Expected:

- PASS.

- [ ] **Step 7: Commit preflight failure persistence**

Run:

```bash
cd core-service
git add proto/account_service.proto gen/accountv1 internal/storage/migrations internal/domain internal/repository internal/service
git commit -m "feat: persist preflight failed sessions"
```

## Task 9: Remove Old Wallet Snapshot Calls from Normal Runtime

**Files:**
- Modify: `strategy-service/strategy_service/account_client.py`
- Modify: `strategy-service/strategy_service/platform_proxy.py`
- Modify: `strategy-service/strategy_service/grpc_server.py`
- Modify: `strategy-service/tests/test_grpc_server.py`
- Modify: `gateway/quant-handler/internal/app/accounts_ext.go`
- Modify: `gateway/quant-handler/README.md`

- [x] **Step 1: Add guard tests**

Add to `strategy-service/tests/test_grpc_server.py`:

```python
def test_phase3_normal_run_never_updates_legacy_wallet_state(monkeypatch):
    calls = {"legacy_update": 0, "portfolio_update": 0}

    class AccountClient:
        def get_portfolio_snapshot(self, account_id, user_id=0):
            return make_portfolio_snapshot_with_binance_perp_and_spot(account_id)

        def update_portfolio_snapshot(self, *args, **kwargs):
            calls["portfolio_update"] += 1

        def update_account_wallet_state(self, *args, **kwargs):
            calls["legacy_update"] += 1
            raise AssertionError("normal Phase 3 run must not call UpdateAccountWalletState")

    # Execute a minimal run through existing servicer harness.
    assert calls["legacy_update"] == 0
```

- [x] **Step 2: Run guard test and verify failure if old path is still used**

Run:

```bash
cd strategy-service && PYTHONPATH=.:../strategy-library pytest -q tests/test_grpc_server.py::test_phase3_normal_run_never_updates_legacy_wallet_state
```

Expected:

- FAIL until old snapshot write callbacks are replaced.

- [x] **Step 3: Remove old normal-path calls**

In strategy-service:

- Keep `get_online_account_info` only if debugger/admin inspection still needs it.
- Mark it non-normal with a docstring:

```python
def get_online_account_info(...):
    """Legacy/admin-only helper. Normal Phase 3 strategy sessions use get_portfolio_snapshot."""
```

- Ensure `RunStrategy`, `PreviewRunStrategy`, backtest runtime, lifecycle settlement, and periodic sample paths call portfolio APIs.

- [x] **Step 4: Update gateway account wallet read path**

In `gateway/quant-handler/internal/app/accounts_ext.go`, prefer `GetPortfolioSnapshot` for Account Detail wallet display. If a compatibility endpoint remains named `/wallet`, its implementation should call portfolio snapshot and map aggregate + venue snapshots to JSON.

Expected mapping:

```go
resp, err := s.accounts.GetPortfolioSnapshot(ctx, &accountv1.GetPortfolioSnapshotRequest{
    AccountId: accountID,
    UserId: userID,
})
```

- [x] **Step 5: Update README**

Modify `gateway/quant-handler/README.md`:

- Replace `mode` account creation docs with `environment`.
- Replace `GetOnlineAccountInfo` wallet docs with `GetPortfolioSnapshot`.
- Remove `UpdateAccountWalletState` from normal account creation flow documentation.

- [x] **Step 6: Run residual scan**

Run:

```bash
rg -n 'GetOnlineAccountInfo|UpdateAccountWalletState|ACCOUNT_GET_ONLINE|ACCOUNT_UPDATE_WALLET' strategy-service gateway/quant-handler -g '!**/.git/**'
```

Expected:

- Matches are either generated stubs, explicit legacy/admin helper comments, or negative tests.
- No normal run path uses old APIs.

- [x] **Step 7: Commit old snapshot path removal**

Run:

```bash
cd strategy-service
git add strategy_service tests
git commit -m "refactor: use portfolio snapshots for strategy sessions"

cd ../gateway/quant-handler
git add internal/app/accounts_ext.go README.md
git commit -m "refactor: read account wallets from portfolio snapshots"
```

## Task 10: Core Order Lifecycle Route Isolation

**Files:**
- Modify: `core-service/internal/order/service/grpc.go`
- Modify: `core-service/internal/order/repository/timescale.go`
- Modify: `core-service/internal/order/lifecycle/*`
- Modify: `strategy-service/strategy_service/order_client.py`
- Modify: `strategy-service/strategy_service/strategy/base.py`
- Test: `core-service/internal/order/service/*_test.go`
- Test: `strategy-service/tests/test_order_client.py`

- [x] **Step 1: Add unresolved order blocking tests**

Add to `strategy-service/tests/test_order_client.py` or `tests/test_strategy_phase3_runtime.py`:

```python
def test_unresolved_order_blocks_only_same_account_route_symbol():
    # First ETHUSDT perpetual order returns RECOVERING.
    # Second ETHUSDT perpetual order is skipped.
    # Spot ETHUSDT order is still attempted.
    # BTCUSDT perpetual order is still attempted.
```

Use concrete assertions on order client calls:

```python
assert attempted == [
    ("binance", "perpetual_futures", "ETHUSDT"),
    ("binance", "spot", "ETHUSDT"),
    ("binance", "perpetual_futures", "BTCUSDT"),
]
```

- [x] **Step 2: Run tests and verify failure**

Run:

```bash
cd strategy-service && PYTHONPATH=.:../strategy-library pytest -q tests/test_strategy_phase3_runtime.py -k unresolved
```

Expected:

- FAIL until blocked keys and multi-order processing are updated.

- [x] **Step 3: Ensure lifecycle event route facts are complete**

In core-service order lifecycle event creation, assert every event has:

```go
AccountID int64
VenueID int64
Exchange domain.Exchange
Market domain.Market
Symbol string
PositionSide string
```

If any lifecycle event path can produce missing route facts, fail closed and persist the failure on the attempt rather than emitting an ambiguous event.

- [x] **Step 4: Update strategy blocked key handling**

In `BaseStrategy`, use:

```python
blocked_key = (sig_exchange, sig_market, sig_sym)
```

Document that account_id is implicit in the session. Ensure core-service lifecycle/recovery queries include account_id.

- [x] **Step 5: Apply fill to correct venue wallet**

In `_consume_order_updates`, replace:

```python
self.wallet.on_order(order_resp.symbol, wallet_market, order_resp)
```

with:

```python
self.wallet.on_order(
    event.exchange,
    event.market,
    event.venue_id,
    order_resp.symbol,
    wallet_market,
    order_resp,
)
```

- [x] **Step 6: Run lifecycle tests**

Run:

```bash
cd core-service && go test ./internal/order/... -count=1
cd ../strategy-service && PYTHONPATH=.:../strategy-library pytest -q tests/test_order_client.py tests/test_strategy_phase3_runtime.py
```

Expected:

- PASS.

- [x] **Step 7: Commit lifecycle isolation**

Run:

```bash
cd core-service
git add internal/order
git commit -m "fix: isolate lifecycle events by venue route"

cd ../strategy-service
git add strategy_service/order_client.py strategy_service/strategy/base.py tests
git commit -m "feat: settle lifecycle fills into venue wallets"
```

## Task 11: Update Strategy Templates, Seeds, and Tests

**Files:**
- Modify: `strategy-service/strategy_templates/eth_pyramid_futures.py`
- Modify: `strategy-service/scripts/seed_test_strategies.py`
- Modify: `strategy-service/scripts/seed_reconciliation_test_strategy.py`
- Modify: `strategy-service/scripts/seed_reconciliation_test_strategy.py`
- Modify: `strategy-service/tests/test_grpc_server.py`
- Modify: `strategy-service/tests/test_data_loop.py`
- Modify: `strategy-service/tests/test_order_client.py`
- Modify: `strategy-service/tests/test_notification.py`

- [x] **Step 1: Replace old template imports**

Update template strategy imports:

```python
from strategy_service.types import Exchange, Market, OrderDecision, OrderSide, OrderType, PositionSide
```

- [x] **Step 2: Replace old INPUTS**

Use:

```python
INPUTS = [
    {"exchange": Exchange.BINANCE, "market": Market.PERPETUAL_FUTURES, "symbol": "ETHUSDT", "interval": "1m"}
]

ORDER_TARGETS = [
    {"exchange": Exchange.BINANCE, "market": Market.PERPETUAL_FUTURES, "symbol": "ETHUSDT"}
]
```

- [x] **Step 3: Replace data access**

Replace:

```python
tick = data.market["futures"].symbol["ETHUSDT"].interval["1m"]
```

with:

```python
tick = data.exchange[Exchange.BINANCE][Market.PERPETUAL_FUTURES].symbol["ETHUSDT"].interval["1m"]
```

- [x] **Step 4: Replace wallet access**

Replace:

```python
wallet_balance = float(wallet.futures.get_wallet_balance())
```

with:

```python
futures_wallet = wallet.get(Exchange.BINANCE, Market.PERPETUAL_FUTURES)
wallet_balance = float(futures_wallet.get_wallet_balance())
```

- [x] **Step 5: Replace OrderDecision**

Replace old futures LONG/SHORT decisions:

```python
OrderDecision(symbol="ETHUSDT", side="LONG", qty=qty, market="futures")
```

with explicit Phase 3 decisions:

```python
OrderDecision(
    exchange=Exchange.BINANCE,
    market=Market.PERPETUAL_FUTURES,
    symbol="ETHUSDT",
    side=OrderSide.BUY,
    qty=str(qty),
    order_type=OrderType.MARKET,
    position_side=PositionSide.BOTH,
)
```

Use `OrderSide.SELL` for closing/reducing a long in one-way mode.

- [x] **Step 6: Run strategy-service tests**

Run:

```bash
cd strategy-service && PYTHONPATH=.:../strategy-library pytest -q tests/
```

Expected:

- PASS after all tests are updated to Phase 3 API.

- [x] **Step 7: Commit template/test hard cut**

Run:

```bash
cd strategy-service
git add strategy_templates scripts tests
git commit -m "test: update strategies to phase 3 api"
```

## Task 12: Update Debugger CLI and Debug Packages

**Files:**
- Modify: `strategy-debugger-cli/src/hushine_debugger/templates/strategy.py.template`
- Modify: `strategy-debugger-cli/src/hushine_debugger/config.py`
- Modify: `strategy-debugger-cli/src/hushine_debugger/demo_data.py`
- Modify: `strategy-debugger-cli/src/hushine_debugger/import_package.py`
- Modify: `strategy-debugger-cli/src/hushine_debugger/replay.py`
- Modify: `strategy-debugger-cli/README.md`
- Modify: `strategy-debugger-cli/tests/test_cli.py`
- Modify: `strategy-debugger-cli/tests/test_replay_cli.py`
- Modify: `gateway/quant-handler/internal/app/debug_package.go`
- Modify: `gateway/quant-handler/internal/app/debug_package_test.go`

- [x] **Step 1: Write failing debugger template tests**

In `strategy-debugger-cli/tests/test_cli.py`, assert generated template contains:

```python
assert "Exchange.BINANCE" in content
assert "Market.PERPETUAL_FUTURES" in content
assert "ORDER_TARGETS" in content
assert "data.exchange" in content
assert 'market = "futures"' not in content
assert "data.market" not in content
```

- [x] **Step 2: Run tests and verify failure**

Run:

```bash
cd strategy-debugger-cli && pytest -q tests/test_cli.py tests/test_replay_cli.py
```

Expected:

- FAIL because templates still use old API.

- [x] **Step 3: Update debugger template**

Modify `strategy-debugger-cli/src/hushine_debugger/templates/strategy.py.template`:

```python
from strategy_service.types import Exchange, Market, OrderDecision, OrderSide, OrderType, PositionSide


class MyStrategy:
    INPUTS = [
        {"exchange": Exchange.BINANCE, "market": Market.PERPETUAL_FUTURES, "symbol": "ETHUSDT", "interval": "1m"}
    ]
    ORDER_TARGETS = [
        {"exchange": Exchange.BINANCE, "market": Market.PERPETUAL_FUTURES, "symbol": "ETHUSDT"}
    ]

    def on_market_data(self, data, wallet):
        tick = data.exchange[Exchange.BINANCE][Market.PERPETUAL_FUTURES].symbol["ETHUSDT"].interval["1m"]
        futures_wallet = wallet.get(Exchange.BINANCE, Market.PERPETUAL_FUTURES)
        if tick is None:
            return None
        return None
```

- [x] **Step 4: Update debugger market defaults**

Replace default `futures` with `perpetual_futures` in:

- `strategy-debugger-cli/src/hushine_debugger/config.py`
- `strategy-debugger-cli/src/hushine_debugger/demo_data.py`
- `strategy-debugger-cli/src/hushine_debugger/import_package.py`
- `strategy-debugger-cli/src/hushine_debugger/replay.py`

Use:

```python
DEFAULT_MARKET = "perpetual_futures"
```

- [x] **Step 5: Update gateway debug package**

Modify `gateway/quant-handler/internal/app/debug_package.go` to generate the same Phase 3 template and include `ORDER_TARGETS`.

- [x] **Step 6: Run debugger/gateway tests**

Run:

```bash
cd strategy-debugger-cli && pytest -q
cd ../gateway/quant-handler && go test ./internal/app -run 'Debug|Package' -count=1
```

Expected:

- PASS.

- [x] **Step 7: Commit debugger hard cut**

Run:

```bash
cd strategy-debugger-cli
git add src tests README.md
git commit -m "feat: update debugger templates for phase 3 api"

cd ../gateway/quant-handler
git add internal/app/debug_package.go internal/app/debug_package_test.go
git commit -m "feat: generate phase 3 debugger packages"
```

## Task 13: Gateway and Frontend Run Strategy Updates

**Files:**
- Modify: `gateway/quant-handler/internal/app/strategy.go`
- Modify: `gateway/quant-handler/internal/app/session_history.go`
- Modify: `gateway/quant-handler/internal/app/strategy_test.go`
- Modify: `gateway/quant-frontend/src/api/client.ts`
- Modify: `gateway/quant-frontend/src/pages/AccountDetail.tsx`
- Modify: `gateway/quant-frontend/src/pages/SessionDetailPage.tsx`
- Modify: `gateway/quant-frontend/src/pages/OrderHistory.tsx`

- [x] **Step 1: Add BFF tests for Phase 3 declarations**

In `gateway/quant-handler/internal/app/strategy_test.go`, add test asserting preview output contains:

```go
wantInput := map[string]any{
    "exchange": "binance",
    "market": "perpetual_futures",
    "symbol": "ETHUSDT",
    "interval": "1m",
}
wantTarget := map[string]any{
    "exchange": "binance",
    "market": "perpetual_futures",
    "symbol": "ETHUSDT",
}
```

- [x] **Step 2: Run BFF tests and verify failure**

Run:

```bash
cd gateway/quant-handler && go test ./internal/app -run Strategy -count=1
```

Expected:

- FAIL until strategy declaration mapping includes `ORDER_TARGETS`.

- [x] **Step 3: Update BFF mapping**

Modify strategy preview/start response JSON to include:

```json
{
  "inputs": [{"exchange":"binance","market":"perpetual_futures","symbol":"ETHUSDT","interval":"1m"}],
  "order_targets": [{"exchange":"binance","market":"perpetual_futures","symbol":"ETHUSDT"}],
  "required_routes": [{"exchange":"binance","market":"perpetual_futures"}]
}
```

- [x] **Step 4: Update frontend API types**

Modify `gateway/quant-frontend/src/api/client.ts`:

```ts
export type StrategyInputDeclaration = {
  exchange: string;
  market: string;
  symbol: string;
  interval: string;
};

export type StrategyOrderTargetDeclaration = {
  exchange: string;
  market: string;
  symbol: string;
};
```

- [x] **Step 5: Update AccountDetail Run Strategy UI**

In `AccountDetail.tsx`, show:

- bound account venues;
- strategy inputs;
- strategy order targets;
- preflight issues grouped by exchange/market/symbol.

Remove hardcoded payloads using:

```ts
market: "futures"
```

Replace with:

```ts
market: "perpetual_futures"
```

where a literal payload is still required by API.

- [x] **Step 6: Update Session/Order route facts**

Ensure `SessionDetailPage.tsx` and `OrderHistory.tsx` display:

- `exchange`
- `market`
- `venue_id`
- `position_side`

Do not display `venue -` placeholders when BFF has route facts.

- [x] **Step 7: Run frontend and BFF tests**

Run:

```bash
cd gateway/quant-handler && go test ./...
cd ../quant-frontend && npm run build
```

Expected:

- PASS.

- [x] **Step 8: Commit gateway/frontend updates**

Run:

```bash
cd gateway/quant-handler
git add internal/app
git commit -m "feat: expose phase 3 strategy declarations"

cd ../quant-frontend
git add src
git commit -m "feat: show phase 3 venue strategy preflight"
```

## Task 14: Final Residual Cleanup

**Files:**
- Modify any file still failing residual scan.
- Likely files:
  - `strategy-library/hushine_strategy/inputs.py`
  - `strategy-library/hushine_strategy/types.py`
  - `strategy-service/strategy_service/strategy/base.py`
  - `strategy-service/strategy_templates/eth_pyramid_futures.py`
  - `strategy-debugger-cli/README.md`
  - `gateway/quant-handler/README.md`
  - `gateway/quant-frontend/src/pages/AccountDetail.tsx`

- [x] **Step 1: Run strict residual scan**

Run:

```bash
rg -n 'market="futures"|market='"'"'futures'"'"'|data\\.market\\[|self\\.market = _MarketNode|VenueWalletView|wallet\\.futures|wallet\\.spot|get_wallet_balance\\(|get_available_balance\\(' \
  strategy-service strategy-library strategy-debugger-cli gateway/quant-handler gateway/quant-frontend \
  -g '!**/.git/**' \
  -g '!**/docs/**'
```

Expected:

- No matches in normal runtime code, templates, or tests except negative tests that explicitly assert rejection.

- [x] **Step 2: Run mode/path residual scan**

Run:

```bash
rg -n 'GetOnlineAccountInfo|UpdateAccountWalletState|ACCOUNT_GET_ONLINE|ACCOUNT_UPDATE_WALLET|GetAccountMeta\\(' \
  strategy-service gateway/quant-handler \
  -g '!**/.git/**'
```

Expected:

- No matches in normal strategy startup, order settlement, periodic snapshot, debugger template generation, or account wallet display.
- Generated stubs and explicit legacy/admin helpers may remain if not called by Phase 3 normal paths.

- [x] **Step 3: Fix any remaining normal-path residual**

For each residual:

1. Identify whether it is generated code, negative test, historical doc, or normal runtime.
2. If normal runtime, replace it with Phase 3 path.
3. If historical doc, mark it as archived or remove it from user-facing docs.

Example replacement:

```python
# Old
tick = data.market["futures"].symbol["ETHUSDT"].interval["1m"]

# New
tick = data.exchange[Exchange.BINANCE][Market.PERPETUAL_FUTURES].symbol["ETHUSDT"].interval["1m"]
```

- [x] **Step 4: Commit residual cleanup**

Run commits in each affected repo with the concrete likely file set:

```bash
cd strategy-service
git add strategy_service strategy_templates scripts tests README.md
git commit -m "refactor: remove phase 2 strategy runtime leftovers"

cd ../strategy-library
git add hushine_strategy tests README.md
git commit -m "refactor: remove legacy futures strategy api"

cd ../strategy-debugger-cli
git add src tests README.md
git commit -m "refactor: remove legacy debugger strategy api"

cd ../gateway/quant-handler
git add internal/app README.md
git commit -m "refactor: remove legacy strategy route payloads"

cd ../quant-frontend
git add src README.md
git commit -m "refactor: remove legacy strategy route ui"
```

**Task 14 Result (2026-05-31):**

- Residual scan still shows expected generated stubs, historical docs, wallet implementation internals, negative tests, and market-data storage tests using the internal `"futures"` storage key.
- Fixed one normal runtime residual: `Stop + close positions` now requires `PortfolioWalletRuntime`, builds close orders per `(exchange, market, venue_id)`, sends `perpetual_futures` decisions, and settles fills back into the matching route wallet.
- Updated `quant-handler` README to remove stale account `mode` / legacy wallet-update wording from user-facing API notes.
- Verification:
  - `strategy-service`: targeted stop/preview/preflight tests — `24 passed`
  - `strategy-service`: `python -m compileall -q strategy_service/grpc_server.py`
  - `gateway/quant-handler`: `go test ./internal/app -run '^$' -count=1`
- Commits:
  - `strategy-service`: `2e783b2 fix: close portfolio sessions by route`
  - `gateway/quant-handler`: `273883b docs: update phase 3 account api notes`

## Task 15: Full Verification and Browser Smoke

**Files:**
- No source files unless bugs are found.
- Update docs/smoke notes if needed.

- [x] **Step 1: Run all unit/build tests**

Run:

```bash
cd strategy-library && pytest -q tests/
cd ../strategy-service && PYTHONPATH=.:../strategy-library pytest -q tests/
cd ../core-service && go test ./...
cd ../gateway/quant-handler && go test ./...
cd ../gateway/quant-frontend && npm run build
cd ../../strategy-debugger-cli && pytest -q
```

Expected:

- All pass.

- [x] **Step 2: Start local stack**

Run from repo root:

```bash
./restart.sh
```

Expected:

- core-service, strategy-service, quant-handler, control-panel-service, frontend dev server, and dependencies are reachable.

- [x] **Step 3: Browser smoke setup**

Using Chrome DevTools / Browser plugin:

1. Login as `test-user` with password `123qwe`.
2. Create a backtest account named `phase3-smoke-manual`.
3. Confirm the account has or create:
   - Binance spot simulated venue.
   - Binance perpetual futures simulated venue.
4. Create a Phase 3 strategy:

```python
from strategy_service.types import Exchange, Market, OrderDecision, OrderSide, OrderType, PositionSide


class MyStrategy:
    INPUTS = [
        {"exchange": Exchange.BINANCE, "market": Market.PERPETUAL_FUTURES, "symbol": "ETHUSDT", "interval": "1m"}
    ]
    ORDER_TARGETS = [
        {"exchange": Exchange.BINANCE, "market": Market.PERPETUAL_FUTURES, "symbol": "ETHUSDT"},
        {"exchange": Exchange.BINANCE, "market": Market.SPOT, "symbol": "ETHUSDT"},
    ]

    def __init__(self):
        self._sent = False

    def on_market_data(self, data, wallet):
        tick = data.exchange[Exchange.BINANCE][Market.PERPETUAL_FUTURES].symbol["ETHUSDT"].interval["1m"]
        futures_wallet = wallet.get(Exchange.BINANCE, Market.PERPETUAL_FUTURES)
        spot_wallet = wallet.get(Exchange.BINANCE, Market.SPOT)
        if tick is None or self._sent:
            return None
        self._sent = True
        return OrderDecision(
            exchange=Exchange.BINANCE,
            market=Market.PERPETUAL_FUTURES,
            symbol="ETHUSDT",
            side=OrderSide.BUY,
            qty="0.01",
            order_type=OrderType.MARKET,
            position_side=PositionSide.BOTH,
        )
```

5. Download/verify ETHUSDT perpetual futures 1m historical coverage for a one-day range.
6. Create hosted runtime.
7. Start backtest from Account Detail.

- [x] **Step 4: Browser smoke assertions**

Expected UI result:

- Run Strategy page shows both bound venues.
- Run Strategy page shows strategy inputs and order targets.
- Preflight passes.
- Session reaches `FINISHED`.
- Order History contains route facts:
  - `exchange=binance`
  - `market=perpetual_futures`
  - `venue_id` is present
  - `position_side=BOTH`
- Session Detail shows route facts and no placeholder `venue -`.

- [x] **Step 5: Negative preflight smoke**

Create a read/write strategy with `ORDER_TARGETS` targeting Binance spot, then unbind/disable the Binance spot venue and start it.

Expected:

- UI shows failure.
- Session Management shows a `preflight_failed` session.
- Failure includes structured message for missing spot venue.

- [x] **Step 6: Stop services and clean runtime**

Run:

```bash
make stop
```

If hosted runtime containers remain, clean them through Runtime Management first; use Docker cleanup only if the control plane is already stopped.

- [x] **Step 7: Commit smoke notes**

If docs are updated:

```bash
git -C hushine-deploy add docs
git -C hushine-deploy commit -m "docs: record phase 3 smoke results"
```

**Task 15 Result (2026-05-30):**

- Full verification:
  - `strategy-library`: `pytest -q tests/` — `90 passed`
  - `strategy-service`: `PYTHONPATH=.:../strategy-library pytest -q tests/` — `428 passed`
  - `core-service`: `go test ./...` — passed
  - `gateway/quant-handler`: `go test ./...` — passed
  - `gateway/quant-frontend`: `npm run build` — passed
  - `strategy-debugger-cli`: `PYTHONPATH=src:../strategy-library pytest -q` — `39 passed`
- Browser smoke:
  - User: `test-user`
  - Account: `phase3-smoke-funded-20260530223032` (`account_id=56`)
  - Strategy: `phase3-browser-smoke-perp-20260530221224` (`strategy_id=39`)
  - Data: Binance `ETHUSDT` `perpetual_futures` `1m`, `2026-05-30 00:00:00` → `2026-05-31 00:00:00`
  - Coverage check: `1440/1440`, `COMPLETE`
  - Runtime: hosted executor `rt-74a9462119296c1eb17a572d`
  - Session: `4da4c4c16d634d589585bb9edfa77220`, `FINISHED`, `bars_processed=1440`
  - Order History and Session Detail show route facts: `binance / perpetual_futures`, `venue 37`, `position BOTH`, account/session links present.
- Negative preflight smoke:
  - Account: `phase3-negative-no-spot-1780182464107` (`account_id=61`)
  - Strategy: `phase3-negative-spot-target-1780182464107` (`strategy_id=41`)
  - Spot venue released before run.
  - Run failed before execution with `VENUE_MISSING: active venue is missing exchange=1 market=1`.
  - Session: `f237ef7c898c4e1094157c2e85776714`, status `preflight_failed`, error `active venue is missing`.
- Cleanup:
  - Hosted smoke runtime `rt-74a9462119296c1eb17a572d` ended through Runtime Management API; Docker runtime container list is empty.
  - `make stop` completed: core-service, control-panel-service, strategy-service, quant-handler, quant-frontend, and scraper stopped.
- Bugs found and fixed during smoke:
  - `control-panel-service` RuntimeChannel proxy did not implement `account.PreflightStrategySession`, causing hosted runtime preflight to fail.
  - `gateway/quant-handler` backtest account creation wrote account rows but did not bootstrap wallet state, leaving futures venue snapshots empty.
  - `strategy-service` portfolio snapshot adapter validated unrequested venue snapshots before applying `allowed_routes`.
  - `strategy-service` proxy-delivered market-data used storage market `futures` inside the strategy API instead of canonical `perpetual_futures`.
  - `strategy-service` runtime `InputView` lacked the `data.exchange[exchange][market]` shorthand that `strategy-library` exposes.

## Final Acceptance Criteria

Phase 3 is complete when:

1. Public strategy API requires constants, `INPUTS`, and `ORDER_TARGETS`.
2. `market="futures"` is rejected in strategy declarations.
3. `data.market[...]` is gone from user-facing strategy runtime.
4. `wallet.get(exchange, market)` is the only wallet access API for strategies.
5. `PortfolioWalletRuntime` reads from multiple `VenueSnapshot` records.
6. Normal strategy sessions call `GetPortfolioSnapshot` and `UpdatePortfolioSnapshot`.
7. Normal strategy sessions do not call `GetOnlineAccountInfo` or `UpdateAccountWalletState`.
8. `OrderDecision` requires explicit route fields and string `qty`/`price`.
9. `list[OrderDecision]` is supported as independent ordinary orders.
10. Lifecycle fills update the correct venue wallet.
11. Unresolved orders block `(account_id, exchange, market, symbol)`.
12. Preflight failures create visible `preflight_failed` session records.
13. Templates/debugger/debug package use the Phase 3 API.
14. Unit/build tests pass in all affected repos.
15. Browser smoke passes with one account containing Binance spot and Binance perpetual futures venues.
