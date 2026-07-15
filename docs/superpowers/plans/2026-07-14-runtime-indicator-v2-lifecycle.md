# Runtime Indicator V2 and Worker Lifecycle Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace count-inferred custom indicators with a typed, actual-time V2 protocol and persistence model, then make every worker termination path durably finalize the last contiguous indicator bar before publishing its desired terminal state or replacing the worker; if safe drain/finalization cannot complete, publish `recoverable`, retain the tail, and finish it by retry.

**Architecture:** The Python session worker assigns a zero-based sequence to every accepted market bar and sends one typed V2 frame per stream/bar. The Go runtime-agent validates the stream clock, advances every declared series, owns deterministic 1024-bar chunks, and persists open revisions plus explicit finalization operations through RuntimeChannel to core-service. Core-service stores actual time arrays, nullable scalar arrays, and typed markers in a V2-only schema; the gateway and frontend pass/render those fields without inferring time from interval or offset. A generation-aware lifecycle coordinator serializes final status, unexpected exit, protocol failure, and Bare restart so no old worker can mutate a replacement session.

**Tech Stack:** Protocol Buffers/gRPC, Python 3.13 with pytest, Go 1.26 with `google.golang.org/protobuf` and `github.com/lib/pq`, PostgreSQL/TimescaleDB, React 19/TypeScript 5.7, lightweight-charts 5.2, Node executable test scripts, Docker/runtime coverage tooling.

## Global Constraints

- The coordinated worker protocol version is exactly `2`; a missing or different `WorkerHello.protocol_version` fails with code `RUNTIME_WORKER_PROTOCOL_UNSUPPORTED` before `StartSession` is sent.
- Consume, do not redefine, the dependency-contract plan's single immutable
  authenticated `WorkerIdentity{SessionID, PID, Token, Generation}`.
  `SessionID` is the canonical `StartSession` ID. `Connect` captures that
  identity once and passes it by value to every frame, exit, stream-close,
  admission, lifecycle, indicator, and cleanup path. No parallel
  `IndicatorFrameIdentity`, `WorkerConnection`, pending/real Session alias, or
  field-by-field identity reconstruction is allowed. The token is opaque and
  is never logged or persisted.
- V1 custom-indicator protobuf fields, RPC names, domain types, repository paths, JSON envelopes, and frontend reconstruction code remain deprecated but executable through Tasks 1–10 and the complete Task 11 pre-cutover gate. They are removed only in Task 11's post-seal coordinated candidate batch, which remains non-deployable/non-push until Task 12 reruns every gate; field number `15` is reserved in that batch and never reused. Before that batch, an untouched V1 database plus the pre-cutover source remains a valid rollback surface; the isolated V2 acceptance stack explicitly selects protocol 2 and never mixes V1/V2 persistence in one database.
- Existing custom-indicator definitions and chunks are deleted; sessions, portfolios, venues, strategies, orders, fills, wallet snapshots, notifications, and reconciliation records retain every pre-existing field value and row. The sole additive Session field is `indicator_finalization_pending`, backfilled/defaulted false and changed only by the lifecycle coordinator.
- `chunk_size` is exactly `1024`; `chunk_index = stream_sequence / 1024`, `offset = stream_sequence % 1024`, and a full chunk becomes immutable immediately.
- Open chunks flush every `2s`; full chunks flush immediately; all network I/O occurs outside indicator-buffer locks; one session flush owner serializes periodic, boundary, terminal, and restart persistence.
- Every accepted bar emits one frame even with no scalar and no marker; a failed user callback discards partial indicator writes and emits one empty frame for that bar before existing guarded/fatal handling.
- Sequence is independent per exact `stream_key`; V2 `market_time_ms` is exactly the candle `open_time` used as chart/bar identity. The adapted `MarketData.timestamp` remains the production close timestamp for existing strategy/order semantics, and `close_time` is retained separately instead of overwriting open time. Time gaps are valid when sequence remains contiguous.
- The Agent retains one bounded canonical payload hash for the immediately previous accepted frame of each stream. An immediate duplicate of `(session_id, stream_key, stream_sequence, market_time_ms)` is idempotently ignored only when `interval_ms`, ordered definitions, and ordered samples are byte-equivalent under deterministic protobuf encoding. Same sequence/time with a different payload, same sequence with a different time/interval, any older sequence, or a gap raises `RUNTIME_INDICATOR_PROTOCOL_ERROR`, closes that generation's frame/order admission, finalizes the last contiguous state, and makes the Session recoverable. Persistence-level exact same-revision chunk retries remain a separate idempotency contract and must not change row count, revision, or `updated_at`.
- Indicator definitions are immutable within a session; changing any key/type/pane/configuration requires a new session, including Bare hot reload.
- Every authenticated worker-final `finished`, legacy `completed` (normalized to
  `finished`), `failed`, `stopped`, `stop_failed`, and `recoverable`, plus max-loss, Bare restart,
  protocol failure, unexpected-exit, and Agent shutdown path finalizes before its
  desired terminal state. A frame-drain or persistence failure instead publishes
  `recoverable`, retains buffers for retry, never finalizes while an admitted
  handler can still mutate them, and never returns a success acknowledgement.
- Runtime heartbeat and RuntimeChannel stay alive while user Python code is blocked; local worker IPC remains loopback TCP and must compile/run on Windows without Unix sockets, POSIX-only paths, or Unix-only signals.
- `Agent.Shutdown` is the sole process-shutdown owner. Main invokes it exactly
  once and never independently calls `WorkerManager.StopAll`, stops worker IPC,
  or cancels RuntimeChannel. `SessionLifecycle` remains the sole terminal-state
  coordinator beneath it. RuntimeChannel owns an independent context and stays
  connected, heartbeating, and platform-call-capable until every bounded
  terminal attempt completes or its exact retry state is durably checkpointed;
  only then may main stop IPC, cancel RuntimeChannel, and exit.
- A failed terminal operation is not retained until a versioned retry journal
  containing exact V2 definitions/chunks/finalization guards, payload hashes,
  desired/effective status, and acknowledged-step state is atomically persisted
  under configured persistent `StateRoot`. The journal never stores
  `WorkerIdentity.Token`; it loads before new Runs are admitted, replays only
  after RuntimeChannel authentication, blocks reuse of its canonical Session
  ID, and is deleted only after finalization, status/pending-clear
  acknowledgement, and cleanup complete. If both completion and durable
  checkpointing fail, `Agent.Shutdown` must not cancel RuntimeChannel or permit
  process exit; an in-memory-only record never satisfies shutdown.
- Route platform calls only through authenticated RuntimeChannel methods; a session is still routed only by `runtime_id`, and no internal database/Kafka/order address is exposed to self-hosted or Bare workers.
- The destructive `0002_runtime_indicator_v2.sql` artifact may be generated and exercised before cutover only on an ownership-verified isolated acceptance database. The mandatory production migration runner inspects the target schema before executing `0002`: fresh V2 bootstrap is non-destructive and needs no cutover seal; a legacy `values_json` schema fails closed unless the database has the exact acceptance ownership token/comment or explicit cutover mode supplies a valid SHA-bound pre-cutover seal. The default/shared `portfolio` target with legacy V1 data always refuses without that explicit authorization, so `make ensure-dbs` cannot bypass this guard.
- Generated SQL is regenerated from service-owned migrations; generated protobuf files are regenerated from their authoritative `.proto` files and never hand-edited.
- Preserve dirty work and commit only owned files inside each independent repository. Every `git add` block below is an owned-file inventory, not permission to stage a pre-existing dirty path wholesale: capture `git status --short` before each task, use `git add -p` for any already-dirty path, stage generated artifacts by exact filename, and inspect `git diff --cached --check` plus `git diff --cached` before every commit.

---

## Execution Order

The full-system acceptance Task 0 freezes repositories and current Notion
requirements first. Then complete the Runtime dependency-contract plan, execute
this plan's physically ordered Tasks 1–12, rerun the dependency plan's focused
gate on the combined descriptors/runtime tree, and only then begin the Binance
Spot plan. Do not run this plan standalone against a pre-dependency tree.

The dependency plan owns the first protocol regeneration in its Task 7 and the
atomic pending/readiness/cleanup cutover in its Task 8. Indicator Task 3 starts
only after both dependency tasks are committed and verified; it regenerates
from that combined authoritative proto, preserves every dependency-owned nested
field/tag, and never restores an earlier generated file. Indicator Task 11,
after its SHA-bound pre-cutover seal, is the only task that reserves WorkerFrame
field 15. After Task 12's post-cutover
rerun, rerun the dependency descriptor/value/checksum gate against the combined
tree before any completion claim.

Within this plan execute Tasks 1–12 strictly: core contract/schema,
authenticated control proxy, worker protocol generation/gate, Python emission,
Go chunking/persistence, gateway, lifecycle coordination, blocked-worker/
Windows safety, strategy-template regression, frontend rendering, additive V2
pre-cutover database/service-chain/real-page proof, coordinated V1 removal, and
the identical post-cutover proof. Do not start a task before its stated
dependencies pass and are committed in their independent repositories.

## File Map

### `core-service`

- `proto/portfolio_service.proto` — additive V2 RPC/messages during migration, followed by final V1 removal.
- `gen/portfoliov1/portfolio_service.pb.go`, `gen/portfoliov1/portfolio_service_grpc.pb.go` — generated Go contract.
- `internal/domain/strategy_indicator.go` — V2 definition, chunk, nullable scalar, marker, and finalization domain types.
- `internal/domain/model.go` — durable `IndicatorFinalizationPending` Session fact.
- `internal/repository/repository.go` — V2 persistence/list/finalize interface and filters.
- `internal/repository/timescale.go` — immutable definitions, monotonic open UPSERT, explicit guarded finalization, and typed array/marker scanning.
- `internal/repository/strategy_indicator_test.go`, `internal/repository/session_test.go` — real-database V2 constraints, idempotency, monotonic revision/finalization, and optional finalization-pending Session updates.
- `internal/service/grpc.go` — ownership checks, V2 validation/conversion, and V2 RPC handlers.
- `internal/service/grpc_strategy_indicator_test.go`, `internal/service/grpc_strategy_test.go` — V2 behavior/ownership plus omitted/true/false finalization-pending update semantics.
- `internal/service/grpc_strategy_indicator_proto_test.go` — generated field contract test.
- `internal/storage/migrations/0001_current_schema_baseline.sql` — fresh-database V2 schema.
- `internal/storage/migrations/0002_runtime_indicator_v2.sql` — transactional, indicator-only destructive upgrade.
- `internal/storage/migrations/baseline_contract_test.go` — migration inventory update.
- `internal/storage/migrations/migration_contract_test.go` — V2 schema contract assertions.
- `internal/storage/migrations/indicator_v2_migration_test.go` — populated-upgrade row-retention test.
- `internal/storage/migrations/indicator_v2_bootstrap_test.go`, `internal/storage/migrations/testdata/indicator_v1_fixture.sql` — isolated fresh bootstrap and reproducible populated-V1 fixture.
- `cmd/ensure-portfolio-db/main.go`, `cmd/ensure-portfolio-db/cutover_guard.go`, `cmd/ensure-portfolio-db/main_test.go`, `cmd/ensure-portfolio-db/cutover_guard_test.go` — migration body and ledger entry committed in one database transaction plus the mandatory destructive-V1 authorization guard.
- `tests/repository_test.go`, `internal/service/grpc_portfolio_meta_test.go` — repository test doubles updated for the V2 interface.

### `control-panel-service`

- `internal/runtimechannel/platform_proxy.go` — authenticated `SaveStrategyIndicatorsV2` and `FinalizeStrategyIndicatorChunksV2` dispatch.
- `internal/runtimechannel/platform_proxy_test.go` — runtime/user/session ownership and field-preservation tests.

### `strategy-service`

- `proto/runtime_worker.proto` — WorkerHello version and typed `IndicatorFrameV2`; V1 field/tag removal at cutover.
- `gen/runtimeworkerv1/runtime_worker.pb.go`, `gen/runtimeworkerv1/runtime_worker_grpc.pb.go` — generated Go worker IPC types.
- `strategy_service/gen/runtime_worker_pb2.py`, `strategy_service/gen/runtime_worker_pb2_grpc.py` — generated Python worker IPC types.
- `gen/portfoliov1/portfolio_service.pb.go`, `gen/portfoliov1/portfolio_service_grpc.pb.go`, `strategy_service/gen/portfolio_service_pb2.py`, `strategy_service/gen/portfolio_service_pb2_grpc.py` — generated local V2 portfolio proxy types.
- `generate_proto.sh` — authoritative regeneration command; only portability fixes necessary to generate the exact sources are allowed.
- `strategy_service/strategy/base.py` — per-stream sequence assignment, open-time bar identity, empty failed-bar emission, partial-write discard, callback error propagation, and hot-reload definition immutability.
- `strategy_service/marketdata_adapter.py` — retain production `open_time` and `close_time` separately while preserving the close-time `MarketData.timestamp` contract.
- `strategy_service/grpc_server.py` — first-frame definitions and V2 sink signature.
- `strategy_service/worker_agent_client.py` — protocol-2 hello and typed V2 frame encoding.
- `strategy_service/session_worker_entry.py` — final acknowledgement/error propagation remains worker exit gate.
- `strategy_service/indicators.py` — typed marker fields and removal of the obsolete Python chunker after hosted V2 cutover.
- `tests/test_runtime_worker_proto.py`, `tests/test_worker_agent_client.py`, `tests/test_strategy_indicators.py`, `tests/test_marketdata_adapter.py`, `tests/test_grpc_server.py`, `tests/test_session_worker_entry.py` — Python protocol/sequencing/open-time/transport-error tests.
- `internal/runtimeagent/indicator_buffer.go` — deterministic sequence-based series chunks with actual times and revisions.
- `internal/runtimeagent/indicator_buffer_test.go` — boundary, sparse-marker, multi-marker, and time-gap tests.
- `internal/runtimeagent/indicator_sync.go` — per-stream clocks, immutable definitions, V2 save/finalize requests, retry, and single flush ownership.
- `internal/runtimeagent/indicator_sync_test.go` — 1/1023/1024/1025/2049, 1023+2, duplicates/gaps, revisions, and independent stream tests.
- `internal/runtimeagent/worker_server.go` — generation in worker identity and alias safety.
- `internal/runtimeagent/worker_ipc_server.go` — generation-aware frame/stream-close callbacks.
- `internal/runtimeagent/worker_manager.go` — generation allocation, exit event, final-status acknowledgement, graceful/forced process lifecycle.
- `internal/runtimeagent/session_lifecycle.go` — one terminal coordinator for final status, unexpected exit, protocol failure, and restart.
- `internal/runtimeagent/agent.go` — handshake gate, V2 dispatch, terminal coordinator integration, and restart ordering.
- `internal/runtimeagent/worker_*_test.go`, `internal/runtimeagent/agent_test.go`, `internal/runtimeagent/session_lifecycle_test.go` — generation, exit, terminal-state, and restart tests.
- `cmd/runtime-agent/main.go`, `cmd/runtime-agent/main_test.go` — wire Manager exit/stream callbacks to Agent and prove loopback TCP/heartbeat independence.
- `scripts/runtime-agent-platform.test.sh` — Windows cross-build remains mandatory.
- `scripts/runtime-agent-windows-native.test.ps1`, `.github/workflows/runtime-agent-windows.yml` — native Windows launcher, loopback IPC, process-reap, generation/restart, and real blocked-worker acceptance for the exact commit.
- `tests/strategies/block_after_first_indicator.py`, `internal/runtimeagent/blocked_worker_integration_test.go`, `scripts/runtime-agent-blocked-worker.test.sh` — real blocked-Python heartbeat/replacement acceptance.
- `internal/runtimeagent/indicator_v2_integration_test.go` — Agent-level 1023+2 and terminal ordering integration.
- `strategy_templates/zecusdt_reconciliation_bollinger_notify.py` — remove the erroneous `bb_width_bps=None` overwrite.
- `tests/test_zecusdt_reconciliation_bollinger_notify.py` — deterministic width and marker/decision alignment.

### `gateway/quant-handler`

- `internal/app/session_indicators.go` — V2 JSON mapping with actual times, nullable scalars, markers, revision, protocol version, and finalized.
- `internal/app/session_indicators_test.go` — field-for-field executable HTTP serialization tests.
- `internal/app/session_history.go`, `internal/app/session_history_test.go` — V2 client double/request types and the durable finalization-pending Session fact.

### `gateway/quant-frontend`

- `src/api/client.ts` — V2 indicator API types.
- `src/components/sessionIndicatorData.ts` — pure actual-time expansion, marker conversion, revision merge, and tail-state functions.
- `src/components/SessionChartPanel.tsx` — use pure V2 functions, immutable finalized cache, open-tail status UI.
- `src/pages/SessionDetailPage.tsx` — serially refresh the Session until the durable indicator-finalization pending fact clears.
- `src/index.css` — accessible open/finalized tail badge styling.
- `scripts/session-indicator-data.test.mjs` — transpile/import pure TypeScript and execute sparse-marker/revision/finalized assertions.
- `scripts/session-custom-indicators.test.mjs` — structural integration checks only; alignment assertions move to executable data tests.
- `scripts/runtime-status.test.mjs` — executable Session-record polling truth table and non-overlapping detail-loop contract.
- `package.json` — add the executable V2 data test command.

### `hushine-deploy`

- `db/generated/portfolio.sql`, `db/generated/README.md` — regenerated V2 migration bundle and source inventory.
- `db/README.md` — destructive indicator-only upgrade/fresh bootstrap procedure.
- `scripts/runtime-indicator-v2-db-smoke.sh` — acceptance-owned fresh/bootstrap and populated-V1 upgrade smoke on `.10`.
- `scripts/runtime-indicator-v2-smoke.sh`, `scripts/runtime-indicator-v2-service-chain.sh`, `scripts/runtime-indicator-v2-cutover-evidence.test.sh`, `Makefile` — exact focused 1023+2, blocked-worker, Windows, gateway/frontend, deterministic real-chain `start/await/advance/stop`, SHA-bound Browser evidence, and pre/post-cutover acceptance entry points.

---

### Task 1: Core V2 Contract, Schema, Repository, and RPC Boundary

**Files:**
- Modify: `core-service/proto/portfolio_service.proto`
- Modify generated: `core-service/gen/portfoliov1/portfolio_service.pb.go`
- Modify generated: `core-service/gen/portfoliov1/portfolio_service_grpc.pb.go`
- Modify: `core-service/internal/domain/strategy_indicator.go`
- Modify: `core-service/internal/domain/model.go`
- Modify: `core-service/internal/repository/repository.go`
- Modify: `core-service/internal/repository/timescale.go`
- Modify: `core-service/internal/repository/strategy_indicator_test.go`
- Modify: `core-service/internal/repository/session_test.go`
- Modify: `core-service/internal/service/grpc.go`
- Modify: `core-service/internal/service/grpc_strategy_indicator_test.go`
- Modify: `core-service/internal/service/grpc_strategy_test.go`
- Modify: `core-service/internal/service/grpc_strategy_indicator_proto_test.go`
- Modify: `core-service/internal/storage/migrations/0001_current_schema_baseline.sql`
- Create: `core-service/internal/storage/migrations/0002_runtime_indicator_v2.sql`
- Modify: `core-service/internal/storage/migrations/baseline_contract_test.go`
- Modify: `core-service/internal/storage/migrations/migration_contract_test.go`
- Create: `core-service/internal/storage/migrations/indicator_v2_migration_test.go`
- Create: `core-service/internal/storage/migrations/indicator_v2_bootstrap_test.go`
- Create: `core-service/internal/storage/migrations/testdata/indicator_v1_fixture.sql`
- Modify: `core-service/cmd/ensure-portfolio-db/main.go`
- Create: `core-service/cmd/ensure-portfolio-db/main_test.go`
- Create: `core-service/cmd/ensure-portfolio-db/cutover_guard.go`
- Create: `core-service/cmd/ensure-portfolio-db/cutover_guard_test.go`
- Modify compile doubles: `core-service/tests/repository_test.go`
- Modify compile doubles: `core-service/internal/service/grpc_portfolio_meta_test.go`

**Interfaces:**
- Consumes: authenticated `user_id`, existing `strategy_sessions`, and exact indicator types `line|histogram|marker`.
- Produces: `SaveStrategyIndicatorsV2`, `FinalizeStrategyIndicatorChunksV2`, `ListStrategyIndicatorsV2`, and `ListStrategyIndicatorChunksV2`; Go repository methods with the same V2 semantics; V2 tables under the existing table names; and a durable orthogonal `indicator_finalization_pending` Session fact used only to distinguish a recoverable Session whose retained indicator tail still needs persistence.

- [ ] **Step 1: Write generated-contract and service validation tests first**

Add a proto contract test that constructs nullable scalar slots and typed markers rather than JSON:

```go
func TestStrategyIndicatorV2ProtoContract(t *testing.T) {
    value := 1.25
    chunk := &portfoliov1.StrategyIndicatorChunkV2{
        SessionId: "sess-1", StreamKey: "binance:perpetual_futures:ETHUSDT:1m",
        IndicatorKey: "alpha", ChunkIndex: 0, StartSequence: 0, EndSequence: 1,
        StartTimeMs: 1_000, EndTimeMs: 9_000, IntervalMs: 60_000, Count: 2,
        TimesMs: []int64{1_000, 9_000},
        ScalarValues: []*portfoliov1.NullableDoubleV2{{Value: &value}, {}},
        Markers: []*portfoliov1.StrategyIndicatorMarkerV2{{
            Sequence: 1, Offset: 1, TimeMs: 9_000, Text: "BUY",
        }},
        Revision: 2, Finalized: false, ProtocolVersion: 2,
    }
    if chunk.GetTimesMs()[1] != 9_000 || chunk.GetMarkers()[0].GetTimeMs() != 9_000 {
        t.Fatalf("V2 actual time fields were not retained: %+v", chunk)
    }
    if chunk.GetScalarValues()[0].Value == nil || chunk.GetScalarValues()[1].Value != nil {
        t.Fatalf("nullable scalar shape = %+v", chunk.GetScalarValues())
    }
}
```

Add table-driven service tests that reject protocol version other than 2, `count=0`, count/time/scalar cardinality mismatch, wrong `start_sequence`, marker offset/sequence/time mismatch, finalized chunks in the save RPC, and a finalization with `expected_revision=0`. Keep the existing foreign-session test and call every V2 RPC with a foreign `user_id`. Add Session update tests proving an omitted finalization-pending field preserves the stored value while explicit `true` and `false` set and clear it without changing the Session's status.

- [ ] **Step 2: Run the focused tests and verify RED**

Run:

```bash
cd core-service
go test ./internal/service -run 'StrategyIndicatorV2|StrategyIndicatorsV2' -count=1 -v
```

Expected: compilation fails because `StrategyIndicatorChunkV2`, `NullableDoubleV2`, and V2 RPC request types do not exist.

- [ ] **Step 3: Add the additive V2 portfolio protobuf contract and generate Go code**

Keep V1 messages temporarily so control-panel, strategy-service, and quant-handler can be migrated in later repository commits. Add these V2 RPCs and exact message shapes:

```protobuf
rpc SaveStrategyIndicatorsV2(SaveStrategyIndicatorsV2Request) returns (SaveStrategyIndicatorsV2Response);
rpc FinalizeStrategyIndicatorChunksV2(FinalizeStrategyIndicatorChunksV2Request) returns (FinalizeStrategyIndicatorChunksV2Response);
rpc ListStrategyIndicatorsV2(ListStrategyIndicatorsV2Request) returns (ListStrategyIndicatorsV2Response);
rpc ListStrategyIndicatorChunksV2(ListStrategyIndicatorChunksV2Request) returns (ListStrategyIndicatorChunksV2Response);

message NullableDoubleV2 {
  optional double value = 1;
}

message StrategyIndicatorMarkerV2 {
  uint64 sequence = 1;
  uint32 offset = 2;
  int64 time_ms = 3;
  string text = 4;
  optional double price = 5;
  string color = 6;
  string position = 7;
  string shape = 8;
}

message StrategyIndicatorDefinitionV2 {
  string session_id = 1;
  int64 strategy_id = 2;
  string stream_key = 3;
  string indicator_key = 4;
  string name = 5;
  string type = 6;
  string pane = 7;
  string color = 8;
  string unit = 9;
  string description = 10;
  string config_json = 11;
  uint32 protocol_version = 12;
}

message StrategyIndicatorChunkV2 {
  string session_id = 1;
  string stream_key = 2;
  string indicator_key = 3;
  uint32 chunk_index = 4;
  uint64 start_sequence = 5;
  uint64 end_sequence = 6;
  int64 start_time_ms = 7;
  int64 end_time_ms = 8;
  int64 interval_ms = 9;
  uint32 count = 10;
  repeated int64 times_ms = 11;
  repeated NullableDoubleV2 scalar_values = 12;
  repeated StrategyIndicatorMarkerV2 markers = 13;
  uint64 revision = 14;
  bool finalized = 15;
  uint32 protocol_version = 16;
}

message StrategyIndicatorChunkFinalizationV2 {
  string stream_key = 1;
  string indicator_key = 2;
  uint32 chunk_index = 3;
  uint64 expected_revision = 4;
}
```

Use the existing request filters and ownership shape, but make V2 save accept definitions plus **open** chunks and make finalization a separate request:

```protobuf
message SaveStrategyIndicatorsV2Request {
  string session_id = 1;
  repeated StrategyIndicatorDefinitionV2 definitions = 2;
  repeated StrategyIndicatorChunkV2 chunks = 3;
  int64 user_id = 100;
}
message SaveStrategyIndicatorsV2Response {
  int32 definitions_saved = 1;
  int32 chunks_saved = 2;
}
message FinalizeStrategyIndicatorChunksV2Request {
  string session_id = 1;
  repeated StrategyIndicatorChunkFinalizationV2 chunks = 2;
  int64 user_id = 100;
}
message FinalizeStrategyIndicatorChunksV2Response { int32 chunks_finalized = 1; }
message ListStrategyIndicatorsV2Request {
  string session_id = 1;
  string stream_key = 2;
  int64 user_id = 100;
}
message ListStrategyIndicatorsV2Response { repeated StrategyIndicatorDefinitionV2 definitions = 1; }
message ListStrategyIndicatorChunksV2Request {
  string session_id = 1;
  string stream_key = 2;
  repeated string indicator_keys = 3;
  int64 start_time_ms = 4;
  int64 end_time_ms = 5;
  int64 user_id = 100;
}
message ListStrategyIndicatorChunksV2Response { repeated StrategyIndicatorChunkV2 chunks = 1; }
```

In the same additive contract, reserve non-conflicting Session fields (the
dependency plan owns `SaveSessionRequest.initial_status = 15`):

```protobuf
// StrategySessionEntry
bool indicator_finalization_pending = 25;

// UpdateSessionRequest
optional bool indicator_finalization_pending = 6;
```

The optional presence bit is mandatory: old callers that omit field 6 must not
clear a retained tail. Regenerate every Go/Python copy from this authoritative
proto; do not hand-edit generated code.

Generate:

```bash
make proto-portfolio
```

Expected: generated Go files contain every V2 message/RPC and still contain V1 only as a temporary migration surface.

- [ ] **Step 4: Define the exact V2 domain and repository interfaces**

Replace count/JSON domain structs with focused V2 types (the old types may remain only until Task 11 removes the transitional RPC):

```go
const StrategyIndicatorProtocolV2 uint32 = 2

type StrategyIndicatorMarkerV2 struct {
    Sequence uint64
    Offset   uint32
    TimeMS   int64
    Text     string
    Price    *float64
    Color    string
    Position string
    Shape    string
}

type StrategyIndicatorChunkV2 struct {
    SessionID, StreamKey, IndicatorKey string
    ChunkIndex                         uint32
    StartSequence, EndSequence         uint64
    StartTimeMS, EndTimeMS, IntervalMS int64
    Count                              uint32
    TimesMS                            []int64
    ScalarValues                       []*float64
    Markers                            []StrategyIndicatorMarkerV2
    Revision                           uint64
    Finalized                          bool
    ProtocolVersion                    uint32
}

type StrategyIndicatorChunkFinalizationV2 struct {
    StreamKey, IndicatorKey string
    ChunkIndex              uint32
    ExpectedRevision        uint64
}
```

Expose these repository methods:

```go
SaveStrategyIndicatorsV2(context.Context, string, []domain.StrategyIndicatorDefinitionV2, []domain.StrategyIndicatorChunkV2) (int, int, error)
FinalizeStrategyIndicatorChunksV2(context.Context, string, []domain.StrategyIndicatorChunkFinalizationV2) (int, error)
ListStrategyIndicatorDefinitionsV2(context.Context, string, string) ([]domain.StrategyIndicatorDefinitionV2, error)
ListStrategyIndicatorChunksV2(context.Context, StrategyIndicatorChunkFilterV2) ([]domain.StrategyIndicatorChunkV2, error)
```

Update every repository double with these exact signatures so compilation failures identify stale consumers immediately.

Extend `domain.StrategySession`, `sessionSelectColumns`, `scanSession`, and
`toProtoSession` with `IndicatorFinalizationPending bool`. Change the repository
Session update boundary to accept `*bool`: `nil` preserves the stored column,
while explicit true/false updates it in the same SQL statement as status/error.
The service passes the generated optional field pointer rather than `Get...()`
alone, preserving presence semantics in every existing caller and test double.

- [ ] **Step 5: Write migration contract and populated-upgrade tests before SQL**

The migration contract must assert all of the following strings exist across baseline + `0002`: `indicator_finalization_pending boolean`, `protocol_version`, `times_ms bigint[]`, `scalar_values double precision[]`, `markers_json jsonb`, `revision bigint`, `start_sequence`, `end_sequence`, both cascade foreign keys, `count > 0 AND count <= 1024`, and the marker validation trigger/function. Update the expected file list to:

```go
want := []string{
    "0000_create_schema_migrations.sql",
    "0001_current_schema_baseline.sql",
    "0002_runtime_indicator_v2.sql",
}
```

In the integration-tag migration test, seed at least one relationally valid row in **every** retained current portfolio table—`users`, `portfolios`, `venues`, `venue_wallet_states`, `venue_events`, `strategies`, `portfolio_strategies`, `strategy_sessions`, `session_venues`, `portfolio_snapshots`, `notification_settings`, `notification_channels`, `notification_plans`, and `reconciliation_runs` (`orders`/`fills` live in another database and are checked by the deploy smoke in Task 12). Insert one V1 definition/chunk, compute a stable ordered row count/hash for every retained table, apply `0002` inside a transaction, and require every count/hash to remain identical. For `strategy_sessions`, hash an explicit projection of all pre-existing columns so adding the new boolean does not create a false data-drift failure, then separately require every upgraded row to have `indicator_finalization_pending=false`. Then additionally assert:

```go
if got := countRows(t, db, "strategy_sessions"); got != beforeSessions { t.Fatalf(...) }
if got := countRows(t, db, "portfolio_snapshots"); got != beforeSnapshots { t.Fatalf(...) }
if got := countRows(t, db, "reconciliation_runs"); got != beforeReconciliation { t.Fatalf(...) }
if got := countRows(t, db, "notification_settings"); got != beforeNotifications { t.Fatalf(...) }
if got := countRows(t, db, "strategy_indicator_definitions"); got != 0 { t.Fatalf(...) }
if got := countRows(t, db, "strategy_indicator_chunks"); got != 0 { t.Fatalf(...) }
```

- [ ] **Step 6: Run migration tests and verify RED**

Run:

```bash
cd core-service
go test ./internal/storage/migrations -run 'IndicatorV2|MigrationSet|FinalContracts' -count=1 -v
```

Expected: FAIL because `0002_runtime_indicator_v2.sql` and V2 baseline columns/constraints do not exist.

- [ ] **Step 7: Create the destructive-only-to-indicators V2 migration and matching baseline**

`0002_runtime_indicator_v2.sql` must add the non-destructive Session fact, then conditionally drop the indicator tables only when the old `values_json` column exists (so a fresh database that already created V2 in `0001` is not rebuilt), then create the V2 definitions first and chunks second. The core schema must contain this shape:

Treat `0002` as a cutover artifact, not an additive shared-environment rollout.
Until Task 11's pre-cutover seal exists, run it only in the unique
`hushine_indicator_*` databases created and ownership-checked by this plan's
integration/smoke helpers. The checked-in file and generated bundle may exist,
but operator documentation and scripts must refuse a shared/long-lived target
unless the exact pre-cutover evidence record for the current repository SHAs is
provided. No ordinary development command may opportunistically migrate the
shared `.10` `portfolio` database.

```sql
ALTER TABLE strategy_sessions
  ADD COLUMN IF NOT EXISTS indicator_finalization_pending boolean NOT NULL DEFAULT false;

DO $migration$
BEGIN
  IF EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema = current_schema()
      AND table_name = 'strategy_indicator_chunks'
      AND column_name = 'values_json'
  ) THEN
    DROP TABLE strategy_indicator_chunks;
    DROP TABLE strategy_indicator_definitions;
  END IF;
END
$migration$;

CREATE TABLE IF NOT EXISTS strategy_indicator_definitions (
  session_id text NOT NULL,
  strategy_id bigint NOT NULL DEFAULT 0,
  stream_key text NOT NULL,
  indicator_key text NOT NULL,
  name text NOT NULL DEFAULT '',
  type text NOT NULL CHECK (type IN ('line','histogram','marker')),
  pane text NOT NULL,
  color text NOT NULL DEFAULT '',
  unit text NOT NULL DEFAULT '',
  description text NOT NULL DEFAULT '',
  config_json jsonb NOT NULL DEFAULT '{}'::jsonb,
  protocol_version smallint NOT NULL DEFAULT 2 CHECK (protocol_version = 2),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (session_id, stream_key, indicator_key),
  FOREIGN KEY (session_id) REFERENCES strategy_sessions(session_id) ON DELETE CASCADE
);

CREATE TABLE IF NOT EXISTS strategy_indicator_chunks (
  session_id text NOT NULL,
  stream_key text NOT NULL,
  indicator_key text NOT NULL,
  chunk_index integer NOT NULL CHECK (chunk_index >= 0),
  start_sequence bigint NOT NULL CHECK (start_sequence >= 0),
  end_sequence bigint NOT NULL CHECK (end_sequence >= start_sequence),
  start_time_ms bigint NOT NULL CHECK (start_time_ms > 0),
  end_time_ms bigint NOT NULL CHECK (end_time_ms > 0),
  interval_ms bigint NOT NULL CHECK (interval_ms > 0),
  count integer NOT NULL CHECK (count > 0 AND count <= 1024),
  times_ms bigint[] NOT NULL,
  scalar_values double precision[] NOT NULL DEFAULT '{}',
  markers_json jsonb NOT NULL DEFAULT '[]'::jsonb,
  revision bigint NOT NULL CHECK (revision > 0),
  finalized boolean NOT NULL DEFAULT false,
  protocol_version smallint NOT NULL DEFAULT 2 CHECK (protocol_version = 2),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (session_id, stream_key, indicator_key, chunk_index),
  FOREIGN KEY (session_id, stream_key, indicator_key)
    REFERENCES strategy_indicator_definitions(session_id, stream_key, indicator_key)
    ON DELETE CASCADE,
  CHECK (start_sequence = chunk_index::bigint * 1024),
  CHECK (end_sequence = start_sequence + count - 1),
  CHECK (cardinality(times_ms) = count),
  CHECK (times_ms[1] = start_time_ms AND times_ms[count] = end_time_ms),
  CHECK (revision = count),
  CHECK (jsonb_typeof(markers_json) = 'array')
);
```

Add an immutable `strategy_indicator_markers_v2_valid(markers_json,start_sequence,count,times_ms)` SQL function plus a chunk validation trigger. For every marker, require numeric `sequence`, `offset`, and `time_ms`; require `sequence BETWEEN start_sequence AND start_sequence+count-1`; require `offset=sequence-start_sequence`; and require `time_ms=times_ms[offset+1]`. The same trigger loads the referenced definition type and requires `cardinality(scalar_values)=count` for line/histogram or `cardinality(scalar_values)=0` for marker.

Copy the final object definition, constraints, functions, trigger, foreign keys, and indexes into `0001_current_schema_baseline.sql`; put `indicator_finalization_pending boolean DEFAULT false NOT NULL` directly in the baseline `strategy_sessions` table and do not copy the conditional `ALTER`/drop blocks into the baseline. For fresh bootstrap ordering, create `strategy_sessions` and its primary key before adding the indicator foreign keys: put the V2 indicator table blocks after the session-key constraint or add their foreign keys later in the baseline's `ALTER TABLE` section. The baseline must never reference a table/key that has not been created yet.

- [ ] **Step 8: Make the production migration runner fail closed before destructive V1 replacement**

Write `cutover_guard_test.go` before changing the runner. Its table uses a fake
database inspector and exact migration filename `0002_runtime_indicator_v2.sql`:

```go
tests := []struct {
    name, database, mode string
    legacyValuesJSON, freshV2, ownerMatch, sealMatches bool
    wantCode string
}{
    {"default shared legacy refuses", "portfolio", "", true, false, false, false, "INDICATOR_V2_CUTOVER_AUTH_REQUIRED"},
    {"unsafe prefixed target refuses", "hushine_indicator_acceptance_forged", "acceptance", true, false, false, false, "INDICATOR_V2_ACCEPTANCE_OWNERSHIP_INVALID"},
    {"owned acceptance legacy succeeds", "hushine_indicator_acceptance_run_upgrade", "acceptance", true, false, true, false, ""},
    {"fresh v2 bootstrap succeeds without seal", "portfolio", "", false, true, false, false, ""},
    {"stale cutover seal refuses", "portfolio", "cutover", true, false, false, false, "INDICATOR_V2_CUTOVER_SEAL_MISMATCH"},
    {"matching explicit cutover succeeds", "portfolio", "cutover", true, false, false, true, ""},
}
```

Also assert every migration other than `0002` is unaffected. Run the RED:

```bash
cd core-service
go test ./cmd/ensure-portfolio-db -run 'IndicatorV2CutoverGuard|MigrationTransaction' -count=1 -v
```

Expected: FAIL because the current ordinary runner applies every migration to
the default `portfolio` target without schema inspection or authorization.

Create `cutover_guard.go` and call it from the one mandatory migration loop
immediately before executing `0002`. It first queries whether
`strategy_indicator_chunks.values_json` exists. If it does not exist, require
the V2 baseline shape and proceed as a non-destructive fresh/idempotent path. If
it exists, authorize exactly one of:

1. `HUSHINE_INDICATOR_V2_DESTRUCTIVE_MODE=acceptance`: database name matches
   `^hushine_indicator_(acceptance|chain)_[a-z0-9_]+$`; a mode-0600 JSON file at
   `HUSHINE_INDICATOR_V2_ACCEPTANCE_OWNER_FILE` names that exact database and a
   64-hex owner token; and the live database comment is exactly
   `hushine-indicator-acceptance:<token>`. Prefix alone never authorizes.
2. `HUSHINE_INDICATOR_V2_DESTRUCTIVE_MODE=cutover`: the mode-0600 file at
   `HUSHINE_INDICATOR_V2_PRECUTOVER_SEAL` has schema/phase `1/pre`, passes the
   same SHA-256 canonical-envelope validation as
   `runtime-indicator-v2-cutover-evidence.test.sh`, and its complete
   `source_shas` map equals the mode-0600 current committed SHA map at
   `HUSHINE_INDICATOR_V2_CURRENT_SHAS`. Missing repos, dirty markers, stale SHA,
   unknown fields/version, symlink/special file, or hash mismatch refuses.

Empty/unknown mode and every mismatch return a typed error with the stable code
from the RED before beginning a transaction. The runner must not offer a
`--force`, truthy boolean, database-prefix-only, or skip-guard escape hatch.
`make ensure-dbs` invokes this same runner and therefore cannot bypass it.

After authorization, SQL execution and ledger insertion share one transaction:

```go
tx, err := acc.BeginTx(ctx, nil)
if err != nil { return fmt.Errorf("begin migration %s: %w", base, err) }
if _, err := tx.ExecContext(ctx, sqlText); err != nil {
    _ = tx.Rollback()
    return fmt.Errorf("exec %s: %w", base, err)
}
if _, err := tx.ExecContext(ctx,
    `INSERT INTO schema_migrations (filename) VALUES ($1) ON CONFLICT (filename) DO NOTHING`, base,
); err != nil {
    _ = tx.Rollback()
    return fmt.Errorf("record migration %s: %w", base, err)
}
if err := tx.Commit(); err != nil { return fmt.Errorf("commit migration %s: %w", base, err) }
```

The unit test uses a fake SQL driver to make the ledger insert fail and asserts `Rollback` occurs and `Commit` does not.

Read the target name from `PGDATABASE_PORTFOLIO` with default `portfolio`, validate it as a non-empty PostgreSQL identifier, create it with `pq.QuoteIdentifier`, use it in the target DSN, and print that exact name. This is not a routing change for normal deployments; it allows acceptance to create and destroy only its own isolated database. Add unit tests for the default, an isolated name, and rejection of an empty/unsafe name.

The acceptance smoke creates the database, writes its random 64-hex token into
the database comment and owner file, then invokes the runner in `acceptance`
mode. The explicit shared cutover command is the only caller of `cutover` mode
and consumes Task 11's sealed pre-cutover SHA map. Re-run the focused tests and
require all six guard rows plus transaction rollback GREEN.

- [ ] **Step 9: Write real-repository V2 monotonic/finalization tests before repository code**

Replace JSON-envelope tests with this sequence:

1. Save an immutable V2 definition.
2. Save revision/count 1 open chunk; identical retry returns `chunks_saved=0` without changing `updated_at`.
3. Save revision/count 2 open chunk; it replaces revision 1.
4. Revision 1 rollback, different payload at revision 2, time rollback, and `finalized=true` in Save each return `repository.ErrConflict`.
5. Higher revision 3 attempts that change `start_sequence`, `start_time_ms`,
   `interval_ms`, any prior `times_ms`, any prior scalar including NULL position,
   or any existing marker return `repository.ErrConflict`; a marker newly added
   for an already persisted sequence also conflicts. Only an exact append of
   new time/scalar slots and markers belonging to the appended sequence range
   may advance the open row.
6. Finalize with expected revision 1 returns conflict; revision 2 finalizes exactly one row; identical finalize retry returns zero without error.
7. Any later upsert returns conflict.
8. Listing reconstructs `[value,nil]`, actual times `{1000,9000}`, and a marker at sequence 1/time 9000 exactly.

Use values shaped as:

```go
v := 1.25
chunk := domain.StrategyIndicatorChunkV2{
    SessionID: sessionID, StreamKey: streamKey, IndicatorKey: "alpha",
    ChunkIndex: 0, StartSequence: 0, EndSequence: 1,
    StartTimeMS: 1_000, EndTimeMS: 9_000, IntervalMS: 60_000,
    Count: 2, TimesMS: []int64{1_000, 9_000}, ScalarValues: []*float64{&v, nil},
    Revision: 2, ProtocolVersion: 2,
}
```

- [ ] **Step 10: Implement immutable definitions, monotonic UPSERT, explicit finalize, and typed scan**

Import `github.com/lib/pq` normally (not blank-only). Convert `[]*float64` to `[]sql.NullFloat64` for `pq.Array`, marshal `[]StrategyIndicatorMarkerV2` to JSON, and scan the reverse shape.

Do not rely on revision alone. In one transaction, insert an absent row or
`SELECT ... FOR UPDATE` the existing row, then perform an append-only comparison
before UPDATE. Require unchanged start sequence/time and interval; newer count/
revision; byte/NULL-equivalent old `times_ms` and scalar arrays as the prefix of
the new arrays; byte-equivalent existing ordered markers; and every newly
appended marker sequence inside only the newly appended sequence range. Any
prefix mutation returns `repository.ErrConflict`. The guarded UPDATE still
requires the locked old revision/finalized state so a concurrent writer cannot
bypass the comparison:

```sql
ON CONFLICT (session_id, stream_key, indicator_key, chunk_index) DO UPDATE SET
  end_sequence=EXCLUDED.end_sequence,
  end_time_ms=EXCLUDED.end_time_ms,
  count=EXCLUDED.count,
  times_ms=EXCLUDED.times_ms,
  scalar_values=EXCLUDED.scalar_values,
  markers_json=EXCLUDED.markers_json,
  revision=EXCLUDED.revision,
  updated_at=NOW()
WHERE strategy_indicator_chunks.finalized=FALSE
  AND EXCLUDED.finalized=FALSE
  AND EXCLUDED.revision > strategy_indicator_chunks.revision
  AND strategy_indicator_chunks.start_sequence=EXCLUDED.start_sequence
  AND strategy_indicator_chunks.start_time_ms=EXCLUDED.start_time_ms
  AND strategy_indicator_chunks.interval_ms=EXCLUDED.interval_ms
RETURNING revision
```

Treat an exact same-revision payload as an idempotent retry without changing
`updated_at`; return `repository.ErrConflict` for every other mismatch.
Definition conflict follows the same pattern: byte-equivalent fields are
idempotent, changed type/pane/config/name metadata returns conflict.

Finalization uses:

```sql
UPDATE strategy_indicator_chunks
SET finalized=TRUE, updated_at=NOW()
WHERE session_id=$1 AND stream_key=$2 AND indicator_key=$3 AND chunk_index=$4
  AND revision=$5 AND finalized=FALSE
RETURNING revision
```

No row is success only when the loaded row is already finalized at the same revision; otherwise it is `repository.ErrConflict`.

- [ ] **Step 11: Implement V2 service ownership, validation, and conversion**

All four handlers call `requireStrategyIndicatorSession`. Validation must enforce the schema rules before repository I/O and must additionally enforce marker fields and legal marker `position` (`""|aboveBar|belowBar|inBar`) and shape (`""|circle|square|arrowUp|arrowDown`). Save rejects `chunk.finalized=true`; only Finalize can seal. Convert proto optional values without turning absent values into zero:

