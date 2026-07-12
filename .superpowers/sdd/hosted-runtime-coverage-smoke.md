# Hosted Runtime Coverage Smoke Evidence

Date: 2026-07-12 (Asia/Singapore)

Run: `manual-coverage-20260711-230823`

Source root: `/Users/xdy/Workplace/hushine-worktrees/medium-cleanup`

Result: **PASS** for revision-bound runtime
`rt-a909e69e54a2871f21b29397` using deploy smoke revision
`be0cc5dfda66ae519e635017e1487ab125f8da6e`.

This evidence includes no credential, private key, TLS bundle, bearer token,
password, raw RPC error detail, or raw Docker environment. Smoke diagnostics
are restricted to IDs, image, platform-owned labels, mount source, environment
variable names, RPC status codes, and lifecycle events.

## Revisions and pre-smoke verification

Relevant commits:

- strategy-service `4dfd4f2` — `fix: use coverage sigterm config`;
- control-panel-service `642869f` — `chore: log hosted coverage settings`;
- hushine-deploy `9d93fca..be0cc5d` — initial smoke, failure-path
  hardening, strict lifecycle assertions, tracked contract, and corrected
  plan/design semantics.

The implementation plan's original `uv run --extra test` command is not valid
because strategy-service has no `test` extra. The repository-owned command from
`AGENTS.md` was used instead.

| Repository | Command | Exit | Evidence |
| --- | --- | ---: | --- |
| strategy-service | `go test ./...` | 0 | all packages passed |
| strategy-service | `go vet ./...` | 0 | no findings |
| strategy-service | `PYTHONPATH=.:../strategy-library uv run --frozen --extra dev pytest tests/ -q` | 0 | 466 passed |
| strategy-service | `bash scripts/start-bare-runtime-debugpy.test.sh` | 0 | passed |
| strategy-service | `bash scripts/runtime-agent-platform.test.sh` | 0 | passed |
| control-panel-service | `go test ./...` | 0 | all packages passed |
| control-panel-service | `go vet ./...` | 0 | no findings |
| hushine-deploy | `./scripts/smoke_hosted_runtime_coverage.test.sh` | 0 | tracked contract passed |
| smoke helper | `go test ../hushine-deploy/scripts/smoke_hosted_runtime_coverage.go` | 0 | compiled |
| smoke helper | `go vet ../hushine-deploy/scripts/smoke_hosted_runtime_coverage.go` | 0 | no findings |

The tracked deploy contract verifies coverage run labels, canonical path and
symlink containment, ownership-checked fallback cleanup, forced-removal
attempt after a failed graceful fallback stop, locked report tooling, strict
Preview and EndRuntime state assertions, `STOP_ACTION_STOP_ONLY`, prohibition
of `STOP_ACTION_CANCEL`, redacted RPC errors, the future Docker-event capture
boundary, and required signal 15 / exit 0 / destroy facts.

## Stack restart and coverage configuration

The pre-existing normal hosted runtime was inspected before cleanup:

- runtime `rt-357d6ee383bec8bc2118c185`, user `127`;
- container `6d9c0214cc883aeca8d4c5b70e3e035d3b1593f0240ba283f4c7bdb0c7e8286e`;
- normal image `hushine/strategy-runtime:executor-dev`, image ID
  `sha256:94bbe142caa99d95d091fad8781a21df4921f2f121bc3adc99900d1c81e3ef1e`;
- no coverage label, mount, or coverage environment name.

It was ended through control-panel for its recorded owner before the sampled
stack was relaunched with the user-requested command:

```text
/Users/xdy/Workplace/hushine/scripts/audit/census/start_instrumented_stack.sh \
  --source-root /Users/xdy/Workplace/hushine-worktrees/medium-cleanup \
  manual-coverage-20260711-230823
```

Control-panel alone was subsequently restarted on the same generated
instrumented binary after adding its safe startup log. No other application
service, Chrome, or CDP collector was restarted. The effective log evidence is
`control-panel-service/logs/system.log:317`, timestamp
`2026-07-12T09:59:38.685635+08:00`:

```text
runtime coverage: enabled image=hushine/strategy-runtime:executor-coverage output_dir=/Users/xdy/Workplace/hushine-worktrees/medium-cleanup/census-runs/manual-coverage-20260711-230823/coverage/runtime-agent stop_timeout_seconds=10
```

No application RPC/access log is used as evidence. The non-Git census inputs
used for this run have these SHA-256 values:

| File | SHA-256 |
| --- | --- |
| `start_instrumented_stack.sh` | `8222e91318b2ca284d3f2f5c75e2d567ba4677375cdcdf687b6c932956de5efc` |
| `census/coverage.py` | `6ccd215f1c1c7b5ef2146725bbfa6eb4050e508bf1ed9a613af330b5562859f1` |
| `config.yaml` | `45100e0e3412856658fa6b712da074a352b51aa5caa5bb07849081468398db5e` |

