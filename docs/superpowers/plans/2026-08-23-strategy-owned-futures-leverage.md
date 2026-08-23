# Strategy-Owned Futures Leverage Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the strategy declaration the only leverage authority, keep preview read-only, configure and confirm Binance Futures leverage before launching a session worker, persist per-symbol facts, and remove leverage controls from the UI without changing Spot or Backtest safety boundaries.

**Architecture:** Strategy parsing computes immutable per-target leverage intents. Preview uses the existing one-shot runtime worker and a read-only core-service preflight. Start uses a one-shot preparation worker, then runtime-agent asks core-service to acquire account/symbol admission, apply/read-back/rollback Binance settings, and atomically create the pending Session plus per-target facts. Only after that commit may runtime-agent launch the final session worker, passing a typed bootstrap that the worker revalidates against the current strategy source and canonical wallet metadata.

**Tech Stack:** Python 3.13, `uv`, pytest, Go, gRPC/protobuf, TimescaleDB/PostgreSQL migrations, React/TypeScript, Node script tests, Binance Futures REST adapter, RuntimeChannel, Docker Compose coverage environment.

**Spec:** `../specs/2026-08-23-strategy-owned-futures-leverage-design.md`

## Global Constraints

- Work from `/Users/xdy/Workplace/hushine-worktrees/medium-cleanup`; the workspace root is not a Git repository, so commit inside each affected repository only.
- Preserve all existing commits and user work. Stage only files/hunks owned by this change; do not reset, force-push, amend unrelated commits, or remove compatibility fields.
- Keep `RunStrategyRequest.leverage`, `PreviewRunStrategyRequest.leverage`, `SaveSessionRequest.leverage`, and `strategy_sessions.leverage` wire/schema-compatible but deprecated. New execution paths must ignore request leverage and must not read the legacy Session scalar for new Sessions.
- Route Sessions only by `runtime_id`; do not expose internal DB/Kafka/order addresses or Venue credentials to self-hosted/bare runtimes.
- Preview must remain side-effect free: no Binance leverage POST, no admission lease, no launch journal mutation, and no Session leverage-fact write.
- The final session worker must not be created until core-service reports that every Futures target is confirmed and the pending Session/facts transaction is committed. A temporary one-shot preparation worker may validate code, but it must never enter strategy execution.
- Spot targets never carry leverage. Backtest and strategy-debugger-cli reuse declaration resolution but never contact Binance or acquire live admission.
- Preserve the existing `environment=2` rollout guard and OKX fail-closed behavior.
- Never place API keys, secrets, Telegram tokens, decrypted credential payloads, or credential fingerprints in logs, fixtures, snapshots, coverage artifacts, commits, or documentation.
- Use test-driven development: add the focused failing test first, run it and confirm the expected failure, implement the smallest behavior, rerun focused tests, then run the repository gate before committing.
- Before claiming completion, use `superpowers:requesting-code-review` and `superpowers:verification-before-completion`; real Demo exchange smoke is an explicit final gate, not something inferred from mocks.

---

## Task 1: Add the canonical strategy leverage resolver

**Repository:** `strategy-library`

**Files:**

- Modify: `strategy-library/hushine_strategy/inputs.py`
- Modify: `strategy-library/hushine_strategy/__init__.py`
- Modify: `strategy-library/hushine_strategy/replay/engine.py`
- Test: `strategy-library/tests/hushine_strategy/test_types_inputs.py`
- Test: `strategy-library/tests/hushine_strategy/test_replay.py`
- Test: `strategy-library/tests/hushine_strategy/test_mixed_route_replay.py`

- [ ] **Step 1: Write declaration-model tests that pin the approved precedence.**

  Add tests for:

  - no declaration -> every Futures target resolves to `1`, source `platform_default`;
  - class `LEVERAGE = 5` -> unoverridden Futures targets resolve to `5`, source `strategy_default`;
  - `ORDER_TARGETS[].leverage = 10` overrides class `LEVERAGE = 5`, source `order_target`;
  - BTC/ETH/ZEC resolves to `5/10/5` without route flattening;
  - booleans, zero, negatives, floats, strings, `NaN`, and dynamic/non-literal values are rejected;
  - Spot target-level leverage is rejected;
  - Spot-only plus global leverage is rejected;
  - mixed Spot/Futures plus global leverage applies only to Futures.

- [ ] **Step 2: Run the new focused tests and confirm they fail because leverage is not modeled.**

  Run:

  ```bash
  cd strategy-library
  uv run pytest tests/hushine_strategy/test_types_inputs.py -q
  ```

  Expected: failures show `StrategyOrderTarget`/`parse_order_targets` has no leverage fields or resolver.

- [ ] **Step 3: Implement one resolver and make all consumers call it.**

  In `inputs.py`:

  - add optional declared `leverage` to `StrategyOrderTarget`;
  - add resolved `effective_leverage: int` and `leverage_source: Literal["order_target", "strategy_default", "platform_default"]`;
  - add a strict positive-integer helper that explicitly rejects `bool`;
  - add `resolve_order_target_leverages(order_targets, strategy_leverage)`;
  - normalize Futures market names before applying leverage and reject Spot leverage.

  Export the resolver from `hushine_strategy.__init__`. Update replay initialization to pass `getattr(strategy, "LEVERAGE", None)` through this resolver rather than inventing its own default.

- [ ] **Step 4: Add replay tests proving Futures metadata gets the resolved values and Spot stays leverage-free.**

  Assert that the simulated Futures wallet/risk metadata for mixed targets contains the resolved per-symbol values. Assert no Binance/network client is constructed.

- [ ] **Step 5: Run strategy-library verification.**

  ```bash
  cd strategy-library
  uv run pytest tests/hushine_strategy/test_types_inputs.py -q
  uv run pytest -q
  ```

  Expected: all tests pass.

- [ ] **Step 6: Commit.**

  ```bash
  cd strategy-library
  git add hushine_strategy/inputs.py hushine_strategy/__init__.py hushine_strategy/replay/engine.py tests
  git commit -m "feat: resolve strategy-owned futures leverage"
  ```

