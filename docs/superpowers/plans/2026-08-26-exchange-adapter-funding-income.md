# Exchange Adapter Funding Income Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use `superpowers:executing-plans` to execute this plan task by task. Use `superpowers:test-driven-development` for every behavior change, `superpowers:systematic-debugging` for every unexpected failure, and `superpowers:verification-before-completion` before each completion claim.

**Goal:** Add exchange-adapter-owned Funding Fee settlement for Futures Backtest, Demo, and Live; persist one generic Venue Income history; reconcile Binance push and REST facts without duplicate wallet effects; deliver confirmed Income through RuntimeChannel; and preserve all Spot and order execution behavior.

**Architecture:** `core-service` owns canonical Income coordination, idempotent persistence, wallet application, and the exchange capability Registry. Binance-specific REST, WebSocket parsing, formula, rounding, and real-total-to-leg allocation stay inside the Binance Adapter. `scraper` stores exact historical Funding facts through its Exchange Adapter. `control-panel-service` queries Funding facts for Backtest and delivers confirmed Income to Runtime Agents. The Go Runtime Agent only forwards frames; the Python Worker maintains an exact position projection, calls the platform for Backtest settlement, and applies each returned Income once using a cursor persisted in the existing canonical wallet snapshot.

**Tech Stack:** Go 1.x, Python 3.13, gRPC/Protocol Buffers, PostgreSQL/TimescaleDB, Binance USDⓈ-M REST/WebSocket, `math/big`, pytest, Go test, existing Binance mock server, Docker Compose.

**Approved spec:** `docs/superpowers/specs/2026-08-26-exchange-adapter-funding-income-design.md`

---

## Execution constraints

- Work in `/Users/xdy/Workplace/hushine-worktrees/medium-cleanup`; the root is not a Git repository.
- Repositories in scope: `core-service`, `scraper`, `control-panel-service`, `strategy-service`, and `hushine-deploy`.
- Do not modify `strategy-debugger-cli`; it is no longer maintained.
- Do not add compatibility branches or dual protocols. The product is not live; update the current baseline, generated bindings, callers, and tests atomically.
- Do not add Binance URLs, event names, Funding formulae, interval assumptions, or rounding rules to common coordinator/runtime code.
- Keep OKX fail-closed. An OKX Futures Session requiring Funding must fail preflight until its Adapter implements all required capabilities.
- Funding applies only to Futures. Spot must never acquire Funding events or ledger mutations.
- Use decimal strings at every protocol/storage boundary. Convert to `float64` only at existing presentation boundaries.
- Add exactly one business table: `venue_income_entries`. Persist the Worker replay cursor inside the existing canonical Futures Wallet snapshot.
- Preserve the current order path and its Mock Binance coverage for GTC, IOC, FOK, GTX, partial fill, full fill, cancel, liquidation, and ADL.
- Stage and commit only files owned by the current task in each repository.

## Canonical type contract

Use these names consistently across the plan. Generated language naming may follow protobuf conventions, but field meaning must not change.

```go
// core-service/internal/exchange/adapter/funding.go
type UserDataEventKind string

const (
	UserDataEventOrderUpdate   UserDataEventKind = "order_update"
	UserDataEventAccountUpdate UserDataEventKind = "account_update"
)

type UserDataEvent struct {
	Kind          UserDataEventKind
	EventTime     time.Time
	TransactionTime time.Time
	Order         *UserDataOrderEvent
	Account       *UserDataAccountEvent
}

type UserDataAccountEvent struct {
	Reason      string
	Balances    []AccountBalanceChange
	Positions   []AccountPositionChange
	RawPayload  json.RawMessage
}

type IncomeHistoryRequest struct {
	Route      Route
	Credential ParsedCredential
	IncomeType string
	StartTime  time.Time
	EndTime    time.Time
	Page       int
	Limit      int
}

type IncomeRecord struct {
	ExternalTransactionID string
	IncomeType             string
	Symbol                 string
	Asset                  string
	SignedAmountDecimal    string
	OccurredAt             time.Time
	RawPayload             json.RawMessage
}

type FundingPositionLeg struct {
	Symbol            string
	PositionSide      string
	MarginMode        string
	SignedQtyDecimal  string
}

type FundingSettlementRequest struct {
	Route               Route
	FundingTime         time.Time
	FundingRateDecimal  string
	MarkPriceDecimal    string
	SettlementAsset     string
	PositionMode        string
	PositionLegs        []FundingPositionLeg
	ActualAmountDecimal *string
}

type FundingSettlementLeg struct {
	Symbol                  string
	PositionSide            string
	MarginMode              string
	SignedQtyDecimal        string
	CalculatedAmountDecimal string
	AppliedAmountDecimal    string
}

type FundingSettlementResult struct {
	Legs                       []FundingSettlementLeg
	CalculatedAmountDecimal    string
	AppliedAmountDecimal       string
	ReconciliationDeltaDecimal string
	CalculatorVersion          string
}
```

```go
type IncomeHistoryReader interface {
	ListIncome(context.Context, IncomeHistoryRequest) (IncomeHistoryPage, error)
}

type FundingSettlementCalculator interface {
	CalculateFundingSettlement(context.Context, FundingSettlementRequest) (FundingSettlementResult, error)
}
```

For Binance, calculate each leg as `-signed_qty * mark_price * funding_rate`. If an exchange actual total is present, start from calculated leg amounts and assign the exact residual to the leg with the greatest absolute calculated amount; ties sort by `symbol`, then `position_side`. This deterministic Adapter-owned rule preserves every calculated leg and guarantees `sum(applied legs) == exchange actual total`, including a zero-net Hedge case.

## Requirement traceability

| Approved requirement | Implemented and verified in |
|---|---|
| Exchange Adapter/Registry boundary | Tasks 1–3, 6, 16 |
| Hedge legs calculated separately | Tasks 2, 6, 12, 16 |
| Cross/Isolated wallet attribution | Tasks 2, 5, 12, 16 |
| One generic Income table | Tasks 4–5 |
| `(session_id, venue_id)` and occurrence-time ownership | Tasks 4–6 |
| `tranId` plus settlement-key idempotency | Tasks 4–6, 16 |
| Account Update trigger plus active REST repair | Tasks 2, 6, 16 |
| 10s/30s/1m/2m/5m retry, 15m poll, 24h grace | Task 6 |
| Backtest Funding before same-time Kline | Tasks 8, 11, 16 |
| Worker-block independence and restart idempotency | Tasks 9–10, 13, 16 |
| Spot and order-mode regressions | Tasks 2, 14, 16 |
| Fresh one-shot database deployment | Tasks 4, 15–16 |
| Binance Demo smoke without checked-in secrets | Task 16 |

---

### Task 1: Add canonical Funding capabilities to the core Exchange Registry

**Files:**

- Create: `../core-service/internal/exchange/adapter/funding.go`
- Create: `../core-service/internal/exchange/adapter/funding_test.go`
- Modify: `../core-service/internal/exchange/adapter/capabilities.go`
- Modify: `../core-service/internal/exchange/adapter/factory.go`
- Modify: `../core-service/internal/exchange/adapter/registry.go`
- Modify: `../core-service/internal/exchange/adapter/registry_test.go`
- Modify: `../core-service/internal/exchange/binance/factory.go`
- Modify: `../core-service/internal/exchange/okx/factory.go`

- [ ] **Step 1: Write failing Registry capability tests**

Add table tests proving:

```go
func TestRegistryFundingCapabilitiesAreBoundByRoute(t *testing.T)
func TestRegistryRejectsFundingCapabilityForSpot(t *testing.T)
func TestRegistryKeepsOKXFundingFailClosed(t *testing.T)
```

The bound capability must overwrite any request route with the Registry-bound `Route`, as existing order capabilities do. Spot and missing optional factories must return a typed unsupported-capability error.

- [ ] **Step 2: Run the focused tests and confirm RED**

```bash
cd ../core-service
go test ./internal/exchange/adapter ./internal/exchange/binance ./internal/exchange/okx
```

Expected: compile/test failure because the Funding types and Registry methods do not exist.

- [ ] **Step 3: Add canonical event and Funding contracts**

Implement the canonical types from this plan plus:

```go
type IncomeHistoryPage struct {
	Records  []IncomeRecord
	Page     int
	HasMore  bool
}

type IncomeHistoryReaderFactory interface {
	IncomeHistoryReader() (IncomeHistoryReader, error)
}

type FundingSettlementCalculatorFactory interface {
	FundingSettlementCalculator() (FundingSettlementCalculator, error)
}
```

Change `UserDataStream.Listen` to emit `UserDataEvent`; do not retain an order-only compatibility callback. Update all current implementations and callers in the same branch.

- [ ] **Step 4: Bind the optional capabilities in Registry**

Add:

```go
func (r *Registry) IncomeHistoryReader(route Route) (IncomeHistoryReader, error)
func (r *Registry) FundingSettlementCalculator(route Route) (FundingSettlementCalculator, error)
```

Reject non-Futures routes before invoking a factory. Binance advertises both capabilities for USDⓈ-M Demo/Live and the calculator for Backtest. OKX returns unsupported.

- [ ] **Step 5: Run tests, formatting, and static checks**

```bash
cd ../core-service
gofmt -w internal/exchange/adapter internal/exchange/binance/factory.go internal/exchange/okx/factory.go
go test ./internal/exchange/adapter ./internal/exchange/binance ./internal/exchange/okx
go vet ./internal/exchange/adapter/... ./internal/exchange/binance/... ./internal/exchange/okx/...
```

- [ ] **Step 6: Commit Task 1**

```bash
git add internal/exchange/adapter internal/exchange/binance/factory.go internal/exchange/okx/factory.go
git commit -m "feat: add canonical funding adapter capabilities"
```

---

### Task 2: Implement Binance exact settlement, Income History, Account Update parsing, and mock behavior

**Files:**

- Create: `../core-service/internal/exchange/binance/funding_calculator.go`
- Create: `../core-service/internal/exchange/binance/funding_calculator_test.go`
- Create: `../core-service/internal/exchange/binance/income_history.go`
- Create: `../core-service/internal/exchange/binance/income_history_test.go`
- Modify: `../core-service/internal/exchange/binance/user_data_events.go`
- Modify: `../core-service/internal/exchange/binance/user_data_events_test.go`
- Modify: `../core-service/internal/exchange/binance/user_data_stream.go`
- Modify: `../core-service/internal/exchange/binance/user_data_stream_client_test.go`
- Modify: `../core-service/internal/exchange/binance/factory.go`
- Modify: `../core-service/internal/exchange/binance/mockserver/scenario.go`
- Create: `../core-service/internal/exchange/binance/mockserver/income.go`
- Modify: `../core-service/internal/exchange/binance/mockserver/server.go`
- Modify: `../core-service/internal/exchange/binance/mockserver/ws.go`
- Modify: `../core-service/internal/exchange/binance/mockserver/server_test.go`

- [ ] **Step 1: Write exact calculator tests**

Cover:

```text
ONE_WAY long: qty=2, mark=100, rate=0.0001 -> -0.02
HEDGE: LONG 2 -> -0.02 and SHORT -1.5 -> +0.015; total -0.005
actual -0.00500001 -> residual -0.00000001 assigned to LONG
equal absolute legs -> stable symbol/side tie break
zero qty -> zero leg; duplicate side/invalid decimal/Spot route -> error
Cross and Isolated use the same formula but retain margin_mode per leg
```

Assert canonical decimal output has no exponent and no precision loss.

- [ ] **Step 2: Write Income History and Account Update parser tests**

Use Mock Binance fixtures to assert:

- signed `income` remains exact text;
- `tranId` remains exact text and is scoped with `incomeType`;
- `startTime`, `endTime`, `page`, `limit`, and `incomeType=FUNDING_FEE` are sent;
- 1000 rows marks `HasMore`, fewer rows ends paging;
- 429/5xx are typed retryable errors; invalid credentials are terminal;
- `ACCOUNT_UPDATE` with reason `FUNDING_FEE` becomes a canonical account event with exact balance and position fields;
- `ORDER_TRADE_UPDATE` still becomes the same canonical order event;
- Spot execution reports still parse and Funding events are rejected on Spot.

- [ ] **Step 3: Confirm RED**

```bash
cd ../core-service
go test ./internal/exchange/binance/... -run 'Funding|Income|AccountUpdate|OrderEvent'
```

- [ ] **Step 4: Implement exact Binance calculation**

Use `math/big.Rat`; do not convert through `float64`. Normalize decimal text by dividing numerator/denominator only when the denominator contains factors 2 and 5; reject a non-terminating result instead of silently rounding. Apply the deterministic residual rule from the canonical contract and use version `binance-usdm-linear-v1`.

- [ ] **Step 5: Implement signed Income History paging**

Call `/fapi/v1/income` through the existing signed Binance REST client. Validate the route is Binance USDⓈ-M Futures and environment is Demo/Live. Preserve each response object as `RawPayload`. Clamp `limit` to `[1,1000]` and require both bounds.

- [ ] **Step 6: Generalize the user-data callback**

Parse one WS message into exactly one canonical `UserDataEvent`. `ORDER_TRADE_UPDATE` fills `Order`; `ACCOUNT_UPDATE` fills `Account`; unknown event types are ignored with a metric and do not terminate the stream. Do not parse Funding amounts from balance deltas as final Income.

- [ ] **Step 7: Extend Mock Binance**

Add scenario-owned queues for REST Income pages and WS Account Update frames. The mock must be able to return duplicate `tranId`, delayed rows, no push, pagination, 429 with `Retry-After`, 5xx, malformed rows, and reconnect replay. Do not add a second mock server.

- [ ] **Step 8: Run Binance plus order regressions**

```bash
cd ../core-service
gofmt -w internal/exchange/binance
go test ./internal/exchange/binance/...
go test ./internal/order/... -run 'GTC|IOC|FOK|GTX|Partial|Fill|Cancel|Liquidation|ADL|Spot'
go vet ./internal/exchange/binance/... ./internal/order/...
```

- [ ] **Step 9: Commit Task 2**

```bash
git add internal/exchange/binance
git commit -m "feat: implement binance funding facts and income"
```

---

### Task 3: Move Funding market data fully behind the scraper Exchange Adapter

**Files:**

- Modify: `../scraper/internal/exchange/types.go`
- Modify: `../scraper/internal/exchange/registry.go`
- Modify: `../scraper/internal/exchange/binance/exchange.go`
- Create: `../scraper/internal/exchange/binance/funding.go`
- Create: `../scraper/internal/exchange/binance/funding_test.go`
- Delete: `../scraper/internal/exchange/binance/scraper/funding.go`
- Delete: `../scraper/internal/scraper/fundingrate/funding.go`
- Delete: `../scraper/internal/scraper/common/planner.go`
- Modify: `../scraper/internal/models/models.go`
- Modify: `../scraper/internal/storage/timescale.go`
- Modify: `../scraper/internal/storage/timescale_test.go`
- Modify: `../scraper/internal/storage/migrations/0001_current_schema_baseline.sql`
- Modify: `../scraper/internal/storage/migrations/baseline_contract_test.go`

- [ ] **Step 1: Write failing Adapter and storage tests**

Assert:

- Binance historical Funding uses `/fapi/v1/fundingRate` and preserves exact `fundingRate` and `markPrice` text;
- the next historical row supplies the previous row's next Funding time; no fixed `+8h` exists;
- latest scheduling uses current Premium/Funding data's real `nextFundingTime`;
- the last historical row may have no known next time;
- storage columns are `NUMERIC(38,18)` and scanned as strings;
- OKX remains registry-visible but returns unsupported for Funding.

- [ ] **Step 2: Confirm RED**

```bash
cd ../scraper
go test ./internal/exchange/... ./internal/storage/... ./internal/models/...
```

- [ ] **Step 3: Define exact canonical Funding facts**

Use:

```go
type FundingRate struct {
	Exchange           Exchange
	Market             Market
	Symbol             string
	FundingTime        time.Time
	FundingRateDecimal string
	MarkPriceDecimal   string
	NextFundingTime    *time.Time
}
```

Keep endpoints and response structs in `internal/exchange/binance/funding.go`. The common Registry only calls a `FundingMarketDataCollector` capability.

- [ ] **Step 4: Remove dead generic/Binance-crossing code**

Delete the unused planner that imports Binance directly and the old generic Funding scraper. Confirm no source imports remain:

```bash
cd ../scraper
rg -n 'internal/scraper/fundingrate|binance/scraper/funding|fundingTime.*8|8\s*\*\s*time.Hour' .
```

Expected: no source match for the deleted paths or fixed-eight-hour derivation.

- [ ] **Step 5: Change the fresh storage baseline**

Use `NUMERIC(38,18)` for Funding rate and mark price. This is a clean baseline update; do not add an ALTER compatibility migration. Keep Kline tables and other exchanges unchanged.

- [ ] **Step 6: Run scraper verification**

```bash
cd ../scraper
gofmt -w internal/exchange internal/models internal/storage
go test ./...
go vet ./...
```

- [ ] **Step 7: Commit Task 3**

```bash
git add -A internal/exchange internal/scraper internal/models internal/storage
git commit -m "refactor: collect funding through exchange adapters"
```

---

### Task 4: Add the single Venue Income table and fresh-deployment contract

**Files:**

- Modify: `../core-service/internal/storage/migrations/0001_current_schema_baseline.sql`
- Modify: `../core-service/internal/storage/migrations/migration_contract_test.go`
- Modify: `db/README.md`
- Modify: `db/generated/portfolio.sql`
- Modify: `db/generated/market_data_year.sql`
- Modify: `db/generated/README.md`

- [ ] **Step 1: Add failing migration contract assertions**

Require the table, JSON checks, composite Session/Venue FK, exact numeric fields, lookup indexes, and both unique indexes. Also assert there is no `funding_fee_entries`, `wallet_ledger`, or second Income table.

- [ ] **Step 2: Confirm RED**

```bash
cd ../core-service
go test ./internal/storage/migrations -run 'MigrationContract|Fresh'
```

- [ ] **Step 3: Add the table to the current portfolio baseline**

Use this schema shape, with constraints expressed as idempotent baseline SQL in the style already used by the file:

```sql
CREATE TABLE IF NOT EXISTS venue_income_entries (
    income_entry_id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    session_id TEXT NOT NULL,
    venue_id BIGINT NOT NULL,
    income_type TEXT NOT NULL,
    source TEXT NOT NULL,
    external_transaction_id TEXT,
    settlement_key TEXT NOT NULL,
    symbol TEXT NOT NULL,
    asset TEXT NOT NULL,
    occurred_at TIMESTAMPTZ NOT NULL,
    calculated_amount NUMERIC(38,18) NOT NULL,
    exchange_amount NUMERIC(38,18),
    applied_amount NUMERIC(38,18) NOT NULL,
    reconciliation_delta NUMERIC(38,18) NOT NULL,
    calculation_details JSONB NOT NULL DEFAULT '[]'::jsonb,
    raw_payload JSONB NOT NULL DEFAULT '{}'::jsonb,
    status TEXT NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    CONSTRAINT venue_income_entries_session_venue_fkey
      FOREIGN KEY (session_id, venue_id)
      REFERENCES session_venues(session_id, venue_id) ON DELETE CASCADE,
    CONSTRAINT chk_venue_income_source CHECK (source IN ('exchange', 'backtest')),
    CONSTRAINT chk_venue_income_status CHECK (status IN ('pending_actual', 'confirmed', 'calculated')),
    CONSTRAINT chk_venue_income_details_array CHECK (jsonb_typeof(calculation_details) = 'array'),
    CONSTRAINT chk_venue_income_raw_object CHECK (jsonb_typeof(raw_payload) = 'object')
);

CREATE UNIQUE INDEX IF NOT EXISTS uq_venue_income_external_transaction
ON venue_income_entries (venue_id, income_type, external_transaction_id)
WHERE external_transaction_id IS NOT NULL;

CREATE UNIQUE INDEX IF NOT EXISTS uq_venue_income_settlement
ON venue_income_entries (session_id, venue_id, income_type, settlement_key);

CREATE INDEX IF NOT EXISTS idx_venue_income_session_delivery
ON venue_income_entries (session_id, income_entry_id);

CREATE INDEX IF NOT EXISTS idx_venue_income_route_time
ON venue_income_entries (venue_id, income_type, occurred_at);
```

- [ ] **Step 4: Render generated bundles and document the inventory**

```bash
cd ../hushine-deploy
make db-schema-bundle SOURCE_ROOT=/Users/xdy/Workplace/hushine-worktrees/medium-cleanup
```

Update `db/README.md` to describe `venue_income_entries`, occurrence-time Session ownership, and the absence of a wallet ledger table.

- [ ] **Step 5: Prove one-shot and idempotent deployment locally**

Use a disposable local database, apply `db/generated/portfolio.sql` twice, and assert one table plus both unique indexes. Use the existing local Compose PostgreSQL rather than `.10`:

```bash
cd ../hushine-deploy
make local-infra-up
make local-ensure-dbs
psql "$PORTFOLIO_DSN" -v ON_ERROR_STOP=1 -f db/generated/portfolio.sql
psql "$PORTFOLIO_DSN" -v ON_ERROR_STOP=1 -f db/generated/portfolio.sql
```

If `PORTFOLIO_DSN` is not exported, use the DSN generated by `make local-configs`; never fall back to `.10`.

- [ ] **Step 6: Run contract tests**

```bash
cd ../core-service
go test ./internal/storage/migrations
cd ../hushine-deploy
bash scripts/runtime-indicator-v2-db-smoke.test.sh
```

- [ ] **Step 7: Commit Task 4 in its owning repositories**

```bash
cd ../core-service
git add internal/storage/migrations
git commit -m "feat: add canonical venue income storage"

cd ../hushine-deploy
git add db
git commit -m "docs: publish venue income database baseline"
```

---

### Task 5: Implement Income repository state transitions and atomic wallet application

**Files:**

- Create: `../core-service/internal/income/types.go`
- Create: `../core-service/internal/income/repository.go`
- Create: `../core-service/internal/repository/income.go`
- Create: `../core-service/internal/repository/income_test.go`
- Modify: `../core-service/internal/repository/repository.go`
- Modify: `../core-service/internal/domain/model.go`
- Modify: `../core-service/proto/portfolio_service.proto`

- [ ] **Step 1: Write repository integration tests before implementation**

Use the existing Timescale test fixture to cover:

```text
pending -> confirmed applies once
REST confirmed first -> later WS pending is a no-op
duplicate tranId applies once
duplicate settlement_key applies once
tranId and settlement_key resolving to different rows -> conflict, rollback
two concurrent confirmations -> one row and one wallet effect
occurred_at at started_at -> belongs to Session
occurred_at at completed_at -> does not belong to Session
same Venue reused sequentially -> original Session selected
overlapping matching Sessions -> fail closed
no matching Session -> offline ignored, no Income row
wallet write failure -> Income insert and aggregate both rollback
Cross aggregate and Isolated leg wallet attribution
```

Assert with exact decimal SQL values, not approximate floats.

- [ ] **Step 2: Confirm RED**

```bash
cd ../core-service
go test ./internal/repository -run 'Income|Funding|SessionAtOccurrence'
```

- [ ] **Step 3: Add focused Income domain types and repository interface**

Define:

```go
type EntryStatus string
const (
	EntryPendingActual EntryStatus = "pending_actual"
	EntryConfirmed     EntryStatus = "confirmed"
	EntryCalculated    EntryStatus = "calculated"
)

type ApplyRequest struct {
	Entry Entry
	WalletLegs []WalletApplicationLeg
}

type Repository interface {
	FindSessionVenueAt(context.Context, int64, time.Time) (SessionVenue, error)
	UpsertAndApply(context.Context, ApplyRequest) (Entry, ApplyOutcome, error)
	ListAfter(context.Context, string, int64, int) ([]Entry, error)
}
```

Use concrete exported Income types rather than `map[string]any`. Keep SQL implementation in `internal/repository/income.go`; do not add Funding SQL to the already-large `timescale.go`.

- [ ] **Step 4: Implement occurrence-time ownership**

Select by `(session_id, venue_id)` membership and:

```sql
s.started_at <= $occurred_at
AND (s.completed_at IS NULL OR $occurred_at < s.completed_at)
```

Return zero matches as a typed offline outcome. Return more than one match as a data-integrity error. Do not use the currently running Session as a fallback.

- [ ] **Step 5: Implement the merge state machine under row locks**