```go
func nullableDoublesFromProto(in []*portfoliov1.NullableDoubleV2) []*float64 {
    out := make([]*float64, len(in))
    for i, item := range in {
        if item == nil || item.Value == nil { continue }
        value := item.GetValue()
        out[i] = &value
    }
    return out
}
```

The list conversion returns `finalized`, `revision`, `times_ms`, nullable values, markers, and `protocol_version` field-for-field.

- [ ] **Step 12: Run core focused and full verification**

Run:

```bash
cd core-service
go test ./internal/service -run 'StrategyIndicatorV2|StrategyIndicatorsV2' -count=1 -v
go test ./internal/storage/migrations -count=1 -v
HUSHINE_TEST_PG_ADMIN_DSN='postgres://hushine-tech@192.168.88.10/postgres?sslmode=disable' go test -tags=integration ./internal/repository -run StrategyIndicatorV2 -count=1 -v
go test ./... -count=1
go vet ./...
```

Expected: all commands PASS. The integration helper creates a uniquely named `hushine_indicator_repo_<pid>_<random>` database through the admin DSN, applies migrations, and drops only that database in `t.Cleanup`; with `HUSHINE_TEST_PG_ADMIN_DSN` set, connection/setup failure is fatal and no test may skip.

- [ ] **Step 13: Commit only core-service files**

```bash
cd core-service
git add proto/portfolio_service.proto gen/portfoliov1/portfolio_service.pb.go gen/portfoliov1/portfolio_service_grpc.pb.go internal/domain/strategy_indicator.go internal/domain/model.go internal/repository/repository.go internal/repository/timescale.go internal/repository/strategy_indicator_test.go internal/repository/session_test.go internal/service/grpc.go internal/service/grpc_strategy_indicator_test.go internal/service/grpc_strategy_indicator_proto_test.go internal/service/grpc_strategy_test.go internal/storage/migrations/0001_current_schema_baseline.sql internal/storage/migrations/0002_runtime_indicator_v2.sql internal/storage/migrations/baseline_contract_test.go internal/storage/migrations/migration_contract_test.go internal/storage/migrations/indicator_v2_migration_test.go internal/storage/migrations/indicator_v2_bootstrap_test.go internal/storage/migrations/testdata/indicator_v1_fixture.sql cmd/ensure-portfolio-db/main.go cmd/ensure-portfolio-db/main_test.go cmd/ensure-portfolio-db/cutover_guard.go cmd/ensure-portfolio-db/cutover_guard_test.go tests/repository_test.go internal/service/grpc_portfolio_meta_test.go
git commit -m "feat: add runtime indicator v2 persistence"
```

---

### Task 2: Authenticated RuntimeChannel Proxy for V2 Persistence

**Files:**
- Modify: `control-panel-service/internal/runtimechannel/platform_proxy.go`
- Modify: `control-panel-service/internal/runtimechannel/platform_proxy_test.go`

**Interfaces:**
- Consumes: core-service V2 RPC/Session optional-field types from Task 1 and authenticated `AuthenticatedRuntime{UserID,RuntimeID}`.
- Produces: canonical platform methods `portfolio.SaveStrategyIndicatorsV2` and `portfolio.FinalizeStrategyIndicatorChunksV2`, both with injected user identity and active-session/runtime ownership checks; the existing `portfolio.UpdateSession` proxy preserves optional `indicator_finalization_pending` presence/value byte-for-byte.

- [ ] **Step 1: Write failing proxy tests for save and finalize**

Create a fake portfolio client that records both V2 requests. The tests send `user_id=0` and assert it becomes the authenticated runtime user, then try a foreign explicit user and a session owned by another runtime and assert `PermissionDenied`.

```go
payload, _ := anypb.New(&portfoliov1.FinalizeStrategyIndicatorChunksV2Request{
    SessionId: "sess-1",
    Chunks: []*portfoliov1.StrategyIndicatorChunkFinalizationV2{{
        StreamKey: "binance:perpetual_futures:ETHUSDT:1m",
        IndicatorKey: "trade_signal", ChunkIndex: 0, ExpectedRevision: 1024,
    }},
})
_, err := proxy.DispatchRuntimeRequest(ctx, runtime, "portfolio.FinalizeStrategyIndicatorChunksV2", payload)
if err != nil { t.Fatalf("finalize proxy: %v", err) }
if got := portfolio.finalizeIndicatorsV2Req.GetUserId(); got != 42 { t.Fatalf("user_id=%d", got) }
```

Through the real `Any -> DispatchRuntimeRequest -> fake portfolio client` path,
table-test three `UpdateSessionRequest` values: field 6 omitted, explicitly true,
and explicitly false (`proto.Bool(false)`). Assert the fake sees nil, pointer true,
and pointer false respectively; a `Get...()`-only reconstruction that loses
presence must fail. Repeat the explicit-false case through the fully qualified
canonical method name because that is the lifecycle retry's flag-clear path.

- [ ] **Step 2: Run tests and verify RED**

Run:

```bash
cd control-panel-service
go test ./internal/runtimechannel -run 'Indicator.*V2|SessionFinalizationPending' -count=1 -v
```

Expected: FAIL because the client interface and canonical V2 methods are absent.

- [ ] **Step 3: Add exact V2 client and dispatch cases**

Extend `PortfolioPlatformClient` with:

```go
SaveStrategyIndicatorsV2(context.Context, *portfoliov1.SaveStrategyIndicatorsV2Request, ...grpc.CallOption) (*portfoliov1.SaveStrategyIndicatorsV2Response, error)
FinalizeStrategyIndicatorChunksV2(context.Context, *portfoliov1.FinalizeStrategyIndicatorChunksV2Request, ...grpc.CallOption) (*portfoliov1.FinalizeStrategyIndicatorChunksV2Response, error)
```

Both dispatch cases must run:

```go
if req.GetUserId() != 0 && req.GetUserId() != rt.UserID {
    return nil, status.Error(codes.PermissionDenied, "user_id does not match authenticated runtime")
}
if err := p.ensureSessionOwner(ctx, rt, req.GetSessionId(), true); err != nil { return nil, err }
req.UserId = rt.UserID
```

Map short and fully qualified names in `canonicalPlatformMethod`; do not accept a V1 method as an alias for V2.

Do not rebuild an `UpdateSessionRequest` from getters. Unmarshal and forward the
generated message while applying only the existing authenticated runtime guard,
so protobuf optional presence survives. The three-state test is a compatibility
contract even if no production edit beyond regenerated types is needed.

- [ ] **Step 4: Run focused and full control-panel verification**

Run:

```bash
go test ./internal/runtimechannel -run 'Indicator.*V2|SessionFinalizationPending' -count=1 -v
go test ./... -count=1
go vet ./...
```

Expected: PASS.

- [ ] **Step 5: Commit only control-panel-service files**

```bash
git add internal/runtimechannel/platform_proxy.go internal/runtimechannel/platform_proxy_test.go
git commit -m "feat: proxy runtime indicator v2 writes"
```

---

### Task 3: Worker Protocol V2 and Handshake Gate

**Files:**
- Modify: `strategy-service/proto/runtime_worker.proto`
- Modify generated: `strategy-service/gen/runtimeworkerv1/runtime_worker.pb.go`
- Modify generated: `strategy-service/gen/runtimeworkerv1/runtime_worker_grpc.pb.go`
- Modify generated: `strategy-service/strategy_service/gen/runtime_worker_pb2.py`
- Modify generated: `strategy-service/strategy_service/gen/runtime_worker_pb2_grpc.py`
- Modify generated: `strategy-service/gen/portfoliov1/portfolio_service.pb.go`
- Modify generated: `strategy-service/gen/portfoliov1/portfolio_service_grpc.pb.go`
- Modify generated: `strategy-service/strategy_service/gen/portfolio_service_pb2.py`
- Modify generated: `strategy-service/strategy_service/gen/portfolio_service_pb2_grpc.py`
- Modify: `strategy-service/strategy_service/worker_agent_client.py`
- Modify: `strategy-service/internal/runtimeagent/agent.go`
- Modify: `strategy-service/internal/runtimeagent/worker_manager.go`
- Modify: `strategy-service/internal/runtimeagent/worker_manager_test.go`
- Modify: `strategy-service/internal/runtimeagent/worker_ipc_server_test.go`
- Modify: `strategy-service/internal/runtimeagent/agent_test.go`
- Modify: `strategy-service/tests/test_runtime_worker_proto.py`
- Modify: `strategy-service/tests/test_worker_agent_client.py`

**Interfaces:**
- Consumes: V2 portfolio proto from Task 1.
- Produces: `WorkerHello.protocol_version=2`, `IndicatorFrameV2`, `IndicatorSampleV2`, typed `IndicatorMarkerV2`, and a pre-StartSession handshake rejection with a stable code/message.

- [ ] **Step 1: Write failing Python and Go protocol tests**

Python hello assertion:

```python
frame = build_worker_hello_frame(env, pid=123)
assert frame.hello.protocol_version == 2
```

Typed frame assertion:

```python
frame = pb2.IndicatorFrameV2(
    session_id="sess-1", user_id=7, strategy_id=11,
    stream_key="binance:perpetual_futures:ZECUSDT:1m",
    stream_sequence=9, market_time_ms=99_000, interval_ms=60_000,
    samples=[pb2.IndicatorSampleV2(
        indicator_key="trade_signal",
        markers=[pb2.IndicatorMarkerV2(text="BUY", price=100.5, color="#16a34a")],
    )],
)
assert frame.stream_sequence == 9
assert frame.samples[0].markers[0].text == "BUY"
```

Go tests send hello versions `0`, `1`, and `3`; assert no `StartSession` is delivered, the pending run returns error frame code `RUNTIME_WORKER_PROTOCOL_UNSUPPORTED`, and the message includes `required=2 received=<n>`. Each rejection sends `ShutdownWorker` with that reason, stops and waits for the pending worker within an injected bound, reaps its process and IPC stream, and leaves zero pending/active identities, aliases, cached run requests, or real Session updates. If the shutdown frame cannot be sent, force-stop/reap while preserving the same public error code. Version 2 proceeds without entering rejection cleanup.

- [ ] **Step 2: Run tests and verify RED**

Run:

```bash
cd strategy-service
uv sync --python 3.13 --frozen --extra dev
PYTHONPATH=.:../strategy-library uv run --frozen --extra dev pytest tests/test_runtime_worker_proto.py tests/test_worker_agent_client.py -q
go test ./internal/runtimeagent -run 'Protocol|WorkerHello|RejectedWorkerCleanup' -count=1 -v
```

Expected: Python and Go tests fail because the V2 fields/types and gate do not exist.

- [ ] **Step 3: Add V2 messages without reusing V1 tags**

During this task, keep the V1 `indicator_frame=15` field executable and mark it deprecated. Tasks 3–10 and Task 11's pre-cutover phase must continue to compile the V1 field so the source remains a rollback surface. Task 11's post-seal candidate phase removes it and adds `reserved 15`; Task 12 then reruns the identical database, real service-chain, and real-page gates before that candidate can advance.

```protobuf
message WorkerHello {
  string session_id = 1;
  string token = 2;
  string worker_version = 3;
  int64 pid = 4;
  uint32 protocol_version = 5;
}

message IndicatorMarkerV2 {
  string text = 1;
  optional double price = 2;
  string color = 3;
  string position = 4;
  string shape = 5;
}

message IndicatorSampleV2 {
  string indicator_key = 1;
  optional double scalar_value = 2;
  repeated IndicatorMarkerV2 markers = 3;
}

message IndicatorFrameV2 {
  string session_id = 1;
  int64 user_id = 2;
  int64 strategy_id = 3;
  string stream_key = 4;
  uint64 stream_sequence = 5;
  int64 market_time_ms = 6;
  int64 interval_ms = 7;
  repeated IndicatorDefinition definitions = 8;
  repeated IndicatorSampleV2 samples = 9;
}

message FinalStatus {
  string session_id = 1;
  string status = 2;
  int64 bars_processed = 3;
  string error = 4;
  strategy.v1.RuntimeDependencyError dependency_error = 5;
  string reconciliation_run_id = 6;
}
```

Add `IndicatorFrameV2 indicator_frame_v2 = 21` to `WorkerFrame.payload`; 21 is new and does not collide with notification/wallet/final/error/log fields 16–20.
`FinalStatus.reconciliation_run_id=6` is the optional identity of an already
persisted reconciliation run used by the later Spot lifecycle; it must round
trip beside the dependency plan's existing `dependency_error=5` in the Python
and Go descriptor/encoding tests, must not create a Session column, and must
never be synthesized when no run exists.

- [ ] **Step 4: Regenerate all strategy-service stubs from authoritative protos**

Run:

```bash
./generate_proto.sh
```

Expected: worker Go/Python stubs and local portfolio V2 Go/Python stubs change. Inspect `git diff --check`; no generated file is edited manually.

- [ ] **Step 5: Add protocol constant and fail before StartSession**

Use one constant in Go and Python:

```go
const RuntimeWorkerProtocolVersion uint32 = 2
```

```python
WORKER_PROTOCOL_VERSION = 2
```

`build_worker_hello_frame` always sets it. Change `pendingSessionStart.failed` from `chan string` to `chan runtimeStartFailure`:

```go
type runtimeStartFailure struct { Code, Message string }
```

In the Agent hello case, check the version before sending `StartSession`; enqueue:

```go
runtimeStartFailure{
    Code: "RUNTIME_WORKER_PROTOCOL_UNSUPPORTED",
    Message: fmt.Sprintf("runtime worker protocol unsupported: required=%d received=%d", RuntimeWorkerProtocolVersion, got),
}
```

Mark the pending identity rejected before any send so a concurrent frame cannot alias it or receive `StartSession`. Best-effort send `ShutdownWorker{session_id: pendingID, reason: failure.Message}`; whether that send succeeds or fails, `handleRunStrategy` calls the generation-pinned manager stop plus bounded wait/reap path before returning the exact failure in `runtimeErrorFrame`. Remove registry/pending state only after process and stream reap. Cleanup errors remain retained/logged for retry and never replace `RUNTIME_WORKER_PROTOCOL_UNSUPPORTED` at the caller boundary. A rejected hello must never alias a real session, cache a run request, or emit/update `running`.

- [ ] **Step 6: Run focused protocol tests and full generation checks**

Run:

```bash
PYTHONPATH=.:../strategy-library uv run --frozen --extra dev pytest tests/test_runtime_worker_proto.py tests/test_worker_agent_client.py -q
go test ./internal/runtimeagent -run 'Protocol|WorkerHello|RejectedWorkerCleanup' -count=1 -v
git diff --check
```

Expected: PASS.

- [ ] **Step 7: Commit strategy-service protocol files**

```bash
git add proto/runtime_worker.proto gen/runtimeworkerv1/runtime_worker.pb.go gen/runtimeworkerv1/runtime_worker_grpc.pb.go strategy_service/gen/runtime_worker_pb2.py strategy_service/gen/runtime_worker_pb2_grpc.py gen/portfoliov1/portfolio_service.pb.go gen/portfoliov1/portfolio_service_grpc.pb.go strategy_service/gen/portfolio_service_pb2.py strategy_service/gen/portfolio_service_pb2_grpc.py strategy_service/worker_agent_client.py internal/runtimeagent/agent.go internal/runtimeagent/worker_manager.go internal/runtimeagent/worker_manager_test.go internal/runtimeagent/worker_ipc_server_test.go internal/runtimeagent/agent_test.go tests/test_runtime_worker_proto.py tests/test_worker_agent_client.py
git commit -m "feat: define runtime worker indicator v2 protocol"
```

---

### Task 4: Python Per-Bar Sequencing, Empty Failed Frames, and Immutable Definitions

**Files:**
- Modify: `strategy-service/strategy_service/marketdata_adapter.py`
- Modify: `strategy-service/strategy_service/strategy/base.py`
- Modify: `strategy-service/strategy_service/grpc_server.py`
- Modify: `strategy-service/strategy_service/worker_agent_client.py`
- Modify: `strategy-service/strategy_service/indicators.py`
- Modify: `strategy-service/tests/test_strategy_indicators.py`
- Modify: `strategy-service/tests/test_marketdata_adapter.py`
- Modify: `strategy-service/tests/test_grpc_server.py`
- Modify: `strategy-service/tests/test_worker_agent_client.py`

**Interfaces:**
- Consumes: `IndicatorFrameV2`/`IndicatorSampleV2` from Task 3 and the existing `IndicatorDefinition`/`IndicatorWriter` user API.
- Produces: `BaseStrategy.on_indicator_frame(stream_key: str, stream_sequence: int, market_time_ms: int, interval_ms: int, frame: IndicatorFrame)`, exactly one callback per accepted indicator-bearing stream/bar, with first-frame-only definitions at the gRPC sink. `market_time_ms` is the adapted K-line's `open_time`; `MarketData.timestamp` remains its close timestamp and `klines["close_time"]` preserves that fact for callback/order behavior.

- [ ] **Step 1: Write sequencing and sparse-frame tests first**

Create a strategy with two declared streams (`BTCUSDT:1m`, `BTCUSDT:5m`), one line and one marker definition. Feed interleaved bars and collect callbacks:

```python
assert [(f.stream_key, f.sequence) for f in seen] == [
    ("binance:perpetual_futures:BTCUSDT:1m", 0),
    ("binance:perpetual_futures:BTCUSDT:5m", 0),
    ("binance:perpetual_futures:BTCUSDT:1m", 1),
]
assert seen[0].frame.values == {}
assert seen[0].frame.markers == {}
```

Add a user callback that calls `indicators.set("alpha", 99)` and then raises. Assert the emitted frame for sequence 0 contains neither that scalar nor a marker. For a hot-reload strategy, assert the existing guarded error callback still fires and the next successful bar is sequence 1. For a non-hot-reload strategy, assert `StrategyUserCodeError` is raised **after** the empty sequence-0 frame was observed.

Add a reload test that changes only function body and keeps `INDICATORS` byte-equivalent (reload accepted), then changes `INDICATORS["alpha"]["pane"]` (reload rejected, original instance/definitions retained, warning says restart required).

Add the production-shaped time RED in `test_marketdata_adapter.py` and carry it
through the strategy frame test:

```python
kline = MarketKline(
    symbol="BTCUSDT", interval="1m",
    open_time=60_000, close_time=119_999, timestamp=119_999,
    open=100.0, high=102.0, low=99.0, close=101.0, volume=3.0,
)
market_data = _adapt_kline(kline, "spot")
assert market_data.timestamp == 119_999       # existing close-time strategy contract
assert market_data.klines["open_time"] == 60_000
assert market_data.klines["close_time"] == 119_999
engine.running_strategy(market_data)
assert seen[-1].market_time_ms == 60_000       # V2 chart/bar identity
```

The strategy emits a BUY marker and an order decision on that bar. Assert the
V2 frame uses `60_000`, while the existing order/callback-visible timestamp
remains `119_999`; no test fixture may set `timestamp=open_time` to make this
pass.

Add a real gRPC collection-boundary RED. Install an Agent sink that succeeds at
sequence 0 and raises `OSError("transport closed")` at sequence 1. Drive the
real `_install_indicator_collection.on_frame` through `BaseStrategy`, not a
standalone fake callback. Assert the inner sink exception escapes the callback,
`BaseStrategy` raises exactly
`RuntimeError("indicator V2 transport failed: transport closed")`, the order
decision produced on sequence 1 is never sent, the session runner stops before
bar 2, and the agent-managed final status is `failed`. Task 7 repeats this at
the real Agent lifecycle boundary and proves a finalization failure yields
`recoverable` instead.

- [ ] **Step 2: Run focused Python tests and verify RED**

Run:

```bash
cd strategy-service
PYTHONPATH=.:../strategy-library uv run --frozen --extra dev pytest \
  tests/test_marketdata_adapter.py tests/test_strategy_indicators.py \
  tests/test_grpc_server.py tests/test_worker_agent_client.py -q
```

Expected: FAIL because the adapter drops both bar times, the callback has no
sequence, failed callbacks emit no frame, hot reload accepts changed indicators,
and `grpc_server.py` swallows the failing Agent sink.

- [ ] **Step 3: Preserve production open and close times without changing order semantics**

Keep the public `MarketData.timestamp=kline.timestamp` assignment unchanged and
extend only the adapted K-line map:

```python
klines={
    "open_time": kline.open_time,
    "close_time": kline.close_time,
    "timestamp": kline.timestamp,
    "open": kline.open,
    "high": kline.high,
    "low": kline.low,
    "close": kline.close,
    "volume": kline.volume,
}
```

`_market_time_ms` already checks `klines["open_time"]` before any timestamp;
retain that precedence and add an explicit assertion rather than adding another
public time field. This separates chart identity from the close-time callback/
order fact without changing user strategy behavior.

- [ ] **Step 4: Assign sequence in `BaseStrategy`, not in the Agent or chunker**

Add:

```python
self._next_indicator_sequence: dict[str, int] = {}
```

Change the callback type and drain method:

```python
self.on_indicator_frame: Callable[[str, int, int, int, IndicatorFrame], None] | None = None

def _drain_indicator_frame(self, stream_key: str, market_time_ms: int, interval_ms: int) -> None:
    writer = getattr(self._strategy_instance, "indicators", None)
    if writer is None or not self._indicator_definitions:
        return
    frame = writer.drain()
    sequence = self._next_indicator_sequence.get(stream_key, 0)
    self._next_indicator_sequence[stream_key] = sequence + 1
    if self.on_indicator_frame is not None:
        try:
            self.on_indicator_frame(stream_key, sequence, market_time_ms, interval_ms, frame)
        except Exception as exc:
            raise RuntimeError(f"indicator V2 transport failed: {exc}") from exc
```

Do not swallow the sink exception.
The drain happens before signal normalization/order execution, so this failure
must terminate the session path before an order for that bar can be admitted.

- [ ] **Step 5: Emit an empty bar frame after discarding partial failed output**

In `running_strategy`, compute `stream_key`, `market_time_ms`, and `interval_ms` before user code. On user exception:

```python
self._indicator_writer.reset_bar()  # discard values/markers written before the exception
self._drain_indicator_frame(stream_key, market_time_ms, interval_ms)  # emits empty frame and advances once
```

Then apply the existing hot-reload guarded return or fatal `StrategyUserCodeError`. On success call `_drain_indicator_frame` exactly once. There must be no `finally` that can emit a second frame.

- [ ] **Step 6: Make indicator declarations part of the hot-reload identity**

Extend the declaration comparison:

```python
if candidate_indicator_definitions != self._indicator_definitions:
    self._hot_reload_signature = signature
    logger.warning(
        "strategy hot reload skipped: indicator declaration changed; restart session required: "
        "session=%s path=%s",
        self._session_id, source_path,
    )
    return
```

Keep the original strategy instance and writer. A source-code-only change with identical definitions still reloads.

- [ ] **Step 7: Encode typed sparse V2 samples**

Change `send_indicator_frame` to accept the sequence and construct only samples actually produced on that bar:

