# Clean-Slate Configuration, Indicator, and Database Baseline Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Delete obsolete config/RPC/status aliases, Indicator V1 and market-data cutover paths, compatibility logger exports, and every incremental migration superseded by fresh current baselines.

**Architecture:** Each service accepts one documented configuration and one current protocol. Database creation starts from empty state using `0000` only where required plus a complete `0001_current_schema_baseline.sql`; no old-schema inspection or upgrade authorization remains.

**Tech Stack:** Go, Python, Protocol Buffers, PostgreSQL/TimescaleDB, SQL migrations, shell deployment scripts

**Spec:** `docs/superpowers/specs/2026-08-24-clean-slate-compatibility-removal-design.md`

## Global Constraints

- Existing local test/demo databases are disposable.
- Preserve current deployment, RuntimeChannel isolation, live/historical market-data functions, Indicator V2 chunk/finalization, ELK, Kafka, Jaeger, and coverage startup.
- A renamed setting or RPC has one current name; no precedence chain or deprecated endpoint remains.
- Migration execution infrastructure may remain, but it supports fresh creation only.
- Do not treat the word `historical` in market-data scope as compatibility.

---

### Task 1: Create a failing compatibility inventory gate

**Files:**
- Create: `hushine-deploy/scripts/audit/no-first-party-compatibility.sh`
- Create: `hushine-deploy/scripts/audit/no-first-party-compatibility.test.sh`
- Modify: `hushine-deploy/Makefile`

**Interfaces:**
- Consumes: workspace production source.
- Produces: one auditable gate with an explicit allowlist for external protocol terms and current historical market-data semantics.

- [ ] **Step 1: Write the gate test first**

The test creates a temporary fixture containing `legacy`, `deprecated`, and `compatibility` production markers and requires the scanner to fail while allowing `scope == "historical"`.

```bash
if "$SCANNER" "$fixture"; then
  echo "scanner accepted a first-party compatibility marker" >&2
  exit 1
fi
rm "$fixture/legacy.go"
printf '%s\n' 'if scope == "historical" {}' > "$fixture/current.go"
"$SCANNER" "$fixture"
```

- [ ] **Step 2: Run the test and verify RED**

```bash
cd hushine-deploy
bash scripts/audit/no-first-party-compatibility.test.sh
```

Expected: FAIL because the scanner does not exist.

- [ ] **Step 3: Implement the scanner**

The scanner searches authored production code, proto, SQL, and current docs while excluding generated artifacts, dependencies, test fixtures, dated Superpowers history, and the explicit current phrase `historical market data`. It prints every candidate as `path:line:text` and exits nonzero. It must not delete anything.

- [ ] **Step 4: Run against the workspace and capture the expected failing inventory**

```bash
bash hushine-deploy/scripts/audit/no-first-party-compatibility.sh .
```

Expected: FAIL with current config aliases, V1 cutover, logger exports, and old protocol paths.

- [ ] **Step 5: Commit the red gate**

```bash
git -C hushine-deploy add scripts/audit Makefile
git -C hushine-deploy commit -m "test: inventory first-party compatibility code"
```

### Task 2: Remove config, status, plan, and RPC aliases

**Files:**
- Modify: `core-service/internal/config/config.go`
- Modify: `control-panel-service/internal/config/config.go`
- Modify: `control-panel-service/internal/domain/runtime.go`
- Modify: `control-panel-service/internal/plan/resolver.go`
- Modify: `control-panel-service/internal/runtime/service.go`
- Modify: `control-panel-service/internal/runtimechannel/platform_proxy.go`
- Modify: `control-panel-service/proto/control_panel_service.proto`
- Modify: `strategy-service/strategy_service/platform_proxy.py`
- Modify: `scraper/internal/config/config.go`
- Modify: `core-service/internal/config/config_test.go`
- Modify: `control-panel-service/internal/config/config_test.go`
- Modify: `control-panel-service/internal/plan/resolver_test.go`
- Modify: `control-panel-service/internal/runtime/service_test.go`
- Modify: `control-panel-service/internal/runtimechannel/platform_proxy_test.go`
- Modify: `scraper/internal/config/config_test.go`
- Modify: `strategy-service/tests/test_platform_proxy.py`
- Regenerate control-panel Go/Python artifacts through `control-panel-service/Makefile` and `strategy-service/generate_proto.sh`.