---

## Task 2: Extend additive protocols for target intents, preview facts, and launch bootstrap

**Repositories:** `core-service`, `strategy-service`, `control-panel-service`

**Files:**

- Modify: `core-service/proto/portfolio_service.proto`
- Regenerate: `core-service/gen/portfoliov1/portfolio_service.pb.go`
- Regenerate: `core-service/gen/portfoliov1/portfolio_service_grpc.pb.go`
- Modify: `strategy-service/proto/strategy_service.proto`
- Regenerate: `strategy-service/gen/strategyv1/strategy_service.pb.go`
- Regenerate: `strategy-service/gen/strategyv1/strategy_service_grpc.pb.go`
- Regenerate: `strategy-service/gen/portfoliov1/portfolio_service.pb.go`
- Regenerate: `strategy-service/gen/portfoliov1/portfolio_service_grpc.pb.go`
- Regenerate: `strategy-service/strategy_service/gen/strategy_service_pb2.py`
- Regenerate: `strategy-service/strategy_service/gen/strategy_service_pb2_grpc.py`
- Regenerate: `strategy-service/strategy_service/gen/portfolio_service_pb2.py`
- Regenerate: `strategy-service/strategy_service/gen/portfolio_service_pb2_grpc.py`
- Regenerate as needed: `strategy-service/gen/controlpanelv1/*`, `strategy-service/strategy_service/gen/control_panel_service_pb2*.py`
- Regenerate: `control-panel-service/gen/controlpanelv1/control_panel_service.pb.go`
- Regenerate: `control-panel-service/gen/controlpanelv1/control_panel_service_grpc.pb.go`
- Test: `strategy-service/tests/test_generated_proto_imports.py`
- Test: `strategy-service/tests/test_runtime_worker_proto.py`
- Test: `control-panel-service/internal/runtimechannel/frame_contract_test.go`

- [ ] **Step 1: Add descriptor tests before editing proto files.**

  Pin these additive fields/messages:

  - `StrategyOrderTargetBinding`: `effective_leverage`, `leverage_source`, optional `current_leverage`, `change_required`, `venue_id`, `leverage_status`;
  - `RunStrategyResponse`: `ok`, repeated structured failures, repeated target results while retaining `session_id = 1`;
  - new one-shot `PrepareRunStrategyStart` RPC and `PreparedRunStrategyStart` response;
  - new `StrategySessionBootstrap` with `launch_operation_id`, `strategy_source_sha256`, and confirmed target facts;
  - `RequiredSymbol`: `effective_leverage` and `leverage_source`;
  - `PreflightStrategySessionResponse`: repeated read-only `FuturesLeveragePreview`;
  - new `CommitStrategySessionStart` RPC with a `SaveSessionRequest`, required routes/symbols, `launch_operation_id`, apply results, rollback results, and confirmed facts;
  - `StrategySessionEntry`: repeated `SessionTargetLeverageFact`.

  Reserve no existing field number and mark existing scalar leverage fields `[deprecated = true]` instead of deleting them.

- [ ] **Step 2: Run descriptor/import tests and confirm missing-field failures.**

  ```bash
  cd strategy-service
  PYTHONPATH=.:../strategy-library uv run --frozen --extra dev pytest \
    tests/test_generated_proto_imports.py tests/test_runtime_worker_proto.py -q
  cd ../control-panel-service
  go test ./internal/runtimechannel -run 'Test.*Frame.*Contract' -count=1
  ```

- [ ] **Step 3: Define the exact core-service messages.**

  Use these responsibilities rather than a mutation flag on preview:

  - `PreflightStrategySession` remains the single read-only route/symbol/Spot/futures-current-state RPC;
  - `CommitStrategySessionStart` is the only RPC allowed to acquire leverage admission, mutate Binance, confirm/rollback, and create a pending Session;
  - expected apply failures return `ok=false` plus `PreflightIssue` and per-target results so the UI can show real state; transport/internal failures use gRPC status;
  - target result status values are stable strings: `unchanged`, `confirmed`, `set_failed`, `confirm_failed`, `rolled_back`, `rollback_failed`, `unknown`;
  - a rollback failure sets top-level code `LEVERAGE_ROLLBACK_FAILED`.

- [ ] **Step 4: Define the exact strategy/runtime messages.**

  `PrepareRunStrategyStart` must return a complete, immutable preparation manifest: canonical Session metadata, source digest, declared inputs/order targets, target leverage intents, required routes/symbols, preflight outcome, and risk max-loss facts. It does not create a Session or run user callbacks.

  `StrategySessionBootstrap` carries only confirmed facts and identity needed by the final worker. Do not place credentials, internal addresses, or raw Venue secrets in it.

- [ ] **Step 5: Regenerate all stubs from their owner scripts.**

  ```bash
  cd core-service
  make proto
  cd ../strategy-service
  PYTHON=.venv/bin/python ./generate_proto.sh
  cd ../control-panel-service
  make proto
  ```

- [ ] **Step 6: Run protocol compilation gates.**

  ```bash
  cd strategy-service
  PYTHONPATH=.:../strategy-library uv run --frozen --extra dev pytest \
    tests/test_generated_proto_imports.py tests/test_runtime_worker_proto.py -q
  go test ./gen/... ./internal/runtimeagent/... -run '^$'
  cd ../core-service
  go test ./gen/... -run '^$'
  cd ../control-panel-service
  go test ./gen/... ./internal/runtimechannel/... -run '^$'
  ```

- [ ] **Step 7: Commit protocol changes in dependency order.**

  ```bash
  cd core-service
  git add proto/portfolio_service.proto gen/portfoliov1
  git commit -m "feat: add strategy leverage launch protocol"

  cd ../strategy-service
  git add proto/strategy_service.proto gen strategy_service/gen
  git commit -m "feat: add strategy leverage runtime protocol"

  cd ../control-panel-service
  if ! git diff --quiet -- gen/controlpanelv1; then
    git add gen/controlpanelv1
    git commit -m "chore: regenerate runtime protocol bindings"
  fi
  ```

