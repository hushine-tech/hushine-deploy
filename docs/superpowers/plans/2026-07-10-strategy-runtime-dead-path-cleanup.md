# Strategy Runtime Dead-Path Cleanup Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Remove the obsolete TimescaleDB/Kafka direct execution loops, Python runtime config loader, and direct Market Data gRPC client without changing paged backtests or RuntimeChannel live execution.

**Architecture:** The Go runtime-agent remains the only runtime config owner and launches the isolated Python session worker. The Python worker receives historical/live data through the platform proxy; a focused `marketdata_adapter.py` keeps the still-live K-line conversion logic after `data_loop.py` is deleted.

**Tech Stack:** Python 3.13, pytest, uv, Go 1.26, gRPC/protobuf, RuntimeChannel.

## Global Constraints

- Preserve every approved product feature from the design spec.
- Runtime routing remains `runtime_id` only.
- Runtime code must not receive internal DB, Kafka, Portfolio, or Order addresses.
- Do not delete `_adapt_kline`; move it before deleting `data_loop.py`.
- Do not edit generated protobuf files by hand.
- Preserve dirty work and stage only files listed by the active task.
- Run repository-scoped tests after every task.

## Design Coverage

- D01: Tasks 1-2 remove the old direct data loops while preserving `_adapt_kline`.
- D02: Task 3 removes the Python runtime config loader.
- D03: Task 3 removes the direct Python Market Data gRPC client.
- D10: Task 4 updates proto comments and regenerated descriptors.

---

## File Map

| File | Responsibility after this plan |
|---|---|
| `strategy-service/strategy_service/marketdata_adapter.py` | Convert platform `MarketKline` messages to framework `MarketData` |
| `strategy-service/strategy_service/grpc_server.py` | Current Run/Preview/Status/Stop execution using platform proxy data |
| `strategy-service/strategy_service/session.py` | Session state without the old `LiveDataLoop` compatibility hook |
| `strategy-service/internal/runtimeagent/config.go` | Sole runtime YAML/environment config loader |
| `strategy-service/scripts/smoke_strategy_runtime.sh` | Container smoke for Go agent plus Python worker imports |
| `strategy-service/proto/strategy_service.proto` | Current Strategy RPC contract and current data-path comments |

### Task 1: Extract the live K-line adapter

**Files:**
- Create: `strategy-service/strategy_service/marketdata_adapter.py`
- Create: `strategy-service/tests/test_marketdata_adapter.py`
- Modify: `strategy-service/strategy_service/grpc_server.py`
- Source to remove later: `strategy-service/strategy_service/data_loop.py`

**Interfaces:**
- Consumes: `market_data.models.MarketKline`, `strategy_service.types.MarketData`.
- Produces: `_adapt_kline(kline: MarketKline, market: str | None = None) -> MarketData`.

- [ ] **Step 1: Add adapter characterization tests**

Move the two `_adapt_kline` tests from `tests/test_data_loop.py` into the new test file. The resulting test must cover explicit and fallback markets:

```python
from market_data.models import MarketKline
from strategy_service.marketdata_adapter import _adapt_kline


def test_adapt_kline_maps_explicit_market_and_ohlcv():
    kline = MarketKline(
        symbol="BTCUSDT", interval="1m",
        open_time=1_700_000_000_000, close_time=1_700_000_059_999,
        open=100.0, high=110.0, low=90.0, close=105.0,
        volume=12.5, timestamp=1_700_000_059_999,
    )
    actual = _adapt_kline(kline, "spot")
    assert actual.symbol == "BTCUSDT"
    assert actual.market == "spot"
    assert actual.interval == "1m"
    assert actual.price == 105.0
    assert actual.klines == {
        "open": 100.0, "high": 110.0, "low": 90.0,
        "close": 105.0, "volume": 12.5,
    }


def test_adapt_kline_defaults_missing_market_to_futures():
    kline = MarketKline(
        symbol="ETHUSDT", interval="5m", open_time=1, close_time=2,
        open=1.0, high=2.0, low=0.5, close=1.5,
        volume=3.0, timestamp=2,
    )
    actual = _adapt_kline(kline)
    assert actual.market == "futures"
    assert actual.orderbook is None
    assert actual.oi is None
    assert actual.funding_rate is None
```

- [ ] **Step 2: Run the new test and verify RED**

```bash
cd strategy-service
PYTHONPATH=.:../strategy-library uv run --frozen --extra dev pytest tests/test_marketdata_adapter.py -q
```

Expected: collection fails because `strategy_service.marketdata_adapter` does not exist.

- [ ] **Step 3: Create the focused adapter module**

