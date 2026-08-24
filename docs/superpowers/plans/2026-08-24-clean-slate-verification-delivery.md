# Clean-Slate Full-System Verification and Delivery Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Prove the clean-slate removal preserves every current product function, measure the exact reduction, review the final code, and push all repository branches.

**Architecture:** Verification proceeds from static contract gates to repository suites, empty-database deployment, mock exchange matrices, and signed-in browser acceptance under coverage. Delivery is blocked on fresh evidence from every layer.

**Tech Stack:** Go/Python/Node test suites, Docker Compose, PostgreSQL/TimescaleDB, Kafka, ELK, Jaeger, Mock Binance, coverage census, in-app browser

**Spec:** `docs/superpowers/specs/2026-08-24-clean-slate-compatibility-removal-design.md`

## Global Constraints

- Do not claim success from earlier test output; every completion claim uses fresh output from the final tree.
- Do not restore compatibility to resolve a regression.
- Keep credentials in the credential manager/environment and never print them in commands, logs, screenshots, or reports.
- Fresh local databases and Docker volumes may be destroyed and recreated.
- Push only after repository status, test evidence, line accounting, and self-review are complete.

---

### Task 1: Establish final-tree source and repository integrity

**Files:**
- Modify only if the checks expose a current-contract defect.
- Produce evidence under `census-runs/clean-slate-final-20260824/`.

**Interfaces:**
- Consumes: all implementation commits from the first three plans.
- Produces: clean repository state and a static compatibility/census report.

- [ ] **Step 1: Inspect every repository status and branch**

```bash
for repo in core-service control-panel-service scraper strategy-service strategy-library strategy-debugger-cli gateway/quant-handler gateway/quant-frontend golang-lib hushine-deploy; do
  git -C "$repo" status --short
  git -C "$repo" branch --show-current
done
```

Expected: only owned planned changes before commits; after commits, clean status on `cleanup/medium-baseline-20260710`.

- [ ] **Step 2: Run compatibility and generated-code checks**

```bash
bash hushine-deploy/scripts/audit/no-first-party-compatibility.sh .
git -C core-service diff --exit-code -- gen
git -C strategy-service diff --exit-code -- gen strategy_service/gen
git -C control-panel-service diff --exit-code -- gen
```

Regenerate first, then require no generator drift.

- [ ] **Step 3: Run static code census**

```bash
cd hushine-deploy
RUN_ID=clean-slate-final-20260824 make code-census-static
```

Review every suspicious-legacy candidate manually; zero first-party compatibility candidate may remain.

### Task 2: Run every repository test and build

**Files:**
- Modify only when a current function fails.

**Interfaces:**
- Consumes: final source tree.
- Produces: complete unit, contract, static-analysis, and build evidence.

- [ ] **Step 1: Run core-service**

```bash
cd core-service
go test ./... -count=1
go vet ./...
go build ./...
```

- [ ] **Step 2: Run control-panel-service and scraper**

```bash
cd control-panel-service
go test ./... -count=1
go vet ./...
go build ./...
cd ../scraper
go test ./... -count=1
go vet ./...
go build ./...
```

- [ ] **Step 3: Run strategy-service, library, and debugger**

```bash
cd strategy-service
PYTHONPATH=.:../strategy-library uv run --frozen --extra dev pytest tests/ -q
go test ./... -count=1
go vet ./...
bash scripts/start-bare-runtime-debugpy.test.sh
bash scripts/runtime-agent-platform.test.sh
cd ../strategy-library
uv run --frozen pytest -q
cd ../strategy-debugger-cli
uv run --frozen --extra test pytest -q
```

- [ ] **Step 4: Run gateways**

```bash
cd gateway/quant-handler
go test ./... -count=1
go vet ./...
go build ./...
cd ../quant-frontend
for test_file in scripts/*.test.mjs; do node "$test_file"; done
npm run build
```

- [ ] **Step 5: Run deployment contracts**

```bash
cd hushine-deploy
bash scripts/audit/no-first-party-compatibility.test.sh
openspec validate --all --strict --no-interactive
make test-runtime-indicator-v2
```

If any check fails, write a focused failing regression test, verify RED, fix only the canonical path, and rerun the repository's full block.

### Task 3: Rebuild the entire local platform from empty state

**Files:**
- Modify local generated configs only through tracked generation commands.
- Do not commit secrets or machine-specific runtime artifacts.

**Interfaces:**
- Consumes: one-shot baselines and coverage-capable runtime image.
- Produces: healthy local TimescaleDB/PostgreSQL, Kafka, ELK, Jaeger, services, and hosted runtime.

