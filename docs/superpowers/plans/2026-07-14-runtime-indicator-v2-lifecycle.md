# Runtime Indicator V2 and Worker Lifecycle Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace count-inferred custom indicators with a typed, actual-time V2 protocol and persistence model, then make every worker termination path durably finalize the last contiguous indicator bar before publishing its desired terminal state or replacing the worker; if safe drain/finalization cannot complete, publish `recoverable`, retain the tail, and finish it by retry.

**Architecture:** The Python session worker assigns a zero-based sequence to every accepted market bar and sends one typed V2 frame per stream/bar. The Go runtime-agent validates the stream clock, advances every declared series, owns deterministic 1024-bar chunks, and persists open revisions plus explicit finalization operations through RuntimeChannel to core-service. Core-service stores actual time arrays, nullable scalar arrays, and typed markers in a V2-only schema; the gateway and frontend pass/render those fields without inferring time from interval or offset. A generation-aware lifecycle coordinator serializes final status, unexpected exit, protocol failure, and Bare restart so no old worker can mutate a replacement session.

**Tech Stack:** Protocol Buffers/gRPC, Python 3.13 with pytest, Go 1.26 with `google.golang.org/protobuf` and `github.com/lib/pq`, PostgreSQL/TimescaleDB, React 19/TypeScript 5.7, lightweight-charts 5.2, Node executable test scripts, Docker/runtime coverage tooling.

## Global Constraints

- The coordinated worker protocol version is exactly `2`; a missing or different `WorkerHello.protocol_version` fails with code `RUNTIME_WORKER_PROTOCOL_UNSUPPORTED` before `StartSession` is sent.
- V1 custom-indicator protobuf fields, RPC names, domain types, repository paths, JSON envelopes, and frontend reconstruction code are removed at cutover; removed protobuf field number `15` is reserved and never reused.
- Existing custom-indicator definitions and chunks are deleted; sessions, portfolios, venues, strategies, orders, fills, wallet snapshots, notifications, and reconciliation records retain every pre-existing field value and row. The sole additive Session field is `indicator_finalization_pending`, backfilled/defaulted false and changed only by the lifecycle coordinator.
- `chunk_size` is exactly `1024`; `chunk_index = stream_sequence / 1024`, `offset = stream_sequence % 1024`, and a full chunk becomes immutable immediately.
- Open chunks flush every `2s`; full chunks flush immediately; all network I/O occurs outside indicator-buffer locks; one session flush owner serializes periodic, boundary, terminal, and restart persistence.
- Every accepted bar emits one frame even with no scalar and no marker; a failed user callback discards partial indicator writes and emits one empty frame for that bar before existing guarded/fatal handling.
- Sequence is independent per exact `stream_key`; actual `market_time_ms` is durable truth, and time gaps are valid when sequence remains contiguous.
- An immediate duplicate of the last accepted `(session_id, stream_key, stream_sequence)` with the same `market_time_ms` is idempotently ignored, exactly as approved; its samples are never applied a second time. A duplicate with a different time, any sequence older than the immediately previous sequence, or a gap stops that generation and makes the session recoverable. Persistence-level retries still require byte-equivalent same-revision chunks before core treats them as idempotent.
- Indicator definitions are immutable within a session; changing any key/type/pane/configuration requires a new session, including Bare hot reload.
- Every `finished`, `failed`, `stopped`, `stop_failed`, max-loss, Bare restart,
  protocol failure, unexpected-exit, and Agent shutdown path finalizes before its
  desired terminal state. A frame-drain or persistence failure instead publishes
  `recoverable`, retains buffers for retry, never finalizes while an admitted
  handler can still mutate them, and never returns a success acknowledgement.
- Runtime heartbeat and RuntimeChannel stay alive while user Python code is blocked; local worker IPC remains loopback TCP and must compile/run on Windows without Unix sockets, POSIX-only paths, or Unix-only signals.
- Route platform calls only through authenticated RuntimeChannel methods; a session is still routed only by `runtime_id`, and no internal database/Kafka/order address is exposed to self-hosted or Bare workers.
- Generated SQL is regenerated from service-owned migrations; generated protobuf files are regenerated from their authoritative `.proto` files and never hand-edited.
- Preserve dirty work and commit only owned files inside each independent repository. Every `git add` block below is an owned-file inventory, not permission to stage a pre-existing dirty path wholesale: capture `git status --short` before each task, use `git add -p` for any already-dirty path, stage generated artifacts by exact filename, and inspect `git diff --cached --check` plus `git diff --cached` before every commit.

---

## Execution Order

