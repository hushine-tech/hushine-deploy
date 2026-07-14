# Full-System Real-Page Acceptance Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Prove the final Runtime dependency, Indicator V2/lifecycle, and Binance Spot USDT implementation through repeatable repository, database, image, service, real-browser, exchange-Demo, reconciliation, and coverage gates, then update only the current three-part Notion documentation and push every affected repository with an auditable line-count report.

**Architecture:** Keep correctness tests in their owning repositories, keep reusable orchestration and acceptance tooling in `hushine-deploy`, and keep generated evidence outside Git under one run-specific `census-runs/` directory. Start complete isolated fresh and upgraded stacks against acceptance-owned databases on the configured `.10` infrastructure, create Hosted workers from the freshly built coverage image, exercise the product only through `quant-frontend -> quant-handler`, and reconcile UI/API results with durable service state. Notion is updated only after the reviewed code is committed and the complete gate has passed on those immutable commits.

**Tech Stack:** Go 1.26 tests and runtime coverage, Python 3.13/uv/pytest/coverage.py, TypeScript/Vite/Node contract tests, PostgreSQL/TimescaleDB, Kafka/ELK/Jaeger, Docker, Chromium CDP controlled through the in-app Browser skill/browser-client, Bash/Python acceptance helpers, Notion MCP.

## Global Constraints

- Execute Task 0 of this plan before any implementation in any of the four plans. Then execute the plans in this exact order: dependency contract, Indicator V2/lifecycle, Binance Spot USDT, then Tasks 1–14 of this full-system acceptance plan. Their focused tests are prerequisites, not substitutes for this final gate.
- Inside this acceptance plan, execute Tasks 1–4, then Task 6 (build/smoke the exact current images), then Task 5 (use those images for both complete isolated DB stacks), then Tasks 7–14. The numbering groups the database matrix before image operations for documentation, but never authorizes Task 5 to reuse a stale image left by an earlier companion plan. Task 14's fresh rerun uses the same `4 -> 6 -> 5 -> 7..12` order.
- The first three plans intentionally overlap `strategy-service/proto/runtime_worker.proto`, generated protobufs, Runtime Agent lifecycle files, core portfolio/order protobufs, quant-handler session/portfolio surfaces, and frontend Session/Portfolio pages. At each overlap, edit the current post-previous-plan source and regenerate from that source; never restore a generated file or hand-written neighbor from a stale pre-plan snapshot.
- After each of the first three plans, rerun that plan's focused gate and the previously completed focused gates. Before Task 4 below, regenerate every protobuf/schema/lock artifact once more from the combined tree and require a clean diff. Dependency-profile fields, Worker protocol V2/indicator tag 21, and Spot route/asset fields must coexist in the final descriptors.
- Work only in `/Users/xdy/Workplace/hushine-worktrees/medium-cleanup`; the workspace root is not Git and every service repository is committed independently.
- Before touching a detached repository, create a local implementation branch from its current detached commit. The approved remote delivery ref remains `cleanup/medium-baseline-20260710`; pushes must be fast-forward and never forced.
- Record every repository baseline commit, approved branch/detached state, remote branch SHA, and porcelain status in Task 0 before implementation. Preserve unrelated dirty work and stage only task-owned hunks. The immutable baseline ledger is carried unchanged into the final run and line-count report.
- The user has explicitly authorized stopping and removing every existing local Docker container before the acceptance run. Do not remove Docker volumes, images, build cache, or remote infrastructure.
- Platform services run on this Mac. PostgreSQL/TimescaleDB, Kafka, Elasticsearch, and Jaeger use the configured `192.168.88.10` environment. PostgreSQL user is `hushine-tech`; the password and all other secrets come from the existing ignored environment/config files and must never appear in commands, logs, screenshots, reports, plans, or commits.
- Store Demo exchange credentials only through the existing encrypted Venue API. Never write raw credentials to fixtures or evidence. Because the real-page stack uses a fresh run-owned database set, its Demo Venues are created exactly once through quant-handler from approved secure FD input before browser/CDP capture; a Venue ID from another database is never copied or treated as usable. The request/auth/response material is unlinked immediately.
- The Browser portions of Task 7 Steps 3/5, all of Task 10, and Task 12 Step 2 form one non-dispatchable `browser-coverage-owner`. The same agent and same persistent `mcp__node_repl__js` kernel must retain the Browser binding, tab object, CDP capability, and in-memory owner nonce from start through finalization. Other tasks may run independently, but loss/replacement of that owner, kernel, browser, or tab invalidates the whole run.
- Live `environment=2` remains fail-closed. Acceptance covers Backtest, Demo/Testnet, and offline debugger behavior only.
- Browser actions use the actual frontend and quant-handler. Internal APIs may be read afterward for reconciliation, but must not be used to fake a UI workflow.
- Generated evidence goes under `census-runs/runtime-v2-spot-acceptance-<UTC timestamp>/` and remains untracked.
- A failed pre-push required check blocks coordinated push. Prepare and review the Notion patch before delivery, but publish it only after all remote SHAs and the post-push no-mirror debugger bootstrap pass. The two necessarily deferred delivery/network scenarios block release completion/finalization; failure there is reported as partial delivery and repaired by normal fix-forward, never force push. Fix failures with `superpowers:systematic-debugging` and `superpowers:test-driven-development`, rerun the narrow reproducer, rerun the owning repository suite, then rerun the invalidated gate.
- OpenSpec is used only for the workspace-mandated read-only archive validation command. It is not used to design, track, or implement this work.
- There is exactly one authoritative manifest per run. The first acceptance manifest is initialized immediately after Task 3 and before Task 4. A final rerun creates a new run directory and initializes its manifest before repeating Tasks 4–12; no PASS record or evidence is copied from an older run.
- Review and fix the combined implementation before committing. Then commit each affected repository, require every owned worktree to be clean, record the exact commit SHAs, and run the final gate against those SHAs. Any subsequent code or Git-tracked documentation commit invalidates the final run and requires a new run. Prepare the Notion diff against the Task 0 requirement snapshot, push dependency producers before consumers, prove every remote SHA and the mandatory no-mirror debugger bootstrap, then publish/refetch Notion and finalize the manifest.

---

### Task 0: Freeze the cross-plan baseline and prove prerequisites before mutation

Execute this task once before the dependency-contract plan. It is a prerequisite shared by all four plans, not a late acceptance step.

**Evidence outside Git:**
- Create: `census-runs/acceptance-preflight-<UTC timestamp>/baseline-ledger.json`
- Create: `census-runs/acceptance-preflight-<UTC timestamp>/prerequisites.json`
- Create: `census-runs/acceptance-preflight-<UTC timestamp>/notion-requirements.json`

- [ ] **Step 1: Inventory the exact ten repositories**

For `core-service`, `control-panel-service`, `strategy-service`, `strategy-library`, `strategy-debugger-cli`, `scraper`, `golang-lib`, `gateway/quant-handler`, `gateway/quant-frontend`, and `hushine-deploy`, record repository absolute path, `HEAD`, current branch or detached state, `origin/cleanup/medium-baseline-20260710` SHA after `git fetch`, merge-base relationship, and `git status --porcelain=v1`. Record unrelated dirty paths as preserved baseline ownership; do not stage, clean, or rewrite them. Create local implementation branches for detached repositories before the first edit.

- [ ] **Step 2: Prove local and remote prerequisites without revealing secrets**

Require the expected ten repositories and companion plan files, writable run directory, ignored environment/config files with restrictive modes, Git, Make, Bash, `rg`, `jq`, Docker server and Buildx, Go, Python, uv, Node/npm, `protoc`, `psql`, `openspec`, and Chrome/Chromium with CDP support. Require `gh` only when the native-Windows gate uses GitHub workflow dispatch rather than a separately attested native runner. Verify the operator has permission to create/drop isolated PostgreSQL databases and create the TimescaleDB extension, but do not print DSNs or environment dumps.

Require an acceptance user ID plus either an already authenticated Browser tab or the Browser skill's documented `browserAuth` capability with an operator available for its secure prompt. The model never asks for, reads, types, or records a username, password, JWT, OTP, or cookie. Any authentication recovery that replaces the retained coverage tab requires a new run.

Independently for Binance Futures Demo and Spot Demo, require an authorized
secure credential source capable of creating one run-owned Venue through
quant-handler in the isolated acceptance database. A pre-existing Venue ID may
help a preliminary smoke only when it belongs to that exact sealed database;
it never satisfies the committed-SHA final run. Record only capability, never a
key/secret value or hash. Also require a concrete secure Telegram handoff
outside the retained frontend tab (approved connector or operator-mediated
Telegram client); bind code, chat ID, and username are ephemeral secrets and
never enter model-visible DOM/screenshot/evidence. Require Notion read/write
capability, remote push capability, and the configured `.10` infrastructure
endpoints. Check required local ports are free. Missing credentials/capabilities
produce a redacted `blocked` prerequisite result before any container removal,
database creation, code edit, or Notion write.

Also require access to a native Windows runner, or the scoped cross-repository
credential and `windows-latest` workflow-dispatch capability defined by the
Indicator plan. The runner path must be able to test an exact local committed
`strategy-service` plus sibling `golang-lib` SHA without first updating the
approved release branch. If only a remote workflow that requires a published
ref is available, acceptance remains blocked until the user separately
authorizes an appropriate validation ref; do not weaken the gate or push the
release branch early.

- [ ] **Step 3: Freeze current Notion requirements before implementation**

Use `notion:notion-research-documentation` read-only against the current root,
Operations, Code/logic, User manual, archive landing, and B-series parent IDs
listed in Task 13. Record each page ID, title, `last_edited_time`, content hash,
and a structured requirement ledger covering every product invariant and
accepted feature in those current pages. Historical pages are context only and
cannot override the four current pages or AGENTS invariants. Resolve any
code-vs-current-Notion conflict explicitly before implementation; do not edit
Notion to make an unreviewed code change appear correct. If a current page's
`last_edited_time` changes before publication preparation, refetch, re-review,
and regenerate the complete requirement ledger.

- [ ] **Step 4: Seal and preserve the baseline ledger**

Write canonical JSON with `schema_version`, timestamps, the exact ten
repository records, prerequisite assertions, and the Notion requirement
snapshot identity. After closing all three files, compute their SHA-256 hashes
and carry the paths/hashes in the immutable run
identity created after Task 3; do not create a circular self-hash field. Never
place secret values in any file. If a repository baseline, remote baseline, or
current Notion source changes before implementation starts, regenerate the
complete ledger rather than editing individual fields.

---

### Task 1: Put the reusable coverage census under version control

The existing coverage census lives in the non-Git workspace root. This task moves the reusable source into `hushine-deploy` so the capability the user requested can be reproduced after cloning the remote branch.

**Files:**
- Create: `hushine-deploy/scripts/audit/census/__init__.py`
- Create: `hushine-deploy/scripts/audit/census/code_census.py`
- Create: `hushine-deploy/scripts/audit/census/config.yaml`
- Create: `hushine-deploy/scripts/audit/census/overrides.yaml`
- Create: `hushine-deploy/scripts/audit/census/requirements.txt`
- Create: `hushine-deploy/scripts/audit/census/frontend_coverage.mjs`
- Create: `hushine-deploy/scripts/audit/census/browser_coverage_owner.mjs`
- Create: `hushine-deploy/scripts/audit/census/start_instrumented_stack.sh`
- Create: `hushine-deploy/scripts/audit/census/census/*.py`
- Create: `hushine-deploy/scripts/audit/census/tests/*.py`
- Create: `hushine-deploy/scripts/make-source-root.test.sh`
- Create: `gateway/quant-frontend/public/coverage-owner.html`
- Create: `gateway/quant-frontend/scripts/coverage-owner-page.test.mjs`
- Modify: `hushine-deploy/Makefile`
- Modify: every tracked `hushine-deploy/docs/code-census/*.md` file, including `README.md`, `candidate-review-guide.md`, `commands.md`, `prerequisites.md`, `runbook-full.md`, `runbook-snapshot.md`, `runbook-static.md`, `runbook-session.md`, `overrides-guide.md`, and `troubleshooting.md`

**Interfaces:**
- Produces: `make code-census-static SOURCE_ROOT=/absolute/worktree RUN_ID=<id>`.
- Produces: `make code-census-snapshot SOURCE_ROOT=/absolute/worktree RUN_ID=<id>`.
- Produces: `make code-census-session-start SOURCE_ROOT=/absolute/worktree RUN_ID=<id>`.
- Produces: `make code-census-session-stop SOURCE_ROOT=/absolute/worktree RUN_ID=<id>`.
- Produces: `make code-census-unit-coverage SOURCE_ROOT=/absolute/worktree RUN_ID=<id>`; emits the complete eight-Go-module, four-Python-project, deploy-tooling, and frontend unit/contract coverage set into that run.
- Produces: `scripts/audit/census/start_instrumented_stack.sh --source-root /absolute/worktree <run-id>`.
- Produces: every root orchestration target with `SOURCE_ROOT=<service-workspace>`, while automatically supporting both the canonical nested clone layout and sibling-repository worktrees.
- Preserves: run-local Go, Python, frontend, and Hosted Runtime coverage output formats already consumed by `census-runs/*/summary.md`.
- Changes frontend ownership: the retained browser-client tab is the sole owner
  of the Chrome Profiler lifecycle through one documented
  `await tab.capabilities.get("cdp")` capability; the census
  `frontend_coverage.mjs` runs only in `external-owner/normalize` mode over raw
  `takePreciseCoverage` output and never attaches to or starts a second profiler.
- Produces: a tested `browser_coverage_owner.mjs` state machine that remains in
  the persistent Browser Node kernel, owns an unexported random nonce plus CDP
  capability, starts/stops Profiler and Network, drains cursor-based events
  after every action, redacts in memory, and always attempts disable cleanup.
- Guarantees: the instrumented launcher never sources an environment with
  `set -a`, never reads Demo Venue credentials, and starts each child with an
  explicit service-specific allowlist. Frontend receives no server secret;
  Telegram/credential-encryption/database secrets reach only their owning
  child and never appear in process argv.

- [ ] **Step 1: Add a failing installation/relocation contract test**

Add `hushine-deploy/scripts/audit/census/tests/test_installation.py`:

```python
from pathlib import Path


DEPLOY_ROOT = Path(__file__).resolve().parents[4]


def test_census_is_owned_by_deploy_repository() -> None:
    assert (DEPLOY_ROOT / "scripts/audit/census/code_census.py").is_file()
    assert (DEPLOY_ROOT / "scripts/audit/census/start_instrumented_stack.sh").is_file()
    assert (DEPLOY_ROOT / "Makefile").read_text().count("code-census-session-start:") == 1


def test_all_census_docs_use_the_deploy_owned_tool_and_explicit_source_root() -> None:
    for path in sorted((DEPLOY_ROOT / "docs/code-census").glob("*.md")):
        text = path.read_text()
        assert "hushine-deploy/scripts/audit/census" in text
        assert "/Users/xdy/Workplace/hushine/scripts/audit/census" not in text
        for line in text.splitlines():
            if "code-census-" in line or "code_census.py" in line:
                assert "SOURCE_ROOT" in line or "--source-root" in line
```

Add frontend coverage contract tests with a fake retained tab whose
`capabilities.get("cdp")` returns a recorder. They require exactly this
one-owner sequence on one unchanged browser/tab binding:

```text
Profiler.enable
Network.enable
Profiler.startPreciseCoverage {callCount: true, detailed: true}
...all UI actions...
Profiler.takePreciseCoverage
Profiler.stopPreciseCoverage
Network.disable
Profiler.disable
```

Assert one and only one start/stop/disable, start occurs before the first UI
feature action/application navigation, browser ID and opaque tab ID are
unchanged at take/stop time, and the taken result contains
at least one `http://127.0.0.1:5173/` application script with a nonempty
function/range. Test a random in-memory owner nonce, one `O_EXCL` owner-start
artifact, per-action cursor draining until `hasMore=false`, failure on
`truncated=true`, and redaction of headers/cookies/query/body before any event is
written. Assert `frontend_coverage.mjs` rejects attach/debug-URL/start flags and
only normalizes an external raw artifact whose owner-start SHA, browser ID,
opaque tab ID, nonce, and raw hash satisfy the finalization envelope. A CDP
`source.targetId`, when available, is stored separately as `cdp_target_id` and
is never inferred from `tab.id`.

Add launcher secret-isolation tests before importing the implementation. They
poison the parent with PG, JWT, Telegram, Venue, credential-encryption, DB/Kafka
and unrelated variables, then inspect real fake-child argv and environment
*names*. Require no `set -a`, no built-in/default password or encryption key,
no `*_API_KEY`/`*_API_SECRET` acceptance by the launcher, frontend zero server
secrets, JWT only in quant-handler, Telegram/portfolio DB/encryption key only in
core-service, and each remaining DB/Kafka value only in its owning service.
Secret sentinels must be absent from argv, diagnostics, and generated launcher
files. Database bootstrap tests require a scoped subshell export or private
`PGPASSFILE`, never `env SECRET=value ...`.

