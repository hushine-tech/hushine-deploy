# Self-Review Remediation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Complete Indicator V2 and fix RuntimeChannel replacement, Spot USDT admission, coverage evidence normalization, and graceful coverage shutdown.

**Architecture:** Follow the three existing approved subsystem designs. Add
identity-aware ownership at connection cleanup, enforce product invariants in
Core, normalize coverage before candidate classification, and remove V1
indicator execution only after isolated V2 gates pass.

**Tech Stack:** Go, Python 3.13, protobuf/gRPC, PostgreSQL/TimescaleDB,
TypeScript/React, Node/V8 precise coverage, Bash, Docker.

## Global Constraints

- Preserve every non-indicator database row; destructive migration is limited
  to the isolated V1 indicator tables and requires the existing cutover guard.
- Do not stop, restart, finalize, relabel, or reuse the user's active manual
  coverage run.
- Route sessions only by `runtime_id`; route orders only through
  core-service `order.v1`.
- Self-hosted and bare runtimes receive no internal DB, Kafka, account,
  Portfolio, or Order addresses.
- Spot supports Binance USDT-quoted symbols only; Live Spot remains fail
  closed.
- Bare worker IPC and replacement remain Windows-compatible.
- Stage and commit only files owned by each task.

---

### Task 1: Complete Indicator V2 Worker and Agent Semantics

**Files:**
- Modify: `strategy-service/proto/runtime_worker.proto`
- Modify: `strategy-service/strategy_service/worker_agent_client.py`
- Modify: `strategy-service/strategy_service/grpc_server.py`
- Modify: `strategy-service/internal/runtimeagent/indicator_sync.go`
- Modify: `strategy-service/internal/runtimeagent/indicator_buffer.go`
- Test: `strategy-service/tests/test_worker_agent_client.py`
- Test: `strategy-service/tests/test_strategy_indicators.py`
- Test: `strategy-service/internal/runtimeagent/indicator_sync_test.go`
- Test: `strategy-service/internal/runtimeagent/indicator_buffer_test.go`

**Interfaces:**
- Consumes: worker hello `protocol_version=2` and per-bar strategy callbacks.
- Produces: typed `IndicatorFrameV2` with contiguous `stream_sequence`,
  `market_time_ms`, immutable definitions, and sparse typed samples.

- [ ] Add Python RED tests proving every accepted bar queues a V2 frame,
  independent stream sequences remain contiguous, and bars without samples are
  retained.
- [ ] Run the focused Python tests and verify failure is caused by the missing
  V2 payload.
- [ ] Add Go RED tests for 1/1023/1024/1025/2049 frames, markers only on bars 4
  and 9, irregular actual times, immediate duplicate idempotency, conflicting
  duplicate rejection, lower/gap rejection, and independent streams.
- [ ] Run focused Go tests and verify they fail against the V1 count-based
  buffer.
- [ ] Add the typed V2 protobuf messages on new field numbers while reserving
  the V1 field only at the coordinated removal step; regenerate Python and Go
  bindings using the repository commands.
- [ ] Implement Python per-stream sequencing, candle-open-time selection,
  immutable definitions, typed sparse samples, and empty-frame delivery.
- [ ] Implement the Go stream clock and deterministic V2 chunks. Advance every
  registered definition once per frame; derive chunk and marker offset from
  sequence and store actual times.
- [ ] Run the focused Python and Go suites until green, then run all
  strategy-service Go, Python, and tracked shell tests.

### Task 2: Add V2 Core Persistence, Gateway Preservation, and Portal Rendering

