# Clean-Slate Compatibility Removal Design

**Date:** 2026-08-24  
**Status:** Approved in conversation  
**Scope:** All first-party repositories in the Hushine workspace

## Context

Hushine has not been released and has no production clients or production data
that require a rolling upgrade. Several recent changes nevertheless preserved
old HTTP fields, protobuf fields, database columns, data shapes, startup paths,
configuration names, and migration guards. That choice created dual models and
branches whose only purpose is to keep obsolete callers or data readable.

The system will instead use one current contract everywhere. Local test/demo
databases are disposable and will be rebuilt from a clean baseline. No
application-level compatibility layer, dual-read path, dual-write path, old
protocol entry point, or historical-data fallback is required.

## Goals

- Remove the maximum amount of first-party compatibility code while preserving
  every current Spot, Futures, Runtime, market-data, indicator, notification,
  reconciliation, and observability function.
- Make each business fact have one authoritative representation across HTTP,
  protobuf, domain objects, persistence, workers, and the frontend.
- Require the current RuntimeChannel startup protocol and route Sessions only by
  `runtime_id`.
- Rebuild every local database from a final one-shot baseline rather than
  supporting upgrades from obsolete schemas.
- Delete compatibility-only tests and replace them with positive tests for the
  canonical contract and absence tests for removed public fields and routes.
- Report exact deleted files, modified files, additions, deletions, and net line
  reduction per repository after implementation.

## Non-goals

- Do not remove current Binance protocol handling or exchange normalization.
- Do not remove failure rollback, crash recovery, reconciliation, idempotency,
  admission locking, or fail-closed safety paths.
- Do not remove historical market-data retrieval merely because its scope is
  named `historical`.
- Do not remove migration execution infrastructure needed to create a fresh
  database; remove obsolete incremental upgrade content instead.
- Do not use coverage alone as proof that safety or failure paths are dead.

## Definition of Compatibility Code

Delete code when its only purpose is one or more of the following:

- accept an old field, route, status, environment variable, YAML key, or RPC;
- read an old data representation and translate it to the current one;
- write both an old and current representation;
- populate, clear, strip, or force a value solely because an obsolete field is
  still present;
- fall back to an old Session or wallet representation when current facts are
  absent;
- upgrade or guard a database schema that can be discarded;
- keep a pre-current Runtime startup, publication, restart, or direct-call path;
- test or document any of the preceding behavior.

Do not classify ordinary validation, retry, rollback, exchange adaptation,
historical market-data handling, or feature fallback within the current product
contract as compatibility code.

## Canonical Product Contracts

### Strategy-owned Futures leverage

- Strategy source is the only configuration authority.
- `LEVERAGE` defaults to `1`; `ORDER_TARGETS[].leverage` overrides it per
  Futures target.
- Spot rejects a leverage declaration and remains effectively `1x`.
- Preview returns immutable per-target intent/current facts and never mutates
  Binance.
- Start applies, reads back, journals, rolls back on failure, and atomically
  persists confirmed per-target facts before launching the worker.
- Runtime bootstrap carries only typed per-target facts. The worker revalidates
  strategy digest, targets, wallet metadata, and confirmed leverage.
- Remove Session-wide request, response, state, persistence, restart, and UI
  leverage scalars. Mixed target leverage is normal and never collapsed.

### Spot wallet

- Assets use Binance-standard asset codes such as `BTC` and `USDT`.
- The only balance fields are `asset`, `free`, and `locked`, plus their current
  exact-decimal and display metadata where required.
- Remove wallet-level `free/locked` and asset-level `symbol/qty` aliases,
  pseudo-assets, synchronization helpers, conflict checks between old and new
  shapes, and old fixture adapters.
- Symbols used for market data and orders remain pairs such as `BTCUSDT`; symbol
  metadata performs the asset/pair conversion.

### Exact quantities and money

- Exact decimal strings are authoritative at all first-party protocol and
  persistence boundaries.