```python
msg = worker_pb2.IndicatorFrameV2(
    session_id=str(session_id), user_id=int(user_id), strategy_id=int(strategy_id),
    stream_key=str(stream_key), stream_sequence=int(stream_sequence),
    market_time_ms=int(market_time_ms), interval_ms=int(interval_ms),
)
for key, raw_value in sorted((getattr(frame, "values", {}) or {}).items()):
    sample = msg.samples.add(indicator_key=str(key))
    if raw_value is not None:
        sample.scalar_value = float(raw_value)
for key, raw_markers in sorted((getattr(frame, "markers", {}) or {}).items()):
    sample = msg.samples.add(indicator_key=str(key))
    for raw in raw_markers:
        marker = sample.markers.add(
            text=str(raw.get("text", "")), color=str(raw.get("color", "")),
            position=str(raw.get("position", "")), shape=str(raw.get("shape", "")),
        )
        if raw.get("price") is not None:
            marker.price = float(raw["price"])
self._outbound.put(worker_pb2.WorkerFrame(indicator_frame_v2=msg))
```

An empty frame has zero samples but is still queued. Reject a key that appears in both `values` and `markers`, because one definition cannot change kind within a session.

Extend `IndicatorWriter.mark` with optional keyword-only `position` and `shape`, validate against the frontend-supported enums, and keep existing calls source-compatible:

```python
def mark(self, key: str, text: str = "", price: float | None = None, color: str = "", *, position: str = "", shape: str = "") -> None:
```

- [ ] **Step 8: Send definitions on sequence zero only and propagate the Agent sink failure**

Update `_install_indicator_collection.on_frame` signature. For every stream, require `stream_sequence==0` on its first callback and attach definitions then; later callbacks attach `[]`. If the first callback for a stream is nonzero, raise `RuntimeError` instead of marking it sent. Call the Agent sink directly; delete the inner `try/except Exception` and its warning so the error reaches `_drain_indicator_frame`. Add `definition_streams_sent` only after a successful sequence-zero sink submission, so a failed first frame cannot falsely suppress definitions on a retry.

Remove the agent-managed path's unused `portfolio_client` acquisition: when `_indicator_frame_sink` is callable, it must not instantiate the direct portfolio client. Retain the non-agent direct path until Task 11 removes the obsolete Python chunk writer.

- [ ] **Step 9: Run Python focused and full verification**

Run:

```bash
PYTHONPATH=.:../strategy-library uv run --frozen --extra dev pytest \
  tests/test_marketdata_adapter.py tests/test_strategy_indicators.py \
  tests/test_grpc_server.py tests/test_worker_agent_client.py \
  tests/test_session_worker_entry.py -q
PYTHONPATH=.:../strategy-library uv run --frozen --extra dev pytest tests/ -q
```

Expected: PASS; the sparse-frame test observes a V2 frame for every accepted
bar, only sequence-zero frames contain definitions, the production-shaped
frame uses candle open time, and the failing sink terminates before any later
order/frame.

- [ ] **Step 10: Commit Python V2 sequencing**

```bash
git add strategy_service/marketdata_adapter.py strategy_service/strategy/base.py strategy_service/grpc_server.py strategy_service/worker_agent_client.py strategy_service/indicators.py tests/test_marketdata_adapter.py tests/test_strategy_indicators.py tests/test_grpc_server.py tests/test_worker_agent_client.py tests/test_session_worker_entry.py
git commit -m "feat: sequence every runtime indicator bar"
```

---

### Task 5: Go V2 Stream Clock, Deterministic Chunks, and V2 Persistence Sync

**Files:**
- Replace: `strategy-service/internal/runtimeagent/indicator_buffer.go`
- Replace: `strategy-service/internal/runtimeagent/indicator_buffer_test.go`
- Modify: `strategy-service/internal/runtimeagent/indicator_sync.go`
- Modify: `strategy-service/internal/runtimeagent/indicator_sync_test.go`
- Modify: `strategy-service/internal/runtimeagent/agent.go`
- Modify: `strategy-service/internal/runtimeagent/agent_test.go`

**Interfaces:**
- Consumes: `runtimeworkerv1.IndicatorFrameV2`; core V2 save/finalize protobufs; platform methods from Task 2.
- Produces: `ReceiveFrame(WorkerIdentity, *rwv1.IndicatorFrameV2) error`,
  `FlushSession(ctx, WorkerIdentity) error`,
  `FinalizeSession(ctx, WorkerIdentity) error`,
  and typed `*IndicatorProtocolError` with code
  `RUNTIME_INDICATOR_PROTOCOL_ERROR`. This is the dependency plan's immutable
  authenticated identity; no indicator-specific identity is introduced.
  Payload IDs are never routing truth, and every flush/finalize remains pinned
  to the same Session/generation.

- [ ] **Step 1: Write deterministic buffer tests for required bar counts and sparse markers**

Use table cases `{1,1023,1024,1025,2049}` and assert finalization counts:

```go
tests := []struct{ bars int; counts []uint32 }{
    {1, []uint32{1}}, {1023, []uint32{1023}}, {1024, []uint32{1024}},
    {1025, []uint32{1024, 1}}, {2049, []uint32{1024, 1024, 1}},
}
```

For ten frames, emit markers only on sequences 4 and 9, with two markers at sequence 9. Assert every series has `Count=10`, times preserve a deliberate gap, scalar slots contain ten entries including nulls, and markers have `(sequence,offset,time)=(4,4,t4),(9,9,t9),(9,9,t9)`.

Add the explicit `1023 -> two frames` test: after the first flush at 1023, accept sequence 1023 and 1024; assert persistence result is chunk 0 count 1024 finalized and chunk 1 count 1 open.

Block the first 1023-save response, append those two frames while it is in
flight, then release the old ACK. Prove the revision-pinned ACK cannot clear the
advanced chunk: the next flush durably produces finalized chunk 0 at revision/
count 1024 plus open chunk 1 count 1. Repeat with terminal finalization racing
the old periodic ACK.

- [ ] **Step 2: Write stream-clock protocol tests**

Test all cases with exact expected disposition:

```go
accept seq=0,time=1000,scalar=1,definitions=A
ignore immediate duplicate seq=0,time=1000 only when interval/definitions/samples are byte-equivalent; do not apply it
reject immediate duplicate seq=0,time=1000,scalar=2
reject immediate duplicate seq=0,time=1000 with a marker added/removed
reject immediate duplicate seq=0,time=1001
reject gap seq=2,time=3000
accept seq=1,time=9000 // time gap is valid
reject older lower seq=0,time=1000 after seq=1
reject seq=1,time=999 // accepted time must strictly increase
reject seq=1,time=1000 // equal time at a new sequence is not a duplicate
reject seq=1,time=2000,interval=300000 after stream interval=60000
```

Interleave three stream keys—including `binance:spot:BTCUSDT:1m`, `binance:perpetual_futures:BTCUSDT:1m`, and a different symbol/interval—and assert each clock begins at zero and advances independently. Send changed definitions on sequence 1 and an unknown sample key; both must return typed protocol errors. Chunking is market-agnostic and must not special-case futures.

- [ ] **Step 3: Run Go indicator tests and verify RED**

Run:

```bash
cd strategy-service
go test ./internal/runtimeagent -run 'IndicatorBufferV2|IndicatorSyncV2|IndicatorProtocol' -count=1 -v
```

Expected: FAIL because V1 buffers infer offsets from received values and have no sequence clock, times, revisions, or typed markers.

- [ ] **Step 4: Replace the buffer with sequence-derived V2 structures**

Use these exact internal shapes:

```go
const indicatorChunkSize uint64 = 1024

type IndicatorMarkerV2 struct {
    Sequence uint64
    Offset   uint32
    TimeMS   int64
    Text     string
    Price    *float64
    Color    string
    Position string
    Shape    string
}

type IndicatorChunkV2 struct {
    ChunkIndex                 uint32
    StartSequence, EndSequence uint64
    StartTimeMS, EndTimeMS     int64
    IntervalMS                 int64
    TimesMS                    []int64
    ScalarValues               []*float64
    Markers                    []IndicatorMarkerV2
    Revision                   uint64
    Finalized                  bool
}

type indicatorStreamClock struct {
    NextSequence uint64
    LastTimeMS   int64
    IntervalMS   int64
    HasLast      bool
    LastPayloadHash [32]byte
}
```

Before classification, build a deterministic payload containing exactly
`interval_ms`, ordered definitions, and ordered samples (including optional
field presence and marker order), marshal it with
`proto.MarshalOptions{Deterministic:true}`, and take SHA-256. Do not include
session/user/strategy routing IDs, sequence, or market time in this payload;
those are authenticated/compared independently. Keep only the last accepted
32-byte hash per stream, so memory remains bounded regardless of Session length.

`indicatorStreamClock.Classify(sequence,time,payloadHash)` is bounded and does
not mutate state. `Commit(sequence,time,payloadHash)` advances only after a new
expected frame's definitions/samples have validated:

```go
switch {
case c.HasLast && c.NextSequence > 0 && sequence == c.NextSequence-1 && time == c.LastTimeMS && payloadHash == c.LastPayloadHash:
    return IndicatorFrameDuplicate, nil
case c.HasLast && c.NextSequence > 0 && sequence == c.NextSequence-1 && time == c.LastTimeMS:
    return IndicatorFrameRejected, protocolError("conflicting duplicate payload", sequence)
case sequence < c.NextSequence:
    return IndicatorFrameRejected, protocolError("duplicate time mismatch or lower sequence", sequence)
case sequence > c.NextSequence:
    return IndicatorFrameRejected, protocolError("sequence gap", sequence)
default:
    return IndicatorFrameExpected, nil
}
```

`Classify` also requires positive time/interval, one immutable interval per
stream, and `time > LastTimeMS` for every new expected sequence; time gaps remain
valid. `Commit` requires `sequence==NextSequence`, then increments
`NextSequence` and stores `LastTimeMS`/the first interval/last payload hash. Calling it for a
duplicate or rejected frame is a test failure.

For every accepted frame, append its time to every definition's chunk. Append a cloned scalar pointer or nil for line/histogram; marker series keep an empty scalar slice and append only typed markers. Set `Revision=uint64(len(TimesMS))`, `StartSequence=uint64(chunkIndex)*1024`, and derive marker offset from sequence. Do not derive time or offset from how many samples arrived.

- [ ] **Step 5: Implement immutable definition registration and frame-wide advancement**

`indicatorSessionState` owns `streams map[string]*indicatorStreamState`; each
stream owns the clock, deterministic serialized first definitions, and series.
Before lookup/mutation, compare the trusted `WorkerIdentity` with the payload
and cached Run facts: canonical Session ID, authenticated PID/token/generation,
and the Run fact's Runtime must agree. A stale generation claiming a replacement Session,
another live Session on the same Runtime, or a cross-Session platform/order/
wallet/final frame is rejected before admission and cannot create a buffer.
Task 7 passes the same `WorkerIdentity` through the real Agent handlers and
repeats these cases without reconstructing it or introducing an alias.

After trusted identity validation, compute the canonical payload hash before
classification. An immediate same-sequence/time/hash retry returns without
applying definitions or samples; an immediate same-sequence/time frame with a
different hash, a lower/gap/different-time duplicate, or an interval mismatch
fails closed. For an expected new frame, sequence zero requires a non-empty
definition list. Later omitted definitions reuse the first list; later present
definitions must satisfy `proto.Equal` element-for-element. Reject duplicate
definition keys and duplicate sample keys; one marker sample may still contain
multiple markers. Samples are indexed once and validated against registered
keys/types, then the clock commits and buffers advance atomically, so a rejected
frame has no partial effect.

The conflicting-duplicate tests must assert no clock/buffer mutation, immediate
closure of that generation's frame and order admission, exactly one
`RUNTIME_INDICATOR_PROTOCOL_ERROR`, last-contiguous-tail finalization, and a
recoverable Session. They are distinct from an exact Agent-to-core open-chunk
retry, which remains idempotent without changing revision or `updated_at`.

Return:

```go
type IndicatorProtocolError struct {
    SessionID, StreamKey string
    Sequence             uint64
    Reason               string
}
func (*IndicatorProtocolError) Code() string { return "RUNTIME_INDICATOR_PROTOCOL_ERROR" }
```

- [ ] **Step 6: Split V2 persistence into save then explicit finalize**

Snapshot under the session/series locks, release those locks, then call
`portfolio.SaveStrategyIndicatorsV2`. Every snapshot emits an immutable token
containing session/generation, stream/key/chunk, revision, count, and canonical
payload hash. The request contains only dirty definitions and open/current
revisions with `Finalized=false`. For every chunk whose full boundary or
terminal seal is pending, call `portfolio.FinalizeStrategyIndicatorChunksV2`
after save acknowledgement:

```go
&portfoliov1.StrategyIndicatorChunkFinalizationV2{
    StreamKey: series.streamKey, IndicatorKey: series.indicatorKey,
    ChunkIndex: chunk.ChunkIndex, ExpectedRevision: chunk.Revision,
}
```

`MarkSaveAcked(token)` may clear dirty state only when current generation,
revision, count, and payload hash still equal that token. If frames advanced
during I/O, record at most the acknowledged prior revision and keep the current
chunk dirty. Only drop/forget a sealed chunk after its matching finalize token
succeeds. An identical retry sends the same revision and finalization guard.
Keep `state.flushMu` as the sole per-session flush owner. Periodic flush calls
`FlushSession`; a full boundary sets an in-memory latched per-session
`flushPending` flag
before a coalesced wakeup. If the wakeup channel is full, the owner still loops
until the flag is observed/cleared, so a boundary cannot degrade silently to the
next periodic tick. Terminal calls `FinalizeSession`, seals every contiguous
open chunk once, and retries save/finalize with bounded exponential backoff.

Add persistence-call tests: after a successful 1023 ACK and no new frame, the
next periodic flush makes zero calls; when the database committed but the
response was lost, retry sends the byte-identical token/revision and core
returns idempotent success without changing `updated_at`.

- [ ] **Step 7: Make protocol failure close frame admission immediately**

When `Agent.HandleWorkerFrame` receives `*IndicatorProtocolError`, atomically
close that generation's admission before returning. Do not synchronously drive
terminal work while the current handler still owns an admission lease: claim/
queue the protocol terminal request, release the lease exactly once, then send
`ShutdownWorker{reason: err.Error()}` and let the lifecycle coordinator drive
it. Tests prohibit defer double-release and prove the real Agent handler cannot
wait on itself. Stop accepting indicator/platform/order frames from that
generation. Task 7 supplies the coordinator implementation.

- [ ] **Step 8: Run focused V2 matrix and race-oriented serialization tests**

Run:

```bash
go test ./internal/runtimeagent -run 'IndicatorBufferV2|IndicatorSyncV2|IndicatorProtocol' -count=1 -v
go test -race ./internal/runtimeagent -run 'IndicatorSyncV2.*Concurrent|IndicatorSyncV2.*Flush' -count=1
PYTHONPATH=.:../strategy-library uv run --frozen --extra dev pytest tests/test_runtime_worker_proto.py -q
```

Expected: PASS. The race test records maximum concurrent platform writes per
session as exactly 1. The descriptor test still observes deprecated executable
V1 field 15 alongside V2 field 21; reservation/removal is intentionally deferred
to Task 11's sealed cutover phase.

- [ ] **Step 9: Commit additive Go V2 chunking without removing V1**

```bash
git add internal/runtimeagent/indicator_buffer.go internal/runtimeagent/indicator_buffer_test.go internal/runtimeagent/indicator_sync.go internal/runtimeagent/indicator_sync_test.go internal/runtimeagent/agent.go internal/runtimeagent/agent_test.go
git commit -m "feat: persist sequence-aligned indicator chunks"
```

---

### Task 6: Gateway V2 Field Preservation

**Files:**
- Modify: `gateway/quant-handler/internal/app/session_indicators.go`
- Modify: `gateway/quant-handler/internal/app/session_indicators_test.go`
- Modify: `gateway/quant-handler/internal/app/session_history.go`
- Modify: `gateway/quant-handler/internal/app/session_history_test.go`

**Interfaces:**
- Consumes: core V2 list RPCs from Task 1.
- Produces: existing HTTP routes `/api/sessions/{id}/indicators` and `/api/sessions/{id}/indicators/chunks` with V2 JSON fields preserved without an opaque `values_json` field, plus `indicator_finalization_pending` on every Session JSON shape produced by `protoSessionToJSON`.

- [ ] **Step 1: Write field-for-field HTTP response tests**

Return one V2 chunk with irregular times, one null scalar, one marker, revision 2, `finalized=false`, and protocol version 2. Decode JSON into a typed struct and assert every field:

```go
if !reflect.DeepEqual(item.TimesMS, []int64{1_000, 9_000}) { t.Fatalf(...) }
if item.ScalarValues[0] == nil || item.ScalarValues[1] != nil { t.Fatalf(...) }
if item.Markers[0].Sequence != 1 || item.Markers[0].TimeMS != 9_000 { t.Fatalf(...) }
if item.Revision != 2 || item.Finalized || item.ProtocolVersion != 2 { t.Fatalf(...) }
```

Also assert the BFF forwards the authenticated user, time range, stream key, and indicator keys to `ListStrategyIndicatorChunksV2`. In `session_history_test.go`, cover Get/List Session mappings with `IndicatorFinalizationPending=true` and false, and require the exact JSON key `indicator_finalization_pending`; it is not inferred from status or chunk contents.

- [ ] **Step 2: Run focused tests and verify RED**

Run:

```bash
cd gateway/quant-handler
go test ./internal/app -run 'StrategyIndicator.*V2' -count=1 -v
```

Expected: FAIL because the BFF still calls V1 RPCs and drops `finalized` even in its old JSON shape.

- [ ] **Step 3: Replace BFF DTOs and RPC calls with V2**

Use explicit DTOs:

```go
type nullableFloat64JSON struct { Value *float64 `json:"value"` }
type strategyIndicatorMarkerV2JSON struct {
    Sequence uint64 `json:"sequence"`; Offset uint32 `json:"offset"`; TimeMS int64 `json:"time_ms"`
    Text string `json:"text"`; Price *float64 `json:"price,omitempty"`; Color string `json:"color"`
    Position string `json:"position"`; Shape string `json:"shape"`
}
type strategyIndicatorChunkV2JSON struct {
    SessionID string `json:"session_id"`; StreamKey string `json:"stream_key"`; IndicatorKey string `json:"indicator_key"`
    ChunkIndex uint32 `json:"chunk_index"`; StartSequence uint64 `json:"start_sequence"`; EndSequence uint64 `json:"end_sequence"`
    StartTimeMS int64 `json:"start_time_ms"`; EndTimeMS int64 `json:"end_time_ms"`; IntervalMS int64 `json:"interval_ms"`
    Count uint32 `json:"count"`; TimesMS []int64 `json:"times_ms"`; ScalarValues []*float64 `json:"scalar_values"`
    Markers []strategyIndicatorMarkerV2JSON `json:"markers"`; Revision uint64 `json:"revision"`
    Finalized bool `json:"finalized"`; ProtocolVersion uint32 `json:"protocol_version"`
}
```

Map optional proto values/prices by checking presence, not `GetValue()!=0`, so real zero values survive. Include `protocol_version` on the definition DTO as well as the chunk DTO and delete `values_json` from the HTTP response. Add `IndicatorFinalizationPending bool \`json:"indicator_finalization_pending"\`` to `sessionJSON` and map it directly from the core Session entry for Get/List responses.

- [ ] **Step 4: Run handler focused/full tests and vet**

Run:

```bash
go test ./internal/app -run 'StrategyIndicator.*V2|Session.*FinalizationPending' -count=1 -v
go test ./... -count=1
go vet ./...
```

Expected: PASS.

- [ ] **Step 5: Commit only quant-handler files**

```bash
git add internal/app/session_indicators.go internal/app/session_indicators_test.go internal/app/session_history.go internal/app/session_history_test.go
git commit -m "feat: expose indicator v2 data to the portal"
```

---

### Task 7: Generation-Aware Worker Exit and One Terminal Coordinator

**Files:**
- Create: `strategy-service/internal/runtimeagent/session_lifecycle.go`
- Create: `strategy-service/internal/runtimeagent/session_lifecycle_test.go`
- Create: `strategy-service/internal/runtimeagent/terminal_retry_store.go`
- Create: `strategy-service/internal/runtimeagent/terminal_retry_store_test.go`
- Modify: `strategy-service/internal/runtimeagent/worker_server.go`
- Modify: `strategy-service/internal/runtimeagent/worker_server_test.go`
- Modify: `strategy-service/internal/runtimeagent/worker_ipc_server.go`
- Modify: `strategy-service/internal/runtimeagent/worker_ipc_server_test.go`
- Modify: `strategy-service/internal/runtimeagent/worker_manager.go`
- Modify: `strategy-service/internal/runtimeagent/worker_manager_test.go`
- Modify: `strategy-service/internal/runtimeagent/agent.go`
- Modify: `strategy-service/internal/runtimeagent/agent_test.go`
- Modify: `strategy-service/cmd/runtime-agent/main.go`
- Modify: `strategy-service/cmd/runtime-agent/main_test.go`
- Modify: `strategy-service/strategy_service/grpc_server.py`
- Modify: `strategy-service/tests/test_grpc_server.py`
- Modify: `strategy-service/tests/test_session_worker_entry.py`

**Interfaces:**
- The dependency plan's `WorkerIdentity{SessionID, PID, Token, Generation}` is
  the sole worker identity. `WorkerManager` allocates generation monotonically;
  process exit and stream close carry that exact captured value. A Run has no
  second random real-session alias; one-shot Validate/Preview identities remain
  private and never become durable Sessions.
- `WorkerManager.SetExitHandler(func(WorkerExitEvent))` reports process completion but never publishes session state itself.
- `WorkerIPCServer.SetStreamClosedHandler(func(WorkerStreamClosedEvent))` reports closure after its receive loop stops and all previously received frames have returned from `WorkerFrameHandler`.
- Preserve `WorkerDrainer` and
  `WorkerManager.MarkSessionWorkerDraining(sessionID string)` source-compatibly.
  For an authenticated FinalStatus, lifecycle calls it after closing admission
  and before indicator/platform persistence, preserving bounded ACK-driven
  natural-exit grace plus the existing signal/force/reap fallback.
- Every generation-pinned mutating frame obtains a
  `SessionRegistry.BeginFrameAdmission` lease. Ordinary paths defer release;
  any path that triggers terminal work must claim/queue it, release exactly
  once, and only then drive termination—never wait on its own lease.
  `CloseFrameAdmission` rejects later frames and `WaitFrameDrain` proves all
  already-admitted handlers returned before finalization.
- `SessionLifecycle.ClaimTerminal(TerminalRequest)` plus
  `DriveTerminal(ctx, claim)` is the only Agent path allowed to finalize
  indicators, publish terminal/recoverable state, acknowledge final status, or
  forget session memory. `Terminate` is only a wrapper for callers that prove
  they hold no admission lease.
