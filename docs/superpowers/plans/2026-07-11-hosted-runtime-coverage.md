# Hosted Runtime Coverage Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a reusable, opt-in hosted-runtime coverage path that persists Go runtime-agent and Python worker execution data into the active census run without changing normal runtime images or production behavior.

**Architecture:** A dedicated `executor-coverage` image instruments the Go agent and wraps isolated Python workers with coverage.py. control-panel-service owns a typed coverage configuration, creates one safe bind-mounted output tree per runtime, chooses the coverage image, and gracefully stops coverage containers before removal. Census finalization merges the mounted Go/Python data and reports missing subjects explicitly.

**Tech Stack:** Go 1.26 runtime coverage, Python 3.13, coverage.py 7.x, Docker multi-stage builds, Go unit tests, pytest, Bash smoke tests, Code Census Python tooling.

## Global Constraints

- Coverage is disabled unless `RUNTIME_COVERAGE_ENABLED=true` and `RUNTIME_COVERAGE_OUTPUT_DIR` is an absolute host path.
- The default coverage image is `hushine/strategy-runtime:executor-coverage`; `RUNTIME_COVERAGE_IMAGE` may override it.
- Existing `executor` and `default` images remain uninstrumented and do not contain coverage.py.
- Hosted runtimes continue to receive only RuntimeChannel identity, credential, TLS, and explicit coverage settings; legacy `runtime_env` remains rejected.
- Runtime coverage output is retained after worker restart and container deletion.
- Shutdown is bounded: TERM/stop first, forced kill/removal only after timeout.
- Runtime IDs may never escape the configured coverage root.
- All implementation uses the existing `cleanup/medium-baseline-20260710` worktree and preserves unrelated dirty work.

## Current Contract Correction (2026-07-12)

This is a dated implementation plan. The following contract supersedes earlier
intermediate snippets below where they differ:

- runtime-agent writes a fresh schema-1 `finalization.json` in `running` state
  immediately after the trusted coverage root and runtime identity are known;
- shutdown order is worker admission close/drain, bounded concurrent worker
  stop/reap, Go snapshot, final marker, then bounded worker-IPC shutdown;
- `complete` requires worker shutdown `ok`, `forced_workers=0`, and Go snapshot
  `ok`; missing/running/malformed/incomplete evidence is never reported `ok`;
- control-panel decides stop-first cleanup from the actual container label and
  keeps inspect/stop/remove failures visible within its declared cleanup bound;
- Census stops only coverage containers with the active run's exact two labels,
  never removes them, writes a per-runtime manifest, and combines only runtimes
  whose finalization, Go, and Python statuses are all `ok`;
- combined output lives under `coverage/runtime-agent/combined/`, with inclusion
  and exclusion reasons in
  `hosted-runtime-coverage-combined-summary.json`;
- the strict smoke requires exact backtest Preview semantics, a complete marker,
  and ordered `kill(15) -> die(0) -> destroy` lifecycle evidence.

---

## File Structure

### strategy-service

- `internal/runtimeagent/worker_manager.go`: bounded TERM-first worker shutdown and StopAll lifecycle.
- `internal/runtimeagent/worker_signal_unix.go`: POSIX SIGTERM implementation.
- `internal/runtimeagent/worker_signal_windows.go`: Windows-compatible forced-stop fallback.
- `internal/runtimeagent/coverage.go`: trusted coverage configuration and Go counter snapshot seam.
- `cmd/runtime-agent/main.go`: construct coverage-aware WorkerManager and order agent shutdown.
- `Dockerfile`: isolated coverage builder/image targets.
- `pyproject.toml`, `uv.lock`, `.coveragerc`: coverage-only Python dependency and source rules.
- `scripts/build_strategy_runtime.sh`: explicit coverage image build mode.
- Existing Go/Python Docker contract tests: regression and coverage-target assertions.

### control-panel-service

