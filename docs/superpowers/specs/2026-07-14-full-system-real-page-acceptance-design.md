# Full-System Real-Page Acceptance Design

**Date:** 2026-07-14

**Status:** Approved in conversation; written specification pending user review

## Goal

Make the user's review concentrate on trading-data correctness rather than
missing imports, broken workers, stale UI contracts, or untested product paths.
After the dependency, Indicator V2, lifecycle, and Spot USDT changes are
implemented, run the complete repository test matrix and then exercise the
actual local product in a real browser with coverage enabled in both services
and hosted runtime containers.

## Scope

This specification is the integration and acceptance gate for three companion
changes:

- Runtime Python dependency contract;
- Runtime Indicator V2 and worker lifecycle;
- Binance Spot USDT end-to-end support.

It also reruns ordinary Futures, notification, runtime management, multi-input,
liquidation, recovery, and deployment tests so the review is not limited to
the immediately changed screens.

It does not open Live trading. `environment=2` remains rollout-guarded.

## Alternatives Considered

### A. Rely on repository unit tests

Fast, but previous green suites missed a missing image dependency, compressed
marker offsets, and production-shaped Spot wallet failures.

### B. Run only browser happy paths

Useful visually, but insufficient for chunk boundaries, retries, exception
paths, and database invariants.

### C. Layered automated and real-page acceptance — selected

Require unit/contract/integration tests, image smoke, fresh and upgrade database
checks, real Hosted sessions, browser workflows, data reconciliation, and
coverage review. A failure at any layer returns to implementation and repeats
the affected layer plus the final full gate.

## Environment Contract

The existing local coverage workflow is reused rather than creating a second
orchestration path.

- Local Docker containers not belonging to the acceptance run are stopped and
  removed before the run.
- Infrastructure databases and brokers use the configured `.10` environment;
  credentials are loaded from existing local secret/config sources and are
  never printed in commands, logs, screenshots, reports, or commits.
- All platform services run locally with service coverage enabled.
- Hosted Runtime uses a freshly built V2 coverage image derived from the same
  locked dependencies as the normal image.
- The browser is a real Chromium session controlled through the in-app browser
  tooling, not a source-code simulation.
- Coverage artifacts are written only under the established coverage output
  root and remain separate from source repositories.

Before testing, record service commit IDs, image digest, migration versions,
database target names, and coverage-run ID. These identities appear in the
final report without secrets.

## Layer 1: Repository Verification

Run the authoritative commands from the workspace `AGENTS.md`:

- every Go repository: `go test ./...` and `go vet ./...`;
- strategy-service: managed Python pytest suite, Go suite, and both tracked
  shell tests;
- strategy-library and strategy-debugger-cli: each managed pytest suite;
- quant-frontend: production build and every `scripts/*.test.mjs` test;
- root deployment/build orchestration;
- read-only `openspec validate --all --strict --no-interactive` only as the
  workspace-mandated archive-integrity check. OpenSpec is not used to design,
  plan, track, or implement this change; Superpowers artifacts remain the
  implementation source of truth.

Changed concurrency paths also run the relevant Go race tests. Generated
protobufs, generated SQL, and lock files must be reproducible from their
sources; a clean regeneration cannot produce an uncommitted diff.

## Layer 2: Image and Worker Verification

Build both normal and coverage Hosted Runtime images from the final source.

For each image:

1. verify the image digest and expected runtime-agent/worker versions;
2. import every allowed third-party strategy dependency inside the image;
3. compile and instantiate a representative strategy using every allowed
   dependency;
4. start a worker, complete protocol V2 handshake, run a minimal session, flush
   one indicator chunk, receive final acknowledgement, and exit cleanly;
5. confirm a forbidden import and a deliberately broken module fail before a
   session can remain running;
6. confirm the image contains no internal database, Kafka, account, or order
   endpoint configuration intended only for platform services.

The coverage image additionally proves that Go and Python coverage shards are
written and mergeable after normal finish, worker restart, and forced cleanup.

## Layer 3: Database Verification

Use isolated database names or schemas on the `.10` server.

### Fresh bootstrap

Run the complete current migrations against an empty database, start every
service, and execute basic create/read operations. This proves that one-time
deployment produces a usable system without historical migrations or manual
SQL repair.

### Populated upgrade

Create a representative pre-V2 database containing users, portfolios, venues,
strategies, sessions, orders, fills, wallet snapshots, notifications,
reconciliation rows, and V1 indicator rows. Record counts and stable hashes for
all non-indicator tables. Apply the V2 migration and require:

- V1 indicator definitions and chunks are gone;
- V2 indicator tables and constraints exist;
- all recorded non-indicator counts and hashes are unchanged;
- services start and can create a new V2 session.

## Layer 4: Service Integration Matrix

Automated integration tests cover:

- Hosted Backtest and Demo Futures;
- Hosted Backtest and Demo Spot USDT;
- offline debugger Futures and Spot USDT;
- multiple symbols, different intervals, and more than one input stream in one
  strategy;
- one strategy declaring Spot and Futures targets for the same trading symbol
  without route or wallet contamination;
- MARKET and LIMIT orders, fills, fees, rejects, pending recovery, and order
  lifecycle history;
- Futures liquidation, max-loss close, stop-only, and stop-and-close;
- Spot insufficient USDT, insufficient base asset, filters, target open orders,
  dust, stop-only, and stop-and-close;
- Runtime registration, Hosted worker creation, heartbeat, session finish,
  recoverable status, resume, worker-only restart, and runtime shutdown;
- Bare worker IPC/restart through the cross-platform transport contract, with
  no Unix-domain-socket dependency for the Windows-supported path;