Add a frontend contract proving `public/coverage-owner.html` is inert static
same-origin HTML: no script, stylesheet, fetch, redirect, form, storage, or
credential field. It exists solely to establish the documented CDP origin
before Profiler starts and the captured navigation to `/` loads application JS.

- [ ] **Step 2: Verify the test fails before relocation**

Run from `hushine-deploy`:

```bash
uv run --isolated --no-project --with pytest \
  python -m pytest scripts/audit/census/tests/test_installation.py -q
```

Expected: FAIL because `scripts/audit/census` is not yet tracked in `hushine-deploy`.

- [ ] **Step 3: Mechanically import the existing census and remove generated files**

Use the current workspace implementation at `/Users/xdy/Workplace/hushine/scripts/audit/census/` as the migration source, then apply the already-failing one-owner and secret-isolation tests before it is executable. Copy only source/config/test files; exclude `.pytest_cache`, `__pycache__`, `*.pyc`, generated coverage output, hard-coded secrets/defaults, and the source launcher's global `set -a` environment behavior. Preserve executable bits on `code_census.py` and `start_instrumented_stack.sh`.

The path calculations already resolve correctly after relocation:

```python
TOOL_ROOT = Path(__file__).resolve().parents[4]
CONFIG_PATH = TOOL_ROOT / "scripts/audit/census/config.yaml"
```

`start_instrumented_stack.sh` likewise keeps:

```bash
TOOL_ROOT="$(cd "$(dirname "$0")/../../.." && pwd -P)"
SOURCE_ROOT="${CODE_CENSUS_SOURCE_ROOT:-${TOOL_ROOT}}"
```

The caller must pass `--source-root` when service repositories are siblings of `hushine-deploy` rather than children of it.

- [ ] **Step 4: Expose repository-owned Make targets with an explicit source root**

Root every deploy-owned path in the Makefile location rather than the caller's current directory. This must work both as `make -C hushine-deploy ...` and as `make -f hushine-deploy/Makefile ...` from the source root:

```make
DEPLOY_ROOT := $(abspath $(dir $(lastword $(MAKEFILE_LIST))))
SOURCE_ROOT ?= $(if $(wildcard $(DEPLOY_ROOT)/core-service),$(DEPLOY_ROOT),$(abspath $(DEPLOY_ROOT)/..))
CODE_CENSUS ?= python3 $(DEPLOY_ROOT)/scripts/audit/census/code_census.py
CODE_CENSUS_ARGS := --source-root $(SOURCE_ROOT) --config $(DEPLOY_ROOT)/scripts/audit/census/config.yaml

.PHONY: code-census-static code-census-snapshot code-census-unit-coverage code-census-session-start code-census-session-stop code-census-full

code-census-static:
	@$(CODE_CENSUS) static $(CODE_CENSUS_ARGS) $(if $(RUN_ID),--run-id $(RUN_ID),)

code-census-snapshot:
	@$(CODE_CENSUS) snapshot $(CODE_CENSUS_ARGS) $(if $(RUN_ID),--run-id $(RUN_ID),)

code-census-session-start:
	@$(CODE_CENSUS) session-start $(CODE_CENSUS_ARGS) $(if $(RUN_ID),--run-id $(RUN_ID),)

code-census-session-stop:
	@if [ -z "$(RUN_ID)" ]; then echo "RUN_ID is required"; exit 2; fi
	@$(CODE_CENSUS) session-stop $(CODE_CENSUS_ARGS) --run-id $(RUN_ID)

code-census-full:
	@$(CODE_CENSUS) full $(CODE_CENSUS_ARGS) $(if $(RUN_ID),--run-id $(RUN_ID),)
```

Change every service build/test/dev/start/stop/clean call from `-C $$svc` to
`-C $(SOURCE_ROOT)/$$svc`, and change `runtime-image` to invoke
`$(SOURCE_ROOT)/strategy-service/scripts/build_strategy_runtime.sh`. Keep
deploy-owned compose files and scripts rooted at `$(DEPLOY_ROOT)`. Pass
`HUSHINE_SOURCE_ROOT=$(SOURCE_ROOT)` to `ensure-dbs` and every schema-bundle
target. Update `.PHONY` and help output for every census target.

Add `scripts/make-source-root.test.sh`. It invokes/dry-runs every root target—
build, test, dev, start, stop, clean, local, runtime-image, dependency image,
database/schema, and all census targets—from both a fake nested layout and an
explicit sibling `SOURCE_ROOT`. It asserts every service path is under the
selected root, every deploy-owned path is under `DEPLOY_ROOT`, and no command
falls back to an unrelated caller directory or contains an unscoped
`-C core-service`/`-C $$svc` path. The example below is the minimum build case;
the checked-in test must table-drive the complete target list.

```bash
#!/usr/bin/env bash
set -euo pipefail

deploy_root="$(cd "$(dirname "$0")/.." && pwd -P)"
tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT
fake_make="$tmpdir/fake-make"
capture="$tmpdir/calls"

cat >"$fake_make" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$MAKE_SOURCE_ROOT_CAPTURE"
EOF
chmod +x "$fake_make"

services=(core-service control-panel-service strategy-service gateway/quant-handler gateway/quant-frontend scraper)
assert_layout() {
  local make_cwd="$1" expected_root="$2" service
  : >"$capture"
  MAKE_SOURCE_ROOT_CAPTURE="$capture" make -s -C "$make_cwd" -f "$deploy_root/Makefile" MAKE="$fake_make" build
  for service in "${services[@]}"; do
    grep -Fx -- "-C $expected_root/$service build" "$capture" >/dev/null || {
      echo "missing source-root build call: $expected_root/$service" >&2
      exit 1
    }
  done
}

nested="$tmpdir/nested"
for service in "${services[@]}"; do mkdir -p "$nested/$service"; done
assert_layout "$nested" "$nested"

sibling="$tmpdir/sibling"
mkdir -p "$sibling/hushine-deploy"
for service in "${services[@]}"; do mkdir -p "$sibling/$service"; done
assert_layout "$sibling/hushine-deploy" "$sibling"

if grep -Fq -- '-C $$svc' "$deploy_root/Makefile"; then
  echo 'unscoped service path remains in Makefile' >&2
  exit 1
fi
```

Implement child launch with an allowlist builder that constructs the final
environment in memory and calls `os.execve` (or an equivalent scoped subshell
`export`), so secret values are never `env KEY=value` argv entries. The ignored
environment file is parsed without exporting it globally. Demo credential names
are refused before start and are never allowlisted. Update `config.yaml` so
managed Python commands match `AGENTS.md` without creating a library lock:

```yaml
  - name: "strategy-library"
    path: "strategy-library"
    kind: "python-library"
    unit_command: "uv run --isolated --no-project --with-editable '.[test]' pytest tests -q"
  - name: "strategy-debugger-cli"
    path: "strategy-debugger-cli"
    kind: "python-cli"
    unit_command: "uv run --frozen --extra test pytest tests -q"
```

Enumerate all eight tracked Go modules—including `golang-lib/log-shipper` and
`golang-lib/elk/kafka-es-bridge`—all four Python projects, deploy-owned Python
tests, and quant-frontend in the census config. Create a managed census development environment from the checked-in
requirements (including `pytest`) before running its suite; do not depend on an
ambient global pytest installation. Extend `start_instrumented_stack.sh` with
an explicit `--coverage-image <immutable-tag-or-id>` and Browser target
arguments described in Task 10. Refactor `frontend_coverage.mjs` to the exact
CLI `external-owner/normalize --raw <json> --owner-start <json> --output <json>`;
it validates and normalizes raw precise coverage but contains no websocket/tab
discovery, `tabs[0]` fallback, `Profiler.enable`, or
`Profiler.startPreciseCoverage` call.

- [ ] **Step 5: Run the complete census test suite and a dry start plan**

```bash
python3 -m venv .tmp/census-venv
.tmp/census-venv/bin/pip install -r scripts/audit/census/requirements.txt
.tmp/census-venv/bin/python -m pytest scripts/audit/census/tests -q
bash scripts/make-source-root.test.sh
RUN_ID=runtime-v2-plan-check make code-census-static SOURCE_ROOT=/Users/xdy/Workplace/hushine-worktrees/medium-cleanup
bash scripts/audit/census/start_instrumented_stack.sh --help
```

Expected: all tests PASS; static inventory is created under the worktree; the
versioned stack launcher prints its usage. Generated-launcher dry runs are
covered by `tests/test_start_instrumented_stack.py` because static mode does not
create runtime launchers.

- [ ] **Step 6: Seal the reusable-tooling candidate diff**

```bash
git diff --check -- Makefile scripts/audit/census scripts/make-source-root.test.sh docs/code-census
git diff --stat -- Makefile scripts/audit/census scripts/make-source-root.test.sh docs/code-census
```

Do not commit yet. Preserve this verified repository-owned diff for the
combined independent review and repository-scoped commit in Task 14.

---

### Task 2: Make one-shot database bootstrap safely testable with isolated names

**Files:**
- Modify: `hushine-deploy/scripts/ensure-all-dbs.sh`
- Modify: `hushine-deploy/scripts/ensure-all-dbs-env.test.sh`
- Modify: `hushine-deploy/db/README.md`
- Modify: `control-panel-service/cmd/ensure-control-panel-db/main.go`
- Create: `control-panel-service/cmd/ensure-control-panel-db/main_test.go`

**Interfaces:**
- Adds: `PORTFOLIO_DATABASE_DBNAME`, default `portfolio`, mapped only to `PGDATABASE_PORTFOLIO` for the core bootstrap.
- Preserves: `ORDER_DATABASE_DBNAME`, default `order`.
- Adds: `CONTROL_PANEL_DATABASE_DBNAME`, default `control_panel`, mapped only to `PGDATABASE_CONTROL_PANEL` for the control-panel bootstrap.
- Preserves: `SCRAPER_DBS` for explicit market-data database names.
- Uses: each acceptance stack's existing scraper `database.dbname` template with
  an ownership prefix, e.g. `acceptance_<token>_fresh_{exchange}_{year}` or
  `acceptance_<token>_upgrade_{exchange}_{year}`; `SCRAPER_DBS` must contain the
  matching concrete current-year names. Production remains `{exchange}_{year}`.
- Guarantees: each database name is scoped only to its owning service invocation; one shared `DATABASE_DBNAME` cannot accidentally route portfolio and control-panel migrations to one database.

- [ ] **Step 1: Add failing environment-routing assertions**

Extend `scripts/ensure-all-dbs-env.test.sh` so its fake `make` captures the environment of all four invocations. Assert:

```bash
assert_call_env core-service ensure-db PGDATABASE_PORTFOLIO=acceptance_portfolio
assert_call_env core-service ensure-order-db ORDER_DATABASE_DBNAME=acceptance_order
assert_call_env control-panel-service ensure-db PGDATABASE_CONTROL_PANEL=acceptance_control_panel
assert_call_env scraper ensure-db SCRAPER_DBS=acceptance_binance_2026
```

Also assert the portfolio database name is absent from the control-panel call and vice versa. Capture the real fake-child argv separately and prove neither a password nor a `SECRET=value` assignment occurs there.

- [ ] **Step 2: Verify the test fails**

```bash
bash scripts/ensure-all-dbs-env.test.sh
```

Expected: FAIL because the current orchestrator has no independent portfolio/control-panel database-name mapping.

- [ ] **Step 3: Add service-scoped environments**

Build `portfolio_db_env`, `order_db_env`, `control_panel_db_env`, and
`scraper_db_env` allowlists for non-secret routing names. Invoke each target in
its own subshell. Database credentials are exported inside that subshell or
supplied through a private mode-0600 `PGPASSFILE`; they are never elements of an
`env` command's argv. In schematic form (the helper performs cleanup/traps):

```bash
( export PGDATABASE_PORTFOLIO="$PORTFOLIO_DATABASE_DBNAME"; make -C "$SOURCE_ROOT/core-service" ensure-db )
( export ORDER_DATABASE_DBNAME; export ORDER_DATABASE_PASSWORD; make -C "$SOURCE_ROOT/core-service" ensure-order-db )
( export PGDATABASE_CONTROL_PANEL="$CONTROL_PANEL_DATABASE_DBNAME"; make -C "$SOURCE_ROOT/control-panel-service" ensure-db )
( export SCRAPER_DBS; make -C "$SOURCE_ROOT/scraper" ensure-db )
```

Map the logical orchestration variables exactly as follows; do not export one global `DATABASE_DBNAME`:

```text
PORTFOLIO_DATABASE_DBNAME   -> core ensure-db PGDATABASE_PORTFOLIO
ORDER_DATABASE_DBNAME       -> core ensure-order-db ORDER_DATABASE_DBNAME
CONTROL_PANEL_DATABASE_DBNAME -> control ensure-db PGDATABASE_CONTROL_PANEL
SCRAPER_DBS                 -> scraper ensure-db SCRAPER_DBS
```

The fake-`make` test must capture each child environment and argv and prove every owning
variable is present only on its owning call. Assert the three unrelated
database-name variables are absent from each invocation, not merely unequal;
assert secret sentinels occur only in the appropriate child environment and in
no argv/log/capture intended for evidence.

- [ ] **Step 4: Make the control-panel bootstrap consume and validate its target**

Replace the hard-coded `control_panel` target in
`cmd/ensure-control-panel-db/main.go` with `PGDATABASE_CONTROL_PANEL`, defaulting
to `control_panel`. Validate it as a PostgreSQL identifier, reject unsafe/empty
overrides, quote it with `pq.QuoteIdentifier`, and use the same validated target
for existence queries, creation, and the target DSN. Unit tests cover default,
custom isolated name, overlength, and injection-shaped input. The companion
Indicator plan makes the analogous core bootstrap consume
`PGDATABASE_PORTFOLIO`; this task verifies that behavior instead of reintroducing
`DATABASE_DBNAME`.

- [ ] **Step 5: Run service, shell, and bundle tests**

```bash
cd control-panel-service
go test ./cmd/ensure-control-panel-db -count=1
go test ./...
go vet ./...

cd ../hushine-deploy
bash scripts/ensure-all-dbs-env.test.sh
make db-schema-bundle
git diff --exit-code -- db/generated
```

Expected: PASS and deterministic generated SQL.

- [ ] **Step 6: Seal the bootstrap candidate diffs in their owning repositories**

```bash
cd control-panel-service
git diff --check -- cmd/ensure-control-panel-db/main.go cmd/ensure-control-panel-db/main_test.go

cd ../hushine-deploy
git diff --check -- scripts/ensure-all-dbs.sh scripts/ensure-all-dbs-env.test.sh db/README.md
```

Do not commit yet. Task 14 commits each owning repository only after combined
review.

---

### Task 3: Create a machine-checkable acceptance manifest and reconciliation gate

**Files:**
- Create: `hushine-deploy/scripts/acceptance/runtime_v2_spot_manifest.py`
- Create: `hushine-deploy/scripts/acceptance/runtime-v2-spot-scenarios.json`
- Create: `hushine-deploy/scripts/acceptance/provision_demo_venue.sh`
- Create: `hushine-deploy/scripts/acceptance/provision_demo_venue.test.sh`
- Create: `hushine-deploy/scripts/acceptance/tests/test_runtime_v2_spot_manifest.py`
- Create: `hushine-deploy/docs/acceptance/runtime-v2-spot.md`
- Modify: `gateway/quant-handler/internal/app/venues.go`
- Modify: `gateway/quant-handler/internal/app/venues_test.go`
- Modify: `gateway/quant-frontend/src/api/client.ts`
- Modify: `gateway/quant-frontend/src/pages/VenueManagement.tsx`
- Modify: `gateway/quant-frontend/src/pages/PortfolioDetail.tsx`
- Create: `gateway/quant-frontend/scripts/venue-credential-redaction.test.mjs`
- Modify: `core-service/internal/notification/telegram.go`
- Create: `core-service/internal/notification/telegram_test.go`
- Modify: `core-service/internal/notification/service.go`
- Modify: `core-service/internal/notification/service_test.go`