- `SessionLifecycle.RunRetryLoop(ctx, interval)` retries retained failed finalization/status work for generation-pinned terminal records; it never changes a previously published `recoverable` state back to the original desired terminal state.
- `TerminalRetryStore` atomically checkpoints the exact retry payload and
  acknowledged steps beneath persistent `StateRoot`; startup loads it before
  admitting Runs and replay begins only after RuntimeChannel authentication.

- [ ] **Step 1: Write generation/alias tests before changing the registry**

Extend the expected and active identities to include generation and verify these cases:

```go
first, _ := manager.PrepareSessionWorker("pending-a")
second, _ := manager.PrepareSessionWorker("pending-b")
if first.Generation == 0 || second.Generation <= first.Generation { t.Fatalf("non-monotonic generations") }

firstIdentity := WorkerIdentity{
    SessionID: first.SessionID, PID: 101,
    Token: first.Token, Generation: first.Generation,
}
registry.AdmitWorker(firstIdentity)
stale := firstIdentity
stale.Generation--
registry.ForgetWorkerIdentity(stale)
if _, ok := registry.ActiveWorker(first.SessionID); !ok { t.Fatal("stale generation removed active worker") }
```

Start a replacement with a new canonical Session ID after generation 1 is
reaped. Deliver generation-1 registration, forget, and close events after
generation 2 is active; assert they neither remove generation 2 nor route a
frame to it. Reject duplicate/live canonical IDs and do not create an alias
from a pending ID to a second Python-generated ID.

Against the real frame handler, let generation 1 forge generation 2's Session
ID, another Session on the same Runtime, and cross-Session indicator/platform/
order/wallet/final payloads. Require connection identity plus cached Run facts
to reject each before mutation or terminal claim.

- [ ] **Step 2: Write process-exit and stream-close event tests**

Use a short Python module that exits 17 and assert exactly one event:

```go
type WorkerExitEvent struct {
    Identity      WorkerIdentity
    ExitErr       error
    StopRequested bool
}
```

The event fires after `Cmd.Wait`, before registry identity is forgotten, and
includes the canonical Session ID for Run (or the private one-shot call identity
when no durable Session exists). A requested graceful/forced stop sets
`StopRequested=true`; a spontaneous exit sets it false. Cleanup failure remains
reported through `ExitErr` and retained manager state.

For IPC, force EOF and handler failure and assert exactly one:

```go
type WorkerStreamClosedEvent struct {
    Identity WorkerIdentity
    Err      error
}
```

The callback must run after the outbound aliases are removed. A stale close cannot close or delete a newer generation's outbound channel.

- [ ] **Step 3: Run lifecycle identity tests and verify RED**

```bash
cd strategy-service
go test ./internal/runtimeagent -run 'Generation|WorkerExitEvent|WorkerStreamClosedEvent|StaleAlias' -count=1 -v
```

Expected: FAIL because identities have no generation and process/stream exit callbacks do not exist.

- [ ] **Step 4: Add generation to manager, registry, IPC identity, and aliases**

Add `nextGeneration atomic.Uint64` to `WorkerManager`; `PrepareSessionWorker`
allocates once and copies the value into the dependency plan's
`WorkerIdentity`, `WorkerStartSpec`, and `ManagedWorker`. Replace the registry's
token-only expected map with that identity. Every admit, lookup, forget, send,
and callback accepts or compares the full captured identity; do not recreate an
identity from individual fields and do not add a Run alias.

Change the frame handler boundary to:

```go
type WorkerFrameHandler func(
    context.Context, WorkerIdentity, *rwv1.WorkerFrame,
    func(*rwv1.AgentFrame) error,
) error
```

`Connect` obtains the admitted identity from `SessionRegistry` and captures it
for the lifetime of the stream. For Run, that identity already contains the
canonical durable Session ID and is never rebound; only explicitly one-shot
non-Session calls may use a private internal alias. Sending by session resolves
the current canonical identity and refuses a stale-generation channel.

In `watchStartedWorker`, emit `WorkerExitEvent` after `Cmd.Wait`; registry cleanup uses the event generation. Wire manager and IPC callbacks to Agent in `cmd/runtime-agent/main.go` before starting the RuntimeChannel.

- [ ] **Step 5: Write a terminal matrix with ordered, failure-sensitive assertions**

In `session_lifecycle_test.go`, table-test these sources and desired terminal states:

| Source | Worker status/input | Durable state after successful indicator finalization |
|---|---|---|
| natural completion | `finished` | `finished` |
| legacy natural completion | `completed` | `finished` (normalize before lifecycle claim) |
| user-code error | `failed` | `failed` |
| indicator transport/enqueue failure | `failed`, reason begins `indicator V2 transport failed:` | `failed` |
| user stop | `stopped` | `stopped` |
| stop failure | `stop_failed` | `stop_failed` |
| worker explicitly requests recovery | `recoverable` | `recoverable` |
| max-loss close succeeds | `stopped`, reason contains `max_loss_close_triggered` | `stopped` |
| max-loss close fails | `stop_failed`, reason contains `max_loss_close_triggered` | `stop_failed` |
| worker protocol violation | protocol error | `recoverable` |
| running worker exits without final status | process + stream close | `recoverable` |
| Bare local restart | restart request | old session `recoverable` |
| Agent SIGTERM/shutdown | Agent shutdown request | active session `recoverable` after tail finalization |

The authenticated worker-final accepted set is exactly
`finished|completed|failed|stopped|stop_failed|recoverable`; normalize
`completed -> finished` before constructing `TerminalRequest` and preserve the
original worker fact in diagnostics. `preflight_failed` is deliberately outside
this matrix: dependency/import preflight completes before user-bar admission,
so there is no indicator tail to finalize and the dependency plan owns its
pending-to-failed cleanup.

For every non-worker-final row assert the call order begins
`close-admission, finalize, update-session`; an authenticated worker-final path is exactly
`close-admission, mark-worker-draining, finalize, update-session, send-ack,
mark-acknowledged, reap, forget`. `failed`, `stopped`, and `stop_failed` must not
bypass finalization. Preserve and extend the existing regressions
`TestAgentFinalStatusMarksWorkerDrainingBeforePlatformUpdate`,
`TestAgentFinalStatusDrainingLetsConcurrentStopAllWaitForAckExit`,
`TestDrainingWorkerTimeoutFallsBackToSignalAndForce`, and
`TestDrainingWorkerProductionDeadlineReservesForceReapAndCleanup`.

Add a deliberately blocked admitted-frame case. After terminal work closes admission, a later frame is rejected, and before the blocked handler releases there is no `FinalizeSession`, terminal `UpdateSession`, success acknowledgement, or forget. After release, assert the exact tail finalizes before the terminal update. Add a drain-timeout variant: before the injected timeout fires there is no durable call; when it fires, record stable `WORKER_FRAME_DRAIN_TIMEOUT`, retain lifecycle/indicator/registry state, perform no finalization while mutation remains possible, and persist Session status `recoverable` with `indicator_finalization_pending=true` and the original desired status/reason embedded in the safe failure reason. There is no success acknowledgement or forget. A retry after release drains and finalizes the exact retained tail, keeps the already-published status `recoverable`, then performs a metadata-only `UpdateSession(recoverable, indicator_finalization_pending=false)` before cleanup; it must not perform a second terminal status transition. If that flag-clear write fails, retain the lifecycle record and retry only the clear. If the timeout's initial recoverable update itself fails, retry that update independently without ever finalizing before drain.

Add a real Agent protocol-error case where the failing handler owns the lease:
it must claim/queue, release, and only then drive; prove no self-deadlock or
double release. Add a restart race where process-exit and stream-close callbacks
both arrive before the restart goroutine resumes: they must attach reap facts to
the already claimed Bare-restart record and never create unexpected-exit.

Repeat every row with indicator finalization failure. Assert one `UpdateSession(recoverable, indicator_finalization_pending=true)` attempt with the original status/reason embedded in the error, an `AgentError{Code:"INDICATOR_FINALIZATION_FAILED"}` instead of an empty success acknowledgement when a worker is waiting, and no buffer forget. Repeat a normal row with `UpdateSession` failure and assert `SESSION_TERMINAL_PERSIST_FAILED`, no success acknowledgement, and a durably journaled record plus live cache.

For the explicit worker-final `recoverable` row, run both finalization-success
and finalization-failure/retry cases. Success persists
`recoverable,pending=false` before acknowledgement. Failure persists
`recoverable,pending=true`, sends the stable failure rather than success, and a
later retry finalizes the exact retained tail then performs only the metadata
clear to `recoverable,pending=false`; it never promotes to another status. For
legacy `completed`, both the successful path and every retry persist only
`finished`, never the legacy spelling.

Drive the Task 4 failing gRPC sink through the real worker-final path. Once the
sequence-N enqueue throws, assert no sequence `N+1` frame or order platform
call is admitted. With successful tail finalization the row becomes `failed`;
with an injected finalization failure it becomes
`recoverable,indicator_finalization_pending=true` and follows the same retained
retry contract.

For each retained-failure case, make the next persistence attempt succeed and drive one retry-loop tick. When finalization originally failed, assert the retry seals the exact retained revision, keeps the already-published Session status `recoverable`, durably clears `indicator_finalization_pending`, and forgets memory only after process/stream reap and the clear is acknowledged. When terminal-status persistence originally failed, assert the retry performs only the still-pending operation(s), publishes the correct desired status/pending fact when no prior status was durable, and then cleans up. Repeated retry ticks after success must make zero platform calls.

- [ ] **Step 6: Run terminal tests and verify RED**

```bash
go test ./internal/runtimeagent -run 'SessionLifecycle|TerminalMatrix|IndicatorFinalizeFailure|TerminalPersistFailure' -count=1 -v
```

Expected: FAIL because the current final-status handler only converts `finished` finalization failure to recoverable, restart forgets before finalization, and unexpected exits have no Agent terminal path.

- [ ] **Step 7: Implement a single serialized lifecycle state machine**

Use one state per `(session_id,generation)`:

```go
type TerminalSource string
const (
    TerminalWorkerFinal TerminalSource = "worker_final"
    TerminalUnexpectedExit TerminalSource = "unexpected_exit"
    TerminalProtocolFailure TerminalSource = "protocol_failure"
    TerminalBareRestart TerminalSource = "bare_restart"
    TerminalAgentShutdown TerminalSource = "agent_shutdown"
)

type TerminalRequest struct {
    Identity            WorkerIdentity
    FrameID             string
    DesiredStatus       string
    Reason              string
    ReconciliationRunID string
    BarsProcessed       uint64
    Source              TerminalSource
    Send                func(*rwv1.AgentFrame) error
}
```

`ClaimTerminal` atomically creates/returns one lifecycle record, marks expected
termination intent for protocol/restart/shutdown before sending any stop, and
closes frame admission. A conflicting source cannot overwrite it.
`DriveTerminal` locks only the lifecycle record and waits on `WaitFrameDrain`;
its caller must hold no admission lease. Data/platform/order/indicator handlers
release exactly once before driving. Network calls run without Agent/indicator/
registry locks. After a proven drain, it calls
`IndicatorSyncManager.FinalizeSession` once through that session's flush owner,
then `UpdateSession`. A drain timeout records `WORKER_FRAME_DRAIN_TIMEOUT`,
retains all state, skips finalization, and attempts
`UpdateSession(recoverable, indicator_finalization_pending=true)`
immediately so a dead worker cannot leave a Session falsely running; that
status says finalization is pending and embeds the original desired fact. It
sends a stable error when applicable and never sends success or forgets state.
The retry loop may retry a failed recoverable write before drain, but finalizes
only after drain. Once the retained tail later finalizes, an already durable
recoverable status is never promoted; it performs a metadata-only
`UpdateSession(recoverable, indicator_finalization_pending=false)` and requires
that write to succeed before forgetting memory. Ordinary successful
finalization/terminal publication explicitly writes pending=false. On
persistence error, lifecycle/buffers remain retryable. On ordinary success,
worker-final sends empty acknowledgement;
cleanup forgets only after process and stream reap. Equivalent claims reuse the
stored result.

Each lifecycle record stores which durable steps are acknowledged
(`frameDrained`, `indicatorFinalized`, `sessionStatusPersisted`,
`finalizationPendingCleared`), whether a drain timeout forced recoverable
status, the effective durable status, process/stream reap facts, and the exact
payload hashes/guards needed for replay. Before returning a retryable error or
dropping live state, write a schema-versioned journal with mode `0600` by
same-directory temporary file, file sync, atomic replace/rename, and directory
sync; provide/test the Windows implementation. Never serialize the worker
token. A truncated, corrupt, unknown-version, hash-mismatched, or conflicting
journal fails startup closed instead of silently admitting Runs.

`RunRetryLoop` starts only after RuntimeChannel authentication, with an
independent lifecycle context and a two-second tick. A tick claims one failed
record, reruns only safe unacknowledged steps, and releases the claim before
moving on. It may persist a pending `recoverable` status without frame drain,
but the per-session flush owner may finalize only after `frameDrained=true`. If
the first pass already persisted `recoverable` because drain or indicator
finalization failed, later success does not promote the Session to the original
`finished`/`failed`/`stopped`; it makes the exact tail durable, clears the
pending fact while leaving status recoverable, and only then permits cleanup
and journal deletion. If no fallback status was required and no status was
persisted, retry persists the original desired status with pending=false after
finalization succeeds. Cancellation is permitted only after completion or a
successful durable checkpoint. Tests use an injected tick channel and never
sleep.

Add a process-reconstruction test: fail save/finalize/update, destroy the Agent,
recreate it with the same `StateRoot`, authenticate RuntimeChannel, and replay
the byte-identical revision/hash without duplicate application. Add corrupt and
truncated-journal tests that fail closed.

Agent owns all terminal updates. Preserve the existing Python guard that skips `_persist_session_status` for agent-managed terminal sessions; add tests for the exact six worker spellings `finished`, `completed`, `failed`, `stopped`, `stop_failed`, and `recoverable`, including the `completed -> finished` normalization, so Python cannot race the Agent's update.

- [ ] **Step 8: Coordinate unexpected exit without dropping already received frames**

Agent records process-exit and stream-close independently. If the generation
already has expected-termination intent (Bare restart, protocol failure, or
Agent shutdown), callbacks only add reap facts to that record and never claim
unexpected-exit. Otherwise, for a generation that reached a real running
session but sent no acknowledged final status, claim `TerminalUnexpectedExit`
only after both events; use recoverable and preserve errors. For a worker that
exits before external running, follow the dependency plan's canonical-Session
cleanup: fail pending Run and idempotently mark any persisted pending/running
row failed through RuntimeChannel; NotFound is allowed only before persistence.

A stream-close event following an acknowledged final status is cleanup evidence, not a second terminal request. A generation-1 event received after generation 2 starts is logged and ignored. A bounded missing-counterpart timeout may close transport and initiate `TerminalUnexpectedExit`; the coordinator closes generation admission and must prove `WaitFrameDrain` before finalizing. If drain also times out, it records `WORKER_FRAME_DRAIN_TIMEOUT`, publishes/retains `recoverable` as the truthful external status, and remains retryable; it never finalizes a buffer that an admitted handler can still mutate.

- [ ] **Step 9: Rewrite Bare restart as finalize/recover/reap/new-run**

`RestartSession` must execute this exact order:

1. Resolve and generation-pin the old session; atomically claim
   `TerminalBareRestart`/expected-termination intent and reject a second restart.
2. With admission already closed by the claim, ask the worker to stop;
   force-stop only after the existing timeout.
3. Wait for process exit and IPC stream close so all previously accepted indicator frames are handled.
4. Drive the already claimed record; callbacks only supplied reap facts. It
   finalizes the tail and persists old session `recoverable` with reason
   `bare debug worker restarted locally`.
5. Forget old Agent/indicator/registry aliases only after successful persistence and process reap.
6. Call `RunStrategy` with the cached request. Return only after the new session reports `running`; that worker receives the materialized strategy from the existing supported path `.hushine-runtime/strategies/user-<user_id>/strategy-<strategy_id>-<name-slug>-<version-slug>.py` produced by `strategy_service.debug_strategy_sources`. This task does not introduce or migrate a strategy path.

If steps 2–5 fail, do not start a replacement. If new `RunStrategy` fails, leave the old session recoverable and return the new-run error. Assert that a late old frame cannot enter the new session and that the response contains distinct old/new session IDs.

Add `Agent.Shutdown(ctx)` as the sole shutdown owner: while RuntimeChannel and
platform persistence remain available, atomically claim
`TerminalAgentShutdown` for every active generation, close admission, stop and
`Cmd.Wait`/stream-reap each worker, drive exact-tail finalization, and persist
recoverable. Main calls it exactly once. Only after every operation completed or
its exact retry journal is atomically durable may `Shutdown` return; if both
completion and checkpoint fail, it does not return permission to cancel the
channel or exit. Main then stops IPC, cancels RuntimeChannel, and exits; it never
calls `StopAll` independently. Add an executable ordering test:
`signal -> Agent.Shutdown once -> terminal persistence/checkpoint -> Shutdown
returns -> IPC stop -> RuntimeChannel cancel`. SIGTERM tests cover normal and
blocked workers plus finalization/status/checkpoint failure; no disappeared
worker leaves a durable running Session.

- [ ] **Step 10: Run lifecycle, race, Python ownership, and full strategy-service tests**

```bash
go test ./internal/runtimeagent -run 'SessionLifecycle|Terminal|RetryPending|UnexpectedExit|RestartSession|Generation' -count=1 -v
go test -race ./internal/runtimeagent -run 'SessionLifecycle|RetryPending|UnexpectedExit|RestartSession' -count=1
go test ./cmd/runtime-agent -count=1
PYTHONPATH=.:../strategy-library uv run --frozen --extra dev pytest \
  tests/test_grpc_server.py tests/test_session_worker_entry.py -q
go test ./... -count=1
PYTHONPATH=.:../strategy-library uv run --frozen --extra dev pytest tests/ -q
```

Expected: PASS; race detector reports no stale-generation alias or double terminal publication.

- [ ] **Step 11: Commit lifecycle coordination in strategy-service**

```bash
git add internal/runtimeagent/session_lifecycle.go internal/runtimeagent/session_lifecycle_test.go internal/runtimeagent/terminal_retry_store.go internal/runtimeagent/terminal_retry_store_test.go internal/runtimeagent/worker_server.go internal/runtimeagent/worker_server_test.go internal/runtimeagent/worker_ipc_server.go internal/runtimeagent/worker_ipc_server_test.go internal/runtimeagent/worker_manager.go internal/runtimeagent/worker_manager_test.go internal/runtimeagent/agent.go internal/runtimeagent/agent_test.go cmd/runtime-agent/main.go cmd/runtime-agent/main_test.go strategy_service/grpc_server.py tests/test_grpc_server.py tests/test_session_worker_entry.py
git commit -m "fix: finalize indicators across worker lifecycle"
```

---

### Task 8: Prove Blocked User Code Cannot Stop Heartbeats and Keep Bare IPC Windows-Safe

**Files:**
- Create: `strategy-service/tests/strategies/block_after_first_indicator.py`
- Create: `strategy-service/internal/runtimeagent/blocked_worker_integration_test.go`
- Create: `strategy-service/scripts/runtime-agent-blocked-worker.test.sh`
- Create: `strategy-service/scripts/runtime-agent-windows-native.test.ps1`
- Create: `strategy-service/.github/workflows/runtime-agent-windows.yml`
- Modify: `strategy-service/internal/runtimeagent/runtime_channel_test.go`
- Modify: `strategy-service/cmd/runtime-agent/main_test.go`
- Modify: `strategy-service/scripts/runtime-agent-platform.test.sh`
- Modify only if a failing cross-build requires it: `strategy-service/internal/runtimeagent/worker_signal_windows.go`
- Modify only if a failing cross-build requires it: `strategy-service/internal/runtimeagent/worker_environment_windows.go`

**Interfaces:**
- Worker IPC remains `tcp://127.0.0.1:<ephemeral>` as created by `net.Listen("tcp", "127.0.0.1:0")`; no Unix-domain socket is introduced.
- RuntimeChannel heartbeats remain owned by `RuntimeChannelClient.heartbeatLoop`, not Python, `WorkerManager`, or a worker stream goroutine.
- `scripts/runtime-agent-blocked-worker.test.sh` is the repeatable long-duration acceptance entry point; it uses an in-process fake control-panel RuntimeChannel and requires no database, credentials, portfolio IDs, or external addresses.

- [ ] **Step 1: Add a real user-strategy fixture that returns once and then blocks**

Create `tests/strategies/block_after_first_indicator.py` with one declared BTCUSDT 1m input and one line indicator. Its first callback writes value 1 and returns; its second callback atomically writes the path from `HUSHINE_BLOCKED_WORKER_MARKER`, then loops until `time.monotonic()` reaches `HUSHINE_BLOCKED_WORKER_SECONDS`:

```python
deadline = time.monotonic() + float(os.environ["HUSHINE_BLOCKED_WORKER_SECONDS"])
while time.monotonic() < deadline:
    time.sleep(0.1)
```

This simulates a debugger pause in user code without blocking the Go runtime-agent. It must not start background threads inside the strategy.

- [ ] **Step 2: Write the real-process integration test first**

In `blocked_worker_integration_test.go`, start a loopback fake RuntimeChannel server that records hello, heartbeat timestamps, request/response, data, and platform calls. Inject a deterministic one-second heartbeat interval. Start the real Go Agent and real Python `strategy_service.session_worker_entry`, run the fixture, send two bars, and wait for its marker file.

Assert while the Python callback is blocked:

```go
before := fakeControl.HeartbeatCount()
fakeControl.WaitForHeartbeatCount(t, before+3, 5*time.Second)
if !agentProcessAlive() { t.Fatal("runtime-agent exited while user worker was blocked") }
```

Read `HUSHINE_BLOCKED_WORKER_OBSERVE_SECONDS` (short-test default `5`) and observe heartbeats for that complete duration before invoking the actual local `RestartSession`. Record first/last timestamps and maximum consecutive gap. Configure the test stop timeout to 500ms so the stuck Python process is force-reaped. Assert the old session's already completed first indicator bar is finalized before its recoverable update, a new distinct session reaches running, and a late generation-1 close event cannot stop it. The short command sets block/observe to `30/5`; cleanup force-kills the worker, so the suite does not wait 30 seconds. The required long run observes all 600 seconds, requires at least 500 heartbeats, a maximum gap no greater than five seconds, and a live Go runtime-agent at every sample; a 660-second block leaves about one minute when replacement begins.

- [ ] **Step 3: Run the blocked-worker test and verify RED**

```bash
cd strategy-service
go test -tags=integration ./internal/runtimeagent -run TestBlockedWorkerKeepsRuntimeHeartbeatAndCanBeReplaced -count=1 -v
```

Expected: FAIL until Task 7's generation callbacks and restart ordering are wired through the actual process/stream integration.

- [ ] **Step 4: Keep heartbeat ownership independent and make timeouts injectable**

Do not add a worker heartbeat dependency to `RuntimeChannelClient`. Add only test seams for the lifecycle stop/reap timeout and Agent startup wiring. Extend `runtime_channel_test.go` so a deliberately blocked `RequestHandler` goroutine does not prevent three outgoing RuntimeChannel heartbeat frames; this proves the outbound heartbeat goroutine remains independent even before the Python process integration runs.