The full-system acceptance Task 0 freezes repositories and current Notion
requirements first. Then complete the Runtime dependency-contract plan, execute
this plan's physically ordered Tasks 1–12, rerun the dependency plan's focused
gate on the combined descriptors/runtime tree, and only then begin the Binance
Spot plan. Do not run this plan standalone against a pre-dependency tree.

Within this plan execute Tasks 1–12 strictly: core contract/schema,
authenticated control proxy, worker protocol generation/gate, Python emission,
Go chunking/persistence, gateway, lifecycle coordination, blocked-worker/
Windows safety, strategy-template regression, frontend rendering, V1 removal,
and deployment/integration verification. Do not start a task before its stated
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
- `cmd/ensure-portfolio-db/main.go`, `cmd/ensure-portfolio-db/main_test.go` — migration body and ledger entry committed in one database transaction.
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
- `strategy_service/strategy/base.py` — per-stream sequence assignment, empty failed-bar emission, partial-write discard, callback error propagation, and hot-reload definition immutability.
- `strategy_service/grpc_server.py` — first-frame definitions and V2 sink signature.
- `strategy_service/worker_agent_client.py` — protocol-2 hello and typed V2 frame encoding.
- `strategy_service/session_worker_entry.py` — final acknowledgement/error propagation remains worker exit gate.
- `strategy_service/indicators.py` — typed marker fields and removal of the obsolete Python chunker after hosted V2 cutover.
- `tests/test_runtime_worker_proto.py`, `tests/test_worker_agent_client.py`, `tests/test_strategy_indicators.py`, `tests/test_grpc_server.py`, `tests/test_session_worker_entry.py` — Python protocol/sequencing/error tests.
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
- `scripts/runtime-indicator-v2-smoke.sh`, `Makefile` — exact focused 1023+2, blocked-worker, Windows, gateway, and frontend acceptance entry point.

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

- [ ] **Step 8: Make portfolio migration application atomic and acceptance-database aware**

Change the runner so SQL execution and ledger insertion share one transaction:

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
git add proto/portfolio_service.proto gen/portfoliov1/portfolio_service.pb.go gen/portfoliov1/portfolio_service_grpc.pb.go internal/domain/strategy_indicator.go internal/domain/model.go internal/repository/repository.go internal/repository/timescale.go internal/repository/strategy_indicator_test.go internal/repository/session_test.go internal/service/grpc.go internal/service/grpc_strategy_indicator_test.go internal/service/grpc_strategy_indicator_proto_test.go internal/service/grpc_strategy_test.go internal/storage/migrations/0001_current_schema_baseline.sql internal/storage/migrations/0002_runtime_indicator_v2.sql internal/storage/migrations/baseline_contract_test.go internal/storage/migrations/migration_contract_test.go internal/storage/migrations/indicator_v2_migration_test.go internal/storage/migrations/indicator_v2_bootstrap_test.go internal/storage/migrations/testdata/indicator_v1_fixture.sql cmd/ensure-portfolio-db/main.go cmd/ensure-portfolio-db/main_test.go tests/repository_test.go internal/service/grpc_portfolio_meta_test.go
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

During this task, keep the V1 `indicator_frame=15` field only long enough for the current Go sync code to compile; mark it deprecated. Task 5 removes it and adds `reserved 15` in the same strategy-service repository before final verification.

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
```

Add `IndicatorFrameV2 indicator_frame_v2 = 21` to `WorkerFrame.payload`; 21 is new and does not collide with notification/wallet/final/error/log fields 16–20.

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
- Modify: `strategy-service/strategy_service/strategy/base.py`
- Modify: `strategy-service/strategy_service/grpc_server.py`
- Modify: `strategy-service/strategy_service/worker_agent_client.py`
- Modify: `strategy-service/strategy_service/indicators.py`
- Modify: `strategy-service/tests/test_strategy_indicators.py`
- Modify: `strategy-service/tests/test_grpc_server.py`
- Modify: `strategy-service/tests/test_worker_agent_client.py`

**Interfaces:**
- Consumes: `IndicatorFrameV2`/`IndicatorSampleV2` from Task 3 and the existing `IndicatorDefinition`/`IndicatorWriter` user API.
- Produces: `BaseStrategy.on_indicator_frame(stream_key: str, stream_sequence: int, market_time_ms: int, interval_ms: int, frame: IndicatorFrame)`, exactly one callback per accepted indicator-bearing stream/bar, with first-frame-only definitions at the gRPC sink.

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

- [ ] **Step 2: Run focused Python tests and verify RED**

Run:

```bash
cd strategy-service
PYTHONPATH=.:../strategy-library uv run --frozen --extra dev pytest \
  tests/test_strategy_indicators.py tests/test_grpc_server.py tests/test_worker_agent_client.py -q
