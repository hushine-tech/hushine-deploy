# Hushine database bootstrap

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
| `PGHOST` | `192.168.88.10` | PostgreSQL/TimescaleDB host |
| `PGPORT` | `5432` | PostgreSQL port |
| `PGUSER` | `postgres` | bootstrap user |
| `PGPASSWORD` | `postgres` | bootstrap password |
| `PGDATABASE_ADMIN` | `postgres` | admin database used for `CREATE DATABASE` |
| `SCRAPER_DBS` | current Binance/OKX year DBs | explicit market-data database list |
| `SCRAPER_EXCHANGES` / `SCRAPER_YEARS` | `binance,okx` / current year | market-data database matrix |

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
| `portfolio` | `core-service` | `internal/storage/migrations/0000` through `0005`, in filename order |
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

Generate twice and require byte-identical output:

```bash
make db-schema-bundle
before="$(shasum -a 256 db/generated/*.sql db/generated/README.md)"
make db-schema-bundle
test "$before" = "$(shasum -a 256 db/generated/*.sql db/generated/README.md)"
```

For release acceptance, create four transient empty databases, apply the
matching bundle once, capture table/view/index/constraint/hypertable and ledger
inventories, apply the bundle a second time, and require identical inventories.
The current ledger counts are:

| Database | Expected migration rows |
|---|---:|
| `portfolio` | 6 |
| `order` | 4 |
| `control_panel` | 2 |
| one market-data year DB | 1 |

Both `0001_current_schema_baseline.sql` files are immutable compatibility
anchors. Verify their approved SHA-256 values before a release:

```text
portfolio bd77d355a6a22c1b8fe970d9e291780849bf55b9ee63ee75cc212761612cb970
order     6e2d179b9ecf706de8461ca6443efacfd22cb084ef6b49a0e2c94f2e49881b60
```

## Populated-upgrade checks

Before applying additive Spot migrations to a current-baseline database:

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
6. Run Spot migration integration tests and the focused Futures regression
   matrix before enabling any Spot capability.

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
  `spot_session_risk_facts`.
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