- `internal/config/config.go`: typed Docker coverage configuration, environment overrides, and validation.
- `internal/config/config_test.go`: default/YAML/env/validation tests.
- `internal/provision/docker.go`: safe output paths, bind mount, coverage labels/image, and stop-then-remove cleanup.
- `internal/provision/docker_test.go`: exact Docker command and cleanup tests.
- `cmd/control-panel-service/main.go`: post-environment validation and effective-mode logging.
- `config.yaml`: documented disabled coverage block.

### census/orchestration

- `scripts/audit/census/census/coverage.py`: discover and merge hosted runtime Go/Python output.
- `scripts/audit/census/config.yaml`: model runtime-agent as a Go subject instead of the removed Python runtime CLI.
- `scripts/audit/census/tests/test_coverage.py`: merge and missing-output tests.
- `scripts/audit/census/start_instrumented_stack.sh`: pass the active run output to control-panel.
- `hushine-deploy/scripts/smoke_hosted_runtime_coverage.sh`: real container stop-and-report smoke.

---

### Task 1: Make worker shutdown bounded and coverage-safe

**Files:**
- Modify: `strategy-service/internal/runtimeagent/worker_manager.go`
- Create: `strategy-service/internal/runtimeagent/worker_signal_unix.go`
- Create: `strategy-service/internal/runtimeagent/worker_signal_windows.go`
- Modify: `strategy-service/internal/runtimeagent/worker_manager_test.go`

**Interfaces:**
- Produces: `func (m *WorkerManager) StopAll(ctx context.Context, timeout time.Duration) error`
- Produces: `func requestWorkerStop(process *os.Process) (forced bool, err error)`, selected by platform build tags.
- Preserves: `StopSessionWorker(ctx, sessionID, timeout)` semantics, adding TERM-first behavior and force-kill fallback.

- [ ] **Step 1: Add failing lifecycle tests**

Add tests that start a helper child which records SIGTERM before exiting, a helper which ignores SIGTERM, and two registry aliases for one PID. Assert that `StopSessionWorker` observes graceful exit, the ignoring helper is killed after the timeout, and `StopAll` stops an aliased process once.

```go
func TestStopSessionWorkerRequestsGracefulStopBeforeKill(t *testing.T) {
    manager, worker, marker := startSignalAwareWorker(t)
    err := manager.StopSessionWorker(context.Background(), worker.SessionID, 2*time.Second)
    if err != nil { t.Fatal(err) }
    if _, err := os.Stat(marker); err != nil { t.Fatalf("SIGTERM marker: %v", err) }
}

func TestStopAllDeduplicatesAliasedWorkers(t *testing.T) {
    manager, worker, counter := startCountingWorker(t)
    if err := manager.AliasWorkerSession(worker.SessionID, "replacement-session"); err != nil { t.Fatal(err) }
    if err := manager.StopAll(context.Background(), 2*time.Second); err != nil { t.Fatal(err) }
    if got := readStopCount(t, counter); got != 1 { t.Fatalf("stop count=%d want 1", got) }
}
```

- [ ] **Step 2: Verify the tests fail**

Run: `go test ./internal/runtimeagent -run 'TestStop(SessionWorkerRequestsGracefulStopBeforeKill|AllDeduplicatesAliasedWorkers)' -count=1`

Expected: FAIL because immediate `Process.Kill` prevents the marker and `StopAll` does not exist.

- [ ] **Step 3: Add platform stop helpers and minimal shutdown implementation**

POSIX helper:

```go
//go:build !windows
func requestWorkerStop(process *os.Process) (bool, error) {
    return false, process.Signal(syscall.SIGTERM)
}
```

Windows helper:

```go
//go:build windows
func requestWorkerStop(process *os.Process) (bool, error) {
    return true, process.Kill()
}
```

Change `StopSessionWorker` to request stop, wait up to the supplied timeout,
then call `Kill` and wait only within the remaining bound. Implement `StopAll`
by taking a snapshot of active worker-generation pointers, deduplicating aliases
by pointer, stopping unique generations concurrently on one shared context, and
joining errors with `errors.Join`. Numeric PID is never a lifetime identity.