```

Expected: FAIL because the callback has no sequence, failed callbacks emit no frame, and hot reload accepts changed indicators.

- [ ] **Step 3: Assign sequence in `BaseStrategy`, not in the Agent or chunker**

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
        self.on_indicator_frame(stream_key, sequence, market_time_ms, interval_ms, frame)
```

Do not swallow a sink exception: wrap it as `RuntimeError("indicator V2 transport failed: ...")` so the session fails instead of silently creating a sequence hole.

- [ ] **Step 4: Emit an empty bar frame after discarding partial failed output**

In `running_strategy`, compute `stream_key`, `market_time_ms`, and `interval_ms` before user code. On user exception:

```python
self._indicator_writer.reset_bar()  # discard values/markers written before the exception
self._drain_indicator_frame(stream_key, market_time_ms, interval_ms)  # emits empty frame and advances once
```

Then apply the existing hot-reload guarded return or fatal `StrategyUserCodeError`. On success call `_drain_indicator_frame` exactly once. There must be no `finally` that can emit a second frame.

- [ ] **Step 5: Make indicator declarations part of the hot-reload identity**

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

- [ ] **Step 6: Encode typed sparse V2 samples**

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

- [ ] **Step 7: Send definitions on sequence zero only**

Update `_install_indicator_collection.on_frame` signature. For every stream, require `stream_sequence==0` on its first callback and attach definitions then; later callbacks attach `[]`. If the first callback for a stream is nonzero, raise `RuntimeError` instead of marking it sent.

Remove the agent-managed path's unused `portfolio_client` acquisition: when `_indicator_frame_sink` is callable, it must not instantiate the direct portfolio client. Retain the non-agent direct path until Task 11 removes the obsolete Python chunk writer.

- [ ] **Step 8: Run Python focused and full verification**

Run:

```bash
PYTHONPATH=.:../strategy-library uv run --frozen --extra dev pytest \
  tests/test_strategy_indicators.py tests/test_grpc_server.py tests/test_worker_agent_client.py \
  tests/test_session_worker_entry.py -q
PYTHONPATH=.:../strategy-library uv run --frozen --extra dev pytest tests/ -q
```

Expected: PASS; the sparse-frame test observes a V2 frame for every accepted bar and only sequence-zero frames contain definitions.

- [ ] **Step 9: Commit Python V2 sequencing**

```bash
git add strategy_service/strategy/base.py strategy_service/grpc_server.py strategy_service/worker_agent_client.py strategy_service/indicators.py tests/test_strategy_indicators.py tests/test_grpc_server.py tests/test_worker_agent_client.py tests/test_session_worker_entry.py
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
- Modify: `strategy-service/proto/runtime_worker.proto`
- Regenerate: `strategy-service/gen/runtimeworkerv1/runtime_worker.pb.go`
- Regenerate: `strategy-service/gen/runtimeworkerv1/runtime_worker_grpc.pb.go`
- Regenerate: `strategy-service/strategy_service/gen/runtime_worker_pb2.py`
- Regenerate: `strategy-service/strategy_service/gen/runtime_worker_pb2_grpc.py`
- Modify: `strategy-service/tests/test_runtime_worker_proto.py`

**Interfaces:**
- Consumes: `runtimeworkerv1.IndicatorFrameV2`; core V2 save/finalize protobufs; platform methods from Task 2.
- Produces: `ReceiveFrame(IndicatorFrameIdentity, *rwv1.IndicatorFrameV2) error`,
  `FlushSession(ctx, sessionID) error`, `FinalizeSession(ctx, sessionID) error`,
  and typed `*IndicatorProtocolError` with code
  `RUNTIME_INDICATOR_PROTOCOL_ERROR`. The trusted identity carries the admitted
  connection's Session ID and generation; payload IDs are never routing truth.

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
ignore immediate duplicate seq=0,time=1000 even if its repeated payload differs; do not apply it
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
}
```

`indicatorStreamClock.Classify(sequence,time)` is bounded regardless of Session length and does not mutate state. `Commit(sequence,time)` advances only after a new expected frame's definitions/samples have validated:

```go
switch {
case c.HasLast && c.NextSequence > 0 && sequence == c.NextSequence-1 && time == c.LastTimeMS:
    return IndicatorFrameDuplicate, nil
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
`NextSequence` and stores `LastTimeMS`/the first interval. Calling it for a
duplicate or rejected frame is a test failure.

For every accepted frame, append its time to every definition's chunk. Append a cloned scalar pointer or nil for line/histogram; marker series keep an empty scalar slice and append only typed markers. Set `Revision=uint64(len(TimesMS))`, `StartSequence=uint64(chunkIndex)*1024`, and derive marker offset from sequence. Do not derive time or offset from how many samples arrived.

- [ ] **Step 5: Implement immutable definition registration and frame-wide advancement**

`indicatorSessionState` owns `streams map[string]*indicatorStreamState`; each
stream owns the clock, deterministic serialized first definitions, and series.
Before lookup/mutation, compare the trusted `IndicatorFrameIdentity` with the
payload and cached Run facts: Session ID, worker connection, Runtime, and
generation must agree. A stale generation claiming a replacement Session,
another live Session on the same Runtime, or a cross-Session platform/order/
wallet/final frame is rejected before admission and cannot create a buffer.
Task 7 wires this identity to `WorkerConnection` and repeats these cases against
the real Agent handlers.

Classify sequence/time first: an approved immediate same-time duplicate returns
without reading/applying definitions or samples; a lower/gap/different-time
duplicate fails. For an expected new frame, sequence zero requires a non-empty
definition list. Later omitted definitions reuse the first list; later present
definitions must satisfy `proto.Equal` element-for-element. Reject duplicate
definition keys and duplicate sample keys; one marker sample may still contain
multiple markers. Samples are indexed once and validated against registered
keys/types, then the clock commits and buffers advance atomically, so a rejected
frame has no partial effect.

Return:

```go
type IndicatorFrameIdentity struct {
    SessionID string
    RuntimeID string
    WorkerID  string
    Generation uint64
}

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
`FlushSession`; a full boundary sets a durable per-session `flushPending` flag
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

- [ ] **Step 8: Remove the V1 worker field and reserve its number**

Now that all Go/Python code uses V2, change the worker oneof to:

```protobuf
message WorkerFrame {
  string frame_id = 1;
  reserved 15;
  reserved "indicator_frame";
  oneof payload {
    WorkerHello hello = 10;
    WorkerHeartbeat heartbeat = 11;
    SessionProgress progress = 12;
    PlatformCall platform_call = 13;
    PlatformCallResult platform_call_result = 14;
    NotificationEvent notification = 16;
    WalletSnapshot wallet_snapshot = 17;
    FinalStatus final_status = 18;
    WorkerError worker_error = 19;
    LogEvent log_event = 20;
    IndicatorFrameV2 indicator_frame_v2 = 21;
  }
}
```

Delete `IndicatorValue` and `IndicatorFrame`; regenerate with `./generate_proto.sh`. Add descriptor tests asserting field 15 is absent, field 21 is `indicator_frame_v2`, and no generated V1 class exists.

- [ ] **Step 9: Run focused V2 matrix and race-oriented serialization tests**

Run:

```bash
go test ./internal/runtimeagent -run 'IndicatorBufferV2|IndicatorSyncV2|IndicatorProtocol' -count=1 -v
go test -race ./internal/runtimeagent -run 'IndicatorSyncV2.*Concurrent|IndicatorSyncV2.*Flush' -count=1
PYTHONPATH=.:../strategy-library uv run --frozen --extra dev pytest tests/test_runtime_worker_proto.py -q
```

Expected: PASS. The race test records maximum concurrent platform writes per session as exactly 1.

- [ ] **Step 10: Commit Go V2 chunking and final worker proto cutover**

```bash
git add internal/runtimeagent/indicator_buffer.go internal/runtimeagent/indicator_buffer_test.go internal/runtimeagent/indicator_sync.go internal/runtimeagent/indicator_sync_test.go internal/runtimeagent/agent.go internal/runtimeagent/agent_test.go proto/runtime_worker.proto gen/runtimeworkerv1/runtime_worker.pb.go gen/runtimeworkerv1/runtime_worker_grpc.pb.go strategy_service/gen/runtime_worker_pb2.py strategy_service/gen/runtime_worker_pb2_grpc.py tests/test_runtime_worker_proto.py
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
- `WorkerStartSpec.Generation uint64` is allocated monotonically by
  `WorkerManager`; token, PID, canonical `StartSession.session_id`, process exit,
  and stream close all carry the same generation. Per the dependency plan, a
  Run has no second random real-session alias; any one-shot Validate/Preview
  internal identity remains distinct and never becomes a durable Session.
- `WorkerManager.SetExitHandler(func(WorkerExitEvent))` reports process completion but never publishes session state itself.
- `WorkerIPCServer.SetStreamClosedHandler(func(WorkerStreamClosedEvent))` reports closure after its receive loop stops and all previously received frames have returned from `WorkerFrameHandler`.
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

- [ ] **Step 1: Write generation/alias tests before changing the registry**

Extend the expected and active identities to include generation and verify these cases:

```go
first, _ := manager.PrepareSessionWorker("pending-a")
second, _ := manager.PrepareSessionWorker("pending-b")
if first.Generation == 0 || second.Generation <= first.Generation { t.Fatalf("non-monotonic generations") }