- Telegram binding, test notification, strategy notifications, unbinding, and
  user-visible notification history;
- Indicator V2 open refresh, 1024 sealing, sparse markers, final tail, and
  failure recovery.

Exchange-backed Demo calls use the user's existing Demo credentials through
the encrypted Venue path. Tests never echo or persist raw key material outside
the existing credential store.

## Layer 5: Real Browser Workflow

The browser workflow uses the public frontend and quant-handler only. It does
not call internal service APIs to fake completion.

1. sign in and verify main navigation and current terminology;
2. create or select Backtest and Demo portfolios;
3. create or select Futures and Spot USDT venues and verify wallet display;
4. create strategies with one stream, multiple symbols, multiple intervals,
   and mixed Spot/Futures targets;
5. run preview and confirm actionable readiness errors;
6. start Hosted Backtest and observe an open V2 chunk before 1024 bars;
7. finish beyond 2049 bars and inspect three finalized chunks;
8. start Hosted Demo Futures and Spot sessions and observe orders, fills,
   wallet changes, notifications, and reconciliation;
9. use stop-only and verify exposure remains;
10. use stop-and-close and verify only declared target exposure is processed,
    with the page warning that pre-existing target exposure is included;
11. exercise recoverable resume and worker-only restart;
12. inspect session history, chart visibility toggles, order lifecycle,
    snapshots, notification settings, and coverage controls.

Browser screenshots are evidence, not the source of truth. Every material
screen result is cross-checked against API responses and durable records.

## Indicator and Trading Data Reconciliation

For each acceptance session, produce a machine-readable reconciliation keyed
by session, stream, and target:

- market bars accepted by the worker;
- V2 sequences and actual times;
- chunk counts, revisions, and finalized state;
- scalar non-null positions;
- marker sequence/time/text/price;
- order intent time and requested side/quantity;
- order, fill, fee, and wallet deltas;
- final portfolio and venue wallet state.

BUY/SELL markers must match the intended order or fill event according to the
strategy template contract. A visually present marker at the wrong time is a
failure. Totals alone are not sufficient.

The known 1023-plus-two case must show one immutable 1024-bar chunk followed by
one open bar. Repeating the same open state must be idempotent and leave the
row revision and update behavior consistent with the V2 contract.

## Blocked Worker Verification

Use a Bare strategy whose user callback enters a ten-minute blocking loop.
Start it under observation, then verify across multiple heartbeat and status
poll intervals that:

- runtime-agent PID and boot identity do not change;
- RuntimeChannel remains connected;
- Agent heartbeat remains healthy;
- other platform services and unrelated sessions remain responsive;
- the blocked worker does not execute Agent lifecycle work;
- worker-only restart terminates/reaps the old generation, finalizes its
  indicator tail, marks the old session recoverable, and starts a new session
  without restarting the runtime.

The test need not wait for the user callback to return naturally. The callback
is deliberately configured for ten minutes, health is observed for a bounded
multi-heartbeat window, and restart proves controlled recovery.

## Coverage Review

After browser and integration workflows:

1. stop sessions and runtimes through product paths so final coverage flushes;
2. validate every raw Go and Python coverage shard;
3. merge reports only from complete runtime finalizations;
4. generate per-repository and Hosted Runtime summaries;
5. identify unexecuted changed branches and user-facing handlers;
6. add tests or page actions for meaningful gaps and repeat the gate;
7. retain genuinely unreachable-code candidates for the user's later
   coverage-driven cleanup decision rather than deleting them in this change.

Coverage percentage is evidence, not the sole acceptance criterion. Critical
error, lifecycle, risk, and migration branches require explicit tests even if
aggregate coverage is high.

## Failure Handling

- Any failing layer blocks push and final completion claims.
- A real Demo exchange limitation is recorded with endpoint, safe error
  category, and reproducible preconditions; it does not convert a failed local
  contract into success.
- A browser/UI failure is traced through frontend, BFF, service, runtime, and
  database boundaries before code changes.
- After a fix, rerun the narrow reproducer, the owning repository suite, and
  the complete final acceptance gate.
- Secrets, raw credentials, authorization headers, strategy source, and
  unrestricted environment dumps are excluded from reports.

## Documentation and Delivery

After code and acceptance are complete:

- update the current Notion project overview, architecture, Runtime Management,
  and user manual pages;
- remove or clearly mark stale Notion guidance and verify every retained link;
- document dependency closure, Indicator V2, 1024 sealing, worker restart,
  Spot USDT semantics, stop-and-close scope, deployment, and troubleshooting;
- commit each repository independently on its approved feature branch;
- push only after verification-before-completion and independent final review.

The final report contains repository commit IDs and remote refs, image digest,
migration versions, files changed/added/deleted, added and removed line counts,
test commands and results, browser workflows, reconciliation evidence,
coverage summaries, and any remaining external limitations.

## Acceptance Criteria

- Every authoritative repository suite passes from clean source.
- Normal and coverage Runtime images pass dependency and V2 worker smoke.
- Fresh and populated databases both start the complete stack after migration.
- Hosted Futures and Spot Backtest/Demo workflows complete through the actual
  page and public API.
- Sparse marker times match their market bars and order/fill evidence.
- Multi-symbol, multi-interval, Spot/Futures, liquidation, notification,
  restart, and recovery paths are exercised.
- Runtime heartbeat survives a deliberately blocked worker.
- Bare Runtime transport and worker-only restart remain Windows-compatible.
- Coverage artifacts are complete, valid, and reported.
- Current Notion documentation matches the delivered code.
- No repository is pushed while a required verification remains failing.
