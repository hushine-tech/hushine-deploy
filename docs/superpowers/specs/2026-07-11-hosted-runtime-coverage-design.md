# Hosted Runtime Coverage Design

**Date:** 2026-07-11

**Status:** Approved; implementation contract amended through 2026-07-13

## Goal

Provide a repeatable development/test capability that measures both the Go
runtime-agent and its Python session workers inside hosted runtime containers.
Coverage must survive worker restart, runtime deletion, control-panel cleanup,
and the end of a manual census session. Normal runtime images and production
behavior remain unchanged unless coverage is explicitly enabled.

## Scope

This change covers hosted runtimes provisioned by control-panel-service's
Docker provisioner. It includes:

- a dedicated coverage image target in strategy-service;
- typed, opt-in control-panel coverage configuration;
- per-runtime host bind mounts for durable Go and Python coverage files;
- bounded graceful shutdown for workers and coverage containers;
- coverage finalization and merge/report tooling;
- contract, unit, and real-container smoke tests.

Bare and self-hosted runtime coverage are not automatically provisioned by
control-panel in this change. They may use the same coverage image and output
layout manually later. No arbitrary runtime environment forwarding is restored.

## Alternatives Considered

### A. Dedicated coverage image and typed Docker support — selected

Build a separate instrumented image and let the existing Docker provisioner
add only the explicitly modeled coverage image, mount, environment, and labels.
This preserves normal-image behavior and provides durable output.

### B. Replace the local `executor-dev` image

This is simpler initially, but it makes it unclear whether a local image is
instrumented, adds overhead outside coverage sessions, and makes results hard
to reproduce.

### C. Copy coverage data out with `docker cp`

This avoids provisioner changes but loses data when containers are removed or
crash before collection. It cannot reliably cover automated cleanup paths.

## Configuration Contract

Coverage is disabled by default. It is enabled only when both of these
environment variables are set correctly:

```text
RUNTIME_COVERAGE_ENABLED=true
RUNTIME_COVERAGE_OUTPUT_DIR=/absolute/host/path
```

An optional image override is supported:

```text
RUNTIME_COVERAGE_IMAGE=hushine/strategy-runtime:executor-coverage
```

The default coverage image is
`hushine/strategy-runtime:executor-coverage`. The equivalent typed YAML lives
under `provisioning.docker.coverage`:

```yaml
provisioning:
  docker:
    coverage:
      enabled: false
      image: "hushine/strategy-runtime:executor-coverage"
      output_dir: ""
      stop_timeout_seconds: 10
```

When enabled, `output_dir` must be absolute and must exist or be creatable by
control-panel. Configuration is validated again after environment overrides.
Coverage settings never pass through the rejected legacy `runtime_env` map.

## Image Design

The existing `executor` and `default` targets remain unchanged. A new
`executor-coverage` target contains:

- runtime-agent built with
  `go build -cover -covermode=atomic -coverpkg=./...`;
- `coverage.py` installed only in the coverage image;
- an explicit Python coverage configuration scoped to platform code under
  `strategy_service`, excluding user strategy source from the platform report;
- the same runtime-agent command, network contract, credentials, and Python
  environment as the normal executor image.

Atomic Go counters are required because runtime-agent is concurrent and the
runtime coverage API may snapshot counters during shutdown.

The build script gains an explicit coverage mode/tag. It does not retag the
coverage image as `executor-dev`, `executor`, `dev`, or another normal image.

## Provisioning and Output Layout

For runtime `<runtime_id>`, control-panel creates and mounts:

```text
<output_dir>/runtimes/<runtime_id>/
├── finalization.json
├── go/
├── python/
└── coverage-manifest.json
```

The container sees the runtime root at `/coverage`. Docker arguments include:

```text
--mount type=bind,src=<runtime-root>,dst=/coverage
-e GOCOVERDIR=/coverage/go
-e HUSHINE_RUNTIME_COVERAGE_DIR=/coverage
```

The coverage image is used as the final Docker argument. The provisioner also
adds platform-owned labels identifying coverage mode and the census run. The
runtime identifier is used only as a validated directory component; path
traversal and symlink escape must fail closed.

`--mount` is preferred over `-v` so an invalid host path does not silently
become a Docker-managed directory. control-panel creates the expected runtime,
Go, and Python directories before invoking Docker.

Each Python worker writes parallel data files beneath `python/`, so multiple
sessions and worker restarts cannot overwrite each other. Go meta/counter files
accumulate beneath `go/` and are merged at report time.

The reusable smoke keeps its derived evidence outside that container-writable
mount. Its host-only layout is:

```text
<output_dir>/smoke-reports/<runtime_id>/
├── python-input/
├── python-data-validation-output.txt
├── docker-events.jsonl
├── go-merged/
├── go.cover.out
├── go-functions.txt
├── python-report.txt
└── python-coverage.json
```