## Failures found and corrected

The first real attempt, `rt-f212b8978f87ab6964f8c149`, failed before the
Python worker connected because coverage.py 7.15 has no `coverage run
--sigterm` option. The coverage image already enables signal handling through
`.coveragerc` with `sigterm = true`. A focused RED/GREEN fix removed only the
invalid CLI argument and retained the configuration-file behavior. Strategy
commit `4dfd4f2`, full Go tests/vet, and six Docker contracts passed.

Further fail-closed smoke iterations established and corrected these harness
semantics:

- report commands must execute from the strategy-service module;
- EndRuntime must reject an active session with `AlreadyExists`;
- `STOP_ACTION_CANCEL` intentionally returns `stopped=false`, while
  `STOP_ACTION_STOP_ONLY` persists `stopped` and finalizes the worker;
- a second distinct session proves worker recreation before runtime shutdown;
- Docker can publish `destroy` one second after container disappearance, so
  event capture waits on a bounded future timestamp rather than dropping the
  final record.

Every failed iteration was reconciled to a terminal runtime, and its exact
ownership-verified container was removed. The retained pre-fix runtime remains
explicitly incomplete in census output instead of being hidden.

## Revision-bound hosted smoke

Coverage image ID:

```text
sha256:f57c325294da83cb145fc9ae869d8ca5ddd012611901b9a18c42a616667d897c
```

Exact command from deploy commit `be0cc5d`:

```text
USER_ID=127 ./scripts/smoke_hosted_runtime_coverage.sh \
  /Users/xdy/Workplace/hushine-worktrees/medium-cleanup/census-runs/manual-coverage-20260711-230823/coverage/runtime-agent
```

Exit: 0.

Identity and containment facts:

- runtime ID `rt-a909e69e54a2871f21b29397`;
- container ID `e7dc30b99f7e8aa251887813f7c7b6969a4372fe61658d63be13f69331081646`;
- user `127`, selected owned portfolio `79`;
- image ID matched the inspected coverage image;
- `hushine.runtime.coverage=true`;
- `hushine.runtime.coverage_run_id=manual-coverage-20260711-230823`;
- `/coverage` bind source matched the canonical unique runtime root;
- only the coverage environment names `GOCOVERDIR` and
  `HUSHINE_RUNTIME_COVERAGE_DIR` were checked.

Runtime and worker lifecycle facts:

1. `PreviewRunStrategy` executed the one-shot Python worker and returned
   `profile=backtest`, `supported=true`, `ok=true`, zero failures, and one
   declared input.
2. `RunStrategy` created session `beed4a08541a48698eafaa478fd2b365`.
3. EndRuntime while that session was active returned the required
   `AlreadyExists` guard.
4. `STOP_ACTION_STOP_ONLY` returned `stopped=true`; portfolio.v1 then reported
   the first session `stopped`.
5. A second RunStrategy created distinct session
   `dc0feed1a24848448ec0443075cafc27`.
6. `STOP_ACTION_STOP_ONLY` returned `stopped=true`; portfolio.v1 reported the
   second session `stopped`.
7. EndRuntime then reported runtime status `cancelled`, source `hosted`, and
   cleanup `succeeded`.

A fresh safe gRPC state query after the smoke confirmed the same terminal
runtime and both session-to-runtime bindings.

The preserved `docker-events.jsonl` records:

```text
create -> start -> kill(signal=15) -> stop -> die(exitCode=0) -> destroy
```

The `destroy` event is timestamped one second after `die`, proving the bounded
future capture fixed an observation race rather than weakening graceful-stop
requirements. No coverage-labeled runtime container remains.

## Generated reports and census merge

Runtime root:

```text
/Users/xdy/Workplace/hushine-worktrees/medium-cleanup/census-runs/manual-coverage-20260711-230823/coverage/runtime-agent/runtimes/rt-a909e69e54a2871f21b29397
```

| Report | Bytes | SHA-256 |
| --- | ---: | --- |
| `go.cover.out` | 709639 | `d1dbdbab4fece70f067735f15e5abba66448f1e1e15e1a9a710beb625580aeb1` |
| `go-functions.txt` | 285009 | `b1260086dee8811f1235d6a5bd82e3b50cffa759dfcfe5bf1717177e4f152b4b` |
| `python-report.txt` | 3801 | `31b1266d91c828cac7b97b33971d7635862288afe2f75259ce6bab59dcbd79ab` |
| `python-coverage.json` | 455261 | `706dae2ceb28942f8c71d19cd52623adc7ce2f4e9025b46af4616c408d786ef1` |

Go total: 15.1% statements. Python total: 2537/7433 lines,
34.13157540696892%. Inputs contain three Go covdata files and three parallel
Python shards (Preview plus both active workers); the collector also retains
the combined Python data file.