- Display numbers may be derived at the UI edge, but are not accepted as a
  second business-value input.
- Remove exact-or-legacy selection, float conflict checks, old float request
  fields, double persistence bindings, and quote/quantity fallbacks that exist
  only for old records.
- Binance adapter conversion remains because Binance itself uses textual decimal
  parameters; this is current exchange behavior, not compatibility.

### Runtime and Session lifecycle

- Hosted, self-hosted, and guarded bare runtimes use RuntimeChannel and typed
  Session bootstrap.
- All Session routing uses `runtime_id`; a missing runtime binding fails closed.
- Remove direct strategy-service startup, old scalar restart overrides, old
  publication branches, unbound Session recovery, and deprecated wallet-update
  RPCs.
- The one-line restart keeps runtime-agent alive, removes the old worker and its
  in-memory state, marks the Session recoverable, obtains a new operation and
  Session ID, rereads user code, and starts a new worker through the current
  protocol.
- Agent heartbeat and control traffic remain independent from blocked user code.

### Indicators and market data

- Runtime indicators use only the V2 chunk protocol, including mutable tails,
  1024-row final blocks, retry/idempotency, and explicit finalization.
- Remove Indicator V1 tables, values-json conversion, V1 schema inspection,
  acceptance seals, and V1-to-V2 migration tests.
- Keep live streams and historical coverage/download as current distinct product
  functions. Remove only obsolete aliases, empty-value defaults, and old table
  names that have a canonical replacement.

### Configuration, statuses, RPCs, and logging

- Each service keeps one documented environment variable/YAML key per setting.
- Remove renamed variable/key aliases and their precedence branches.
- Keep only current status values and current RPC names; callers must be updated
  in the same repository set.
- Remove old logger initializer exports after all first-party callers use the
  current initializer.
- External library behavior is not wrapped solely to emulate a removed internal
  API.

## Protocol Cutover

- Delete deprecated fields from authored protobuf files and regenerate every Go
  and Python artifact in all repositories that vendor those schemas.
- Do not add replacement compatibility messages, shadow fields, translation
  helpers, or reserved declarations solely for the removed fields.
- Remove old fields from HTTP request/response types, frontend types, runtime
  messages, domain models, and repository bind/scan lists.
- HTTP JSON boundaries must use the canonical request shape. Old field names are
  rejected as unknown through a shared strict decoder where the endpoint accepts
  user-authored JSON; do not add field-specific legacy error handling.
- Protobuf library handling of unknown wire bytes is not an application contract;
  no custom compatibility code will inspect or translate removed field numbers.

## Database Baseline

- Existing local portfolio, order, control-panel, market-data, and scraper data
  may be dropped.
- Merge every currently required table, index, constraint, trigger, and seed into
  each service's `0001_current_schema_baseline.sql`.
- Retain `0000_create_schema_migrations.sql` only where the migration runner
  requires it to bootstrap a fresh database.
- Delete incremental migrations whose effects are included in the new baseline,
  including Spot transition migrations, Indicator V2 cutover migrations,
  leverage migrations, notification-outbox migrations, and runtime cleanup
  outbox migrations.
- Delete cutover seals, acceptance-owner checks, old-schema inspection, and
  incremental-upgrade contract tests.
- Fresh bootstrap tests must build empty databases in one pass and verify that
  every current service can read and write its complete schema.

## Implementation Order

1. Add failing source-contract tests that require canonical fields/routes and
   prove compatibility symbols still exist before deletion.
2. Remove authored protobuf compatibility fields and regenerate artifacts.
3. Update current callers from the outer boundaries inward: frontend, handler,
   control panel, runtime-agent, strategy worker, core service, repositories.
4. Remove leverage scalar and pre-bootstrap startup/restart/publication paths.
5. Remove Spot wallet dual representations and update all fixtures/callers.
6. Remove legacy decimal inputs and convert current boundaries to exact strings.
7. Remove legacy config aliases, statuses, RPCs, logger exports, and confirmed
   obsolete market-data aliases.