**Interfaces:**
- Consumes: canonical environment/YAML keys and current RPC/status values.
- Produces: one setting/status/RPC per behavior.

- [ ] **Step 1: Add canonical-only config tests**

For each service, set only the documented current variables and assert they load. Set `TIMESCALEDB_DSN`, `MOCK_BINANCE`, `SYMBOL_CACHE_TTL`, `HTTP_ADDR`, `GRPC_ADDR`, and renamed runtime pool/environment keys and assert they do not override configuration.

- [ ] **Step 2: Run config tests and verify RED**

```bash
cd core-service && go test ./internal/config -count=1
cd ../control-panel-service && go test ./internal/config ./internal/runtime ./internal/plan ./internal/runtimechannel -count=1
cd ../scraper && go test ./internal/config -count=1
```

- [ ] **Step 3: Delete alias precedence and retained config fields**

Remove old environment/YAML fields and `else if old-name` branches. Update local/deploy configuration to current names in the same task.

- [ ] **Step 4: Remove old status and RPC behavior**

Delete `RuntimeStatusPaired`, old empty-plan fallback, deprecated include/exclude flag, `portfolio.UpdatePortfolioSnapshot`, and compatibility branches in runtime service. Keep current `UpdatePortfolioWalletState`, `include_inactive`, and current runtime statuses.

- [ ] **Step 5: Regenerate protocol artifacts**

```bash
cd control-panel-service && make proto
cd ../strategy-service && PYTHON=.venv/bin/python ./generate_proto.sh
```

- [ ] **Step 6: Run and commit each repository**

```bash
cd core-service && go test ./internal/config && go vet ./internal/config
cd ../control-panel-service && go test ./internal/config ./internal/runtime ./internal/plan ./internal/runtimechannel && go vet ./...
cd ../scraper && go test ./internal/config && go vet ./internal/config
cd ../strategy-service && PYTHONPATH=.:../strategy-library uv run --frozen --extra dev pytest tests/test_platform_proxy.py -q
```

Commit `refactor: remove configuration compatibility aliases` in core-service, control-panel-service, scraper, and strategy-service.

### Task 3: Remove market-data aliases and old logging APIs

**Files:**
- Modify: `control-panel-service/proto/marketdata_service.proto`
- Modify: `control-panel-service/internal/marketdata/**`
- Modify: `strategy-library/market_data/config.py`
- Modify: `scraper/internal/storage/timescale.go`
- Modify: `golang-lib/py_log/log/logger.py`
- Modify: `strategy-library/utils/log/logger.py`
- Modify: `strategy-debugger-cli/src/hushine_debugger/templates/hushine-debug.yaml`
- Modify: `control-panel-service/internal/marketdata/service_test.go`
- Modify: `strategy-library/market_data/tests/test_config.py`
- Modify: `scraper/internal/storage/timescale_test.go`
- Modify: `golang-lib/py_log/log/test_context.py`
- Modify: `strategy-library/utils/log/test_logger.py`
- Modify: `strategy-debugger-cli/tests/test_config.py`
- Modify: `strategy-debugger-cli/tests/test_workspace.py`

**Interfaces:**
- Consumes: explicit `live` or `historical` scope, full input keys, symbol-suffixed scraper tables, and current `init_log`.
- Produces: no empty-scope default, single-interval alias, old table fallback, or old logger initializer.

- [ ] **Step 1: Add failing canonical-only tests**

Require empty market-data scope to be invalid, require `allowed_inputs` instead of single-interval fields, require current table naming, and require old logger exports to be absent.

- [ ] **Step 2: Verify RED**

```bash
cd control-panel-service && go test ./internal/marketdata -count=1
cd ../strategy-library && uv run --frozen pytest -q
cd ../scraper && go test ./internal/storage -count=1
```