**Interfaces:**
- Produces: `python3 scripts/acceptance/runtime_v2_spot_manifest.py init --run-dir <absolute-dir> --source-root <absolute-worktree>`.
- Produces: `... record --run-dir <dir> --scenario <id> --evidence <relative-json-path>`; status and producer come from the validated evidence envelope and cannot be asserted only on the command line.
- Produces: `... precheck --run-dir <dir> --allow-pending <id>...`; `--allow-pending` is repeatable and exits zero only when its exact named set equals the missing required set and every recorded scenario passes with valid evidence.
- Produces: `... finalize --run-dir <dir>`; exits non-zero unless all required scenarios pass and every evidence path exists below the run directory without symlink escape.
- Produces: `provision_demo_venue.sh --exchange binance --market spot|perpetual_futures --run-id <id> --auth-fd <n>`; reads a short-lived Bearer credential only from that inherited FD and that route's Demo key/secret only from an approved private FD or tightly scoped provisioning subprocess, creates at most one encrypted acceptance-owned Venue through quant-handler, prints only canonical JSON containing the public Venue ID/route, and always closes/unsets/unlinks transient material before exit. Authorization and secret values never appear in curl/process argv.
- Changes: quant-handler Venue create/list/get responses never return raw `api_key`; they expose only the existing credential fingerprint plus a server-generated masked label. Frontend no longer searches or renders a raw API key.
- Changes: Telegram transport failures are converted at the client boundary to stable redacted error codes before logging/persistence; a `url.Error` can never persist or display a bot-token URL.
- Writes: immutable `<run-dir>/run-identity.json`, `<run-dir>/acceptance-manifest.json`, and `<run-dir>/acceptance-summary.md`.

- [ ] **Step 1: Add failing manifest tests**

Cover duplicate scenario IDs, missing required scenarios, path traversal,
symlink/special-file evidence, empty evidence, malformed JSON, schema mismatch,
wrong producer, wrong scenario ID, missing source commits, nonzero commands, false
assertions, missing or hash-mismatched artifacts, secret-shaped keys or values in
the evidence payload, failed scenarios, exact-set single and repeatable pending
prechecks, rejection of any additional missing/failed/blocked scenario during
precheck, and a complete valid manifest. For every scenario contract, delete
each required assertion ID, artifact kind, identity key, command, or browser
action in turn and require rejection; a trivial `{pass:true}` assertion cannot
satisfy a product scenario:

```python
def test_finalize_rejects_missing_required_scenario(tmp_path):
    run = init_run(tmp_path)
    record(run, "repo-matrix", write_valid_evidence(run, "repo-matrix", "repository"))
    result = finalize(run)
    assert result.exit_code == 1
    assert "missing required scenarios" in result.stderr


def test_finalize_accepts_complete_redacted_evidence(tmp_path):
    run = init_run(tmp_path)
    for scenario in required_scenarios():
        evidence = write_valid_evidence(run, scenario["id"], scenario["producer"])
        record(run, scenario["id"], evidence)
    assert finalize(run).exit_code == 0

def test_precheck_accepts_only_the_named_pending_documentation_scenario(tmp_path):
    run = init_run(tmp_path)
    for scenario in required_scenarios():
        if scenario["id"] != "notion-current-pages":
            record(run, scenario["id"], write_valid_evidence(run, scenario["id"], scenario["producer"]))
    assert precheck(run, allow_pending="notion-current-pages").exit_code == 0

def test_precheck_accepts_only_an_exact_repeatable_pending_set(tmp_path):
    pending = {"notion-current-pages", "remote-delivery", "post-push-debugger-bootstrap"}
    run = init_run(tmp_path)
    record_all_except(run, pending)
    assert precheck(run, allow_pending=sorted(pending)).exit_code == 0
    assert precheck(run, allow_pending=sorted(pending - {"remote-delivery"})).exit_code == 1

def test_record_rejects_self_asserted_or_empty_pass(tmp_path):
    run = init_run(tmp_path)
    empty = run / "evidence/empty.json"
    empty.parent.mkdir()
    empty.write_text("")
    assert record(run, "repo-matrix", empty).exit_code == 1

def test_record_rejects_wrong_producer_and_secret_inside_evidence(tmp_path):
    run = init_run(tmp_path)
    evidence = write_valid_evidence(run, "repo-matrix", "browser")
    assert record(run, "repo-matrix", evidence).exit_code == 1
    evidence = write_valid_evidence(run, "repo-matrix", "repository", extra={"dsn": "postgres://user:redacted@example/db"})
    assert record(run, "repo-matrix", evidence).exit_code == 1
```

Add manifest permission/lifecycle tests: `init` sets `umask 077`, the run root
is 0700, every retained regular artifact is 0600 with link count one, and
finalize rejects symlink/hardlink/special-file escape. Transient JWT/auth config,
request body, raw product response, bind-code state, or unredacted network event
must be unlinked before finalize; a scanner failure removes/quarantines the
unsafe original rather than leaving it inside the run.

Add `provision_demo_venue.test.sh` with fake quant-handler/curl and filesystem
hooks. Require strict mode, no `set -x`, route allow-listing, mode-0600 auth/body
inputs, authorization read only from `--auth-fd`, one create request, immediate
FD/variable closing and unlink on success/error/signal, exact run-ID ownership
tagging, redacted stdout/stderr, and rejection of a response that contains no
single canonical Venue ID. On an ambiguous response, never POST again: issue a
safe authenticated list lookup and recover only one exact match by run tag,
route, environment, and credential fingerprint; zero/multiple matches are
blocked while the cleanup ledger retains the possible run tag. Assert keys,
secrets, JWT, and Authorization never enter argv, process diagnostics, evidence,
or a child Runtime environment.

Add quant-handler/frontend redaction tests proving create/list/get/wallet
responses contain no raw `api_key`, only fingerprint/masked label, and that the
page never renders or searches the request credential. Add core notification
tests with a token-bearing `url.Error`/transport error and prove logs,
`last_delivery_error`, API JSON, and rendered UI contain only a stable redacted
category, never URL/token text.

- [ ] **Step 2: Verify the tests fail**

```bash
.tmp/census-venv/bin/python -m pytest scripts/acceptance/tests/test_runtime_v2_spot_manifest.py -q
bash scripts/acceptance/provision_demo_venue.test.sh
```

Expected: FAIL because the manifest and safe provisioning tools do not exist.

- [ ] **Step 3: Define the required scenario IDs**

`runtime-v2-spot-scenarios.json` is a registry of objects, not a list of names.
Every object fixes the only allowed evidence producer, evidence schema,
`required_assertion_ids`, `required_artifact_kinds`,
`required_identity_keys`, `min_commands`, and—only for browser scenarios—
`min_actions`. The checked-in registry spells out those contracts for every
scenario; common requirements are expanded during generation and committed as
ordinary JSON, not inferred at validation time.
Use the following complete required set (abbreviated object formatting shown;
the checked-in JSON contains one object per line):

```json
{
  "schema_version": 1,
  "required": [
    {"id":"repo-matrix","producer":"repository","evidence_schema":1},
    {"id":"generated-artifacts","producer":"repository","evidence_schema":1},
    {"id":"windows-runtime-release","producer":"repository","evidence_schema":1},
    {"id":"fresh-bootstrap","producer":"db-matrix","evidence_schema":1},
    {"id":"populated-v1-upgrade","producer":"db-matrix","evidence_schema":1},
    {"id":"database-cleanup","producer":"db-matrix","evidence_schema":1},
    {"id":"normal-image-import-closure","producer":"image-smoke","evidence_schema":1},
    {"id":"coverage-image-import-closure","producer":"image-smoke","evidence_schema":1},
    {"id":"runtime-v2-smoke","producer":"image-smoke","evidence_schema":1},
    {"id":"futures-backtest","producer":"integration","evidence_schema":1},
    {"id":"futures-demo-contract","producer":"integration","evidence_schema":1},
    {"id":"spot-backtest","producer":"integration","evidence_schema":1},
    {"id":"spot-demo-contract","producer":"integration","evidence_schema":1},
    {"id":"offline-debugger-futures","producer":"integration","evidence_schema":1},
    {"id":"offline-debugger-spot","producer":"integration","evidence_schema":1},
    {"id":"multi-input-multi-interval","producer":"integration","evidence_schema":1},
    {"id":"mixed-spot-futures","producer":"integration","evidence_schema":1},
    {"id":"indicator-1023-plus-2","producer":"reconciliation","evidence_schema":1},
    {"id":"indicator-repeat-idempotency","producer":"reconciliation","evidence_schema":1},
    {"id":"indicator-sparse-marker-time","producer":"reconciliation","evidence_schema":1},
    {"id":"indicator-terminal-tail","producer":"integration","evidence_schema":1},
    {"id":"bare-blocked-worker-heartbeat","producer":"bare","evidence_schema":1},
    {"id":"bare-worker-only-restart","producer":"bare","evidence_schema":1},
    {"id":"futures-liquidation-max-loss","producer":"integration","evidence_schema":1},
    {"id":"spot-stop-only","producer":"integration","evidence_schema":1},
    {"id":"spot-stop-and-close","producer":"integration","evidence_schema":1},
    {"id":"live-spot-rollout-guard","producer":"integration","evidence_schema":1},
    {"id":"okx-execution-fail-closed","producer":"integration","evidence_schema":1},
    {"id":"browser-auth-navigation","producer":"browser","evidence_schema":1},
    {"id":"browser-portfolio-venue","producer":"browser","evidence_schema":1},
    {"id":"browser-strategy-readiness","producer":"browser","evidence_schema":1},
    {"id":"browser-running-indicator","producer":"browser","evidence_schema":1},
    {"id":"browser-futures-demo","producer":"browser","evidence_schema":1},
    {"id":"browser-spot-demo","producer":"browser","evidence_schema":1},
    {"id":"browser-stop-recovery","producer":"browser","evidence_schema":1},
    {"id":"browser-console-network","producer":"browser","evidence_schema":1},
    {"id":"telegram-bind-test-unbind","producer":"browser","evidence_schema":1},
    {"id":"demo-venue-cleanup","producer":"reconciliation","evidence_schema":1},
    {"id":"durable-reconciliation","producer":"reconciliation","evidence_schema":1},
    {"id":"coverage-finalization","producer":"coverage","evidence_schema":1},
    {"id":"notion-current-pages","producer":"notion","evidence_schema":1},
    {"id":"remote-delivery","producer":"delivery","evidence_schema":1},
    {"id":"post-push-debugger-bootstrap","producer":"delivery","evidence_schema":1}
  ]
}
```

The `demo-venue-cleanup` record is immutable and separate from already-recorded
browser Demo evidence. It owns both run-created Venue IDs, cleanup/deactivation
outcomes, and retained-history assertions; no recorded envelope is edited or
re-recorded after hashing. The `*-demo-contract` integration records prove safe automated contract
coverage; they cannot satisfy the distinct `browser-*-demo` real-page records.

- [ ] **Step 4: Implement safe init/record/finalize behavior**

Use JSON writes through a same-directory temporary file plus `os.replace`.
Resolve every evidence path, require it to remain below `run_dir`, and reject
symlinks/special files. `record` parses a nonempty regular JSON file and
validates this envelope before changing the manifest:

```json
{
  "schema_version": 1,
  "scenario_id": "repo-matrix",
  "producer": "repository",
  "status": "pass",
  "source_commits": {"hushine-deploy": "<40-hex-sha>"},
  "started_at": "<RFC3339>",
  "finished_at": "<RFC3339>",
  "commands": [{"argv": ["go", "test", "./..."], "exit_code": 0, "log": "logs/repo.log"}],
  "assertions": [{"name": "all packages pass", "expected": true, "actual": true, "pass": true}],
  "artifacts": [{"path": "logs/repo.log", "sha256": "<64-hex>"}],
  "identities": {"run_id": "<run-id>"}
}
```

Scenario-specific contracts are table-driven from the registry: `record`
requires every named assertion ID exactly once, every artifact kind, all
identity keys, at least the declared number of nonzero-work commands/actions,
and scenario-specific lifecycle facts. Unknown assertions may supplement but
never replace required ones. Repository evidence
contains all ten commits; DB evidence contains the ownership token and exact
database list; image evidence contains exact tag, image ID and config digest;
browser evidence contains owner-start SHA, browser ID, opaque browser tab ID,
owner nonce, browser-envelope SHA plus applicable Portfolio/Venue/runtime/session
IDs; reconciliation contains its scoped export hash; Notion contains page ID
and `last_edited_time`; delivery contains the complete affected remote/local SHA
map or the published debugger/library SHAs plus clean-network/no-mirror facts.
The `post-push-debugger-bootstrap` registry contract specifically requires
assertions `library-baseline-present`, `python-3.12-bootstrap`,
`python-3.13-bootstrap`, `python-3.14-bootstrap`, `canonical-direct-url`, and
`no-mirror-or-rewrite`, plus hashes of the fresh library baseline JSON and all
three debugger logs; omission of any one rejects the envelope.
A `pass` record is rejected when any command is nonzero,
any assertion is false, an artifact is missing/escapes the run directory, or an
artifact hash differs. Store the evidence file SHA-256 in the manifest. Reject
duplicate records; an exact byte-for-byte idempotent retry may return success
without rewriting.

Initialize under `umask 077`, require run directory mode 0700, retained regular
artifact mode 0600 and link count one, and reject symlinks/special files/hard
links. Recursively inspect both evidence JSON values and referenced text/JSON
artifacts for secret-key names and secret-shaped content (including DSNs,
authorization headers, private keys, raw exchange/Telegram tokens, and ignored
environment values). Fail closed without echoing the matched value. Redaction
is performed by the evidence producer; the manifest tool never silently turns
unsafe evidence into a pass. `precheck` accepts exactly one
one or more repeatable `--allow-pending` values, requires every value to be a unique configured
required scenario, and requires the supplied set to equal the missing set
exactly. It still rejects every fail/blocked record or invalid/missing evidence
file. Thus a broad allow-list cannot hide a newly missing scenario, and an
already-recorded scenario cannot remain named as pending.

Screenshot artifacts are permitted only for explicitly non-sensitive pages and
must pass image decode plus visual/OCR redaction review; a sensitive-page deny
list covers login, credential forms, visible bind codes, notification identities,
and any modal containing request secrets. Screenshot metadata scanning alone is
never sufficient.

Implement `provision_demo_venue.sh` as a narrow product-API client, not an
exchange client. It validates the exchange/market/environment/run ID before
reading secrets, reads the short-lived Bearer value from `--auth-fd`, creates
auth config and request body as distinct mode-0600 files under a private
temporary directory with `umask 077`, disables tracing, and submits exactly once
to quant-handler's existing authenticated Venue endpoint. Authorization is
loaded by curl from the private config/FD and is not a command argument. Parse
only the public ID/fingerprint/masked label, then immediately unlink the raw
response and all auth/request files. It never calls Binance itself and never
prints or hashes credential values. `spot` reads only the Spot Demo input and
`perpetual_futures` only the Futures Demo input. A definite non-2xx returns
nonzero; an ambiguous response performs only the exact run-tag recovery GET
described by the tests and never retries POST.

In quant-handler, remove `APIKey` from `venueJSON`; compute/use a server-owned
masked label from the credential fingerprint. Update client/page types and
search/render behavior accordingly. In core notification transport, unwrap and
map network failures to stable codes before service persistence; never return,
log, or save `err.Error()` when it can contain a request URL.

- [ ] **Step 5: Run tests and CLI smoke**

```bash
.tmp/census-venv/bin/python -m pytest scripts/acceptance/tests -q
bash scripts/acceptance/provision_demo_venue.test.sh
run_dir="$(mktemp -d)"
python3 scripts/acceptance/runtime_v2_spot_manifest.py init --run-dir "$run_dir" --source-root /Users/xdy/Workplace/hushine-worktrees/medium-cleanup
python3 scripts/acceptance/runtime_v2_spot_manifest.py finalize --run-dir "$run_dir"
```

Expected: tests PASS; the empty CLI smoke exits 1 and lists all missing required scenarios without a traceback.

- [ ] **Step 6: Seal the acceptance-gate candidate diff**

```bash
git diff --check -- scripts/acceptance docs/acceptance/runtime-v2-spot.md
git -C ../gateway/quant-handler diff --check -- internal/app/venues.go internal/app/venues_test.go
git -C ../gateway/quant-frontend diff --check -- src/api/client.ts src/pages/VenueManagement.tsx src/pages/PortfolioDetail.tsx scripts/venue-credential-redaction.test.mjs
git -C ../core-service diff --check -- internal/notification
```

Do not commit yet; Task 14 owns the reviewed repository-scoped commit.

- [ ] **Step 7: Initialize the first authoritative run before Task 4**

```bash
RUN_ID="runtime-v2-spot-acceptance-$(date -u +%Y%m%d-%H%M%S)"
SOURCE_ROOT=/Users/xdy/Workplace/hushine-worktrees/medium-cleanup
RUN_DIR="$SOURCE_ROOT/census-runs/$RUN_ID"
python3 scripts/acceptance/runtime_v2_spot_manifest.py init \
  --run-dir "$RUN_DIR" --source-root "$SOURCE_ROOT" \
  --baseline-ledger "$SOURCE_ROOT/census-runs/<preflight-id>/baseline-ledger.json" \
  --notion-requirements "$SOURCE_ROOT/census-runs/<preflight-id>/notion-requirements.json"
```

