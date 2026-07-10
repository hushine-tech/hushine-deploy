# Database Baseline and Deploy Cleanup Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace four historical migration chains with current-schema baselines, make fresh deployment and generated DDL reproducible from the versioned deploy repository, and remove the broken audit entrypoint.

**Architecture:** Each database domain retains `schema_migrations` plus one idempotent current baseline. `hushine-deploy` becomes the versioned deployment owner for `ensure-dbs`, schema bundle generation, and DB documentation while service repositories remain the schema source of truth.

**Tech Stack:** PostgreSQL 16, TimescaleDB 2.17.2, SQL migrations, Go migration runners/tests, Bash, Docker.

## Global Constraints

- Old databases are not upgraded in place; environments must be wiped and rebuilt.
- Never run destructive validation against `192.168.88.10`.
- Fresh validation must use a dedicated temporary TimescaleDB container and a dynamically assigned localhost port.
- Preserve every table, view, index, constraint, hypertable, trigger, and seed row listed in the approved design.
- Keep `schema_migrations` and future incremental migration support.
- A second `make ensure-dbs` must exit 0 without schema or data damage.
- `hushine-deploy` is the versioned deployment truth source; the workspace root is not Git.
- Delete historical SQL only after final-schema contract tests exist.

## Design Coverage

- D07: Tasks 1-4 replace all historical migration chains with current baselines.
- D08: Tasks 5 and 7 version, render, and execute the one-shot DDL bundles twice.
- D09: Task 6 removes the broken audit script and Make target.

---

## File Map

| Repository/path | Responsibility after this plan |
|---|---|
| `core-service/internal/storage/migrations/0001_current_schema_baseline.sql` | Complete Portfolio DB schema |
| `core-service/internal/order/storage/migrations/0001_current_schema_baseline.sql` | Complete Order DB schema |
| `control-panel-service/internal/storage/migrations/0001_current_schema_baseline.sql` | Complete Runtime/Market Data control schema |
| `scraper/internal/storage/migrations/0001_current_schema_baseline.sql` | Complete market-data year schema |
| `hushine-deploy/scripts/ensure-all-dbs.sh` | One-shot orchestration across sibling service repositories |
| `hushine-deploy/scripts/db/render-schema-bundle.sh` | Render versioned review/manual-bootstrap bundles |
| `hushine-deploy/db/` | Versioned DB inventory and generated bundles |

### Task 1: Convert migration tests from history assertions to final-schema assertions

**Files:**
- Modify: `core-service/internal/storage/migrations/migration_contract_test.go`
- Modify: `core-service/internal/storage/migrations/portfolio_environment_contract_test.go`
- Modify: `core-service/internal/order/storage/migrations/order_environment_contract_test.go`
- Modify: `core-service/internal/order/repository/timescale_migrations_test.go`
- Modify: `control-panel-service/internal/storage/migration_environment_contract_test.go`
- Modify: `control-panel-service/internal/storage/migration_schema_test.go`
- Modify: `scraper/internal/storage/timescale_test.go`

**Interfaces:**
- Produces: tests that read/apply `0001_current_schema_baseline.sql` and assert final state rather than upgrade history.

- [ ] **Step 1: Point static contract tests at the baseline filename**

Replace per-history `os.ReadFile(...)` calls with one helper in each package:

```go
func readCurrentBaseline(t *testing.T) string {
    t.Helper()
    raw, err := os.ReadFile("0001_current_schema_baseline.sql")
    if err != nil {
        t.Fatalf("read current schema baseline: %v", err)
    }
    return strings.ToLower(string(raw))
}
```

For tests outside the migration directory, use the exact repository-relative migration path already resolved by that package.

- [ ] **Step 2: Replace compatibility assertions with final-state assertions**

Every baseline contract test must reject historical operations and Account-era naming:

```go
for _, forbidden := range []string{
    "rename column account_id",
    "drop table",
    "drop column",
    " account_id ",
} {
    if strings.Contains(sql, forbidden) {
        t.Fatalf("current baseline contains historical operation/name %q", forbidden)
    }
}
```

Retain the existing positive assertions for synthetic backtest keys, stop-failed status, unbound Venue wallets, notification/strategy user-FK boundaries, Order recovery fields, and lifecycle event identity. Change them to inspect the baseline file instead of numbered history files.

- [ ] **Step 3: Make runtime schema integration apply the full baseline twice**

In `migration_schema_test.go`, replace the prefix replay with:

```go
files := migrationFiles(t, migrationsDir)
applyMigrationFiles(ctx, t, db, files, "fresh")
applyMigrationFiles(ctx, t, db, files, "full-idempotency")
assertRuntimeIdentitySchema(ctx, t, db, schema)
```

Delete `filesWithPrefixAtLeast`; it has no purpose after history collapse.

- [ ] **Step 4: Add exact migration-set assertions**

Add to each domain test package:

```go
func TestCurrentMigrationSetIsBaselineOnly(t *testing.T) {
    entries, err := os.ReadDir(".")
    if err != nil { t.Fatal(err) }
    var got []string
    for _, entry := range entries {
        if !entry.IsDir() && strings.HasSuffix(entry.Name(), ".sql") {
            got = append(got, entry.Name())
        }
    }
    sort.Strings(got)
    want := []string{"0000_create_schema_migrations.sql", "0001_current_schema_baseline.sql"}
    if !reflect.DeepEqual(got, want) {
        t.Fatalf("migration set = %v, want %v", got, want)
    }
}
```

Scraper has no existing `0000`; its expected set is only `0001_current_schema_baseline.sql` because the scraper runner creates `schema_migrations` itself.

- [ ] **Step 5: Run tests and verify RED**

```bash
cd core-service
go test ./internal/storage/migrations ./internal/order/storage/migrations ./internal/order/repository
cd ../control-panel-service
go test ./internal/storage
cd ../scraper
go test ./internal/storage
```

Expected: tests fail because baseline files do not exist and historical files still exist.

### Task 2: Build the Portfolio and Order current baselines

**Files:**
- Create: `core-service/internal/storage/migrations/0001_current_schema_baseline.sql`
- Keep: `core-service/internal/storage/migrations/0000_create_schema_migrations.sql`
- Delete: all other Portfolio `.sql` migrations
- Create: `core-service/internal/order/storage/migrations/0001_current_schema_baseline.sql`
- Keep: `core-service/internal/order/storage/migrations/0000_create_schema_migrations.sql`
- Delete: all other Order `.sql` migrations
- Modify tests from Task 1 as needed to match exact final DDL.

**Interfaces:**
- Produces: fresh `portfolio` and `order` schemas consumed by current repositories.

- [ ] **Step 1: Assemble the Portfolio baseline in dependency order**

The SQL order must be:

```sql
CREATE EXTENSION IF NOT EXISTS timescaledb;
-- users
-- portfolios, venues, venue_wallet_states, venue_events
-- strategies, portfolio_strategies
-- strategy_sessions, session_venues
-- portfolio_snapshots + current_portfolio_snapshots view
-- reconciliation_runs
-- strategy_indicator_definitions, strategy_indicator_chunks
-- notification_plans, notification_settings, notification_channels
-- indexes, hypertables, triggers, and default notification plan rows
```

Fold the final state from these source migrations before deleting them:

| Final object | Source history to fold |
|---|---|
| users/plan | `0005`, `0006`, `0011`; omit fresh-DB backfill from `0036` |
| Portfolio/Venue/wallet/events/mounts | final definitions in `0019`, with nullable wallet owner from `0027` |
| snapshots/view | `0002`, `0021`, `0028` |
| strategies/runtime metadata | `0003`, `0017`, and no local-user FK per `0035` |
| sessions | `0004`, `0013`-`0015`, `0017`, `0023`, `0030`-`0032` |
| indicators | `0033`, `0037` |
| reconciliation | `0007`, `0008` |
| notifications | `0016`, `0029`, with no local-user FK per `0034` |

The finished baseline must use direct final `CREATE TABLE IF NOT EXISTS` definitions. It must not contain compatibility `ALTER`, `DROP`, rename, or backfill statements.

- [ ] **Step 2: Assemble the Order baseline in dependency order**

```sql
CREATE EXTENSION IF NOT EXISTS timescaledb;
-- order_intents
-- order_attempts
-- orders
-- order_fills + hypertable
-- order_lifecycle_events
-- final indexes and constraints
```

Fold `0006` through `0014` into direct final definitions, preserving:

- Venue/Portfolio/Session route facts.
- MARKET/LIMIT, post-only, good-till-date, reduce-only.
- `risk_status`, `risk_reasons_json`, RISK_REJECTED status 8.
- recovery status/timestamps/deadline/error/force-close fields.
- lifecycle `event_source`, `event_identity`, and partial unique identity index.
- Order fills Timescale hypertable and time indexes.

Do not include the `0014` Account-to-Portfolio rename operation; define `portfolio_id` directly.

