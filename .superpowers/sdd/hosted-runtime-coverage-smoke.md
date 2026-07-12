# Hosted Runtime Coverage Smoke Evidence

Date: 2026-07-12 (Asia/Singapore)

Run: `manual-coverage-20260711-230823`

Source root: `/Users/xdy/Workplace/hushine-worktrees/medium-cleanup`

Result: PASS for final runtime `rt-ae731d1a0be4f19aa3ce5021`.

No credential, private key, TLS bundle, bearer token, password, or raw Docker
environment was printed or recorded. Docker evidence below was restricted to
IDs, image, platform-owned labels, mount source, environment variable names,
and lifecycle events.

## Repository verification before Docker

The implementation plan's `uv run --extra test` command is not valid because
strategy-service has no `test` extra. The repository-owned command from
`AGENTS.md` was used instead.

| Repository | Command | Exit | Evidence |
| --- | --- | ---: | --- |
| strategy-service | `go test ./...` | 0 | `cmd/runtime-agent` and `internal/runtimeagent` passed |
| strategy-service | `go vet ./...` | 0 | no findings |
| strategy-service | `PYTHONPATH=.:../strategy-library uv run --frozen --extra dev pytest tests/ -q` | 0 | 466 passed |
| strategy-service | `bash scripts/start-bare-runtime-debugpy.test.sh` | 0 | passed |
| strategy-service | `bash scripts/runtime-agent-platform.test.sh` | 0 | passed |
| control-panel-service | `go test ./...` | 0 | all packages passed |
| control-panel-service | `go vet ./...` | 0 | no findings |
| hushine-deploy | `bash /tmp/task7-smoke-contract.test.sh` | 0 | shell/helper contract passed |
| hushine-deploy helper | `go test .../scripts/smoke_hosted_runtime_coverage.go` | 0 | compiled; no test files |

## Stack restart and coverage configuration

The pre-existing hosted container was first inspected and attributed to
control-panel:

- runtime: `rt-357d6ee383bec8bc2118c185`, user `127`;
- container: `6d9c0214cc883aeca8d4c5b70e3e035d3b1593f0240ba283f4c7bdb0c7e8286e`;
- image: `hushine/strategy-runtime:executor-dev`, image ID
  `sha256:94bbe142caa99d95d091fad8781a21df4921f2f121bc3adc99900d1c81e3ef1e`;
- no coverage label, mount, or coverage environment name.

It was ended via control-panel `EndRuntime` for its recorded owner. The normal,
non-coverage provisioner removed it with its existing forced-removal behavior;
no coverage output existed to flush.

The sampled stack was restarted with:

```text
/Users/xdy/Workplace/hushine/scripts/audit/census/start_instrumented_stack.sh \
  --source-root /Users/xdy/Workplace/hushine-worktrees/medium-cleanup \
  manual-coverage-20260711-230823
```

The command harness reaps detached children when a command cell closes, so the
launcher is held by a persistent command session. The application processes
remain the launcher-generated instrumented binaries. Process environment was
checked by variable name only: the control-panel child has
`RUNTIME_COVERAGE_ENABLED`, `RUNTIME_COVERAGE_OUTPUT_DIR`,
`RUNTIME_COVERAGE_IMAGE`, and `GOCOVERDIR` set.

The current control-panel code does not log the effective coverage image/output
root at startup. Coverage configuration was therefore verified from the process
environment names and the real container's image, labels, and mount. This is an
acceptance-evidence gap, not a failed runtime path.

## Failure found and corrected

The first real attempt provisioned `rt-f212b8978f87ab6964f8c149`, then the
one-shot worker exited before IPC connection. An exact image reproduction
returned:

```text
no such option: --sigterm
```

coverage.py 7.15 does not expose `--sigterm` as a `coverage run` CLI option.
The image's `.coveragerc` already has `sigterm = true`. A focused TDD fix removed
only the invalid CLI argument and updated the exact argument test. Evidence:

- red: `go test ./internal/runtimeagent -run '^TestCoverageConfigPythonArgs$' -count=1`
  exited 1 and showed the extra `--sigterm`;
- green: the same command exited 0;
- `go test ./...`, `go vet ./...`, and the six Docker contract tests exited 0;
- strategy-service commit: `4dfd4f2` (`fix: use coverage sigterm config`).

