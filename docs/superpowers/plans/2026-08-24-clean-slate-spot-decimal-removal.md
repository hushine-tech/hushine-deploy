# Clean-Slate Spot and Decimal Removal Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Remove Spot wallet dual shapes and exact-or-float fallbacks so Binance asset codes and exact decimal strings are the only first-party business-value contract.

**Architecture:** HTTP/gRPC/database boundaries carry canonical asset codes and exact decimal text. Core and strategy runtimes parse exact values once for calculation, while the frontend renders exact text directly; no wallet aliases or parallel float fields remain.

**Tech Stack:** Protocol Buffers, Go `math/big`, Python `decimal.Decimal`, PostgreSQL numeric, TypeScript/React

**Spec:** `docs/superpowers/specs/2026-08-24-clean-slate-compatibility-removal-design.md`

## Global Constraints

- Preserve Binance Spot behavior, Futures risk math, filters, fills, fees, reconciliation, and supported order/time-in-force combinations.
- `asset` is a balance identity; pairs such as `BTCUSDT` remain market-data and order identities.
- Exact decimal text is authoritative at first-party boundaries. Parsing for calculation is allowed; a second float field is not.
- Never round before Binance filter validation or persistence.
- Generated protobuf artifacts are regenerated, never hand-edited.

---

### Task 1: Pin canonical Spot and decimal schemas

**Files:**
- Modify: `strategy-service/tests/test_generated_proto_imports.py`
- Modify: `core-service/internal/domain/spot_wallet_test.go`
- Modify: `core-service/internal/order/service/exact_decimal_test.go`
- Create: `gateway/quant-frontend/scripts/order-history-contract.test.mjs`
- Modify: `gateway/quant-handler/internal/app/order_history_test.go`

**Interfaces:**
- Consumes: current generated portfolio/order descriptors and JSON/domain adapters.
- Produces: failing tests that require old wallet aliases and duplicate numeric fields to be absent.

- [ ] **Step 1: Assert old Spot fields are absent from protobuf**

```python
from strategy_service.gen import order_service_pb2 as order_pb2
from strategy_service.gen import portfolio_service_pb2 as portfolio_pb2

def test_spot_wallet_uses_only_canonical_assets_and_exact_balances():
    wallet = portfolio_pb2.SpotWallet.DESCRIPTOR.fields_by_name
    asset = portfolio_pb2.SpotAsset.DESCRIPTOR.fields_by_name
    assert "free" not in wallet
    assert "locked" not in wallet
    assert "symbol" not in asset
    assert "qty" not in asset
    assert "free" not in asset
    assert "locked" not in asset
    assert {"asset", "free_decimal", "locked_decimal"} <= set(asset)
```

- [ ] **Step 2: Assert order protocol contains only exact business-value fields**

For `PlaceOrderRequest`, `OrderIntentEntry`, `OrderAttemptEntry`, `OrderEntry`, `FillEntry`, `FillDelta`, and `OrderStateDelta`, assert old double quantity/price/fee fields are absent and `*_decimal` fields remain.

```python
assert "qty" not in order_pb2.PlaceOrderRequest.DESCRIPTOR.fields_by_name
assert "qty_decimal" in order_pb2.PlaceOrderRequest.DESCRIPTOR.fields_by_name
assert "fee" not in order_pb2.FillEntry.DESCRIPTOR.fields_by_name
assert "fee_decimal" in order_pb2.FillEntry.DESCRIPTOR.fields_by_name
```

- [ ] **Step 3: Replace dual-shape Spot tests with canonical-only tests**

```go
func TestSpotWalletAcceptsCanonicalAssetsOnly(t *testing.T) {
    wallet := SpotWallet{Assets: []SpotAsset{{
        Asset: "BTC", FreeDecimal: "1.25", LockedDecimal: "0.10",
    }}}
    if err := wallet.Validate(); err != nil {
        t.Fatal(err)
    }
}
```

Add a JSON boundary test proving `symbol`, `qty`, and wallet-level `free/locked` are rejected by the shared strict request decoder.

- [ ] **Step 4: Run focused tests and verify RED**

```bash
cd strategy-service
PYTHONPATH=.:../strategy-library uv run --frozen --extra dev pytest tests/test_generated_proto_imports.py -q
cd ../core-service
go test ./internal/domain ./internal/order/service -run 'SpotWallet|ExactDecimal' -count=1
cd ../gateway/quant-handler
go test ./internal/app -run 'OrderHistory|Spot' -count=1
cd ../quant-frontend
node scripts/order-history-contract.test.mjs
```

Expected: old protobuf fields, dual-shape JSON, and float fallbacks make the tests fail.