- [ ] **Step 4: Run focused and cross-platform tests**

Run:

```bash
go test ./internal/runtimeagent -count=1
GOOS=windows GOARCH=amd64 go test -c ./internal/runtimeagent -o /tmp/runtimeagent-windows.test.exe
```

Expected: PASS; Windows package compiles without POSIX symbols.

- [ ] **Step 5: Commit strategy-service**

```bash
git add internal/runtimeagent/worker_manager.go internal/runtimeagent/worker_manager_test.go internal/runtimeagent/worker_signal_unix.go internal/runtimeagent/worker_signal_windows.go
git commit -m "fix: gracefully stop runtime workers"
```

### Task 2: Add trusted runtime-agent coverage and bounded agent shutdown

**Files:**
- Create: `strategy-service/internal/runtimeagent/coverage.go`
- Create: `strategy-service/internal/runtimeagent/coverage_test.go`
- Modify: `strategy-service/cmd/runtime-agent/main.go`
- Modify: `strategy-service/cmd/runtime-agent/main_test.go`

**Interfaces:**
- Produces: `CoverageConfig{RootDir string}` and `PythonArgsPrefix() []string`.
- Produces: `WriteGoCoverageSnapshot(dir string) error`, wrapping `runtime/coverage.WriteCountersDir`.
- Consumes: `WorkerManager.StopAll` from Task 1.

- [ ] **Step 1: Add failing coverage configuration tests**

```go
func TestCoverageConfigPythonArgs(t *testing.T) {
    cfg := runtimeagent.CoverageConfig{RootDir: "/coverage"}
    got := cfg.PythonArgsPrefix()
    want := []string{"-m", "coverage", "run", "--parallel-mode", "--data-file=/coverage/python/.coverage", "--source=strategy_service"}
    if diff := cmp.Diff(want, got); diff != "" { t.Fatal(diff) }
}

func TestCoverageConfigDisabledHasNoPythonWrapper(t *testing.T) {
    if got := (runtimeagent.CoverageConfig{}).PythonArgsPrefix(); len(got) != 0 { t.Fatalf("args=%v", got) }
}
```

Add a command-level test that cancels the runtime context with an active fake
worker and asserts workers stop before the worker gRPC server's bounded stop.

- [ ] **Step 2: Verify the tests fail**

Run: `go test ./internal/runtimeagent ./cmd/runtime-agent -run 'Coverage|Shutdown' -count=1`

Expected: FAIL because `CoverageConfig` and ordered shutdown do not exist.

- [ ] **Step 3: Implement trusted coverage configuration**

Read `HUSHINE_RUNTIME_COVERAGE_DIR` once in `main.go`. When non-empty, require
an absolute cleaned path, create `go` and `python` children, append
`CoverageConfig.PythonArgsPrefix()` before the worker module, and use the Go
child for snapshots. Do not pass arbitrary inherited coverage variables into
the worker environment. SIGTERM handling comes from the coverage image's
`.coveragerc` (`sigterm = true`); `coverage run` has no `--sigterm` option.

On context cancellation, the effective implementation order is:

```go
shutdownCtx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
defer cancel()
workerErr := workerManager.StopAll(shutdownCtx, 5*time.Second)
snapshotErr := runtimeagent.WriteGoCoverageSnapshot(filepath.Join(coverageRoot, "go"))
// Atomically write complete only when workerErr == nil, forced count is zero,
// and snapshotErr == nil; otherwise write incomplete.
```

Stop workers before bounded gRPC graceful shutdown; call `grpcServer.Stop()` if
the grace deadline expires.

- [ ] **Step 4: Run focused tests and vet**

Run:

```bash
go test ./internal/runtimeagent ./cmd/runtime-agent -count=1
go vet ./internal/runtimeagent ./cmd/runtime-agent
```

