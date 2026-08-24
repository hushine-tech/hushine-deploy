# Core clean-slate baseline fix 2 implementer report

## Scope

- Repository: `hushine-deploy` only.
- Base: `01b14d87116da0cb40a75cca608cc1d8e72528be`.
- Review blocker addressed: the mandatory database smoke could accept an
  exit-zero Go transcript containing `[no tests to run]`.
- No other repository was edited, and nothing was pushed.

## Change

`scripts/runtime-indicator-v2-db-smoke.sh` now positively requires both exact
top-level evidence lines for its requested Core integration test:

```text
=== RUN   TestPortfolioBaselineFreshBootstrapIsCompleteAndIdempotent
--- PASS: TestPortfolioBaselineFreshBootstrapIsCompleteAndIdempotent (...s)
```

The existing `SKIP` rejection and live database assertions remain in place.
`scripts/runtime-indicator-v2-db-smoke.test.sh` now also makes the fake Go
boundary return Go's successful no-match transcript and requires the real
production smoke script to reject it specifically because the named test did
not run.

## RED -> GREEN evidence

The behavior regression was added before the production change. This focused
command was observed RED:

```text
bash scripts/runtime-indicator-v2-db-smoke.test.sh
runtime Indicator V2 DB smoke contract: database smoke accepted an exit-zero Go transcript with no tests run: ...
testing: warning: no tests to run
PASS
ok  hushine/core-service/internal/storage/migrations  0.001s [no tests to run]
...
✓ Runtime Indicator V2 database smoke passed
```

After adding only the exact run/pass assertions, the same command exited 0.

## Verification

The following fresh checks passed:

```text
bash scripts/runtime-indicator-v2-db-smoke.test.sh
bash scripts/runtime-indicator-v2-cutover-evidence-contract.test.sh
HUSHINE_SOURCE_ROOT="$(cd .. && pwd -P)" \
  bash scripts/runtime-indicator-v2-cutover-evidence.test.sh scan-no-v1
bash scripts/make-source-root.test.sh
bash -n scripts/runtime-indicator-v2-db-smoke.sh \
  scripts/runtime-indicator-v2-db-smoke.test.sh \
  scripts/runtime-indicator-v2-cutover-evidence.test.sh \
  scripts/runtime-indicator-v2-cutover-evidence-contract.test.sh \
  scripts/runtime-indicator-v2-smoke.sh
git diff --check
```

Exact production-path legacy-name and deleted-Core-path allowlist scans found
no matches. The live database smoke passed against the local TimescaleDB,
showing the exact baseline test run/pass evidence, both current migration
files applied on the first runner pass and skipped on the second, generated
bundle idempotence, and the final success marker. Its owned acceptance
databases were absent after cleanup.

The full public gate also passed:

```text
HUSHINE_BLOCKED_WORKER_SECONDS=30 \
HUSHINE_BLOCKED_WORKER_OBSERVE_SECONDS=5 \
  make test-runtime-indicator-v2
✓ Runtime Indicator V2 focused smoke passed
```

That run included the live database gate, Core/control/agent contracts, 42
Python tests, blocked-worker replacement acceptance, bare/Windows-compatible
boundaries, handler and portal tests, and the frontend production build.