**Files:**
- Modify: `core-service/proto/portfolio_service.proto`
- Modify: `core-service/internal/storage/migrations/*.sql`
- Modify: `core-service/internal/repository/timescale.go`
- Modify: `core-service/internal/service/grpc.go`
- Modify: `control-panel-service/internal/runtimechannel/platform_proxy.go`
- Modify: `gateway/quant-handler/internal/app/session_indicators.go`
- Modify: `gateway/quant-frontend/src/api/client.ts`
- Create: `gateway/quant-frontend/src/utils/strategyIndicatorV2.ts`
- Modify: `gateway/quant-frontend/src/components/SessionChartPanel.tsx`
- Test: matching repository, service, proxy, handler, and executable frontend
  unit tests.

**Interfaces:**
- Consumes: Agent V2 definitions/chunks with actual times and revisions.
- Produces: Core V2 save/finalize/list RPCs and field-for-field HTTP/portal
  models.

- [ ] Add RED database/service tests for V2 constraints, monotonic append,
  idempotent retry, stale revision rejection, immutable finalized rows, and
  indicator-only destructive migration.
- [ ] Add RED proxy/handler tests proving all V2 fields and nullable scalar
  values survive each boundary.
- [ ] Add executable frontend RED tests proving irregular `times_ms` and marker
  `time_ms` are used directly and sparse entries do not shift.
- [ ] Implement V2 protobufs, transactional migration/baseline, repository,
  Core service, RuntimeChannel proxy, and handler mapping.
- [ ] Implement pure frontend V2 validation/expansion/merge functions and
  replace interval/offset time inference in the chart.
- [ ] Run isolated fresh/bootstrap and populated-upgrade database tests twice,
  then run focused Core, control-panel, handler, and frontend suites.

### Task 3: Remove the Executable V1 Indicator Path After the Isolated Gate

**Files:**
- Modify: `strategy-service/strategy_service/indicators.py`
- Modify: `strategy-service/strategy_service/platform_proxy.py`
- Modify: `strategy-service/strategy_service/grpc_server.py`
- Modify: V1 protobuf/RPC/repository/handler/frontend files identified by the
  exact no-V1 scan in the approved Indicator plan.
- Test: no-V1 source and descriptor contract tests.

**Interfaces:**
- Consumes: passing isolated Worker→Agent→control-panel→Core→handler→frontend
  V2 evidence.
- Produces: one V2-only coordinated candidate with V1 tags/RPC identifiers
  reserved.

- [ ] Run and retain the additive isolated V2 gate before removal.
- [ ] Add a RED no-V1 contract that rejects executable V1 fields, RPCs, old
  table names, old JSON envelopes, `IndicatorChunkBuffer`, and
  `save_strategy_indicators`.
- [ ] Delete the Python direct chunk fallback and all executable V1 surfaces;
  reserve wire identifiers rather than reusing them.
- [ ] Regenerate bindings and schema bundles, run the no-V1 scan, and rerun the
  identical isolated V2 gate.

### Task 4: Make RuntimeChannel Cleanup Stream-Identity-Aware

**Files:**
- Modify: `control-panel-service/internal/runtimechannel/registry.go`
- Modify: `control-panel-service/internal/runtimechannel/service.go`
- Test: `control-panel-service/internal/runtimechannel/auth_test.go`

**Interfaces:**
- Consumes: exact `*runtimeStream` returned by `Registry.Register`.
- Produces: `Unregister(runtimeID string, expected *runtimeStream) bool` and an
  owner-clear decision tied to the current stream.

- [ ] Add a RED test registering A then B for one runtime, cleaning up A, and
  proving B remains in the registry and routable.
- [ ] Add a service-level RED test proving A's deferred cleanup cannot clear
  B's persisted owner.
- [ ] Implement compare-and-remove unregister and conditional owner clearing.
- [ ] Run RuntimeChannel tests and `go vet ./internal/runtimechannel`.

### Task 5: Enforce Spot USDT in Core Order Admission

**Files:**
- Modify: `core-service/internal/order/service/grpc.go`
- Modify: `core-service/internal/order/risk/spot_filters.go`
- Test: `core-service/internal/order/service/*spot*_test.go`
- Test: `core-service/internal/order/risk/spot_filters_test.go`