---

## Task 3: Make strategy validation the sole leverage authority

**Repository:** `strategy-service`

**Files:**

- Modify: `strategy-service/strategy_service/inputs.py`
- Modify: `strategy-service/strategy_service/strategy_validator.py`
- Modify: `strategy-service/strategy_service/grpc_server.py`
- Test: `strategy-service/tests/test_strategy_validator.py`
- Test: `strategy-service/tests/test_grpc_server.py`

- [ ] **Step 1: Add failing static-validator tests.**

  Cover literal positive integers, `bool`, zero/negative/fractional/string/dynamic expressions, Spot-only global leverage, Spot target override, mixed Spot/Futures, and target-over-global precedence. Require issue locations to point at `LEVERAGE` or the target entry.

- [ ] **Step 2: Add failing declaration extraction and response-shaping tests.**

  Pin that `extract_declarations()` returns resolved target facts and that both `ValidateStrategySource` and `PreviewRunStrategy` expose the same `effective_leverage`/source. Pin that a nonzero legacy request leverage is ignored.

- [ ] **Step 3: Run focused tests and observe the old request-default behavior fail.**

  ```bash
  cd strategy-service
  PYTHONPATH=.:../strategy-library uv run --frozen --extra dev pytest \
    tests/test_strategy_validator.py tests/test_grpc_server.py \
    -q -k 'leverage or order_target'
  ```

  Expected: current tests still report `request_default`; new tests fail until the resolver is wired.

- [ ] **Step 4: Implement static and runtime declaration resolution.**

  - validate AST literals without executing dynamic expressions;
  - pass the class-level `LEVERAGE` into the strategy-library resolver;
  - remove leverage from `_EffectiveRiskControls` so it retains only max-loss controls;
  - build `RequiredSymbol` target intents from resolved declarations;
  - keep old request fields accepted but ignored and never label any value `request_default`;
  - fail closed when downstream protocol lacks per-target support for non-default or mixed leverage.

- [ ] **Step 5: Run focused and repository Python tests.**

  ```bash
  cd strategy-service
  PYTHONPATH=.:../strategy-library uv run --frozen --extra dev pytest \
    tests/test_strategy_validator.py tests/test_grpc_server.py -q
  ```

- [ ] **Step 6: Commit.**

  ```bash
  cd strategy-service
  git add strategy_service/inputs.py strategy_service/strategy_validator.py \
    strategy_service/grpc_server.py tests/test_strategy_validator.py tests/test_grpc_server.py
  git commit -m "feat: derive leverage from strategy declarations"
  ```

---

## Task 4: Canonicalize Binance Futures margin mode at the adapter boundary

**Repository:** `core-service`

**Files:**

- Modify: `core-service/internal/exchange/binance.go`
- Modify: `core-service/internal/exchange/binance/leverage.go`
- Test: `core-service/internal/exchange/binance_test.go`
- Test: `core-service/internal/exchange/binance/leverage_test.go`

- [ ] **Step 1: Add failing table tests for external margin-mode values.**

  Assert `CROSSED`, `crossed`, and `cross` become `cross`; `ISOLATED`/`isolated` become `isolated`; blank or unknown values return an unsupported/fail-closed error instead of being guessed.

- [ ] **Step 2: Add snapshot tests for both Binance endpoints.**

  Pin canonical output from `/fapi/v1/symbolConfig` and `/fapi/v3/positionRisk`, including the exact screenshot regression where `ConfiguredMarginMode=CROSSED` previously caused a false Telegram warning.

- [ ] **Step 3: Run tests and confirm raw `CROSSED` currently leaks through.**

  ```bash
  cd core-service
  go test ./internal/exchange/... -run 'MarginMode|SymbolConfig|PositionRisk' -count=1
  ```

- [ ] **Step 4: Add one normalization helper and route every Binance risk path through it.**

  Do not add compatibility comparisons in strategy code. Keep the external-to-canonical conversion inside the Binance adapter.

- [ ] **Step 5: Verify and commit.**

  ```bash
  cd core-service
  go test ./internal/exchange/... -count=1
  git add internal/exchange/binance.go internal/exchange/binance/leverage.go \
    internal/exchange/binance_test.go internal/exchange/binance/leverage_test.go
  git commit -m "fix: canonicalize Binance futures margin mode"
  ```

---

## Task 5: Persist launch journals, target admission, and Session leverage facts

**Repository:** `core-service`

**Files:**

- Create: `core-service/internal/storage/migrations/0006_strategy_owned_futures_leverage.sql`
- Modify: `core-service/internal/storage/migrations/migration_contract_test.go`
- Modify: `core-service/internal/storage/migrations/baseline_contract_test.go`
- Modify: `core-service/internal/domain/model.go`
- Modify: `core-service/internal/repository/repository.go`
- Modify: `core-service/internal/repository/timescale.go`
- Test: `core-service/internal/repository/session_test.go`
- Create: `core-service/internal/repository/session_leverage_test.go`

- [ ] **Step 1: Write migration contract tests first.**

  Require these tables and constraints:

  - `strategy_launch_operations`: operation identity, owner/session metadata, state, primary error, timestamps;
  - `strategy_leverage_apply_attempts`: stable ordinal, route/symbol, previous/target/confirmed values, apply and rollback status/errors;
  - `strategy_target_admissions`: exchange/environment/credential fingerprint/market/symbol key, operation/session holder, lease/recovery state, timestamps, one active holder per key;
  - `strategy_session_target_facts`: Session/venue/route/symbol, effective/source, previous/confirmed leverage, confirmation time, uniqueness over `(session_id, venue_id, market, symbol)`.

  Add foreign keys where lifecycle permits them, but keep failed launch operations independent of a Session foreign key.

- [ ] **Step 2: Run migration tests and confirm migration `0006` is missing.**

  ```bash
  cd core-service
  go test ./internal/storage/migrations -count=1
  ```

