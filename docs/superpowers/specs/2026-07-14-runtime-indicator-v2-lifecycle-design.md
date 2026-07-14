# Runtime Indicator V2 and Worker Lifecycle Design

**Date:** 2026-07-14

**Status:** Approved in conversation; written specification pending user review

## Goal

Replace the implicit, count-based custom-indicator transport with an explicit
V2 protocol and storage model. Every indicator sample and marker must remain
aligned with the market bar that produced it, full chunks must become immutable
at exactly 1024 bars, an open tail must remain visible while a session runs,
and every worker exit path must either durably finalize the tail or leave the
session recoverable.

## Confirmed Compatibility Decision

The user selected a clean V2 cutover.

- Existing custom-indicator definitions and chunks are deleted during the V2
  database migration.
- Existing sessions, portfolios, venues, strategies, orders, fills, wallet
  snapshots, notifications, and reconciliation records are retained.
- Old sessions do not have a V1 read path. Re-running the backtest is the only
  general way to regenerate their custom indicators.
- Runtime worker protocol V1 is rejected explicitly. The runtime-agent and
  session worker must both support protocol version 2 before a session starts.
- V1 protobuf tags and RPC identifiers are reserved rather than reused.

This is a test-stage coordinated deployment. No mixed V1/V2 runtime operation
is supported.

## Root Cause Being Removed

The current Python in-process buffer advances every declared indicator once
per market bar. The hosted path does not. It sends definitions only on the
first frame and later sends only keys that have a value or marker on that bar.
The Go buffer therefore counts sparse marker frames rather than market bars and
assigns offsets from that compressed count. A marker from bar 1438 can be
stored near offset 588 even though every marker was generated and delivered.

V2 removes offset inference. Bar identity is part of the protocol and actual
bar times are part of durable storage.

## Alternatives Considered

### A. Send a null value for every definition on every frame

This is a small repair but still relies on an implicit convention, cannot
distinguish old workers reliably, and keeps the frontend dependent on inferred
times.

### B. Keep the protocol and add times to the existing JSON envelope

This can correct rendering without protobuf regeneration, but leaves two
different chunk implementations and weakly typed payloads.

### C. Typed protocol and storage V2 — selected

Use an explicit worker protocol version, per-stream bar sequence, typed scalar
and marker payloads, actual time arrays, and V2-only persistence APIs. The
larger coordinated change is acceptable because old indicator history and
mixed-version compatibility were explicitly declined.

## Worker Protocol V2

`WorkerHello` declares `protocol_version = 2`. The Agent refuses to start or
alias a session from a worker that omits the field or reports another version.
The error code is `RUNTIME_WORKER_PROTOCOL_UNSUPPORTED`, includes the received
and required versions, and never leaves the platform session in `running`.

The V1 indicator field number is reserved. A new `IndicatorFrameV2` payload
contains:

```text
session_id
user_id
strategy_id
stream_key
stream_sequence       uint64, zero-based and contiguous per stream
market_time_ms        actual market-bar time
interval_ms
definitions[]         first frame only; immutable within the session
samples[]             only values or markers produced on this bar
```

An `IndicatorSampleV2` identifies one `indicator_key` and contains either an
optional scalar value or repeated typed markers. A marker contains user-visible
text and optional price/color/position/shape fields. Sequence and time are
inherited from the frame and attached explicitly when the Agent builds durable
markers.

Definitions are sent on the first frame for each stream. A later definition
set is accepted only when byte-equivalent to the first set. Changing an
indicator key, type, pane, or configuration requires a session restart. Bare
hot reload may change strategy code in place only while its indicator
declaration remains identical.

## Bar Sequence Contract

The Python worker owns sequence assignment but not chunking.

- Every declared input stream has its own counter beginning at zero.
- The counter advances once for every market bar accepted by the strategy
  router, independent of whether the strategy emits a scalar or marker.
- If user code raises while processing a bar, the worker emits an empty V2
  frame for that sequence before applying the environment's existing guarded
  or fatal error behavior. Partially written values from the failed callback
  are discarded.
- A duplicate `(session_id, stream_key, stream_sequence)` with identical time
  is idempotently ignored.
- A duplicate sequence with a different time, a lower sequence, or a gap is a
  protocol error. The Agent stops that worker generation, stops accepting its
  frames, finalizes the last contiguous state, and marks the session
  `recoverable`. A worker with a corrupt audit stream may not continue placing
  orders in the background.
