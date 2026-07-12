# Hosted Runtime Coverage Final Review Remediation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Close the final-review gaps so hosted runtime coverage is provably finalized, bounded, safely cleaned, aggregated across runtimes, and ready for the user's manual census workflow.

**Architecture:** The runtime-agent owns an atomic per-boot `finalization.json` marker. It closes worker admission, drains in-flight starts, stops every worker within explicit bounds, snapshots Go counters, and records whether any worker required force. control-panel chooses graceful cleanup from the container's persisted label and honors the configured stop budget. Code Census stops only coverage containers labeled for the active run, requires a complete runtime-agent marker before reporting a runtime `ok`, writes per-runtime manifests, and creates combined Go/Python reports from complete runtimes only.

**Tech Stack:** Go 1.26, Python 3.13, coverage.py 7.x, Docker CLI, Go runtime coverage, unittest/pytest, Bash, Superpowers TDD and review gates.

## Global Constraints

- Work only in `/Users/xdy/Workplace/hushine-worktrees/medium-cleanup` on `cleanup/medium-baseline-20260710`; preserve unrelated work and stage only owned files.
- Coverage remains opt-in; normal images and disabled provisioning behavior remain uninstrumented.
- Hosted runtimes still receive only RuntimeChannel identity/credential/TLS and the two explicit coverage variables; `runtime_env` stays rejected.
- `finalization.json` contains no credential, TLS material, raw error text, address, strategy code, or Docker environment values.
- A runtime is coverage-complete only when its latest boot marker is `complete`, worker shutdown had no error or forced stop, and the Go snapshot succeeded.
- Census finalization targets only containers labeled `hushine.runtime.coverage=true` and `hushine.runtime.coverage_run_id=<active run id>`.
- Missing, running, malformed, failed, or force-stopped finalization evidence makes the runtime `incomplete`; mergeable files alone never produce overall `ok`.
- Combined reports contain only runtimes whose finalization, Go, and Python statuses are all `ok`; raw per-runtime shards are retained.
- All shutdown/cleanup waits remain bounded; forced removal is attempted after a stop failure, and the stop failure remains visible.
- The live manual census is not finalized during implementation. Restore the instrumented application stack and preserve Chrome/CDP collection for handoff.

---

### Task 9: Make runtime-agent shutdown admission-safe, bounded, and attestable

**Files:**
- Modify: `strategy-service/internal/runtimeagent/worker_manager.go`
- Modify: `strategy-service/internal/runtimeagent/worker_manager_test.go`
- Modify: `strategy-service/internal/runtimeagent/coverage.go`
- Modify: `strategy-service/internal/runtimeagent/coverage_test.go`
- Modify: `strategy-service/cmd/runtime-agent/main.go`
- Modify: `strategy-service/cmd/runtime-agent/main_test.go`

**Interfaces:**
- Produce: `var ErrWorkerManagerStopping error` and an admission gate that rejects new starts after `StopAll` begins.
- Produce: `type WorkerShutdownSummary struct { ForcedStops int }` and `func (m *WorkerManager) ShutdownSummary() WorkerShutdownSummary`.
- Produce: `type CoverageFinalization struct` with schema version `1`, runtime ID, boot ID, state (`running|complete|incomplete`), worker shutdown status, forced worker count, Go snapshot status, and completion timestamp.
- Produce: `InitializeCoverageFinalization(root, runtimeID string) (bootID string, err error)` and `WriteCoverageFinalization(root string, record CoverageFinalization) error`; both use same-directory temp file + rename.
- Preserve: `StopSessionWorker` and `StopAll` public signatures and worker-replacement identity semantics.

- [ ] **Step 1: Add RED admission and bounded-cleanup tests**

Add tests that block the initial session-root cleanup inside `StartSessionWorker`, begin `StopAll`, and assert a second start returns `ErrWorkerManagerStopping`. Release the blocked start and assert `StopAll` stops the worker registered by that in-flight start. Add a managed worker whose process-exit channel closes but whose cleanup `done` channel never completes; assert `StopSessionWorker` returns a cleanup-pending/context error within the supplied bound and retains the session reservation.

