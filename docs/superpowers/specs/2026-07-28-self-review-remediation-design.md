# Self-Review Remediation Design

**Date:** 2026-07-28

**Status:** Approved by the user's instruction to fix every finding from the
2026-07-24 self-review.

## Goal

Close the six verified gaps from the medium-cleanup self-review without
weakening the already approved Runtime Indicator V2, Binance Spot USDT, hosted
coverage, RuntimeChannel, or runtime isolation contracts.

## Existing Approved Contracts

This remediation implements, and does not replace, these specifications:

- `2026-07-14-runtime-indicator-v2-lifecycle-design.md`;
- `2026-07-14-binance-spot-usdt-end-to-end-design.md`;
- `2026-07-11-hosted-runtime-coverage-design.md`.

The current source only contains the worker protocol-version handshake; it does
not yet contain the approved Indicator V2 transport, persistence, or portal
model. A null-padding repair to the V1 envelope is therefore not the final
solution.

## 1. Indicator Alignment and V1 Removal

### Considered approaches

1. Repeat every definition and send one null V1 value per bar. This repairs
   sparse offsets but preserves inferred time and two chunk owners.
2. Add time fields to the V1 JSON envelope. This repairs rendering but leaves
   untyped persistence and ambiguous version admission.
3. Complete the approved typed V2 cutover. This is selected.

The Python worker emits one `IndicatorFrameV2` for every accepted stream bar,
including bars with no scalar or marker sample. The frame carries a contiguous
per-stream sequence and candle open time. The Go Agent advances every declared
definition once per accepted frame, derives chunk index and offset from
sequence, stores actual times, and is the only chunk/finalization owner.

Core persists typed V2 chunks with monotonic revisions and immutable finalized
rows. Handler preserves every V2 field. Frontend pure functions render scalar
points and markers by stored time rather than reconstructing time from
`start_time_ms + offset * interval_ms`.

After the V2 database, worker-to-page, and no-V1 gates pass in isolation, the
obsolete Python `IndicatorChunkBuffer`, direct
`save_strategy_indicators` fallback, V1 worker field, V1 RPCs, V1 tables, and
V1 frontend parser are removed in the coordinated candidate. No shared
database receives the destructive indicator-only migration during development.

## 2. RuntimeChannel Replacement Ownership

### Considered approaches

1. Reject reconnects while an older stream is still registered.
2. Serialize replacement until the old handler exits.
3. Replace immediately but make cleanup stream-identity-aware. This is
   selected because reconnect remains fast and cleanup becomes deterministic.

`Registry.Unregister` accepts the exact `runtimeStream` registered by that
handler and removes it only if it is still the current stream for the
`runtime_id`. The handler also clears the persisted connection owner only when
its stream is still current. Closing an old stream after a replacement cannot
close or unroute the replacement. Shutdown still closes all streams and rejects
late registration.

## 3. Core-Authoritative Spot USDT Admission

### Considered approaches

1. Rely on catalog/UI filtering.
2. Rely on Session preflight.
3. Validate trusted metadata in ordinary Core order admission and retain the
   existing preflight check. This is selected.

Every external Spot order, including direct `order.v1.PlaceOrder` and runtime
platform calls, must have trusted symbol metadata with
`quoteAsset == "USDT"`. Core returns the stable
`SPOT_QUOTE_UNSUPPORTED` rejection before risk/execution. Internal atomic Spot
close uses the same metadata requirement. Risk validation repeats the
invariant as defense in depth so a future caller cannot bypass it.

## 4. Coverage Evidence Normalization

### Considered approaches

1. Keep raw artifacts and require manual interpretation.
2. Mark only a whole service active when any coverage exists.
3. Normalize dynamic coverage into file/function subjects and make candidate
   classification consume those subjects. This is selected.

Session stop validates and records the retained-browser
`frontend-precise.json` artifact. Go cover profiles/function reports, Python
coverage JSON, frontend precise coverage, and observability endpoint evidence
are converted into normalized evidence records. File subjects use
workspace-relative paths; function subjects include their containing file.

Candidate classification never treats a filename containing `legacy`, `old`,
or `deprecated` as unreferenced. Static reachability and naming suspicion are
separate facts. Dynamic zero coverage is never sufficient for deletion;
migrations, generated protocol code, tests, fixtures, bootstrap, and historical
compatibility surfaces remain protected, and every delete candidate still
requires static unreachability plus user approval.

## 5. Graceful Coverage Stop

The instrumented stack stop path sends TERM once, polls owned process trees
until all roots exit or a configurable ten-second deadline expires, and only
then sends KILL to survivors. It does not sleep for an arbitrary one second.
The result records which services exited gracefully and which were forced.
This gives Go and Python their configured flush window while keeping shutdown
bounded.

## 6. Testing and Safety

All fixes use red-green-refactor:

- sparse markers at bars 4, 9, and 1438, empty frames, 1023 plus two bars,
  irregular candle times, duplicate/conflicting frames, and terminal tails;
- replacement stream A followed by B, then A cleanup, with B remaining
  routable and owner state intact;
- direct and Session Spot orders with USDT and non-USDT trusted metadata;
- frontend, Go, Python, and observability evidence mapped to exact subjects;
- naming-only legacy paths never called unreferenced;
- TERM-fast exit and deadline/KILL coverage stop cases;
- no executable V1 indicator surface after the isolated cutover gate.

Tests may create isolated temporary databases, processes, and containers, but
must not stop or relabel the user's active manual coverage run. Runtime
configuration continues to exclude internal DB, Kafka, Portfolio, Order, and
account addresses.