The second real attempt, `rt-e5023dcc35854edccc88ce8e`, proved the worker and
graceful container path but exposed a smoke-only report bug: `go tool cover`
was run outside the strategy-service module. A contract regression was observed
failing, the Go report commands were moved under the module root, and the
contract returned to green. The retained raw data for this attempt was later
successfully processed by the census collector.

The first diagnostic runtime intentionally remains in the census output with
Go status `ok` and Python status `missing`; its absence records the pre-import
coverage.py failure instead of hiding it.

## Final image and hosted smoke

Coverage image build command:

```text
./strategy-service/scripts/build_strategy_runtime.sh --coverage
```

Exit: 0.

Fresh image ID:

```text
sha256:f57c325294da83cb145fc9ae869d8ca5ddd012611901b9a18c42a616667d897c
```

Smoke command:

```text
USER_ID=127 hushine-deploy/scripts/smoke_hosted_runtime_coverage.sh \
  /Users/xdy/Workplace/hushine-worktrees/medium-cleanup/census-runs/manual-coverage-20260711-230823/coverage/runtime-agent
```

Exit: 0.

Safe runtime evidence:

- runtime ID: `rt-ae731d1a0be4f19aa3ce5021`;
- container ID: `2959b4d8b681511a0b732529e470b200ae9c066abfc954d44dc1f67edbe1493d`;
- image ID matched the fresh coverage image;
- `hushine.runtime.coverage=true`;
- `hushine.runtime.coverage_run_id=manual-coverage-20260711-230823`;
- `/coverage` bind source matched the unique runtime root;
- coverage environment names `GOCOVERDIR` and
  `HUSHINE_RUNTIME_COVERAGE_DIR` were present;
- `PreviewRunStrategy` selected owned portfolio `79`, executed a one-shot
  Python worker, and returned a structured backtest preflight (`supported=true`,
  one declared input);
- `EndRuntime` reported `cleanup_status=succeeded`;
- Docker lifecycle was create -> start -> signal 15 -> stop -> die exit 0 ->
  destroy;
- no `hushine-runtime-*` or coverage-labeled container remained.

## Generated reports

Runtime root:

```text
/Users/xdy/Workplace/hushine-worktrees/medium-cleanup/census-runs/manual-coverage-20260711-230823/coverage/runtime-agent/runtimes/rt-ae731d1a0be4f19aa3ce5021
```

| Report | Bytes | SHA-256 |
| --- | ---: | --- |
| `go.cover.out` | 709524 | `d825dd3fc28538d7a4f0a018590d0eb89db4c09b1ee7102cc6fa4d5b904a599a` |
| `go-functions.txt` | 284955 | `8912e1fea83066a9f0c7d96d446f6e88b7ac6c13ea4b7439f14cef33e7100a55` |
| `python-report.txt` | 3789 | `cd92fb190425343c77be119ebbe100a1a6a0b6066e049e0b16691c4a70dd8237` |
| `python-coverage.json` | 453722 | `613fa9b8b1a3660e7be0e4261f3ed4c42365f48db759ee4aa0c05936316f11b0` |

Go total: 11.9% statements. Python total: 1967/7433 lines,
26.463070092829273%.

The updated census collector was then run without stopping the frontend CDP
collector. `hosted-runtime-coverage-summary.json` reports:

- `rt-ae731d1a0be4f19aa3ce5021`: Go `ok`, Python `ok`, overall `ok`;
- `rt-e5023dcc35854edccc88ce8e`: Go `ok`, Python `ok`, overall `ok`;
- `rt-f212b8978f87ab6964f8c149`: Go `ok`, Python `missing`, overall
  `incomplete` (the retained diagnostic attempt described above).

## Remaining live manual-test state

All expected listeners were present: 8080, 50051, 8082, 50054, 50055, 8090,
5173, and Chrome CDP 9222. HTTP probes returned 200 for control-panel readiness,
quant-handler health, and the frontend.

| Process | Wrapper PID | Child PID |
| --- | ---: | ---: |
| core-service | 70667 | 70676 |
| control-panel-service | 70685 | 70801 |
| scraper | 70694 | 70710 |
| quant-handler | 70718 | 70778 |
| quant-frontend | 70722 | 70799 |

Frontend census Chrome PID `91773` and CDP collector PID `91793` were preserved
across the restart and remain alive. There are no remaining Docker runtime
containers.