Run:

```bash
go test ./internal/runtimeagent -run 'TestStopAllClosesAdmissionAndDrainsInFlightStart|TestStopSessionWorkerBoundsPostExitCleanup' -count=1
```

Expected: FAIL because worker admission is open during `StopAll` and stop waits forever on cleanup.

- [ ] **Step 2: Implement the minimal worker lifecycle fix**

Under `WorkerManager.mu`, track `stopping`, the number of in-flight starts, and a drain channel. `StartSessionWorker` must acquire admission before `PrepareSessionWorker` and release it only after failure cleanup or active-map registration. `StopAll` sets `stopping=true`, waits for admitted starts to drain subject to `ctx`, then snapshots and deduplicates active workers.

Stop logic must wait on `processExited` separately from managed cleanup. After TERM timeout, record a forced stop, send kill, and wait for process reap only within the remaining context/bound. If cleanup is still pending, return a bounded error without deleting registry/active ownership; the existing wait goroutine releases it only after cleanup succeeds.

- [ ] **Step 3: Verify worker RED→GREEN and platform build**

Run:

```bash
go test ./internal/runtimeagent -count=1
go vet ./internal/runtimeagent
GOOS=windows GOARCH=amd64 go test -c ./internal/runtimeagent -o /tmp/runtimeagent-windows.test.exe
```

Expected: PASS; the Windows build has no POSIX-only symbols.

- [ ] **Step 4: Add RED finalization-marker tests**

Tests must assert:

- startup atomically replaces an old `complete` marker with a new boot ID in `running` state;
- successful worker stop + Go snapshot produces `complete`;
- stop error, forced count, or snapshot error produces `incomplete`;
- marker JSON exposes only the approved fields and never raw error text;
- shutdown orders worker stop before snapshot, and snapshot before the marker is finalized.

Run:

```bash
go test ./internal/runtimeagent ./cmd/runtime-agent -run 'Finalization|Shutdown' -count=1
```

Expected: FAIL because the marker and ordered result handling do not exist.

- [ ] **Step 5: Implement atomic coverage finalization**

Initialize the marker after the trusted coverage root and runtime identity are known. On cancellation, close/drain worker admission through `StopAll`, snapshot Go counters, then write a final record. State is `complete` only when `StopAll` returns nil, `ShutdownSummary().ForcedStops == 0`, and the snapshot succeeds. Log only safe status names when finalization writing fails. Keep gRPC graceful/forced shutdown bounded after coverage finalization.

- [ ] **Step 6: Run full strategy verification and commit**

Run:

```bash
go test ./...
go vet ./...
PYTHONPATH=.:../strategy-library uv run --frozen --extra dev pytest tests/ -q
bash scripts/start-bare-runtime-debugpy.test.sh
bash scripts/runtime-agent-platform.test.sh
```

Expected: PASS.

Commit only owned strategy-service files:

```bash
git add internal/runtimeagent/worker_manager.go internal/runtimeagent/worker_manager_test.go internal/runtimeagent/coverage.go internal/runtimeagent/coverage_test.go cmd/runtime-agent/main.go cmd/runtime-agent/main_test.go
git commit -m "fix: attest bounded runtime coverage shutdown"
```

### Task 10: Make control-panel cleanup fact-based, correctly bounded, and safely redacted

**Files:**
- Modify: `control-panel-service/internal/provision/provision.go`
- Modify: `control-panel-service/internal/provision/docker.go`
- Modify: `control-panel-service/internal/provision/docker_test.go`
- Modify: `control-panel-service/internal/runtime/service.go`
- Modify: `control-panel-service/internal/runtime/service_test.go`

**Interfaces:**
- Produce optional interface: `type CleanupTimeoutProvider interface { DeprovisionTimeout() time.Duration }`.
- `DockerProvisioner.DeprovisionTimeout` returns a bound that includes the configured Docker stop grace, forced removal, and small command overhead.
- `DockerProvisioner.Deprovision` inspects `hushine.runtime.coverage` on the actual container before choosing stop-first cleanup.
- Preserve: normal/coverage provision arguments, opaque handle interface, and best-effort forced removal.