Expected: PASS.

- [ ] **Step 5: Commit strategy-service**

```bash
git add internal/runtimeagent/coverage.go internal/runtimeagent/coverage_test.go cmd/runtime-agent/main.go cmd/runtime-agent/main_test.go
git commit -m "feat: persist runtime agent coverage"
```

### Task 3: Build a separate coverage runtime image

**Files:**
- Modify: `strategy-service/Dockerfile`
- Modify: `strategy-service/pyproject.toml`
- Modify: `strategy-service/uv.lock`
- Create: `strategy-service/.coveragerc`
- Modify: `strategy-service/scripts/build_strategy_runtime.sh`
- Modify: `strategy-service/tests/test_strategy_runtime_dockerfile.py`

**Interfaces:**
- Produces image: `hushine/strategy-runtime:executor-coverage`.
- Preserves images: `executor`, `executor-dev`, `dev`, and default version tags.

- [ ] **Step 1: Add failing Dockerfile/build contract tests**

Assert the production target still copies the plain binary, while the coverage
target uses an atomic cover build, installs the `coverage` extra, exposes no
normal tags, and uses the same CMD.

```python
def test_coverage_target_is_isolated():
    text = DOCKERFILE.read_text()
    assert "go build -cover -covermode=atomic -coverpkg=./..." in text
    assert "FROM runtime-base AS executor-coverage" in text
    assert "uv sync --frozen --no-dev --extra coverage" in text
    assert 'CMD ["./bin/runtime-agent", "--config", "config.yaml"]' in text
```

- [ ] **Step 2: Verify the tests fail**

Run: `uv run --extra test pytest tests/test_strategy_runtime_dockerfile.py -q`

Expected: FAIL because no coverage target exists.

- [ ] **Step 3: Add the coverage extra and image target**

Add a `coverage` optional dependency constrained to coverage.py 7.x, update the
lock with `uv lock`, create `.coveragerc` with `source = strategy_service`,
`parallel = true`, and `sigterm = true`, and create a coverage-only Go builder
and executor stage. Extend the build script so:

```bash
./scripts/build_strategy_runtime.sh --coverage
```

builds only `--target executor-coverage` and tags only
`hushine/strategy-runtime:executor-coverage`.

- [ ] **Step 4: Run contracts and build both images**

Run:

```bash
uv run --extra test pytest tests/test_strategy_runtime_dockerfile.py -q
./scripts/build_strategy_runtime.sh --coverage
docker image inspect hushine/strategy-runtime:executor-coverage
```

Expected: tests PASS and the coverage image exists. Verify the normal target
Dockerfile contract remains uninstrumented.

- [ ] **Step 5: Commit strategy-service**

```bash
git add Dockerfile pyproject.toml uv.lock .coveragerc scripts/build_strategy_runtime.sh tests/test_strategy_runtime_dockerfile.py
git commit -m "feat: build coverage runtime image"
```

### Task 4: Add typed control-panel coverage configuration

**Files:**
- Modify: `control-panel-service/internal/config/config.go`
- Modify: `control-panel-service/internal/config/config_test.go`
- Modify: `control-panel-service/cmd/control-panel-service/main.go`
- Modify: `control-panel-service/config.yaml`

**Interfaces:**
- Produces: `DockerCoverageConfig{Enabled bool, Image string, OutputDir string, StopTimeoutSeconds int}`.
- Produces: `func (c ProvisioningConfig) ValidateRuntimeIsolation() error` covering post-env coverage constraints.

- [ ] **Step 1: Add failing default, YAML, environment, and validation tests**

Cover disabled defaults, all three approved environment variables, relative
path rejection, missing output rejection, stop timeout validation, and continued
rejection of non-empty `runtime_env`.