- [ ] **Step 3: Write repository integration tests for lifecycle invariants.**

  Cover:

  - duplicate credential/symbol admission conflict even through two Venue rows;
  - different symbols on the same credential are allowed;
  - begin launch stores an operation and admissions without a Session;
  - successful commit atomically inserts Session + facts and transfers holders to `session_id`;
  - failed launch with successful rollback releases admissions but retains audit rows;
  - rollback failure keeps a `recovery_required` admission and cannot be silently reused;
  - terminal Session update releases its active admissions;
  - historical Sessions with no facts still load legacy scalar leverage;
  - new mixed-leverage Sessions load facts and do not synthesize a false scalar.

- [ ] **Step 4: Implement the migration and domain types.**

  Add `StrategyLaunchOperation`, `LeverageApplyAttempt`, `TargetAdmission`, and `SessionTargetLeverageFact`. Add `CredentialFingerprint` to `VenueRouteMeta`; update both route-resolution queries/scans so admission never keys on raw API key.

- [ ] **Step 5: Implement narrow repository lifecycle methods.**

  Add methods equivalent to:

  - `BeginStrategyLaunch(ctx, operation, intents)`;
  - `RecordLeverageAttempt(ctx, attempt)`;
  - `CommitStrategyLaunch(ctx, operationID, session, facts)`;
  - `FailStrategyLaunch(ctx, operationID, result, releaseAdmissions)`;
  - `ListSessionTargetLeverageFacts(ctx, sessionID)`;
  - `ReleaseSessionTargetAdmissions(ctx, sessionID)`.

  Use database transactions and row locks; do not hold a SQL transaction open during Binance network calls.

- [ ] **Step 6: Make terminal updates release admission in the same transaction.**

  Update `UpdateSessionWithIndicatorFinalization` so terminal states release active admissions atomically with the state transition. Preserve recoverable semantics: a deliberately recoverable running Session still owns targets until the established recovery/termination path resolves it.

- [ ] **Step 7: Verify empty and incremental schema paths.**

  ```bash
  cd core-service
  go test ./internal/storage/migrations -count=1
  go test ./internal/repository -run 'Session|Leverage|Admission|Migration' -count=1
  ```

- [ ] **Step 8: Commit.**

  ```bash
  cd core-service
  git add internal/storage/migrations internal/domain/model.go \
    internal/repository/repository.go internal/repository/timescale.go \
    internal/repository/session_test.go internal/repository/session_leverage_test.go
  git commit -m "feat: persist strategy leverage launch facts"
  ```

---

## Task 6: Split core preview from apply/confirm/rollback

**Repository:** `core-service`

**Files:**

- Create: `core-service/internal/service/strategy_leverage_start.go`
- Create: `core-service/internal/service/strategy_leverage_start_test.go`
- Modify: `core-service/internal/service/grpc.go`
- Modify: `core-service/internal/service/grpc_strategy_test.go`
- Modify: `core-service/internal/exchange/adapter/capabilities.go`
- Modify: `core-service/internal/notification/event.go`
- Test: `core-service/internal/service/grpc_portfolio_meta_test.go` (repository mock interface updates only where required)

- [ ] **Step 1: Add a side-effect spy test for preview.**

  Construct a Futures target with current 3x and desired 5x. Assert `PreflightStrategySession` returns current 3x, desired 5x, `change_required=true`, but records zero `SetFuturesLeverage` calls, zero repository launch calls, and zero Session writes across repeated preview calls.

- [ ] **Step 2: Add start happy-path tests.**

  Cover unchanged target (GET + confirm GET, no POST), changed target (GET, POST, confirm GET), deterministic BTC/ETH/ZEC ordering, all facts committed once, and worker-independent response data.

- [ ] **Step 3: Add failure and rollback tests.**

  For failures on target 1/2/3, assert:

  - no Session is created;
  - previously modified targets roll back in reverse order;
  - every rollback is read back;
  - original error and rollback results are both returned;
  - rollback failure yields `LEVERAGE_ROLLBACK_FAILED`, keeps recovery admission, and publishes one deduplicated system notification event without credentials.

- [ ] **Step 4: Add concurrency tests.**

  Race two starts for the same `(exchange, environment, credential_fingerprint, market, symbol)` and assert exactly one acquires admission. Repeat through two Venues sharing the credential fingerprint. Assert non-overlapping symbols can proceed.

- [ ] **Step 5: Run tests and confirm the existing preflight mutation fails the spy assertion.**

  ```bash
  cd core-service
  go test ./internal/service -run 'StrategyLeverage|Preflight.*ReadOnly|Rollback|Admission' -count=1
  ```

- [ ] **Step 6: Extract a launch coordinator.**

  `PreflightStrategySession` resolves Venue facts and performs GET-only current leverage reads. `CommitStrategySessionStart` repeats authoritative resolution, validates target intents, begins admission, performs stable ordered apply/readback, journals each step, rolls back on failure, and commits the pending Session/facts only after every target is confirmed.

  For Backtest, bypass Binance/admission and atomically create the pending Session with simulated confirmed facts. For Spot-only Sessions, create the pending Session with no leverage facts. For OKX or unsupported execution, fail closed.

- [ ] **Step 7: Wire rollback-failure notifications.**

  Reuse the `notification.Service` already injected into `PortfolioGRPCService`. Add a stable system event type such as `strategy.leverage_rollback_failed` to `internal/notification/event.go`, include user/portfolio/operation and affected symbols only, and use `launch_operation_id` as the dedupe key. Delivery failure must be recorded but must not hide the rollback failure response.

- [ ] **Step 8: Add read paths for Session facts.**

  Populate `StrategySessionEntry.target_leverage_facts` in Get/List responses. Populate legacy `leverage` only as historical fallback when no facts exist; do not collapse a mixed Session.

- [ ] **Step 9: Verify core-service.**

  ```bash
  cd core-service
  go test ./internal/service ./internal/repository ./internal/exchange/... -count=1
  go test ./...
  go vet ./...
  ```

- [ ] **Step 10: Commit.**

  ```bash
  cd core-service
  git add internal/service internal/exchange/adapter/capabilities.go \
    internal/notification/event.go
  git commit -m "feat: confirm futures leverage before session commit"
  ```

---