- [ ] **Step 1: Add RED container-fact and error-propagation tests**

Add exact runner tests for:

- current config disabled + container label `coverage=true` => inspect, stop with configured/default timeout, then rm;
- current config enabled + container label absent/false => inspect then rm without stop;
- inspection failure => conservative stop then rm, with the inspection failure reported;
- stop failure + successful rm => returned error still contains the stop failure;
- canceled/short caller context cannot truncate the declared cleanup budget;
- service cleanup context deadline is at least the provisioner's declared bound.

Run:

```bash
go test ./internal/provision ./internal/runtime -run 'Deprovision|CleanupTimeout|ContainerFact' -count=1
```

Expected: FAIL because cleanup is selected from global config, stop errors are discarded, and service hard-codes ten seconds.

- [ ] **Step 2: Implement fact-based bounded cleanup**

Inspect only the platform coverage label. Use the configured stop timeout even when coverage is currently disabled, because defaults remain present. Always attempt `docker rm -f` with a fresh bound. Return `errors.Join(inspectErr, stopErr, removeErr)` for attempted operations; do not clear a stop failure merely because removal succeeded. Service selects the optional timeout provider's value before calling `Deprovision`.

- [ ] **Step 3: Add RED actual TLS-key redaction test**

Feed diagnostics containing JSON and key/value forms of `client_key_pem`, including a multiline PEM body. Assert no key body or secret survives. Keep the existing `private_key_pem`, API key, token, and password cases.

Run:

```bash
go test ./internal/provision -run 'Diagnostics.*Redact|ClientKeyPEM' -count=1
```

Expected: FAIL because the regex does not recognize `client_key_pem`.

- [ ] **Step 4: Extend redaction minimally and verify**

Extend the existing sensitive-name alternatives to cover `client[_-]?key(?:_pem)?` without logging or parsing the runtime credential JSON elsewhere.

Run:

```bash
go test ./...
go vet ./...
```

Expected: PASS.

- [ ] **Step 5: Commit control-panel-service**

```bash
git add internal/provision/provision.go internal/provision/docker.go internal/provision/docker_test.go internal/runtime/service.go internal/runtime/service_test.go
git commit -m "fix: preserve hosted coverage cleanup facts"
```

### Task 11: Finalize hosted containers and produce trustworthy per-runtime and combined Census reports

**Files:**
- Modify: `/Users/xdy/Workplace/hushine/scripts/audit/census/census/config.py`
- Modify: `/Users/xdy/Workplace/hushine/scripts/audit/census/census/coverage.py`
- Modify: `/Users/xdy/Workplace/hushine/scripts/audit/census/config.yaml`
- Modify: `/Users/xdy/Workplace/hushine/scripts/audit/census/tests/test_config.py`
- Modify: `/Users/xdy/Workplace/hushine/scripts/audit/census/tests/test_coverage.py`

**Interfaces:**
- Produce `CensusConfig.hosted_runtime_coverage` with default `stop_timeout_seconds: 10` and positive validation.
- Produce `finalize_hosted_runtime_containers(ctx, cfg, run_command=subprocess.run) -> list[dict]`.
- Consume `${runtime_dir}/finalization.json` schema version `1` from Task 9.
- Produce `${runtime_dir}/coverage-manifest.json` and `${runtime-agent-root}/hosted-runtime-coverage-combined-summary.json`.
- Preserve `hosted-runtime-coverage-summary.json` as the ordered list of per-runtime results for current consumers.

- [ ] **Step 1: Add RED finalization-gate tests**

Add fake-Docker tests proving only containers with both current-run labels are stopped, unsafe/mismatched runtime labels are rejected, configured timeout is used, and stop failure is recorded. Add collector tests proving mergeable Go/Python files with missing/running/malformed/incomplete markers yield overall `incomplete`; a matching `complete` marker yields `ok`; and a stale marker is overwritten by Task 9 startup semantics rather than trusted by Census.