```go
func TestCoverageEnvOverrides(t *testing.T) {
    t.Setenv("RUNTIME_COVERAGE_ENABLED", "true")
    t.Setenv("RUNTIME_COVERAGE_OUTPUT_DIR", "/tmp/census/run-1/coverage/runtime-agent")
    t.Setenv("RUNTIME_COVERAGE_IMAGE", "hushine/strategy-runtime:test-cover")
    cfg := Default()
    cfg.ApplyEnvOverrides()
    if err := cfg.Provisioning.ValidateRuntimeIsolation(); err != nil { t.Fatal(err) }
    if !cfg.Provisioning.Docker.Coverage.Enabled { t.Fatal("coverage disabled") }
}
```

- [ ] **Step 2: Verify tests fail**

Run: `go test ./internal/config -run 'Coverage|RuntimeIsolation' -count=1`

Expected: FAIL because the typed block and overrides do not exist.

- [ ] **Step 3: Implement configuration and post-env validation**

Add YAML key `provisioning.docker.coverage`; default image
`hushine/strategy-runtime:executor-coverage` and stop timeout 10 seconds.
Parse the approved environment variables. After `cfg.ApplyEnvOverrides()` in
`main.go`, call `cfg.Provisioning.ValidateRuntimeIsolation()` and fail before
logger/provisioner initialization when invalid.

- [ ] **Step 4: Run config and command tests**

Run: `go test ./internal/config ./cmd/control-panel-service -count=1`

Expected: PASS.

- [ ] **Step 5: Commit control-panel-service**

```bash
git add internal/config/config.go internal/config/config_test.go cmd/control-panel-service/main.go config.yaml
git commit -m "feat: configure hosted runtime coverage"
```

### Task 5: Mount durable coverage output and stop containers gracefully

**Files:**
- Modify: `control-panel-service/internal/provision/docker.go`
- Modify: `control-panel-service/internal/provision/docker_test.go`

**Interfaces:**
- Consumes: `DockerCoverageConfig` from Task 4.
- Produces per-runtime directory: `${RUNTIME_COVERAGE_OUTPUT_DIR}/runtimes/rt-123/{go,python}` for runtime `rt-123`.
- Preserves: `Provisioner.Provision` and `Provisioner.Deprovision` interfaces.

- [ ] **Step 1: Add failing exact-command and cleanup tests**

Assert disabled mode retains current arguments. In enabled mode assert one
bind mount, `GOCOVERDIR`, `HUSHINE_RUNTIME_COVERAGE_DIR`, coverage labels, and
coverage image. Add malicious runtime IDs (`../x`, separators, absolute paths)
and verify provisioning fails before Docker. Assert deprovision invokes:

```text
docker stop --time 10 "$container_id"
docker rm -f "$container_id"
```

and still removes when stop fails.

- [ ] **Step 2: Verify tests fail**

Run: `go test ./internal/provision -run 'Coverage|Deprovision' -count=1`

Expected: FAIL because coverage arguments and stop-first cleanup do not exist.

- [ ] **Step 3: Implement safe output creation and Docker arguments**

Validate the runtime ID as one path component, build the runtime directory with
`filepath.Join`, confirm `filepath.Rel` does not begin with `..`, and create
runtime/Go/Python directories with `0700`. Add a single `--mount` argument and
only the two platform-owned coverage environment variables. Choose the coverage
image only when enabled.

In coverage mode, `Deprovision` calls `docker stop` with the configured timeout,
then always calls `docker rm -f`; join errors only when removal also fails.

- [ ] **Step 4: Run provisioner and full control-panel verification**

Run:

```bash
go test ./internal/provision -count=1
go test ./...
go vet ./...
```

Expected: PASS.

- [ ] **Step 5: Commit control-panel-service**

```bash
git add internal/provision/docker.go internal/provision/docker_test.go
git commit -m "feat: persist hosted runtime coverage"
```

### Task 6: Integrate hosted runtime output into Code Census