- [ ] **Step 5: Commit the red tests**

Commit `test: require canonical spot decimal contracts` in strategy-service, core-service, quant-handler, and quant-frontend.

### Task 2: Remove old Spot wallet shapes from core and protobuf

**Files:**
- Modify: `core-service/proto/portfolio_service.proto`
- Modify: `core-service/internal/domain/model.go`
- Delete or replace: `core-service/internal/domain/spot_wallet.go`
- Modify: `core-service/internal/service/grpc.go`
- Modify: `core-service/internal/repository/timescale.go`
- Modify: `core-service/internal/exchange/binance.go`
- Modify: `core-service/internal/exchange/binance/portfolio_snapshot.go`
- Modify: `core-service/internal/reconciliation/**`
- Regenerate: `core-service/gen/portfoliov1/**`
- Modify: `core-service/internal/domain/spot_wallet_test.go`
- Modify: `core-service/internal/exchange/binance_test.go`
- Modify: `core-service/internal/repository/spot_repair_test.go`
- Modify: `core-service/internal/service/portfolio_snapshot_test.go`
- Modify: `core-service/internal/service/wallet_state_proto_test.go`
- Modify: `core-service/internal/reconciliation/spot_coordinator_test.go`

**Interfaces:**
- Consumes: Binance account balances with asset/free/locked text.
- Produces: canonical `SpotWallet{Assets []SpotAsset}` and exact protobuf fields.

- [ ] **Step 1: Simplify authored portfolio protobuf**

```proto
message SpotWallet {
  repeated SpotAsset assets = 1;
}

message SpotAsset {
  string asset = 1;
  string free_decimal = 2;
  string locked_decimal = 3;
  string avg_entry_price_decimal = 4;
  optional string price_decimal = 5;
}
```

No old field reservation is required.

- [ ] **Step 2: Regenerate core and strategy copies**

```bash
cd core-service && make proto-portfolio
cd ../strategy-service && PYTHON=.venv/bin/python ./generate_proto.sh
```

- [ ] **Step 3: Replace the domain model**

```go
type SpotAsset struct {
    Asset                string  `json:"asset"`
    FreeDecimal          string  `json:"free_decimal"`
    LockedDecimal        string  `json:"locked_decimal"`
    AvgEntryPriceDecimal string  `json:"avg_entry_price_decimal,omitempty"`
    PriceDecimal         *string `json:"price_decimal,omitempty"`
}

type SpotWallet struct {
    Assets []SpotAsset `json:"assets"`
}
```

Delete custom dual-shape JSON, `Canonicalized`, `syncLegacyFields`, `Symbol`, `Qty`, wallet-level balances, and conflict checks. Retain one `Validate() error` method for uppercase unique assets and non-negative decimals.

- [ ] **Step 4: Update Binance snapshot and core consumers**

Map Binance text directly into the canonical domain. Calculations parse exact values locally and never write a second authoritative field.

- [ ] **Step 5: Run core Spot tests**

```bash
cd core-service
go test ./internal/domain ./internal/service ./internal/exchange/binance ./internal/reconciliation -run 'Spot|PortfolioSnapshot|Wallet' -count=1
go vet ./internal/domain ./internal/service/... ./internal/exchange/binance/...
```

- [ ] **Step 6: Commit canonical Spot wallet changes**

Commit `refactor: keep canonical spot assets only` in core-service and `build: regenerate canonical spot wallet protocol` in strategy-service.

### Task 3: Remove float duplicates from order protocol and core execution

**Files:**
- Modify: `core-service/proto/order_service.proto`
- Regenerate: `core-service/gen/orderv1/**`
- Regenerate: `strategy-service/strategy_service/gen/order_service_pb2*.py`
- Modify: `core-service/internal/order/risk/decimal.go`
- Modify: `core-service/internal/order/risk/spot_filters.go`
- Modify: `core-service/internal/order/service/grpc.go`
- Modify: `core-service/internal/order/repository/decimal_binds.go`
- Modify: `core-service/internal/order/repository/timescale.go`
- Modify: `core-service/internal/exchange/binance/order_executor.go`
- Modify: `core-service/internal/order/lifecycle/user_data_ingestor.go`
- Modify: `core-service/internal/reconciliation/**`
- Modify: `core-service/internal/order/risk/decimal_test.go`
- Modify: `core-service/internal/order/risk/spot_filter_contract_test.go`
- Modify: `core-service/internal/order/risk/spot_filters_test.go`
- Modify: `core-service/internal/order/service/exact_decimal_test.go`
- Modify: `core-service/internal/order/service/protocol_contract_test.go`
- Modify: `core-service/internal/order/repository/lifecycle_events_test.go`
- Modify: `core-service/internal/reconciliation/diff_test.go`