`init` creates the run directory, captures the exact ten current source SHAs,
records the baseline-ledger path/hash, and writes immutable
`run-identity.json`. Export `RUN_ID`, `RUN_DIR`, and `SOURCE_ROOT` for Tasks
4–12. Refuse an existing/nonempty run directory or a second `init`. Do not
start census collectors here; Task 7 attaches them to this already initialized
run.

---

### Task 4: Run the authoritative generated-artifact, repository, and Windows release matrix

**Files:**
- Write evidence only: `census-runs/<run-id>/evidence/repository-matrix.json`
- Write evidence only: `census-runs/<run-id>/evidence/generated-artifacts.json`
- Write evidence only: `census-runs/<run-id>/evidence/windows-runtime-release.json`

- [ ] **Step 1: Verify run identity and record complete tool versions**

Before running a command, verify `$RUN_DIR/run-identity.json` exists, its
baseline-ledger hash matches Task 0, and all ten current repository SHAs match
the run identity. Record, without environment dumps:

```bash
git -C <repo> rev-parse HEAD
git -C <repo> status --porcelain=v1
go version
python3 --version
uv --version
node --version
npm --version
protoc --version
psql --version
openspec --version
docker version --format 'client={{.Client.Version}} server={{.Server.Version}}'
docker buildx version
<chrome-binary> --version
```

Include all ten repositories from Task 0. A dirty path is permitted here only
when it is the recorded pre-existing unrelated path or a task-owned uncommitted
change during the preliminary run. The final run in Task 14 requires all owned
paths clean and exact committed SHAs.

- [ ] **Step 2: Regenerate combined artifacts before any test**

Run the exact generation commands named by the three companion plans for Go and
Python protobufs, frontend/runtime descriptors, mocks, dependency locks, and
database schema bundles. Capture the descriptor sets and machine-check that
dependency-profile fields, Worker protocol V2/indicator field 21, and final
Portfolio/Venue/Spot route fields coexist. Capture `git status --porcelain=v1`
before and after and require no new diff in any repository. A generated diff is
a failure and must be committed with its source before continuing.

At minimum execute the combined-tree commands explicitly rather than relying on
a later build side effect:

```bash
(cd "$SOURCE_ROOT/core-service" && make proto)
(cd "$SOURCE_ROOT/control-panel-service" && make proto)
(cd "$SOURCE_ROOT/strategy-service" && \
  env -u PYTHONPATH uv sync --python 3.13 --frozen --extra dev && \
  PYTHON=.venv/bin/python ./generate_proto.sh && uv lock --check)
(cd "$SOURCE_ROOT/strategy-debugger-cli" && \
  ./scripts/with-local-strategy-library-git.sh "$SOURCE_ROOT/strategy-library" \
    uv lock --check)
(cd "$SOURCE_ROOT/hushine-deploy" && \
  make db-schema-bundle SOURCE_ROOT="$SOURCE_ROOT")
```

Run each generator a second time and compare first/second file checksums for
determinism, then require the repository diffs are unchanged from the captured
candidate/final baseline. The debugger wrapper is the companion plan's
process-local pre-push bare mirror for an intentionally unpublished immutable
library SHA; it must leave no URL rewrite, file/mirror path, or user/global Git
configuration behind. Task 14 separately proves the clean-network canonical
HTTPS resolution after coordinated push.

- [ ] **Step 3: Run every Go module's complete test and vet suite**

Run `go test ./...` and `go vet ./...` from each of these eight module roots;
`golang-lib` itself does not cover its nested modules:

```bash
core-service
control-panel-service
strategy-service
scraper
golang-lib
golang-lib/log-shipper
golang-lib/elk/kafka-es-bridge
gateway/quant-handler
```

At each root run both commands, then run the exact focused race packages named
by the companion plans for runtime-agent/worker lifecycle, Indicator V2
ownership, core indicator repository/service, and Spot order/wallet state. The
minimum examples remain:

```bash
go test -race ./internal/runtimeagent/... -count=1
go test -race ./internal/repository/... -count=1
go test -race ./internal/order/... -count=1
```

Run each command only in the repository where the package exists; absence is a plan/interface mismatch and must be corrected, not silently ignored.

- [ ] **Step 4: Run every managed Python suite and strategy-service shell contract**

```bash
cd "$SOURCE_ROOT/strategy-service"
env -u PYTHONPATH uv sync --python 3.13 --frozen --extra dev
PYTHONPATH=.:../strategy-library uv run --frozen --extra dev pytest tests/ -q
go test ./...
bash -euo pipefail -c '
  tests="$(git ls-files "scripts/*.test.sh" | LC_ALL=C sort)"
  test -n "$tests"
  while IFS= read -r test_file; do bash "$test_file"; done <<<"$tests"
'

# Installed/frozen production contract: no source shadowing.
env -u PYTHONPATH uv sync --python 3.13 --frozen --extra dev
SERVICE_PROFILE_JSON="$(env -u PYTHONPATH -u PYTHONHOME -u VIRTUAL_ENV \
  .venv/bin/python -I -m hushine_strategy.runtime_dependencies show --json)"
SERVICE_INSTALLED_JSON="$(env -u PYTHONPATH -u PYTHONHOME -u VIRTUAL_ENV \
  .venv/bin/python -I -m hushine_strategy.runtime_dependencies \
  verify-installed --python-constraint 3.13 --json)"
jq -e -n --argjson expected "$SERVICE_PROFILE_JSON" --argjson actual "$SERVICE_INSTALLED_JSON" \
  '$actual.ok == true and $actual.name == $expected.name and $actual.version == $expected.version and $actual.digest == $expected.digest'

cd "$SOURCE_ROOT/strategy-library"
test ! -e uv.lock
uv run --isolated --no-project --with-editable '.[test]' pytest tests -q
test ! -e uv.lock

cd "$SOURCE_ROOT/strategy-debugger-cli"
./scripts/with-local-strategy-library-git.sh "$SOURCE_ROOT/strategy-library" \
  env -u PYTHONPATH uv sync --frozen --extra test
./scripts/with-local-strategy-library-git.sh "$SOURCE_ROOT/strategy-library" \
  uv run --frozen --extra test pytest tests -q
bash scripts/bootstrap-standalone.test.sh --library-repo "$SOURCE_ROOT/strategy-library"
DEBUGGER_PROFILE_JSON="$(env -u PYTHONPATH -u PYTHONHOME -u VIRTUAL_ENV \
  .venv/bin/python -I -m hushine_strategy.runtime_dependencies show --json)"
DEBUGGER_INSTALLED_JSON="$(env -u PYTHONPATH -u PYTHONHOME -u VIRTUAL_ENV \
  .venv/bin/python -I -m hushine_strategy.runtime_dependencies \
  verify-installed --python-constraint '>=3.12' --json)"
jq -e -n --argjson expected "$DEBUGGER_PROFILE_JSON" --argjson actual "$DEBUGGER_INSTALLED_JSON" \
  '$actual.ok == true and $actual.name == $expected.name and $actual.version == $expected.version and $actual.digest == $expected.digest'

cd "$SOURCE_ROOT/golang-lib/py_log"
test ! -e uv.lock
uv run --isolated --no-project --with-editable '.[dev]' pytest -q
test ! -e uv.lock
```

The first strategy-service pytest command is retained exactly because the
current workspace `AGENTS.md` requires that source-compatibility regression.
It is not production-admission evidence. The following installed/frozen checks
must run with `PYTHONPATH` removed and prove imports resolve from the synced
environment rather than sibling source. Only the explicitly named AGENTS source
suite and dependency manifest-checker test harness may use the sibling source;
any production image, Hosted/Self-hosted worker, image/container smoke child, or
real-stack execution subprocess containing a strategy-library `PYTHONPATH`
fails. Internal Bare development may use only the dependency plan's explicit,
verified sibling-source guard and is tested separately; it is never generalized
into Hosted/Self-hosted launch environment.
Current operator docs must label the old command test-only;
if the project later removes it from `AGENTS.md`, update this matrix and the
current operations docs together rather than retaining a hidden compatibility
exception.

The tracked strategy-service loop must include the companion plan's new
`runtime-agent-blocked-worker.test.sh`, `runtime-agent-platform.test.sh`, and
both pre-existing shell tests. A newly tracked `.test.sh` is included
automatically; a skipped/unexecutable tracked test fails the matrix.

- [ ] **Step 5: Run a clean frontend install, build, and every tracked JavaScript contract**

```bash
cd "$SOURCE_ROOT/gateway/quant-frontend"
npm ci
npm run build
bash -euo pipefail -c '
  tests="$(git ls-files "scripts/*.test.mjs" | LC_ALL=C sort)"
  test -n "$tests"
  while IFS= read -r test_file; do node "$test_file"; done <<<"$tests"
'
```

Expected: the build and every current/future `scripts/*.test.mjs` file PASS; the loop prevents a new test from being omitted from the matrix.

- [ ] **Step 6: Run all deploy contracts, root orchestration, and companion focused gates**

```bash
cd "$SOURCE_ROOT/hushine-deploy"
make build SOURCE_ROOT="$SOURCE_ROOT"
make test SOURCE_ROOT="$SOURCE_ROOT"
python3 -m venv "$RUN_DIR/tools/deploy-test-venv"
"$RUN_DIR/tools/deploy-test-venv/bin/pip" install -r scripts/audit/census/requirements.txt
"$RUN_DIR/tools/deploy-test-venv/bin/python" -m pytest \
  scripts/audit/census/tests scripts/acceptance/tests -q
bash -euo pipefail -c '
  tests="$(git ls-files "scripts/*.test.sh" | LC_ALL=C sort)"
  test -n "$tests"
  while IFS= read -r test_file; do bash "$test_file"; done <<<"$tests"
'
make test-runtime-indicator-v2

cd "$SOURCE_ROOT"
make -f hushine-deploy/Makefile runtime-dependency-acceptance \
  SOURCE_ROOT="$PWD" RUNTIME_DEPENDENCY_BASE_SHA="$RUNTIME_DEPENDENCY_BASE_SHA"
./hushine-deploy/scripts/verify_spot_usdt.sh backtest
./hushine-deploy/scripts/verify_spot_usdt.sh offline
./hushine-deploy/scripts/verify_spot_usdt.sh ui
./hushine-deploy/scripts/verify_spot_usdt.sh filters
./hushine-deploy/scripts/verify_spot_usdt.sh stop

cd /Users/xdy/Workplace/hushine
set +e
openspec_output="$(openspec validate --all --strict --no-interactive 2>&1)"
openspec_status=$?
set -e
printf '%s\n' "$openspec_output"
if [ "$openspec_status" -ne 0 ]; then exit "$openspec_status"; fi
if grep -Fq 'No items found to validate' <<<"$openspec_output"; then exit 1; fi
```

The deploy loop includes current and companion-created tests such as
`restart-patterns.test.sh`, `runtime-dependency-contract.test.sh`,
`smoke_spot_demo.test.sh`, `verify_spot_usdt.test.sh`, the census
source-root test, and every other tracked self-contained `.test.sh`. Run
stateful acceptance entrypoints separately as shown. The Demo scope is deferred
to Tasks 8 and 10 and must use the encrypted `VENUE_ID` recorded by Task 7,
whether pre-existing or acceptance-owned; no raw credential is typed while
coverage is active. OpenSpec output is archive-
integrity evidence only.

- [ ] **Step 7: Collect complete unit/contract coverage inside this run**

Run the repository-owned census phase after the ordinary regression matrix so
coverage cannot replace a normal test gate:

```bash
make -C "$SOURCE_ROOT/hushine-deploy" code-census-unit-coverage \
  SOURCE_ROOT="$SOURCE_ROOT" RUN_ID="$RUN_ID"
```

The target discovers and then requires exactly the eight tracked Go module
roots listed in Step 3 and runs `go test -covermode=atomic -coverprofile=...`
for each. It covers strategy-service, strategy-library, strategy-debugger-cli,
and `golang-lib/py_log` through their managed environments (using the local-Git
wrapper for every pre-push debugger command and isolated no-project mode for
both lockless libraries), and covers deploy-owned Python tooling with the
run-local census venv. It runs every tracked frontend contract under
`NODE_V8_COVERAGE`, preserves source maps from the exact build, and emits a
source-mapped frontend unit report. Each expected profile has a module/project
identity, source commit, command status, nonempty source/function index, and
hash; absence of even an untouched module is failure. No coverage command may
create `strategy-library/uv.lock` or `golang-lib/py_log/uv.lock`.

- [ ] **Step 8: Build and inspect the full cross-platform release set**

The companion platform contract must perform real Windows cross-compilation,
not only filename/dry-run checks. Run it and the complete release builder with
output outside Git:

```bash
cd "$SOURCE_ROOT/strategy-service"
./scripts/runtime-agent-platform.test.sh
RUNTIME_AGENT_DIST_DIR="$RUN_DIR/windows-release" \
  ./scripts/build-runtime-agent-release.sh --version "$RUN_ID"
```

Require exactly the six `darwin-{amd64,arm64}`, `linux-{amd64,arm64}`, and
`windows-{amd64,arm64}` runtime-agent binaries, with `.exe` only on Windows.
Inspect format/architecture, require both Windows files are valid PE executables,
record SHA-256 hashes, and prove the build produced no untracked repository
output. Also run the companion plan's `CGO_ENABLED=0 GOOS=windows GOARCH=amd64`
real `go build` and `go test -c` assertions. Failure of either Windows
architecture blocks release even when the current host is macOS.

Cross-compilation is only the first half of this gate. On a native Windows
runner, execute the Indicator plan's checked-in script against the same exact
`strategy-service` and sibling `golang-lib` commits:

```powershell
pwsh -File scripts/runtime-agent-windows-native.test.ps1
```

It must build/run `runtime-agent.exe`, prove the PowerShell launcher selects the
`.exe`, and run native loopback TCP IPC, graceful/forced termination plus
`Cmd.Wait` reap, stale-generation isolation, `RestartSession`, and the real
blocked-worker `30/5` integration in the locked Python environment. With the
GitHub path, dispatch `.github/workflows/runtime-agent-windows.yml` on
`windows-latest` and require its successful job URL. With a local/leased native
runner, transfer a content-addressed source bundle and return a signed/hashed
artifact manifest. In both cases the log, executable, runner image, strategy-
service SHA, and golang-lib SHA must be present and equal the final source
ledger. A missing runner, credential, exact-SHA checkout, job URL, or artifact
is `blocked`; PE inspection or successful cross-compilation cannot substitute.

- [ ] **Step 9: Record all structured matrix scenarios**

Write producer=`repository` evidence envelopes containing command argv,
start/end time, exit code, artifact hashes, and exact ten source commits. Record
`repo-matrix`, `generated-artifacts`, and `windows-runtime-release` as pass only
when every required command/assertion exits zero. In particular,
`windows-runtime-release` requires both the six-host cross-build evidence and
the exact-SHA native Windows artifact above. A hand-written summary, empty log,
or cross-build-only record cannot satisfy any scenario.

---

### Task 5: Prove fresh bootstrap and populated V1-to-V2 upgrade on `.10`

Execution dependency: complete Task 6 against the current combined source
first. Refuse Task 5 if either exact acceptance image ID/label is missing or
does not match the current run's source-SHA ledger.

**Files:**
- Create: `hushine-deploy/scripts/acceptance/runtime_v2_spot_db_matrix.py`
- Create: `hushine-deploy/scripts/acceptance/tests/test_runtime_v2_spot_db_matrix.py`
- Create: `hushine-deploy/scripts/acceptance/fixtures/runtime-v2-spot-db-state.json`
- Use: `core-service/internal/storage/migrations/testdata/indicator_v1_fixture.sql` from the Indicator V2 plan; do not treat `runtime-indicator-v2-db-smoke.sh` as a parameterized fixture-loader library.
- Write evidence only: `census-runs/<run-id>/database/fresh-bootstrap.json`
- Write evidence only: `census-runs/<run-id>/database/populated-upgrade.json`
- Write evidence only: `census-runs/<run-id>/database/ownership.json`
- Write evidence only: `census-runs/<run-id>/database/cleanup.json`

**Interfaces:**
- Produces: `runtime_v2_spot_db_matrix.py allocate --run-dir <dir> --source-root <root>`; selects and seals exactly eight absent names and a random ownership token without creating a database.
- Produces: `... run --run-dir <dir> --mode fresh|upgrade --coverage-image <exact-tag-or-id>`; owns creation, migration, fixtures, complete-stack health/write/read checks, stable hashes, and failure cleanup for one set.
- Produces: `... verify --run-dir <dir> --mode fresh|upgrade`; rechecks schema, data, ownership, and evidence without mutation.
- Produces: `... cleanup --run-dir <dir>`; stops registered processes, terminates only target-database connections, and drops only exact owned names.
- Guarantees: no wildcard/prefix drop, no unprefixed shared/current-year database, no pre-existing target reuse, separate prefixed market databases for fresh and upgrade, and no cleanup success without ownership proof.