**Files:**
- Modify: `scripts/audit/census/census/coverage.py`
- Modify: `scripts/audit/census/config.yaml`
- Create or modify: `scripts/audit/census/tests/test_coverage.py`
- Modify: `scripts/audit/census/start_instrumented_stack.sh`

**Interfaces:**
- Consumes: `${RUN_DIR}/coverage/runtime-agent/runtimes/rt-123/{go,python}` for each discovered runtime directory.
- Produces: per-runtime `coverage-manifest.json`, Go/Python reports, ordered
  `hosted-runtime-coverage-summary.json`, `combined/` reports, and
  `hosted-runtime-coverage-combined-summary.json`.

- [ ] **Step 1: Add failing merge/missing-output tests**

Use temporary fake runtime directories and injectable command runners. Assert
valid subjects run Go covdata and Python combine commands, while empty/missing
language directories produce explicit `status: missing` entries.

```python
def test_hosted_runtime_missing_python_is_reported(tmp_path):
    runtime = make_runtime_output(tmp_path, runtime_id="rt-1", go=True, python=False)
    result = collect_hosted_runtime_coverage(runtime, run_command=fake_success)
    assert result["go"]["status"] == "ok"
    assert result["python"]["status"] == "missing"
```

- [ ] **Step 2: Verify tests fail**

Run: `python3 -m unittest scripts.audit.census.tests.test_coverage -v`

Expected: FAIL because hosted runtime discovery/merge does not exist.

- [ ] **Step 3: Implement discovery, merge, and startup propagation**

Model runtime-agent as a Go subject in census config. Add deterministic discovery,
schema-1 finalization gating, active-run container stop, per-runtime manifests,
and language-specific/per-run combined collectors. Update the instrumented stack
launcher to set:

```text
RUNTIME_COVERAGE_ENABLED=true
RUNTIME_COVERAGE_OUTPUT_DIR="${RUN_DIR}/coverage/runtime-agent"
RUNTIME_COVERAGE_IMAGE=hushine/strategy-runtime:executor-coverage
```

when starting control-panel. Do not start a standalone Python strategy-service
process.

- [ ] **Step 4: Run census tests and dry-run the stack plan**

Run:

```bash
python3 -m unittest discover -s scripts/audit/census/tests -v
scripts/audit/census/start_instrumented_stack.sh --dry-run manual-coverage-20260711-230823
```

Expected: tests PASS; plan includes hosted coverage variables and no standalone
strategy-service runtime.

- [ ] **Step 5: Commit tracked census changes where owned and record root changes**

Stage only files owned by the repository that contains them. If root
orchestration files are intentionally outside Git, record their checksums and
paths in the smoke report rather than staging unrelated repositories.

### Task 7: Build, restart the current sampled stack, and run a real smoke

**Files:**
- Create: `hushine-deploy/scripts/smoke_hosted_runtime_coverage.sh`
- Create: `hushine-deploy/scripts/smoke_hosted_runtime_coverage.go`
- Create: `hushine-deploy/scripts/smoke_hosted_runtime_coverage_test.go`
- Create: `hushine-deploy/scripts/smoke_hosted_runtime_coverage.test.sh`
- Create: `hushine-deploy/.superpowers/sdd/hosted-runtime-coverage-smoke.md`

**Interfaces:**
- Consumes image and configuration from Tasks 3–6.
- Produces evidence that a stopped hosted runtime yields mergeable Go and Python coverage.

- [ ] **Step 1: Add the smoke script with strict prerequisites**

The script must require an absolute output directory, verify the coverage image,
create a unique runtime output directory, start a coverage container with a
real RuntimeChannel credential supplied by the existing smoke harness, require
a strict Preview result (`profile=backtest`, supported/ok, no failures, exactly
one declared input), run an active worker, prove EndRuntime rejects that
active session with `AlreadyExists`, stop it with `STOP_ACTION_STOP_ONLY` and
require exact `stopped` state, then run and stop a second distinct session to
prove worker recreation. End the runtime through control-panel, require exact
`cancelled` state, exact complete schema-1 finalization, and ordered Docker
SIGTERM, exit 0, and destroy events before executing Go/Python report commands.
It must trap ownership-checked cleanup and redact credentials.

