# RPC Surface Cleanup Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Preserve strategy validation and internal Venue routing while removing four approved, unused remote RPC transports and their generated surface.

**Architecture:** Saved strategy code is validated inside the Run/Preview startup gate before declaration loading. Core-service keeps its in-process `ResolveVenueRouteMeta` repository interface for Preflight and Order, while the credential-bearing `GetPortfolioMeta` and `GetVenueRouteMeta` remote methods disappear.

**Tech Stack:** proto3, Go gRPC, Python grpcio, pytest, Go test/vet.

## Global Constraints

- Remove transport only after its retained replacement has passing tests.
- Keep `PreflightStrategySession`, `ResolveVenueRouteMeta`, `ListSessionDeliveryHealth`, and `LiveStreamBinding`.
- Keep internal unroutable/backpressure counters even after deleting the diagnostics RPC.
- Regenerate protobufs with repository commands; never hand-edit generated code.
- All controlled clients may cut over together; no unknown external client compatibility is promised.
- Stage and commit each repository independently.

## Design Coverage

- D04: Task 3 removes two unused Portfolio metadata RPC transports only.
- D05: Task 2 removes the unused live-consumption diagnostics RPC.
- D06: Task 1 preserves validation in Run/Preview before Task 2 removes the standalone RPC.

---

## File Map

| File | Responsibility after this plan |
|---|---|
| `strategy-service/strategy_service/strategy_validator.py` | Saved-strategy static validation implementation |
| `strategy-service/strategy_service/grpc_server.py` | Run/Preview validation gate; no standalone validation/diagnostics RPC |
| `strategy-service/proto/strategy_service.proto` | Run/Preview/Status/Stop contract only, plus shared binding messages |
| `core-service/internal/order/portfoliometa/adapter.go` | In-process Order-to-Venue route adapter retained |
| `core-service/internal/repository/repository.go` | Retained `ResolveVenueRouteMeta` repository contract |
| `core-service/proto/portfolio_service.proto` | Portfolio RPCs without credential-bearing unused metadata methods |

### Task 1: Move saved-code validation into Run and Preview

**Files:**
- Modify: `strategy-service/strategy_service/grpc_server.py`
- Create: `strategy-service/tests/test_strategy_validation_preflight.py`
- Source tests: `strategy-service/tests/test_grpc_validate_strategy.py`

**Interfaces:**
- Consumes: `validate_strategy_code(code: str) -> StrategyValidationResult`.
- Produces: `_strategy_validation_error(code: str | None) -> str` and identical Run/Preview failure details.

- [ ] **Step 1: Write helper and parity tests first**

Create tests for a valid saved strategy and for syntax, unsupported dependency, and debugger-only dependency failures:

```python
from strategy_service.grpc_server import _strategy_validation_error


VALID = """
class MyStrategy:
    INPUTS = [{"exchange": "binance", "market": "perpetual_futures", "symbol": "BTCUSDT", "interval": "1m"}]
    ORDER_TARGETS = []
    def on_market_data(self, data, wallet):
        return None
"""


def test_saved_strategy_validation_accepts_current_contract():
    assert _strategy_validation_error(VALID) == ""


def test_saved_strategy_validation_returns_machine_readable_issues():
    error = _strategy_validation_error("import talib\n" + VALID)
    assert error.startswith("strategy code validation failed: ")
    assert '"code":"unsupported_dependency"' in error
    assert '"module":"talib"' in error


def test_file_path_strategy_defers_to_existing_loader_contract():
    assert _strategy_validation_error(None) == ""
```

Add Run and Preview tests using the existing active-strategy fake setup. Both must assert:

```python
assert context.code == grpc.StatusCode.FAILED_PRECONDITION
assert context.details == expected_validation_error
```

The fake active strategy code must contain `import talib` plus otherwise valid `MyStrategy` declarations so the failure is specifically the validator gate.

- [ ] **Step 2: Run the new tests and verify RED**

```bash
cd strategy-service
PYTHONPATH=.:../strategy-library uv run --frozen --extra dev pytest \
  tests/test_strategy_validation_preflight.py -q
```

Expected: collection fails because `_strategy_validation_error` does not exist.

- [ ] **Step 3: Implement the common error formatter**

Add `import json` with the standard-library imports, then add this module-level helper near other request-shaping helpers in `grpc_server.py`:

```python
def _strategy_validation_error(code: str | None) -> str:
    if code is None:
        return ""
    result = validate_strategy_code(code)
    if result.ok:
        return ""
    issues = [
        {
            "code": issue.code,
            "message": issue.message,
            "module": issue.module,
            "line": issue.line,
        }
        for issue in result.issues
    ]
    return "strategy code validation failed: " + json.dumps(
        issues, separators=(",", ":"), sort_keys=True
    )
```

Immediately after `_debug_strategy_source_for_db_code(...)` succeeds in both Run and Preview, add:

```python
validation_error = _strategy_validation_error(strategy_code)
if validation_error:
    context.set_code(grpc.StatusCode.FAILED_PRECONDITION)
    context.set_details(validation_error)
    return pb2.RunStrategyResponse()  # Preview uses PreviewRunStrategyResponse
```

`strategy_code is None` is the explicitly internal file-path path and remains governed by the existing loader/declaration checks.

- [ ] **Step 4: Run validation and startup tests**

```bash
cd strategy-service
PYTHONPATH=.:../strategy-library uv run --frozen --extra dev pytest \
  tests/test_strategy_validation_preflight.py \
  tests/test_preflight.py tests/test_grpc_server.py tests/test_mode0_parity_cutover.py -q
```

Expected: all selected tests pass and Run/Preview return identical validation details.

- [ ] **Step 5: Commit the retained behavior before transport deletion**

```bash
cd strategy-service
git add strategy_service/grpc_server.py tests/test_strategy_validation_preflight.py
git commit -m "fix: enforce saved strategy validation in preflight"
```

### Task 2: Remove standalone Strategy validation and diagnostics RPCs

**Files:**
- Modify: `strategy-service/proto/strategy_service.proto`
- Modify: `strategy-service/strategy_service/grpc_server.py`
- Delete: `strategy-service/tests/test_grpc_validate_strategy.py`
- Modify: `gateway/quant-handler/internal/app/strategy_route.go`
- Modify generated files under: `strategy-service/gen/strategyv1/`
- Modify generated files under: `strategy-service/strategy_service/gen/`
- Modify generated files under: `control-panel-service/gen/controlpanelv1/`

**Interfaces:**
- Keeps: RunStrategy, PreviewRunStrategy, GetStrategyStatus, StopStrategy, `LiveStreamBinding`.
- Removes: ValidateStrategyCode and GetLiveConsumptionDiagnostics transports.

- [ ] **Step 1: Add a contract scan that initially fails**

```bash
rg -n 'rpc (ValidateStrategyCode|GetLiveConsumptionDiagnostics)|ValidateStrategyCodeRequest|GetLiveConsumptionDiagnosticsRequest' \
  strategy-service/proto gateway/quant-handler/internal/app strategy-service/strategy_service
```

Expected before deletion: matches in the proto, servicer, tests, and handler interface shim.

- [ ] **Step 2: Remove only RPC-specific proto messages**

Delete:

```proto
rpc GetLiveConsumptionDiagnostics(...);
rpc ValidateStrategyCode(...);
message ValidateStrategyCodeRequest { ... }
message StrategyValidationIssue { ... }
message ValidateStrategyCodeResponse { ... }
message GetLiveConsumptionDiagnosticsRequest {}
message LiveSessionDiagnostic { ... }
message GetLiveConsumptionDiagnosticsResponse { ... }
```

Do not delete this shared message because Preview and RuntimeChannel paths use it:

```proto
message LiveStreamBinding {
  int64 stream_id = 1;
  string exchange = 2;
  string market = 3;
  string kind = 4;
  string symbol = 5;
  string interval = 6;
}
```

- [ ] **Step 3: Remove servicer methods and handler shims**

Delete `StrategyServiceServicer.ValidateStrategyCode` and
`StrategyServiceServicer.GetLiveConsumptionDiagnostics`. Keep
`validate_strategy_code` imported for `_strategy_validation_error`.

Delete these two methods from `controlPanelStrategyClient` in `strategy_route.go`:

```go
GetLiveConsumptionDiagnostics(...)
ValidateStrategyCode(...)
```

After proto regeneration, the client interface no longer requires them.

- [ ] **Step 4: Regenerate all affected Strategy contracts**

```bash
cd strategy-service
./generate_proto.sh
gofmt -w gen

cd ../control-panel-service
make proto
gofmt -w gen
```

Expected: generated Strategy interfaces contain only the retained RPCs.

- [ ] **Step 5: Verify and commit each repository**

```bash
cd strategy-service
if rg -n 'ValidateStrategyCode|GetLiveConsumptionDiagnostics|LiveSessionDiagnostic' \
  proto strategy_service gen --glob '!**/*.md'; then exit 1; fi
PYTHONPATH=.:../strategy-library uv run --frozen --extra dev pytest tests/ -q
go test ./...
git add proto strategy_service gen tests
git commit -m "refactor: remove unused strategy rpc transports"

cd ../gateway/quant-handler
go test ./...
go vet ./...
git add internal/app/strategy_route.go
git commit -m "refactor: drop removed strategy rpc shims"

cd ../../control-panel-service
go test ./...
go vet ./...
if ! git diff --quiet; then
  git add gen
  git commit -m "chore: refresh strategy proxy protobufs"
fi
```

Expected: tests pass; conditional control-panel commit occurs only if protoc changes tracked files.

### Task 3: Remove GetPortfolioMeta and GetVenueRouteMeta transports