- [ ] **Step 3: Delete aliases**

Remove empty-to-live scope conversion, legacy single-interval storage/read paths, scraper table-without-symbol lookup, duplicate logger initializers, and debugger user-id zero/manual-workspace behavior. Update all current callers.

- [ ] **Step 4: Preserve current market-data behavior**

Keep explicit live stream lifecycle, explicit historical requested ranges, Timescale coverage, Kafka delivery for finalized live klines, and the current debugger import-managed workspace.

- [ ] **Step 5: Run and commit**

Run full suites in control-panel-service, strategy-library, scraper, golang-lib, and strategy-debugger-cli; commit separately per repository.

### Task 4: Collapse portfolio and order schemas to fresh baselines

**Files:**
- Modify: `core-service/internal/storage/migrations/0001_current_schema_baseline.sql`
- Keep if runner requires: `core-service/internal/storage/migrations/0000_create_schema_migrations.sql`
- Delete: `core-service/internal/storage/migrations/0002_spot_risk_facts.sql`
- Delete: `core-service/internal/storage/migrations/0003_spot_reconciliation_repair.sql`
- Delete: `core-service/internal/storage/migrations/0004_spot_close_reconciliation_pending.sql`
- Delete: `core-service/internal/storage/migrations/0005_runtime_indicator_v2.sql`
- Delete: `core-service/internal/storage/migrations/0006_strategy_owned_futures_leverage.sql`
- Delete: `core-service/internal/storage/migrations/0007_strategy_leverage_notification_outbox.sql`
- Delete: `core-service/cmd/ensure-portfolio-db/cutover_guard.go`
- Delete: `core-service/cmd/ensure-portfolio-db/cutover_guard_test.go`
- Modify: `core-service/cmd/ensure-portfolio-db/main.go`
- Modify: `core-service/internal/storage/migrations/baseline_contract_test.go`
- Modify: `core-service/internal/storage/migrations/indicator_v2_integration_test.go`
- Modify: `core-service/internal/storage/migrations/migration_contract_test.go`
- Delete: `core-service/internal/storage/migrations/spot_reconciliation_repair_migration_test.go`
- Delete: `core-service/internal/storage/migrations/spot_risk_facts_migration_test.go`
- Delete: `core-service/internal/storage/migrations/strategy_leverage_notification_outbox_migration_test.go`
- Modify: `core-service/internal/order/storage/migrations/0001_current_schema_baseline.sql`
- Keep if required: `core-service/internal/order/storage/migrations/0000_create_schema_migrations.sql`
- Delete: `core-service/internal/order/storage/migrations/0002_spot_order_route_identity.sql`
- Delete: `core-service/internal/order/storage/migrations/0003_spot_close_operations.sql`
- Modify: `core-service/internal/order/storage/migrations/baseline_contract_test.go`
- Modify: `core-service/internal/order/storage/migrations/order_environment_contract_test.go`
- Delete: `core-service/internal/order/storage/migrations/spot_order_route_identity_migration_test.go`
- Update generated baseline: `hushine-deploy/db/generated/portfolio.sql`

**Interfaces:**
- Consumes: final schemas from the previous two plans.
- Produces: empty portfolio and order databases fully created by current baselines.

- [ ] **Step 1: Add fresh-bootstrap integration tests**

Create empty temporary PostgreSQL databases, run the current migration command once, and assert current tables for Spot risk, reconciliation, Indicator V2, leverage operations/facts/admissions, notification outbox, route identity, and Spot close operations exist with canonical columns.

- [ ] **Step 2: Run tests and verify RED after staging deletion expectations**

The contract test must require the migration directory to contain only `0000` where needed and `0001_current_schema_baseline.sql`.

- [ ] **Step 3: Merge every final object into the two baselines**

Copy final table/index/constraint/trigger definitions, but omit obsolete columns and all conditional old-schema transforms. Ensure creation order satisfies foreign keys from an empty database.

- [ ] **Step 4: Delete incremental migrations and cutover guard**

Remove Indicator V1 inspection, acceptance owner/seal modes, and incremental-upgrade authorization flags from the ensure command and deployment environment.