- [ ] **Step 1: Allocate isolated database names from the run ID**

Normalize the run ID to lowercase alphanumerics and underscores, then allocate
separate fresh and upgrade sets:

```text
${DB_PREFIX}_fresh_portfolio
${DB_PREFIX}_fresh_order
${DB_PREFIX}_fresh_control_panel
${DB_PREFIX}_upgrade_portfolio
${DB_PREFIX}_upgrade_order
${DB_PREFIX}_upgrade_control_panel
${DB_PREFIX}_fresh_binance_${CURRENT_MARKET_YEAR}
${DB_PREFIX}_upgrade_binance_${CURRENT_MARKET_YEAR}
```

The `allocate` subcommand rejects names longer than PostgreSQL's 63-byte
identifier limit, queries `pg_database`, and rejects the entire allocation if
any of the eight derived names already exists. Each stack receives a generated
run-local scraper config whose existing `database.dbname` is respectively
`${DB_PREFIX}_fresh_{exchange}_{year}` or
`${DB_PREFIX}_upgrade_{exchange}_{year}`; its `SCRAPER_DBS` bootstrap value is
the matching concrete current-UTC-year name. Thus real 2026 event timestamps
route into that stack's own 2026 database instead of a fake 9000-series year or
the other stack. It refuses shared `portfolio`, `order`, `control_panel`, every
configured production name, and unprefixed `{exchange}_{year}` names.

It implements the equivalent of the following after loading libpq
authentication without printing the environment:

```bash
DB_PREFIX="$(printf '%s' "$RUN_ID" | tr '[:upper:]-' '[:lower:]_' | tr -cd 'a-z0-9_' | cut -c1-35)"
CURRENT_MARKET_YEAR="$(date -u +%Y)"
FRESH_PORTFOLIO_DB="${DB_PREFIX}_fresh_portfolio"
FRESH_ORDER_DB="${DB_PREFIX}_fresh_order"
FRESH_CONTROL_DB="${DB_PREFIX}_fresh_control_panel"
UPGRADE_PORTFOLIO_DB="${DB_PREFIX}_upgrade_portfolio"
UPGRADE_ORDER_DB="${DB_PREFIX}_upgrade_order"
UPGRADE_CONTROL_DB="${DB_PREFIX}_upgrade_control_panel"
FRESH_MARKET_TEMPLATE="${DB_PREFIX}_fresh_{exchange}_{year}"
UPGRADE_MARKET_TEMPLATE="${DB_PREFIX}_upgrade_{exchange}_{year}"
FRESH_MARKET_DB="${DB_PREFIX}_fresh_binance_${CURRENT_MARKET_YEAR}"
UPGRADE_MARKET_DB="${DB_PREFIX}_upgrade_binance_${CURRENT_MARKET_YEAR}"
```

Require `DB_PREFIX` to match `^[a-z][a-z0-9_]+$`, every derived name to be at
most 63 bytes, and `CURRENT_MARKET_YEAR` to equal the current UTC year before
creating anything. Machine-check both templates through scraper's real
`DatabaseNameForYear` behavior and require their concrete results equal the two
sealed market names. Write the eight exact names, safe admin
host/port/user identity, random 256-bit ownership-token hash, allocation time,
and `absent_before` assertion for each name to `database/ownership.json` before
the first create. Store that artifact's SHA-256 in the acceptance manifest.
Every later create/connect/drop reads the sealed list; no command reconstructs
targets from a prefix or shell glob.

- [ ] **Step 2: Add adversarial unit/contract tests before remote mutation**

Use fake `psql`, `make`, process, and stack-runner executables to prove:

- `allocate` rejects a pre-existing one of any of the eight targets, unprefixed
  current-year `binance_YYYY`, shared names, invalid/overlength identifiers,
  mismatched scraper template/concrete route, and a
  changed ownership file;
- `run` passes the exact four service-scoped variables from Task 2 to the real
  one-shot orchestrator twice and never emits a secret;
- cleanup is registered immediately after the sealed absent-name check, uses
  only parameterized/quoted exact names, refuses a missing/wrong marker or
  token, and never issues a wildcard/prefix `DROP DATABASE`;
- a simulated failure at every create/migrate/seed/start/verify phase stops
  registered processes and attempts safe cleanup;
- successful cleanup terminates connections only where `datname` equals one
  exact owned name, drops all and only eight names, and is idempotent after a
  completed owned cleanup.

```bash
.tmp/census-venv/bin/python -m pytest scripts/acceptance/tests/test_runtime_v2_spot_db_matrix.py -q
```

Expected before implementation: FAIL because the tool does not exist. Implement
allocation/run/verify/cleanup behind injectable command runners, rerun this
complete test file, and require PASS. Remote execution is forbidden until then.

- [ ] **Step 3: Bootstrap the fresh set twice through the one-shot orchestrator**

Load the ignored secret file without echoing it, then run:

```bash
python3 hushine-deploy/scripts/acceptance/runtime_v2_spot_db_matrix.py allocate \
  --run-dir "$RUN_DIR" --source-root "$SOURCE_ROOT"
python3 hushine-deploy/scripts/acceptance/runtime_v2_spot_db_matrix.py run \
  --run-dir "$RUN_DIR" --mode fresh \
  --coverage-image hushine/strategy-runtime:executor-coverage-acceptance
```

`run` loads libpq authentication only in the child environment, installs its
failure cleanup immediately, and invokes `ensure-all-dbs.sh` twice with the
exact fresh portfolio/order/control and fresh market name/template. Both
invocations must succeed; every expected table/constraint/index exists and
each `schema_migrations` filename appears exactly once. Immediately after each
database is created, write a private `hushine_acceptance` ownership marker with
the token hash and run identity. A later standalone cleanup requires both the
sealed local ownership file and matching database marker. A partially created,
unmarked database may be removed only by the still-running creator under its
exclusive run lock and recorded `absent_before` fact; after a crash, fail closed
for operator review rather than guessing ownership.

- [ ] **Step 4: Start a complete stack against fresh databases and perform public writes**

Generate mode-specific run-local configs that reference isolated names and
secret-file paths/placeholders, never raw secret values. Start the complete
product path: core-service, control-panel control API and RuntimeChannel,
scraper, quant-handler, quant-frontend, and a Hosted runtime-agent plus isolated
Python session worker from the exact coverage image. Include any remaining
strategy-service runtime process only if it is still part of the final combined
architecture; do not revive a retired `:50053` control path.

Wait for every health/readiness endpoint. Through the frontend/quant-handler
and owning public APIs, create/read an acceptance user, Portfolio, non-secret
Backtest Spot and Futures Venue facts, strategy, Hosted runtime, session,
wallet, order/fill/reconciliation/lifecycle records, notification, runtime
registry, and Spot market-data row. Do not copy encrypted Demo credentials from
the shared environment into isolated DB evidence; Tasks 8 and 10 exercise the
recorded encrypted Demo Venues on the dedicated Demo acceptance stack.
Prove RuntimeChannel routes only by `runtime_id` and the Hosted worker has no
DB/Kafka/account/order address. Stop through product paths and validate graceful
worker finalization before stopping the stack.

- [ ] **Step 5: Seed an exact populated V1 upgrade set**

The `upgrade` mode first invokes the same one-shot orchestrator twice with the
three upgrade names and its distinct upgrade market database/template. It then applies
`indicator_v1_fixture.sql` directly through a checked, parameterized `psql`
invocation against exactly the recorded upgrade portfolio database. Do not call
an undocumented loader mode on `runtime-indicator-v2-db-smoke.sh`.

The checked-in JSON fixture declares representative users, portfolios, Venue
references, strategies, sessions, session venues, wallets, orders, fills,
lifecycle events, notifications, reconciliation rows, and runtime/control state
plus their owning service/API. Seed them through owning APIs wherever the V1
contract permits; use explicit parameterized SQL only for the V1 indicator
shape and otherwise-inexpressible historical states. The fixture tool validates
table/column names against a checked-in allow-list.

Discover every non-system table in the exact upgrade portfolio, order,
control-panel, and upgrade market database and require an explicit primary-
key ordering. Before migration, produce a machine-generated inventory and for
every table except the two V1 indicator tables, migration ledgers, and private
ownership marker record `COUNT(*)` plus SHA-256 over newline-delimited
canonical `jsonb` rows ordered by the full primary key. Fail if a table has no
declared stable key or is silently omitted. Persist database role, table name,
key columns, count, and hash; never persist a secret-bearing column value.

- [ ] **Step 6: Upgrade, start the complete upgraded stack, and prove preservation**

Run `runtime_v2_spot_db_matrix.py run --mode upgrade` with the same exact
coverage image. It reruns the one-shot command, applying only the missing
portfolio V2 migration while treating current order, control-panel, and market-
data ledgers as idempotent. Recompute the complete inventory and require:

Expected:

```text
V1 indicator definitions/chunks: deleted
V2 indicator tables/constraints: present
all non-indicator table counts: unchanged
all non-indicator stable hashes: unchanged
new protocol-V2 session: insert/read succeeds
```

The migration must not delete sessions, orders, fills, wallets, venues, users, notifications, reconciliation, or runtime state.

Then start the same complete stack against the upgraded database set. Read all
preserved fixtures through owning APIs and the real frontend/handler path,
create and execute a new protocol-V2 Hosted session, verify its indicator/order/
wallet state, and stop/finalize cleanly. A schema-only query without a running
complete fresh and complete upgraded stack does not satisfy either scenario.

- [ ] **Step 7: Verify and record both database scenarios**

```bash
python3 hushine-deploy/scripts/acceptance/runtime_v2_spot_db_matrix.py verify \
  --run-dir "$RUN_DIR" --mode fresh
python3 hushine-deploy/scripts/acceptance/runtime_v2_spot_db_matrix.py verify \
  --run-dir "$RUN_DIR" --mode upgrade
```

Producer=`db-matrix` evidence includes ownership-token hash, exact eight names,
migration filenames, all ten source commits, exact coverage image identity,
complete-stack component/health identities, scoped public IDs, stable table
counts/hashes, commands/assertions, and artifact hashes. Never include a DSN,
password, raw Venue credential, or full secret-bearing row. Record
`fresh-bootstrap` and `populated-v1-upgrade` only after both independent
verifiers pass.

- [ ] **Step 8: Define the Task 12 acceptance-owned cleanup gate**

Task 12 runs this command after stopping every process that uses the databases:

```bash
python3 hushine-deploy/scripts/acceptance/runtime_v2_spot_db_matrix.py cleanup \
  --run-dir "$RUN_DIR"
```

For each exact recorded name, revalidate identifier and forbidden-name rules,
match the sealed token to the private database marker, terminate only
connections whose `datname` equals that parameter, and issue an individually
quoted drop. Never use a wildcard/prefix query and never drop shared/current-
year databases. Re-query `pg_database`, require all eight absent, hash the
redacted cleanup log, and record the required `database-cleanup` scenario.
Failed or ownership-ambiguous cleanup blocks finalization and is never reported
as a skip/success.

---

### Task 6: Build and smoke both Hosted Runtime images

**Files:**
- Use dependency/image smoke scripts created by the dependency-contract plan.
- Use protocol/lifecycle smoke scripts created by the Indicator V2 plan.
- Create: `strategy-service/scripts/smoke_runtime_v2_container.sh`
- Create: `strategy-service/scripts/smoke_runtime_v2_container.test.sh`
- Modify: `hushine-deploy/scripts/audit/census/start_instrumented_stack.sh` so acceptance mode requires an exact coverage image.
- Write evidence only: `census-runs/<run-id>/images/*.json`

- [ ] **Step 0: Add the arbitrary-image lifecycle smoke with TDD**

Write `smoke_runtime_v2_container.test.sh` first and prove it fails because the
CLI does not exist. Implement only the exact `--image`, `--coverage`, and
`--output` interface described in Step 3, including image-ID pinning, no rebuild/
fallback, run-local RuntimeChannel fixture cleanup, V1 rejection, V2 lifecycle,
and coverage-mode shard checks. Then run:

```bash
cd "$SOURCE_ROOT/strategy-service"
bash scripts/smoke_runtime_v2_container.test.sh
```

Expected: PASS without Docker/network side effects in contract-test mode.

- [ ] **Step 1: Build normal and coverage images from the same lock closure**

```bash
cd "$SOURCE_ROOT/strategy-service"
./scripts/build_strategy_runtime.sh --all --no-cache --verify acceptance
```

The command above is mandatory, with no `--allow-dirty`, for Task 14's clean
committed-SHA run. During the earlier candidate-diff run only, append the
companion CLI's explicit `--allow-dirty` to the builder and all verifier/smoke
commands; require `source_dirty=true`, keep the same acceptance tags, and mark
that evidence preliminary/non-reusable. Never silently fall back to a dev tag.

The only accepted tags are
`hushine/strategy-runtime:executor-acceptance` and
`hushine/strategy-runtime:executor-coverage-acceptance`. Do not invoke the old
one-argument/implicit-dev CLI and do not use the mutable `executor-coverage`
alias. Record each exact tag, image ID, config digest, OCI contract/profile/
source labels, and RepoDigests when present. A local image may have no
RepoDigest; image ID plus config digest and labels are then the authoritative
immutable identity rather than an invented digest.

- [ ] **Step 2: Run the dependency manifest/import closure against both images**

Run the dependency plan's exact checked-in verifiers and smokes:

```bash
PROFILE_JSON="$(env -u PYTHONPATH -u PYTHONHOME -u VIRTUAL_ENV \
  .venv/bin/python -I -m hushine_strategy.runtime_dependencies show --json)"
PROFILE="$(jq -er .name <<<"$PROFILE_JSON")"
PROFILE_VERSION="$(jq -er .version <<<"$PROFILE_JSON")"
PROFILE_DIGEST="$(jq -er .digest <<<"$PROFILE_JSON")"

./scripts/verify_runtime_image.sh \
  --image hushine/strategy-runtime:executor-acceptance --coverage false \
  --profile "$PROFILE" --version "$PROFILE_VERSION" --digest "$PROFILE_DIGEST"
./scripts/verify_runtime_image.sh \
  --image hushine/strategy-runtime:executor-coverage-acceptance --coverage true \
  --profile "$PROFILE" --version "$PROFILE_VERSION" --digest "$PROFILE_DIGEST"
./scripts/smoke_strategy_runtime.sh \
  --image hushine/strategy-runtime:executor-acceptance --coverage false \
  --profile "$PROFILE" --version "$PROFILE_VERSION" --digest "$PROFILE_DIGEST"
./scripts/smoke_strategy_runtime.sh \
  --image hushine/strategy-runtime:executor-coverage-acceptance --coverage true \
  --profile "$PROFILE" --version "$PROFILE_VERSION" --digest "$PROFILE_DIGEST"
```

They must import exactly the eight allowed public roots (`dateutil`, `google`,
`grpc`, `numpy`, `pandas`, `pydantic`, `requests`, `yaml`), compile and
instantiate the representative strategy, reject a forbidden import, and reject
a deliberately broken allowed module before a session can remain running. They
also prove the frozen installed strategy-library is used with no source-path
`PYTHONPATH`, the normal and coverage dependency profile/digest is identical,
and `coverage` is present only as instrumentation and denied to user code.

- [ ] **Step 3: Run protocol V2 and lifecycle smoke against both images**

The Indicator plan's `runtime-indicator-v2-smoke.sh` is a focused source gate,
not an arbitrary-image interface. Add a separate checked-in container smoke
with this exact CLI:

```bash
./scripts/smoke_runtime_v2_container.sh \
  --image hushine/strategy-runtime:executor-acceptance \
  --coverage false --output "$RUN_DIR/images/normal-v2-smoke"
./scripts/smoke_runtime_v2_container.sh \
  --image hushine/strategy-runtime:executor-coverage-acceptance \
  --coverage true --output "$RUN_DIR/images/coverage-v2-smoke"
```

Its shell contract test proves it never rebuilds/falls back to another tag and
fails on image-ID drift. The smoke starts a run-local RuntimeChannel fixture,
launches the supplied image, and requires WorkerHello protocol version 2, one
minimal session, an open indicator write, final acknowledgement, clean worker
reap, and complete runtime finalization. A V1 hello is rejected with the stable
compatibility error from the Indicator plan. Coverage mode additionally
validates every raw shard; normal mode proves no coverage-only dependency.

- [ ] **Step 4: Inspect environment isolation**

Assert neither image contains or receives internal database DSNs, Kafka brokers, account/order service addresses, or a legacy `runtime_env`. Allowed configuration is limited to RuntimeChannel identity/credential/TLS and explicit coverage output settings in the coverage image.

