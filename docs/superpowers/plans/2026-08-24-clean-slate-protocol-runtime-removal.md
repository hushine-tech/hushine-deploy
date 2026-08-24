# Clean-Slate Protocol and Runtime Removal Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Remove Session-wide leverage and every pre-bootstrap Runtime start/restart/publication path while preserving strategy-owned per-target leverage and the current RuntimeChannel lifecycle.

**Architecture:** Authored protobuf schemas become the only protocol authority. Runtime-agent always prepares and commits a typed Session bootstrap before worker launch; strategy-service always consumes that bootstrap, and all HTTP/UI consumers expose only per-target leverage facts.

**Tech Stack:** Protocol Buffers, Go, Python 3.13, gRPC, TypeScript/React, Node.js

**Spec:** `docs/superpowers/specs/2026-08-24-clean-slate-compatibility-removal-design.md`

## Global Constraints

- Hushine has no production compatibility or database-upgrade requirement.
- Preserve strategy `LEVERAGE` and `ORDER_TARGETS[].leverage`, Binance apply/readback/rollback, durable target facts, RuntimeChannel, and worker heartbeat isolation.
- Remove old fields rather than accepting, clearing, stripping, translating, or displaying them.
- Generated protobuf files are regenerated from authored schemas and never edited by hand.
- Stage and commit only owned files inside each independent repository.

---

### Task 1: Pin the canonical protocol surface

**Files:**
- Modify: `strategy-service/tests/test_generated_proto_imports.py`
- Modify: `strategy-service/tests/test_runtime_worker_proto.py`
- Modify: `core-service/internal/service/grpc_strategy_test.go`
- Modify: `gateway/quant-frontend/scripts/strategy-leverage-display.test.mjs`

**Interfaces:**
- Consumes: current generated `strategy.v1` and `portfolio.v1` descriptors.
- Produces: failing source-contract tests that require removed scalar fields to be absent and typed bootstrap to be mandatory.

- [ ] **Step 1: Replace deprecated-field assertions with absence assertions**

```python
from strategy_service.gen import strategy_service_pb2 as strategy_pb2

def test_session_wide_leverage_fields_do_not_exist():
    assert "leverage" not in strategy_pb2.RunStrategyRequest.DESCRIPTOR.fields_by_name
    assert "leverage" not in strategy_pb2.PreviewRunStrategyRequest.DESCRIPTOR.fields_by_name
    assert "leverage" not in strategy_pb2.RiskControls.DESCRIPTOR.fields_by_name
    assert "leverage_source" not in strategy_pb2.RiskControls.DESCRIPTOR.fields_by_name
    assert "leverage" not in portfolio_pb2.PreflightStrategySessionRequest.DESCRIPTOR.fields_by_name
    assert "leverage" not in portfolio_pb2.StrategySessionEntry.DESCRIPTOR.fields_by_name
    assert "leverage" not in portfolio_pb2.SaveSessionRequest.DESCRIPTOR.fields_by_name
```

- [ ] **Step 2: Require every worker start to carry typed bootstrap**

```python
def test_start_without_typed_bootstrap_is_rejected():
    start = pb2.StartSession(session_id="1" * 32)
    with pytest.raises(RuntimeError, match="bootstrap is required"):
        session_worker_entry._validated_start_bootstrap(start)
```

The wished-for API has no `required` flag: all worker starts require bootstrap.

- [ ] **Step 3: Require frontend source to contain no scalar-stripping or historical fallback**

```javascript
assert.equal(clientSource.includes("withoutLegacyLeverage"), false);
assert.equal(clientSource.includes("Legacy session value"), false);
assert.equal(clientSource.includes("Historical session"), false);
```

- [ ] **Step 4: Run the focused tests and verify RED**

```bash
cd strategy-service
PYTHONPATH=.:../strategy-library uv run --frozen --extra dev pytest \
  tests/test_generated_proto_imports.py tests/test_runtime_worker_proto.py -q
cd ../core-service
go test ./internal/service -run 'Session.*Leverage|Strategy.*Session' -count=1
cd ../gateway/quant-frontend
node scripts/strategy-leverage-display.test.mjs
```

Expected: failures show the seven scalar protobuf fields and frontend fallback still exist.

- [ ] **Step 5: Commit the red contract tests in their owning repositories**