registry.AdmitWorker(first.SessionID, first.Token, 101, first.Generation)
registry.ForgetWorkerIdentity(first.SessionID, 101, first.Token, first.Generation-1)
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
    PendingSessionID string
    SessionID        string
    Generation       uint64
    PID              int64
    ExitErr          error
    StopRequested    bool
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
    PendingSessionID string
    SessionID        string
    Generation       uint64
    Err              error
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

Add `nextGeneration atomic.Uint64` to `WorkerManager`; `PrepareSessionWorker` allocates once and copies the value into `WorkerStartSpec` and `ManagedWorker`. Replace the registry's token-only expected map with an identity record. Every admit, alias, lookup, forget, send, and callback must compare generation as well as token/PID.

Change the frame handler boundary to:

```go
type WorkerConnection struct {
    PendingSessionID string
    SessionID        string
    Generation       uint64
    PID              int64
}

type WorkerFrameHandler func(
    context.Context, WorkerConnection, *rwv1.WorkerFrame,
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
| user-code error | `failed` | `failed` |
| user stop | `stopped` | `stopped` |
| stop failure | `stop_failed` | `stop_failed` |
| max-loss close succeeds | `stopped`, reason contains `max_loss_close_triggered` | `stopped` |
| max-loss close fails | `stop_failed`, reason contains `max_loss_close_triggered` | `stop_failed` |
| worker protocol violation | protocol error | `recoverable` |
| running worker exits without final status | process + stream close | `recoverable` |
| Bare local restart | restart request | old session `recoverable` |
| Agent SIGTERM/shutdown | Agent shutdown request | active session `recoverable` after tail finalization |

For every row assert the call order begins `close-admission, finalize, update-session`; a worker final-status path then does `send-ack, mark-acknowledged`, and process/stream cleanup ends with `forget`. `failed`, `stopped`, and `stop_failed` must not bypass finalization.

Add a deliberately blocked admitted-frame case. After terminal work closes admission, a later frame is rejected, and before the blocked handler releases there is no `FinalizeSession`, terminal `UpdateSession`, success acknowledgement, or forget. After release, assert the exact tail finalizes before the terminal update. Add a drain-timeout variant: before the injected timeout fires there is no durable call; when it fires, record stable `WORKER_FRAME_DRAIN_TIMEOUT`, retain lifecycle/indicator/registry state, perform no finalization while mutation remains possible, and persist Session status `recoverable` with `indicator_finalization_pending=true` and the original desired status/reason embedded in the safe failure reason. There is no success acknowledgement or forget. A retry after release drains and finalizes the exact retained tail, keeps the already-published status `recoverable`, then performs a metadata-only `UpdateSession(recoverable, indicator_finalization_pending=false)` before cleanup; it must not perform a second terminal status transition. If that flag-clear write fails, retain the lifecycle record and retry only the clear. If the timeout's initial recoverable update itself fails, retry that update independently without ever finalizing before drain.

Add a real Agent protocol-error case where the failing handler owns the lease:
it must claim/queue, release, and only then drive; prove no self-deadlock or
double release. Add a restart race where process-exit and stream-close callbacks
both arrive before the restart goroutine resumes: they must attach reap facts to
the already claimed Bare-restart record and never create unexpected-exit.

Repeat every row with indicator finalization failure. Assert one `UpdateSession(recoverable, indicator_finalization_pending=true)` attempt with the original status/reason embedded in the error, an `AgentError{Code:"INDICATOR_FINALIZATION_FAILED"}` instead of an empty success acknowledgement when a worker is waiting, and no buffer forget. Repeat a normal row with `UpdateSession` failure and assert `SESSION_TERMINAL_PERSIST_FAILED`, no success acknowledgement, and retained memory.

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
    SessionID, FrameID, DesiredStatus, Reason string
    Generation, BarsProcessed uint64
    Source TerminalSource
    Send func(*rwv1.AgentFrame) error
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

Each lifecycle record stores which durable steps are acknowledged (`frameDrained`, `indicatorFinalized`, `sessionStatusPersisted`, `finalizationPendingCleared`), whether a drain timeout forced recoverable status, the effective durable status, and process/stream reap facts. `RunRetryLoop` is started by `cmd/runtime-agent/main.go` with the Agent context and a two-second tick. A tick claims one failed record, reruns only safe unacknowledged steps, and releases the claim before moving on. It may persist a pending `recoverable` status without frame drain, but the per-session flush owner may finalize only after `frameDrained=true`. If the first pass already persisted `recoverable` because drain or indicator finalization failed, later drain/finalization success does not promote the Session to the original `finished`/`failed`/`stopped`; it makes the retained tail durable, clears the pending fact while leaving status recoverable, and only then permits generation cleanup. If no fallback status was required and no status was persisted, the retry persists the original desired status with pending=false after finalization succeeds. Cancellation leaves records intact until normal Agent shutdown handling reports them. Tests use an injected tick channel and never sleep.

Agent owns all terminal updates. Preserve the existing Python guard that skips `_persist_session_status` for agent-managed terminal sessions; add tests for all five terminal strings so Python cannot race the Agent's update.

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

Add `Agent.Shutdown(ctx)`: while RuntimeChannel/platform persistence is still
available, atomically claim `TerminalAgentShutdown` for every active generation,
close admission, stop and `Cmd.Wait`/stream-reap each worker, drive exact-tail
finalization, and persist recoverable. Only after all bounded attempts (or
retained explicit retryable failure records) may main cancel RuntimeChannel and
gRPC. SIGTERM tests cover a normal and blocked worker plus finalization/status
failure; no disappeared worker leaves a durable running Session.

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
git add internal/runtimeagent/session_lifecycle.go internal/runtimeagent/session_lifecycle_test.go internal/runtimeagent/worker_server.go internal/runtimeagent/worker_server_test.go internal/runtimeagent/worker_ipc_server.go internal/runtimeagent/worker_ipc_server_test.go internal/runtimeagent/worker_manager.go internal/runtimeagent/worker_manager_test.go internal/runtimeagent/agent.go internal/runtimeagent/agent_test.go cmd/runtime-agent/main.go cmd/runtime-agent/main_test.go strategy_service/grpc_server.py tests/test_grpc_server.py tests/test_session_worker_entry.py
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

### Task 11: Remove the Coordinated V1 Indicator Surface and Obsolete Direct Python Persistence

**Files:**
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

**Interfaces:**
- The only portfolio indicator RPCs after this task are `SaveStrategyIndicatorsV2`, `FinalizeStrategyIndicatorChunksV2`, `ListStrategyIndicatorsV2`, and `ListStrategyIndicatorChunksV2`.
- The only worker wire payload is `indicator_frame_v2=21`; field 15 and name `indicator_frame` remain reserved.
- Python retains the user-facing in-memory `IndicatorFrame`/`IndicatorWriter` API, but removes `IndicatorChunkBuffer` and the direct `portfolio.SaveStrategyIndicators` branch; all runtime persistence goes through the Go Agent.

- [ ] **Step 1: Add descriptor and source-contract tests that reject V1**

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

Python/Go worker descriptor tests from Task 5 continue to assert tag 15 is reserved and V1 wire classes/accessors are absent. Add a Python test that constructing a runtime servicer with no Agent indicator sink cannot instantiate or call a portfolio indicator writer.

- [ ] **Step 2: Run the removal contracts and verify RED**

```bash
cd core-service
go test ./internal/service -run 'IndicatorProtoV1Removed' -count=1 -v
cd ../strategy-service
PYTHONPATH=.:../strategy-library uv run --frozen --extra dev pytest \
  tests/test_runtime_worker_proto.py tests/test_grpc_server.py tests/test_platform_proxy.py -q