- [ ] **Step 5: Register the reusable Hosted coverage smoke for the running stack**

This smoke requires live control-panel/core endpoints, so do not run it before
Task 7 starts the instrumented stack. Task 7 Step 7 executes it with the exact
coverage tag and output under the current run. The smoke must resolve that tag
to the recorded image ID and refuse drift/fallback. Pass the same exact image
to `start_instrumented_stack.sh --coverage-image`.

- [ ] **Step 6: Record the image scenarios**

Producer=`image-smoke` envelopes record
`normal-image-import-closure`, `coverage-image-import-closure`, and
`runtime-v2-smoke` with exact tags, image IDs/config digests/labels, commands,
assertions, and artifact hashes. Task 12 owns the distinct producer=`coverage`
`coverage-finalization` record after the complete real-page run; this image
smoke cannot pre-satisfy it.

---

### Task 7: Clean local containers and start the instrumented local stack

**Files:**
- Write evidence only: `census-runs/<run-id>/environment/*.json`
- Write evidence only: `census-runs/<run-id>/coverage/instrumented-stack.json`

- [ ] **Step 1: Revalidate all destructive-run prerequisites before cleanup**

Verify the existing `$RUN_DIR/run-identity.json` and manifest from Task 3; do
not generate a new `RUN_ID` and do not call `init` again. Recheck Docker server,
required local ports, exact normal/coverage image IDs, acceptance user and each
Demo route's secure one-time Venue creation/auth-FD capability, Telegram secure
handoff capability, Notion write capability, push capability, and
remote infrastructure without printing credentials.

Verify TCP/service reachability for PostgreSQL `:5432`, Kafka `:19092`,
Elasticsearch `:9200`, Jaeger `:16686`, OTLP HTTP `:4318`, and OTLP gRPC
`:4317`. Query only safe health endpoints. If an endpoint or required operator
capability is unavailable, record a redacted blocked prerequisite and stop
before removing a container. This run explicitly requires coverage plus
observability; an optional/disabled endpoint is not silently waived.

- [ ] **Step 2: Inventory, stop, and remove every local container**

Record container IDs, names, images, and states before cleanup, excluding environment variables and mounted secret contents. Then stop and remove all IDs returned by `docker ps -aq`. Verify `docker ps -aq` is empty. Do not run `docker system prune`, do not remove volumes, and do not remove images.

- [ ] **Step 3: Bind the sole Browser coverage owner before collectors**

This step begins the non-dispatchable `browser-coverage-owner`; the same agent
and persistent Node kernel owns every later browser/CDP step through Task 12.
Invoke `browser:control-in-app-browser`, import its absolute plugin-owned
`<browser-plugin-root>/scripts/browser-client.mjs`, where
`<browser-plugin-root>` is resolved at execution time from the currently
installed Browser skill's `SKILL.md` locator. Expand that locator to an absolute
path before import; fail if the skill-owned file is absent and never import a
built-in lookalike. Then select the browser for
`http://127.0.0.1:5173` with `agent.browsers.getForUrl`, and read that browser's
complete documentation before interaction. Obtain or create exactly one tab
and retain the browser binding and tab object in this kernel. Record
`browser.id` and the opaque `tab.id` separately; `tab.id` is never called or
treated as a Chrome/CDP target ID. Do not inspect cookies/storage/profiles/
passwords or obtain a second CDP client. CDP is acquired in Step 5—after the
same-origin inert page is live—only through the documented
`await tab.capabilities.get("cdp")` path. Do not open a second standalone browser
or replace browser-client with another MCP/automation server.

- [ ] **Step 4: Attach census collectors to the already initialized run**

```bash
test "$RUN_DIR" = "$SOURCE_ROOT/census-runs/$RUN_ID"
test -f "$RUN_DIR/run-identity.json"
CODE_CENSUS_BROWSER_ID="$BROWSER_ID" \
CODE_CENSUS_BROWSER_TAB_ID="$BROWSER_TAB_ID" \
CODE_CENSUS_CHROME_TARGET_URL=http://127.0.0.1:5173/ \
CODE_CENSUS_ENV_FILE="$IGNORED_CENSUS_ENV_FILE" \
make -C "$SOURCE_ROOT/hushine-deploy" code-census-session-start \
  SOURCE_ROOT="$SOURCE_ROOT" RUN_ID="$RUN_ID"
```

The census validates that run identity already exists and refuses to create or
overwrite the acceptance manifest. It records frontend state as
`waiting-for-browser-owner`; it does not attach to CDP or start a profiler.
`frontend_coverage.mjs` has no tab discovery or `tabs[0]` fallback and cannot
double-start coverage.

- [ ] **Step 5: Start all instrumented services with the exact coverage image**

```bash
bash "$SOURCE_ROOT/hushine-deploy/scripts/audit/census/start_instrumented_stack.sh" \
  --source-root "$SOURCE_ROOT" \
  --coverage-image hushine/strategy-runtime:executor-coverage-acceptance \
  --database-ownership "$RUN_DIR/database/ownership.json" \
  --database-mode fresh \
  --browser-id "$BROWSER_ID" --browser-tab-id "$BROWSER_TAB_ID" "$RUN_ID"
```

Wait for core, control-panel control gRPC/RuntimeChannel/HTTP, quant-handler,
scraper, frontend, and observability health. Prove every stateful service and
scraper points to Task 5's sealed **fresh** portfolio/order/control/current-year
market database set; no browser-created entity may land in shared databases.
Create exactly one Spot and one Futures Demo Venue now through authenticated
quant-handler before starting Profiler. The helper accepts auth and route
credentials only through approved inherited secure FDs, writes private
mode-0600 transient files outside evidence, disables tracing, submits exactly
one POST per route, captures only public Venue ID/fingerprint/masked label, and
unlinks auth/request/raw-response material. Fetch each Venue through the product
API and require encrypted-at-rest plus redacted response behavior. Tag both with
the run ID and record them as acceptance-owned for exact product cleanup; an
ambiguous response uses only exact run-tag recovery GET and never a second POST.

Use the Task 3 checked helper once for each missing route and parse only its
redacted JSON result, for example:

```bash
SPOT_VENUE_JSON="$(bash "$SOURCE_ROOT/hushine-deploy/scripts/acceptance/provision_demo_venue.sh" \
  --exchange binance --market spot --run-id "$RUN_ID" \
  --auth-fd "$AUTH_FD" --credential-fd "$SPOT_CREDENTIAL_FD")"
SPOT_VENUE_ID="$(jq -er '.venue_id' <<<"$SPOT_VENUE_JSON")"
unset SPOT_VENUE_JSON
```

The Futures invocation differs only by `--market perpetual_futures` and its
route-specific credential FD. Close every FD and assert the launcher/Hosted
Runtime environments contain none of their names before Profiler or evidence.

On the retained tab, navigate first to a checked-in inert same-origin
`http://127.0.0.1:5173/coverage-owner.html` that loads no application script.
This satisfies the Browser CDP origin precondition without missing frontend
bootstrap execution. Recheck the same browser/tab IDs, acquire and fully read
the documented CDP capability once, and construct `BrowserCoverageOwner` in the
same kernel. Before navigating to `/` or performing any feature action, it runs:

```javascript
var cdp = await tab.capabilities.get("cdp");
await cdp.documentation();
await cdp.send("Profiler.enable");
await cdp.send("Network.enable");
var networkCursor = (await cdp.readEvents({methods: [
  "Network.requestWillBeSent", "Network.responseReceived", "Network.loadingFailed"
]})).cursor;
await cdp.send("Profiler.startPreciseCoverage", {
  callCount: true, detailed: true, allowTriggeredUpdates: false
});
```

With `O_EXCL`, atomically create the one-time
`$RUN_DIR/coverage/frontend-owner-start.json` containing browser ID, opaque tab
ID, optional separately sourced `cdp_target_id`, inert URL, random owner nonce,
cursor, start timestamp, and successful command order; compute its SHA after
close. This is the second-stage browser binding layered onto the earlier
immutable run identity. Then use the owner to navigate the same tab to `/` as
the first captured application action. Do not call
`Profiler.startPreciseCoverage` anywhere else. Every later browser envelope
references this owner-start SHA and nonce. Confirm process IDs belong to
generated instrumented binaries and control-panel selects the recorded coverage
image ID for Hosted Runtime.

- [ ] **Step 6: Prove RuntimeChannel admission before browser work**

Create one Hosted executor through the public control path; require container start, protocol V2 HELLO, active/routeable state, and healthy heartbeats. Record runtime ID, boot ID, image ID, and profile digest without credentials.

- [ ] **Step 7: Run the reusable Hosted coverage smoke on the live stack**

```bash
cd "$SOURCE_ROOT/hushine-deploy"
USER_ID="$ACCEPTANCE_USER_ID" \
HUSHINE_SOURCE_ROOT="$SOURCE_ROOT" \
COVERAGE_IMAGE=hushine/strategy-runtime:executor-coverage-acceptance \
bash scripts/smoke_hosted_runtime_coverage.sh \
  "$RUN_DIR/coverage/runtime-agent"
```

Require the exact recorded image ID, complete finalization, zero forced workers
on normal finish, valid Go shards, every raw Python shard independently valid,
and combined Go/Python reports. This is an early shard/lifecycle assertion;
only Task 12 may record the complete-run `coverage-finalization` scenario.

---

### Task 8: Run automated integration scenarios before browser acceptance

**Files:**
- Use repository integration tests/fixtures created by the three implementation plans.
- Write evidence only: `census-runs/<run-id>/integration/*.json`

- [ ] **Step 1: Run Futures regression scenarios**

Exercise Backtest and Demo using the recorded encrypted Futures Venue ID,
MARKET/LIMIT orders, fills/fees/rejects, pending recovery, stop-only, stop-and-
close, max-loss close, and the implemented liquidation behavior. Verify all
route facts include Portfolio, Venue, Strategy, Session, exchange, market,
symbol, and environment. This is automated contract evidence, not the later
real-page Demo scenario.

- [ ] **Step 2: Run Spot USDT scenarios**

Exercise Backtest and Demo with the Task 7 recorded encrypted Spot `VENUE_ID` and
Binance `/api/v3/account` and `/api/v3/exchangeInfo` semantics, canonical wallet
assets (`BTC`, `USDT`), trading symbol (`BTCUSDT`), MARKET/LIMIT filters,
insufficient quote/base balance, open-order fail-closed, dust, stop-only, and
stop-and-close including pre-existing declared-target exposure. Never pass raw
key/secret values. Prove a declared target whose exact free balance is zero is
an `already_closed` no-op rather than dust/failure, while any non-zero locked
amount or open order still fails the whole preplan before its first order.

- [ ] **Step 3: Run offline debugger parity scenarios**

Run Futures and Spot USDT replay from generated debug packages. Require multi-input parsing, BUY/SELL decisions, Spot canonical asset wallets, and stable diagnostics for capabilities intentionally unavailable offline.

- [ ] **Step 4: Run multi-input and mixed-market scenarios**

One strategy must include at least:

```python
INPUTS = [
    {"exchange": "binance", "market": "perpetual_futures", "symbol": "BTCUSDT", "interval": "1m"},
    {"exchange": "binance", "market": "perpetual_futures", "symbol": "BTCUSDT", "interval": "5m"},
    {"exchange": "binance", "market": "spot", "symbol": "ETHUSDT", "interval": "1m"},
]
```

Also run a strategy with Spot and Futures `BTCUSDT` ORDER_TARGETS. Verify streams, Venue routes, wallets, orders, and risk state cannot contaminate one another.

- [ ] **Step 5: Run exact Indicator V2 boundary scenarios**

Require:

```text
1023 -> open chunk 0, count 1023, finalized false
next two frames -> immutable chunk 0 count 1024 finalized true
                  open chunk 1 count 1 finalized false
repeat identical 1023-frame state -> no revision/write change
2049 frames -> 1024 finalized + 1024 finalized + 1 open/final tail
sparse marker at sequence 1438 -> stored/rendered at sequence/time 1438
```

The 1024 final chunk and one-point open chunk may travel in one platform request or two; durable state, sequence ownership, and immutability are the required contract.

- [ ] **Step 6: Run terminal and worker-failure scenarios**

Cover finished, failed, stopped, stop_failed, recoverable, worker unexpected exit, agent shutdown, and Bare worker-only restart. Every path must finalize the current indicator tail or surface a recoverable/finalization failure; no path may leave a session indefinitely running after its worker is gone.

Also attempt guarded Live `environment=2` and OKX execution through their safe
contract fixtures and require stable fail-closed results before any external
order or session side effect. Record these as `live-spot-rollout-guard` and
`okx-execution-fail-closed`; this acceptance does not authorize live trading.

- [ ] **Step 7: Record integration scenarios**

Write producer=`integration` envelopes for the registry's exact IDs, including
`futures-backtest`, `futures-demo-contract`, `spot-backtest`,
`spot-demo-contract`, and every ID below:

```text
offline-debugger-futures
offline-debugger-spot
multi-input-multi-interval
mixed-spot-futures
indicator-terminal-tail
futures-liquidation-max-loss
spot-stop-only
spot-stop-and-close
live-spot-rollout-guard
okx-execution-fail-closed
```

Do not record any `browser-*` ID here. Each pass requires zero-exit commands,
explicit API and durable-state assertions, scoped identity facts, and artifact
hashes.

---

### Task 9: Prove a blocked Bare worker cannot block the Runtime

**Files:**
- Use the cross-platform Bare fixture/launcher from the Indicator V2 plan.
- Write evidence only: `census-runs/<run-id>/bare-blocked-worker/*.jsonl`

- [ ] **Step 1: Materialize a block that remains active through a full ten-minute observation**

The user callback contains a real bounded blocking loop:

```python
import time

deadline = time.monotonic() + 660
while time.monotonic() < deadline:
    time.sleep(1)
```

Run it in the Python worker, never in the Go agent or test controller.

- [ ] **Step 2: Run the Indicator plan's mandatory long blocked-worker gate**

```bash
cd "$SOURCE_ROOT/strategy-service"
HUSHINE_BLOCKED_WORKER_SECONDS=660 \
HUSHINE_BLOCKED_WORKER_OBSERVE_SECONDS=600 \
  ./scripts/runtime-agent-blocked-worker.test.sh
```

Observe the complete continuous 600-second window, require at least 500
heartbeats and a maximum consecutive heartbeat gap no greater than five
seconds, and prove the Go runtime-agent remains live at every sample. Record
runtime-agent PID, boot ID, RuntimeChannel connection/lease, heartbeat
timestamp, worker PID/generation, session state, and unrelated health requests.
The agent PID/boot ID and lease remain unchanged while the Python callback is
still blocked. The companion `30/5` command is a fast repository regression
only and cannot produce either final Bare scenario.

- [ ] **Step 3: Perform worker-only restart**

After the full 600-second observation—and while the 660-second callback is
still blocked—invoke the supported one-line restart command. Require old worker
termination and reap, old indicator tail finalization, old session recoverable
publication, new session ID, new worker generation, reloaded code under the
supported `.hushine-runtime/strategies/user-<user_id>/...` path, and unchanged
agent PID/boot ID. A restart after the callback naturally unblocks is a failure.

- [ ] **Step 4: Verify cross-platform transport**

Use Task 4's freshly passed Windows cross-compile/release evidence, then run the
Indicator plan's platform transport contract. The Windows-supported Bare path
must not require a Unix-domain socket; endpoint creation, permission checks,
cleanup, and generation identity must use the selected cross-platform
transport. This check references but does not duplicate or pre-satisfy the
separate `windows-runtime-release` scenario.

- [ ] **Step 5: Record both Bare scenarios**

Write producer=`bare` envelopes for `bare-blocked-worker-heartbeat` and
`bare-worker-only-restart`, including all 600 seconds of monotonic observation
timestamps, heartbeat count, maximum gap, agent/worker generation identities,
still-blocked-at-restart assertion, command exit codes, and log hashes. The test
observes ten complete minutes but does not wait 660 seconds for natural callback
return; controlled restart ends it after the required long window.

---

### Task 10: Exercise every product area through the real page

**Files:**
- Write evidence only: `census-runs/<run-id>/browser/actions.jsonl`
- Write evidence only: `census-runs/<run-id>/browser/screenshots/*.png`
- Write evidence only: `census-runs/<run-id>/browser/network-summary.json`
- Write evidence only: `census-runs/<run-id>/browser/console-summary.json`

- [ ] **Step 1: Reuse the retained browser-client tab and establish clean baselines**

The non-dispatchable `browser-coverage-owner` continues in the same agent and
persistent Node kernel. Reuse the exact Browser binding, tab, CDP capability,
owner object, and nonce retained by Task 7; do not initialize a browser runtime,
kernel, or tab. Revalidate browser ID and opaque tab ID against the `O_EXCL`
`coverage/frontend-owner-start.json`, verify its SHA, and prove it records the
sole Profiler/Network start before navigation to the application. Any owner,
kernel, binding, browser/tab replacement, duplicate start, nonce mismatch, or
application action before that timestamp invalidates the run.