```bash
git -C strategy-service add tests/test_generated_proto_imports.py tests/test_runtime_worker_proto.py
git -C strategy-service commit -m "test: require bootstrap-only leverage protocol"
git -C core-service add internal/service/grpc_strategy_test.go
git -C core-service commit -m "test: reject session-wide leverage protocol"
git -C gateway/quant-frontend add scripts/strategy-leverage-display.test.mjs
git -C gateway/quant-frontend commit -m "test: require target-only leverage display"
```

### Task 2: Delete scalar leverage from authored protobuf and core persistence

**Files:**
- Modify: `core-service/proto/portfolio_service.proto`
- Modify: `core-service/internal/domain/model.go`
- Modify: `core-service/internal/repository/timescale.go`
- Modify: `core-service/internal/service/grpc.go`
- Modify: `core-service/internal/service/strategy_leverage_start.go`
- Modify: `core-service/internal/storage/migrations/0001_current_schema_baseline.sql`
- Delete: `core-service/internal/storage/migrations/0008_strategy_session_deprecated_leverage_zero.sql`
- Regenerate: `core-service/gen/portfoliov1/portfolio_service.pb.go`
- Regenerate: `core-service/gen/portfoliov1/portfolio_service_grpc.pb.go`
- Modify: `core-service/internal/repository/session_leverage_test.go`
- Modify: `core-service/internal/storage/migrations/migration_contract_test.go`

**Interfaces:**
- Consumes: per-target `RequiredSymbol.effective_leverage` and `SessionTargetLeverageFact`.
- Produces: Session rows and responses with target facts only; no `strategy_sessions.leverage` column.

- [ ] **Step 1: Delete the three scalar fields from `portfolio_service.proto`**

Remove `PreflightStrategySessionRequest.leverage`, `StrategySessionEntry.leverage`, and `SaveSessionRequest.leverage`, including compatibility comments. Do not add replacement or reserved declarations.

- [ ] **Step 2: Regenerate core-service Go stubs**

```bash
cd core-service
make proto-portfolio
```

Expected: generated `GetLeverage` accessors for those three messages disappear.

- [ ] **Step 3: Remove the Session scalar from the domain and database baseline**

Delete `StrategySession.Leverage`, the `strategy_sessions.leverage` column and constraint, select/scan/bind entries, both `normalizeSessionLeverage` helpers, `preserveLegacyLeverage`, and target-fact scalar clearing.

The insert helper becomes:

```go
func saveSessionTx(ctx context.Context, tx *sql.Tx, s domain.StrategySession) error
```

Both repository call sites use that signature; no boolean mode remains.

- [ ] **Step 4: Make Session protobuf conversion always emit target facts**

```go
e.TargetLeverageFacts = make([]*portfoliov1.SessionTargetLeverageFact, 0, len(s.TargetLeverageFacts))
for _, fact := range s.TargetLeverageFacts {
    e.TargetLeverageFacts = append(e.TargetLeverageFacts, toProtoSessionTargetLeverageFact(fact))
}
```

Remove every conditional that substitutes a Session scalar when facts are empty.

- [ ] **Step 5: Delete scalar-specific migration and repository tests**

Delete tests that preserve `0`, default `1`, or a historical positive scalar. Retain tests for mixed per-target facts, Spot sessions with no Futures facts, atomic commit, rollback, and readback.

- [ ] **Step 6: Run core focused verification**

```bash
cd core-service
go test ./internal/repository ./internal/service ./internal/storage/migrations -count=1
go vet ./internal/repository ./internal/service/...
```

Expected: PASS and `rg -n 'normalizeSessionLeverage|preserveLegacyLeverage|GetLeverage\(\)' internal proto` finds no Session-scalar reference.

- [ ] **Step 7: Commit core cutover**

```bash
git -C core-service add proto gen internal
git -C core-service commit -m "refactor: remove session-wide leverage compatibility"
```

### Task 3: Require typed bootstrap in strategy-service and runtime-agent