- [ ] **Step 5: Regenerate deployment SQL**

Use the repository's tracked database generation command; compare object lists between service baseline and `hushine-deploy/db/generated/portfolio.sql`.

- [ ] **Step 6: Run fresh bootstrap twice**

First run on empty databases must create everything. Second run must be a clean no-op through the migration runner, not an old-schema upgrade.

- [ ] **Step 7: Run core verification and commit**

```bash
cd core-service
go test ./cmd/ensure-portfolio-db ./cmd/ensure-order-db ./internal/storage/migrations ./internal/order/storage/migrations -count=1
go test ./...
go vet ./...
```

Commit baseline and deleted migrations in core-service; commit regenerated SQL separately in hushine-deploy.

### Task 5: Collapse control-panel and scraper baselines

**Files:**
- Modify: `control-panel-service/internal/storage/migrations/0001_current_schema_baseline.sql`
- Keep if required: `control-panel-service/internal/storage/migrations/0000_create_schema_migrations.sql`
- Delete: `control-panel-service/internal/storage/migrations/0002_runtime_session_cleanup_outbox.sql`
- Modify: `control-panel-service/internal/storage/baseline_contract_test.go`
- Modify: `control-panel-service/internal/storage/migration_environment_contract_test.go`
- Modify: `control-panel-service/internal/storage/migration_schema_test.go`
- Modify: `scraper/internal/storage/migrations/0001_current_schema_baseline.sql`
- Modify: `scraper/internal/storage/migrations/README.md`
- Modify fresh-baseline tests in both repositories.

**Interfaces:**
- Consumes: current runtime cleanup outbox and symbol-keyed scraper schema.
- Produces: one-pass fresh control-panel and market-data databases.

- [ ] **Step 1: Write failing baseline-only file-set tests**

Assert each migration directory contains only the bootstrap metadata migration where required and one current baseline.

- [ ] **Step 2: Merge current objects and delete incremental files**

Move runtime cleanup outbox into control-panel `0001`; ensure scraper baseline contains only current symbol-keyed structures.

- [ ] **Step 3: Test empty database creation**

Run repository ensure commands against disposable local databases and assert current repository smoke queries pass.

- [ ] **Step 4: Run full repository checks and commit**

```bash
cd control-panel-service && go test ./... && go vet ./...
cd ../scraper && go test ./... && go vet ./...
```

### Task 6: Remove obsolete docs and pass the compatibility gate

**Files:**
- Delete/replace: `hushine-deploy/docs/strategy-owned-futures-leverage.md` sections that prescribe scalar compatibility.
- Delete superseded compatibility plan/spec artifacts only after current docs retain canonical leverage behavior.
- Modify current repository READMEs and operator/user docs.
- Modify: `hushine-deploy/scripts/audit/no-first-party-compatibility.sh`

**Interfaces:**
- Consumes: completed canonical code and baselines.
- Produces: current documentation and zero unexplained compatibility candidates.

- [ ] **Step 1: Update current documentation**

Document only target leverage, canonical Spot assets, exact values, current RuntimeChannel, explicit market-data scopes, current config names, and one-shot databases.

- [ ] **Step 2: Delete superseded compatibility instructions**

Remove docs that tell operators or users to use old fields, aliases, migrations, or startup paths. Retain this approved design and execution plans as the decision record.

- [ ] **Step 3: Run the scanner**

```bash
bash hushine-deploy/scripts/audit/no-first-party-compatibility.sh .
```

Every remaining candidate must be either removed or documented in the scanner allowlist with a current external/protocol justification. The allowlist may not contain first-party old field names.

- [ ] **Step 4: Run documentation and repository checks**

```bash
cd hushine-deploy
bash scripts/audit/no-first-party-compatibility.test.sh
openspec validate --all --strict --no-interactive
```

OpenSpec is validation only; Superpowers remains the implementation workflow.

- [ ] **Step 5: Commit documentation and gate changes**

Commit `docs: describe clean-slate canonical platform` in hushine-deploy.