Use the browser-client tab's documented visible-page APIs. Before every click,
type, select, or assertion, take a fresh accessibility/DOM snapshot and resolve
a fresh reference; never reuse stale refs across navigation or rerender, except
for the narrowly specified secret-visible Telegram window below where only
targeted non-content locators are allowed. Record a console timestamp/sequence
baseline—there is no fictional clear API. Before each action, snapshot the CDP
network cursor; immediately afterward, the owner repeatedly calls
`readEvents(... afterSequence ...)` with the same method filters until
`hasMore=false`. Any `truncated=true` fails the run. Raw events remain only in
Node memory; before writing, strip headers, cookies, query/fragment, request and
response bodies, and retain only method, safe path, status, duration, and
redacted category.

- [ ] **Step 2: Exercise identity, navigation, and Portfolio/Venue creation**

Use the already authenticated tab when available. If login is required, begin
the Browser skill's secure `browserAuth` workflow before any credential
interaction; credentials are filled by the capability and never returned to,
read, or typed by the model. Do not snapshot/screenshot a credential page. A
browserAuth recovery that creates/replaces a tab invalidates this coverage run.
Then visit every primary navigation page, create/select Backtest and Demo
portfolios, and select the encrypted Binance Futures and Spot Demo Venues
recorded by Task 7. Create only non-secret Backtest Venue state during
capture. Do not type or paste raw exchange credentials while browser/network/
coverage capture is active. Verify Spot wallet rows are asset codes (`BTC`,
`USDT`) while order forms use symbols (`BTCUSDT`). Verify the one-active-Venue-
per-`(exchange, market)` rule within one Portfolio and isolation across two
Portfolios.

- [ ] **Step 3: Exercise strategy, market-data, and readiness paths**

Create/activate one single-input strategy, one multi-symbol/multi-interval strategy, and one mixed Spot/Futures strategy. Visit Historical Coverage, Data Viewer, live-stream controls, Strategy detail, debug package generation, and Run Strategy preview. Intentionally trigger and then resolve a missing-coverage/readiness error.

- [ ] **Step 4: Observe a running Backtest before finalization**

Start a Hosted session whose custom scalar and sparse BUY/SELL markers update while running. Before 1024 bars, verify the chart shows the open V2 data after the configured short flush delay. Let it pass 2049 bars and require two immutable 1024 chunks plus one tail.

- [ ] **Step 5: Run real Demo Futures and Spot**

Use only the recorded encrypted Demo Venue IDs. Through the page, run Futures
and Spot sessions, then inspect orders, fills, fees, wallet deltas, snapshots,
lifecycle, notifications, and reconciliation. The companion Spot smoke receives
`VENUE_ID`, not one-time raw key/secret values. Exchange rejection is acceptable
evidence only when the local request is contract-correct and the safe remote
error category/preconditions are recorded; it does not waive a local bug.

- [ ] **Step 6: Exercise stop, recovery, and restart controls**

For Futures and Spot, exercise stop-only and verify exposure remains. Exercise stop-and-close and verify exactly the declared target scope is processed, including the page warning that pre-existing target exposure is included. Exercise recoverable resume/new-session behavior and guarded worker-only restart; verify Runtime stays online.

- [ ] **Step 7: Exercise Telegram and remaining user-facing reads**

Create a binding code only after the Task 0 secure external Telegram handoff is
ready. The retained frontend tab never navigates to Telegram. From issuance
until confirmed consumption/expiry and UI clearing, bind code, chat ID, and
username are ephemeral secrets: make no DOM/accessibility dump, screenshot,
console-content capture, or hash. The operator/approved connector transfers the
code in an external Telegram client outside all model-visible tools; evidence
records only issuance/consumption timestamps and final bound status. During the
secret-visible interval, interact only with prevalidated targeted controls that
cannot return page text; once the code is cleared, resume fresh snapshots.
Refresh status, enable categories, send a test notification, emit strategy
notifications, inspect redacted history/delivery state, and unbind. Also inspect
Runtime detail/failures, Session list/detail tabs, Order History/tree, chart
toggles, snapshots, reconciliation, Quick Start return routing, profile, and
logout/login through the same-tab secure-auth rules.

- [ ] **Step 8: Fail on browser regressions**

After every action's network drain, perform a final cursor drain and read
console messages since the recorded timestamp baseline through the same owner.
There is no end-of-run unbounded network-list or clear call. Fail for uncaught
exceptions, React errors, failed same-origin API
calls, protocol decode errors, repeated polling storms, unexpected 4xx/5xx, a
coverage-owner mismatch, any truncated event page, or loss of the retained
tab/profiler owner. Explicitly
classify intentionally triggered validation/rejection responses. Run the
manifest secret scanner over action logs, redacted network/console summaries,
and decoded screenshot pixels/OCR results before recording a pass. Sensitive
pages are never screenshotted; every retained image is manually/automatically
marked reviewed and contains no credential/bind/identity secret.

- [ ] **Step 9: Record browser scenarios**

Create one producer=`browser` evidence envelope for each of:

```text
browser-auth-navigation
browser-portfolio-venue
browser-strategy-readiness
browser-running-indicator
browser-futures-demo
browser-spot-demo
browser-stop-recovery
browser-console-network
telegram-bind-test-unbind
```

Each contains browser ID, opaque tab ID, optional separately sourced CDP target
ID, owner nonce, owner-start SHA, its own envelope SHA, frontend URL, coverage
attachment assertion, applicable Portfolio/Venue/runtime/session IDs,
timestamped actions with fresh-snapshot identity, per-action network cursor/
non-truncation assertion, expected/actual assertions, and hashes of redacted
logs and approved screenshots. The manifest cross-record validator requires
all browser envelopes to share the owner binding and Task 12 finalization to
reference every browser-envelope SHA plus raw-coverage SHA. Automated
integration evidence from Task 8 cannot record or
satisfy these browser-producer scenarios.

---

### Task 11: Reconcile indicator, order, fill, and wallet data

**Files:**
- Create: `hushine-deploy/scripts/acceptance/export_runtime_v2_spot.py`
- Create: `hushine-deploy/scripts/acceptance/reconcile_runtime_v2_spot.py`
- Create: `hushine-deploy/scripts/acceptance/tests/test_export_runtime_v2_spot.py`
- Create: `hushine-deploy/scripts/acceptance/tests/test_reconcile_runtime_v2_spot.py`
- Write evidence only: `census-runs/<run-id>/reconciliation/*.json`

**Interfaces:**
- Produces: `export_runtime_v2_spot.py --run-dir <dir> --session-id <id> --portfolio-id <id> --venue-id <id> --output <json>`; performs read-only, parameterized, ID-scoped exports through owning APIs/DB read roles and emits no DSN/credential/secret-bearing column.
- Produces: `reconcile_runtime_v2_spot.py --input <redacted-export.json> --output <reconciliation.json>`.
- Consumes a schema-versioned redacted export for exactly one acceptance session and rejects an extra/unscoped identity.
- Emits one reconciliation record per `(session_id, stream_key, target_route)`.
- Exits non-zero for sequence gaps, wrong actual time, mutable finalized chunks, marker/order time mismatch, route contamination, impossible wallet delta, or missing fee/fill evidence.

- [ ] **Step 1: Add failing deterministic reconciliation tests**

Exporter tests prove every query is read-only/parameterized and scoped by the
recorded session/Portfolio/Venue IDs; reject missing/multiple identities,
secret-bearing columns, a DSN in output, and rows outside scope. Reconciler
fixtures cover a marker shifted from sequence 1438 to 588, a 1024 chunk later
shortened, duplicate open write, Spot `BTCUSDT` wallet asset, cross-Venue order,
and a valid complete session.

- [ ] **Step 2: Verify failure**

```bash
uv run --isolated --no-project --with pytest python -m pytest \
  scripts/acceptance/tests/test_export_runtime_v2_spot.py \
  scripts/acceptance/tests/test_reconcile_runtime_v2_spot.py -q
```

- [ ] **Step 3: Implement exact reconciliation**

Compare accepted bars, V2 sequence/actual time/interval, definitions, scalar null positions, markers, order intent, order/fill/fee, and wallet deltas. BUY/SELL marker sequence and actual time must match the strategy template's intended order/fill event; equal totals at different times are a failure.

- [ ] **Step 4: Reconcile every acceptance session**

For every recorded Futures, Spot, multi-input, mixed-market, stop,
liquidation/max-loss, and restart session, run the exporter with its exact
session/Portfolio/Venue IDs and then the reconciler with explicit input/output
paths. Hash both artifacts. Export and reconciliation files use schema version
1 and carry the exact source commits and image/runtime identities; the tool
fails if any requested scope does not match the run manifest.

- [ ] **Step 5: Seal the candidate diff and record**

```bash
git diff --check -- scripts/acceptance/export_runtime_v2_spot.py scripts/acceptance/reconcile_runtime_v2_spot.py scripts/acceptance/tests/test_export_runtime_v2_spot.py scripts/acceptance/tests/test_reconcile_runtime_v2_spot.py
```

Do not commit before the combined review in Task 14. Record
`durable-reconciliation`, `indicator-1023-plus-2`,
`indicator-repeat-idempotency`, and `indicator-sparse-marker-time` only when all
reconciliations pass.

---

### Task 12: Stop through product paths and finalize coverage

**Files:**
- Write evidence only: `census-runs/<run-id>/coverage/*`

- [ ] **Step 1: Gracefully end sessions and runtimes**

Stop active sessions through page/public API, wait for worker cleanup/finalization, end Hosted runtimes through Runtime Management, and verify Docker lifecycle ordering and exit zero. Do not kill coverage containers first.

After Task 11 has sealed all reconciliation evidence, clean up only Demo Venues
that Task 7 recorded as acceptance-owned. Use the supported authenticated
quant-handler delete/deactivate path and its history-preserving product
semantics; never issue direct credential-table SQL and never touch a
pre-existing Venue. Require the exact created Venue IDs to be absent from the
active/selectable list (or durably disabled when deletion is intentionally
soft), while their already recorded order/reconciliation history remains
queryable as the product contract requires. Add the redacted result to the
new immutable producer=`reconciliation` `demo-venue-cleanup` envelope; do not
edit or re-record the already hashed browser Demo scenarios. A cleanup failure
blocks finalization rather than broadening deletion scope.

- [ ] **Step 2: Take and stop precise frontend coverage on the same retained tab**

The original non-dispatchable browser owner continues in the same agent/kernel.
Before stopping the frontend or closing/replacing the tab, re-read browser ID
and opaque tab ID and require both, the in-memory nonce, CDP capability, and
owner-start SHA equal every browser envelope. Perform the final Network cursor
drain and fail on truncation. On that retained owner—and nowhere else—run:

```javascript
const precise = await cdp.send("Profiler.takePreciseCoverage");
await cdp.send("Profiler.stopPreciseCoverage");
await cdp.send("Network.disable");
await cdp.send("Profiler.disable");
```

Use `finally` to attempt Profiler stop plus Network/Profiler disable if take or
validation fails, but record the
scenario failed. Require a nonempty result with at least one script/function
and nonempty ranges for the frontend origin, the same owner binding, exactly one
prior start and one stop, and no UI action before start or after take. Atomically write the raw result,
browser/tab IDs, optional separate CDP target ID, nonce, owner-start SHA, every
browser-envelope SHA, URL, start/take timestamps, raw result hash, and command-
order record to `$RUN_DIR/coverage/frontend-precise-raw.json`; never include
browser storage, headers, query strings, or bodies.

- [ ] **Step 3: Stop the stack, normalize the captured frontend output, then merge census results**

```bash
bash "$SOURCE_ROOT/hushine-deploy/scripts/audit/census/start_instrumented_stack.sh" --stop --source-root "$SOURCE_ROOT" "$RUN_ID"
node "$SOURCE_ROOT/hushine-deploy/scripts/audit/census/frontend_coverage.mjs" \
  external-owner/normalize \
  --raw "$RUN_DIR/coverage/frontend-precise-raw.json" \
  --owner-start "$RUN_DIR/coverage/frontend-owner-start.json" \
  --output "$RUN_DIR/coverage/frontend-precise.json"
make -C "$SOURCE_ROOT/hushine-deploy" code-census-session-stop SOURCE_ROOT="$SOURCE_ROOT" RUN_ID="$RUN_ID"
```

- [ ] **Step 4: Validate raw and combined coverage**

Require the Task 4 unit-coverage registry to contain all eight Go module
profiles, four Python projects, deploy tooling, and frontend contract/source-map
reports, and validate every Go profile/covdata directory and Python
`.coverage*` shard independently. Combine only complete Hosted runtime
finalizations. Generate per-repository and Hosted Runtime function summaries
plus frontend unit and precise-coverage output. Require frontend finalization to
reference the owner-start SHA, every browser-envelope SHA, and raw coverage SHA,
with the same browser/tab/nonce binding. Write and record the producer=`coverage`
`coverage-finalization` envelope only after all raw shards, combinations,
process finalization assertions, and artifact hashes pass.

- [ ] **Step 5: Review meaningful gaps**

List unexecuted changed branches and user-facing handlers. During a preliminary
run, add focused tests or browser actions for missing critical lifecycle, risk,
migration, protocol, and error branches, then return to the owning gates. During
Task 14's committed-SHA run, any required source change invalidates the run and
returns to Task 14 Step 2/commit/clean-source initialization. Do not delete code
based only on this run; retain candidates for the user's later coverage-driven
cleanup decision.

- [ ] **Step 6: Run exact acceptance-owned database cleanup**

Invoke Task 5 Step 8 now. Require the complete stack/process registry to be
empty, all eight exact databases to be absent afterward, and the structured
`database-cleanup` scenario to pass. Cleanup failure, wrong ownership, or a
remaining connection/database blocks precheck; do not defer it until after
Notion or push.

- [ ] **Step 7: Precheck the acceptance manifest before documentation**

Run:

```bash
python3 "$SOURCE_ROOT/hushine-deploy/scripts/acceptance/runtime_v2_spot_manifest.py" \
  precheck --run-dir "$SOURCE_ROOT/census-runs/$RUN_ID" \
  --allow-pending notion-current-pages \
  --allow-pending remote-delivery \
  --allow-pending post-push-debugger-bootstrap
```

Expected: zero exit only when those exact three necessarily later scenarios are
the complete missing set and every other scenario is pass with valid redacted
evidence. If any other scenario is fail/blocked/missing, stop here and fix it;
do not update Notion.

---

### Task 13: Replace stale current Notion guidance and quarantine historical search hits

Use the `notion:notion-research-documentation` skill. Read
`notion://docs/enhanced-markdown-spec` before preparing or writing. This task
has two explicit phases: prepare a redacted targeted patch with no mutation,
then—only after Task 14 proves remote delivery and the deferred debugger gate—
refetch, apply it with targeted `update_content`, and verify. Do not overwrite
child-page blocks or delete history.

Do not execute this task immediately after Task 12 in the preliminary run.
Task 14 Step 6 invokes only the preparation phase after independent review,
repository-scoped commits, clean committed-SHA final Tasks 4–12, and the exact
three-pending precheck. Task 14 Step 11 invokes publication after delivery.
Notion is external evidence, not a substitute for a green code gate.

**Current pages:**
- Root: `ef0c1509-857a-8229-a104-0176fb5ce349` — `量化交易系统文档`
- Operations: `399c1509-857a-8137-83d1-e11e298bc3e9` — `1 基础运维`
- Code/logic: `399c1509-857a-8101-9dd2-e3599a734a03` — `2 代码结构和逻辑`
- User manual: `399c1509-857a-8165-a0a6-c9608b064c76` — `3 用户手册`
- Historical archive: `39ac1509-857a-81d9-84c8-e4ed70ca8bf9` — `Hushine 历史档案（禁止作为当前依据）`
- Historical B-series parent: `369c1509-857a-816b-8840-fe30b18ddc81` — parent of B.0–B.15; it is distinct from the archive landing page above and must be quarantined too.

- [ ] **Step 1: Refetch and reconcile the four current pages against the frozen requirements and final code**

Require each current page's `last_edited_time` to equal Task 0's frozen source
or explicitly re-run requirement reconciliation before proceeding. For every
factual statement, map it first to the frozen current requirement, then to a
final source/proto/schema/test/acceptance artifact. A conflict is resolved
explicitly rather than rewriting Notion to match code by default. Remove commit
IDs and dated claims that no longer match. The root page must keep exactly three
current entry pages. Produce a redacted per-page targeted patch artifact and
review it without calling any Notion mutation API.