In one transaction:

1. resolve/lock Session Venue;
2. look up the external key and settlement key separately;
3. reject if both point at different rows;
4. lock/create the one Income row;
5. transition only `pending_actual -> confirmed` or insert `confirmed/calculated`;
6. apply only when the row first becomes `confirmed` or `calculated`;
7. lock and update `venue_wallet_states`, Portfolio aggregate, and Session snapshot;
8. commit before returning a deliverable entry.

Never infer “already applied” from amount equality.

- [ ] **Step 6: Add the persistent Worker cursor to canonical wallet schema**

Add this field without a second database table:

Append field number 117 to the existing `FuturesWallet` message without renumbering any field:

```proto
int64 last_applied_income_entry_id = 117;
```

Map it through `internal/domain/model.go`, snapshot JSON serialization, repository reads, and wallet update writes. A stale Worker snapshot with a lower cursor must not move the stored cursor backwards.

- [ ] **Step 7: Generate core bindings and run repository tests**

```bash
cd ../core-service
make proto
gofmt -w internal/income internal/repository internal/domain
go test ./internal/repository ./internal/storage/migrations
go test ./internal/service -run 'Wallet|Snapshot'
go vet ./internal/income/... ./internal/repository/... ./internal/service/...
```

- [ ] **Step 8: Commit Task 5**

```bash
git add internal/income internal/repository internal/domain proto gen/portfoliov1
git commit -m "feat: apply venue income atomically"
```

---

### Task 6: Build the common Funding Coordinator, position projection, poller, and stream lifecycle

**Files:**

- Create: `../core-service/internal/income/coordinator.go`
- Create: `../core-service/internal/income/coordinator_test.go`
- Create: `../core-service/internal/income/position_projection.go`
- Create: `../core-service/internal/income/position_projection_test.go`
- Create: `../core-service/internal/income/poller.go`
- Create: `../core-service/internal/income/poller_test.go`
- Modify: `../core-service/internal/order/executor/user_data_stream_manager.go`
- Modify: `../core-service/internal/order/executor/user_data_stream_manager_test.go`
- Modify: `../core-service/internal/order/repository/repository.go`
- Modify: `../core-service/cmd/core-service/main.go`
- Modify: `../core-service/internal/config/config.go`
- Modify: `../core-service/config.yaml`

- [ ] **Step 1: Write coordinator and stream-lifecycle tests**

Cover:

- desired user-data streams are the union of active/settlement-grace Session Venue Futures routes and routes with open orders;
- a Futures Session with no open order still receives account events;
- a terminal Session with an open order keeps order recovery working;
- stale routes stop after both requirements disappear;
- Spot routes keep order events but never start Income polling;
- Funding Account Update triggers an immediate Income query and pending settlement;
- an ordinary order event follows the unchanged lifecycle ingestor;
- duplicate/replayed push and REST events converge;
- a blocked/unavailable Runtime has no effect on stream, poller, or repository work.

- [ ] **Step 2: Write exact position-projection tests**

Cover ONE_WAY, HEDGE LONG/SHORT, Cross, Isolated, multi-symbol, partial fills, repeated exchange trade IDs, out-of-order events, liquidation/ADL, and recovery from the Session's starting canonical snapshot plus exact fills up to `occurred_at`. Invalid/ambiguous projections must fail closed.

- [ ] **Step 3: Write deterministic poll scheduling tests with a fake clock**

Assert:

```text
startup/reconnect/account-update -> immediate overlapping query
retry delays -> 10s, 30s, 1m, 2m, 5m (then remain at 5m)
nextFundingTime -> query at nextFundingTime + 10s
healthy periodic repair -> 15m plus bounded jitter
every request overlaps the prior successful watermark by 24h
pages continue until fewer than 1000 records
global limiter serializes weight-30 calls
grace closes after pending confirmed plus one final overlap query
hard grace cap -> 24h with an explicit unresolved alert
```

- [ ] **Step 4: Confirm RED**

```bash
cd ../core-service
go test ./internal/income ./internal/order/executor -run 'Funding|Income|DesiredRoutes|PositionProjection|Poll'
```

- [ ] **Step 5: Implement the position projector**

Consume canonical Account Update position facts and exact order lifecycle fills. Persist no second position table. On recovery, start from the Session wallet snapshot and replay order fills through `occurred_at`; use a Funding Account Update as an authoritative checkpoint when available. Require one fact per `(symbol, position_side, margin_mode)` and retain decimal strings.

- [ ] **Step 6: Implement the common Coordinator without exchange branching**

The Coordinator must only:

```go
calculator, err := registry.FundingSettlementCalculator(route)
result, err := calculator.CalculateFundingSettlement(ctx, request)
outcome, err := incomeRepo.UpsertAndApply(ctx, applyRequest(result))
```

It must not compare `route.Exchange` to Binance/OKX. For Demo/Live, `ActualAmountDecimal` is the exchange record. For Backtest it is nil. Account Update may establish pending state and trigger lookup, but cannot be final Income.

- [ ] **Step 7: Implement the active reconciliation poller**

List active and grace-window Session Venue routes from the repository. Share a process-wide weighted limiter. Store only scheduling/watermark state in memory; restart always begins with a 24-hour overlap. Use context cancellation for stale routes.

- [ ] **Step 8: Generalize UserDataStreamManager**

Rename order-only callback paths where necessary, but retain one route stream. Dispatch `event.Order` to the existing lifecycle ingestor and `event.Account` to position projection/Coordinator. Do not fork two Binance WebSockets for one route.

- [ ] **Step 9: Wire dependencies and config**

Wire Registry, Income repository, Coordinator, Poller, projector, and stream manager in `cmd/core-service/main.go`. Add only exchange-neutral schedule/limit configuration. Keep Binance endpoints in the Binance Adapter configuration.

- [ ] **Step 10: Run focused and package verification**

```bash
cd ../core-service
gofmt -w internal/income internal/order/executor internal/order/repository cmd/core-service internal/config
go test ./internal/income ./internal/order/executor ./internal/order/lifecycle ./internal/order/repository
go test ./internal/exchange/binance/... ./internal/repository
go vet ./internal/income/... ./internal/order/... ./cmd/core-service
```

- [ ] **Step 11: Commit Task 6**

```bash
git add internal/income internal/order cmd/core-service internal/config config.yaml
git commit -m "feat: reconcile futures funding income"
```

---

### Task 7: Expose typed Income delivery and Backtest settlement through PortfolioService

**Files:**

- Modify: `../core-service/proto/portfolio_service.proto`
- Modify: `../core-service/gen/portfoliov1/portfolio_service.pb.go`
- Modify: `../core-service/gen/portfoliov1/portfolio_service_grpc.pb.go`
- Modify: `../core-service/internal/service/grpc.go`
- Create: `../core-service/internal/service/grpc_income_test.go`
- Modify: `../core-service/internal/repository/repository.go`

- [ ] **Step 1: Add failing service tests for authorization and semantics**

Test:

- `ListVenueIncomeEntries` requires owner `user_id`, exact Session, and ascending cursor;
- it returns at most 500 entries and stable `next_after_income_entry_id`;
- `SettleBacktestFunding` requires active Backtest Session, Session Venue membership, matching route, real Funding time inside the requested Backtest range, and Futures market;
- Demo/Live callers cannot invoke Backtest settlement;
- missing/ambiguous position legs fail before database mutation;
- repeated identical settlement returns the original Entry without a second wallet effect.

- [ ] **Step 2: Confirm RED**

```bash
cd ../core-service
go test ./internal/service -run 'Income|SettleBacktestFunding'
```

- [ ] **Step 3: Add protobuf messages and RPCs**

Use typed decimal strings:

```proto
rpc ListVenueIncomeEntries(ListVenueIncomeEntriesRequest) returns (ListVenueIncomeEntriesResponse);
rpc SettleBacktestFunding(SettleBacktestFundingRequest) returns (SettleBacktestFundingResponse);

message FundingPositionLegFact {
  string symbol = 1;
  string position_side = 2;
  string margin_mode = 3;
  string signed_qty_decimal = 4;
}

message FundingFact {
  int64 venue_id = 1;
  int32 exchange = 2;
  int32 market = 3;
  string symbol = 4;
  google.protobuf.Timestamp funding_time = 5;
  string funding_rate_decimal = 6;
  string mark_price_decimal = 7;
  string settlement_asset = 8;
}

message VenueIncomeEntry {
  int64 income_entry_id = 1;
  string session_id = 2;
  int64 venue_id = 3;
  string income_type = 4;
  string source = 5;
  string external_transaction_id = 6;
  string settlement_key = 7;
  string symbol = 8;
  string asset = 9;
  google.protobuf.Timestamp occurred_at = 10;
  string calculated_amount_decimal = 11;
  string exchange_amount_decimal = 12;
  string applied_amount_decimal = 13;
  string reconciliation_delta_decimal = 14;
  string calculation_details_json = 15;
  string status = 16;
}
```

`SettleBacktestFundingRequest` contains `user_id`, `session_id`, `FundingFact`, `position_mode`, and repeated position legs. `ListVenueIncomeEntriesRequest` contains `user_id`, `session_id`, `after_income_entry_id`, and `limit`.

- [ ] **Step 4: Generate, implement, and verify**

```bash
cd ../core-service
make proto
gofmt -w internal/service internal/repository
go test ./internal/service ./internal/income ./internal/repository
go vet ./internal/service/... ./internal/income/...
```

- [ ] **Step 5: Commit Task 7**

```bash
git add proto gen internal/service internal/repository/repository.go
git commit -m "feat: expose funding settlement and income feed"
```

---

### Task 8: Add exact Funding facts to Backtest pages in control-panel-service

**Files:**

- Modify: `../control-panel-service/internal/runtimechannel/market_data_query.go`
- Modify: `../control-panel-service/internal/runtimechannel/market_data_query_test.go`
- Modify: `../control-panel-service/internal/runtimechannel/platform_proxy.go`
- Modify: `../control-panel-service/internal/runtimechannel/platform_proxy_test.go`

- [ ] **Step 1: Write failing multi-year and ordering tests**

Assert that a Futures Backtest page fetches Klines plus Funding facts for the same `[start,end)` window, exact decimal text survives PostgreSQL scanning, the Funding table may be absent for Spot, and the last page does not invent a Funding interval. Verify exchange/year database routing works for Binance and does not hardcode Binance in common validation.

- [ ] **Step 2: Confirm RED**

```bash
cd ../control-panel-service
go test ./internal/runtimechannel -run 'Funding|BacktestPage|MarketDataQuery'
```

- [ ] **Step 3: Add a Funding query alongside Kline query**

Define:

```go
type FundingQuery struct {
	Exchange string
	Market string
	Symbol string
	StartTimeMS int64
	EndTimeMS int64
	Limit int
}

type FundingRow struct {
	Exchange string
	Market string
	Symbol string
	FundingTimeMS int64
	FundingRateDecimal string
	MarkPriceDecimal string
}
```

Query the scraper baseline's Funding table. Common code builds the database from `{exchange}_{year}` and never chooses a Binance endpoint.

- [ ] **Step 4: Return Funding facts in `marketdata.FetchBacktestPage`**

Extend the current `structpb.Struct` response with a typed JSON list named `funding_facts`. Only Futures pages include it. Preserve current Kline cursor semantics; Funding facts at the page boundary must not be skipped or duplicated.

- [ ] **Step 5: Run tests and commit**

```bash
cd ../control-panel-service
gofmt -w internal/runtimechannel
go test ./internal/runtimechannel
go vet ./internal/runtimechannel/...
git add internal/runtimechannel
git commit -m "feat: include funding facts in backtest pages"
```

---

### Task 9: Deliver confirmed Income through RuntimeChannel without coupling platform work to the Worker

**Files:**

- Modify: `../control-panel-service/proto/control_panel_service.proto`
- Modify: `../control-panel-service/gen/controlpanelv1/control_panel_service.pb.go`
- Modify: `../control-panel-service/gen/controlpanelv1/control_panel_service_grpc.pb.go`
- Create: `../control-panel-service/internal/runtimechannel/income_delivery.go`
- Create: `../control-panel-service/internal/runtimechannel/income_delivery_test.go`
- Modify: `../control-panel-service/internal/runtimechannel/live_delivery.go`
- Modify: `../control-panel-service/internal/runtimechannel/live_delivery_test.go`
- Modify: `../control-panel-service/internal/runtimechannel/platform_proxy.go`
- Modify: `../control-panel-service/internal/runtimechannel/platform_proxy_test.go`
- Modify: `../control-panel-service/cmd/control-panel-service/main.go`

- [ ] **Step 1: Write failing delivery tests**

Test one active Session, two Sessions, reconnect, duplicate page, Worker backpressure, Worker absent for ten minutes, Session ownership mismatch, and terminal Session replay. Confirm platform Income polling and core database application are outside the delivery goroutine and continue even when `DeliverIncomeBatch` blocks/fails.

- [ ] **Step 2: Confirm RED**

```bash
cd ../control-panel-service
go test ./internal/runtimechannel -run 'IncomeDelivery|IncomeBatch|Backpressure'
```

- [ ] **Step 3: Add the RuntimeChannel frame**

Append, without reusing existing numbers:

```proto
enum FrameType {
  FRAME_TYPE_INCOME_BATCH = 22;
}

message RuntimeIncomeBatch {
  string session_id = 1;
  string stream_key = 2;
  int64 sequence = 3;
  repeated portfolio.v1.VenueIncomeEntry entries = 4;
}
```

Add `RuntimeIncomeBatch income_batch = 31` to `RuntimeFrame.payload`. Use stream key `income/{session_id}` and existing data ACK/backpressure semantics.

- [ ] **Step 4: Implement cursor-based delivery**

Poll `ListVenueIncomeEntries(session_id, after_income_entry_id)` in ascending ID order. Advance the delivery cursor only after ACK. On reconnect, start from the Worker-reported canonical wallet cursor when available; otherwise replay from zero and let Worker idempotency discard old entries. Delivery cursor may remain in control-panel memory because correctness lives in the wallet cursor.

- [ ] **Step 5: Authorize Backtest settlement in PlatformProxy**

Add `ListVenueIncomeEntries` and `SettleBacktestFunding` to `PortfolioPlatformClient` and `DispatchRuntimeRequest`. Require authenticated runtime user, exact owning runtime, exact Session, active status, and Backtest environment before proxying. Add canonical method names:

```text
portfolio.ListVenueIncomeEntries
portfolio.SettleBacktestFunding
```

- [ ] **Step 6: Generate bindings, wire the worker, and verify**

```bash
cd ../control-panel-service
make proto
gofmt -w internal/runtimechannel cmd/control-panel-service
go test ./internal/runtimechannel ./cmd/control-panel-service
go vet ./internal/runtimechannel/... ./cmd/control-panel-service
```

- [ ] **Step 7: Commit Task 9**

```bash
git add proto gen internal/runtimechannel cmd/control-panel-service
git commit -m "feat: deliver venue income over runtime channel"
```

---

### Task 10: Forward Income through the Go Runtime Agent and persist Worker replay identity

**Files:**

- Modify: `../strategy-service/proto/runtime_worker.proto`
- Modify: `../strategy-service/gen/runtimeworkerv1/runtime_worker.pb.go`
- Modify: `../strategy-service/gen/runtimeworkerv1/runtime_worker_grpc.pb.go`
- Modify: `../strategy-service/gen/controlpanelv1/control_panel_service.pb.go`
- Modify: `../strategy-service/strategy_service/gen/runtime_worker_pb2.py`
- Modify: `../strategy-service/strategy_service/gen/runtime_worker_pb2_grpc.py`
- Modify: `../strategy-service/strategy_service/gen/control_panel_service_pb2.py`
- Modify: `../strategy-service/internal/runtimeagent/agent.go`
- Modify: `../strategy-service/internal/runtimeagent/agent_test.go`
- Modify: `../strategy-service/internal/runtimeagent/runtime_channel.go`
- Modify: `../strategy-service/internal/runtimeagent/runtime_channel_test.go`
- Modify: `../strategy-service/strategy_service/worker_agent_client.py`
- Modify: `../strategy-service/tests/test_worker_agent_client.py`
- Modify: `../strategy-service/tests/test_runtime_worker_proto.py`

- [ ] **Step 1: Write failing frame-forwarding tests**