**Interfaces:**
- Consumes: exact strings at gRPC and exchange event boundaries.
- Produces: exact strings through risk, persistence, lifecycle, and reconciliation.

- [ ] **Step 1: Delete duplicate double fields from `order_service.proto`**

Keep only decimal fields for quantity, price, mark price, requested/original/executed/remaining/average values, fees, fills, and quote quantities.

- [ ] **Step 2: Regenerate order stubs**

```bash
cd core-service && make proto-order
cd ../strategy-service && PYTHON=.venv/bin/python ./generate_proto.sh
```

- [ ] **Step 3: Replace exact-or-legacy normalization**

```go
func CanonicalUnsignedDecimal(exact string) (string, error) {
    if err := validateNumeric38Scale18(exact); err != nil {
        return "", fmt.Errorf("%w: %v", ErrDecimalOutOfRange, err)
    }
    return exact, nil
}
```

Keep exact zero/positive helpers based on `big.Rat`. Delete `ErrDecimalConflict`, float presence/equality logic, and float-to-string fallback.

- [ ] **Step 4: Make risk, repository, exchange, and reconciliation exact-only**

Risk gates parse exact strings; SQL binds pass strings to numeric columns; Binance parameters use exact strings directly; user-data ingestion requires exact event decimals; reconciliation compares exact values.

- [ ] **Step 5: Run order and mock-exchange tests**

```bash
cd core-service
go test ./internal/order/... ./internal/exchange/binance/... ./internal/reconciliation/... -count=1
go vet ./internal/order/... ./internal/exchange/binance/... ./internal/reconciliation/...
```

Expected: MARKET/LIMIT, GTC/IOC/FOK, filters, partial fills, fees, and reconciliation remain green.

- [ ] **Step 6: Commit exact-only protocol changes**

Commit `refactor: remove float order compatibility` in core-service and regenerate strategy-service order stubs in a `build:` commit.

### Task 4: Update strategy wallets and worker order creation

**Files:**
- Modify: `strategy-service/strategy_service/wallet/canonical.py`
- Modify: `strategy-service/strategy_service/wallet/spot.py`
- Modify: `strategy-service/strategy_service/wallet/runtime.py`
- Modify: `strategy-service/strategy_service/wallet/binance.py`
- Modify: `strategy-service/strategy_service/strategy/base.py`
- Modify: `strategy-service/strategy_service/grpc_server.py`
- Modify: `strategy-service/tests/helpers/wallet_fixtures.py`
- Modify: `strategy-service/tests/test_wallet_runtime.py`
- Modify: `strategy-service/tests/test_wallet_strict_rules.py`
- Modify: `strategy-service/tests/test_mode0_parity_cutover.py`
- Modify: `strategy-library/hushine_strategy/replay/engine.py`
- Modify: `strategy-library/hushine_strategy/wallet/portfolio.py`
- Modify: `strategy-library/hushine_strategy/wallet/spot.py`
- Modify: `strategy-library/hushine_strategy/wallet/futures.py`
- Modify: `strategy-library/tests/hushine_strategy/test_mixed_route_replay.py`
- Modify: `strategy-library/tests/hushine_strategy/test_replay.py`
- Modify: `strategy-library/tests/hushine_strategy/test_spot_wallet.py`

**Interfaces:**
- Consumes: canonical Spot assets and exact order protocol.
- Produces: one wallet representation and exact order request values.

- [ ] **Step 1: Delete pseudo-asset and fixture fallbacks**

Remove wallet-level USDT, `symbol/qty`, old in-memory snapshot reads, synthetic compatibility trade identities, and fixture alias assignment.

- [ ] **Step 2: Canonicalize user strategy numeric output once**

```python
def canonical_decimal_text(value: int | float | Decimal | str) -> str:
    decimal_value = Decimal(str(value))
    if not decimal_value.is_finite() or decimal_value < 0:
        raise ValueError("a finite non-negative decimal is required")
    return format(decimal_value, "f")
```

Order requests carry only canonical strings after this worker boundary.

- [ ] **Step 3: Preserve current calculations**

Spot free/locked, Futures wallet balance, margin balance, UPnL, fees, liquidation, and per-target sizing calculate from parsed exact values and confirmed leverage facts.

- [ ] **Step 4: Run strategy/library suites**