- [ ] **Step 2: Run repository-level verification before Docker**

Run:

```bash
cd strategy-service && go test ./... && go vet ./... && uv run --extra test pytest tests -q
cd ../control-panel-service && go test ./... && go vet ./...
```

Expected: all commands exit 0.

- [ ] **Step 3: Build the coverage image and restart only control-panel with coverage enabled**

Use the active run:

```bash
./strategy-service/scripts/build_strategy_runtime.sh --coverage
RUNTIME_COVERAGE_ENABLED=true \
RUNTIME_COVERAGE_OUTPUT_DIR=/Users/xdy/Workplace/hushine-worktrees/medium-cleanup/census-runs/manual-coverage-20260711-230823/coverage/runtime-agent \
RUNTIME_COVERAGE_IMAGE=hushine/strategy-runtime:executor-coverage \
/Users/xdy/Workplace/hushine-worktrees/medium-cleanup/census-runs/manual-coverage-20260711-230823/coverage/control-panel-service/runtime/run-instrumented.sh \
  -config ./config.yaml
```

Expected: control-panel listens on 50054/50055/8082 and logs coverage mode with
the effective image/output root but no credentials.

- [ ] **Step 4: Run the real hosted coverage smoke**

Run:

```bash
hushine-deploy/scripts/smoke_hosted_runtime_coverage.sh \
  /Users/xdy/Workplace/hushine-worktrees/medium-cleanup/census-runs/manual-coverage-20260711-230823/coverage/runtime-agent
```

Expected: runtime registers through RuntimeChannel; strict Preview succeeds;
EndRuntime rejects the first active session; both `STOP_ACTION_STOP_ONLY`
requests persist exact `stopped` sessions; the second session has a new ID;
final runtime state is exactly `cancelled`; finalization is exactly complete;
the runtime container records ordered SIGTERM, exit 0, and destroy; Go `covdata textfmt` succeeds; Python `coverage
combine` succeeds; and Docker has no leftover smoke container.

- [ ] **Step 5: Verify the manual testing stack remains ready**

Check all application listeners, scraper process, frontend CDP collector, Docker
container labels, and output directories. Record commands, exit codes, image ID,
container ID, and generated report paths in the smoke report without secrets.

- [ ] **Step 6: Commit deploy tooling and report**

```bash
git add scripts/smoke_hosted_runtime_coverage.sh scripts/smoke_hosted_runtime_coverage.go scripts/smoke_hosted_runtime_coverage_test.go scripts/smoke_hosted_runtime_coverage.test.sh .superpowers/sdd/hosted-runtime-coverage-smoke.md
git commit -m "test: verify hosted runtime coverage"
```

### Task 8: Final review and branch handoff

**Files:**
- Review all files changed by Tasks 1–7.

**Interfaces:**
- Produces a verified multi-repository commit list and leaves the manual census running.

- [ ] **Step 1: Run final repository verification**

Run all commands from AGENTS.md for strategy-service and control-panel-service,
the census tests, Dockerfile contract tests, image inspection, and the hosted
coverage smoke again from clean processes.

- [ ] **Step 2: Inspect diffs and commits**

For each affected repository run `git status --short`, `git diff --check`, and
`git log -5 --oneline`. Confirm every owned change is committed and unrelated
work remains untouched.

- [ ] **Step 3: Request a two-stage Superpowers review**

First review requirements/spec compliance, then review code quality, shutdown
races, path containment, credential redaction, and test evidence. Fix all
Critical/Important findings with focused regressions.

- [ ] **Step 4: Re-run fresh verification and report**

Report exact commits, image ID, active run ID, service/collector status, Go and
Python report paths, tests executed, and any remaining environment-only limits.
Do not claim the runtime path is covered if either language report is missing.