- [ ] **Step 1: Stop services and destroy local infrastructure volumes**

```bash
cd hushine-deploy
make local-stop
make local-infra-reset
```

- [ ] **Step 2: Build normal and coverage runtime images**

```bash
make runtime-image IMAGE_TAG=dev
make runtime-images-verify
```

Expected: image verification confirms strategy code, dependencies, Runtime worker entrypoint, and coverage tooling.

- [ ] **Step 3: Generate local configs and start infrastructure**

```bash
make local-configs
make local-infra-up
make local-infra-ps
```

Require healthy PostgreSQL/TimescaleDB, Kafka, Elasticsearch, Logstash, Kibana, Jaeger, and bridge containers.

- [ ] **Step 4: Create databases from empty state**

```bash
make local-ensure-dbs
```

Run the command a second time and require a clean no-op. Query migration tables and current object inventories to prove only fresh baselines were used.

- [ ] **Step 5: Start all services with coverage enabled**

```bash
make local-start
```

Verify frontend `:5173`, handler `:8090`, core gRPC `:50051`, control gRPC `:50054`, RuntimeChannel `:50055`, scraper, ELK, and Jaeger health. Confirm credential-manager encryption key is present before accepting credentials.

### Task 4: Execute the Mock Binance trading matrix

**Files:**
- Modify mock fixtures/tests only when a current supported scenario is missing.
- Never add a legacy request shape.

**Interfaces:**
- Consumes: current Spot/Futures order protocol and canonical wallets.
- Produces: deterministic execution evidence for order type, time-in-force, account mode, fills, and errors.

- [ ] **Step 1: Run existing mock server and adapter suites**

```bash
cd core-service
go test ./internal/exchange/binance/mockserver ./internal/exchange/binance/... ./internal/order/... -count=1
```

- [ ] **Step 2: Cover Spot matrix**

Verify MARKET BUY/SELL, LIMIT GTC, LIMIT IOC, LIMIT FOK, full fill, partial fill where valid, expiry, rejection, insufficient balance, min quantity/notional, tick/step filters, fees, locked/free changes, and reconciliation.

- [ ] **Step 3: Cover Futures matrix**

Verify MARKET/LIMIT with supported GTC/IOC/FOK, cross/isolated, one-way/hedge, LONG/SHORT position side, reduce-only, multi-symbol BTC/ETH/ZEC, per-target leverage, liquidation/max-loss behavior, fees, and reconciliation.

- [ ] **Step 4: Cover leverage startup failures**

Verify read failure, set failure, confirmation mismatch, reverse rollback order, rollback confirmation, rollback failure admission retention, one deduplicated Telegram/system notification, and no worker launch before atomic commit.

- [ ] **Step 5: Run the complete mock suite again**

Run `go test ./... -count=1` in core-service and the strategy wallet/runtime suites after adding any missing matrix case.

### Task 5: Execute signed-in browser acceptance under coverage

**Files:**
- Modify product code only after reproducing a defect with an automated test.
- Store screenshots/coverage evidence in the current census run.

**Interfaces:**
- Consumes: signed-in local frontend and healthy local platform.
- Produces: end-user workflow and runtime coverage evidence.

- [ ] **Step 1: Use the in-app browser control skill**

Open the existing signed-in local page. Do not create a second browser profile unless the current session is unavailable.

- [ ] **Step 2: Test Quick Start and stream readiness**

Create/select canonical BTCUSDT, ETHUSDT, and ZECUSDT inputs. Confirm missing streams are clearly reported and current Manage Streams can create/activate them without any old request field.

- [ ] **Step 3: Test Spot**

Create a Spot USDT Venue and run low-buy/high-sell behavior. Verify asset/free/locked display, orders, fills, fees, chart, Session history, stop/recoverable behavior, and no cross/hedge/leverage controls.

- [ ] **Step 4: Test Futures**

Run cross and isolated sessions, one-way and hedge where supported, and the BTC/ETH/ZEC multi-symbol strategy. Confirm preview and Session detail show strategy-derived per-target leverage, Binance confirmation, correct initial wallet balance, positions, UPnL, orders, fills, and liquidation/max-loss behavior.

- [ ] **Step 5: Test indicators**

Exercise scalar indicators and buy/sell markers. Verify repeated 1023-row tails update idempotently; a subsequent two rows create one finalized 1024-row block plus one mutable row; finalization closes the remaining tail and every marker appears.

- [ ] **Step 6: Test worker isolation and restart**