**Files:**
- Modify: `strategy-service/proto/strategy_service.proto`
- Modify: `strategy-service/strategy_service/grpc_server.py`
- Modify: `strategy-service/strategy_service/session.py`
- Modify: `strategy-service/strategy_service/portfolio_client.py`
- Modify: `strategy-service/strategy_service/platform_proxy.py`
- Modify: `strategy-service/strategy_service/session_worker_entry.py`
- Modify: `strategy-service/internal/runtimeagent/agent.go`
- Modify: `strategy-service/internal/runtimeagent/local_control.go`
- Modify: `strategy-service/scripts/restart_bare_worker_session.py`
- Modify: `strategy-service/scripts/restart-bare-worker-session.sh`
- Regenerate: `strategy-service/gen/**`
- Regenerate: `strategy-service/strategy_service/gen/**`
- Modify: `strategy-service/tests/test_grpc_server.py`
- Modify: `strategy-service/tests/test_portfolio_client_runtime_binding.py`
- Modify: `strategy-service/tests/test_platform_proxy.py`
- Modify: `strategy-service/internal/runtimeagent/agent_test.go`
- Modify: `strategy-service/internal/runtimeagent/local_control_test.go`

**Interfaces:**
- Consumes: `PreparedRunStrategyStart`, committed `StrategySessionBootstrap`, and confirmed target facts.
- Produces: one bootstrap-required worker path and restart API with no leverage override.

- [ ] **Step 1: Remove strategy scalar fields and regenerate all vendored stubs**

Delete `RunStrategyRequest.leverage`, `PreviewRunStrategyRequest.leverage`, and `RiskControls.leverage/leverage_source`, then run:

```bash
cd strategy-service
PYTHON=.venv/bin/python ./generate_proto.sh
```

Expected: generated strategy and copied portfolio descriptors contain no removed fields.

- [ ] **Step 2: Delete the scalar compatibility bridge**

Delete `DEFAULT_SESSION_LEVERAGE`, `_SessionLeverageCompatibility`, `_TargetLeverageCapabilityError`, `_session_leverage_compatibility`, scalar client arguments, and fallback fields from `SessionState`.

`configure_risk_runtime` accepts only:

```python
def configure_risk_runtime(
    self,
    *,
    order_target_keys: set[tuple[str, str, str]],
    max_loss_close_pct: float,
    max_loss_close_source: str,
    target_leverage_facts: dict[tuple[str, str, str], tuple[int, str, int]],
    initial_margin_balance: float = 0.0,
) -> None:
```

`leverage_for_target` raises when a requested Futures target has no confirmed fact; it never returns a Session default.

- [ ] **Step 3: Delete the pre-bootstrap RunStrategy branch**

Remove `require_session_bootstrap` as a feature flag. A servicer that handles `RunStrategy` requires `session_bootstrap`; preview and validation remain bootstrap-free and side-effect-free.

Delete direct start portfolio preflight and `SaveSession`, compatibility publication/release, old terminal persistence fallback, and protocol-generation expected-status selection. Keep bootstrap validation, pending-to-running CAS, abort, final status, indicator finalization, and market-data release.

- [ ] **Step 4: Remove leverage from restart control**

`RestartSessionOptions` and `/restart-worker-session` accept only `session_id` and optional `max_loss_close_pct`. `restartRunRequest` never copies Session leverage; the new worker rereads source and derives target leverage through prepare/commit.

- [ ] **Step 5: Rewrite tests around the only current path**

Delete tests for a missing capability marker, mixed-target scalar rejection, direct SaveSession, and restart scalar overrides. Keep tests for bootstrap identity/digest mismatch, missing confirmed target facts, new operation/Session on restart, worker cleanup/recoverable transition, and blocked-worker heartbeat isolation.

- [ ] **Step 6: Run strategy-service focused verification**

```bash
cd strategy-service
PYTHONPATH=.:../strategy-library uv run --frozen --extra dev pytest \
  tests/test_generated_proto_imports.py \
  tests/test_runtime_worker_proto.py \
  tests/test_grpc_server.py \
  tests/test_portfolio_client_runtime_binding.py \
  tests/test_platform_proxy.py -q
go test ./internal/runtimeagent/... -count=1
bash scripts/runtime-agent-platform.test.sh
bash scripts/start-bare-runtime-debugpy.test.sh
```

- [ ] **Step 7: Commit strategy/runtime cutover**

```bash
git -C strategy-service add proto gen strategy_service internal scripts tests
git -C strategy-service commit -m "refactor: require target-leverage runtime bootstrap"
```

### Task 4: Remove gateway and control-plane scalar surfaces