## Task 7: Proxy the new core launch operation without leaking platform configuration

**Repositories:** `strategy-service`, `control-panel-service`

**Files:**

- Modify: `strategy-service/strategy_service/portfolio_client.py`
- Modify: `strategy-service/strategy_service/platform_proxy.py`
- Test: `strategy-service/tests/test_portfolio_client_runtime_binding.py`
- Test: `strategy-service/tests/test_platform_proxy.py`
- Modify: `control-panel-service/internal/runtimechannel/platform_proxy.go`
- Test: `control-panel-service/internal/runtimechannel/platform_proxy_test.go`

- [ ] **Step 1: Add proxy contract tests.**

  Assert authenticated `user_id` injection, exact forwarding of launch operation/Session metadata and target intents, structured response preservation, deadline propagation, and rejection of spoofed user identity.

- [ ] **Step 2: Run focused tests and confirm the new platform method is not whitelisted.**

  ```bash
  cd strategy-service
  PYTHONPATH=.:../strategy-library uv run --frozen --extra dev pytest \
    tests/test_portfolio_client_runtime_binding.py tests/test_platform_proxy.py -q
  cd ../control-panel-service
  go test ./internal/runtimechannel -run 'PlatformProxy.*StrategySessionStart' -count=1
  ```

- [ ] **Step 3: Add `portfolio.CommitStrategySessionStart` to both proxy paths.**

  Keep control-panel-service as a typed authenticated relay only. It must not resolve credentials, calculate leverage, call Binance, or accept internal endpoint overrides from the runtime payload.

- [ ] **Step 4: Remove the old global leverage argument from new preflight client calls.**

  Continue serializing the deprecated proto field as zero/default only where generated compatibility requires it.

- [ ] **Step 5: Verify and commit per repository.**

  ```bash
  cd strategy-service
  PYTHONPATH=.:../strategy-library uv run --frozen --extra dev pytest \
    tests/test_portfolio_client_runtime_binding.py tests/test_platform_proxy.py -q
  git add strategy_service/portfolio_client.py strategy_service/platform_proxy.py \
    tests/test_portfolio_client_runtime_binding.py tests/test_platform_proxy.py
  git commit -m "feat: proxy strategy leverage launch commits"

  cd ../control-panel-service
  go test ./internal/runtimechannel -count=1
  git add internal/runtimechannel/platform_proxy.go internal/runtimechannel/platform_proxy_test.go
  git commit -m "feat: relay strategy session launch commits"
  ```

---

## Task 8: Move start orchestration ahead of the final session worker

**Repository:** `strategy-service`

**Files:**

- Modify: `strategy-service/internal/runtimeagent/agent.go`
- Modify: `strategy-service/internal/runtimeagent/agent_test.go`
- Modify: `strategy-service/internal/runtimeagent/blocked_worker_integration_test.go`
- Modify: `strategy-service/strategy_service/session_worker_entry.py`
- Modify: `strategy-service/strategy_service/grpc_server.py`
- Modify: `strategy-service/strategy_service/session.py`
- Test: `strategy-service/tests/test_grpc_server.py`
- Test: `strategy-service/tests/test_runtime_worker_proto.py`

- [ ] **Step 1: Add an agent ordering test with event recording.**

  Require the order:

  1. reserve canonical `session_id` and `launch_operation_id`;
  2. run one-shot `PrepareRunStrategyStart`;
  3. receive read-only readiness and immutable target intents;
  4. call `portfolio.CommitStrategySessionStart`;
  5. receive committed pending Session and confirmed facts;
  6. only then call `StartSessionWorker` for the final Session.

  On preparation/apply/confirmation/commit failure, assert the final `StartSessionWorker` count is zero.

- [ ] **Step 2: Add bootstrap validation tests.**

  Assert the final worker fails closed when:

  - bootstrap is absent for a new protocol start;
  - source digest changed after preparation;
  - target set, effective leverage, source, venue, or confirmed leverage differs;
  - canonical wallet risk metadata differs from confirmed facts;
  - mixed leverage was collapsed to the legacy Session scalar.

  Preserve an explicit legacy compatibility path only for old Sessions/protocols that contain no new capability marker.

- [ ] **Step 3: Add lifecycle tests.**

  - final worker launch failure after Session commit marks the pending Session failed, which releases admissions;
  - worker start timeout does the same;
  - successful publication moves pending -> running without a second `SaveSession`;
  - Resume generates a new operation/session, rereads new code, and never reuses old target facts;
  - blocked user code does not block agent heartbeat (existing invariant stays green).

- [ ] **Step 4: Run tests and confirm current code starts the final worker before apply.**

  ```bash
  cd strategy-service
  go test ./internal/runtimeagent -run 'RunStrategy|SessionStart|RestartSession' -count=1
  PYTHONPATH=.:../strategy-library uv run --frozen --extra dev pytest \
    tests/test_grpc_server.py tests/test_runtime_worker_proto.py -q -k 'bootstrap or leverage or startup'
  ```

- [ ] **Step 5: Implement reusable one-shot preparation in runtime-agent.**

  Reuse the guarded one-shot worker machinery used by Preview/Validate. The preparation worker may load/validate the strategy and call read-only platform APIs, but it must exit before commit and must never register a running Session or execute callbacks.

- [ ] **Step 6: Commit through core and launch the final worker only on success.**

  Pack `StrategySessionBootstrap` into `StartSession.session_bootstrap`. Return structured expected failures in `RunStrategyResponse`; preserve transport errors for unavailable/internal failures. If final launch fails after commit, immediately mark the pending Session failed so core releases admissions.

- [ ] **Step 7: Refactor Python RunStrategy to consume the bootstrap.**

  Re-read/revalidate the strategy, compare its digest and resolved targets, build the canonical wallet, confirm metadata, and skip the old side-effecting preflight/`SaveSession`. Keep profile/stream readiness parity and strategy start snapshot gates.

- [ ] **Step 8: Replace SessionState scalar leverage with a target map for new Sessions.**

  Max-loss controls remain global. Sizing and strategy runtime look up leverage by `(exchange, market, symbol)`. Retain scalar fields only for legacy read compatibility and add assertions that mixed targets never use them.