```python
from __future__ import annotations

from market_data.models import MarketKline

from strategy_service.types import MarketData


def _adapt_kline(kline: MarketKline, market: str | None = None) -> MarketData:
    resolved_market = market
    if resolved_market is None:
        raw_market = getattr(kline, "market", None)
        resolved_market = (
            raw_market.strip().lower()
            if isinstance(raw_market, str) and raw_market.strip()
            else "futures"
        )
    return MarketData(
        symbol=kline.symbol,
        price=float(kline.close),
        timestamp=kline.timestamp,
        market=resolved_market,
        interval=str(getattr(kline, "interval", "") or "1m").strip(),
        klines={
            "open": kline.open, "high": kline.high, "low": kline.low,
            "close": kline.close, "volume": kline.volume,
        },
        orderbook=None, oi=None, funding_rate=None,
    )
```

Change both lazy imports in `grpc_server.py` from `strategy_service.data_loop` to `strategy_service.marketdata_adapter`.

- [ ] **Step 4: Run adapter and execution-path tests**

```bash
cd strategy-service
PYTHONPATH=.:../strategy-library uv run --frozen --extra dev pytest \
  tests/test_marketdata_adapter.py tests/test_backtest_pages.py tests/test_grpc_server.py -q
```

Expected: all selected tests pass.

- [ ] **Step 5: Commit the extraction**

```bash
cd strategy-service
git add strategy_service/marketdata_adapter.py strategy_service/grpc_server.py \
  tests/test_marketdata_adapter.py
git commit -m "refactor: isolate platform market data adapter"
```

### Task 2: Delete the obsolete BacktestDataLoop and LiveDataLoop

**Files:**
- Delete: `strategy-service/strategy_service/data_loop.py`
- Delete: `strategy-service/tests/test_data_loop.py`
- Modify: `strategy-service/strategy_service/__init__.py`
- Modify: `strategy-service/strategy_service/session.py`
- Modify: `strategy-service/strategy_service/grpc_server.py`
- Modify: `strategy-service/tests/test_grpc_server.py`

**Interfaces:**
- Consumes: Task 1 `_adapt_kline` module.
- Produces: Session stop based only on `_stop_event` and lease stop events.

- [ ] **Step 1: Rewrite stop tests around the current stop mechanism**

In the two tests that create `FakeLiveLoop`, remove the fake loop and `state.live_loop` assignment. Keep:

```python
assert resp.stopped is True
assert stop_event.is_set() is True
assert state.lease_stop_event is not None
assert state.lease_stop_event.is_set() is True
```

Add:

```python
def test_session_state_has_no_legacy_live_loop_hook():
    state = SessionState(environment=1, user_id=17, portfolio_id=404)
    assert not hasattr(state, "live_loop")
```

- [ ] **Step 2: Run the hook-removal test and verify RED**

```bash
cd strategy-service
PYTHONPATH=.:../strategy-library uv run --frozen --extra dev pytest \
  tests/test_grpc_server.py -k 'legacy_live_loop_hook' -q
```

Expected: FAIL because `SessionState.live_loop` still exists.

- [ ] **Step 3: Remove compatibility code**

Apply these resulting structures:

```python
# strategy_service/__init__.py
# BacktestDataLoop and LiveDataLoop are absent from __all__ and __getattr__.

# strategy_service/session.py
# No TYPE_CHECKING LiveDataLoop import, live_loop field, or set_live_loop method.

# strategy_service/grpc_server.py
@staticmethod
def _halt_session_runtime(state: SessionState, *, finalize: bool) -> None:
    if state.lease_stop_event is not None:
        state.lease_stop_event.set()
    if finalize:
        stop_event = getattr(state, "_stop_event", None)
        if stop_event is not None:
            stop_event.set()
```

Delete `data_loop.py` and the remaining Loop-only `test_data_loop.py`. Also replace the
`grpc_server.py` comment that cites `data_loop.BacktestDataLoop.run_declared` with a
transport-neutral statement that declared `(exchange, market, symbol, interval)` inputs
are preserved without flattening.

- [ ] **Step 4: Run negative scans and tests**

```bash
cd strategy-service
if rg -n 'BacktestDataLoop|LiveDataLoop|set_live_loop|state\.live_loop' \
  strategy_service tests --glob '!strategy_service/gen/**'; then exit 1; fi
PYTHONPATH=.:../strategy-library uv run --frozen --extra dev pytest tests/ -q
go test ./...
```

Expected: the scan returns no matches and both test commands pass.

- [ ] **Step 5: Commit the deletion**

```bash
cd strategy-service
git add strategy_service tests
git commit -m "refactor: remove legacy direct data loops"
```

### Task 3: Remove the Python config loader and direct Market Data client

**Files:**
- Delete: `strategy-service/strategy_service/config.py`
- Delete: `strategy-service/tests/test_config_env.py`
- Delete: `strategy-service/strategy_service/marketdata_client.py`
- Modify: `strategy-service/scripts/smoke_strategy_runtime.sh`
- Modify: `strategy-service/pyproject.toml`
- Modify: `strategy-service/uv.lock`
- Test: `strategy-service/internal/runtimeagent/config_test.go`

**Interfaces:**
- Consumes: Go `runtimeagent.LoadConfig(path) (Config, error)`.
- Produces: container smoke that checks the real Go config owner and Python worker imports.