**Interfaces:**
- Consumes: trusted `SpotSymbolRule.QuoteAsset`.
- Produces: stable `SPOT_QUOTE_UNSUPPORTED` rejection before execution for
  every non-USDT Spot order.

- [ ] Add RED ordinary/direct PlaceOrder tests for `BTCUSDC` in Backtest and
  Demo and a green control for `BTCUSDT`.
- [ ] Add a RED risk-layer test proving non-USDT trusted metadata is rejected
  even outside Session preflight.
- [ ] Implement the Core admission guard and risk defense in depth without
  suffix inference.
- [ ] Run Core Spot service/risk tests, all Core tests, and `go vet ./...`.

### Task 6: Normalize Coverage Evidence and Correct Candidate Reachability

**Files:**
- Modify: `hushine-deploy/scripts/audit/census/census/coverage.py`
- Modify: `hushine-deploy/scripts/audit/census/census/candidates.py`
- Modify: `hushine-deploy/scripts/audit/census/census/db_matrix.py`
- Modify: `hushine-deploy/docs/code-census/commands.md`
- Test: `hushine-deploy/scripts/audit/census/tests/test_coverage.py`
- Test: `hushine-deploy/scripts/audit/census/tests/test_candidates.py`
- Test: `hushine-deploy/scripts/audit/census/tests/test_db_matrix.py`

**Interfaces:**
- Consumes: Go cover profiles/function reports, Python coverage JSON,
  `frontend-precise.json`, and observability evidence.
- Produces: normalized file/function evidence with workspace-relative subjects
  and conservative candidate buckets.

- [ ] Add RED tests requiring session-stop to validate and include frontend
  precise coverage.
- [ ] Add RED tests mapping Go, Python, and frontend covered files/functions to
  exact candidate subjects.
- [ ] Add a RED test proving a referenced path containing `legacy` is naming
  evidence, not `unreferenced-static`.
- [ ] Implement normalized evidence readers and separate naming suspicion from
  actual reference reachability.
- [ ] Update command documentation and run all Python and Node Census tests.

### Task 7: Give Instrumented Services Their Full Graceful-Exit Budget

**Files:**
- Modify: `hushine-deploy/scripts/audit/census/start_instrumented_stack.sh`
- Test: `hushine-deploy/scripts/audit/census/tests/test_start_instrumented_stack.py`

**Interfaces:**
- Consumes: PID file entries and `CODE_CENSUS_STOP_TIMEOUT_SECONDS` with
  default `10`.
- Produces: bounded TERM/poll/KILL shutdown with per-service graceful/forced
  status.

- [ ] Add RED tests using fake process tools for fast graceful exit, delayed
  exit within the deadline, and forced exit after the deadline.
- [ ] Implement monotonic deadline polling without a fixed one-second grace.
- [ ] Validate timeout input, retain process-tree behavior, and report forced
  services without leaking command lines or environment.
- [ ] Run shell syntax, shell contract, and all Census tests.

### Task 8: Cross-Repository Review, Verification, Commit, and Push

**Files:**
- Modify only documentation needed to reflect the verified final behavior.

**Interfaces:**
- Consumes: all task commits and fresh verification outputs.
- Produces: clean, remote-synchronized repository branches and an exact changed
  file/line summary.

- [ ] Run every AGENTS.md repository test, vet, frontend build/script test,
  schema bundle/bootstrap, OpenSpec validation, Windows compile/native-eligible
  contracts, and `git diff --check`.
- [ ] Run isolated V2 and coverage smoke gates without touching the active
  manual run.
- [ ] Review every diff against the six findings and the three approved specs.
- [ ] Commit repository-scoped changes, push each
  `cleanup/medium-baseline-20260710` branch, and verify local HEAD equals its
  upstream.
- [ ] Report changed files, inserted/deleted line counts, tests, and any
  external acceptance still blocked by unavailable credentials or services.