**Files:**
- Modify: `core-service/proto/portfolio_service.proto`
- Modify: `core-service/internal/service/grpc.go`
- Modify: `core-service/internal/service/grpc_portfolio_meta_test.go`
- Modify generated files under: `core-service/gen/portfoliov1/`
- Modify generated copies under: `strategy-service/gen/portfoliov1/`
- Modify generated copies under: `strategy-service/strategy_service/gen/`

**Interfaces:**
- Keeps: `Repository.ResolveVenueRouteMeta(...)`, `PreflightStrategySession`, Order portfoliometa adapter.
- Removes: two credential-bearing gRPC methods and their dedicated messages.

- [ ] **Step 1: Preserve the existing retained-route characterization test**

`TestAdapterGetReturnsBacktestRouteMeta` already proves the in-process path. Keep these exact assertions while deleting the remote RPC:

```go
meta, err := NewAdapter(repo, nil).Get(context.Background(), 7, 1, 2)
if err != nil {
    t.Fatalf("Get() error = %v", err)
}
if repo.routeCalls != 1 {
    t.Fatalf("ResolveVenueRouteMeta calls = %d, want 1", repo.routeCalls)
}
if meta.PortfolioID != 7 || meta.VenueID != 88 || meta.UserID != 42 {
    t.Fatalf("meta identity = (%d,%d,%d), want (7,88,42)", meta.PortfolioID, meta.VenueID, meta.UserID)
}
```

- [ ] **Step 2: Run the retained internal-path test**

```bash
cd core-service
go test ./internal/order/portfoliometa -run TestAdapterGetReturnsBacktestRouteMeta -v
```

Expected: PASS before transport removal, establishing the replacement path.

- [ ] **Step 3: Delete the remote surface**

Remove both RPC declarations and these messages:

```proto
GetVenueRouteMetaRequest
GetVenueRouteMetaResponse
GetPortfolioMetaRequest
GetPortfolioMetaResponse
```

Delete only the two gRPC server methods from `internal/service/grpc.go`. Delete the five tests whose names start with `TestGetVenueRouteMeta` or `TestGetPortfolioMeta`.

Do not remove any occurrence of:

```go
ResolveVenueRouteMeta(ctx context.Context, portfolioID int64, exchange domain.Exchange, market domain.Market)
```

- [ ] **Step 4: Regenerate Core and Strategy copies**

```bash
cd core-service
make proto-portfolio
gofmt -w gen/portfoliov1

cd ../strategy-service
./generate_proto.sh
gofmt -w gen
```

- [ ] **Step 5: Verify zero transport references and retained repository use**

```bash
if rg -n 'GetPortfolioMeta|GetVenueRouteMeta' \
  core-service strategy-service control-panel-service gateway/quant-handler \
  --glob '!**/*.md' --glob '!**/logs/**'; then exit 1; fi
rg -n 'ResolveVenueRouteMeta' core-service/internal

cd core-service
go test ./...
go vet ./...

cd ../strategy-service
PYTHONPATH=.:../strategy-library uv run --frozen --extra dev pytest tests/ -q
go test ./...
```

Expected: no removed transport symbols; internal repository/Order/Preflight uses remain and tests pass.

- [ ] **Step 6: Commit both repositories**

```bash
cd core-service
git add proto gen internal/service internal/order/portfoliometa
git commit -m "refactor: remove unused portfolio metadata rpcs"

cd ../strategy-service
git add gen strategy_service/gen
git commit -m "chore: refresh portfolio protobuf contract"
```

### Task 4: Cross-repository protocol verification

**Files:**
- Verify only; no planned edits.

- [ ] **Step 1: Run protocol and build checks**

```bash
cd core-service && make proto && go test ./... && go vet ./...
cd ../strategy-service && ./generate_proto.sh && go test ./... && go vet ./...
PYTHONPATH=.:../strategy-library uv run --frozen --extra dev pytest tests/ -q
cd ../control-panel-service && make proto && go test ./... && go vet ./...
cd ../gateway/quant-handler && go test ./... && go vet ./...
```

Expected: generators are idempotent after the first run and all commands exit 0.

- [ ] **Step 2: Run final negative and positive scans**

```bash
cd /Users/xdy/Workplace/hushine
if rg -n 'GetPortfolioMeta|GetVenueRouteMeta|GetLiveConsumptionDiagnostics|ValidateStrategyCode' \
  core-service control-panel-service gateway strategy-service \
  --glob '!**/.git/**' --glob '!**/*.md' --glob '!**/logs/**'; then exit 1; fi
rg -n 'ResolveVenueRouteMeta|PreflightStrategySession|ListSessionDeliveryHealth|LiveStreamBinding' \
  core-service control-panel-service gateway strategy-service \
  --glob '!**/.git/**' --glob '!**/logs/**'
```

Expected: removed symbols have zero current code references; all retained replacement symbols have production references.

- [ ] **Step 3: Confirm clean, synchronized repository state before the DB plan**

```bash
for repo in core-service strategy-service control-panel-service gateway/quant-handler; do
  git -C "$repo" status --short
  git -C "$repo" log -1 --oneline
done
```

Expected: each worktree is clean and shows the task's latest commit.