Run:

```bash
python3 -m unittest scripts.audit.census.tests.test_config scripts.audit.census.tests.test_coverage -v
```

Expected: FAIL because Docker finalization and marker validation do not exist.

- [ ] **Step 2: Implement current-run container finalization**

Before hosted report collection in `stop_session_collectors`, list containers with Docker's two exact label filters, parse tab-separated ID/runtime/user fields without a shell, validate the runtime ID as one safe component, call `docker stop --time <configured>` on each, and wait a short bounded interval for its marker to leave `running`. Store only IDs, runtime IDs, exit codes/status names, and safe error categories in the session summary. Do not print raw Docker output or environment values. Do not remove containers in Census; control-panel remains the cleanup owner.

- [ ] **Step 3: Implement marker-gated per-runtime manifests**

Always generate language reports when raw inputs exist, but derive overall status from both languages plus finalization. Write a per-runtime manifest containing the marker fields, language statuses/report paths, and combined-inclusion decision. Missing or invalid finalization evidence is `incomplete` even when both languages merge.

- [ ] **Step 4: Add RED combined-report tests**

Create two complete runtimes and one incomplete runtime. Assert combined Go/Python command inputs include only the complete pair, raw inputs are retained, output files are nonempty, and the combined summary lists included and excluded runtime IDs with reasons. Assert zero complete runtimes yields explicit `missing`/`incomplete`, not a fabricated zero-coverage report.

Run:

```bash
python3 -m unittest scripts.audit.census.tests.test_coverage -v
```

Expected: FAIL because no cross-runtime reports exist.

- [ ] **Step 5: Implement deterministic combined reports**

Recreate only the owned `runtime-agent/combined` output. Merge eligible Go input directories with `go tool covdata`; stage uniquely named copies of eligible Python `.coverage.*` shards (or the base file only when no shards exist), then run locked `uv run --frozen --extra coverage coverage combine/report/json`. Never delete per-runtime raw data. Write the combined summary after all commands finish.

- [ ] **Step 6: Run full Census verification and record non-Git hashes**

Run:

```bash
python3 -m unittest discover -s scripts/audit/census/tests -v
python3 -m compileall -q scripts/audit/census/census scripts/audit/census/tests
bash -n scripts/audit/census/start_instrumented_stack.sh
scripts/audit/census/start_instrumented_stack.sh --dry-run --source-root /Users/xdy/Workplace/hushine-worktrees/medium-cleanup manual-coverage-20260711-230823
```

Expected: PASS. Record paths, modes, sizes, and SHA-256 values in the Task 13 report; the orchestration root is intentionally non-Git.

### Task 12: Make the reusable smoke enforce the exact finalization contract

**Files:**
- Modify: `hushine-deploy/scripts/smoke_hosted_runtime_coverage.go`
- Modify: `hushine-deploy/scripts/smoke_hosted_runtime_coverage_test.go`
- Modify: `hushine-deploy/scripts/smoke_hosted_runtime_coverage.sh`
- Modify: `hushine-deploy/scripts/smoke_hosted_runtime_coverage.test.sh`
- Modify: `hushine-deploy/docs/superpowers/specs/2026-07-11-hosted-runtime-coverage-design.md`
- Modify: `hushine-deploy/docs/superpowers/plans/2026-07-11-hosted-runtime-coverage.md`

**Interfaces:**
- Preview requires exact `profile=backtest`, `supported=true`, `ok=true`, zero failures, and exactly one declared input.
- Docker lifecycle requires ordered `kill(signal=15) -> die(exitCode=0) -> destroy` for the exact container.
- Runtime root requires schema-1 `finalization.json` in exact `complete` state with no worker error, zero forced workers, and successful Go snapshot.

- [ ] **Step 1: Add RED strict Preview/finalization/order tests**