- [ ] **Step 3: Delete historical SQL files only after both baselines exist**

Use `apply_patch` deletions. The exact surviving sets must be:

```text
internal/storage/migrations/0000_create_schema_migrations.sql
internal/storage/migrations/0001_current_schema_baseline.sql
internal/order/storage/migrations/0000_create_schema_migrations.sql
internal/order/storage/migrations/0001_current_schema_baseline.sql
```

- [ ] **Step 4: Run Core schema and repository tests**

```bash
cd core-service
go test ./internal/storage/migrations ./internal/order/storage/migrations \
  ./internal/order/repository ./internal/repository ./internal/service ./internal/order/...
go test ./...
go vet ./...
```

Expected: static contract tests and all repository/service tests pass.

- [ ] **Step 5: Commit Core baseline changes**

```bash
cd core-service
git add internal/storage/migrations internal/order/storage/migrations \
  internal/order/repository
git commit -m "refactor: baseline current portfolio and order schemas"
```

### Task 3: Build the Control Panel current baseline

**Files:**
- Create: `control-panel-service/internal/storage/migrations/0001_current_schema_baseline.sql`
- Keep: `control-panel-service/internal/storage/migrations/0000_create_schema_migrations.sql`
- Delete: all other Control Panel `.sql` migrations
- Modify: `control-panel-service/internal/storage/migration_environment_contract_test.go`
- Modify: `control-panel-service/internal/storage/migration_schema_test.go`

**Interfaces:**
- Produces: fresh Runtime, credential, debugger, Market Data control, and delivery schema.

- [ ] **Step 1: Build direct final definitions in dependency order**

```sql
-- runtime_registry
-- runtime_credentials
-- runtime_commands
-- runtime_channel_leases, runtime_admission_failures
-- market_data_streams, market_data_requests, market_data_history_requests
-- market_data_leases, market_data_writer_leases, market_data_coverage_segments
-- session_market_data_subscriptions, stream_delivery_leases, stream_delivery_failures
-- runtime_debug_datasets
-- final indexes and constraints
```

Fold the final state from `0001` through `0031`. Explicitly omit:

- `runtime_pairings` creation/drop (`0002`, `0009`).
- Account-to-Portfolio rename operations (`0031`).
- obsolete selected-runtime uniqueness that was later removed.

Preserve direct final values for:

- runtime source `hosted/self_hosted/bare`, role `executor/debugger`, lifecycle statuses.
- permanent per-user runtime name uniqueness and active hosted/debugger/credential guards.
- cleanup state and connection ownership.
- credential lifecycle, client cert fingerprint/expiry/issuer, and one-time secret semantics.
- RuntimeChannel resume/admission failures; bare runtime nullable credential lease.
- subscription `environment`, delivery progress and failure diagnostics.
- debug workspace fields on `runtime_registry` and `runtime_debug_datasets` metadata.

- [ ] **Step 2: Delete historical files and run schema tests**

```bash
cd control-panel-service
go test ./internal/storage -run 'Test(Current|ControlPanel|Session|Runtime)' -v
CONTROL_PANEL_TEST_DSN="$CONTROL_PANEL_TEST_DSN" go test ./internal/storage \
  -run TestControlPanelMigrationsExposeRuntimeIdentitySchema -v
```

The second command is required during the isolated DB task when the DSN is available; it may skip during this static task but must not be reported as passed if skipped.

- [ ] **Step 3: Run full Control Panel verification**

```bash
cd control-panel-service
go test ./...
go vet ./...
```

- [ ] **Step 4: Commit the baseline**

```bash
cd control-panel-service
git add internal/storage/migrations internal/storage/*migration*test.go
git commit -m "refactor: baseline current control panel schema"
```

### Task 4: Build the Market Data year baseline

**Files:**
- Create: `scraper/internal/storage/migrations/0001_current_schema_baseline.sql`
- Delete: `scraper/internal/storage/migrations/0001_enable_timescaledb.sql` through `0008_symbol_year_partitioning.sql`
- Modify: `scraper/internal/storage/timescale_test.go`
- Modify: `scraper/internal/storage/migrations/README.md`

**Interfaces:**
- Produces: one idempotent schema for every `{exchange}_{year}` database.

- [ ] **Step 1: Build the baseline from final table definitions**

The baseline must contain:

```sql
CREATE EXTENSION IF NOT EXISTS timescaledb;
-- spot_klines and futures_klines + hypertables
-- spot_orderbook and futures_orderbook + hypertables
-- futures_funding_rates + hypertable
-- futures_open_interest + hypertable
-- build_symbol_year_table(...) or the current equivalent dynamic creator
-- final symbol/year indexes
```

Fold `0002` through `0008` without losing the timestamp-year routing introduced by `0008`. Every base table uses `CREATE TABLE IF NOT EXISTS`; every hypertable call uses `if_not_exists => TRUE`.

- [ ] **Step 2: Update migration tests**

Keep the generic migration-ledger/advisory-lock tests. Add baseline assertions:

```go
func TestCurrentBaselineContainsAllMarketDataKinds(t *testing.T) {
    sql := readCurrentBaseline(t)
    for _, required := range []string{
        "spot_klines", "futures_klines", "spot_orderbook",
        "futures_orderbook", "futures_funding_rates",
        "futures_open_interest", "create_hypertable",
    } {
        if !strings.Contains(sql, required) {
            t.Fatalf("baseline missing %q", required)
        }
    }
}
```

- [ ] **Step 3: Run tests and commit**

```bash
cd scraper
go test ./internal/storage ./internal/scraper/...
go test ./...
go vet ./...
git add internal/storage/migrations internal/storage/timescale_test.go
git commit -m "refactor: baseline market data year schema"
```

### Task 5: Make deploy orchestration and schema bundles versioned

**Files:**
- Modify: `hushine-deploy/scripts/ensure-all-dbs.sh`
- Modify: `hushine-deploy/scripts/ensure-all-dbs-env.test.sh`
- Create: `hushine-deploy/scripts/db/render-schema-bundle.sh`
- Create: `hushine-deploy/db/README.md`
- Create generated files under: `hushine-deploy/db/generated/`
- Modify: `hushine-deploy/Makefile`
- Modify: `hushine-deploy/README.md`

**Interfaces:**
- Consumes: sibling service migration directories.
- Produces: `HUSHINE_SOURCE_ROOT` override and versioned `make db-schema-bundle`.

- [ ] **Step 1: Add a failing source-root orchestration test**

Extend `ensure-all-dbs-env.test.sh` so fake Make records every `-C` path and assert:

```bash
expected_root="$(cd .. && pwd)"
for repo in core-service control-panel-service scraper; do
  grep -Fq -- "-C ${expected_root}/${repo}" "$make_call_capture"
done
```

Also run once with `HUSHINE_SOURCE_ROOT=/tmp/hushine-source` and assert all `-C` paths use that override.

- [ ] **Step 2: Fix `ensure-all-dbs.sh` for sibling repositories**

Use:

```bash
DEPLOY_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
SOURCE_ROOT="${HUSHINE_SOURCE_ROOT:-$(cd -- "${DEPLOY_ROOT}/.." && pwd)}"
```

Change every service invocation from `$ROOT_DIR/<repo>` to `$SOURCE_ROOT/<repo>`. Before invoking Make, fail clearly if any required repository directory is missing.

- [ ] **Step 3: Add versioned bundle rendering**

Move the current workspace render logic into `hushine-deploy/scripts/db/render-schema-bundle.sh` with:

```bash
DEPLOY_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
SOURCE_ROOT="${HUSHINE_SOURCE_ROOT:-$(cd -- "${DEPLOY_ROOT}/.." && pwd)}"
OUT_DIR="${1:-${DEPLOY_ROOT}/db/generated}"
```

Tracked bundle headers must be deterministic. Remove the current wall-clock
`rendered_at` value and use a stable header such as:

```text
-- Generated by hushine-deploy/scripts/db/render-schema-bundle.sh
```

Render from these exact sources:

```text
$SOURCE_ROOT/core-service/internal/storage/migrations
$SOURCE_ROOT/core-service/internal/order/storage/migrations
$SOURCE_ROOT/control-panel-service/internal/storage/migrations
$SOURCE_ROOT/scraper/internal/storage/migrations
```

The generated README must say Baseline/fresh rebuild, not historical hard-cut.

- [ ] **Step 4: Add Makefile targets and generate bundles**

Add `db-schema-bundle` to `.PHONY`, help, and:

```make
db-schema-bundle:
	@bash scripts/db/render-schema-bundle.sh
```

Run:

```bash
cd hushine-deploy
bash scripts/ensure-all-dbs-env.test.sh
make db-schema-bundle
git diff --check
```

Expected generated files:

```text
db/generated/00_create_databases.psql
db/generated/portfolio.sql
db/generated/order.sql
db/generated/control_panel.sql
db/generated/market_data_year.sql
db/generated/README.md
```

- [ ] **Step 5: Commit versioned deployment ownership**

```bash
cd hushine-deploy
git add Makefile README.md scripts/ensure-all-dbs.sh \
  scripts/ensure-all-dbs-env.test.sh scripts/db db
git commit -m "feat: version current database bootstrap bundles"
```

### Task 6: Delete the broken audit entrypoint

**Files:**
- Delete: `hushine-deploy/scripts/audit/run_audit.sh`
- Modify: `hushine-deploy/Makefile`
- Modify: `hushine-deploy/README.md` if it mentions `make audit`

**Interfaces:**
- Keeps: `make test`, runtime smoke scripts, E2E, and Code Census where versioned.

- [ ] **Step 1: Record broken references**

```bash
cd hushine-deploy
rg -n 'test_indicator_scenarios|test_cross_margin|test_hedge_mode|test_liquidation_risk|test_wallet_hierarchy|test_binance_wallet' \
  scripts/audit/run_audit.sh
```

Expected: six nonexistent test-file references.

- [ ] **Step 2: Delete the script and target**

Remove `audit` from `.PHONY`, help text, and the Make target. Delete the script with `apply_patch`.

- [ ] **Step 3: Verify retained test entrypoints and commit**

```bash
cd hushine-deploy
if rg -n 'scripts/audit/run_audit\.sh|^audit:' Makefile scripts README.md; then exit 1; fi
rg -n '^test:|smoke-hosted-runtime|smoke-self-hosted-runtime|e2e' Makefile scripts
bash scripts/ensure-all-dbs-env.test.sh
git add Makefile README.md scripts/audit/run_audit.sh
git commit -m "chore: remove broken audit entrypoint"
```

### Task 7: Prove isolated one-shot deployment and idempotency

**Files:**
- Verification only; update docs/tests only if evidence reveals a real omission.

- [ ] **Step 1: Start a dedicated temporary TimescaleDB container**

```bash
cd /Users/xdy/Workplace/hushine
name="hushine-baseline-$(date +%s)-$$"
docker run -d --rm --name "$name" \
  -e POSTGRES_USER=postgres -e POSTGRES_PASSWORD=postgres -e POSTGRES_DB=postgres \
  -p 127.0.0.1::5432 timescale/timescaledb:2.17.2-pg16
port="$(docker port "$name" 5432/tcp | sed 's/.*://')"
printf 'isolated_db=127.0.0.1:%s container=%s\n' "$port" "$name"
```

Before continuing, assert `port` is nonempty and not `5432`. Arrange cleanup with `docker rm -f "$name"` at the end even on failure.

- [ ] **Step 2: Wait for readiness and run first bootstrap**

```bash
until PGPASSWORD=postgres pg_isready -h 127.0.0.1 -p "$port" -U postgres -d postgres; do sleep 1; done
PGHOST=127.0.0.1 PGPORT="$port" PGUSER=postgres PGPASSWORD=postgres \
PGDATABASE_ADMIN=postgres HUSHINE_SOURCE_ROOT=/Users/xdy/Workplace/hushine \
  bash hushine-deploy/scripts/ensure-all-dbs.sh
```

Expected: portfolio, order, control_panel, binance current-year, and okx current-year databases are created and all baseline migrations apply once.

- [ ] **Step 3: Inspect exact schema objects**

Run `psql` queries for every table listed in the approved design and verify:

```sql
SELECT extname FROM pg_extension WHERE extname = 'timescaledb';
SELECT tablename FROM pg_tables WHERE schemaname = 'public' ORDER BY tablename;
SELECT viewname FROM pg_views WHERE schemaname = 'public' ORDER BY viewname;
SELECT indexname FROM pg_indexes WHERE schemaname = 'public' ORDER BY indexname;
SELECT hypertable_name FROM timescaledb_information.hypertables ORDER BY hypertable_name;
SELECT filename, count(*) FROM schema_migrations GROUP BY filename ORDER BY filename;
```

Expected migration ledger per Portfolio/Order/Control DB:

```text
0000_create_schema_migrations.sql  1
0001_current_schema_baseline.sql   1
```

Expected market year ledger: `0001_current_schema_baseline.sql` exactly once.

- [ ] **Step 4: Run DB-backed schema and repository tests**