```

Expected: FAIL because the additive migration phase still contains V1 core RPC/messages and the direct Python chunk writer.

- [ ] **Step 3: Remove V1 from core-service and regenerate from source**

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

- [ ] **Step 4: Remove the V1 control-panel dispatch and commit independently**

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

- [ ] **Step 5: Regenerate strategy-service portfolio stubs and remove direct persistence**

Run `./generate_proto.sh` against the now-V2-only core proto. In `grpc_server._install_indicator_collection`, remove the `IndicatorChunkBuffer`/direct portfolio-client branch. An agent-managed worker must have the sink installed before session execution; missing sink fails start with `RUNTIME_INDICATOR_SINK_REQUIRED` rather than silently dropping indicators. Strategies with no `INDICATORS` remain unaffected.

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
git add gen/portfoliov1/portfolio_service.pb.go gen/portfoliov1/portfolio_service_grpc.pb.go strategy_service/gen/portfolio_service_pb2.py strategy_service/gen/portfolio_service_pb2_grpc.py strategy_service/grpc_server.py strategy_service/indicators.py strategy_service/platform_proxy.py tests/test_strategy_indicators.py tests/test_grpc_server.py tests/test_platform_proxy.py
git commit -m "refactor: remove direct indicator v1 persistence"
```

- [ ] **Step 6: Confirm quant-handler has no V1 client surface and commit only if cleanup changes remain**

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

