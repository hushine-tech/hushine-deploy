# Hushine database bootstrap

Last verified: 2026-08-24 against core-service
`c00cdf6d8c82f67302c46b4bcd2e4d99ee1056d3`.

This is the deployment inventory for a fresh Hushine environment. Service
repositories own the schema source files; this repository owns orchestration,
review bundles, and deployment instructions.

The current schema starts from a rebuild baseline and then applies tracked
additive migrations. It does not upgrade an Account-era database to the
baseline in place. Rebuild an Account-era environment first; once the current
`0001` baseline is installed, later numbered migrations are forward-only and
must not be rewritten.

## One-shot bootstrap

Place `hushine-deploy` beside the service repositories and run:

```bash
make ensure-dbs
```

The command creates and initializes, in dependency order:

1. `portfolio`
2. `order`
3. `control_panel`
4. the configured `{exchange}_{year}` market-data databases

It is safe to run again. Applied filenames are recorded once in each
database's `schema_migrations` table.

By default the deploy repository uses its parent directory as the source root.
Set `HUSHINE_SOURCE_ROOT` when the service repositories live elsewhere:

```bash
HUSHINE_SOURCE_ROOT=/srv/hushine make ensure-dbs
```

Connection variables:

| Variable | Default | Purpose |
|---|---|---|
| `PGHOST` | runner-specific; local commands export `127.0.0.1` | PostgreSQL/TimescaleDB host; set explicitly outside the local workflow |
| `PGPORT` | `5432` | PostgreSQL port |
| `PGUSER` | `postgres` | bootstrap user |
| `PGPASSWORD` | `postgres` | bootstrap password |
| `PGDATABASE_ADMIN` | `postgres` | admin database used for `CREATE DATABASE` |
| `SCRAPER_DBS` | current Binance/OKX year DBs | explicit market-data database list |
| `SCRAPER_EXCHANGES` / `SCRAPER_YEARS` | `binance,okx` / current year | market-data database matrix |

The owner repositories retain different legacy `PGHOST` fallbacks, so
operators must not infer a shared deployment host from an omitted variable.
`make local-bootstrap`/`make local-ensure-dbs` set the local host explicitly;
other environments must do the same.

## Versioned SQL bundles

Refresh the tracked review/manual-bootstrap files with:

```bash
make db-schema-bundle
```

The deterministic output is stored under `db/generated/`:

| File | Run against |
|---|---|
| `00_create_databases.psql` | the `postgres` admin database |
| `portfolio.sql` | `portfolio` |
| `order.sql` | `order` |
| `control_panel.sql` | `control_panel` |
| `market_data_year.sql` | every `{exchange}_{year}` database |

Each schema bundle is transactional, idempotent, and maintains the same
`schema_migrations` ledger used by service bootstrap commands. One bundle run
on an empty database creates the complete current schema; running the same
bundle again is a no-op at the object and ledger level. The bundles are for
fresh rebuild and review, not an Account-era in-place upgrade.

## Schema sources

| Database | Owning repository | Source |
|---|---|---|
| `portfolio` | `core-service` | `internal/storage/migrations/0000` through `0008`, in filename order |
| `order` | `core-service` | `internal/order/storage/migrations/0000` through `0003`, in filename order |
| `control_panel` | `control-panel-service` | `internal/storage/migrations/0000_create_schema_migrations.sql` and `0001_current_schema_baseline.sql` |
| `{exchange}_{year}` | `scraper` | `internal/storage/migrations/0001_current_schema_baseline.sql` |

Exact current order:

### `portfolio`

1. `0000_create_schema_migrations.sql`
2. `0001_current_schema_baseline.sql`
3. `0002_spot_risk_facts.sql`
4. `0003_spot_reconciliation_repair.sql`
5. `0004_spot_close_reconciliation_pending.sql`
6. `0005_runtime_indicator_v2.sql`
7. `0006_strategy_owned_futures_leverage.sql`
8. `0007_strategy_leverage_notification_outbox.sql`
9. `0008_strategy_session_deprecated_leverage_zero.sql`

`0002` adds immutable per-session Spot risk facts. `0003` adds repair source,
status and identities to reconciliation history. `0004` adds the synchronous
`pending` repair tombstone used by Spot close failure handling. Because
`reconciliation_runs` is a Timescale hypertable, the pending lookup index is a
non-unique partial index on `(run_id, time DESC)`; a unique index that omits
the partitioning column cannot be created by TimescaleDB. Application-level
idempotency is serialized with a transaction-scoped advisory lock on `run_id`.
`0005` installs Indicator V2 chunk persistence and finalization. A fresh
baseline already contains the V2 tables, so ordinary one-shot bootstrap is
non-destructive. An older database that still contains V1 `values_json`
indicator tables remains behind the explicit acceptance/cutover guard.

`0006` adds the durable strategy-launch journal, per-target apply attempts,
credential/symbol admission, and authoritative Session target leverage facts.
`0007` adds the crash-safe rollback-failure notification outbox, deduplicated
by launch operation. `0008` changes only the deprecated
`strategy_sessions.leverage` check from `> 0` to `>= 0`: the default remains
`1`, historical values are not rewritten, and zero means that a new
coordinated Session has no truthful session-wide scalar. New Futures reads use
target facts; historical Sessions with no facts may still expose their positive
legacy scalar.

### `order`

1. `0000_create_schema_migrations.sql`
2. `0001_current_schema_baseline.sql`
3. `0002_spot_order_route_identity.sql`
4. `0003_spot_close_operations.sql`