- [ ] **Step 9: Verify and commit.**

  ```bash
  cd strategy-service
  go test ./internal/runtimeagent -count=1
  PYTHONPATH=.:../strategy-library uv run --frozen --extra dev pytest \
    tests/test_grpc_server.py tests/test_runtime_worker_proto.py -q
  git add internal/runtimeagent strategy_service/session_worker_entry.py \
    strategy_service/grpc_server.py strategy_service/session.py tests
  git commit -m "feat: gate worker launch on leverage confirmation"
  ```

---

## Task 9: Keep Backtest and debugger semantics aligned without exchange mutation

**Repositories:** `strategy-service`, `strategy-debugger-cli`

**Files:**

- Modify: `strategy-service/strategy_service/wallet_factory.py`
- Modify: `strategy-service/strategy_service/wallet/binance.py` only if target-map consumption belongs there
- Modify: `strategy-service/tests/helpers/wallet_fixtures.py`
- Modify: `strategy-service/tests/test_wallet_runtime.py`
- Modify: `strategy-service/tests/test_mode0_parity_cutover.py`
- Modify: `strategy-debugger-cli/src/hushine_debugger/replay.py`
- Modify: `strategy-debugger-cli/tests/test_replay_cli.py`
- Modify: `strategy-debugger-cli/tests/test_mixed_route_package_v2.py`

- [ ] **Step 1: Add parity tests for 1x/global/override/mixed leverage.**

  Feed the same strategy declaration to Backtest and debugger replay, then assert equal per-symbol leverage metadata and order sizing. Add spies proving neither path constructs a live Venue client or calls Binance.

- [ ] **Step 2: Run focused tests and observe missing target-map behavior.**

  ```bash
  cd strategy-service
  PYTHONPATH=.:../strategy-library uv run --frozen --extra dev pytest \
    tests/test_wallet_runtime.py tests/test_mode0_parity_cutover.py -q
  cd ../strategy-debugger-cli
  uv run pytest tests/test_replay_cli.py tests/test_mixed_route_package_v2.py -q
  ```

- [ ] **Step 3: Initialize simulated risk metadata from the shared resolver.**

  Do not add a debugger CLI leverage override. Strategy source remains authoritative, with platform default 1x. Preserve Spot wallet behavior and mixed Spot/Futures route isolation.

- [ ] **Step 4: Verify and commit per repository.**

  ```bash
  cd strategy-service
  PYTHONPATH=.:../strategy-library uv run --frozen --extra dev pytest \
    tests/test_wallet_runtime.py tests/test_mode0_parity_cutover.py -q
  git add strategy_service/wallet_factory.py strategy_service/wallet/binance.py \
    tests/helpers/wallet_fixtures.py \
    tests/test_wallet_runtime.py tests/test_mode0_parity_cutover.py
  git commit -m "feat: apply target leverage to simulated wallets"

  cd ../strategy-debugger-cli
  uv run pytest -q
  git add src/hushine_debugger/replay.py tests
  git commit -m "feat: align debugger leverage with strategy declarations"
  ```

---

## Task 10: Remove HTTP/UI leverage inputs and show per-target facts

**Repositories:** `gateway/quant-handler`, `gateway/quant-frontend`

**Files:**

- Modify: `gateway/quant-handler/internal/app/strategy.go`
- Modify: `gateway/quant-handler/internal/app/strategy_test.go`
- Modify: `gateway/quant-handler/internal/app/strategy_cutover_test.go`
- Modify: `gateway/quant-handler/internal/app/session_history.go`
- Modify: `gateway/quant-handler/internal/app/session_history_test.go`
- Modify: `gateway/quant-frontend/src/api/client.ts`
- Modify: `gateway/quant-frontend/src/pages/PortfolioDetail.tsx`
- Modify: `gateway/quant-frontend/src/pages/SessionDetailPage.tsx`
- Modify: `gateway/quant-frontend/scripts/demo-start-preflight-gate.test.mjs`
- Modify: `gateway/quant-frontend/scripts/session-management.test.mjs`
- Modify: `gateway/quant-frontend/scripts/risk-controls-input-validity.test.mjs`
- Create: `gateway/quant-frontend/scripts/strategy-leverage-display.test.mjs`

- [ ] **Step 1: Add gateway tests that reject leverage authority.**

  Assert incoming legacy HTTP `leverage` is tolerated for compatibility but never forwarded as authority. Map preview target facts unchanged. Map structured start failures/results without converting them into a generic 500. Expose Session target facts and historical fallback.

- [ ] **Step 2: Add frontend source-contract tests first.**

  Require:

  - no editable leverage input in Start Demo, Backtest, Portfolio resume, or Session-detail resume;
  - preview calls do not send leverage;
  - Start calls do not send leverage;
  - each Futures target shows symbol, effective value, source label, current value, and change/no-change state;
  - Spot targets display no leverage;
  - apply disables duplicate submission and displays target results/rollback failures;
  - Session detail uses target facts, with legacy scalar only when facts are absent.

- [ ] **Step 3: Run focused tests and confirm current controls/request fields are still present.**

  ```bash
  cd gateway/quant-handler
  go test ./internal/app -run 'PreviewRunStrategy|RunStrategy|SessionHistory|Leverage' -count=1
  cd ../quant-frontend
  node scripts/demo-start-preflight-gate.test.mjs
  node scripts/session-management.test.mjs
  node scripts/risk-controls-input-validity.test.mjs
  node scripts/strategy-leverage-display.test.mjs
  ```

- [ ] **Step 4: Update quant-handler as a pure mapper.**

  Remove leverage from new request structs/mapping while keeping compatibility decode behavior. Add JSON shapes for target facts/results. Do not calculate precedence or parse Python in the gateway.

- [ ] **Step 5: Update the React screens.**

  Remove `sessionLeverage`, parsing helpers, defaults, validation, and input components. Render the per-target preview near `ORDER_TARGETS`. On Start show pending status, then confirmed/rolled-back/failed status. Keep max-loss control behavior unchanged.