```bash
(cd control-panel-service && \
  CONTROL_PANEL_TEST_DSN="host=127.0.0.1 port=$port user=postgres password=postgres dbname=control_panel sslmode=disable" \
  go test ./internal/storage -run TestControlPanelMigrationsExposeRuntimeIdentitySchema -v)
(cd core-service && go test ./internal/repository ./internal/order/repository)
(cd scraper && go test ./internal/storage)
```

Expected: no skip and all tests pass. Record the output line proving the control-panel integration test ran.

- [ ] **Step 5: Run second bootstrap and compare state**

Capture the table/index/hypertable/ledger queries, run the same `ensure-all-dbs.sh` command again, then capture them again. Compare with `diff -u`.

Expected: second bootstrap exits 0 and the before/after schema inventories are identical.

- [ ] **Step 6: Validate manual bundles twice**

Execute the versioned bundles twice against the already isolated databases. The service
ledger and Baseline DDL are both required to tolerate this:

```bash
for pass in 1 2; do
  PGPASSWORD=postgres psql -h 127.0.0.1 -p "$port" -U postgres -d portfolio \
    -v ON_ERROR_STOP=1 -f hushine-deploy/db/generated/portfolio.sql
  PGPASSWORD=postgres psql -h 127.0.0.1 -p "$port" -U postgres -d order \
    -v ON_ERROR_STOP=1 -f hushine-deploy/db/generated/order.sql
  PGPASSWORD=postgres psql -h 127.0.0.1 -p "$port" -U postgres -d control_panel \
    -v ON_ERROR_STOP=1 -f hushine-deploy/db/generated/control_panel.sql
  year="$(date -u +%Y)"
  for db in "binance_${year}" "okx_${year}"; do
    PGPASSWORD=postgres psql -h 127.0.0.1 -p "$port" -U postgres -d "$db" \
      -v ON_ERROR_STOP=1 -f hushine-deploy/db/generated/market_data_year.sql
  done
done
```

Expected: both passes exit 0; no duplicate tables, indexes, constraints, hypertables, or seed rows.

- [ ] **Step 7: Run service build/smoke gates before cleanup**

```bash
cd /Users/xdy/Workplace/hushine
make build
bash hushine-deploy/scripts/e2e-runtime-channel-cutover.test.sh
bash hushine-deploy/scripts/restart-patterns.test.sh
bash hushine-deploy/scripts/self-hosted-runtime-script.test.sh
```

If an infra-backed full-flow smoke is run, pass the isolated `PGHOST`/`PGPORT` and verify its scripts do not override them. Never allow fallback to `192.168.88.10`.

- [ ] **Step 8: Remove the temporary container**

```bash
docker rm -f "$name"
```

Expected: the dedicated container is removed; no shared/local named volume was used.

### Task 8: Full workspace verification, statistics, commits, and push

**Files:**
- Verify/report only; no unplanned edits.

- [ ] **Step 1: Run the approved full test matrix**

```bash
cd core-service && go test ./... && go vet ./...
cd ../control-panel-service && go test ./... && go vet ./...
cd ../gateway/quant-handler && go test ./... && go vet ./...
cd ../../scraper && go test ./... && go vet ./...
cd ../golang-lib && go test ./... && go vet ./...
cd ../strategy-service
PYTHONPATH=.:../strategy-library uv run --frozen --extra dev pytest tests/ -q
go test ./... && go vet ./...
for test_script in scripts/*.test.sh; do bash "$test_script"; done
cd ../strategy-library && uv run pytest -q
cd ../strategy-debugger-cli && uv run pytest -q
cd ../gateway/quant-frontend && npm run build
for test_script in scripts/*.test.mjs; do node "$test_script"; done
cd ../..
openspec validate --all --strict --no-interactive
```

Expected: all commands exit 0. Record skips/failures exactly; do not report skipped infra checks as passing.

- [ ] **Step 2: Capture deletion statistics before pushing**

For every changed repository, save:

```bash
git diff <pre-cleanup-head>..HEAD --numstat
git diff <pre-cleanup-head>..HEAD --shortstat
git diff <pre-cleanup-head>..HEAD --name-status
```

Compute deleted lines, added lines, and net reduction separately for hand-written code, generated protobufs, migrations, tests, docs, and scripts.

- [ ] **Step 3: Push every changed current branch**

```bash
for repo in core-service control-panel-service strategy-service gateway/quant-handler scraper hushine-deploy; do
  git -C "$repo" push
  git -C "$repo" fetch --prune
  git -C "$repo" status -sb
done
```

Expected: every changed repository is clean with `ahead=0` and `behind=0`.