`0002` adds exact cumulative/quote quantities, route-qualified fill identity
and route-qualified lifecycle indexes. `0003` adds durable Spot close
operations, target state and admission leases.

Future additive migrations continue with the next filename. Do not edit,
rename, reorder or reuse an already deployed filename.

## Fresh-bundle verification

Render to a temporary directory and require byte-identical output:

```bash
generated_check_dir="$(mktemp -d)"
bash scripts/db/render-schema-bundle.sh "$generated_check_dir"
diff -ru "$generated_check_dir" db/generated
find "$generated_check_dir" -type f -delete
rmdir "$generated_check_dir"
```

For release acceptance, create four transient empty databases, apply the
matching bundle once, capture table/view/index/constraint/hypertable and ledger
inventories, apply the bundle a second time, and require identical inventories.
The current ledger counts are:

| Database | Expected migration rows |
|---|---:|
| `portfolio` | 9 |
| `order` | 4 |
| `control_panel` | 2 |
| one market-data year DB | 1 |

Both `0001_current_schema_baseline.sql` files are immutable compatibility
anchors. Verify their approved SHA-256 values before a release:

```text
portfolio 80ddde3a21e385dde2cdb7b292e26fa3d055997e9ddbbf99593742d199a17a8c
order     6e2d179b9ecf706de8461ca6443efacfd22cb084ef6b49a0e2c94f2e49881b60
```

## Populated-upgrade checks

Before applying additive migrations to a current-baseline database:

1. Record row counts and stable identities for `orders`, `order_fills`,
   `order_lifecycle_events`, `portfolio_snapshots`, `reconciliation_runs`,
   `strategy_sessions` and wallet-state tables.
2. Record route identity columns for every existing Futures order/fill and the
   current `schema_migrations` filenames.
3. Apply each pending migration with the service migration runner; body and
   ledger insert must commit atomically.
4. Re-run the same migration runner and require every migration to be skipped.
5. Compare pre/post row counts and identities. Backfill may populate new
   columns or `order_fill_identities`; it must not delete, renumber or merge
   historical order/fill/lifecycle/session/snapshot rows.
6. For `0006` through `0008`, inspect all launch journal, admission, target fact,
   and outbox constraints/indexes; prove the old Session row still reads its
   legacy scalar; prove the default remains `1`, zero is accepted, and negative
   values are rejected.
7. Run Spot migration integration tests and the focused Futures regression
   matrix before enabling the corresponding capability.

Rollback is capability-first: disable new Spot admission and roll consumers
back in reverse order. Never delete order, fill, close-operation, wallet,
snapshot or reconciliation history, and never remove an applied migration
from `schema_migrations`. Correct a database defect with a new forward
migration.

## Current object inventory

### `portfolio`

- Identity and policy: `users`, `notification_plans`,
  `notification_settings`, `notification_channels`.
- Portfolio/Venue state: `portfolios`, `venues`, `venue_wallet_states`,
  `venue_events`, `portfolio_strategies`.
- Strategy execution: `strategies`, `strategy_sessions`, `session_venues`,
  `strategy_indicator_definitions`, `strategy_indicator_chunks`,
  `spot_session_risk_facts`, `strategy_launch_operations`,
  `strategy_leverage_apply_attempts`, `strategy_target_admissions`, and
  `strategy_session_target_facts`.
- Strategy leverage recovery delivery:
  `strategy_leverage_notification_outbox`.
- Audit/state history: `portfolio_snapshots` and `reconciliation_runs` are
  Timescale hypertables with seven-day chunks.
- Read model: `current_portfolio_snapshots` view.

Telegram binding and notification preferences remain part of the current
schema. Strategy ownership and notification ownership are authenticated by the
API and intentionally do not depend on local `users` foreign keys.

### `order`

- `order_intents`
- `order_attempts`
- `orders`
- `order_fills` (Timescale hypertable with one-day chunks)
- `order_lifecycle_events`
- `order_fill_identities`
- `spot_close_operations`
- `spot_close_targets`
- `spot_order_admission_leases`

These tables preserve Portfolio/Venue/Session route facts, MARKET/LIMIT
semantics, risk decisions, recovery state, and lifecycle event identity.

### `control_panel`

- Runtime: `runtime_registry`, `runtime_credentials`, `runtime_commands`,
  `runtime_channel_leases`, `runtime_admission_failures`,
  `runtime_debug_datasets`.
- Market-data control: `market_data_streams`, `market_data_requests`,
  `market_data_history_requests`, `market_data_leases`,
  `market_data_writer_leases`, `market_data_coverage_segments`.
- Session delivery: `session_market_data_subscriptions`,
  `stream_delivery_leases`, `stream_delivery_failures`.

`runtime_pairings` is not part of the current schema. Runtime sessions route by
`runtime_id`; hosted, self-hosted, and guarded bare/debugger runtime state is
kept in the objects above.

### `{exchange}_{year}`

- `spot_klines`
- `futures_klines`
- `spot_orderbook`
- `futures_orderbook`
- `futures_funding_rates`
- `futures_open_interest`

All six base tables are one-day Timescale hypertables. The baseline also keeps
the symbol/year compatibility table helper; dynamically created tables use
one-month chunks. Current writes are routed to the database selected from the
event timestamp.

`strategy-service` owns no database tables. Runtime and session workers use
platform proxies rather than receiving internal database addresses.