`cmd/runtime-agent/main_test.go` must assert the listener network is `tcp`, its
address parses as loopback, and the dependency plan's immutable resolved
`WorkerLaunchSpec` plus `BuildWorkerSessionInvocation` inject that exact address
into the per-session invocation. Do not resurrect `WorkerManagerConfig.AgentAddr`
or repeat executable/base-environment resolution; `NewWorkerManager` continues
consuming the already resolved spec. Search assertions forbid
`net.Listen("unix"`, `.sock`, `syscall.Kill`, and Unix path assumptions in
non-build-tagged runtime-agent files.

- [ ] **Step 5: Strengthen the Windows compile/run boundary**

Extend `scripts/runtime-agent-platform.test.sh` with real cross-compilation, not only dry-run filename checks:

```bash
tmp_build="${tmpdir}/build"
mkdir -p "${tmp_build}"
(
  cd "${SERVICE_DIR}"
  CGO_ENABLED=0 GOOS=windows GOARCH=amd64 go build -o "${tmp_build}/runtime-agent.exe" ./cmd/runtime-agent
  CGO_ENABLED=0 GOOS=windows GOARCH=amd64 go test -c -o "${tmp_build}/runtimeagent.test.exe" ./internal/runtimeagent
)
test -s "${tmp_build}/runtime-agent.exe"
test -s "${tmp_build}/runtimeagent.test.exe"
```

Keep graceful POSIX signalling in `worker_signal_unix.go` and Windows termination in `worker_signal_windows.go`; shared files must not import Unix-only packages or constants. The PowerShell launcher remains the Windows entry point.

- [ ] **Step 6: Add a native Windows acceptance gate**

Create `scripts/runtime-agent-windows-native.test.ps1` with `$ErrorActionPreference = "Stop"`; fail unless `$IsWindows`, build `runtime-agent.exe` natively, and run `scripts/start-runtime-agent.ps1 --print-command -- --help` with `RUNTIME_AGENT_BIN` pointing at that binary. Assert the printed command selects the `.exe` and preserves `--help`. Run native focused Go tests covering loopback TCP IPC, Windows graceful/forced process termination plus `Cmd.Wait` reap, stale-generation isolation, and `RestartSession`. Install the locked Python environment, then run the actual real-process blocked-worker integration with `HUSHINE_BLOCKED_WORKER_SECONDS=30` and `HUSHINE_BLOCKED_WORKER_OBSERVE_SECONDS=5`; compile-only output is not native acceptance.

Create `.github/workflows/runtime-agent-windows.yml` for `pull_request` and
`workflow_dispatch` on `windows-latest`, Go `1.26.1`, Python `3.13`, and `uv`.
Because `go.mod` replaces `golang-lib` with `../golang-lib` and Python consumes
the private strategy library, check out both repositories as siblings using the
scoped CI credential before running the PowerShell script. Upload log and `.exe`
and record both tested SHAs. This task obtains a pre-commit native proof when a
runner is available; it cannot claim final-SHA evidence because later tasks
still modify strategy-service. The full-system acceptance Task 4 dispatches the
checked-in workflow against the final clean committed SHA and owns the mandatory
job URL/artifact gate. Missing native capability remains a final-release block,
never replaced by cross-compilation.

- [ ] **Step 7: Add the exact ten-minute observation acceptance script**

`scripts/runtime-agent-blocked-worker.test.sh` validates prerequisites and runs:

```bash
#!/usr/bin/env bash
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${REPO_ROOT}"
export HUSHINE_BLOCKED_WORKER_SECONDS="${HUSHINE_BLOCKED_WORKER_SECONDS:-660}"
export HUSHINE_BLOCKED_WORKER_OBSERVE_SECONDS="${HUSHINE_BLOCKED_WORKER_OBSERVE_SECONDS:-600}"
go test -tags=integration ./internal/runtimeagent \
  -run TestBlockedWorkerKeepsRuntimeHeartbeatAndCanBeReplaced \
  -count=1 -timeout "$((HUSHINE_BLOCKED_WORKER_SECONDS + 90))s" -v
```

The integration test observes heartbeats for ten complete minutes, then triggers replacement while the 660-second callback still has roughly 60 seconds left. This proves sustained heartbeat independence and replacement of an actively blocked worker; it must not wait until the loop unlocks naturally.

- [ ] **Step 8: Run short, race, platform, native-Windows, and ten-minute acceptance checks**

```bash
go test ./internal/runtimeagent -run 'HeartbeatIndependent|LoopbackWorkerIPC' -count=1 -v
HUSHINE_BLOCKED_WORKER_SECONDS=30 HUSHINE_BLOCKED_WORKER_OBSERVE_SECONDS=5 ./scripts/runtime-agent-blocked-worker.test.sh
HUSHINE_BLOCKED_WORKER_SECONDS=30 HUSHINE_BLOCKED_WORKER_OBSERVE_SECONDS=5 go test -race -tags=integration ./internal/runtimeagent -run TestBlockedWorkerKeepsRuntimeHeartbeatAndCanBeReplaced -count=1 -v
./scripts/runtime-agent-platform.test.sh
HUSHINE_BLOCKED_WORKER_SECONDS=660 HUSHINE_BLOCKED_WORKER_OBSERVE_SECONDS=600 ./scripts/runtime-agent-blocked-worker.test.sh
```

On a Windows checkout of the same final SHA (or its required workflow job), also run:

```powershell
pwsh -File scripts/runtime-agent-windows-native.test.ps1
```

Expected: all PASS. The long command observes the complete 600-second window, records at least 500 one-second heartbeats with no gap over five seconds, then finalizes the old tail and force-replaces the still-blocked worker without restarting the Go runtime-agent. Record the native Windows workflow URL/artifact for the exact SHA.

- [ ] **Step 9: Commit blocked-worker and portability tests in strategy-service**

```bash
git add tests/strategies/block_after_first_indicator.py internal/runtimeagent/blocked_worker_integration_test.go internal/runtimeagent/runtime_channel_test.go cmd/runtime-agent/main_test.go scripts/runtime-agent-blocked-worker.test.sh scripts/runtime-agent-platform.test.sh scripts/runtime-agent-windows-native.test.ps1 .github/workflows/runtime-agent-windows.yml internal/runtimeagent/worker_signal_windows.go internal/runtimeagent/worker_environment_windows.go
git commit -m "test: cover blocked workers and windows runtime ipc"
```

---

### Task 9: Fix and Lock the Bollinger Width and Trade-Marker Template Regression

**Files:**
- Modify: `strategy-service/strategy_templates/zecusdt_reconciliation_bollinger_notify.py`
- Modify: `strategy-service/tests/test_zecusdt_reconciliation_bollinger_notify.py`

**Interfaces:**
- The template keeps the existing futures-only `ZECUSDT` input/order target and declared indicator keys.
- `bb_width_bps` is null only before a band can be calculated; once at least two prices exist it equals `((upper-lower)/middle)*10000` for the same callback.
- Each accepted BUY/SELL decision creates exactly one `trade_signal` marker in that bar's frame with the same side text and execution-reference price.

- [ ] **Step 1: Add exact numeric and marker regression tests**

Feed prices `100.0, 101.0` and calculate the expected population standard deviation directly in the test:

```python
middle = 100.5
variance = ((100.0 - middle) ** 2 + (101.0 - middle) ** 2) / 2
band = 2.0 * variance**0.5
expected_width = (((middle + band) - (middle - band)) / middle) * 10_000.0
assert recorder.values["bb_width_bps"] == pytest.approx(expected_width)
```

Then feed 25 deterministic prices and assert the value on every callback from index 1 onward is finite/non-null and uses only the trailing 20 points. Record values by callback rather than only the recorder's last dictionary value so a later accidental null overwrite is caught.

Extend BUY and SELL tests to drain the recorder after each callback and assert exactly one marker is attached to the decision bar, no marker appears on the initialization bar, text is exactly `BUY`/`SELL`, price equals that bar's price, and a subsequent no-trigger bar does not repeat the old marker. Update `_IndicatorRecorder.mark` to accept Task 4's keyword-only `position`/`shape` fields.

- [ ] **Step 2: Run the template test and verify RED**

```bash
cd strategy-service
PYTHONPATH=.:../strategy-library uv run --frozen --extra dev pytest \
  tests/test_zecusdt_reconciliation_bollinger_notify.py -q
```

Expected: the width assertions FAIL because `_record_indicators` unconditionally overwrites the calculated width with `None`.

- [ ] **Step 3: Remove the erroneous overwrite without changing the formula**

Delete only this statement after the `if/else` block:

```python
indicators.set("bb_width_bps", None)
```

Keep the null assignment inside the one-price branch by adding it there if necessary:

```python
else:
    indicators.set("bb_upper", None)
    indicators.set("bb_middle", price)
    indicators.set("bb_lower", None)
    indicators.set("bb_width_bps", None)
```

- [ ] **Step 4: Run focused and adjacent strategy tests**

```bash
PYTHONPATH=.:../strategy-library uv run --frozen --extra dev pytest \
  tests/test_zecusdt_reconciliation_bollinger_notify.py \
  tests/test_strategy_indicators.py tests/test_grpc_server.py -q
```

Expected: PASS; widths remain populated and BUY/SELL markers remain bar-local.

- [ ] **Step 5: Commit the template regression fix in strategy-service**

```bash
git add strategy_templates/zecusdt_reconciliation_bollinger_notify.py tests/test_zecusdt_reconciliation_bollinger_notify.py
git commit -m "fix: retain bollinger width and trade markers"
```

---

### Task 10: Render V2 Indicators by Actual Time and Make Finalized Chunks Immutable in the Portal

**Files:**
- Modify: `gateway/quant-frontend/src/api/client.ts`
- Create: `gateway/quant-frontend/src/components/sessionIndicatorData.ts`
- Modify: `gateway/quant-frontend/src/components/SessionChartPanel.tsx`
- Modify: `gateway/quant-frontend/src/pages/SessionDetailPage.tsx`
- Modify: `gateway/quant-frontend/src/index.css`
- Create: `gateway/quant-frontend/scripts/session-indicator-data.test.mjs`
- Modify: `gateway/quant-frontend/scripts/session-custom-indicators.test.mjs`
- Modify: `gateway/quant-frontend/scripts/runtime-status.test.mjs`
- Modify: `gateway/quant-frontend/package.json`

**Interfaces:**
- Consumes the Task 6 JSON exactly: definition `type`/`protocol_version`, chunk `times_ms`, nullable `scalar_values`, typed `markers`, `revision`, `finalized`, and `protocol_version`, plus Session `indicator_finalization_pending`.
- Produces chart scalar points and markers using durable `time_ms`; no function reconstructs time with `start_time_ms + offset * interval_ms`.
- Cache identity is `(session_id, stream_key, indicator_key, chunk_index)`;
  switching Session atomically clears/rekeys prior data. Open chunks accept only
  newer revisions or an identical same-revision finalized promotion, while a
  finalized chunk is immutable.
- Definition/chunk loads and polls are serial per `(session_id,stream_key)` and
  generation-owned. A Session/stream change aborts the old request and advances
  an epoch; a late old response cannot merge, render, mutate backoff, or schedule
  another timer.
- Poll scheduling uses orthogonal Session state and
  `indicator_finalization_pending`: running always polls across a 1024 boundary;
  recoverable polls with bounded exponential backoff only while finalization is
  pending, and stops after lifecycle retry durably clears that fact.
- Session-detail record polling is serial (one request in flight), continues for
  a terminal Session only while `indicator_finalization_pending=true`, and
  ignores every response belonging to a superseded Session/effect.

- [ ] **Step 1: Replace frontend API types in a failing executable data test**

Add `indicator_finalization_pending: boolean` to `Session`; it is a required JSON
field with a server-side false default, not an optional client guess. Add
`protocol_version: 2` to `StrategyIndicatorDefinition`, then define:

```ts
export type StrategyIndicatorMarkerV2 = {
  sequence: number;
  offset: number;
  time_ms: number;
  text: string;
  price?: number;
  color: string;
  position: "" | "aboveBar" | "belowBar" | "inBar" | string;
  shape: "" | "circle" | "square" | "arrowUp" | "arrowDown" | string;
};

export type StrategyIndicatorChunk = {
  session_id: string;
  stream_key: string;
  indicator_key: string;
  chunk_index: number;
  start_sequence: number;
  end_sequence: number;
  start_time_ms: number;
  end_time_ms: number;
  interval_ms: number;
  count: number;
  times_ms: number[];
  scalar_values: Array<number | null>;
  markers: StrategyIndicatorMarkerV2[];
  revision: number;
  finalized: boolean;
  protocol_version: 2;
};
```

Delete `values_json` from the type. In `session-indicator-data.test.mjs`, transpile `sessionIndicatorData.ts` with the same `typescript.transpileModule` + data-URL import pattern as `scripts/session-chart.test.mjs`.

- [ ] **Step 2: Write executable RED cases for actual times, sparse values/markers, revisions, and sealing**

Use an open chunk with `times_ms:[1000,9000]`, `scalar_values:[1.5,null]`, and a marker at sequence 1/time 9000. Assert:

```js
assert.deepEqual(expandScalarIndicatorV2(lineDefinition, chunk), [{ time: 1, value: 1.5 }]);
assert.equal(buildIndicatorMarkersV2(markerDefinition, markerChunk)[0].time, 9);
```

The seconds conversion is exactly `Math.floor(time_ms / 1000)` because `lightweight-charts` uses Unix seconds. No assertion may derive 9000 from interval.

Merge these updates in order:

1. open revision 1/count 1;
2. open revision 2/count 2 replaces it;
3. stale revision 1 is ignored;
4. same revision 2 with byte-equivalent payload and `finalized=true` promotes it;
5. revision 3 after finalization is rejected/ignored and reports a conflict diagnostic;
6. identical finalized retry is idempotent.

Also assert marker ordering by `(time_ms, sequence, input-order)`, two markers on one bar survive, missing scalar values do not shift later values, definition/chunk `protocol_version!==2` is rejected, line/histogram definitions reject `scalar_values.length!==count`, marker definitions reject non-empty `scalar_values`, and `tailState` reports `{openChunks:1, finalizedChunks:0}` before sealing and `{0,1}` after.

Add scheduler cases: running plus a finalized boundary remains true and a later
one-point chunk merges into the same Session cache. Recoverable plus
`indicator_finalization_pending=true` polls with bounded exponential delays up
to 30 seconds; once false it stops even when status remains recoverable. A
terminal Session with only finalized chunks is false, while a terminal response
with an open chunk remains true until finalization is observed. Switch to a new
Session with identical stream/key/chunk IDs and prove old finalized cache data
cannot block or merge into it.

Use deferred request promises for the switch case, not only sequential input:
start old-Session definitions/chunks, switch and complete the new Session first,
then resolve the old request. Assert the old completion produces no cache/chart
write, warning, backoff mutation, or timer, while the new data remains intact.
Repeat for a stream-key change inside one Session and for an aborted request
whose transport still resolves despite cancellation.

Extend `runtime-status.test.mjs` for a new exported
`shouldPollSessionRecord(session)`: nonterminal is true, recoverable/pending true
is true, and recoverable/pending false is false. Add a structural assertion that
`SessionDetailPage` uses recursive `setTimeout` only after the preceding
`getSession` settles, never `setInterval`; a pending-true response schedules the
next read, a later pending-false response does not, and cleanup/superseded
Session identity prevents a late response from setting state or scheduling.

- [ ] **Step 3: Run the executable script and verify RED**

```bash
cd gateway/quant-frontend
node scripts/session-indicator-data.test.mjs
```

Expected: FAIL because the pure module does not exist and the current chart parses `values_json` and reconstructs time by offset.

- [ ] **Step 4: Implement pure V2 validation, expansion, marker conversion, and merge**

Use `import type` for `UTCTimestamp` and `SeriesMarker` so the executable data-URL test has no unresolved runtime import. Export these functions from `sessionIndicatorData.ts`:

```ts
export function validateIndicatorChunkV2(definition: StrategyIndicatorDefinition, chunk: StrategyIndicatorChunk): void;
export function expandScalarIndicatorV2(definition: StrategyIndicatorDefinition, chunk: StrategyIndicatorChunk): Array<{time: UTCTimestamp; value: number}>;
export function buildIndicatorMarkersV2(definition: StrategyIndicatorDefinition, chunk: StrategyIndicatorChunk): SeriesMarker<UTCTimestamp>[];
export function mergeIndicatorChunksV2(definitions: StrategyIndicatorDefinition[], current: StrategyIndicatorChunk[], incoming: StrategyIndicatorChunk[]): IndicatorMergeResult;
export function indicatorTailState(chunks: StrategyIndicatorChunk[]): {openChunks: number; finalizedChunks: number};
export function indicatorPollDecision(session: Pick<Session, "status" | "indicator_finalization_pending">, chunks: StrategyIndicatorChunk[], retryAttempt: number): {poll: boolean; delayMs: number};
export type IndicatorRequestToken = Readonly<{sessionID: string; streamKey: string; epoch: number}>;
export type IndicatorRequestOwner = {begin(sessionID: string, streamKey: string): IndicatorRequestToken; invalidate(): void; isCurrent(token: IndicatorRequestToken): boolean};
export function createIndicatorRequestOwner(): IndicatorRequestOwner;
```

Remove the stale one-argument declaration rather than overload it. Validation
requires matching definition/chunk identity and protocol 2,
`count===times_ms.length`, sequence range/count consistency, scalar count equal
to count for line/histogram definitions, an empty scalar array for marker
definitions, and each marker's offset/sequence/time relationship. Expansion
indexes scalar value and `times_ms` by the same offset and skips null only.
Marker conversion accepts only a marker definition, uses `marker.time_ms`,
validates it against `times_ms[marker.offset]`, preserves text/color/price, and
maps empty position/shape to the current chart defaults.

For same-revision open→finalized promotion, compare all fields except `finalized`; any other same-revision difference is a conflict. Return conflicts from `mergeIndicatorChunksV2` so the component can log one bounded warning rather than silently displaying corrupt data.

`IndicatorRequestOwner.begin(sessionID, streamKey)` returns a token containing
that identity plus a monotonically increasing epoch; `invalidate()` advances the
epoch, and `isCurrent(token)` is true only for the exact current token. The pure
executable test drives deferred old/new promises through this owner and proves
out-of-order old completion cannot call its apply/schedule callbacks. The React
component still owns the actual `AbortController`; the epoch check is mandatory
even after abort because cancellation does not prove a transport callback will
never resolve.

In `client.ts`, keep `isSessionTerminal` unchanged for product semantics and add:

```ts
export function shouldPollSessionRecord(
  session: Pick<Session, "status" | "indicator_finalization_pending">,
): boolean {
  return !isSessionTerminal(session) || session.indicator_finalization_pending;
}
```

This helper controls only refreshing the Session record; it does not redefine a
recoverable Session as nonterminal.

- [ ] **Step 5: Integrate the immutable cache and open-tail status into `SessionChartPanel`**

Replace `parseIndicatorValues`, `valueAtOffset`, `expandCustomIndicatorChunks`, and `buildCustomIndicatorMarkers` internals with the pure functions. Keep the current series/pane/toggle behavior. Store chunks in a ref-backed cache by full `(session_id,stream_key,indicator_key,chunk_index)` identity and atomically clear the ref plus rendered series data when the selected Session ID changes, so polling cannot recreate finalized data, regress an open revision, or merge a prior Session.

Own one `IndicatorRequestOwner`, `AbortController`, and timer in refs. On
Session/stream change or unmount: clear the timer, abort the current controller,
invalidate the owner, clear the cache/rendered data, and reset backoff for the
new identity. Start no second definitions/chunks request until the current one
settles. Before every merge, render, diagnostic, retry-counter change, or timer
schedule, require `owner.isCurrent(capturedToken)` and exact captured/current
Session/stream equality. A stale completion exits without side effects even if
the HTTP layer ignored abort.

Use `indicatorPollDecision` as the only scheduler. A running Session continues
the short-delay poll regardless of whether an open chunk currently exists; this
covers the boundary window after chunk 0 finalizes and before sequence 1024
creates chunk 1. Recoverable polls only while
`indicator_finalization_pending=true`, with deterministic exponential backoff
capped at 30 seconds, and stops immediately after the Session refresh observes
false. Other terminal statuses poll only while an actually returned open chunk
remains, then stop. Keep the recoverable retry attempt in a ref keyed by Session
ID. Increment it after either an error or a successful response with no revision/
finalization progress; reset it only on actual chunk progress, Session-ID
change, or a transition back to running—not merely because a new Session object
or another unchanged successful response arrived. Cancel old timers on
unmount/change. Finalized cache entries remain
immutable/idempotent when the API returns them again; the component must not
recreate their chart points. Render one accessible badge in the custom-indicator section:

```tsx
<span className="session-chart__indicator-tail" aria-live="polite">
  {tail.openChunks > 0
    ? `Live tail · ${tail.openChunks} open`
    : isLiveSession
      ? "Waiting for next live indicator chunk"
      : "Indicators finalized"}
</span>
```

Do not use `interval_ms` to place points. It remains metadata for diagnostics only.

Replace `SessionDetailPage`'s overlapping `setInterval` loop with one recursive
`setTimeout` loop. Await `getSession(stableSessionId)`, ignore the result when
the effect was cancelled or its captured Session ID is no longer current, set
the Session, and schedule the next call only when
`shouldPollSessionRecord(item)` is true. A transient read error schedules one
bounded retry without clearing a newer Session. Cleanup clears the one timer
and marks the effect cancelled. This guarantees the page observes the durable
true→false pending transition and prevents an older slow response from
overwriting it.

- [ ] **Step 6: Update structural tests to enforce the V2 boundary**

`session-custom-indicators.test.mjs` asserts imports/calls to the new pure functions and badge, and asserts the component source does **not** contain `values_json`, `start_time_ms +`, or `offset * interval`. Keep existing pane/toggle/layout assertions. Add minimal `.session-chart__indicator-tail` styling without changing chart dimensions.

- [ ] **Step 7: Run executable, structural, build, and all tracked frontend tests**

```bash
node scripts/session-indicator-data.test.mjs
npm run test:session-custom-indicators
npm run build
for test_file in scripts/*.test.mjs; do node "${test_file}" || exit 1; done
```

Expected: PASS; the executable test proves irregular actual times and finalized-cache semantics rather than matching source strings alone.

- [ ] **Step 8: Commit only quant-frontend files**

```bash
git add src/api/client.ts src/components/sessionIndicatorData.ts src/components/SessionChartPanel.tsx src/pages/SessionDetailPage.tsx src/index.css scripts/session-indicator-data.test.mjs scripts/session-custom-indicators.test.mjs scripts/runtime-status.test.mjs package.json
git commit -m "feat: render runtime indicators by actual time"
```

---

### Task 11: Seal Additive V2 on the Real Chain, Then Build One Coordinated V1-Removal Candidate