- [ ] **Step 1: Replace the legacy Python config smoke**

Use this Python import smoke and keep the separate `runtime-agent --help` smoke:

```bash
docker run --rm --entrypoint python "${IMAGE}" -c "
import sys
print('python:', sys.version.split()[0])
from strategy_service.gen import control_panel_service_pb2 as cp
from strategy_service.gen import runtime_worker_pb2 as worker
from strategy_service.session_worker_entry import main as worker_main
print('runtime proto:', cp.RuntimeHello.DESCRIPTOR.full_name)
print('worker proto:', worker.WorkerFrame.DESCRIPTOR.full_name)
print('worker entry:', worker_main.__name__)
print('OK')
"
```

- [ ] **Step 2: Verify the current smoke dependency before and after editing**

```bash
cd strategy-service
rg -n 'strategy_service\.config|Config\.load' scripts/smoke_strategy_runtime.sh
```

Expected before editing: matches. Expected after editing: no matches.

- [ ] **Step 3: Delete dead modules and direct dependency**

Delete the three files listed above. Remove only this direct project dependency from `pyproject.toml`:

```toml
"PyYAML>=6.0.0",
```

Then run:

```bash
cd strategy-service
uv lock
```

PyYAML may remain transitive in `uv.lock`; the project package must no longer list it directly.

- [ ] **Step 4: Verify ownership and run tests**

```bash
cd strategy-service
if rg -n 'strategy_service\.config|from strategy_service\.config|\bMarketDataClient\(' \
  strategy_service scripts tests --glob '!gen/**'; then exit 1; fi
bash -n scripts/smoke_strategy_runtime.sh
go test ./internal/runtimeagent/... ./cmd/runtime-agent/...
PYTHONPATH=.:../strategy-library uv run --frozen --extra dev pytest tests/ -q
```

Expected: no legacy references and all tests pass.

- [ ] **Step 5: Commit the cleanup**

```bash
cd strategy-service
git add pyproject.toml uv.lock scripts/smoke_strategy_runtime.sh strategy_service tests
git commit -m "refactor: remove legacy python runtime clients"
```

### Task 4: Update the Strategy proto data-path description

**Files:**
- Modify: `strategy-service/proto/strategy_service.proto`
- Modify generated files under: `strategy-service/gen/strategyv1/`
- Modify generated files under: `strategy-service/strategy_service/gen/`
- Modify generated imported contract under: `strategy-service/gen/controlpanelv1/`

**Interfaces:**
- Produces: generated descriptors whose comments no longer name deleted Loop classes.

- [ ] **Step 1: Record the stale-comment RED state**

```bash
cd strategy-service
rg -n 'BacktestDataLoop|LiveDataLoop' proto gen strategy_service/gen
```

Expected: current proto and generated comments contain matches.

- [ ] **Step 2: Replace the RunStrategy comment**

```proto
// RunStrategy starts strategy execution and returns immediately with a session_id.
// Data delivery is selected from the Portfolio environment:
//   environment=0 (backtest) -> paged historical reads through the platform proxy
//   environment=1 (demo)     -> RuntimeChannel live K-line and order-update frames
//   environment=2 (live)     -> RuntimeChannel, rollout-guarded and fail-closed
```

- [ ] **Step 3: Regenerate checked-in code**

```bash
cd strategy-service
./generate_proto.sh
gofmt -w gen
```

Expected: only generated files derived from current workspace protos change.

- [ ] **Step 4: Verify generated-code scope**

```bash
cd strategy-service
if rg -n 'BacktestDataLoop|LiveDataLoop' proto gen strategy_service/gen; then exit 1; fi
git diff --check
go test ./...
PYTHONPATH=.:../strategy-library uv run --frozen --extra dev pytest tests/ -q
```

Expected: no old Loop names and tests pass.

- [ ] **Step 5: Commit proto regeneration**

```bash
cd strategy-service
git add proto gen strategy_service/gen
git commit -m "docs: describe platform strategy data delivery"
```

### Task 5: Repository verification checkpoint

**Files:**
- Verify only; no planned edits.

- [ ] **Step 1: Run complete Strategy Service verification**

```bash
cd strategy-service
PYTHONPATH=.:../strategy-library uv run --frozen --extra dev pytest tests/ -q
go test ./...
go vet ./...
for test_script in scripts/*.test.sh; do bash "$test_script"; done
bash -n scripts/smoke_strategy_runtime.sh
```

Expected: every command exits 0; no tracked shell test is skipped.

- [ ] **Step 2: Review the deletion boundary**

```bash
cd strategy-service
git status --short
git log --oneline -4
rg -n 'PagedBacktestDataSource|iter_session_events|_adapt_kline' \
  strategy_service/grpc_server.py strategy_service/marketdata_adapter.py
```

Expected: paged backtest, RuntimeChannel event iteration, and the adapter remain; worktree is clean after commits.