Before provisioning a runtime, the smoke builds its control-panel action helper
into a fresh mode-`0700` temporary directory. The later 30-second session-stop
and 45-second runtime/action bounds therefore measure the RPC work rather than
an unbounded `go run` compilation. The EXIT trap first discovers and stops any
running sessions and only then calls `EndRuntime`, which also reconciles a
session whose RunStrategy response was lost.

After the runtime has stopped, the staging helper recursively rejects every
symlink and special file anywhere in the runtime mount. It copies each raw
Python shard into `smoke-reports/<runtime_id>/python-input` using a no-follow
open plus stable pre/open/post file-identity checks. Each staged copy must then pass
the locked `uv run --frozen --extra coverage coverage debug data` validation
before combine/report can use it. Go and Python reports plus the Docker event
evidence are written only beneath the host-only smoke report root, never into
the bind mount that the runtime container could write.

## Runtime and Worker Lifecycle

The current worker environment is intentionally rebuilt from a safe allowlist,
so coverage variables are not inherited implicitly. Coverage mode is represented
as a trusted WorkerManager configuration. Workers start with the equivalent of:

```text
python -m coverage run --parallel-mode \
  --data-file=/coverage/python/.coverage \
  --source=strategy_service \
  -m strategy_service.session_worker_entry
```

SIGTERM handling is enabled by the coverage image's `.coveragerc`, where
`sigterm = true`; it is not a `coverage run` command-line option.

Successful `StopStrategy` and one-shot Preview responses use coverage-flush
barriers. After a worker returns `StopStrategy(stopped=true)`, the Agent does not
forward that response until the corresponding worker has completed natural
process exit and managed session-root cleanup. A one-shot `PreviewRunStrategy`
with `ok=true` uses the same natural managed-cleanup barrier before returning.
Neither wait sends a process signal, and each is bounded by the request/frame's
remaining timeout.

Every validated terminal `FinalStatus` marks its worker `draining` before
indicator finalization and before any terminal or recoverable platform state is
published. `StopAll` gives a draining worker a bounded natural-exit and managed-
cleanup window. If that window expires, one per-worker stop owner sends TERM;
if the worker still does not finish, that owner force-kills it. The same owner
completes process reap and managed cleanup in either case. Concurrent followers
only await the shared result and never signal the worker again. Under the
production shared deadline, after natural draining expires the TERM phase is
capped at no more than half of the remaining shared time so force, reap, and
managed cleanup retain a budget. The shared runtime-agent shutdown deadline
remains 10 seconds and does not extend the control-panel/Docker 10-second
coverage stop grace. Deadline-free draining keeps the configured TERM timeout,
and non-draining behavior is unchanged.

For other owned stop paths, including worker replacement, the bounded fallback
sequence is:

1. request termination with SIGTERM on POSIX;
2. wait for the configured bounded timeout;
3. force-kill only if the worker does not exit;
4. wait for process cleanup before replacing in-memory ownership.

The runtime-agent closes worker admission before shutdown, drains starts already
admitted within the shared deadline, and prevents a timed-out start from
launching later. It stops unique worker generations concurrently; aliases for
one generation are stopped once, while PID reuse cannot merge two generations.
Worker shutdown happens before the worker IPC gRPC server is gracefully stopped.

An instrumented boot atomically replaces any prior marker with
`finalization.json` in `running` state as soon as the trusted coverage root and
runtime identity are known. On SIGINT/SIGTERM the order is:

1. close admission and stop/reap workers within one shared bound;
2. snapshot Go counters into `go/`;
3. atomically publish the final marker;
4. gracefully stop worker IPC, with a bounded forced fallback.

The schema-1 marker contains only these fields:

```json
{
  "schema_version": 1,
  "runtime_id": "rt-123",
  "boot_id": "opaque-random-id",
  "state": "running|complete|incomplete",
  "worker_shutdown": "pending|ok|error|forced",
  "forced_workers": 0,
  "go_snapshot": "pending|ok|error",
  "completed_at": "RFC3339 timestamp, final states only"
}
```

`complete` requires worker shutdown `ok`, zero forced workers, and Go snapshot
`ok`. Raw errors, credentials, addresses, and strategy content are never written
to this marker. A normal uninstrumented image creates no marker or snapshot.

## Container Cleanup

Normal Docker provisioning remains unchanged when coverage is disabled.

Cleanup behavior is selected from the actual container's persisted coverage
label, not from the current process configuration. For a coverage container,
deprovisioning performs:

1. `docker stop --time <configured-seconds> <handle>`;
2. bounded worker and runtime-agent shutdown, allowing both languages to flush;
3. `docker rm -f <handle>` as idempotent cleanup.

Registration timeout, explicit runtime deletion, stale-runtime reaping, and
partial startup cleanup all retain existing service semantics. A stop failure
does not prevent forced removal, and both failures are reported without exposing
credentials.