Assert one control-panel Income frame becomes one Worker `IncomeBatch` with unchanged IDs/decimal strings. Duplicate, out-of-order, backpressured, and replayed frames must follow the existing data ACK rules. A Worker that does not read for ten minutes must not stop Agent heartbeat or RuntimeChannel heartbeat ACK.

- [ ] **Step 2: Confirm RED**

```bash
cd ../strategy-service
go test ./internal/runtimeagent -run 'Income|Heartbeat|Backpressure'
PYTHONPATH=.:../strategy-library uv run --frozen --extra dev pytest tests/test_worker_agent_client.py tests/test_runtime_worker_proto.py -q
```

- [ ] **Step 3: Add Worker protocol payload**

```proto
message AgentFrame {
  oneof payload {
    IncomeBatch income_batch = 18;
  }
}

message IncomeBatch {
  string session_id = 1;
  string stream_key = 2;
  int64 sequence = 3;
  repeated google.protobuf.Any entries = 4;
}
```

Increment `WorkerHello.protocol_version` expectation from 5 to 6 and update both sides atomically. There is no legacy protocol branch.

- [ ] **Step 4: Generate all cross-repository bindings**

Run core generation first, then control-panel generation, then strategy generation:

```bash
cd ../core-service && make proto
cd ../control-panel-service && make proto
cd ../strategy-service && PYTHON=.venv/bin/python ./generate_proto.sh
```

- [ ] **Step 5: Map RuntimeChannel to Worker events**

Extend `workerDataFrameFromRuntime` and the runtime-channel switch. Keep Income frames in the data plane, never the command/heartbeat path. In Python, decode each `VenueIncomeEntry` and emit a `RuntimeSessionEvent(kind="income", ...)`.

- [ ] **Step 6: Run protocol, blocked-worker, and generation tests**

```bash
cd ../strategy-service
gofmt -w internal/runtimeagent
go test ./internal/runtimeagent
PYTHONPATH=.:../strategy-library uv run --frozen --extra dev pytest tests/test_worker_agent_client.py tests/test_runtime_worker_proto.py tests/test_generated_proto_imports.py -q
bash scripts/runtime-agent-blocked-worker.test.sh
go vet ./internal/runtimeagent/...
```

- [ ] **Step 7: Commit generated and source changes**

```bash
git add proto gen strategy_service/gen internal/runtimeagent strategy_service/worker_agent_client.py tests
git commit -m "feat: forward income frames to session workers"
```

---

### Task 11: Merge Backtest Funding into the Worker market timeline before same-time Klines

**Files:**

- Modify: `../strategy-service/strategy_service/platform_proxy.py`
- Modify: `../strategy-service/tests/test_platform_proxy.py`
- Modify: `../strategy-service/strategy_service/backtest_pages.py`
- Modify: `../strategy-service/tests/test_backtest_pages.py`
- Modify: `../strategy-service/strategy_service/grpc_server.py`
- Modify: `../strategy-service/tests/test_grpc_server.py`

- [ ] **Step 1: Write failing timeline tests**

Use pages containing BTCUSDT, ETHUSDT, and ZECUSDT. Assert:

```text
09:00 Funding -> settlement call -> wallet result -> 09:00 Kline callback
two symbols at 09:00 -> deterministic symbol order, each settled once
Funding at a page boundary -> neither missing nor duplicate
Spot page -> no Funding facts or settlement calls
open Futures position plus missing Funding storage -> Backtest fails with a typed data-gap error
no open position plus missing Funding row -> Kline may continue
```

- [ ] **Step 2: Confirm RED**

```bash
cd ../strategy-service
PYTHONPATH=.:../strategy-library uv run --frozen --extra dev pytest tests/test_backtest_pages.py tests/test_platform_proxy.py tests/test_grpc_server.py -q
```

- [ ] **Step 3: Decode exact Funding facts**

Add:

```python
@dataclass(frozen=True)
class FundingFact:
    venue_id: int
    exchange: str
    market: str
    symbol: str
    funding_time_ms: int
    funding_rate_decimal: str
    mark_price_decimal: str
    settlement_asset: str
```

`BacktestPage` carries `klines` and `funding_facts`. Preserve decimal strings exactly.

- [ ] **Step 4: Replace `iter_klines` with a typed timeline**

Define `BacktestTimelineEvent(kind, market_time_ms, stream_index, payload)` and merge heap keys as:

```python
(market_time_ms, 0 if kind == "funding" else 1, stream_index, sequence)
```

Keep a thin `iter_klines` only if existing internal tests require it during the same commit; remove it before Task completion if no current caller remains. Do not add a compatibility mode.

- [ ] **Step 5: Call platform settlement before strategy Kline handling**

Add `ProxyPortfolioClient.settle_backtest_funding`. Build the request with the exact position legs from Task 12. Apply the returned Income before invoking strategy callbacks. A settlement failure stops Backtest with a structured error; it is never logged-and-skipped.

- [ ] **Step 6: Remove hardcoded input exchange defaults**

Where Backtest preflight/page fetch currently forces `binance`, use each declared input's `exchange`. Defaults are resolved once during strategy declaration validation, not inside the page loop.

- [ ] **Step 7: Verify and commit**

```bash
cd ../strategy-service
PYTHONPATH=.:../strategy-library uv run --frozen --extra dev pytest tests/test_backtest_pages.py tests/test_platform_proxy.py tests/test_grpc_server.py -q
git add strategy_service/platform_proxy.py strategy_service/backtest_pages.py strategy_service/grpc_server.py tests
git commit -m "feat: settle funding in backtest market time"
```

---

### Task 12: Track exact Futures legs and apply Funding once in canonical wallets

**Files:**

- Create: `../strategy-service/strategy_service/funding_position_tracker.py`
- Create: `../strategy-service/tests/test_funding_position_tracker.py`
- Modify: `../strategy-service/strategy_service/wallet/order_types.py`
- Modify: `../strategy-service/strategy_service/wallet/binance.py`
- Modify: `../strategy-service/strategy_service/wallet/canonical.py`
- Modify: `../strategy-service/strategy_service/wallet/portfolio_adapter.py`
- Modify: `../strategy-service/strategy_service/wallet/runtime.py`
- Modify: `../strategy-service/strategy_service/wallet/portfolio.py`
- Modify: `../strategy-service/strategy_service/portfolio_client.py`
- Modify: `../strategy-service/tests/test_wallet_runtime.py`
- Modify: `../strategy-service/tests/test_portfolio_wallet_runtime.py`
- Modify: `../strategy-service/tests/test_portfolio_snapshot_adapter.py`

- [ ] **Step 1: Write exact tracker tests**

Use Python `Decimal` and cover:

- ONE_WAY BUY/SELL and reduce-only close;
- HEDGE LONG and SHORT remain separate;
- Cross and Isolated retain attribution;
- partial fill then final fill;
- duplicate `exchange_trade_id` ignored;
- BTC, ETH, and ZEC remain independent;
- liquidation/ADL terminal fills update legs exactly;
- snapshot recovery plus later fills;
- invalid side, missing position side in Hedge, or float-only amount fails closed.

- [ ] **Step 2: Write wallet replay-cursor tests**

Assert Entry IDs 7, 7, 6, 8 apply only 7 then 8; serialization/restoration retains cursor 8; a stale snapshot cannot lower the cursor; Cross changes the shared Futures wallet; Isolated uses the specified leg wallet; Spot rejects the ledger event.

- [ ] **Step 3: Confirm RED**

```bash
cd ../strategy-service
PYTHONPATH=.:../strategy-library uv run --frozen --extra dev pytest tests/test_funding_position_tracker.py tests/test_wallet_runtime.py tests/test_portfolio_wallet_runtime.py tests/test_portfolio_snapshot_adapter.py -q
```

- [ ] **Step 4: Implement the exact position tracker**

The tracker owns `dict[(venue_id, symbol, position_side, margin_mode), Decimal]` and a set of processed exchange trade IDs. It receives exact lifecycle decimal fields, never derives authority from `float` wallet positions. Expose sorted `FundingPositionLegFact` values for a specified Venue/symbol/time.

- [ ] **Step 5: Extend canonical LedgerEvent and Binance wallet**

Add `income_entry_id`, `venue_id`, `asset`, `amount_decimal`, and `margin_mode`. `BinanceFuturesWallet.on_ledger_event` must:

1. reject non-Funding or wrong Venue events at this path;
2. return unchanged for `income_entry_id <= last_applied_income_entry_id`;
3. apply exact amount to the correct Cross/Isolated wallet field;
4. recompute derived balances through existing wallet methods;
5. set the cursor only after successful application.

- [ ] **Step 6: Map cursor through protobuf snapshots**

Update serialize/deserialize and Portfolio snapshot adapters for `last_applied_income_entry_id`. Preserve max(existing, incoming) on update.

- [ ] **Step 7: Run all wallet/Spot tests and commit**

```bash
cd ../strategy-service
PYTHONPATH=.:../strategy-library uv run --frozen --extra dev pytest tests/test_funding_position_tracker.py tests/test_wallet_runtime.py tests/test_portfolio_wallet_runtime.py tests/test_portfolio_snapshot_adapter.py tests/test_spot_end_to_end.py tests/test_spot_filter_contract.py -q
git add strategy_service/funding_position_tracker.py strategy_service/wallet strategy_service/portfolio_client.py tests
git commit -m "feat: apply funding with durable wallet cursor"
```

---

### Task 13: Integrate Demo/Live Income consumption, restart recovery, and blocked-Worker behavior

**Files:**

- Modify: `../strategy-service/strategy_service/grpc_server.py`
- Modify: `../strategy-service/strategy_service/session.py`
- Modify: `../strategy-service/tests/test_grpc_server.py`
- Modify: `../strategy-service/tests/test_session.py`
- Modify: `../strategy-service/internal/runtimeagent/blocked_worker_integration_test.go`
- Modify: `../strategy-service/scripts/runtime-agent-blocked-worker.test.sh`
- Modify: `../strategy-service/tests/test_restart_bare_worker_session.py`

- [ ] **Step 1: Write failing Demo/Live consumption tests**

Assert that Income is applied before the next strategy event, to the matching Venue only, in ascending ID order. Duplicate/replayed batches are ACKed but do not change the wallet. A Session with multiple Futures Venues routes correctly. A Spot Session rejects Income.

- [ ] **Step 2: Write ten-minute block and restart tests with accelerated clocks**

Do not sleep ten real minutes. Block the Python strategy on a controllable barrier while advancing a fake clock by ten minutes. Assert Agent heartbeat, RuntimeChannel heartbeat, core Income persistence, and control-panel delivery retry continue. Then restart only the Worker, restore the canonical wallet cursor, replay the batch, and assert zero duplicate wallet effect.

- [ ] **Step 3: Confirm RED**

```bash
cd ../strategy-service
go test ./internal/runtimeagent -run 'BlockedWorker|Income|Restart'
PYTHONPATH=.:../strategy-library uv run --frozen --extra dev pytest tests/test_grpc_server.py tests/test_session.py tests/test_restart_bare_worker_session.py -q
```

- [ ] **Step 4: Integrate the Worker event loop**

Handle `RuntimeSessionEvent(kind="income")` outside strategy user callbacks, resolve the Venue wallet, apply and persist the snapshot, then ACK. When strategy code is blocked, queue/backpressure safely; do not run platform reconciliation inside the Worker.

- [ ] **Step 5: Verify worker-only restart semantics**

Ensure the existing one-command Session restart clears Worker memory, marks the old Session recoverable, starts a new Session ID, reloads code, and keeps the Agent alive. Income belonging to the old Session cannot attach to the new Session because core ownership uses occurrence time and `(session_id, venue_id)`.

- [ ] **Step 6: Run and commit**

```bash
cd ../strategy-service
go test ./internal/runtimeagent
PYTHONPATH=.:../strategy-library uv run --frozen --extra dev pytest tests/test_grpc_server.py tests/test_session.py tests/test_restart_bare_worker_session.py -q
bash scripts/runtime-agent-blocked-worker.test.sh
git add strategy_service internal/runtimeagent scripts tests
git commit -m "feat: consume income across worker recovery"
```

---

### Task 14: Complete Mock Binance execution and Funding reconciliation matrix

**Files:**

- Modify: `../core-service/internal/exchange/binance/mockserver/fixtures.go`
- Modify: `../core-service/internal/exchange/binance/mockserver/fixtures_test.go`
- Modify: `../core-service/internal/exchange/binance/mockserver/scenario.go`
- Modify: `../core-service/internal/exchange/binance/mockserver/server_test.go`
- Modify: `../core-service/internal/exchange/binance/mockserver/ws_test.go`
- Modify: `../core-service/internal/order/executor/user_data_stream_manager_test.go`
- Create: `../core-service/tests/integration/funding_income_test.go`
- Modify: `../core-service/scripts/integration_e2e.sh`

- [ ] **Step 1: Define a single scenario matrix**

Create table-driven scenarios; do not duplicate one mock for Funding and another for orders:

| Market | Order mode | Exchange response | Expected order result | Expected Funding result |
|---|---|---|---|---|
| Futures | GTC | no fill, partial, full, cancel | rests/updates/terminal as appropriate | one settlement at Funding time |
| Futures | IOC | partial then expire | partial fill plus expired remainder | position leg uses filled quantity |
| Futures | FOK | full or reject | no partial terminal state | rejected order contributes no position |
| Futures | GTX | post-only rest or maker rejection | exchange result preserved | position changes only after fill |
| Futures | liquidation/ADL | terminal account/order events | order lifecycle and position close | settlement uses position at occurrence time |
| Spot | GTC/IOC/FOK | full/partial/reject | current Spot wallet semantics | no Funding query/event/mutation |

- [ ] **Step 2: Add RED integration assertions**

For each Futures row, run ONE_WAY Cross, HEDGE Cross, and HEDGE Isolated where meaningful. Include BTCUSDT, ETHUSDT, and ZECUSDT in one Session and verify symbol independence. Add push-only, REST-only, delayed REST, duplicate push, duplicate REST, reconnect replay, 429, 5xx, and missing Income cases.

- [ ] **Step 3: Run focused tests and fix only proven gaps**

```bash
cd ../core-service
go test ./internal/exchange/binance/mockserver ./internal/exchange/binance ./internal/order/executor -run 'GTC|IOC|FOK|GTX|Funding|Income|Liquidation|ADL|Spot'
go test -tags=integration ./tests/integration -run 'FundingIncome|OrderModes'
```

If a failure occurs, invoke `superpowers:systematic-debugging`, identify the first incorrect boundary, add the smallest failing unit test there, then change production code. Do not weaken the scenario.

- [ ] **Step 4: Verify notification behavior**

Confirmed Funding Income may emit one notification/audit event after transaction commit. Duplicate, pending, offline, and replayed records must not notify twice. Reuse the existing notification publisher; do not add Telegram-specific calls to Income Coordinator.

- [ ] **Step 5: Run all core tests and commit**

```bash
cd ../core-service
gofmt -w internal/exchange/binance internal/order tests/integration
go test ./...
go vet ./...
git add internal/exchange/binance internal/order tests scripts/integration_e2e.sh
git commit -m "test: cover order modes and funding reconciliation"
```

---

### Task 15: Update current project/operator documentation and remove superseded current guidance

**Files:**

- Modify: `db/README.md`
- Create: `docs/operations/funding-income.md`
- Create: `docs/operations/local-development.md`
- Create: `docs/architecture/exchange-adapters.md`
- Create: `docs/architecture/runtime-channel.md`
- Create: `docs/user-manual/backtest.md`
- Create: `docs/user-manual/demo-live.md`
- Modify: `docs/README.md`
- Modify: `scripts/audit/no-first-party-compatibility.sh`
- Modify: `scripts/audit/no-first-party-compatibility.test.sh`

- [ ] **Step 1: Inventory current documentation paths**

```bash
cd ../hushine-deploy
find docs -maxdepth 3 -type f | sort
rg -n 'funding|Funding|8 hours|8h|strategy-debugger-cli|wallet ledger|income table' docs db
```

Keep dated files under `docs/superpowers/specs`, `docs/superpowers/plans`, and archived historical evidence as history. Remove or rewrite only documents presented as current operator/user guidance.

- [ ] **Step 2: Write current operations guidance**

Document:

- Funding support matrix: Futures only; Backtest/Demo/Live; Binance supported; OKX fail-closed;
- local PostgreSQL/Kafka/ELK/Jaeger startup and one-shot schema bootstrap;
- Income poll schedules, 24-hour overlap/grace, rate limiting, metrics, alerts, and reconciliation states;
- how to run Mock Binance scenarios and the guarded real Demo smoke;
- no secrets in files/logs and no dependency on `.10`.

- [ ] **Step 3: Write architecture guidance**

Explain Registry capability routing, canonical Account Update, exact Funding facts, Adapter-owned formula/rounding, pending-to-confirmed merge, one Income table, atomic wallet update, RuntimeChannel Income delivery, persistent wallet cursor, Worker-block independence, and same-time Backtest ordering.

- [ ] **Step 4: Write user guidance**

Explain Funding as a Futures wallet adjustment, why Spot has none, what calculated/actual/delta mean, when Demo/Live reconciliation may be pending, and how missing Backtest Funding data fails. Do not expose internal DB/Kafka addresses or strategy-debugger-cli instructions.

- [ ] **Step 5: Extend the compatibility audit**

Add current-source checks that reject:

```text
generic/core Binance Funding endpoint strings
fixed 8-hour next-funding derivation
order-only UserDataStream callback contract
strategy-debugger-cli as a current supported runtime path
more than venue_income_entries as new Income/Funding ledger tables
```

- [ ] **Step 6: Validate docs and commit**

```bash
cd ../hushine-deploy
bash scripts/audit/no-first-party-compatibility.test.sh
bash scripts/audit/no-first-party-compatibility.sh
git diff --check
git add docs db scripts/audit
git commit -m "docs: publish funding income operations and architecture"
```

---

### Task 16: Run the full verification gate, real Demo smoke, review, and push all repositories

**Files:**

- Create: `scripts/funding-income-service-chain.test.sh`
- Create: `scripts/funding-income-demo-smoke.sh`
- Modify: `Makefile`
- Create when run: ignored logs under `.coverage/` or a temporary evidence directory; do not commit credentials or live response payloads.

- [ ] **Step 1: Add the cross-repository service-chain gate**

The script must fail if any required repository is dirty before the run, start from local Docker infrastructure, apply fresh schemas, run Mock Binance, start services, execute Backtest/Demo-style scenarios, and always tear down started processes. Assertions:

```text
single table and both unique indexes exist
BTC/ETH/ZEC multi-symbol Backtest settles before same-time Kline
1023 -> 1025 indicator regression still finalizes 1024 + open 1
Demo Account Update + REST Income yields one wallet effect
REST-only repair yields one wallet effect
Worker blocked/restarted yields one wallet effect and live Agent heartbeat
Spot produces zero Funding records
GTC/IOC/FOK/GTX and liquidation/ADL order regressions pass
```

- [ ] **Step 2: Add a guarded real Binance Demo smoke script**

Read credentials only from environment:

```text
BINANCE_DEMO_API_KEY
BINANCE_DEMO_API_SECRET
FUNDING_SMOKE_VENUE_ID
FUNDING_SMOKE_SESSION_ID
```

The script must refuse Live environment, print no secret or signed URL, use a narrowly bounded Income query, and write a redacted summary. It may create/use a Demo Venue only when explicit IDs/credentials are supplied. No credential from this conversation is written to disk.

- [ ] **Step 3: Run repository-native verification**

```bash
cd ../core-service
make proto
go test ./...
go vet ./...

cd ../scraper
go test ./...
go vet ./...

cd ../control-panel-service
make proto
go test ./...
go vet ./...

cd ../strategy-service
PYTHON=.venv/bin/python ./generate_proto.sh
PYTHONPATH=.:../strategy-library uv run --frozen --extra dev pytest tests/ -q
go test ./...
go vet ./...
bash scripts/start-bare-runtime-debugpy.test.sh
bash scripts/runtime-agent-platform.test.sh
bash scripts/runtime-agent-blocked-worker.test.sh

cd ../hushine-deploy
make db-schema-bundle SOURCE_ROOT=/Users/xdy/Workplace/hushine-worktrees/medium-cleanup
bash scripts/funding-income-service-chain.test.sh
bash scripts/runtime-indicator-v2-db-smoke.test.sh
bash scripts/audit/no-first-party-compatibility.test.sh
```

- [ ] **Step 4: Run the real Demo smoke when external access is available**

```bash
cd ../hushine-deploy
BINANCE_DEMO_API_KEY="$BINANCE_DEMO_API_KEY" \
BINANCE_DEMO_API_SECRET="$BINANCE_DEMO_API_SECRET" \
FUNDING_SMOKE_VENUE_ID="$FUNDING_SMOKE_VENUE_ID" \
FUNDING_SMOKE_SESSION_ID="$FUNDING_SMOKE_SESSION_ID" \
bash scripts/funding-income-demo-smoke.sh
```

If Binance/network access is unavailable, record the exact external blocker and retain all Mock/service-chain evidence. Do not claim exchange-backed confidence without a successful real smoke.

- [ ] **Step 5: Run Superpowers code review**

Invoke `superpowers:requesting-code-review` with the approved spec, this plan, all repository commit ranges, and verification logs. Resolve every correctness/security finding through TDD. Re-run the affected repository gate after each fix.

- [ ] **Step 6: Run final anti-drift checks**

```bash
cd /Users/xdy/Workplace/hushine-worktrees/medium-cleanup
rg -n '/fapi/v1/(income|fundingRate|premiumIndex)' core-service scraper control-panel-service strategy-service \
  --glob '!core-service/internal/exchange/binance/**' \
  --glob '!scraper/internal/exchange/binance/**' \
  --glob '!**/*_test.go' --glob '!**/tests/**'
rg -n '8\s*\*\s*time.Hour|timedelta\(hours=8\)' core-service scraper control-panel-service strategy-service
rg -n 'strategy-debugger-cli' hushine-deploy/docs --glob '!superpowers/specs/**' --glob '!superpowers/plans/**'
```

Expected: no production-code match for Binance endpoints outside Binance Adapters, no fixed-eight-hour derivation, and no current user/operator instruction maintaining strategy-debugger-cli.

- [ ] **Step 7: Commit verification assets**

```bash
cd ../hushine-deploy
git add Makefile scripts/funding-income-service-chain.test.sh scripts/funding-income-demo-smoke.sh
git commit -m "test: add funding income service chain gate"
```

- [ ] **Step 8: Verify clean trees and push the feature branch in every changed repository**

```bash
for repo in core-service scraper control-panel-service strategy-service hushine-deploy; do
  git -C "/Users/xdy/Workplace/hushine-worktrees/medium-cleanup/$repo" status --short --branch
  git -C "/Users/xdy/Workplace/hushine-worktrees/medium-cleanup/$repo" log -1 --oneline
  git -C "/Users/xdy/Workplace/hushine-worktrees/medium-cleanup/$repo" push -u origin cleanup/medium-baseline-20260710
done
```

If an affected repository uses an isolated local feature branch rather than the shared branch name, push that exact branch and record it in the handoff. Do not force-push.

- [ ] **Step 9: Report evidence, not only status**

The completion handoff must list:

- repository, branch, and final commit SHA;
- files added/modified/deleted and net line counts per repository;
- exact tests run and pass/fail counts;
- Mock matrix results for Futures/Spot and GTC/IOC/FOK/GTX;
- one-shot schema deployment result;
- real Demo smoke result or exact external blocker;
- any remaining exchange-backed observation risk.

---

## Plan self-review checklist

Before execution begins, verify:

- [ ] Every type and field name in Tasks 1–16 matches the canonical type contract.
- [ ] All five repository commit boundaries are explicit.
- [ ] Every behavior task starts with a failing test.
- [ ] No task writes to `strategy-debugger-cli`.
- [ ] No compatibility mode or dual protocol remains.
- [ ] Only `venue_income_entries` is added as a business table.
- [ ] Binance-specific behavior appears only in Binance Adapter/Mock files.
- [ ] Demo/Live actual totals and Backtest calculated totals are never interchanged.
- [ ] `last_applied_income_entry_id` survives Worker restart and cannot decrease.
- [ ] Spot, order modes, indicators, liquidation/ADL, multi-symbol, and blocked-Worker regressions are present.
- [ ] Local deployment is independent of `.10`.
- [ ] Final completion requires fresh evidence and remote SHAs.
