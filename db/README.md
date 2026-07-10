# Hushine database bootstrap

This is the deployment inventory for a fresh Hushine environment. Service
repositories own the schema source files; this repository owns orchestration,
review bundles, and deployment instructions.

The current schema is a rebuild baseline. It does not upgrade an older
Account-era or multi-migration database in place. Wipe and rebuild the target
environment before switching to this baseline.

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
`schema_migrations` ledger used by service bootstrap commands. The bundles are
for Baseline/fresh rebuild and review, not in-place upgrades of old databases.

## Schema sources

| Database | Owning repository | Source |
|---|---|---|
| `portfolio` | `core-service` | `internal/storage/migrations/0000_create_schema_migrations.sql` and `0001_current_schema_baseline.sql` |
| `order` | `core-service` | `internal/order/storage/migrations/0000_create_schema_migrations.sql` and `0001_current_schema_baseline.sql` |
| `control_panel` | `control-panel-service` | `internal/storage/migrations/0000_create_schema_migrations.sql` and `0001_current_schema_baseline.sql` |
| `{exchange}_{year}` | `scraper` | `internal/storage/migrations/0001_current_schema_baseline.sql` |

Future additive migrations continue with the next filename after the baseline;
do not rewrite an already deployed filename.

## Current object inventory

### `portfolio`

- Identity and policy: `users`, `notification_plans`,
  `notification_settings`, `notification_channels`.
- Portfolio/Venue state: `portfolios`, `venues`, `venue_wallet_states`,
  `venue_events`, `portfolio_strategies`.
- Strategy execution: `strategies`, `strategy_sessions`, `session_venues`,
  `strategy_indicator_definitions`, `strategy_indicator_chunks`.
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