At census finalization, Census selects only containers carrying both
`hushine.runtime.coverage=true` and the active run's exact
`hushine.runtime.coverage_run_id`. It stops them with the configured bound and
waits briefly for their marker to leave `running`; it does not remove them.
control-panel remains the sole removal owner. Containers from other runs are
never touched.

## Reporting

Go runtime output is converted using:

```text
go tool covdata merge
go tool covdata textfmt
go tool cover -func
```

Python output is converted using:

```text
COVERAGE_FILE=<raw .coverage* shard> uv run --frozen --extra coverage coverage debug data
uv run --frozen --extra coverage coverage combine --keep
uv run --frozen --extra coverage coverage report --keep-combined
uv run --frozen --extra coverage coverage json --keep-combined
```

Before combine or report, every raw `.coverage*` shard is independently
validated with locked `uv run --frozen --extra coverage coverage debug data`.
A zero exit from `coverage combine` is not sufficient because coverage.py can
warn and skip a malformed shard. One invalid shard makes the runtime's Python
status `error` and its per-runtime overall status `error`, leaves the broader
coverage result incomplete, excludes that runtime from combined reports, and
retains the raw shard and validation evidence. The strict reusable smoke applies
the same per-shard gate with the same locked tooling.

The census run records `coverage-manifest.json` per runtime and preserves the
ordered `hosted-runtime-coverage-summary.json`. Missing, running, malformed,
incomplete, or forced finalization evidence makes the runtime `incomplete` even
when mergeable files exist.

Only runtimes whose finalization, Go, and Python statuses are all `ok` are
included in cross-runtime reports under `runtime-agent/combined/`. The adjacent
`hosted-runtime-coverage-combined-summary.json` lists included and excluded
runtime IDs with safe reasons. Raw per-runtime Go and Python shards are retained.

## Error Handling and Safety

- Coverage remains disabled unless explicitly enabled.
- Enabled coverage with a missing/relative output path fails startup.
- Normal images do not contain `coverage.py` and are not Go-instrumented.
- No database, Kafka, order, portfolio, account, or arbitrary environment
  addresses are forwarded into hosted runtimes.
- Credential/TLS environment behavior stays unchanged and diagnostics remain
  redacted.
- A container or process that reaches SIGKILL is incomplete: missing evidence,
  a forced worker count, or a failed snapshot can never be reported as `ok`.
- Coverage directories are never deleted automatically with the container.

## Verification

### Contract and unit tests

- production Docker target remains uninstrumented;
- coverage target contains Go instrumentation and Python coverage;
- default configuration is disabled;
- environment overrides are applied and post-override validation runs;
- missing or relative output directories fail closed;
- legacy `runtime_env` remains rejected;
- disabled provisioner arguments are byte-for-byte behavior-compatible;
- enabled arguments contain exactly one mount, owned coverage environment, the
  coverage labels, and the coverage image;
- runtime IDs cannot escape the output root;
- coverage deprovision performs stop then remove;
- TERM-first worker shutdown and force-kill fallback are both tested;
- shutdown deduplicates worker aliases and remains bounded.

### Integration and smoke tests

- build both normal and coverage images;
- confirm normal image lacks coverage instrumentation;
- start a coverage runtime with a temporary bind mount;
- run a real hosted session that creates a Python worker;
- assert EndRuntime rejects the active session with `AlreadyExists`;
- stop the session with `STOP_ACTION_STOP_ONLY`, require exact `stopped` state,
  then run a second session with a different ID to prove worker recreation;
- require Preview `profile=backtest`, `supported=true`, `ok=true`, zero failures,
  and exactly one declared input;
- stop the second session, then EndRuntime and require an exact complete schema-1
  marker plus ordered Docker `kill(signal=15) -> die(exitCode=0) -> destroy`;
- independently validate every raw Python shard, then verify valid Go and Python
  reports can be generated into the host-only
  `smoke-reports/<runtime_id>/` tree;
- require the stopped runtime mount to contain only real directories and regular
  files, stage Python inputs through no-follow identity-stable copies, and keep
  Python validation, Go/Python reports, and Docker event evidence outside the
  container-writable bind mount;
- prove EXIT cleanup stops running sessions before `EndRuntime`, with the smoke
  action helper precompiled before provisioning so compilation is outside the
  30/45-second action bounds;
- verify the complete hosted path still registers and communicates solely over
  RuntimeChannel.

### Operational status and Task 13 gates

The previous hosted smoke exposed a malformed Python shard that `coverage
combine` warned about and skipped while still exiting zero. That observation
drove the lifecycle flush barriers and fail-closed shard validation above; it is
evidence of the prior defect, not a successful current acceptance run.

Task 13 still requires a fresh-image hosted smoke against the corrected
revisions and an isolated real Census `session-stop` that verifies the current-
run two-label boundary and resulting per-runtime and combined reports. Neither
gate is claimed as passed here.