The updated census collector was invoked programmatically with a manually
constructed `RunContext`, so the live run manifest and frontend CDP collector
were not stopped or overwritten. It exited 0 and rewrote
`coverage/hosted-runtime-coverage-summary.json`. The exact final runtime is Go
`ok`, Python `ok`, overall `ok`. All retained post-fix runtimes are also `ok`;
only `rt-f212b8978f87ab6964f8c149` remains Go `ok`, Python `missing`, overall
`incomplete` as the intentional pre-fix diagnostic.

## Post-smoke command and exit matrix

The table uses `RT_ROOT` for the final runtime directory shown above and
`SUMMARY` for `coverage/hosted-runtime-coverage-summary.json` under the census
run directory.

| Assertion | Command | Exit |
| --- | --- | ---: |
| image is inspectable | `docker image inspect --format '{{.Id}}' hushine/strategy-runtime:executor-coverage` | 0 |
| no coverage container remains | `test -z "$(docker ps -aq --filter label=hushine.runtime.coverage=true)"` | 0 |
| graceful events | three `jq -e` selections over `$RT_ROOT/docker-events.jsonl` for kill/signal 15, die/exit 0, and destroy | 0 |
| four reports are nonempty | `test -s` chained for `go.cover.out`, `go-functions.txt`, `python-report.txt`, and `python-coverage.json` | 0 |
| census collection | programmatic collector command below | 0 |
| final collector status | `jq -e '.[] | select(.runtime_id=="rt-a909e69e54a2871f21b29397" and .status=="ok" and .go.status=="ok" and .python.status=="ok")' "$SUMMARY"` | 0 |
| frontend listener | `lsof -nP -iTCP:5173 -sTCP:LISTEN` | 0 |
| application/CDP HTTP | `curl -fsS` chained for control-panel `/readyz`, quant-handler `/healthz`, `http://localhost:5173`, and CDP `/json/version` | 0 |
| scraper, Chrome, collector | `ps -p 70710,91773,91793` | 0 |

Concrete lifecycle and report checks:

```bash
RT_ROOT=/Users/xdy/Workplace/hushine-worktrees/medium-cleanup/census-runs/manual-coverage-20260711-230823/coverage/runtime-agent/runtimes/rt-a909e69e54a2871f21b29397
jq -e 'select(.action == "kill" and .signal == "15")' "$RT_ROOT/docker-events.jsonl" >/dev/null \
  && jq -e 'select(.action == "die" and .exitCode == "0")' "$RT_ROOT/docker-events.jsonl" >/dev/null \
  && jq -e 'select(.action == "destroy")' "$RT_ROOT/docker-events.jsonl" >/dev/null
test -s "$RT_ROOT/go.cover.out" \
  && test -s "$RT_ROOT/go-functions.txt" \
  && test -s "$RT_ROOT/python-report.txt" \
  && test -s "$RT_ROOT/python-coverage.json"
```

Exact collector invocation (the direct constructor deliberately avoids
`RunContext.create`, which would rewrite the live run manifest):

```bash
PYTHONPATH=/Users/xdy/Workplace/hushine/scripts/audit/census \
/Users/xdy/Workplace/hushine-worktrees/medium-cleanup/strategy-service/.venv/bin/python -c '
from pathlib import Path
from census.config import load_config
from census.coverage import collect_hosted_runtime_coverage_outputs
from census.run_context import RunContext
workspace = Path("/Users/xdy/Workplace/hushine-worktrees/medium-cleanup")
run_id = "manual-coverage-20260711-230823"
ctx = RunContext(workspace, run_id, workspace / "census-runs" / run_id,
                 "dynamic", "2026-07-11T23:08:23+08:00")
cfg = load_config(Path("/Users/xdy/Workplace/hushine/scripts/audit/census/config.yaml"))
collect_hosted_runtime_coverage_outputs(ctx, cfg)
'
```

The concrete HTTP command was:

```bash
curl -fsS http://127.0.0.1:8082/readyz >/dev/null \
  && curl -fsS http://127.0.0.1:8090/healthz >/dev/null \
  && curl -fsS http://localhost:5173 >/dev/null \
  && curl -fsS http://127.0.0.1:9222/json/version >/dev/null
```

## Remaining live manual-test state

TCP listeners are ready on 8080, 50051, 8082, 50054, 50055, 8090, 5173, and
Chrome CDP 9222. Vite intentionally listens on `[::1]:5173`; its readiness was
verified with `localhost`, not an IPv4-only `127.0.0.1` probe. HTTP GET returned
200 for `http://localhost:5173` and the Chrome CDP version endpoint.

| Process | Wrapper PID | Child PID |
| --- | ---: | ---: |
| core-service | 70667 | 70676 |
| control-panel-service | 84002 | 84091 |
| scraper | 70694 | 70710 |
| quant-handler | 70718 | 70778 |
| quant-frontend | 70722 | 70799 |

Frontend Chrome PID `91773` and CDP collector PID `91793` were preserved and
remain alive. Coverage-labeled Docker container count is zero.
