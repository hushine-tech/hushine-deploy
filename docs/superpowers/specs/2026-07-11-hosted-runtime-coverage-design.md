# Hosted Runtime Coverage Design

**Date:** 2026-07-11

**Status:** Approved for implementation

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
├── go/
└── python/
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

## Runtime and Worker Lifecycle

The current worker environment is intentionally rebuilt from a safe allowlist,
so coverage variables are not inherited implicitly. Coverage mode is represented
as a trusted WorkerManager configuration. Workers start with the equivalent of:

```text
python -m coverage run --parallel-mode --sigterm \
  --data-file=/coverage/python/.coverage \
  --source=strategy_service \
  -m strategy_service.session_worker_entry
```

Normal strategy completion follows the existing final-status acknowledgement
flow and exits normally. Worker restart changes from immediate kill to:

1. request termination with SIGTERM on POSIX;
2. wait for the configured bounded timeout;
3. force-kill only if the worker does not exit;
4. wait for process cleanup before replacing in-memory ownership.

The runtime-agent gains bounded shutdown of all unique active workers. Aliased
session IDs that refer to one process are stopped once. Worker shutdown happens
before the worker IPC gRPC server is gracefully stopped, preventing an active
Connect stream from blocking runtime-agent shutdown indefinitely.

When runtime-agent receives SIGINT or SIGTERM in an instrumented build, it
snapshots Go counters to `GOCOVERDIR` before shutdown. Calling the snapshot path
in a normal, uninstrumented image is disabled and has no effect.

## Container Cleanup

Normal Docker provisioning remains unchanged when coverage is disabled.

For coverage containers, deprovisioning performs:

1. `docker stop --time <configured-seconds> <handle>`;
2. bounded worker and runtime-agent shutdown, allowing both languages to flush;
3. `docker rm -f <handle>` as idempotent cleanup.

Registration timeout, explicit runtime deletion, stale-runtime reaping, and
partial startup cleanup all retain existing service semantics. A stop failure
does not prevent forced removal, and both failures are reported without exposing
credentials.

At census finalization, coverage-labeled hosted containers are stopped before
Go/Python reports are merged. This is required because SIGKILL cannot be made
reliably flush either runtime.

## Reporting

Go runtime output is converted using:

```text
go tool covdata merge
go tool covdata textfmt
go tool cover -func
```

Python output is converted using:

```text
coverage combine
coverage report
coverage json
```

The census run records a per-runtime manifest and both per-runtime and combined
reports. Missing output is an explicit failed/incomplete coverage subject, not
silently treated as zero execution.

## Error Handling and Safety

- Coverage remains disabled unless explicitly enabled.
- Enabled coverage with a missing/relative output path fails startup.
- Normal images do not contain `coverage.py` and are not Go-instrumented.
- No database, Kafka, order, portfolio, account, or arbitrary environment
  addresses are forwarded into hosted runtimes.
- Credential/TLS environment behavior stays unchanged and diagnostics remain
  redacted.
- A container or process that reaches SIGKILL may have incomplete last-interval
  counters; the report marks that runtime incomplete when finalization evidence
  is absent.
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
- exercise normal completion and worker restart;
- stop the container while a worker is connected;
- verify valid Go and Python reports can be generated from mounted output;
- verify the complete hosted path still registers and communicates solely over
  RuntimeChannel.

### Current manual census

After implementation, build the coverage image, restart the already
instrumented local control-panel with this run's output directory, create a new
hosted runtime from the UI, and verify both language outputs before the user
continues broad manual coverage testing.