8. Collapse databases to fresh baselines and delete incremental upgrade code.
9. Delete compatibility-only tests and documents, update current repository and
   operator documentation, and regenerate the code census.
10. Rebuild and launch the entire local system from empty state and run automated
    and real-page acceptance.

Every step must leave the affected repository internally buildable. Cross-repo
protocol commits may be coordinated, but no compatibility shim is added between
steps; the complete workspace cutover is the unit that is deployed.

## Error Handling and Safety

- Canonical input violations fail at the nearest boundary with stable current
  error codes.
- Missing runtime bootstrap, per-target facts, runtime binding, exact decimal, or
  canonical Spot asset data fails closed.
- Exchange mutation retains pre-POST journaling, readback confirmation, reverse
  rollback, recovery admission, and durable notification behavior.
- Removal must not weaken ownership checks, credential isolation, environment
  isolation, idempotency, or transaction boundaries.
- If a current positive-path or safety-path test fails, stop that deletion group,
  determine the current contract, and fix the canonical implementation. Do not
  restore an obsolete interface to make tests pass.

## Verification

### Repository checks

- Every Go repository: `go test ./...` and `go vet ./...`.
- `strategy-service`: full managed Python suite, Go suite, and both tracked shell
  tests.
- `strategy-library` and `strategy-debugger-cli`: complete managed pytest suites.
- `quant-frontend`: every `scripts/*.test.mjs` test and `npm run build`.
- Root: strict OpenSpec validation remains a repository health check even though
  this change is designed and executed with Superpowers.

### Fresh-system checks

- Delete local service databases and create them from the new baselines.
- Start database, Kafka, Elasticsearch, Logstash, Kibana, Jaeger, all services,
  and the coverage-instrumented hosted runtime image.
- Confirm health, registration, RuntimeChannel connectivity, stream management,
  authentication, and credential-manager startup.

### Trading acceptance

- Mock Binance covers Spot and Futures order paths for supported MARKET/LIMIT and
  GTC/IOC/FOK combinations, including fills, partial fills, expiry, rejection,
  fees, and reconciliation.
- Futures covers one-way/hedge, cross/isolated, per-symbol leverage, multi-symbol
  strategies, liquidation behavior, apply/readback failure, reverse rollback,
  and rollback failure notification.
- Spot covers Binance asset balances, low-buy/high-sell behavior, insufficient
  balances, filters, fees, locked/free transitions, and reconciliation.
- Real-page acceptance covers Quick Start, Spot, Futures, multi-symbol
  BTC/ETH/ZEC, Telegram notifications, incremental indicators, final 1024-row
  chunks, mutable tails, worker restart, Resume, and a deliberately blocked
  strategy worker while runtime heartbeat remains healthy.

## Documentation and Accounting

- Current repository documentation describes only canonical behavior.
- Delete or clearly replace old operator/user instructions; dated implementation
  artifacts that directly prescribe compatibility behavior are removed once this
  design and plan supersede them.
- Final reporting is derived from repository-scoped `git diff --numstat` and
  includes, per repository: deleted files, modified files, added lines, deleted
  lines, and net reduction.
- Generated-code deletion is reported separately from hand-written production,
  tests, migrations, and documentation.

## Acceptance Criteria

- No first-party production source contains a confirmed compatibility branch,
  dual-read/write model, deprecated internal field, old route, old config alias,
  or old-schema upgrade path.
- Authored protobuf files contain no application field retained solely for an
  obsolete Hushine client.
- Fresh databases start in one pass and contain only the current schema.
- All repository checks and fresh-system acceptance checks pass.
- Existing current Spot, Futures, Runtime, indicator, notification,
  reconciliation, and observability behavior remains available.
- The final change produces a substantial net line reduction, expected to be in
  the thousands once generated artifacts, incremental migrations, compatibility
  tests, and old startup/data-model branches are removed.