**Files:**
- Create: `strategy-service/internal/runtimeagent/indicator_v2_integration_test.go`
- Create: `strategy-service/tests/strategies/indicator_v2_open_time_cutover.py`
- Modify: `strategy-service/proto/runtime_worker.proto`
- Regenerate: `strategy-service/gen/runtimeworkerv1/runtime_worker.pb.go`
- Regenerate: `strategy-service/gen/runtimeworkerv1/runtime_worker_grpc.pb.go`
- Regenerate: `strategy-service/strategy_service/gen/runtime_worker_pb2.py`
- Regenerate: `strategy-service/strategy_service/gen/runtime_worker_pb2_grpc.py`
- Modify: `strategy-service/tests/test_runtime_worker_proto.py`
- Modify: `core-service/proto/portfolio_service.proto`
- Regenerate: `core-service/gen/portfoliov1/portfolio_service.pb.go`
- Regenerate: `core-service/gen/portfoliov1/portfolio_service_grpc.pb.go`
- Modify: `core-service/internal/domain/strategy_indicator.go`
- Modify: `core-service/internal/repository/repository.go`
- Modify: `core-service/internal/repository/timescale.go`
- Modify: `core-service/internal/service/grpc.go`
- Modify: `core-service/internal/repository/strategy_indicator_test.go`
- Modify: `core-service/internal/service/grpc_strategy_indicator_test.go`
- Modify: `core-service/internal/service/grpc_strategy_indicator_proto_test.go`
- Modify: `core-service/tests/repository_test.go`
- Modify: `core-service/internal/service/grpc_portfolio_meta_test.go`
- Modify: `control-panel-service/internal/runtimechannel/platform_proxy.go`
- Modify: `control-panel-service/internal/runtimechannel/platform_proxy_test.go`
- Regenerate: `strategy-service/gen/portfoliov1/portfolio_service.pb.go`
- Regenerate: `strategy-service/gen/portfoliov1/portfolio_service_grpc.pb.go`
- Regenerate: `strategy-service/strategy_service/gen/portfolio_service_pb2.py`
- Regenerate: `strategy-service/strategy_service/gen/portfolio_service_pb2_grpc.py`
- Modify: `strategy-service/strategy_service/grpc_server.py`
- Modify: `strategy-service/strategy_service/indicators.py`
- Modify: `strategy-service/strategy_service/platform_proxy.py`
- Modify: `strategy-service/tests/test_strategy_indicators.py`
- Modify: `strategy-service/tests/test_grpc_server.py`
- Modify: `strategy-service/tests/test_platform_proxy.py`
- Modify: `gateway/quant-handler/internal/app/session_indicators.go`
- Modify: `gateway/quant-handler/internal/app/session_indicators_test.go`
- Modify: `gateway/quant-handler/internal/app/session_history_test.go`
- Create: `hushine-deploy/scripts/runtime-indicator-v2-db-smoke.sh`
- Create: `hushine-deploy/scripts/runtime-indicator-v2-smoke.sh`
- Create: `hushine-deploy/scripts/runtime-indicator-v2-service-chain.sh`
- Create: `hushine-deploy/scripts/runtime-indicator-v2-cutover-evidence.test.sh`
- Modify: `hushine-deploy/Makefile`

**Interfaces:**
- Before any deletion, V2 passes the exact 1023+2/2049/database/service-chain/page assertions below while every V1 source/wire surface still exists. The pre-cutover evidence seal is bound to all repository SHAs and to acceptance-owned database/runtime/session/browser identities.
- The only portfolio indicator RPCs after this task are `SaveStrategyIndicatorsV2`, `FinalizeStrategyIndicatorChunksV2`, `ListStrategyIndicatorsV2`, and `ListStrategyIndicatorChunksV2`.
- The only worker wire payload is `indicator_frame_v2=21`; field 15 and name `indicator_frame` remain reserved.
- Python retains the user-facing in-memory `IndicatorFrame`/`IndicatorWriter` API, but removes `IndicatorChunkBuffer` and the direct `portfolio.SaveStrategyIndicators` branch; all runtime persistence goes through the Go Agent.
- Every V1-removal commit produced below is one coordinated candidate. Individual repository commits are intentionally non-releasable, non-deployable, and non-push until Task 12 reruns the identical gates and no-V1 scan. A failure resets the candidate to the pre-cutover SHAs; it never authorizes a partial rollout.

- [ ] **Step 1: Write the additive V2 integration, database, service-chain, and evidence gates before deleting V1**

Keep the existing V1 descriptor/API/direct-writer tests GREEN while adding the
V2 tests. `indicator_v2_integration_test.go` drives 1023 frames through the real
Agent handler, lets the normal two-second flush become in flight, then sends
sequences 1023 and 1024. It asserts the durable 1024-finalized plus one-open
result, and adds 2049, exact repeated-1023, conflicting duplicate, sparse and
multiple markers, three independent stream keys, every terminal row, and
retry cases. The conflicting duplicate is same sequence/time with a changed
scalar/marker payload and must close order/frame admission.

`indicator_v2_open_time_cutover.py` declares one scalar and one marker and uses
production-shaped bars where
`open_time=n*60_000`, `close_time=open_time+59_999`, and
`timestamp=close_time`. It emits markers on sequences 4, 9, and 1438 and an
order decision on the same bars, receives at least 2050 source bars, and never
reads a test-only `timestamp=open_time` shortcut. Before processing the next
bar after exactly 1023, 1025, or 2049 completed callbacks, it reads the private
mode-0600 control JSON named by `HUSHINE_INDICATOR_V2_BARRIER_FILE`. It writes an
atomic acknowledgement containing owner token, completed count, and last
open-time, then blocks before any writes/orders for the next bar until the
owner- and generation-matching target advances. Thus the preceding callback
has already returned and its frame has drained before each barrier; the blocked
next callback contributes no partial frame.

Create `runtime-indicator-v2-db-smoke.sh` with unique names
`hushine_indicator_acceptance_<run>_{fresh,upgrade,order_guard}`. It refuses
pre-existing targets; applies fresh bootstrap twice; loads a populated V1
fixture; requires identical hashes for every retained non-indicator table;
requires zero legacy indicator rows and exact V2 constraints afterward; proves
the separate order/fill database hash is unchanged; grep-fails on `SKIP`; and a
name/ownership-token-checked trap terminates connections and drops only those
three databases. Before invoking the production runner on a legacy fixture, it
sets the exact random token in the database comment and a mode-0600 owner JSON,
then exports `HUSHINE_INDICATOR_V2_DESTRUCTIVE_MODE=acceptance` and
`HUSHINE_INDICATOR_V2_ACCEPTANCE_OWNER_FILE=<that file>`; add a shell RED proving
prefix-only and mismatched-token attempts fail before the V1 row count changes.
Create
`runtime-indicator-v2-smoke.sh` to run the focused repository/blocked-worker/
Windows/gateway/frontend matrix. At this stage both scripts must also assert
the deprecated V1 descriptors and source surfaces still exist; they select V2
only for the acceptance processes.

Add executable coexistence tests before the cutover: control-panel
`TestIndicatorProtoV1CoexistsWithV2` dispatches one authenticated V1 save and
the V2 save/finalize pair through their distinct canonical methods; quant-handler
`TestStrategyIndicatorV1CoexistsWithV2` exercises the deprecated V1 mapper and
the V2 mapper against their generated clients without aliasing either response.
Both tests assert the expected V1 and V2 descriptor method names. Keep them
GREEN in the pre-cutover commit; Task 11's removal RED later flips these exact
contracts to absence.

`runtime-indicator-v2-service-chain.sh` exposes exact subcommands
`start|await|advance|stop`. `start --phase pre --state-dir <absolute-dir>` must
use acceptance-owned `.10` databases whose names begin
`hushine_indicator_chain_`, ephemeral loopback ports, and mode-0600 state. It
starts the real core-service, control-panel-service, quant-handler,
quant-frontend, hosted runtime-agent, and actual Python session worker; a fake
Agent platform or direct database writer is forbidden. It authenticates the
RuntimeChannel, loads the fixture through the supported strategy path, starts a
Backtest session through quant-handler, launches a long-lived ownership-token-
pinned supervisor, and returns only after the Session reaches the deterministic
`open-1023` barrier. The supervisor—not the short `start` caller—owns cleanup;
an explicit `stop` command or supervisor signal runs the same cleanup path. It
records PIDs plus process start identities and exact source SHAs before startup,
fails on any skipped process/readiness check, and stops only matching PIDs and
drops only ownership-token-matching databases. The destructive migration is applied only
to those owned databases through the same runner acceptance guard; the shared/
long-lived portfolio database remains untouched. After the pre-cutover seal,
the explicit shared cutover entry point uses mode `cutover`, the sealed pre-tree
record, and the exact current committed SHA map. No direct `psql 0002` or
unguarded runner invocation is an allowed deployment path.

The service-chain script writes `<state-dir>/chain.json` with schema 1, phase,
repository SHAs, database names/ownership token, runtime/session/strategy IDs,
and redacted URLs. `await <state>` validates the fixture acknowledgement and
then queries the real core database plus authenticated handler until the exact
state is observed or a bounded deadline fails. `advance <count>` atomically
writes a strictly increasing target with the same owner/runtime/session/
generation token; only `1025` after `1023`, and `2049` after `1025`, are valid.
Wall-clock sleeps are never state evidence. The exact assertions are:

```json
{
  "chunk_1023": {"count": 1023, "finalized": false},
  "chunk_1025": [{"count": 1024, "finalized": true}, {"count": 1, "finalized": false}],
  "chunk_2049": [1024, 1024, 1],
  "repeat_1023": {"row_delta": 0, "revision_delta": 0, "updated_at_changed": false},
  "marker_1438": {"sequence": 1438, "time_ms_equals_open_time": true},
  "close_time_preserved_for_order": true,
  "protocol_version": 2
}
```

Do not start removal-contract REDs in the same edit batch; first make every
additive V2 test and script GREEN with V1 still present.

Commit the additive test fixture/integration test in strategy-service and the
four acceptance scripts/Make target in hushine-deploy as ordinary pre-cutover
commits, then rerun their focused tests. Do not push. The Browser seal in Step 2
must name these committed SHAs, not a dirty-worktree approximation:

```bash
cd strategy-service
git add internal/runtimeagent/indicator_v2_integration_test.go tests/strategies/indicator_v2_open_time_cutover.py
git diff --cached --check
git commit -m "test: cover additive indicator v2 real-chain cases"
cd ../hushine-deploy
git add Makefile scripts/runtime-indicator-v2-db-smoke.sh scripts/runtime-indicator-v2-smoke.sh scripts/runtime-indicator-v2-service-chain.sh scripts/runtime-indicator-v2-cutover-evidence.test.sh
git diff --cached --check
git commit -m "test: add indicator v2 pre-cutover gate"
```

- [ ] **Step 2: Run the real page against the additive V2 stack and seal pre-cutover evidence**

Run the database/focused gate, then start the supervisor-owned service-chain
stack and prove its first deterministic barrier:

```bash
cd hushine-deploy
make test-runtime-indicator-v2
state_dir="$(pwd)/.superpowers/sdd/indicator-v2-precutover"
bash scripts/runtime-indicator-v2-service-chain.sh start --phase pre --state-dir "$state_dir"
bash scripts/runtime-indicator-v2-service-chain.sh await open-1023 --state-dir "$state_dir"
```

Use the installed `browser:control-in-app-browser` skill on the exact frontend
URL and Session ID from `chain.json`. This is a real-page gate, not a pure
frontend test or HTTP-only substitute. With fresh page snapshots before every
action:

1. while `await open-1023` is pinned, open the Session chart and verify exactly
   one open chunk with count 1023 after its normal flush; capture DB/API/page
   values before advancing;
2. verify BUY/SELL marker sequence/time matches the candle `open_time`, while
   the order record retains the intended close-time fact;
3. run `advance 1025`, then `await finalized-1024-plus-tail`; verify the same
   Session now shows chunk 0 count 1024/finalized and chunk 1 count 1/open;
4. run `advance 2049`, then `await two-full-plus-tail`; verify two immutable
   1024 chunks plus one one-bar tail, refresh twice, and prove finalized points
   do not move;
5. inspect the page's API/network result and require V2 fields
   `times_ms`, `revision`, `finalized`, and `protocol_version=2` with no
   `values_json` use; fail on console errors or unexpected same-origin 4xx/5xx.

Use these exact transitions from a second terminal while the Browser remains on
the same Session:

```bash
bash scripts/runtime-indicator-v2-service-chain.sh advance 1025 --state-dir "$state_dir"
bash scripts/runtime-indicator-v2-service-chain.sh await finalized-1024-plus-tail --state-dir "$state_dir"
bash scripts/runtime-indicator-v2-service-chain.sh advance 2049 --state-dir "$state_dir"
bash scripts/runtime-indicator-v2-service-chain.sh await two-full-plus-tail --state-dir "$state_dir"
```

Write `<state-dir>/browser.json` with schema 1, source SHA map, browser/tab
identity, runtime/session IDs, timestamped actions, the 1023+2/2049/open-time
assertions, redacted network/console summaries, and hashes of approved
non-sensitive screenshots. The model/operator must not type secrets during
this gate.

Always finish with the ownership-validated stop, even after a failed Browser
assertion; `stop` records cleanup proof in `chain.json` before the evidence seal:

```bash
bash scripts/runtime-indicator-v2-service-chain.sh stop --state-dir "$state_dir"
```

At this point `chain.json` and `browser.json` are complete, but do **not** write
the pre-cutover seal yet. Step 3 must first capture and bind all four executable
coexistence results. Preserve these files as local ignored artifacts; do not
commit screenshots or runtime IDs.

- [ ] **Step 3: Prove the pre-cutover rollback surface and hard-stop without a current seal**

Before the first deletion edit, use the evidence script's fixed
`capture-coexistence` subcommand. It runs the exact four descriptor/source tests
that require V1 field 15, the three core V1 methods, control-panel V1 dispatch,
Python direct writer, handler V1 types, and V2 field 21 to coexist:

```bash
cd hushine-deploy
state_dir="$(pwd)/.superpowers/sdd/indicator-v2-precutover"
bash scripts/runtime-indicator-v2-cutover-evidence.test.sh \
  capture-coexistence --state-dir "$state_dir" \
  --chain "$state_dir/chain.json" \
  --out "$state_dir/coexistence.json"
```

The subcommand owns this immutable table; callers cannot replace argv, cwd, or
test ID:

| ID | Repository | Exact command |
|---|---|---|
| `strategy-service-worker-v1-v2` | `strategy-service` | `PYTHONPATH=.:../strategy-library uv run --frozen --extra dev pytest tests/test_runtime_worker_proto.py tests/test_grpc_server.py -q` |
| `core-indicator-v1-v2` | `core-service` | `go test ./internal/service -run IndicatorProtoV1CoexistsWithV2 -count=1 -v` |
| `control-indicator-v1-v2` | `control-panel-service` | `go test ./internal/runtimechannel -run IndicatorProtoV1CoexistsWithV2 -count=1 -v` |
| `handler-indicator-v1-v2` | `gateway/quant-handler` | `go test ./internal/app -run StrategyIndicatorV1CoexistsWithV2 -count=1 -v` |

For each command, create a mode-0600 non-symlink regular log beneath
`<state-dir>/coexistence/`, capture the real exit status plus redacted combined
stdout/stderr, require exit 0 and non-empty output, and compute SHA-256 after
redaction. Atomically write mode-0600 `coexistence.json` with schema/phase
`1/pre`, the exact four IDs, repository name and 40-hex SHA copied from
`chain.json.source_shas`, fixed argv/cwd and allowlisted environment overrides
(`PYTHONPATH` only for strategy-service), exit code, start/finish timestamps,
relative log path, and log SHA-256. Before execution, current `HEAD` must equal
that repository SHA and the owned paths must be clean. Missing/extra/duplicate IDs, changed argv/environment,
repo-SHA mismatch, unsafe path/mode/type, empty log, nonzero exit, or hash drift
fails without a manifest.

Now write the first pre-cutover seal with all three inputs:

```bash
bash scripts/runtime-indicator-v2-cutover-evidence.test.sh --phase pre \
  --chain "$state_dir/chain.json" \
  --browser "$state_dir/browser.json" \
  --coexistence "$state_dir/coexistence.json" \
  --seal "$state_dir/seal.json" --check-current-shas
```

The validator reopens and rehashes every coexistence log, validates the exact
manifest table and repo SHAs, and includes
`coexistence_manifest_sha256` plus the four `{id,repository_sha,log_sha256}`
records inside the canonical seal payload before hashing/writing `seal.json`.
Seal revalidation repeats those checks; it never trusts hashes copied only from
the seal. The expected result is all GREEN and a current three-input seal. No shared migration,
removal edit, removal commit, push, or deploy is permitted before this point.

- [ ] **Step 4: Add descriptor and source-contract tests that reject V1**

Update the core descriptor test to assert that these methods/messages are absent:

```go
for _, name := range []protoreflect.Name{
    "SaveStrategyIndicators", "ListStrategyIndicators", "ListStrategyIndicatorChunks",
} {
    if svc.Methods().ByName(name) != nil { t.Fatalf("V1 method remains: %s", name) }
}
for _, name := range []protoreflect.Name{
    "StrategyIndicatorChunk", "SaveStrategyIndicatorsRequest",
    "ListStrategyIndicatorsRequest", "ListStrategyIndicatorChunksRequest",
} {
    if file.Messages().ByName(name) != nil { t.Fatalf("V1 message remains: %s", name) }
}
```

Move the worker removal contract here: Python/Go descriptor tests first require
tag 15 to be reserved, field 21 to remain `indicator_frame_v2`, and generated V1
wire classes/accessors to be absent. Add a Python test that constructing a
runtime servicer with no Agent indicator sink cannot instantiate or call a
portfolio indicator writer.

- [ ] **Step 5: Run the removal contracts and verify RED**

```bash
cd core-service
go test ./internal/service -run 'IndicatorProtoV1Removed' -count=1 -v
cd ../strategy-service
PYTHONPATH=.:../strategy-library uv run --frozen --extra dev pytest \
  tests/test_runtime_worker_proto.py tests/test_grpc_server.py tests/test_platform_proxy.py -q
```

Expected: FAIL because the sealed additive phase still contains WorkerFrame V1,
V1 core RPC/messages, control dispatch, and the direct Python chunk writer.

- [ ] **Step 6: Remove V1 from core-service and regenerate from source**

Delete only the three V1 RPC declarations and their V1 definition/chunk/request/response messages from `proto/portfolio_service.proto`. Keep all four V2 RPCs and types. Remove the V1 domain structs, repository methods/filter, SQL code, service handlers/converters, and test-double methods; retain the V2 implementations and the `0002` migration's `values_json` detection because it is required to recognize populated V1 databases.

Run and verify core before committing:

```bash
cd core-service
make proto-portfolio
go test ./internal/service ./internal/repository ./internal/storage/migrations -count=1
go test ./... -count=1
go vet ./...
git diff --check
git add proto/portfolio_service.proto gen/portfoliov1/portfolio_service.pb.go gen/portfoliov1/portfolio_service_grpc.pb.go internal/domain/strategy_indicator.go internal/repository/repository.go internal/repository/timescale.go internal/service/grpc.go internal/repository/strategy_indicator_test.go internal/service/grpc_strategy_indicator_test.go internal/service/grpc_strategy_indicator_proto_test.go tests/repository_test.go internal/service/grpc_portfolio_meta_test.go
git commit -m "refactor: remove indicator v1 portfolio api"
```

- [ ] **Step 7: Remove the V1 control-panel dispatch and create its coordinated candidate commit**

Delete `PortfolioPlatformClient.SaveStrategyIndicators`, its dispatch case, canonical method alias, unavailable-client method, and V1-only test. Keep authenticated V2 save/finalize cases unchanged.

```bash
cd control-panel-service
go test ./internal/runtimechannel -run 'Indicator.*V2|V1Removed' -count=1 -v
go test ./... -count=1
go vet ./...
git diff --check
git add internal/runtimechannel/platform_proxy.go internal/runtimechannel/platform_proxy_test.go
git commit -m "refactor: remove indicator v1 runtime proxy"
```

- [ ] **Step 8: Reserve worker field 15, regenerate all strategy-service stubs, and remove direct persistence**

Change `WorkerFrame` only now: remove `indicator_frame=15`, add
`reserved 15; reserved "indicator_frame";`, keep
`indicator_frame_v2=21`, and preserve every dependency Task 7/8 nested field.
Delete worker `IndicatorValue`/`IndicatorFrame`, then run
`./generate_proto.sh` against both authoritative V2-only protos. In
`grpc_server._install_indicator_collection`, remove the
`IndicatorChunkBuffer`/direct portfolio-client branch. An agent-managed worker
must have the sink installed before session execution; missing sink fails start
with `RUNTIME_INDICATOR_SINK_REQUIRED` rather than silently dropping indicators.
Strategies with no `INDICATORS` remain unaffected.

Delete `IndicatorChunkBuffer` and its persisted-chunk DTO from `indicators.py`; keep `IndicatorDefinition`, the user-facing sparse `IndicatorFrame`, and `IndicatorWriter`. Delete `PORTFOLIO_SAVE_STRATEGY_INDICATORS` and `PlatformProxy.save_strategy_indicators` from `platform_proxy.py`; keep unrelated order, wallet, market-data, notification, and session operations.

Replace old direct-writer tests with these assertions:

```python
assert not hasattr(platform_proxy, "PORTFOLIO_SAVE_STRATEGY_INDICATORS")
assert not hasattr(PlatformProxy, "save_strategy_indicators")
assert not hasattr(indicators, "IndicatorChunkBuffer")
```

Then verify and commit:

```bash
cd strategy-service
./generate_proto.sh
PYTHONPATH=.:../strategy-library uv run --frozen --extra dev pytest tests/ -q
go test ./... -count=1
go vet ./...
./scripts/runtime-agent-platform.test.sh
git diff --check
git add proto/runtime_worker.proto gen/runtimeworkerv1/runtime_worker.pb.go gen/runtimeworkerv1/runtime_worker_grpc.pb.go strategy_service/gen/runtime_worker_pb2.py strategy_service/gen/runtime_worker_pb2_grpc.py gen/portfoliov1/portfolio_service.pb.go gen/portfoliov1/portfolio_service_grpc.pb.go strategy_service/gen/portfolio_service_pb2.py strategy_service/gen/portfolio_service_pb2_grpc.py strategy_service/grpc_server.py strategy_service/indicators.py strategy_service/platform_proxy.py tests/test_runtime_worker_proto.py tests/test_strategy_indicators.py tests/test_grpc_server.py tests/test_platform_proxy.py
git commit -m "refactor: remove direct indicator v1 persistence"
```

- [ ] **Step 9: Confirm quant-handler has no V1 client surface and create a candidate commit only if needed**

Task 6 should already have moved all handlers/test doubles to V2. Delete any residual V1 client fields/methods or `values_json` assertions, run:

```bash
cd gateway/quant-handler
go test ./internal/app -run 'StrategyIndicator.*V2|IndicatorV1Removed' -count=1 -v
go test ./... -count=1
go vet ./...
git diff --check
```

If this step produces owned changes, commit only those files:

```bash
git add internal/app/session_indicators.go internal/app/session_indicators_test.go internal/app/session_history_test.go
git commit -m "refactor: remove indicator v1 gateway types"
```

- [ ] **Step 10: Run a precise no-V1 scan and freeze the non-push candidate**

From the workspace root:

```bash
if rg -n \
  -g '!**/docs/**' \
  -g '!core-service/internal/storage/migrations/0002_runtime_indicator_v2.sql' \
  -g '!core-service/internal/storage/migrations/testdata/indicator_v1_fixture.sql' \
  '(SaveStrategyIndicators(Request|Response|\()|ListStrategyIndicators(Request|Response|\()|ListStrategyIndicatorChunks(Request|Response|\()|values_json|PORTFOLIO_SAVE_STRATEGY_INDICATORS|IndicatorChunkBuffer|WorkerFrame_IndicatorFrame|GetIndicatorFrame\(|IndicatorFrame indicator_frame = 15)' \
  core-service control-panel-service strategy-service gateway/quant-handler gateway/quant-frontend; then
  echo 'unexpected indicator V1 executable surface remains' >&2
  exit 1
fi
```

Expected: no output and exit 0. Historical dated Superpowers documents are intentionally excluded; the upgrade migration is the single allowed executable `values_json` occurrence because it detects and destroys old indicator-only storage.

Record every pre-cutover and candidate SHA plus the seal hash. Mark all removal
commits `candidate_only=true`; do not push, deploy, apply `0002` to a shared
database, or describe any individual repository SHA as runnable/releasable.
Proceed directly to Task 12. If Task 12 fails, return every repository to its
recorded pre-cutover branch tip without broad/destructive worktree commands,
preserving unrelated dirty work.

---

### Task 12: Rerun the Identical Database, Real Service-Chain, and Real-Page Gates After Atomic V1 Removal

**Files:**
- Verify: `strategy-service/internal/runtimeagent/indicator_v2_integration_test.go`
- Verify: `strategy-service/tests/strategies/indicator_v2_open_time_cutover.py`
- Modify/verify: `hushine-deploy/scripts/runtime-indicator-v2-db-smoke.sh`
- Modify/verify: `hushine-deploy/scripts/runtime-indicator-v2-smoke.sh`
- Modify/verify: `hushine-deploy/scripts/runtime-indicator-v2-service-chain.sh`
- Modify/verify: `hushine-deploy/scripts/runtime-indicator-v2-cutover-evidence.test.sh`
- Modify: `hushine-deploy/scripts/db/render-schema-bundle.sh`
- Modify generated: `hushine-deploy/db/generated/portfolio.sql`
- Modify generated: `hushine-deploy/db/generated/README.md`
- Modify: `hushine-deploy/db/README.md`
- Modify: `hushine-deploy/Makefile`

**Interfaces and exact acceptance entry points:**
- Fresh/bootstrap and populated V1→V2: `hushine-deploy/scripts/runtime-indicator-v2-db-smoke.sh`.
- Populated V1 fixture: `core-service/internal/storage/migrations/testdata/indicator_v1_fixture.sql`.
- 1023+2 Agent integration: `strategy-service/internal/runtimeagent/indicator_v2_integration_test.go::TestIndicatorV2Integration1023ThenTwoFrames`.
- Blocked worker: `strategy-service/scripts/runtime-agent-blocked-worker.test.sh` and `strategy-service/internal/runtimeagent/blocked_worker_integration_test.go::TestBlockedWorkerKeepsRuntimeHeartbeatAndCanBeReplaced`.
- Complete focused acceptance: `hushine-deploy/scripts/runtime-indicator-v2-smoke.sh` or `make test-runtime-indicator-v2`.
- Real chain/page: `runtime-indicator-v2-service-chain.sh start --phase post`, deterministic `await/advance/stop` subcommands, a fresh Browser-skill run, and `runtime-indicator-v2-cutover-evidence.test.sh --phase post`.
- This task uses new acceptance-owned databases, runtime, Session, browser evidence, and timestamps. Reusing or relabeling Task 11's pre-cutover evidence is a hard failure.

- [ ] **Step 1: Re-run isolated fresh and populated-upgrade database tests on the V1-free candidate**

`indicator_v2_bootstrap_test.go` and `indicator_v2_migration_test.go` use `HUSHINE_TEST_PG_ADMIN_DSN`, create unique databases prefixed `hushine_indicator_acceptance_`, and register cleanup immediately after creation. When `HUSHINE_TEST_DATABASE_NAME` is set, each test validates and owns that exact acceptance-prefixed name; this lets the smoke script run the fresh and upgrade cases separately. They may skip only when the admin DSN is absent during ordinary unit runs; `runtime-indicator-v2-db-smoke.sh` always supplies it, grep-fails on `SKIP`, and treats any connection/extension/migration failure as fatal.

The checked-in `testdata/indicator_v1_fixture.sql` does exactly this on a current baseline: drops only the two V2 indicator tables, recreates their former V1 `values_json` shape, inserts two definitions/two chunks, and deletes only `0002_runtime_indicator_v2.sql` from `schema_migrations`. Before applying `0002`, the test inserts a non-empty, foreign-key-valid owned row into every retained table—`users`, `portfolios`, `venues`, `venue_wallet_states`, `venue_events`, `strategies`, `portfolio_strategies`, `strategy_sessions`, `session_venues`, `portfolio_snapshots`, `notification_settings`, `notification_channels`, `notification_plans`, and `reconciliation_runs`—then records `(count, md5(string_agg(to_jsonb(row)::text ORDER BY stable_key)))` for each table except `strategy_sessions`, whose hash is the explicit pre-existing-column projection defined in Task 1. Empty-table hashes do not satisfy this acceptance check.

After the migration, require identical counts/hashes for all retained tables (`users`, `portfolios`, `venues`, `venue_wallet_states`, `venue_events`, `strategies`, `portfolio_strategies`, `strategy_sessions`, `session_venues`, `portfolio_snapshots`, `notification_settings`, `notification_channels`, `notification_plans`, and `reconciliation_runs`), zero old indicator rows, V2 columns/constraints/triggers/foreign keys, and exactly one `0002` ledger row. The `strategy_sessions` comparison hashes the explicit legacy-column projection on both sides and separately requires the new `indicator_finalization_pending` column/default plus false on all upgraded rows. A forced error after the migration body but before ledger insert must leave both schema and ledger at the pre-transaction state.

- [ ] **Step 2: Re-run the complete Agent integration matrix from the committed pre-cutover test**

Feed 1023 complete V2 frames through `Agent.HandleWorkerFrame`, wait for the two-second open flush, then feed sequences 1023 and 1024 without an intervening manual flush. The fake authenticated platform applies the same monotonic-save and guarded-finalize rules as core and records durable rows. Assert before terminal status:

```go
chunk0 := store.RequireChunk(streamKey, "alpha", 0)
chunk1 := store.RequireChunk(streamKey, "alpha", 1)
require.Equal(t, uint32(1024), chunk0.Count)
require.True(t, chunk0.Finalized)
require.Equal(t, uint32(1), chunk1.Count)
require.False(t, chunk1.Finalized)
require.Equal(t, uint64(1024), chunk1.StartSequence)
```

It is valid for save/finalize to use one or two platform requests; the test checks durable state and ordering, not request count. Send `finished`, assert chunk 1 finalizes at revision 1 before `UpdateSession(finished)` and worker acknowledgement. Re-run subtests for two interleaved symbols, same symbol/different intervals, concurrent Binance spot/futures stream keys, sparse/multiple markers, actual-time gaps, an exact immediate same-sequence/time/payload retry ignored without reapplying, same sequence/time with changed scalar or marker failed closed, older lower sequence rejected, all authenticated worker-final spellings including `recoverable` and `completed -> finished`, gRPC sink failure, and finalization retry.

- [ ] **Step 3: Run the integration tests and require GREEN before touching generated deployment output**

```bash
cd core-service
HUSHINE_TEST_PG_ADMIN_DSN='postgres://hushine-tech@192.168.88.10/postgres?sslmode=disable' \
  go test -tags=integration ./internal/storage/migrations -run 'IndicatorV2FreshBootstrap|IndicatorV1PopulatedUpgrade' -count=1 -v
cd ../strategy-service
go test ./internal/runtimeagent -run TestIndicatorV2Integration1023ThenTwoFrames -count=1 -v
```

Expected: PASS with no skip. No command targets the shared `portfolio` database,
and the same production-shaped K-line uses open time for V2 while preserving
close time for existing strategy/order semantics.

- [ ] **Step 4: Regenerate the tracked fresh bundle and document the destructive indicator-only upgrade**

Run `make db-schema-bundle`; do not edit generated SQL manually. `db/generated/portfolio.sql` must include `0000`, the V2 `0001`, and transactional `0002` exactly once. Update `db/generated/README.md` source inventory and `db/README.md` with:

- fresh one-shot command and idempotent second run;
- V1→V2 warning that only custom indicators are deleted and old sessions require rerun for indicator regeneration;
- retained table list;
- coordinated protocol-2 deployment order;
- rollback rule: restore service binaries/schema backup together, never run a mixed V1/V2 worker.

- [ ] **Step 5: Audit and run the ownership-safe database smoke script**

`runtime-indicator-v2-db-smoke.sh` defaults to `PGHOST=192.168.88.10`, `PGPORT=5432`, `PGUSER=hushine-tech`, and `PGDATABASE_ADMIN=postgres`; authentication comes from the operator's existing `PGPASSWORD`/`.pgpass`. It generates a safe run ID from PID plus 16 random hex characters and creates only:

```text
hushine_indicator_acceptance_<run>_fresh
hushine_indicator_acceptance_<run>_upgrade
hushine_indicator_acceptance_<run>_order_guard
```

The trap verifies every name against `^hushine_indicator_acceptance_[a-z0-9_]+$`, terminates connections, and drops only those three databases. It refuses to run if any target pre-exists and contains no `DROP DATABASE portfolio/order/control_panel` command.

The script:

1. Preflights that all three target names are absent. It builds
   `HUSHINE_TEST_PG_ADMIN_DSN`, runs the fresh test with
   `HUSHINE_TEST_DATABASE_NAME="${FRESH_DB}"` and the populated-upgrade test
   with `HUSHINE_TEST_DATABASE_NAME="${UPGRADE_DB}"`, both with
   `-tags=integration`, and grep-fails on `SKIP`. Each integration test alone
   creates and drops its owned database; after each returns, the script proves
   that name is absent. The script then creates `FRESH_DB`, `UPGRADE_DB`, and
   `ORDER_GUARD_DB` exactly once for the command-level checks below.
2. Reuses `"${FRESH_DB}"`; runs
   `PGDATABASE_PORTFOLIO="${FRESH_DB}" go run ./cmd/ensure-portfolio-db` twice
   and asserts ledger/schema equality after the second run.
3. Applies `db/generated/portfolio.sql` to the same fresh DB and asserts it is idempotent.
4. Reuses `"${UPGRADE_DB}"`; applies the current baseline, loads
   `indicator_v1_fixture.sql`, records retained hashes, then runs
   `PGDATABASE_PORTFOLIO="${UPGRADE_DB}" go run ./cmd/ensure-portfolio-db`; it
   asserts only indicator data disappeared.
5. Reuses `"${ORDER_GUARD_DB}"`; applies `db/generated/order.sql`, inserts an
   owned order and fill, records hashes, runs the portfolio upgrade, and proves
   the separate order/fill hashes are unchanged.
6. Before starting core, inserts an acceptance-owned user, Portfolio, strategy,
   and Session into `"${FRESH_DB}"` through a parameterized fixture transaction,
   using unique run-derived IDs and satisfying every ownership/foreign-key fact;
   it records those IDs in mode-0600 shell variables/artifacts and deletes no
   shared row. It then starts the built core-service on an ephemeral loopback
   port with a temporary config targeting `"${FRESH_DB}"`/`"${ORDER_GUARD_DB}"`,
   waits for gRPC readiness, calls `ListStrategyIndicatorsV2` with that exact
   user/Session identity, and requires a valid empty definition list. It also
   calls GetSession and proves `indicator_finalization_pending=false`. Cleanup
   stops only that PID and deletes its temporary config directory; dropping the
   owned database removes the fixture.

No branch treats unreachable `.10`, missing TimescaleDB, a skipped test, or a failed cleanup as success.

- [ ] **Step 6: Run the complete focused smoke and Make target**

`runtime-indicator-v2-smoke.sh` runs, in this exact order:

```bash
./scripts/runtime-indicator-v2-db-smoke.sh
(cd ../control-panel-service && go test ./internal/runtimechannel -run 'Indicator.*V2|SessionFinalizationPending' -count=1 -v)
(cd ../strategy-service && go test ./internal/runtimeagent -run 'TestIndicatorV2Integration1023ThenTwoFrames|SessionLifecycle|RetryPending|UnexpectedExit|RestartSession' -count=1 -v)
(cd ../strategy-service && HUSHINE_BLOCKED_WORKER_SECONDS=660 HUSHINE_BLOCKED_WORKER_OBSERVE_SECONDS=600 ./scripts/runtime-agent-blocked-worker.test.sh)
(cd ../strategy-service && bash scripts/start-bare-runtime-debugpy.test.sh)
(cd ../strategy-service && ./scripts/runtime-agent-platform.test.sh)
(cd ../gateway/quant-handler && go test ./internal/app -run 'StrategyIndicator.*V2|Session.*FinalizationPending' -count=1 -v)
(cd ../gateway/quant-frontend && node scripts/session-indicator-data.test.mjs && node scripts/runtime-status.test.mjs && npm run test:session-custom-indicators && npm run build)
```

Resolve all paths from the script's own directory, preserve the caller's PG env, and fail on the first error. Add:

```make
.PHONY: test-runtime-indicator-v2
test-runtime-indicator-v2:
	@bash scripts/runtime-indicator-v2-smoke.sh
```

- [ ] **Step 7: Finish every tracked artifact and commit the final candidate before any post-cutover gate**

Regenerate/review the deployment bundle and commit every remaining tracked
acceptance/generated/documentation change now, before starting the post-cutover
stack:

```bash
cd hushine-deploy
git diff --check
make db-schema-bundle
before_bundle="$(shasum -a 256 db/generated/portfolio.sql db/generated/README.md)"
make db-schema-bundle
after_bundle="$(shasum -a 256 db/generated/portfolio.sql db/generated/README.md)"
test "$before_bundle" = "$after_bundle"
git add Makefile scripts/runtime-indicator-v2-db-smoke.sh scripts/runtime-indicator-v2-smoke.sh scripts/runtime-indicator-v2-service-chain.sh scripts/runtime-indicator-v2-cutover-evidence.test.sh scripts/db/render-schema-bundle.sh db/generated/portfolio.sql db/generated/README.md db/README.md docs/superpowers/plans/2026-07-14-runtime-indicator-v2-lifecycle.md docs/superpowers/specs/2026-07-14-runtime-indicator-v2-lifecycle-design.md
git diff --cached --check
git commit -m "test: verify runtime indicator v2 deployment"
```

Require every affected repository clean, then atomically write the complete
committed SHA map to the ignored post-cutover state directory. Any staged,
unstaged, or untracked non-ignored file fails; the strategy integration fixture
must be an ancestor of the recorded strategy-service SHA:

```bash
state_dir="$(pwd)/.superpowers/sdd/indicator-v2-postcutover"
mkdir -p "$state_dir" && chmod 700 "$state_dir"
for repo in core-service control-panel-service strategy-library strategy-service strategy-debugger-cli gateway/quant-handler gateway/quant-frontend hushine-deploy; do
  test -z "$(git -C "../$repo" status --porcelain --untracked-files=normal)" || exit 1
done
bash scripts/runtime-indicator-v2-cutover-evidence.test.sh \
  --write-current-shas "$state_dir/final-shas.json" --require-clean
```

Only after that final commit and SHA freeze, run every repository's normal gate
plus focused acceptance.

From the workspace root, with `.10` credentials available through libpq:

```bash
cd core-service && make proto && go test ./... -count=1 && go vet ./...
cd ../control-panel-service && go test ./... -count=1 && go vet ./...
cd ../strategy-service && ./generate_proto.sh && PYTHONPATH=.:../strategy-library uv run --frozen --extra dev pytest tests/ -q && go test ./... -count=1 && go vet ./... && bash scripts/start-bare-runtime-debugpy.test.sh && bash scripts/runtime-agent-platform.test.sh
cd ../gateway/quant-handler && go test ./... -count=1 && go vet ./...
cd ../quant-frontend && npm run build && for test_file in scripts/*.test.mjs; do node "${test_file}" || exit 1; done
cd ../../hushine-deploy && make db-schema-bundle && make test-runtime-indicator-v2
cd ..
set +e
openspec_output="$(openspec validate --all --strict --no-interactive 2>&1)"
openspec_status=$?
set -e
printf '%s\n' "$openspec_output"
test "$openspec_status" -eq 0
! grep -Fq 'No items found to validate' <<<"$openspec_output"
```

Expected: all PASS, no skips in the focused smoke, and a second `make db-schema-bundle` produces no diff.

- [ ] **Step 8: Repeat the real service-chain and real-page proof with fresh post-cutover identities**

Start a new supervisor-owned stack and Session from the clean SHA map; do not
copy Task 11 evidence:

```bash
cd hushine-deploy
state_dir="$(pwd)/.superpowers/sdd/indicator-v2-postcutover"
bash scripts/runtime-indicator-v2-service-chain.sh start --phase post \
  --state-dir "$state_dir" --expected-shas "$state_dir/final-shas.json"
bash scripts/runtime-indicator-v2-service-chain.sh await open-1023 --state-dir "$state_dir"
```

Using `browser:control-in-app-browser`, repeat every Task 11 page action against
the new URL/Session. At the pinned `open-1023` barrier, assert exact DB/API/page
count 1023 and open tail. Then run the same deterministic transitions used
pre-cutover:

```bash
bash scripts/runtime-indicator-v2-service-chain.sh advance 1025 --state-dir "$state_dir"
bash scripts/runtime-indicator-v2-service-chain.sh await finalized-1024-plus-tail --state-dir "$state_dir"
bash scripts/runtime-indicator-v2-service-chain.sh advance 2049 --state-dir "$state_dir"
bash scripts/runtime-indicator-v2-service-chain.sh await two-full-plus-tail --state-dir "$state_dir"
```

Verify BUY/SELL marker at candle open time with the close-time order fact
preserved, exact 1024-finalized plus one-open at 1025, two immutable full chunks
plus a one-point tail at 2049, two refreshes with no finalized movement, V2
network fields, and zero unexpected console/network errors. Write a fresh
`<state-dir>/browser.json`. Run the no-V1 scan and Runtime dependency combined
descriptor/value/checksum gate now, append their SHA-bound logs, then stop the
owned supervisor and require cleanup proof in `chain.json`:

```bash
bash scripts/runtime-indicator-v2-service-chain.sh stop --state-dir "$state_dir"
```

Only after all post-cutover database/focused/service-chain/browser/no-V1/
dependency checks and cleanup are complete, write the final code seal:

```bash
bash scripts/runtime-indicator-v2-cutover-evidence.test.sh \
  --phase post \
  --expected-shas "$state_dir/final-shas.json" \
  --chain "$state_dir/chain.json" \
  --browser "$state_dir/browser.json" \
  --seal "$state_dir/seal.json" \
  --check-current-shas
```

Compare pre/post assertion sets (not volatile IDs/timestamps) and require them
to be identical. Final descriptors must retain all dependency fields, expose V2
field 21, and reserve 15. Any failure leaves the
coordinated candidate non-push/non-deploy and requires a fix plus fresh pre and
post evidence from the new tree.

- [ ] **Step 9: Prove the final seal still names the complete clean committed tree**

Immediately after sealing, recompute every SHA and compare it to
`final-shas.json`; require every affected repository clean and the integration
fixture an ancestor of the sealed strategy-service commit:

```bash
cd hushine-deploy
bash scripts/runtime-indicator-v2-cutover-evidence.test.sh \
  --phase post --seal .superpowers/sdd/indicator-v2-postcutover/seal.json \
  --expected-shas .superpowers/sdd/indicator-v2-postcutover/final-shas.json \
  --check-current-shas --require-clean
cd ../strategy-service
git log -1 --format=%H -- internal/runtimeagent/indicator_v2_integration_test.go tests/strategies/indicator_v2_open_time_cutover.py
git diff --check -- internal/runtimeagent/indicator_v2_integration_test.go tests/strategies/indicator_v2_open_time_cutover.py
test -z "$(git status --short -- internal/runtimeagent/indicator_v2_integration_test.go tests/strategies/indicator_v2_open_time_cutover.py)"
```

- [ ] **Step 10: Permit no tracked commit or product change after the final code seal**

There is no commit step after Step 8. Any tracked product, generated,
acceptance, test, plan, or documentation change—or any repository SHA change—
invalidates the post-cutover chain/browser/current-tree assertions and final
seal. Commit the necessary fix, rerun Step 7's clean SHA freeze and post-commit
gates (without creating an empty commit), regenerate `final-shas.json`, and
rerun Steps 8–9 from the new clean tree. The historical pre-cutover seal remains bound to
its V1-coexistence tree and is never relabelled; the final code seal always
names the exact post-cutover commits presented to the later full-system gate.

---

## Indicator Focused Cutover Checkpoints (Non-Release)

Record separate pre-cutover and post-cutover seal hashes, every independent
repository SHA, acceptance-owned database names and cleanup proof, distinct
runtime/Session/browser identities, the 1023+2 and 2049 durable summaries, the
open-time marker/close-time order comparison, conflicting-duplicate failure,
explicit `recoverable` and `completed -> finished` terminal results, the full
600-second blocked-worker heartbeat count/max-gap/replacement generation,
Windows cross-build artifacts, the successful native Windows workflow URL/
artifact for the exact strategy-service SHA, both tracked strategy-service
shell-test results, the strict non-empty OpenSpec validation result, and the
frontend executable result. Unit tests, a fake Agent platform, cross-build
output, or only one side of the cutover never seals this checkpoint.

Completing this implementation plan means only that the V1-free candidate may
enter the later full-system acceptance plan. It is **not** release acceptance
and does not authorize push/deploy by itself. Before any release/push claim,
`docs/superpowers/plans/2026-07-14-full-system-real-page-acceptance.md` must
produce fresh post-cutover evidence for these exact mandatory scenario IDs:

```text
browser-running-indicator
indicator-1023-plus-2
indicator-repeat-idempotency
indicator-sparse-marker-time
indicator-terminal-tail
durable-reconciliation
coverage-finalization
```

`browser-running-indicator` must include the real 2049-bar two-full-plus-tail
page result; `indicator-repeat-idempotency` must replay the complete 1023-frame
state (not only the last frame); `durable-reconciliation` must compare accepted
bars, candle open times, close-time order/fill facts, marker sequence/time, DB,
handler JSON, and chart output. All Task 12 commands, both cutover seals, and
the native Windows gate require fresh output from the final tree. Only the
full-system plan's later coordinated delivery gate may authorize remote push or
deployment.