- [ ] **Step 6: Verify and commit per repository.**

  ```bash
  cd gateway/quant-handler
  go test ./...
  go vet ./...
  git add internal/app/strategy.go internal/app/strategy_test.go \
    internal/app/strategy_cutover_test.go internal/app/session_history.go \
    internal/app/session_history_test.go
  git commit -m "feat: expose strategy leverage target facts"

  cd ../quant-frontend
  for test_file in scripts/*.test.mjs; do node "$test_file"; done
  npm run build
  git add src/api/client.ts src/pages/PortfolioDetail.tsx src/pages/SessionDetailPage.tsx scripts
  git commit -m "feat: show strategy-owned leverage at session start"
  ```

---

## Task 11: Convert the BTC/ETH/ZEC strategy and eliminate duplicate margin warnings

**Repository:** `strategy-service`

**Files:**

- Modify: `strategy-service/strategy_templates/btc_eth_zec_cross_momentum.py`
- Modify: `strategy-service/tests/test_btc_eth_zec_cross_momentum.py`

- [ ] **Step 1: Add tests for standard declaration and canonical facts.**

  Require `LEVERAGE = 10`, no `REQUIRED_LEVERAGE`, no direct `CROSSED` compatibility branch, no repeated Telegram warning when canonical mode is `cross`, and per-symbol sizing based on confirmed target leverage plus `wallet_balance`.

- [ ] **Step 2: Run the focused test and confirm the old duplicate checks fail it.**

  ```bash
  cd strategy-service
  PYTHONPATH=.:../strategy-library uv run --frozen --extra dev pytest \
    tests/test_btc_eth_zec_cross_momentum.py -q
  ```

- [ ] **Step 3: Replace local leverage policy with the standard contract.**

  Keep the strategy's intended Cross requirement and 1% wallet-balance sizing, but read only canonical `cross` and confirmed leverage metadata. Deduplicate unchanged warnings so a persistent invalid state does not spam Telegram on every symbol/bar.

- [ ] **Step 4: Verify and commit.**

  ```bash
  cd strategy-service
  PYTHONPATH=.:../strategy-library uv run --frozen --extra dev pytest \
    tests/test_btc_eth_zec_cross_momentum.py -q
  git add strategy_templates/btc_eth_zec_cross_momentum.py \
    tests/test_btc_eth_zec_cross_momentum.py
  git commit -m "fix: use confirmed leverage in multi-symbol strategy"
  ```

---

## Task 12: Update deployment schema bundle and current documentation

**Repositories:** `hushine-deploy`, plus owner-repository READMEs where the behavior is documented

**Files:**

- Regenerate: `hushine-deploy/db/generated/portfolio.sql`
- Modify: `hushine-deploy/db/README.md`
- Create: `hushine-deploy/docs/strategy-owned-futures-leverage.md`
- Modify: `hushine-deploy/docs/runtime-operator-flow.md`
- Modify: `hushine-deploy/README.md`
- Modify: `strategy-service/README.md`
- Modify: `core-service/README.md`
- External docs: current authoritative Notion pages `System Architecture`, `Runtime Management`, and `User Manual`
- Verify: render to a temporary directory with `hushine-deploy/scripts/db/render-schema-bundle.sh` and compare it byte-for-byte with `hushine-deploy/db/generated`

- [ ] **Step 1: Regenerate the one-shot database bundle from migrations.**

  ```bash
  cd hushine-deploy
  bash scripts/db/render-schema-bundle.sh
  ```

  Do not hand-maintain a second schema. The generated bundle must contain migration `0006` exactly once.

- [ ] **Step 2: Test empty-db and incremental upgrade deployment.**

  Use isolated local PostgreSQL/Timescale databases:

  - empty database -> run the normal one-shot deployment and inspect all four new tables/constraints;
  - database at migration `0005` -> run migration tooling and verify existing Sessions remain readable;
  - rerun migration tooling -> verify idempotent/no duplicate objects.

- [ ] **Step 3: Update current code-logic documentation.**

  Document declaration precedence, one-shot preparation, read-only preview, admission key, apply/readback/rollback, atomic Session facts, RuntimeChannel bootstrap, worker digest/fact verification, Resume semantics, and historical fallback. Mark old page/global leverage instructions obsolete; do not link archived Notion pages as current authority.

- [ ] **Step 4: Update the user manual.**

  Show `LEVERAGE` and target override examples, explain Spot rejection/default 1x, show the target preview labels, explain changes applied on Start, and describe rollback/recovery errors. Remove instructions to enter leverage on Demo/Backtest/Resume screens.

- [ ] **Step 5: Update the three authoritative Notion sections after code verification.**

  Use the Notion documentation workflow to locate the current pages by exact title, verify every retained link against current code, and update:

  - `System Architecture`: authority boundary and end-to-end launch sequence;
  - `Runtime Management`: one-shot preparation, RuntimeChannel commit, bootstrap validation, Resume and admission lifecycle;
  - `User Manual`: declarations, per-target preview, Start effects, errors, and removal of UI leverage fields.

  Add a last-verified date and repository commit references. Remove or clearly mark obsolete page-level leverage instructions; do not silently preserve an old Notion link just because the page still exists.

- [ ] **Step 6: Run documentation/schema consistency checks and commit.**

  ```bash
  cd hushine-deploy
  generated_check_dir="$(mktemp -d)"
  bash scripts/db/render-schema-bundle.sh "$generated_check_dir"
  diff -ru "$generated_check_dir" db/generated
  rm -rf "$generated_check_dir"
  rg -n "request_default.*leverage|enter.*leverage|Leverage \(x\)" db docs
  git add db docs
  git commit -m "docs: document strategy-owned futures leverage"

  cd ../strategy-service
  git add README.md
  git commit -m "docs: explain strategy leverage startup"

  cd ../core-service
  git add README.md
  git commit -m "docs: explain leverage admission and rollback"
  ```

  Expected `rg`: no current operator/user instruction tells users to set Session leverage on the page. Historical changelog/spec text may remain only when clearly labeled historical.