Run a deliberately blocked/ten-minute strategy loop and confirm Runtime heartbeat remains healthy. Invoke one-line restart; verify old worker/state cleanup, recoverable transition, new operation/Session ID, reread code, typed bootstrap, and no runtime-agent restart.

- [ ] **Step 7: Test Telegram and observability**

Trigger order, failure, rollback-failure, and Session lifecycle notifications. Verify Telegram delivery/deduplication and inspect Elasticsearch/Jaeger for current request paths without secrets.

### Task 6: Capture coverage and reconcile unexecuted code

**Files:**
- Produce: final coverage/census evidence.
- Modify code only after reachability and product-boundary review.

**Interfaces:**
- Consumes: unit/mock/browser execution.
- Produces: coverage report and reviewed list of any remaining cold code.

- [ ] **Step 1: Finalize the coverage session**

Use the run ID from Task 1 with the repository's `code-census-session-stop` or full coverage target.

- [ ] **Step 2: Review uncovered production code**

For each uncovered function, check static entrypoints, gRPC/HTTP registration, failure-path reachability, database ownership, and current product requirements. Coverage alone never authorizes deletion.

- [ ] **Step 3: Remove only newly proven dead current code via TDD**

Add a source-contract or reachability test, verify it fails while the dead symbol exists, delete the symbol, and rerun affected full suites.

### Task 7: Self-review, line accounting, and remote delivery

**Files:**
- Update current docs/Notion only after behavior is verified.
- Produce final repository accounting.

**Interfaces:**
- Consumes: final verified tree and evidence.
- Produces: pushed branches and user-facing deletion report.

- [ ] **Step 1: Review every repository diff**

```bash
for repo in core-service control-panel-service scraper strategy-service strategy-library strategy-debugger-cli gateway/quant-handler gateway/quant-frontend golang-lib hushine-deploy; do
  git -C "$repo" diff --check
  git -C "$repo" status --short
  git -C "$repo" log --oneline --decorate -12
done
```

Inspect security, transaction, error, cancellation, concurrency, Windows bare-mode, and secret-handling changes manually.

- [ ] **Step 2: Compute exact line totals**

Use the recorded pre-cleanup commits:

```bash
git -C core-service diff --numstat 6b7b6aec02bad86d363627f3f0ca7465556ee5fa...HEAD
git -C control-panel-service diff --numstat ada3ab0614fbec84e8420a0c1ded5fac11e4108b...HEAD
git -C scraper diff --numstat 0f40e6ca392d89c08713726d5dc64d886e3c4034...HEAD
git -C strategy-service diff --numstat 4d2835ad099eed41760b34b0975d7ef0e69ec91d...HEAD
git -C strategy-library diff --numstat cb89b4c3413f6cd9bba4aab2da589862c048ba76...HEAD
git -C strategy-debugger-cli diff --numstat 652c09bf1aab5f1bad9fbd4a14adfeaf02731264...HEAD
git -C gateway/quant-handler diff --numstat 74575981de53f5cb4313171895718d03d2ff4d0c...HEAD
git -C gateway/quant-frontend diff --numstat 6e59bd1a5c55e65a0041722fffae07996b90be54...HEAD
git -C golang-lib diff --numstat 95965151aefbf2b191f3e793f73ccff9430a3140...HEAD
git -C hushine-deploy diff --numstat ed6162522552718df9524e515cdea96c28c961c9...HEAD
```

Classify deleted files and lines as handwritten production, generated, tests, migrations, and docs. Report additions, deletions, and net reduction; do not infer totals from terminal truncation.

- [ ] **Step 3: Update current documentation**

Update repository docs and the three current Notion sections—基础运维、代码结构和逻辑、用户手册—using only verified canonical behavior. Remove links to superseded current instructions.

- [ ] **Step 4: Run final verification once more**

Use Superpowers `verification-before-completion`; rerun the full repository checks and the minimum fresh-system smoke after all review fixes.

- [ ] **Step 5: Push every repository branch**

```bash
for repo in core-service control-panel-service scraper strategy-service strategy-library strategy-debugger-cli gateway/quant-handler gateway/quant-frontend golang-lib hushine-deploy; do
  git -C "$repo" push origin cleanup/medium-baseline-20260710
done
```

- [ ] **Step 6: Deliver the final report**

Report pushed commit IDs, exact deleted/modified file lists, per-repository line totals, generated-vs-handwritten totals, all test commands/results, fresh deployment status, browser acceptance results, known external smoke limitations, and no remaining first-party compatibility layer.