- [ ] **Step 7: Run a precise cross-repository no-V1 scan**

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

---

### Task 12: Regenerate Deployment SQL and Run Isolated Database, 1023+2, Lifecycle, and Cross-Repository Acceptance

**Files:**
- Create: `strategy-service/internal/runtimeagent/indicator_v2_integration_test.go`
- Create: `hushine-deploy/scripts/runtime-indicator-v2-db-smoke.sh`
- Create: `hushine-deploy/scripts/runtime-indicator-v2-smoke.sh`
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

- [ ] **Step 1: Finish isolated fresh and populated-upgrade database tests before changing deployment output**

`indicator_v2_bootstrap_test.go` and `indicator_v2_migration_test.go` use `HUSHINE_TEST_PG_ADMIN_DSN`, create unique databases prefixed `hushine_indicator_acceptance_`, and register cleanup immediately after creation. When `HUSHINE_TEST_DATABASE_NAME` is set, each test validates and owns that exact acceptance-prefixed name; this lets the smoke script run the fresh and upgrade cases separately. They may skip only when the admin DSN is absent during ordinary unit runs; `runtime-indicator-v2-db-smoke.sh` always supplies it, grep-fails on `SKIP`, and treats any connection/extension/migration failure as fatal.

The checked-in `testdata/indicator_v1_fixture.sql` does exactly this on a current baseline: drops only the two V2 indicator tables, recreates their former V1 `values_json` shape, inserts two definitions/two chunks, and deletes only `0002_runtime_indicator_v2.sql` from `schema_migrations`. Before applying `0002`, the test inserts a non-empty, foreign-key-valid owned row into every retained table—`users`, `portfolios`, `venues`, `venue_wallet_states`, `venue_events`, `strategies`, `portfolio_strategies`, `strategy_sessions`, `session_venues`, `portfolio_snapshots`, `notification_settings`, `notification_channels`, `notification_plans`, and `reconciliation_runs`—then records `(count, md5(string_agg(to_jsonb(row)::text ORDER BY stable_key)))` for each table except `strategy_sessions`, whose hash is the explicit pre-existing-column projection defined in Task 1. Empty-table hashes do not satisfy this acceptance check.

After the migration, require identical counts/hashes for all retained tables (`users`, `portfolios`, `venues`, `venue_wallet_states`, `venue_events`, `strategies`, `portfolio_strategies`, `strategy_sessions`, `session_venues`, `portfolio_snapshots`, `notification_settings`, `notification_channels`, `notification_plans`, and `reconciliation_runs`), zero old indicator rows, V2 columns/constraints/triggers/foreign keys, and exactly one `0002` ledger row. The `strategy_sessions` comparison hashes the explicit legacy-column projection on both sides and separately requires the new `indicator_finalization_pending` column/default plus false on all upgraded rows. A forced error after the migration body but before ledger insert must leave both schema and ledger at the pre-transaction state.

- [ ] **Step 2: Write the 1023+2 Agent integration test before the final smoke runner**

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

It is valid for save/finalize to use one or two platform requests; the test checks durable state and ordering, not request count. Send `finished`, assert chunk 1 finalizes at revision 1 before `UpdateSession(finished)` and worker acknowledgement. Add subtests for two interleaved symbols, same symbol/different intervals, concurrent Binance spot/futures stream keys, sparse/multiple markers, actual-time gaps, immediate same-sequence/time duplicate ignored without reapplying payload, older lower sequence rejected, and finalization retry.

- [ ] **Step 3: Run the new integration tests and verify RED where deployment artifacts are stale**

```bash
cd core-service
HUSHINE_TEST_PG_ADMIN_DSN='postgres://hushine-tech@192.168.88.10/postgres?sslmode=disable' \
  go test -tags=integration ./internal/storage/migrations -run 'IndicatorV2FreshBootstrap|IndicatorV1PopulatedUpgrade' -count=1 -v
cd ../strategy-service
go test ./internal/runtimeagent -run TestIndicatorV2Integration1023ThenTwoFrames -count=1 -v
```

Expected at the initial RED checkpoint: the tests fail because the fresh/upgrade helpers, V2 schema, and complete V2 sync/lifecycle path are not present. No command targets the shared `portfolio` database.