---

## Task 13: Run cross-repository review, conventional verification, and real Demo smoke

**Repositories:** all affected repositories

- [ ] **Step 1: Use `superpowers:requesting-code-review`.**

  Review the complete diff against every section of the approved spec. Treat findings as evidence to verify, then use `superpowers:receiving-code-review` before applying nontrivial review suggestions.

- [ ] **Step 2: Run fast repository gates.**

  ```bash
  cd strategy-library
  uv run pytest -q

  cd ../strategy-debugger-cli
  uv run pytest -q

  cd ../strategy-service
  PYTHONPATH=.:../strategy-library uv run --frozen --extra dev pytest tests/ -q
  go test ./...
  go vet ./...
  bash scripts/start-bare-runtime-debugpy.test.sh
  bash scripts/runtime-agent-platform.test.sh

  cd ../core-service
  go test ./...
  go vet ./...

  cd ../control-panel-service
  go test ./...
  go vet ./...

  cd ../gateway/quant-handler
  go test ./...
  go vet ./...

  cd ../quant-frontend
  for test_file in scripts/*.test.mjs; do node "$test_file"; done
  npm run build
  ```

- [ ] **Step 3: Validate protocol generation is clean.**

  Regenerate protos again and require `git diff --exit-code` for generated owner paths. This catches stale copies between core-service, strategy-service, and control-panel-service.

- [ ] **Step 4: Bring up the local instrumented stack.**

  From `hushine-deploy`, start the local TimescaleDB, Kafka, ELK, Jaeger, services, and coverage-instrumented hosted runtime using the repository's current Make targets/config generator. Confirm health endpoints and runtime registration before UI testing. Do not use the unavailable `.10` host.

- [ ] **Step 5: Run mock failure matrix before touching the real Demo credential.**

  With the project mock Binance adapter, verify:

  - preview repeated refresh -> GET only;
  - unchanged targets -> no POST;
  - BTC/ETH/ZEC changed -> deterministic set and confirm;
  - failures at each target -> reverse rollback;
  - rollback failure -> system notification and recovery admission;
  - concurrent same-account/symbol starts -> one admitted;
  - Spot-only -> no leverage API;
  - Backtest/debugger -> no leverage API;
  - final worker is never launched for failed apply.

- [ ] **Step 6: Run real Binance Demo smoke from the signed-in UI.**

  Using the active BTC/ETH/ZEC strategy:

  - capture Binance current leverage through the adapter without logging secrets;
  - open Start Demo and wait through multiple preview refreshes; prove values do not change;
  - verify the UI shows each symbol's target/source/current/change state;
  - click Start once and verify all targets are set/read back;
  - query Session facts and compare with Binance readback and worker canonical metadata;
  - allow orders and verify quantity calculation uses `wallet_balance * 1%` and each target's confirmed leverage;
  - verify `CROSSED` produces canonical `cross` and no false Telegram warning;
  - run a true non-Cross mismatch case and verify one deduplicated warning/fail-closed outcome;
  - terminate the Session and verify admission release without automatic leverage restoration.

- [ ] **Step 7: Exercise Resume and worker-isolation behavior.**

  Change strategy code leverage, issue the one-line restart, verify old worker cleanup/recoverable transition, new operation/session/facts, and unchanged runtime-agent heartbeat. Repeat with a deliberate 10-minute blocking loop/breakpoint and verify runtime heartbeat stays healthy.

- [ ] **Step 8: Collect and inspect coverage.**

  Export service, runtime-container, frontend, and Go/Python coverage using the already instrumented workflow. Scan the reports/logs for secrets before sharing. Record covered/uncovered leverage branches as evidence for later cleanup; do not delete code in this task based only on one smoke run.

- [ ] **Step 9: Use `superpowers:verification-before-completion`.**

  Re-run the specific commands that support every completion claim. Record command, exit status, test count, and real-smoke evidence. If the real Demo credential/environment is unavailable, report that gate as blocked; do not claim exchange-backed completion from mocks.

- [ ] **Step 10: Push only after all owned commits and gates are reviewed.**

  For each affected repository, confirm branch, clean working tree, commit list, and remote tracking. Push `cleanup/medium-baseline-20260710` without force. Report every repository/commit and any gate that remains operational rather than code-complete.

---

## Spec-Coverage Checklist

- [ ] Strategy target > strategy default > platform 1x precedence has one implementation.
- [ ] Invalid/Spot leverage declarations fail before runtime execution.
- [ ] Preview is proven GET-only and storage-free.
- [ ] Start repeats source validation and target resolution server-side.
- [ ] Same-account/symbol admission uses credential fingerprint, not Venue ID or API key.
- [ ] Apply is stable-ordered; no-op targets avoid POST; all targets are read back.
- [ ] Partial failure reverses prior modifications; rollback failure is visible and notified.
- [ ] Session/facts/admission transfer is atomic before final worker launch.
- [ ] Final worker validates source digest, target intents, confirmed facts, and wallet metadata.
- [ ] Backtest/debugger use the same resolver without exchange calls.
- [ ] Resume creates a new operation/session and does not reuse old facts.
- [ ] UI has no leverage input and displays per-target preview/apply/session facts.
- [ ] Historical Sessions retain scalar fallback; mixed new Sessions never collapse to it.
- [ ] Binance margin mode is canonicalized at the adapter boundary.
- [ ] Empty and incremental DB deployment both pass.
- [ ] Mock matrix, conventional tests, real Demo smoke, and coverage evidence are complete.

## Plan Self-Review

- [ ] Scan this plan for unfinished markers and replace them with exact ownership, paths, or commands.
- [ ] Verify every modified interface has named producer and consumer repositories.
- [ ] Verify every behavior task begins with a failing test and includes the expected failure.
- [ ] Verify every repository mutation has its own focused verification and commit step.
- [ ] Verify no step asks Preview, frontend, runtime, or control-panel-service to hold credentials or calculate leverage precedence.
- [ ] Verify no completion step can pass solely on mocks when the spec requires real Binance Demo evidence.