- [ ] **Step 2: Update `1 基础运维`**

Document `.10` dependencies, database/Kafka/ELK/Jaeger topology, one-shot fresh bootstrap, migration/upgrade boundary, TLS/secrets, normal and coverage image builds, local instrumented service start/stop, health, smoke, coverage collection, backup/restore, and troubleshooting. Explicitly state Hosted/Self-hosted/Bare runtimes do not receive internal DB/Kafka/account/order addresses.

- [ ] **Step 3: Update `2 代码结构和逻辑`**

Document service/repository ownership, RuntimeChannel versus worker transport, dependency profile/digest admission, protocol V2 hello, Agent-owned 1024 sequence chunks, exact 1023+2/idempotency/sparse-marker behavior, all terminal finalization paths, blocked-worker heartbeat isolation, worker-only restart, Windows Bare transport, multi-input merge, Futures/Spot route isolation, Binance Spot asset/symbol/filter semantics, stop-and-close scope, notifications, liquidation/max-loss, and coverage architecture.

- [ ] **Step 4: Update `3 用户手册`**

Document Portfolio/Venue creation, Binance Futures and Spot USDT choices, canonical Spot wallet assets, strategy INPUTS/ORDER_TARGETS/INDICATORS, Backtest/Demo, Runtime selection, Session/chart/order/reconciliation, stop-only/stop-and-close warning, recoverable/new-session restart semantics, offline debugger, Telegram, and current Live/OKX guards.

- [ ] **Step 5: Quarantine the historical landing/parent and all B.0–B.15 pages**

Fetch the archive landing page `39ac1509-857a-81d9-84c8-e4ed70ca8bf9`, the
B-series parent `369c1509-857a-816b-8840-fe30b18ddc81`, and every child below.
Add the same first-line historical warning to both landing/parent pages, make
their relationship explicit, and link them to the current user manual. Prefix
the B-series parent and every child title with `[历史明细]` if missing. Preserve
historical body text for traceability; do not present it as verified current
behavior. The current root still contains exactly the three current entry
pages—never add an archive page as a fourth current entry.

Child IDs:

```text
369c1509-857a-8144-adf8-f193fa9bd37a  B.0
369c1509-857a-8109-a0f1-efd1c400d975  B.1
369c1509-857a-8108-90f0-d0961ade8e3e  B.2
369c1509-857a-814c-94a9-ff28676f1a16  B.3
369c1509-857a-8195-b635-fae698e52e79  B.4
369c1509-857a-81bd-acd5-eda49829543d  B.5
369c1509-857a-8131-b1bc-cb8a242a6c73  B.6
369c1509-857a-81ea-8276-c21ff08eae85  B.7
369c1509-857a-81f4-b367-c349830172d4  B.8
369c1509-857a-813f-b5bc-cc0b4c844e61  B.9
369c1509-857a-8183-8422-e0d46beb1598  B.10
369c1509-857a-815b-9597-c6278aed4a6f  B.11
369c1509-857a-81a1-83bd-f0008ed4cf14  B.12
38dc1509-857a-8167-a7bf-e12cc9ba9c21  B.13
394c1509-857a-817f-acf9-d2b078adef71  B.14
394c1509-857a-8167-b4ab-d593329de8d5  B.15
```

The warning must say the page may contain old Runtime, indicator, Account-era, migration, screenshot, or Futures-only behavior and link to page `399c1509-857a-8165-a0a6-c9608b064c76`.

- [ ] **Step 6: After remote delivery, refetch, apply the prepared patch, and verify links/facts**

Immediately before the first write, refetch every target and require its
`last_edited_time` still equals the prepared base. Any concurrent edit blocks
publication and requires a new reconciliation/patch; never overwrite it. Apply
targeted updates in dependency-safe order, recording before/after timestamps.
If a write is partial, stop further writes, report the exact redacted page set,
and repair via targeted forward updates; remote Git history remains unchanged.

Refetch root/current/archive/B-series-parent/child pages. Search current pages
for `account.v1`, `strategy-service :50053`, `hushine-runtime start`,
`runtime_env`, `Unix socket`, V1 indicator fields, old migration IDs, and
historical page URLs. A mention inside an explicit historical-warning section
is allowed; an operational instruction is not.

Search for `Runtime Management`, `Chart 自定义指标`, `Spot USDT`, and `1023 + 2`; current results must lead first to one of the three current pages, while historical results visibly start with `[历史明细]`.

- [ ] **Step 7: Record `notion-current-pages` only after publication/refetch**

Store a producer=`notion` envelope with every current/archive/parent/child page
ID, final `last_edited_time`, section checklist, current-root child count, title/
warning/link audit, source-commit ledger, and hashes of redacted refetch output.
Do not copy full Notion page bodies into Git. A page not refetched after its
last write or a historical result without the warning makes the scenario fail.

---

### Task 14: Independent review, committed-SHA final run, remote delivery, and Notion publication

Use `superpowers:requesting-code-review` followed by `superpowers:verification-before-completion`.

- [ ] **Step 1: Run independent cross-plan reviews**

Assign separate reviewers to:

1. dependency/profile/image closure;
2. Indicator V2/chunk/lifecycle/Bare transport;
3. Spot USDT/order/wallet/risk/UI;
4. deployment, database preservation, acceptance evidence, and Notion accuracy.

Reviewers inspect diffs, tests, generated artifacts, and preliminary evidence,
not just green summaries. They explicitly compare all four plans and the current
AGENTS/product invariants. Consolidate findings into one ledger with owner,
severity, disposition, and verification command.

- [ ] **Step 2: Resolve review findings before any final commit**

Resolve every correctness/blocking finding with TDD. Rerun each narrow
reproducer, owning repository suite, generated-artifact check, and affected
preliminary acceptance scenario. Invoke `superpowers:receiving-code-review` for
ambiguous feedback and do not accept a suggestion without verifying it against
the final combined contract. Repeat independent review until the finding ledger
has no unresolved correctness/blocking item.

- [ ] **Step 3: Commit each affected repository independently**

Stage only task-owned hunks in each owning repository; preserve every Task 0
unrelated dirty path. Use repository-scoped commits with coherent messages and
include generated artifacts with their source. No acceptance evidence is
staged. Record each commit SHA and the exact staged path list before committing.
After the final commit, rerun `git diff --cached --check`/`git diff --check` and
prove no task-owned change remains uncommitted.

- [ ] **Step 4: Materialize and seal one clean immutable source root**

Require all affected repositories to be clean at their recorded commit SHAs. If
Task 0 preserved unrelated dirt in any original worktree, create detached clean
repository worktrees under a run-local
`/Users/xdy/Workplace/hushine-worktrees/medium-cleanup/.acceptance-final/<id>/`
source-root, preserving the sibling/nested ten-repository layout; never clean or
copy the unrelated dirt. Run all final commands only from this clean source
root. Verify for all ten repositories:

```bash
git rev-parse HEAD
git status --porcelain=v1
git diff --exit-code
git diff --cached --exit-code
```

All status/diff commands must be empty. Write a canonical source-SHA ledger for
the exact ten commits. Any code or Git-tracked documentation change after this
point invalidates the run, even if its narrow tests pass.

- [ ] **Step 5: Initialize a fresh manifest, then rerun Tasks 4–12 from zero**

Do not copy any PASS marker, log, database allocation, coverage shard, image
identity, or browser evidence from the preliminary run. Create a new run before
Task 4:

```bash
FINAL_RUN_ID="runtime-v2-spot-final-$(date -u +%Y%m%d-%H%M%S)"
FINAL_RUN_DIR="$FINAL_SOURCE_ROOT/census-runs/$FINAL_RUN_ID"
python3 "$FINAL_SOURCE_ROOT/hushine-deploy/scripts/acceptance/runtime_v2_spot_manifest.py" \
  init --run-dir "$FINAL_RUN_DIR" --source-root "$FINAL_SOURCE_ROOT" \
  --baseline-ledger <absolute-task-0-ledger> \
  --notion-requirements <absolute-task-0-notion-requirements>
```

Point `SOURCE_ROOT`, `RUN_ID`, and `RUN_DIR` to these final values, then rerun
Task 4, Task 6, Task 5, and Tasks 7–12 in that order, including no-cache normal/coverage images, both complete
isolated DB stacks, Browser skill same-tab CDP coverage, Demo page workflows,
reconciliation, Windows release gate, graceful coverage finalization, and exact
eight-database cleanup. Every evidence envelope must carry the clean source-SHA
ledger. Before leaving Task 12, recheck all ten SHAs/statuses and image source
labels. Any mismatch or later code/doc commit discards this run and returns to
Step 4 with a new run ID.

- [ ] **Step 6: Prepare and review the Notion patch without publishing**

Run Task 13 Steps 1–5 in preparation-only mode using the frozen Task 0 Notion
requirements, final committed code, and final run evidence. Refetch current and
historical targets, reconcile concurrent edits, and independently review the
redacted targeted patch artifact, but call no mutation API and do not record
`notion-current-pages` yet. Require that exactly Notion plus the two delivery
scenarios remain pending:

```bash
python3 "$SOURCE_ROOT/hushine-deploy/scripts/acceptance/runtime_v2_spot_manifest.py" \
  precheck --run-dir "$RUN_DIR" \
  --allow-pending notion-current-pages \
  --allow-pending remote-delivery \
  --allow-pending post-push-debugger-bootstrap
```

Require exit zero. Recheck the ten repository SHAs and clean statuses after
patch preparation. Prepared base timestamps, source-SHA ledger, image labels,
and report inputs must all refer to this same run.

- [ ] **Step 7: Compute exact file and line counts from Task 0 baselines**

For each repository:

```bash
git diff --name-status <baseline>..HEAD
git diff --numstat <baseline>..HEAD
git diff --diff-filter=D --name-only <baseline>..HEAD
git diff --numstat --diff-filter=D <baseline>..HEAD
```

Sum added and removed lines separately; compute the deleted-file line total
from the deletion-only numstat independently of total removed lines. List every
added, modified, renamed, and deleted file. Report binary rows separately
rather than treating `-` as zero.

- [ ] **Step 8: Preflight every affected remote before the first push**

Fetch and check every affected repository first, recording local and remote
SHAs. Do not push any repository until all ancestor checks succeed:

```bash
git fetch origin cleanup/medium-baseline-20260710
git merge-base --is-ancestor origin/cleanup/medium-baseline-20260710 HEAD
git status --porcelain=v1
```

If any remote moved incompatibly or any source SHA/status differs from the
final run, stop before the first push and reconcile normally. Never force push.

- [ ] **Step 9: Push the preflighted commits in dependency order without force**

Push `strategy-library` before `strategy-debugger-cli`; push every other
producer before its generated/consumer repository according to the reviewed
dependency ledger. This is a coordinated sequence after the all-repository
preflight, not permission to publish strategy-library early just to make a gate
pass. For every preflighted repository:

```bash
git push origin HEAD:cleanup/medium-baseline-20260710
git ls-remote origin refs/heads/cleanup/medium-baseline-20260710
```

Require the returned remote SHA to equal the exact local SHA in the final run.
If a race moves a remote during sequential pushes, stop immediately, do not
force or rewrite already pushed repositories, and report/reconcile the partial
delivery explicitly.

- [ ] **Step 10: Record remote delivery, then run the deferred no-mirror network gate**

After every affected remote SHA equals the final source ledger, write a
producer=`delivery` `remote-delivery` envelope containing the complete affected
repository set, approved ref, local/remote SHAs, fetch/push/ls-remote command
results, timestamps, and artifact hashes. A partial push cannot record pass.

Then run the dependency plan's necessarily post-push gate from a fresh
directory with no URL rewrite, sibling library, warm cache, or inherited HOME:

```bash
LIBRARY_PUBLISHED_REF=cleanup/medium-baseline-20260710
DEBUGGER_PUBLISHED_REF=cleanup/medium-baseline-20260710
DEBUGGER_COMMIT=<strategy-debugger-cli-sha-from-final-ledger>
LIBRARY_COMMIT=<strategy-library-sha-from-final-ledger>
test -n "$LIBRARY_PUBLISHED_REF"
test -n "$DEBUGGER_PUBLISHED_REF"
test -n "$DEBUGGER_COMMIT"
test -n "$LIBRARY_COMMIT"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/home"
env -u GIT_CONFIG_COUNT -u GIT_CONFIG_KEY_0 -u GIT_CONFIG_VALUE_0 \
  -u GIT_ALLOW_PROTOCOL HOME="$TMP/home" \
  git clone --branch "$LIBRARY_PUBLISHED_REF" \
  https://github.com/hushine-tech/strategy-library.git "$TMP/library"
test "$(git -C "$TMP/library" rev-parse HEAD)" = "$LIBRARY_COMMIT"
env -u GIT_CONFIG_COUNT -u GIT_CONFIG_KEY_0 -u GIT_CONFIG_VALUE_0 \
  -u GIT_ALLOW_PROTOCOL HOME="$TMP/home" UV_CACHE_DIR="$TMP/library-uv-cache" \
  uv run --directory "$TMP/library" --isolated --no-project \
    --with-editable '.[test]' python scripts/check_runtime_dependency_contract.py \
    --baseline-only --baseline-ref "$LIBRARY_COMMIT" --json \
    > "$TMP/library-baseline.json"
jq -e '.baseline.state == "present" and .ok == true' "$TMP/library-baseline.json"
env -u GIT_CONFIG_COUNT -u GIT_CONFIG_KEY_0 -u GIT_CONFIG_VALUE_0 \
  -u GIT_ALLOW_PROTOCOL HOME="$TMP/home" \
  git clone --branch "$DEBUGGER_PUBLISHED_REF" \
  https://github.com/hushine-tech/strategy-debugger-cli.git "$TMP/debugger"
test "$(git -C "$TMP/debugger" rev-parse HEAD)" = "$DEBUGGER_COMMIT"
env -u GIT_CONFIG_COUNT -u GIT_CONFIG_KEY_0 -u GIT_CONFIG_VALUE_0 \
  -u GIT_ALLOW_PROTOCOL HOME="$TMP/home" UV_CACHE_DIR="$TMP/uv-cache" \
  bash "$TMP/debugger/scripts/bootstrap-standalone.test.sh" \
  --network --expected-library-commit "$LIBRARY_COMMIT"
```

The fresh library clone must report baseline state `present`. The debugger
script must refuse every mirror/local path/rewrite and run fresh standalone
bootstraps on Python 3.12, 3.13, and 3.14. Verify installed `direct_url` metadata names
the canonical HTTPS strategy-library URL and exact `$LIBRARY_COMMIT`. Record a
producer=`delivery` `post-push-debugger-bootstrap` envelope with clean-network
assertions and redacted log hashes. Pre-push local bare-mirror/offline evidence
does not satisfy it.

If this gate fails, the repositories are already partially delivered: report
that fact, do not claim release completion, do not force/rewrite remote history,
and repair only with normal fix-forward commits followed by every invalidated
review/final-run/Notion/coordinated-push gate. Never push strategy-library alone
early to make this test pass.

- [ ] **Step 11: Publish/refetch the prepared Notion patch after delivery**

Run Task 13 Steps 6–7. Immediately refetch and compare each target to the
prepared base before writing; on concurrent edit, regenerate/review the patch.
Apply targeted updates, refetch every current/archive/parent/child page, and
record `notion-current-pages`. A partial write is repaired by targeted forward
updates and blocks finalization, but never rewrites already delivered Git
history. Recheck all remote SHAs and prepared source facts afterward.

- [ ] **Step 12: Finalize the now-complete manifest**

```bash
python3 "$SOURCE_ROOT/hushine-deploy/scripts/acceptance/runtime_v2_spot_manifest.py" \
  finalize --run-dir "$RUN_DIR"
```

Require exit zero with no pending exception. Refetch remote SHAs and Notion page
timestamps one last time and require them to match the delivery/notion evidence;
recheck the clean source-SHA ledger. Finalization cannot precede either delivery
scenario.

- [ ] **Step 13: Deliver the final report**

Report:

- repository -> local commit -> remote ref/SHA;
- files added/modified/renamed/deleted;
- exact lines added and removed, plus deleted-line total;
- all test commands/results;
- normal/coverage image IDs/digests;
- migration versions and non-indicator preservation hashes;
- browser workflow results and relevant screenshots;
- Futures/Spot/indicator/order/fill/wallet reconciliation;
- blocked-worker heartbeat/restart evidence;
- coverage summaries and remaining unexecuted meaningful branches;
- Notion pages updated and historical pages quarantined;
- coordinated remote-delivery evidence and the clean-network, no-mirror
  post-push debugger bootstrap;
- remaining external limitations, especially Demo exchange behavior and guarded Live/OKX execution.

Do not claim completion until remote SHAs, the post-push clean-network debugger
bootstrap, final acceptance manifest, and Notion refetch all agree with the
report.