- Time gaps are valid when the sequence is contiguous. Actual `market_time_ms`
  is stored, so maintenance gaps and missing exchange candles are never
  reconstructed from `interval_ms`.

## Agent Chunk Ownership

The Go Agent is the only component that creates chunk indexes or finalization
state. It holds one stream clock per `(session_id, stream_key)` and one buffer
per `(session_id, stream_key, indicator_key)`.

For every accepted frame, the Agent advances every registered definition:

- line and histogram indicators append the scalar or `null`;
- marker indicators advance the bar slot and append only markers actually
  present on that bar;
- multiple markers on one bar share the same sequence and time;
- different streams never advance one another.

Chunk identity is deterministic:

```text
chunk_index   = stream_sequence / 1024
offset        = stream_sequence % 1024
start_sequence = chunk_index * 1024
```

At sequence 1023, chunk 0 has 1024 bars and becomes immutable. Sequence 1024
creates chunk 1 with one open bar. A flush may persist the finalized chunk and
open chunk in one platform request or two; the required durable result is:

```text
chunk 0: count=1024, finalized=true
chunk 1: count=1,    finalized=false
```

Open chunks are snapshotted every two seconds. A full chunk triggers an
immediate flush. Network I/O happens outside buffer locks and each session has
one flush owner, so periodic, full-boundary, terminal, and restart flushes do
not race.

## V2 Persistence Contract

Core-service owns the durable V2 tables and V2-only portfolio RPCs. A chunk
contains typed fields instead of an opaque values envelope:

```text
session_id
stream_key
indicator_key
chunk_index
start_sequence
end_sequence
start_time_ms
end_time_ms
interval_ms
count
times_ms[]
scalar_values[]       nullable values; empty for marker indicators
markers_json          array; each item carries sequence, offset, and time_ms
revision
finalized
protocol_version = 2
created_at
updated_at
```

Database constraints require:

- `protocol_version = 2`;
- `0 < count <= 1024`;
- `end_sequence = start_sequence + count - 1`;
- `cardinality(times_ms) = count`;
- scalar arrays are either empty for marker series or have `count` slots;
- marker sequence and offset are inside the chunk range;
- the primary key remains
  `(session_id, stream_key, indicator_key, chunk_index)`;
- definitions reference the owning session, and chunks reference their
  definition, both with cascade cleanup when a session is deleted.

An open chunk carries a monotonically increasing `revision`. UPSERT accepts a
strictly newer revision or an identical idempotent retry. It rejects count,
sequence, or time rollback. A finalized row can never be updated. Finalizing
an open row at its current revision uses an explicit finalize operation guarded
by the previous revision.

The listing API returns `finalized`, actual times, typed values, and markers.
The gateway must not drop any of these fields.

## Database Migration and Fresh Bootstrap

The core-service migration is transactional and deliberately destructive only
to the two old indicator tables:

1. drop old indicator chunk and definition tables;
2. create the V2 definition and chunk tables, checks, foreign keys, and indexes;
3. commit only after the complete V2 schema exists.

The current baseline schema is updated to the same V2 definition. A brand-new
database can run all migrations once and start every service. An existing test
database retains all non-indicator rows. Verification records row counts for
sessions, orders, fills, snapshots, and notifications before and after the
migration and requires equality.

Generated deployment SQL is regenerated from the authoritative service
migrations; it is not edited as an independent schema source.

## Frontend Rendering

The frontend consumes actual times from each V2 chunk.

- Scalar point `i` uses `times_ms[i]`.
- A marker uses its stored `time_ms`; its offset is only an integrity field.
- Open chunks render while `finalized=false` and are replaced idempotently as
  their revision grows.
- Finalized chunks are cached as immutable.
- The UI exposes whether the visible tail is open or finalized.
- No code path computes custom-indicator time as
  `start_time + offset * interval`.

Rendering expansion is extracted into executable pure functions. Source-regex
tests are insufficient for data alignment.

## Strategy Template Correctness

Protocol correctness does not excuse a template that emits the wrong value.
The current reconciliation/Bollinger notification template computes
`bb_width_bps` and then overwrites it with `None`; this known defect is fixed
under the same TDD gate. A deterministic template test must process enough bars
for the Bollinger window, assert that width is numeric and matches the source
prices, and verify that every BUY/SELL marker matches the strategy's order
decision time and side. Tests that only check key presence are not sufficient.

## Terminal Finalization

Every terminal path uses the same Agent finalization coordinator:

1. stop accepting new frames for the worker generation;
2. drain frames already received on RuntimeChannel;
3. seal every contiguous open chunk;
4. retry the V2 persistence request with bounded exponential backoff;
5. publish the terminal status only after persistence is acknowledged;
6. acknowledge the worker final frame;
7. forget in-memory state only after the worker generation is reaped.

This applies to `finished`, `failed`, `stopped`, `stop_failed`, max-loss stop,
Bare restart, and unexpected process exit. If persistence cannot be confirmed,
the Agent publishes `recoverable`, preserves the original terminal reason in
the error chain, does not send a success acknowledgement, and retains the
buffer for retry. No terminal status may silently discard a tail.

For an Agent-managed session, the Python worker reports its desired terminal
state but does not independently publish that terminal state to the platform.
The Agent is the sole external terminal-status publisher, preventing a worker
from racing indicator finalization with a direct `finished` update. Direct
preview validation remains non-session work and is unaffected.

## Unexpected Exit and Bare Restart

WorkerManager reports process exit to Agent with worker generation, pending
session ID, real session alias, exit code category, and whether an acknowledged
`FinalStatus` was observed. PID alone is never an identity.

An unexpected exit without acknowledged final status causes the Agent to
finalize the last contiguous indicator state and mark the real session
`recoverable`. A late callback from an old generation cannot alter a replacement
worker's session.

Bare restart performs:

1. close admission for the old generation;
2. request graceful worker stop, then force and reap within the existing bound
   if user code is blocked;
3. finalize the old V2 indicator tail;
4. persist the old session as recoverable with restart reason;
5. clear only the old worker generation and session-owned memory;
6. create a new session ID and worker using the current user source;
7. send resume only after the new session is confirmed running.

The Go runtime-agent process, RuntimeChannel, and runtime heartbeat remain
alive throughout. A blocked Python callback never executes on the Agent's
heartbeat goroutine.

Worker IPC and restart remain cross-platform. Bare mode may run on Windows, so
the V2 protocol, lifecycle callbacks, process identity, and local transport
cannot require Unix domain sockets, POSIX-only paths, or Unix-only signals.
POSIX may use TERM before force-kill; Windows uses the existing platform process
abstraction with equivalent bounded graceful/forced semantics.

## Testing Strategy

All implementation work follows red-green-refactor TDD.

### Python worker

- first frame definitions and later sparse frames;
- no scalar or marker still emits one bar frame;
- failed callback emits an empty frame and discards partial values;
- independent sequence for multiple symbols and intervals;
- protocol version handshake and unsupported-version failure;
- final acknowledgement and bounded shutdown.

### Go Agent

- 1, 1023, 1024, 1025, and 2049 bars;
- explicit 1023 then two-bar transition;
- markers only on bars 4 and 9;
- marker on the last bar and multiple markers on one bar;
- duplicate, conflicting duplicate, out-of-order, sequence gap, and time gap;
- three concurrent stream keys with independent chunk indexes;
- repeated open flush, immutable final chunk, and stale revision rejection;
- every terminal state, persistence failure, Bare restart, and unexpected exit;
- blocked worker while Agent and runtime heartbeats continue.

### Core, gateway, and frontend

- V2 schema constraints and monotonic UPSERT with a real test database;
- ownership checks on every save and list request;
- fresh bootstrap and populated-upgrade migration;
- gateway field-for-field V2 serialization;
- executable chart expansion tests using actual times;
- marker times matched against order intent, fill, and market-bar times.
- deterministic `bb_width_bps` value and template marker/order alignment;
- Windows-compatible Bare transport and worker replacement tests.

## Acceptance Criteria

- A sparse marker on bar 1438 renders at bar 1438.
- 1023 plus two bars produces one immutable 1024-bar chunk and one one-bar
  open chunk.
- A 2049-bar run finalizes chunks of 1024, 1024, and 1 bars.
- Multi-symbol and multi-interval streams do not advance each other.
- No frontend code infers V2 indicator times from interval and offset.
- A finalization failure cannot produce a false terminal success.
- A ten-minute blocked Python strategy leaves RuntimeChannel and Agent heartbeat
  healthy and can be replaced without restarting the runtime.
- V2 worker IPC and session-only restart do not depend on Unix sockets and pass
  the supported Windows Bare test path.
- Fresh and upgraded databases both start the complete service stack.
- Only historical custom-indicator data is removed by migration.