Extend Go behavioral tests for the exact Preview predicate. Extend the tracked shell contract and a fixture-based `jq -s` check so out-of-order lifecycle events fail. Require all approved finalization fields and forbid raw error-detail fields.

Run:

```bash
./scripts/smoke_hosted_runtime_coverage.test.sh
```

Expected: FAIL because profile/input cardinality, finalization marker, and event order are not enforced.

- [ ] **Step 2: Implement minimal strict assertions and update design truthfully**

Tighten the helper predicate, validate the marker after EndRuntime and before report generation, and use one ordered event assertion. Update the design/plan with the marker schema, current-run Census stop boundary, incomplete semantics, and combined output paths.

- [ ] **Step 3: Verify and commit deploy tooling/docs**

Run:

```bash
./scripts/smoke_hosted_runtime_coverage.test.sh
bash -n scripts/smoke_hosted_runtime_coverage.sh
(cd ../control-panel-service && go test ../hushine-deploy/scripts/smoke_hosted_runtime_coverage.go ../hushine-deploy/scripts/smoke_hosted_runtime_coverage_test.go)
(cd ../control-panel-service && go vet ../hushine-deploy/scripts/smoke_hosted_runtime_coverage.go ../hushine-deploy/scripts/smoke_hosted_runtime_coverage_test.go)
```

Expected: PASS.

```bash
git add scripts/smoke_hosted_runtime_coverage.go scripts/smoke_hosted_runtime_coverage_test.go scripts/smoke_hosted_runtime_coverage.sh scripts/smoke_hosted_runtime_coverage.test.sh docs/superpowers/specs/2026-07-11-hosted-runtime-coverage-design.md docs/superpowers/plans/2026-07-11-hosted-runtime-coverage.md
git commit -m "test: require finalized hosted coverage"
```

### Task 13: Rebuild, restore the sampled stack, verify, re-review, and push

**Files:**
- Modify ignored reports/ledger only under `hushine-deploy/.superpowers/sdd/`.

**Interfaces:**
- Produce fresh image, runtime, finalization marker, per-runtime reports, combined reports, full test evidence, and restored live services/CDP.
- Push `cleanup/medium-baseline-20260710` in strategy-service, control-panel-service, and hushine-deploy only after both final review stages approve.

- [ ] **Step 1: Build the new coverage image and restore the instrumented application stack**

Build `hushine/strategy-runtime:executor-coverage`, restart the generated local instrumented core/control/scraper/handler/frontend stack against `.10`, preserve or reconnect Chrome/CDP, and verify ports `8080`, `50051`, `8082`, `50054`, `50055`, `8090`, `5173`, and `9222`.

- [ ] **Step 2: Run fresh full verification**

Repeat all AGENTS.md strategy/control commands, Census tests/dry-run, Docker contracts/image isolation, deploy contract/helper, and `git diff --check`. Run a new strict hosted smoke and assert exact stopped/cancelled states, complete finalization marker, ordered Docker lifecycle, per-runtime Go/Python `ok`, and combined report inclusion.

- [ ] **Step 3: Prove Census session-stop on an isolated temporary run**

Create a separate coverage run label and hosted runtime so testing finalization does not terminate the user's active manual run. Invoke the actual `session-stop` finalization path, verify only that run's container is stopped, its marker becomes complete, its per-runtime and combined reports are `ok`, and no other labeled runtime is touched. Reconcile/remove the isolated runtime afterward through the existing control-panel lifecycle.

- [ ] **Step 4: Request sequential final reviews**

First run a complete requirements/spec review over all unpushed packages plus non-Git Census files. Fix every Critical/Important and repeat it until approved. Then run a separate code-quality/security/concurrency review and fix every Critical/Important. Minors are recorded explicitly.

- [ ] **Step 5: Fresh final gate and remote push**

Re-run affected tests after the last review change, verify three clean worktrees and live services/CDP, then push the named branch normally (never force) in all three Git repositories. Record remote refs, exact commit IDs, image ID, run/runtime/report paths, test counts, non-Git checksums, and accepted environment-only limits.