**Files:**
- Modify: `control-panel-service/internal/runtimechannel/platform_proxy.go`
- Modify: `control-panel-service/internal/runtimechannel/platform_proxy_test.go`
- Modify: `gateway/quant-handler/internal/app/strategy.go`
- Modify: `gateway/quant-handler/internal/app/backtest_download_jobs.go`
- Modify: `gateway/quant-handler/internal/app/session_history.go`
- Modify: `gateway/quant-handler/internal/app/strategy_test.go`
- Modify: `gateway/quant-handler/internal/app/strategy_cutover_test.go`
- Modify: `gateway/quant-handler/internal/app/backtest_coverage_test.go`
- Modify: `gateway/quant-handler/internal/app/session_history_test.go`
- Modify: `gateway/quant-frontend/src/api/client.ts`
- Modify: `gateway/quant-frontend/src/pages/SessionDetailPage.tsx`
- Modify: `gateway/quant-frontend/scripts/strategy-leverage-display.test.mjs`

**Interfaces:**
- Consumes: target-level preview, apply result, and durable Session facts.
- Produces: HTTP/UI contract with no Session-wide leverage input or historical scalar output.

- [ ] **Step 1: Delete scalar JSON fields and forwarding guards**

Remove leverage from run, preview, download, risk-controls, and Session history JSON types. Remove `withoutLegacyLeverage` and serialize typed request objects directly.

- [ ] **Step 2: Simplify Session leverage display**

`sessionLeverageDisplayFacts` accepts only `target_leverage_facts` and maps every fact to its confirmed value. Remove `historical` from `SessionLeverageDisplayFact` and React keys.

- [ ] **Step 3: Remove control-panel scalar clearing**

Delete `session.Leverage = 0` and its test assertion. Identity rebinding and authorization checks remain unchanged.

- [ ] **Step 4: Run gateway/control verification**

```bash
cd control-panel-service
go test ./internal/runtimechannel -count=1
go vet ./internal/runtimechannel/...
cd ../gateway/quant-handler
go test ./internal/app -run 'Strategy|SessionHistory|DownloadAndRun|Leverage' -count=1
go vet ./internal/app/...
cd ../quant-frontend
node scripts/strategy-leverage-display.test.mjs
npm run build
```

- [ ] **Step 5: Commit each repository**

```bash
git -C control-panel-service add internal/runtimechannel
git -C control-panel-service commit -m "refactor: remove leverage relay compatibility"
git -C gateway/quant-handler add internal/app
git -C gateway/quant-handler commit -m "refactor: remove session leverage HTTP compatibility"
git -C gateway/quant-frontend add src scripts/strategy-leverage-display.test.mjs
git -C gateway/quant-frontend commit -m "refactor: display target leverage facts only"
```

### Task 5: Run the protocol/runtime phase gate

**Files:**
- Modify only if a current-path regression is found; never restore a removed contract.

**Interfaces:**
- Consumes: Tasks 1–4.
- Produces: a buildable cross-repository current protocol before Spot/decimal cleanup begins.

- [ ] **Step 1: Sweep removed symbols**

```bash
rg -n 'withoutLegacyLeverage|_SessionLeverageCompatibility|preserveLegacyLeverage|normalizeSessionLeverage|Legacy session value|Historical session|require_session_bootstrap|RestartSessionOptions.*Leverage' \
  core-service control-panel-service strategy-service gateway
```

Expected: no production match.

- [ ] **Step 2: Run full affected repository suites**

```bash
cd core-service && go test ./... && go vet ./...
cd ../control-panel-service && go test ./... && go vet ./...
cd ../strategy-service && make test
cd ../gateway/quant-handler && go test ./... && go vet ./...
cd ../quant-frontend && for test_file in scripts/*.test.mjs; do node "$test_file"; done && npm run build
```

- [ ] **Step 3: Record phase line accounting**

Record the following totals and separate generated files from handwritten production, tests, migrations, and documentation:

```bash
git -C core-service diff --numstat 6b7b6aec02bad86d363627f3f0ca7465556ee5fa...HEAD
git -C control-panel-service diff --numstat ada3ab0614fbec84e8420a0c1ded5fac11e4108b...HEAD
git -C strategy-service diff --numstat 4d2835ad099eed41760b34b0975d7ef0e69ec91d...HEAD
git -C gateway/quant-handler diff --numstat 74575981de53f5cb4313171895718d03d2ff4d0c...HEAD
git -C gateway/quant-frontend diff --numstat 6e59bd1a5c55e65a0041722fffae07996b90be54...HEAD
```