```bash
cd strategy-service
PYTHONPATH=.:../strategy-library uv run --frozen --extra dev pytest \
  tests/test_wallet_runtime.py tests/test_wallet_strict_rules.py \
  tests/test_mode0_parity_cutover.py tests/test_grpc_server.py -q
cd ../strategy-library
uv run --frozen pytest -q
```

- [ ] **Step 5: Commit strategy and library changes**

Commit `refactor: remove wallet compatibility shapes` in both repositories.

### Task 5: Remove gateway/UI fallbacks

**Files:**
- Modify: `gateway/quant-handler/internal/app/order_history.go`
- Modify: `gateway/quant-handler/internal/app/session_history.go`
- Modify: `gateway/quant-handler/internal/app/venues.go`
- Modify: `gateway/quant-handler/internal/walletagg/totalvalue.go`
- Modify: `gateway/quant-handler/internal/app/order_history_test.go`
- Modify: `gateway/quant-handler/internal/app/session_history_test.go`
- Modify: `gateway/quant-handler/internal/app/venues_test.go`
- Modify: `gateway/quant-handler/internal/app/portfolios_ext_test.go`
- Modify: `gateway/quant-frontend/src/api/client.ts`
- Modify: `gateway/quant-frontend/src/components/OrderTree.tsx`
- Modify: `gateway/quant-frontend/src/pages/SessionDetailPage.tsx`
- Modify: `gateway/quant-frontend/src/pages/VenueManagement.tsx`
- Modify frontend order-history, Spot-wallet, and venue-form scripts.

**Interfaces:**
- Consumes: exact-string order/fill/session JSON and canonical Spot assets.
- Produces: direct exact rendering and strategy-owned leverage UX.

- [ ] **Step 1: Delete gateway fallback helpers**

Delete `exactDecimalOrLegacy`, `optionalExactDecimalOrLegacy`, float product fallbacks, old Spot initial-balance payloads, and JSON float fields. Map exact protobuf strings directly.

- [ ] **Step 2: Make frontend rendering exact-only**

```typescript
export function exactDecimalText(exact: string | null | undefined): string {
  return typeof exact === "string" && exact.trim() !== "" ? exact : "-";
}
```

Update all call sites to one argument.

- [ ] **Step 3: Remove venue-level leverage and old wallet inputs**

Delete the leverage column/input from `VenueManagement.tsx` and old wallet bootstrap payload fields. Strategy source remains the only leverage authority.

- [ ] **Step 4: Run gateway/frontend tests**

```bash
cd gateway/quant-handler
go test ./internal/app ./internal/walletagg -count=1
go vet ./internal/app/... ./internal/walletagg/...
cd ../quant-frontend
for test_file in scripts/*.test.mjs; do node "$test_file"; done
npm run build
```

- [ ] **Step 5: Commit gateway/frontend changes**

Commit `refactor: expose canonical decimal values only` in both repositories.

### Task 6: Run the Spot/decimal phase gate

**Files:**
- Modify only to fix current-contract regressions.

**Interfaces:**
- Consumes: Tasks 1–5.
- Produces: canonical Spot and exact-value behavior ready for baseline collapse.

- [ ] **Step 1: Sweep compatibility symbols**

```bash
rg -n 'exactDecimalOrLegacy|optionalExactDecimalOrLegacy|exactOrLegacyDecimal|NormalizeAuthoritativeDecimal|ErrDecimalConflict|syncLegacyFields' \
  core-service strategy-service gateway
```

Expected: no production match.

- [ ] **Step 2: Verify descriptors have one field per value**

Run the descriptor tests and require every order/wallet business value to have exactly one canonical field.

- [ ] **Step 3: Run full suites**

```bash
cd core-service && go test ./... && go vet ./...
cd ../strategy-service && make test
cd ../strategy-library && uv run --frozen pytest -q
cd ../gateway/quant-handler && go test ./... && go vet ./...
cd ../quant-frontend && for test_file in scripts/*.test.mjs; do node "$test_file"; done && npm run build
```

- [ ] **Step 4: Record handwritten, generated, and test line reduction separately**

Capture these repository-scoped totals for the final report:

```bash
git -C core-service diff --numstat 6b7b6aec02bad86d363627f3f0ca7465556ee5fa...HEAD
git -C strategy-service diff --numstat 4d2835ad099eed41760b34b0975d7ef0e69ec91d...HEAD
git -C strategy-library diff --numstat cb89b4c3413f6cd9bba4aab2da589862c048ba76...HEAD
git -C gateway/quant-handler diff --numstat 74575981de53f5cb4313171895718d03d2ff4d0c...HEAD
git -C gateway/quant-frontend diff --numstat 6e59bd1a5c55e65a0041722fffae07996b90be54...HEAD
```