- [ ] **Step 4: Regenerate the tracked fresh bundle and document the destructive indicator-only upgrade**

Run `make db-schema-bundle`; do not edit generated SQL manually. `db/generated/portfolio.sql` must include `0000`, the V2 `0001`, and transactional `0002` exactly once. Update `db/generated/README.md` source inventory and `db/README.md` with:

- fresh one-shot command and idempotent second run;
- V1→V2 warning that only custom indicators are deleted and old sessions require rerun for indicator regeneration;
- retained table list;
- coordinated protocol-2 deployment order;
- rollback rule: restore service binaries/schema backup together, never run a mixed V1/V2 worker.

- [ ] **Step 5: Implement the ownership-safe database smoke script**

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

- [ ] **Step 6: Implement the complete focused smoke and Make target**

`runtime-indicator-v2-smoke.sh` runs, in this exact order:

```bash
./scripts/runtime-indicator-v2-db-smoke.sh
(cd ../control-panel-service && go test ./internal/runtimechannel -run 'Indicator.*V2|SessionFinalizationPending' -count=1 -v)
(cd ../strategy-service && go test ./internal/runtimeagent -run 'TestIndicatorV2Integration1023ThenTwoFrames|SessionLifecycle|RetryPending|UnexpectedExit|RestartSession' -count=1 -v)
(cd ../strategy-service && HUSHINE_BLOCKED_WORKER_SECONDS=660 HUSHINE_BLOCKED_WORKER_OBSERVE_SECONDS=600 ./scripts/runtime-agent-blocked-worker.test.sh)
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

- [ ] **Step 7: Run every repository's normal gate plus focused acceptance**

From the workspace root, with `.10` credentials available through libpq:

```bash
cd core-service && make proto && go test ./... -count=1 && go vet ./...
cd ../control-panel-service && go test ./... -count=1 && go vet ./...
cd ../strategy-service && ./generate_proto.sh && PYTHONPATH=.:../strategy-library uv run --frozen --extra dev pytest tests/ -q && go test ./... -count=1 && go vet ./...
cd ../gateway/quant-handler && go test ./... -count=1 && go vet ./...
cd ../quant-frontend && npm run build && for test_file in scripts/*.test.mjs; do node "${test_file}" || exit 1; done
cd ../../hushine-deploy && make db-schema-bundle && make test-runtime-indicator-v2
```

Expected: all PASS, no skips in the focused smoke, and a second `make db-schema-bundle` produces no diff.

- [ ] **Step 8: Commit the strategy-service integration test before the deploy acceptance commit**

The runtime integration test is a strategy-service-owned artifact and must be
committed before the deploy runner that names it:

```bash
cd strategy-service
git add internal/runtimeagent/indicator_v2_integration_test.go
git diff --cached --check
git diff --cached -- internal/runtimeagent/indicator_v2_integration_test.go
git commit -m "test: cover indicator v2 lifecycle integration"
```

- [ ] **Step 9: Self-review generated/source consistency and commit only deploy-owned files**

```bash
cd hushine-deploy
git diff --check
before_bundle="$(shasum -a 256 db/generated/portfolio.sql db/generated/README.md)"
make db-schema-bundle
after_bundle="$(shasum -a 256 db/generated/portfolio.sql db/generated/README.md)"
test "$before_bundle" = "$after_bundle"
git add Makefile scripts/runtime-indicator-v2-db-smoke.sh scripts/runtime-indicator-v2-smoke.sh scripts/db/render-schema-bundle.sh db/generated/portfolio.sql db/generated/README.md db/README.md docs/superpowers/plans/2026-07-14-runtime-indicator-v2-lifecycle.md
git diff --cached --check
git diff --cached -- Makefile scripts/runtime-indicator-v2-db-smoke.sh scripts/runtime-indicator-v2-smoke.sh scripts/db/render-schema-bundle.sh db/generated/portfolio.sql db/generated/README.md db/README.md docs/superpowers/plans/2026-07-14-runtime-indicator-v2-lifecycle.md
git commit -m "test: verify runtime indicator v2 deployment"
```

---

## Final Acceptance Record

Record the commit SHA from each independent repository, the three acceptance-owned database names, their successful cleanup, the 1023+2 durable chunk summary, the full 600-second blocked-worker heartbeat count/max-gap/replacement generation, Windows cross-build artifacts, the successful native Windows workflow URL/artifact for the exact strategy-service SHA, and the frontend executable-test result. Do not claim completion from unit tests or cross-build output alone; all Task 12 commands and the native Windows gate must have fresh output from the final tree.
