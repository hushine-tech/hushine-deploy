# Runtime Python Dependency Contract Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the eight approved public Python import roots a single machine-readable contract that is locked, import-tested, admitted by RuntimeChannel, enforced before Preview/Run user-code execution, optionally available for explicit validation, and explained end-to-end without widening Runtime capabilities or changing Strategy creation order.

**Architecture:** strategy-library owns and packages one TOML dependency profile plus immutable loaders and shared import-validation primitives. strategy-service and strategy-debugger-cli project the manifest distributions into explicit locked dependencies; both final Runtime image targets and debugger workspaces prove installed metadata plus real imports. The runtime-agent verifies the exact worker interpreter before HELLO, reports signed profile facts on HELLO and RESUME, and control-panel admits only the configured profile/version/digest while continuing to route exclusively by runtime_id. Preview and Run validate complete import paths and initialization inside the selected Runtime; an explicit ValidateStrategySource API is available when a caller already has a runtime_id, but ordinary Strategy creation remains independent of Runtime creation/selection. Typed dependency failures cross worker IPC, RuntimeChannel, gRPC, quant-handler HTTP, and the frontend without creating a false running Session.

**Tech Stack:** Python 3.13 Hosted Runtime and Python 3.12+ debugger, TOML/tomllib/importlib.metadata/importlib.resources, uv lock/sync, pytest, Protocol Buffers/gRPC, Go 1.26, React 19/TypeScript 5.7, Docker BuildKit and OCI image labels, shell smoke tests.

## Global Constraints

- The only hand-written public dependency mapping is strategy-library/hushine_strategy/runtime_dependencies.toml. No Go, Python, Docker, shell, configuration, test fixture, or frontend file may copy the eight-root allow-list. Product dependency entries and smoke/import fixtures are deterministic projections written or rendered by the manifest tooling.
- Schema 1 is exact: profile platform-python-3.13, profile version 1.0.0, Hosted Python 3.13, debugger Python >=3.12, and the eight approved roots dateutil, google, grpc, numpy, pandas, pydantic, requests, and yaml. The loader rejects a non-SemVer profile_version and any schema-1 Python constraint other than those exact values; later changes must introduce a new supported schema deliberately.
- The schema-1 manifest bytes specified in Task 1 have SHA-256 8457b3c35618558fc8bfc74d4135b7eb52e00c33a8c9a49d202830f3fd5b62c5. Build, HELLO, admission configuration, tests, and documentation use the loader-computed digest; the literal appears only in assertions/configuration that intentionally pin this rollout.
- scipy, sklearn, statsmodels, pandas_ta, pandas-ta, TA-Lib, and ta remain unsupported. coverage, debugpy, pyarrow, pytest, zstandard, grpcio-tools, and all other installed tools remain non-public.
- Standard-library imports and the existing safe platform prefixes strategy_service.types and hushine_strategy remain governed by existing safety rules; they are not manifest distributions.
- Every manifest public distribution is a direct Runtime dependency in both strategy-service and strategy-debugger-cli and resolves in each committed uv.lock. A transitive installation is an explicit failure. The checker owns a write mode that reconciles only its marked pyproject projection block from the manifest; check mode proves that regeneration is a no-op, so tests and developers never maintain a second eight-item mapping.
- `strategy-library` deliberately has no `uv.lock`. Every library test/check command uses `uv run --isolated --no-project --with-editable '.[test]' ...`, records repository status before/after, and must not create a lock or any tracked/untracked repository artifact. The service and debugger remain the only lock owners.
- Debugger closure is run on every currently released CPython minor satisfying schema 1's `>=3.12` at release time—3.12, 3.13, and 3.14 for this release. A newly released satisfying minor expands the required matrix before the next debugger publication; “3.12+” is never treated as proof from only two sampled minors.
- `strategy-service` resolves `hushine-strategy-library` from the sibling build-context path recorded in `[tool.uv.sources]`, not from a mutable remote branch. The normal and coverage image therefore install and metadata-check the exact library source whose commit is embedded in the image facts.
- Changing manifest bytes after the manifest exists at the chosen baseline requires a strictly greater SemVer profile_version, regenerating both projections and locks, and passing comparison against that baseline Git ref. On the one-time introduction where the ref resolves but has no manifest path, the checker records BASELINE_MANIFEST_ABSENT and accepts only the exact schema-1 1.0.0 bytes/digest from Task 1; an unresolved ref remains a configuration error. Lock-only or Dockerfile-only changes cannot add public imports.
- Normal and coverage Runtime images derive from one locked runtime-base. Coverage adds instrumentation only, then repeats the full metadata/import/bootstrap closure check.
- Build and publish verification always builds both final targets without cache and validates each final image, not only runtime-base. Development builds may label a dirty worktree only when explicitly allowed; release acceptance rebuilds from clean commits and rejects dirty/missing source facts.
- The runtime-agent verifies the exact Python executable, argument prefix, working directory, sanitized environment, Python version, installed metadata, and import probes that worker_manager will use. Version, metadata, and import checks execute in one child process under that target interpreter; no check is satisfied by the runtime-agent caller's interpreter. Failure exits before listener registration or RuntimeChannel HELLO with RUNTIME_DEPENDENCY_PROFILE_INVALID.
- HELLO and RESUME carry profile name, version, contract digest, strategy-service commit, strategy-library commit, and image build ID. These fields are signed for credential HELLO and contain no secret, repository URL, credential, endpoint, environment value, or host path.
- control-panel compares HELLO and RESUME to one typed expected profile configuration before registry upsert, channel registration, or route availability. Session routing remains exclusively runtime_id; profile metadata is an admission fact, never a second route key.
- Hosted Preview and Run, optional explicit ValidateStrategySource, and debugger replay use the same shared AST dependency rules. Complete imported module paths are checked against the selected worker interpreter before user code is executed.
- Stable dependency codes are exactly UNSUPPORTED_STRATEGY_DEPENDENCY, STRATEGY_DEPENDENCY_UNAVAILABLE, STRATEGY_IMPORT_FAILED, RUNTIME_DEPENDENCY_PROFILE_INVALID, and RUNTIME_DEPENDENCY_PROFILE_MISMATCH.
- A dependency error preserves code, module, runtime_profile, runtime_profile_version, image_build_id, and a safe message across worker startup, synchronous Preview/Run/Validate, asynchronous download-and-run jobs, RuntimeChannel, gRPC, quant-handler HTTP, and the frontend. Tracebacks are logged with existing redaction and are never returned to the browser.
- A worker process HELLO is not strategy readiness. Run returns success only after validation, import, and user strategy load have completed and SessionProgress reports running.
- Dependency/import failure before running terminates the one-shot or session worker generation, clears agent pending maps/aliases, and leaves no running Session.
- Existing CreateStrategy remains valid without runtime_id and preserves the current product sequence: create/save Strategy first, then create/select Runtime when starting it. The design phrase "save-time validation" is resolved as an optional editor action against an already selected runtime, exposed through HTTP ValidateStrategySource; storage-only Create never invokes it, never requires runtime_id, and is never blocked by Runtime availability. Preview and Run always validate on their selected runtime.
- A Hosted startup-profile failure is captured by the platform provisioner as a structured admission failure without registering or routing the Runtime. A Self-hosted startup-profile failure may send one bounded credential-authenticated failure report that creates no HELLO, lease, registry entry, or route; local stderr remains authoritative if reporting cannot connect. Bare/debugger stays an internal local-log path.
- The change adds no database table, column, migration, compatibility alias, dynamic pip/uv install, or requirements upload.
- Generated protobuf files are regenerated from authoritative proto files and are never edited manually. Determinism is proven by checksums of a first and second generation, not by comparing generated output with the pre-change worktree. Dependency-protocol tags coexist with Indicator V2: dependency fields use nested-message tags 5/6; Indicator V2 uses WorkerHello.protocol_version field number 5 with runtime value 2 and WorkerFrame.indicator_frame_v2 field number 21 while reserving the old WorkerFrame field number 15. The final descriptor/value test asserts all fields and reservations together.
- Each repository is independent. Preserve unrelated dirty work, stage only task-owned files, and use repository-scoped commits named in each task.
- Before Task 1 edits strategy-library, fetch its approved remote branch and record the exact pre-implementation `HEAD`/merge-base as `RUNTIME_DEPENDENCY_BASE_SHA`; require a 40-character commit that resolves locally. Every pre-push baseline check uses that immutable SHA. The coordinated post-push gate instead uses the final published strategy-library SHA and requires state `present`.

---

## File Map

### strategy-library

- strategy-library/hushine_strategy/runtime_dependencies.toml — sole schema-1 dependency mapping.
- strategy-library/hushine_strategy/runtime_dependencies.py — package-resource loader, schema validation, digest, installed metadata/probe checks, and JSON CLI.
- strategy-library/hushine_strategy/import_validation.py — shared AST import collection and permission/availability issue model.
- strategy-library/hushine_strategy/validator.py — existing safety validator consuming the shared profile and import validation.
- strategy-library/hushine_strategy/__init__.py — exports only the stable profile/import-validation API needed by consumers.
- strategy-library/pyproject.toml — TOML package data and removal of pandas-ta from the public/default capability story.
- strategy-library/scripts/check_runtime_dependency_contract.py — deterministic manifest projection writer plus project/lock/first-baseline/target-interpreter checker.
- strategy-library/tests/hushine_strategy/test_runtime_dependencies.py — schema, resource, digest, metadata, probe, and CLI tests.
- strategy-library/tests/hushine_strategy/test_import_validation.py — exact public roots, complete-path resolution, and stable issue tests.
- strategy-library/tests/hushine_strategy/test_validator.py — Hosted/debugger convergence and forbidden/internal regressions.
- strategy-library/tests/test_runtime_dependency_contract.py — direct dependency, lock, transitive-only, stale lock, and profile-version-change fixtures.
- strategy-library/README.md — contract ownership and public-versus-internal explanation.

### strategy-service

- strategy-service/pyproject.toml and strategy-service/uv.lock — explicit direct projection of all eight public distributions.
- strategy-service/strategy_service/runtime_profile.py — immutable adapter over the packaged shared profile plus image facts.
- strategy-service/strategy_service/strategy_validator.py — Phase 3 declaration checks combined with shared import issues.
- strategy-service/strategy_service/strategy_imports.py — complete-path resolution and isolated import-initialization preflight.
- strategy-service/strategy_service/grpc_server.py — ValidateStrategySource plus Preview/Run pre-running validation/load gate.
- strategy-service/strategy_service/platform_proxy.py and portfolio_client.py — carry the pending startup state through hosted/proxied and direct/Bare SaveSession paths.
- strategy-service/strategy_service/strategy/base.py — preserves typed strategy import failures instead of flattening them.
- strategy-service/strategy_service/session_worker_entry.py — typed worker failure/READY ordering.
- strategy-service/proto/strategy_service.proto — shared profile/error/validation messages and ValidateStrategySource RPC.
- strategy-service/proto/runtime_worker.proto — typed dependency details on progress/call/error frames.
- strategy-service/strategy_service/gen/*.py and strategy-service/gen/{strategyv1,runtimeworkerv1,controlpanelv1,portfoliov1}/*.go — regenerated local protocol clients/types.
- strategy-service/generate_proto.sh — portable deterministic regeneration of all owned stubs.
- strategy-service/internal/runtimeagent/dependency_profile.go — exact worker-interpreter startup verification and typed Go profile facts.
- strategy-service/internal/runtimeagent/runtime_channel.go — HELLO/RESUME facts and signed canonical payload.
- strategy-service/internal/runtimeagent/agent.go — Validate dispatch, typed worker error propagation, running gate, and cleanup.
- strategy-service/internal/runtimeagent/worker_manager.go — exact Python invocation exposed to startup verification and worker cleanup.
- strategy-service/internal/runtimeagent/startup_failure_report.go — bounded signed Self-hosted failure-only report.
- strategy-service/cmd/runtime-agent/main.go — fail-closed startup gate before listener/channel construction.
- strategy-service/Dockerfile — shared locked base, final-target closure gates, OCI labels, and embedded facts.
- strategy-service/scripts/build_strategy_runtime.sh and scripts/prepare_runtime_build_context.py — reproducible three-repository build facts, hermetic Git-derived context, and normal/coverage target selection.
- strategy-service/scripts/verify_runtime_image.sh — final-image facts, metadata, import, worker bootstrap, and coverage-denial checks.
- strategy-service/scripts/smoke_strategy_runtime.sh — representative all-public strategy smoke.
- strategy-service/scripts/fixtures/runtime_dependency_strategy_body.py — dependency-neutral Phase 3 strategy body; smoke code prepends probes read from the packaged TOML.
- strategy-service/scripts/runtime_dependency_worker_smoke.py — actual one-shot session-worker/loopback-agent validation harness.
- strategy-service/tests/test_runtime_profile.py, test_strategy_validator.py, test_strategy_imports.py, test_grpc_server.py, test_session_worker_entry.py, test_strategy_runtime_dockerfile.py — Python contract and lifecycle tests.
- strategy-service/internal/runtimeagent/dependency_profile_test.go, runtime_channel_test.go, agent_test.go and strategy-service/cmd/runtime-agent/main_test.go — startup/admission metadata/error/cleanup Go tests.
- strategy-service/Makefile and strategy-service/README.md — contract/image verification entry points and operator-facing behavior.

### core-service

- core-service/proto/portfolio_service.proto and generated `gen/portfoliov1` — backward-compatible `SaveSessionRequest.initial_status` wire field.
- core-service/internal/service/grpc.go and tests — pending startup admission, strategy-start-only snapshot exception, and pending-to-running/failed transitions without making pending order-active.
- core-service/internal/repository/timescale.go and tests — preserves all existing status code/text mappings and adds only explicit pending transition predicates.

### strategy-debugger-cli

- strategy-debugger-cli/pyproject.toml and strategy-debugger-cli/uv.lock — explicit locked projection for Python >=3.12.
- strategy-debugger-cli/init.py — lock-driven bootstrap rather than open-ended installation.
- strategy-debugger-cli/scripts/with-local-strategy-library-git.sh — pre-push canonical-URL resolution through an isolated local bare mirror.
- strategy-debugger-cli/scripts/bootstrap-standalone.test.sh — clean Python 3.12/3.13/3.14 bootstrap without a sibling strategy-library checkout.
- strategy-debugger-cli/src/hushine_debugger/runtime_profile.py — packaged profile display and workspace closure checks.
- strategy-debugger-cli/src/hushine_debugger/cli.py — hushine-debug profile --json and preflight wiring.
- strategy-debugger-cli/src/hushine_debugger/init_workspace.py — clean workspace sync and post-sync contract gate.
- strategy-debugger-cli/src/hushine_debugger/replay.py — fail before replay when workspace profile is incomplete.
- strategy-debugger-cli/tests/test_runtime_profile.py, test_cli.py, test_workspace.py, and test_replay_cli.py — supported Python, locked install, closure, public/internal, and error parity tests.
- strategy-debugger-cli/README.md — profile inspection, locked workspace upgrade, and dependency error help.

### protocol and control-panel-service

- control-panel-service/proto/control_panel_service.proto — Validate proxy, HELLO/RESUME profile facts, structured StreamError detail, and signed failure-only startup report.
- control-panel-service/gen/controlpanelv1/*.go — regenerated control-panel protocol.
- control-panel-service/internal/config/config.go, config_test.go, and control-panel-service/config.yaml — exact expected profile admission settings.
- control-panel-service/internal/runtimechannel/auth.go and auth_test.go — signed HELLO payload includes all dependency facts.
- control-panel-service/internal/runtimechannel/service.go and admission tests — HELLO/RESUME validation before registration.
- control-panel-service/internal/runtimechannel/startup_failure_test.go — signed Self-hosted invalid-profile reporting without registration.
- control-panel-service/internal/provision/{provision.go,docker.go,docker_test.go} and control-panel-service/internal/runtime/{service.go,service_test.go} — Hosted failure JSON capture and existing admission-failure recording.
- control-panel-service/internal/runtimechannel/proxy.go, grpc.go, and tests — Validate forwarding and structured status preservation.
- control-panel-service/internal/runtime/grpc.go and grpc_status_test.go — public strategy proxy and stable gRPC status detail.
- control-panel-service/Makefile and control-panel-service/README.md — generation, verification, admission, rollout, and rollback instructions.

### golang-lib

- golang-lib/pkg/errors/error.go and error_test.go — CommonError details map JSON contract.
- golang-lib/pkg/errors/grpc.go and grpc_test.go — gRPC StringValue detail round trip without losing runtime fields.

### gateway/quant-handler

- gateway/quant-handler/internal/app/app.go, strategy_route.go, and runtime route tests — explicit HTTP ValidateStrategySource on the selected runtime_id.
- gateway/quant-handler/internal/app/strategy_mgmt.go and new strategy_mgmt_test.go — regression proof that Strategy creation remains runtime-independent.
- gateway/quant-handler/internal/app/strategy.go, strategy_test.go, and strategy_cutover_test.go — Preview/Run structured runtime error envelope.
- gateway/quant-handler/internal/app/backtest_download_jobs.go and backtest_coverage_test.go — structured dependency errors in asynchronous download-and-run status.
- gateway/quant-handler/internal/app/runtime_dependency_error.go and runtime_dependency_error_test.go — gRPC CommonError to safe HTTP error mapping.

### gateway/quant-frontend

- gateway/quant-frontend/src/api/client.ts — runtime dependency/job/Validate types, unchanged Create payload, and safe formatter.
- gateway/quant-frontend/src/pages/StrategyList.tsx — regression proof that Strategy creation does not require Runtime selection.
- gateway/quant-frontend/src/pages/PortfolioDetail.tsx — Preview/Run dependency category/module/profile/build display.
- gateway/quant-frontend/src/pages/RuntimeManagement.tsx — dependency-profile admission mismatch details.
- gateway/quant-frontend/scripts/runtime-dependency-contract.test.mjs — executable API/UI structure and error-format assertions.
- gateway/quant-frontend/package.json — named frontend contract test.

### hushine-deploy

- hushine-deploy/Makefile — dependency-contract and paired normal/coverage image gates.
- hushine-deploy/scripts/runtime-dependency-contract.test.sh — repository-wide contract, lock, image, and protocol checks.
- hushine-deploy/scripts/scan-saved-strategy-imports.py — read-only deployment report using a DSN environment-variable name, never a DSN CLI value.
- hushine-deploy/docs/runtime-operator-flow.md — profile facts, admission, image verification, deployment, and rollback.
- hushine-deploy/docs/production-deploy-checklist.md — ordered release and saved-strategy scan checklist.

---

### Task 1: Package the Authoritative Manifest and Immutable Loader

**Files:**
- Create: strategy-library/hushine_strategy/runtime_dependencies.toml
- Create: strategy-library/hushine_strategy/runtime_dependencies.py
- Modify: strategy-library/hushine_strategy/__init__.py
- Modify: strategy-library/pyproject.toml
- Create: strategy-library/tests/hushine_strategy/test_runtime_dependencies.py

**Interfaces:**
- Consumes: packaged TOML bytes through importlib.resources, optional explicit fixture path, current Python executable.
- Produces: RuntimeDependency, RuntimeDependencyProfile, DependencyProbeFailure, load_runtime_dependency_profile(), probe_runtime_dependency_profile(), require_runtime_dependency_profile(), and module CLI show/verify-installed JSON.

- [ ] **Step 1: Write failing schema, package-resource, digest, and probe tests**

Add tests with the exact API and values:

~~~python
from hushine_strategy.runtime_dependencies import (
    load_runtime_dependency_profile,
    probe_runtime_dependency_profile,
)

def test_packaged_schema_1_profile_is_exact():
    profile = load_runtime_dependency_profile()
    assert profile.schema_version == 1
    assert profile.profile_name == "platform-python-3.13"
    assert profile.profile_version == "1.0.0"
    assert profile.hosted_python == "3.13"
    assert profile.debugger_python == ">=3.12"
    public = tuple(item for item in profile.dependencies if item.public)
    assert len(public) == 8
    assert profile.public_import_roots == tuple(sorted(
        item.import_root for item in public
    ))
    assert all(item.probe.split(".", 1)[0] == item.import_root for item in public)
    assert profile.contract_sha256 == "8457b3c35618558fc8bfc74d4135b7eb52e00c33a8c9a49d202830f3fd5b62c5"

def test_probe_uses_one_target_process_without_importing_in_caller(monkeypatch):
    profile = load_runtime_dependency_profile()
    calls = []
    monkeypatch.setattr(
        "hushine_strategy.runtime_dependencies._run_installed_probe",
        lambda executable, constraint, env: calls.append((executable, constraint, env))
        or installed_probe_result(
            profile,
            failures=[("grpc", "grpcio", "grpc", "ModuleNotFoundError: grpc")],
        ),
    )
    failures = probe_runtime_dependency_profile(
        profile,
        python_executable="/venv/bin/python",
        python_constraint="3.13",
    )
    assert [(f.import_root, f.distribution, f.probe) for f in failures] == [
        ("grpc", "grpcio", "grpc")
    ]
    assert [(executable, constraint) for executable, constraint, _ in calls] == [
        ("/venv/bin/python", "3.13")
    ]
~~~

Add parameterized invalid fixture tests for missing required fields, unsupported schema, empty strings, duplicate import_root/distribution/probe after normalized distribution comparison, non-boolean public, no public entries, malformed TOML, and a probe whose first root differs from import_root.

- [ ] **Step 2: Run the focused test and verify RED**

Run:

~~~bash
cd strategy-library
uv run --isolated --no-project --with-editable '.[test]' pytest tests/hushine_strategy/test_runtime_dependencies.py -q
~~~

Expected: collection fails with ModuleNotFoundError for hushine_strategy.runtime_dependencies.

- [ ] **Step 3: Add the exact schema-1 TOML**

Write these bytes, including the final newline:

~~~toml
schema_version = 1
profile_name = "platform-python-3.13"
profile_version = "1.0.0"
hosted_python = "3.13"
debugger_python = ">=3.12"

[[dependencies]]
import_root = "dateutil"
distribution = "python-dateutil"
probe = "dateutil"
public = true

[[dependencies]]
import_root = "google"
distribution = "protobuf"
probe = "google.protobuf"
public = true

[[dependencies]]
import_root = "grpc"
distribution = "grpcio"
probe = "grpc"
public = true

[[dependencies]]
import_root = "numpy"
distribution = "numpy"
probe = "numpy"
public = true

[[dependencies]]
import_root = "pandas"
distribution = "pandas"
probe = "pandas"
public = true

[[dependencies]]
import_root = "pydantic"
distribution = "pydantic"
probe = "pydantic"
public = true

[[dependencies]]
import_root = "requests"
distribution = "requests"
probe = "requests"
public = true

[[dependencies]]
import_root = "yaml"
distribution = "PyYAML"
probe = "yaml"
public = true
~~~

- [ ] **Step 4: Implement frozen loader/value objects and isolated probes**

Use exact public signatures:

~~~python
@dataclass(frozen=True)
class RuntimeDependency:
    import_root: str
    distribution: str
    probe: str
    public: bool

@dataclass(frozen=True)
class RuntimeDependencyProfile:
    schema_version: int
    profile_name: str
    profile_version: str
    hosted_python: str
    debugger_python: str
    dependencies: tuple[RuntimeDependency, ...]
    contract_sha256: str

    @property
    def public_import_roots(self) -> tuple[str, ...]: ...

    @property
    def public_distributions(self) -> tuple[str, ...]: ...

@dataclass(frozen=True)
class DependencyProbeFailure:
    import_root: str
    distribution: str
    probe: str
    reason: str

def load_runtime_dependency_profile(path: str | Path | None = None) -> RuntimeDependencyProfile: ...
def probe_runtime_dependency_profile(
    profile: RuntimeDependencyProfile | None = None,
    *,
    python_executable: str = sys.executable,
    python_constraint: str | None = None,
) -> tuple[DependencyProbeFailure, ...]: ...
def require_runtime_dependency_profile(
    profile: RuntimeDependencyProfile | None = None,
    *,
    python_executable: str = sys.executable,
    python_constraint: str | None = None,
) -> RuntimeDependencyProfile: ...
~~~

Read default bytes with importlib.resources.files("hushine_strategy").joinpath("runtime_dependencies.toml").read_bytes(), parse with tomllib, hash the unmodified bytes, normalize distribution equality with packaging-style lower/dash normalization implemented locally, and sort all public projections. Implement and test a strict SemVer parser for profile_version. Schema 1 accepts only `hosted_python = "3.13"` and `debugger_python = ">=3.12"`; do not silently interpret arbitrary specifier syntax.

The parent process must not satisfy metadata using its own environment. Launch one isolated target-interpreter process:

~~~python
[
    python_executable,
    "-I",
    "-m",
    "hushine_strategy.runtime_dependencies",
    "_probe-installed",
    "--python-constraint",
    python_constraint,
    "--json",
]
~~~

That single process verifies its own `sys.version_info`, requires importlib.metadata.version(distribution), imports every probe in manifest order, and returns its packaged profile digest plus sorted failures. `probe_runtime_dependency_profile` validates that returned digest against the caller's profile. Hosted callers pass `3.13`; debugger callers pass `>=3.12`. Return safe exception class/message text only; do not include environment variables or sys.path in JSON. Add a regression with a fake caller metadata environment and a different target executable to prove neither Python version nor distribution metadata can be borrowed from the caller.

- [ ] **Step 5: Add package data and the JSON CLI**

Add:

~~~toml
[tool.setuptools.package-data]
hushine_strategy = ["runtime_dependencies.toml"]
~~~

Support:

~~~bash
python -m hushine_strategy.runtime_dependencies show --json
python -m hushine_strategy.runtime_dependencies verify-installed \
  --python-constraint 3.13 --json
~~~

`show` exits 0 with name/version/digest, Python constraints, sorted roots, and dependency mappings. `verify-installed` performs version, installed-metadata, and import checks in that exact process, exits 0 with the same profile plus ok=true, or exits 1 with ok=false and failures. `_probe-installed` is the same implementation used by the public API and is not documented as an operator command.

- [ ] **Step 6: Prove source and wheel resource behavior**

Run:

~~~bash
cd strategy-library
before_status="$(git status --porcelain=v1 --untracked-files=all)"
test ! -e uv.lock
wheel_root="$(mktemp -d)"
trap 'rm -rf "$wheel_root"' EXIT
uv run --isolated --no-project --with-editable '.[test]' pytest tests/hushine_strategy/test_runtime_dependencies.py -q
uv build --wheel --out-dir "$wheel_root/wheels"
wheel="$(find "$wheel_root/wheels" -maxdepth 1 -type f -name '*.whl' -print -quit)"
test -n "$wheel"
python -c 'import sys,zipfile; z=zipfile.ZipFile(sys.argv[1]); assert any(n.endswith("hushine_strategy/runtime_dependencies.toml") for n in z.namelist())' "$wheel"
test ! -e uv.lock
after_status="$(git status --porcelain=v1 --untracked-files=all)"
test "$after_status" = "$before_status"
~~~

Expected: pytest passes and the wheel assertion exits 0; no `dist/`, `uv.lock`,
egg-info, cache, or other repository artifact is created by this proof.

- [ ] **Step 7: Commit only the library manifest/loader unit**

~~~bash
cd strategy-library
git add hushine_strategy/runtime_dependencies.toml hushine_strategy/runtime_dependencies.py hushine_strategy/__init__.py pyproject.toml tests/hushine_strategy/test_runtime_dependencies.py
git commit -m "feat: package runtime dependency profile"
~~~

### Task 2: Add the Deterministic Project, Lock, Baseline, and Environment Checker

**Files:**
- Create: strategy-library/scripts/check_runtime_dependency_contract.py
- Create: strategy-library/tests/test_runtime_dependency_contract.py

**Interfaces:**
- Consumes: RuntimeDependencyProfile, a product pyproject.toml, product uv.lock, optional resolvable baseline Git ref, and optional exact Python executable.
- Produces: deterministic marked pyproject projections, ContractViolation/ContractNotice records, and a command that exits 0 only when generated direct dependencies, lock entries, first-introduction or monotonic profile-version evolution, target-interpreter metadata, and real probes close.

- [ ] **Step 1: Write failing pure checker tests**

Use temporary TOML/lock fixtures and assert exact codes:

~~~python
def test_transitive_dependency_does_not_satisfy_direct_projection(tmp_path):
    project, lock = write_project(
        tmp_path,
        direct=["pandas>=2"],
        locked=["pandas", "numpy"],
    )
    violations = check_project_projection(profile_for("numpy"), "debugger", project, lock)
    assert [v.code for v in violations] == ["MISSING_DIRECT_DISTRIBUTION"]

def test_manifest_change_requires_profile_version_change():
    before = manifest_bytes(version="1.0.0", roots=["numpy"])
    after = manifest_bytes(version="1.0.0", roots=["numpy", "pandas"])
    assert [v.code for v in check_profile_change(before, after)] == [
        "PROFILE_VERSION_NOT_BUMPED"
    ]

def test_manifest_change_requires_strictly_greater_semver():
    before = manifest_bytes(version="1.2.0", roots=["numpy"])
    after = manifest_bytes(version="1.1.9", roots=["numpy", "pandas"])
    assert [v.code for v in check_profile_change(before, after)] == [
        "PROFILE_VERSION_NOT_GREATER"
    ]

def test_first_introduction_at_existing_ref_accepts_only_schema_1_bytes(tmp_path):
    repo = git_repo_with_commit(tmp_path, files={"README.md": "before\n"})
    result = check_baseline(repo, "HEAD", exact_schema_1_manifest_bytes())
    assert result.violations == ()
    assert [notice.code for notice in result.notices] == [
        "BASELINE_MANIFEST_ABSENT"
    ]

def test_projection_write_is_manifest_derived_and_idempotent(tmp_path):
    project = write_marked_project(tmp_path, direct=["internal-tool>=1"])
    sync_project_projection(profile_for("numpy", "pandas"), project)
    once = project.read_bytes()
    sync_project_projection(profile_for("numpy", "pandas"), project)
    assert project.read_bytes() == once
    assert read_generated_names(project) == {"numpy", "pandas"}

def test_lock_must_contain_direct_distribution(tmp_path):
    project, lock = write_project(tmp_path, direct=["numpy>=1.26"], locked=[])
    assert [v.code for v in check_project_projection(
        profile_for("numpy"), "service", project, lock
    )] == ["DISTRIBUTION_NOT_LOCKED"]
~~~

Also cover malformed lock, stale uv lock by running uv lock --check, missing/duplicate/out-of-marker projection, extra internal dependencies not becoming public, deterministic distribution ordering, marker corruption, check-mode drift, baseline unchanged, an unresolved baseline ref as CLI error, an existing ref with no manifest path as the one-time notice, a non-exact current manifest on first introduction as INVALID_INITIAL_CONTRACT, metadata missing, wrong interpreter Python version, caller/target interpreter disagreement, sanitized-env canaries, and probe failure.

- [ ] **Step 2: Run focused tests and verify RED**

~~~bash
cd strategy-library
uv run --isolated --no-project --with-editable '.[test]' pytest tests/test_runtime_dependency_contract.py -q
~~~

Expected: import fails because scripts/check_runtime_dependency_contract.py does not exist.

- [ ] **Step 3: Implement deterministic checker functions**

Expose:

~~~python
@dataclass(frozen=True)
class ContractViolation:
    code: str
    project: str
    distribution: str = ""
    message: str = ""

def check_project_projection(
    profile: RuntimeDependencyProfile,
    project_name: str,
    pyproject_path: Path,
    lock_path: Path,
) -> tuple[ContractViolation, ...]: ...

def check_profile_change(
    baseline_manifest: bytes,
    current_manifest: bytes,
) -> tuple[ContractViolation, ...]: ...

def sync_project_projection(
    profile: RuntimeDependencyProfile,
    pyproject_path: Path,
    *,
    write: bool = False,
) -> tuple[ContractViolation, ...]: ...

def check_installed_projection(
    profile: RuntimeDependencyProfile,
    python_executable: str,
    expected_python: str,
) -> tuple[ContractViolation, ...]: ...
~~~

The checker reserves these comments inside each `[project].dependencies` array and owns only the lines between them:

~~~toml
# BEGIN GENERATED RUNTIME DEPENDENCY PROJECTION
"numpy",
# END GENERATED RUNTIME DEPENDENCY PROJECTION
~~~

`--write-projections` renders one bare PEP 508 requirement per loader-sorted public distribution; the committed uv.lock supplies reproducibility. It neither rewrites TOML outside the marked block nor owns internal dependencies. Ordinary check mode computes the same bytes in memory and emits PROJECTION_NOT_GENERATED if the file is not already identical. Parse all direct requirement names, normalize names consistently, reject a public name outside the generated block, parse top-level uv.lock package names, and invoke `uv lock --check --project PROJECT_DIR`.

For `--baseline-ref REF`, first discover the manifest repository root with `git rev-parse --show-toplevel`; never append a second `strategy-library` path to the current working directory. Resolve `REF^{commit}`. If the ref cannot resolve, exit 2. If it resolves, attempt the equivalent of:

~~~bash
git -C "$MANIFEST_REPOSITORY_ROOT" show \
  "$BASELINE_REF:hushine_strategy/runtime_dependencies.toml"
~~~

There are exactly two valid states:

1. The path exists: parse both profiles. If bytes differ, current profile_version must be valid SemVer and strictly greater than the baseline version; otherwise emit PROFILE_VERSION_NOT_BUMPED or PROFILE_VERSION_NOT_GREATER.
2. The commit exists but the path does not: emit the non-failing notice BASELINE_MANIFEST_ABSENT and require the current bytes, schema/version, and digest to equal Task 1 exactly. Any other current bytes emit INVALID_INITIAL_CONTRACT.

Do not make Git history a Runtime image requirement: build-time calls omit `--baseline-ref` but still check schema/project/lock/installed closure.

Installed checking launches exactly one JSON probe child under `python_executable`. That child checks `sys.version_info`, loads installed distribution metadata, imports every probe, and returns the packaged manifest bytes/digest it sees. The parent does not call importlib.metadata or import any probe itself. Supply only the target invocation's allowlisted environment plus `PATH`, `HOME`, locale, and required runtime build facts; explicitly remove inherited PYTHONPATH, PYTHONHOME, VIRTUAL_ENV, UV_PROJECT_ENVIRONMENT, database, Kafka, core/order endpoints, tokens, and credentials. Tests set poisoned caller values for each removed variable and require the child not to observe them.

- [ ] **Step 4: Add stable CLI arguments and output**

The command contract is:

~~~bash
python scripts/check_runtime_dependency_contract.py \
  --service-project ../strategy-service/pyproject.toml \
  --service-lock ../strategy-service/uv.lock \
  --debugger-project ../strategy-debugger-cli/pyproject.toml \
  --debugger-lock ../strategy-debugger-cli/uv.lock \
  --baseline-ref "$RUNTIME_DEPENDENCY_BASE_SHA" \
  --json
~~~

Add mutually exclusive `--write-projections` and `--baseline-only`, plus repeatable `--installed-python NAME=PATH` and required matching `--installed-python-version NAME=CONSTRAINT`. Write mode updates only marked blocks and exits after reparsing them; baseline-only requires no product paths and exercises only Git evolution semantics. Service image checks pass `3.13`; debugger checks pass `>=3.12`. JSON contains profile, digest, baseline `{ref, commit, state}`, checked projects/interpreters, ok, and sorted notices/violations. Exit 2 for CLI/configuration errors, 1 for contract violations, and 0 when only BASELINE_MANIFEST_ABSENT is present.

- [ ] **Step 5: Run checker unit tests and the loader suite**

~~~bash
cd strategy-library
uv run --isolated --no-project --with-editable '.[test]' pytest tests/test_runtime_dependency_contract.py tests/hushine_strategy/test_runtime_dependencies.py -q
~~~

Expected: all tests pass.

Then prove the real first-rollout baseline from the immutable pre-implementation commit recorded before Task 1; do not default to `origin/main` or any moving ref:

~~~bash
cd strategy-library
test "${#RUNTIME_DEPENDENCY_BASE_SHA}" -eq 40
git cat-file -e "$RUNTIME_DEPENDENCY_BASE_SHA^{commit}"
set +e
uv run --isolated --no-project --with-editable '.[test]' python scripts/check_runtime_dependency_contract.py \
  --baseline-only \
  --baseline-ref "$RUNTIME_DEPENDENCY_BASE_SHA" \
  --json > /tmp/runtime-dependency-baseline.json
checker_status=$?
set -e
test "$checker_status" -eq 0
python -c 'import json; d=json.load(open("/tmp/runtime-dependency-baseline.json")); assert d["ok"] is True; assert d["baseline"]["state"] == "introduced"; assert [n["code"] for n in d["notices"]] == ["BASELINE_MANIFEST_ABSENT"]'
~~~

This first-rollout proof must be exactly `introduced`; `present` is accepted
only by the later post-push steady-state gate against the final published
library SHA. A pre-implementation SHA that already contains the manifest is the
wrong baseline and fails here.

On the first rollout, expected baseline state is `introduced`, exit is 0, and notices contains BASELINE_MANIFEST_ABSENT. After coordinated delivery, the full-system gate passes the exact published cleanup-branch strategy-library SHA as baseline and must report `present`; later changes compare to an explicitly selected immutable deployed SHA and enforce strictly increasing SemVer. A moving/default branch is never silently substituted.

- [ ] **Step 6: Commit the checker**

~~~bash
cd strategy-library
git add scripts/check_runtime_dependency_contract.py tests/test_runtime_dependency_contract.py
git commit -m "test: enforce runtime dependency projections"
~~~

### Task 3: Lock the Public Distributions in strategy-service and strategy-debugger-cli

**Files:**
- Modify: strategy-service/pyproject.toml
- Modify generated lock: strategy-service/uv.lock
- Modify: strategy-debugger-cli/pyproject.toml
- Create generated lock: strategy-debugger-cli/uv.lock
- Create: strategy-debugger-cli/scripts/with-local-strategy-library-git.sh
- Modify: strategy-service/Makefile
- Create: strategy-service/tests/test_runtime_dependency_projection.py
- Create: strategy-debugger-cli/tests/test_dependency_projection.py

**Interfaces:**
- Consumes: manifest public_distributions, the Task 2 projection writer, the committed strategy-library revision, and each product project/lock.
- Produces: manifest-generated direct projections, a local-source service lock, a standalone immutable-Git debugger lock, and frozen Python-compatible installations for Hosted 3.13 and debugger 3.12+.

- [ ] **Step 1: Write product-level projection tests before editing dependencies**

In each repository import the checker from ../strategy-library and compare normalized direct/locked names to `profile.public_distributions`. Do not spell public names in these product tests. Generate a transitive-only fixture by moving the first loader-selected public distribution outside the marked direct block while leaving it in the synthetic lock; assert MISSING_DIRECT_DISTRIBUTION for that loader-selected name. Both tests also assert that check-mode projection regeneration is a no-op.

~~~python
def test_every_public_distribution_is_direct_and_locked():
    violations = check_project_projection(
        load_runtime_dependency_profile(),
        "strategy-service",
        ROOT / "pyproject.toml",
        ROOT / "uv.lock",
    )
    assert violations == ()
~~~

- [ ] **Step 2: Run tests and verify RED**

~~~bash
cd strategy-service
uv sync --python 3.13 --frozen --extra dev
PYTHONPATH=.:../strategy-library uv run --frozen --extra dev pytest tests/test_runtime_dependency_projection.py -q
cd ../strategy-debugger-cli
uv run --isolated --no-project --with-editable '.[test]' pytest tests/test_dependency_projection.py -q
~~~

Expected: both tests report the loader-derived missing-direct set; debugger additionally reports its missing lock. Failure assertions derive names and counts from the manifest rather than embedding an expected public list.

- [ ] **Step 3: Add exact direct dependency projections**

Add the Task 2 marker block to both `[project].dependencies` arrays, remove every manifest-owned distribution from outside that block, and render both blocks from the manifest:

~~~bash
cd strategy-library
uv run --isolated --no-project --with-editable '.[test]' python scripts/check_runtime_dependency_contract.py \
  --write-projections \
  --service-project ../strategy-service/pyproject.toml \
  --debugger-project ../strategy-debugger-cli/pyproject.toml
~~~

Expected: each block contains the loader-sorted bare distribution names and a second identical command changes no bytes. Internal dependencies stay present outside the block and do not enter the manifest. The committed locks, not duplicated hand-written lower bounds, pin concrete versions for these two application environments.

In `strategy-service/pyproject.toml`, replace the mutable Git-`main` requirement for the shared SDK with a normal direct requirement and a sibling source override:

~~~toml
"hushine-strategy-library>=0.1.0"

[tool.uv.sources]
hushine-strategy-library = { path = "../strategy-library" }
~~~

Do not mark the image dependency editable. The relative source resolves both in the sibling-repository worktree and in the Docker layout `/app/strategy-service` plus `/app/strategy-library`. Extend the service projection test to assert that the old `git+ssh://...@main` source is absent and the lock records the local source; this binds the installed SDK to the library tree whose commit becomes an image fact.

The debugger must remain bootstrappable from a clone containing only `strategy-debugger-cli`. Remove its sibling path override and pin `hushine-strategy-library` to the exact Task 1/2 commit through the existing HTTPS repository. That commit is intentionally not pushed yet, so never assume GitHub can fetch it and never push it early. Add `scripts/with-local-strategy-library-git.sh SOURCE_REPO COMMAND...`: it clones SOURCE_REPO to a private temporary bare mirror, verifies the requested 40-character commit exists, and runs COMMAND with process-local Git config `url.file://MIRROR.insteadOf=https://github.com/hushine-tech/strategy-library.git` plus `GIT_ALLOW_PROTOCOL=file:https`. It changes no user/global Git config and removes the mirror on exit.

~~~bash
cd /Users/xdy/Workplace/hushine-worktrees/medium-cleanup/strategy-debugger-cli
LIBRARY_COMMIT="$(git -C ../strategy-library rev-parse HEAD)"
test "${#LIBRARY_COMMIT}" -eq 40
./scripts/with-local-strategy-library-git.sh ../strategy-library \
  uv add --no-sync "hushine-strategy-library @ git+https://github.com/hushine-tech/strategy-library.git@${LIBRARY_COMMIT}"
~~~

The rewrite changes transport only. The resulting `pyproject.toml`/`uv.lock` must contain the canonical HTTPS URL and immutable 40-character revision, and no file URL, mirror path, `../strategy-library` path, editable source, branch, or tag. Unit-test mirror cleanup on success/failure. Add a debugger projection test that copies only the debugger repository fixture and proves `uv lock --check` resolves through an explicitly supplied mirror without a sibling checkout.

- [ ] **Step 4: Regenerate and verify both locks**

~~~bash
cd strategy-service
uv lock
uv lock --check
uv sync --python 3.13 --frozen --extra dev
cd ../strategy-debugger-cli
./scripts/with-local-strategy-library-git.sh ../strategy-library uv lock
./scripts/with-local-strategy-library-git.sh ../strategy-library uv lock --check
./scripts/with-local-strategy-library-git.sh ../strategy-library \
  uv sync --frozen --extra test
~~~

Expected: every lock/sync command exits 0; strategy-debugger-cli/uv.lock is newly tracked and contains no mirror/file path.

- [ ] **Step 5: Wire a service Make target and run the product tests**

Add dependency-contract to strategy-service/Makefile:

~~~make
dependency-contract:
	uv sync --python 3.13 --frozen --extra dev
	PYTHONPATH=../strategy-library uv run --frozen \
		python ../strategy-library/scripts/check_runtime_dependency_contract.py \
		--service-project pyproject.toml --service-lock uv.lock \
		--installed-python strategy-service=.venv/bin/python \
		--installed-python-version strategy-service=3.13
~~~

Run:

~~~bash
cd strategy-service
PYTHONPATH=.:../strategy-library uv run --frozen --extra dev pytest tests/test_runtime_dependency_projection.py -q
make dependency-contract
cd ../strategy-debugger-cli
./scripts/with-local-strategy-library-git.sh ../strategy-library \
  uv run --frozen --extra test pytest tests/test_dependency_projection.py -q
~~~

Expected: all commands pass. Confirm uv lock --check leaves both worktrees unchanged.

- [ ] **Step 6: Commit independently in each product repository**

~~~bash
cd strategy-service
git add pyproject.toml uv.lock Makefile tests/test_runtime_dependency_projection.py
git commit -m "build: lock runtime dependency contract"
cd ../strategy-debugger-cli
git add pyproject.toml uv.lock scripts/with-local-strategy-library-git.sh tests/test_dependency_projection.py
git commit -m "build: lock debugger runtime dependencies"
~~~

### Task 4: Converge Hosted and Offline Static Dependency Validation

**Files:**
- Create: strategy-library/hushine_strategy/import_validation.py
- Modify: strategy-library/hushine_strategy/validator.py
- Modify: strategy-library/hushine_strategy/__init__.py
- Create: strategy-library/tests/hushine_strategy/test_import_validation.py
- Modify: strategy-library/tests/hushine_strategy/test_validator.py
- Modify: strategy-service/strategy_service/runtime_profile.py
- Modify: strategy-service/strategy_service/strategy_validator.py
- Create: strategy-service/tests/test_runtime_profile.py
- Modify: strategy-service/tests/test_strategy_validator.py

**Interfaces:**
- Consumes: parsed AST, caller-owned standard-library roots, safe platform prefixes, packaged public profile, and an injectable module finder.
- Produces: ImportedModule and DependencyValidationIssue values with stable dependency codes; Hosted RuntimeProfile carrying name, version, digest, Python constraint, build facts, and sorted public roots.

- [ ] **Step 1: Write the shared validator contract tests**

Cover all eight roots individually, all excluded algorithm/tool roots individually, dotted allowed modules, missing allowed submodules, relative imports, and caller-specific standard-library policy:

~~~python
@pytest.mark.parametrize(
    "root",
    load_runtime_dependency_profile().public_import_roots,
)
def test_each_manifest_root_is_allowed(root):
    tree = ast.parse(f"import {root}")
    assert validate_dependency_imports(
        tree,
        profile=load_runtime_dependency_profile(),
        stdlib_roots=frozenset(),
        platform_prefixes=("hushine_strategy",),
        finder=lambda name: object(),
    ) == ()

@pytest.mark.parametrize("module", [
    "scipy", "sklearn", "statsmodels", "pandas_ta", "ta",
    "coverage", "debugpy", "pytest", "pyarrow", "zstandard",
])
def test_non_contract_modules_are_not_public(module):
    issues = validate_dependency_imports(
        ast.parse(f"import {module}"),
        profile=load_runtime_dependency_profile(),
        stdlib_roots=frozenset(),
        platform_prefixes=(),
        finder=lambda name: object(),
    )
    assert [(issue.code, issue.module) for issue in issues] == [
        ("UNSUPPORTED_STRATEGY_DEPENDENCY", module)
    ]

def test_allowed_root_with_missing_complete_path_is_unavailable():
    issues = validate_dependency_imports(
        ast.parse("from google.cloud import storage"),
        profile=load_runtime_dependency_profile(),
        stdlib_roots=frozenset(),
        platform_prefixes=(),
        finder=lambda name: None if name == "google.cloud" else object(),
    )
    assert [(issue.code, issue.module) for issue in issues] == [
        ("STRATEGY_DEPENDENCY_UNAVAILABLE", "google.cloud")
    ]
~~~

The import collector records alias.name for ast.Import and node.module for absolute ast.ImportFrom; it never treats imported symbols such as pandas.DataFrame as submodules. A finder exception is converted to unavailable with a safe message.

- [ ] **Step 2: Run shared tests and verify RED**

~~~bash
cd strategy-library
uv run --isolated --no-project --with-editable '.[test]' pytest tests/hushine_strategy/test_import_validation.py tests/hushine_strategy/test_validator.py -q
~~~

Expected: the new module is missing; existing tests also show requests is falsely rejected and scipy/pandas_ta are falsely accepted.

- [ ] **Step 3: Implement the shared import-validation API**

Expose these immutable interfaces:

~~~python
@dataclass(frozen=True)
class ImportedModule:
    module: str
    root: str
    line: int

@dataclass(frozen=True)
class DependencyValidationIssue:
    code: str
    module: str
    line: int
    message: str

def iter_imported_modules(tree: ast.AST) -> tuple[ImportedModule, ...]: ...

def validate_dependency_imports(
    tree: ast.AST,
    *,
    profile: RuntimeDependencyProfile,
    stdlib_roots: AbstractSet[str],
    platform_prefixes: tuple[str, ...],
    finder: Callable[[str], object | None] = importlib.util.find_spec,
) -> tuple[DependencyValidationIssue, ...]: ...
~~~

Permission is decided only by the top-level root. Availability is decided using the complete ImportedModule.module. Sort issues by line, module, and code and deduplicate identical AST paths so Hosted and debugger results are byte-stable.

- [ ] **Step 4: Refactor the library validator without weakening safety rules**

Remove the manually maintained third-party names from ALLOWED_IMPORT_ROOTS and remove requests from FORBIDDEN_IMPORT_ROOTS. Keep its existing limited standard-library roots, relative-import rejection, __builtins__ checks, forbidden-call alias tracking, and MyStrategy requirement. Map shared dependency issues into existing ValidationIssue fields without changing unrelated safety codes.

Update assertions so:

~~~python
assert validate_strategy_code("import requests\nclass MyStrategy: pass").issues == []
assert dependency_codes("import scipy\nclass MyStrategy: pass") == [
    "UNSUPPORTED_STRATEGY_DEPENDENCY"
]
assert dependency_codes(
    "import pandas.io.common\nclass MyStrategy: pass"
) == []
~~~

The dotted pandas import passes only when the finder resolves pandas.io.common.

- [ ] **Step 5: Replace strategy-service constants with a shared profile adapter**

RuntimeProfile has exact fields:

~~~python
@dataclass(frozen=True)
class RuntimeProfile:
    name: str
    version: str
    contract_sha256: str
    hosted_python: str
    allowed_third_party_modules: tuple[str, ...]
    strategy_service_commit: str
    strategy_library_commit: str
    image_build_id: str
~~~

current_runtime_profile() loads the packaged profile on each process through a cached, immutable loader and reads build facts from HUSHINE_RUNTIME_STRATEGY_SERVICE_COMMIT, HUSHINE_RUNTIME_STRATEGY_LIBRARY_COMMIT, and HUSHINE_RUNTIME_IMAGE_BUILD_ID. Missing build vars use the literal local-dev only outside a packaged Runtime image; Task 9 makes image startup fail when embedded facts are absent.

Refactor strategy_service/strategy_validator.py to call validate_dependency_imports with sys.stdlib_module_names and platform prefixes strategy_service.types and hushine_strategy, then append its existing INPUTS, ORDER_TARGETS, risk, and OrderDecision checks. Replace lowercase dependency-only codes with the stable uppercase forms while preserving existing declaration codes.

- [ ] **Step 6: Prove Hosted/library equality and non-expansion**

~~~bash
cd strategy-library
uv run --isolated --no-project --with-editable '.[test]' pytest tests/hushine_strategy/test_import_validation.py tests/hushine_strategy/test_validator.py -q
cd ../strategy-service
PYTHONPATH=.:../strategy-library uv run --frozen --extra dev pytest \
  tests/test_runtime_profile.py tests/test_strategy_validator.py -q
~~~

Expected: both suites pass and the service assertion compares its sorted public modules directly to load_runtime_dependency_profile().public_import_roots.

- [ ] **Step 7: Commit shared and service changes separately**

~~~bash
cd strategy-library
git add hushine_strategy/import_validation.py hushine_strategy/validator.py hushine_strategy/__init__.py tests/hushine_strategy/test_import_validation.py tests/hushine_strategy/test_validator.py
git commit -m "refactor: share strategy dependency validation"
cd ../strategy-service
git add strategy_service/runtime_profile.py strategy_service/strategy_validator.py tests/test_runtime_profile.py tests/test_strategy_validator.py
git commit -m "refactor: consume shared runtime profile"
~~~

### Task 5: Gate Complete Module Resolution and Import Initialization Before User Code

**Files:**
- Create: strategy-service/strategy_service/strategy_imports.py
- Modify: strategy-service/strategy_service/strategy/base.py
- Modify: strategy-service/strategy_service/grpc_server.py
- Create: strategy-service/tests/test_strategy_imports.py
- Modify: strategy-service/tests/test_grpc_server.py

**Interfaces:**
- Consumes: validated strategy source, current RuntimeProfile, and the exact worker Python executable.
- Produces: StrategyDependencyError with stable fields, StrategySourceGateResult preserving both validation issues and typed dependency detail, resolve_strategy_imports(), and probe_strategy_imports() which execute no user statements other than Python import statements.

- [ ] **Step 1: Write failure-classification and no-user-code tests**

Create an importable test package whose __init__ raises RuntimeError and inject it through the test path. Assert:

~~~python
def test_missing_allowed_submodule_is_unavailable():
    error = resolve_strategy_imports(
        "import google.hushine_missing\nraise AssertionError('must not execute')",
        finder=lambda name: None if name == "google.hushine_missing" else object(),
        profile=test_profile(),
    )
    assert error.code == "STRATEGY_DEPENDENCY_UNAVAILABLE"
    assert error.module == "google.hushine_missing"

def test_import_initialization_failure_is_distinct(tmp_path):
    result = probe_strategy_imports(
        "import broken_allowed\nraise AssertionError('user body executed')",
        python_executable=sys.executable,
        profile=profile_with_root("broken_allowed"),
        extra_python_path=(str(tmp_path),),
    )
    assert result.code == "STRATEGY_IMPORT_FAILED"
    assert result.module == "broken_allowed"
    assert "user body executed" not in result.message
~~~

Add three distinct fixtures/tests:

1. The requested complete module or one of its parent packages is absent (`requested=google.cloud`, `missing=google.cloud` or `missing=google`): STRATEGY_DEPENDENCY_UNAVAILABLE, reporting only `google.cloud`.
2. The requested module is found, but its initialization imports an unrelated absent transitive module (`requested=broken_allowed`, `missing=private_transitive`): STRATEGY_IMPORT_FAILED, reporting only `broken_allowed`; the internal missing name appears only in redacted server logs.
3. A distribution/probe required by the packaged profile is absent before strategy validation: the Task 1 installed probe fails and Task 10 maps startup to RUNTIME_DEPENDENCY_PROFILE_INVALID; no Preview/Run worker or StrategyDependencyError is created.

Also assert syntax and unsupported dependency are returned before subprocess creation, subprocess timeout is STRATEGY_IMPORT_FAILED, traceback/path/internal-missing text is absent from safe messages, the caller's PYTHONPATH/venv cannot leak into the child, and manifest-rendered all-public imports succeed.

- [ ] **Step 2: Run focused tests and verify RED**

~~~bash
cd strategy-service
PYTHONPATH=.:../strategy-library uv run --frozen --extra dev pytest tests/test_strategy_imports.py -q
~~~

Expected: ModuleNotFoundError for strategy_service.strategy_imports.

- [ ] **Step 3: Implement typed errors and an import-only child probe**

Use:

~~~python
@dataclass(frozen=True)
class StrategyDependencyError(Exception):
    code: str
    module: str
    runtime_profile: str
    runtime_profile_version: str
    image_build_id: str
    message: str

@dataclass(frozen=True)
class StrategySourceGateResult:
    ok: bool
    issues: tuple[ValidationIssue, ...]
    dependency_error: StrategyDependencyError | None = None

def resolve_strategy_imports(
    source: str,
    *,
    profile: RuntimeProfile | None = None,
    finder: Callable[[str], object | None] = importlib.util.find_spec,
) -> StrategyDependencyError | None: ...

def probe_strategy_imports(
    source: str,
    *,
    python_executable: str = sys.executable,
    profile: RuntimeProfile | None = None,
    timeout_seconds: float = 15.0,
    extra_python_path: tuple[str, ...] = (),
) -> StrategyDependencyError | None: ...
~~~

`extra_python_path` exists only for hermetic fixture tests; production call sites always pass the default empty tuple. Build a new ast.Module containing only copied ast.Import and absolute ast.ImportFrom nodes, compile each requested module import separately in manifest/source order, and execute it in one sanitized child interpreter. The child emits one JSON object containing the requested module, whether static resolution found it, exception class, and (for diagnostics only) ModuleNotFoundError.name.

Classification is strict: ModuleNotFoundError is STRATEGY_DEPENDENCY_UNAVAILABLE only when `missing_name == requested_module` or `requested_module.startswith(missing_name + ".")`, meaning the requested full path or a parent package is absent. If the requested module was found but initialization lacks a child/unrelated transitive import, classify STRATEGY_IMPORT_FAILED. Every other import-time exception is also STRATEGY_IMPORT_FAILED. Profile-declared distribution/probe absence belongs to the startup verifier and becomes RUNTIME_DEPENDENCY_PROFILE_INVALID before any strategy request. Log exception type, internal missing name, and redacted traceback server-side, but construct the user message only from requested-module/profile facts; never expose the transitive module name.

- [ ] **Step 4: Put the gate immediately before all user-code load sites**

In grpc_server.py create one helper used by source validation, Preview, and Run:

~~~python
def _validate_and_probe_strategy_source(code: str) -> StrategySourceGateResult:
    static = validate_strategy_code(code)
    if not static.ok:
        return gate_result_from_static_validation(static)
    if dependency_error := resolve_strategy_imports(code):
        return gate_result_from_dependency_error(dependency_error)
    if dependency_error := probe_strategy_imports(code):
        return gate_result_from_dependency_error(dependency_error)
    return StrategySourceGateResult(ok=True, issues=())
~~~

`gate_result_from_static_validation` maps the first deterministically sorted issue with one of the dependency codes into `dependency_error` while retaining the full issue tuple; syntax/declaration-only failures leave dependency_error unset. Call the helper after code retrieval but before extract_strategy_declarations(), exec(), Session creation, background task insertion, or running progress. Preview/Run must attach `gate.dependency_error` to their gRPC/worker failure path rather than converting only `gate.issues[0].message` into a generic validation error. Validate returns all issues and the profile. In strategy/base.py re-raise StrategyDependencyError unchanged and wrap only non-dependency load exceptions. Do not return a generic ImportError for known dependency failures.

- [ ] **Step 5: Add lifecycle assertions around Preview and Run**

Extend tests/test_grpc_server.py with fakes that record create_session, task creation, status updates, context details, and worker state. For unsupported static, unavailable requested-path/parent ModuleNotFoundError, transitive ModuleNotFoundError import-failed, and other import-failed cases assert no session ID was allocated, no task was inserted, no running status was written, and `StrategySourceGateResult.dependency_error` reaches the RPC context with exact fields. A declaration-only validation error remains an ordinary validation response.

- [ ] **Step 6: Run focused and adjacent Python tests**

~~~bash
cd strategy-service
PYTHONPATH=.:../strategy-library uv run --frozen --extra dev pytest \
  tests/test_strategy_imports.py \
  tests/test_strategy_validator.py \
  tests/test_strategy_validation_preflight.py \
  tests/test_grpc_server.py \
  tests/test_strategy_phase3_declarations.py -q
~~~

Expected: all tests pass.

- [ ] **Step 7: Commit the pre-execution gate**

~~~bash
cd strategy-service
git add strategy_service/strategy_imports.py strategy_service/strategy/base.py strategy_service/grpc_server.py tests/test_strategy_imports.py tests/test_grpc_server.py
git commit -m "fix: reject unavailable strategy imports before execution"
~~~

### Task 6: Make Debugger Bootstrap Lock-Driven and Profile-Aware

**Files:**
- Modify: strategy-debugger-cli/pyproject.toml
- Modify generated lock: strategy-debugger-cli/uv.lock
- Modify: strategy-debugger-cli/init.py
- Create: strategy-debugger-cli/scripts/bootstrap-standalone.test.sh
- Create: strategy-debugger-cli/src/hushine_debugger/runtime_profile.py
- Modify: strategy-debugger-cli/src/hushine_debugger/cli.py
- Modify: strategy-debugger-cli/src/hushine_debugger/init_workspace.py
- Modify: strategy-debugger-cli/src/hushine_debugger/replay.py
- Create: strategy-debugger-cli/tests/test_runtime_profile.py
- Modify: strategy-debugger-cli/tests/test_cli.py
- Modify: strategy-debugger-cli/tests/test_workspace.py
- Modify: strategy-debugger-cli/tests/test_replay_cli.py

**Interfaces:**
- Consumes: a standalone strategy-debugger-cli checkout, its committed uv.lock with immutable strategy-library Git source, a Python 3.12+ bootstrap interpreter, workspace interpreter, and shared validator.
- Produces: a staged/atomic workspace venv, ensure_workspace_runtime_profile(), profile JSON output, deterministic sync, and the same dependency code/module/profile facts as Hosted without requiring a sibling repository.

- [ ] **Step 1: Write debugger profile and workspace failure tests**

Tests must prove:

~~~python
def test_profile_json_matches_shared_manifest(cli_runner):
    result = cli_runner("profile", "--json")
    body = json.loads(result.stdout)
    assert body["profile_name"] == "platform-python-3.13"
    assert body["profile_version"] == "1.0.0"
    assert body["contract_sha256"] == load_runtime_dependency_profile().contract_sha256
    assert body["public_import_roots"] == list(
        load_runtime_dependency_profile().public_import_roots
    )

def test_workspace_preflight_names_missing_hosted_dependency(monkeypatch):
    monkeypatch.setattr(runtime_profile, "probe_runtime_dependency_profile", lambda **_: (
        DependencyProbeFailure("grpc", "grpcio", "grpc", "not installed"),
    ))
    with pytest.raises(DebuggerRuntimeProfileError) as exc:
        ensure_workspace_runtime_profile(Path("/workspace/.venv/bin/python"))
    assert exc.value.code == "STRATEGY_DEPENDENCY_UNAVAILABLE"
    assert exc.value.module == "grpc"
~~~

Add a subprocess-command recorder asserting init checks the lock, exports frozen requirements, creates a staging venv, uses uv pip sync, installs only the debugger project with --no-deps, and runs verify-installed in the staging interpreter before atomic replacement. Assert it never installs strategy-library from a local path, never calls pip install without --no-deps, never resolves an unlocked package, and leaves an existing workspace venv byte-for-byte untouched on export/sync/verification failure.

- [ ] **Step 2: Run debugger tests and verify RED**

~~~bash
cd strategy-debugger-cli
./scripts/with-local-strategy-library-git.sh ../strategy-library \
  uv run --frozen --extra test pytest tests/test_runtime_profile.py tests/test_workspace.py tests/test_cli.py tests/test_replay_cli.py -q
~~~

Expected: profile command/module is missing and current bootstrap command assertions fail.

- [ ] **Step 3: Implement exact debugger profile checks**

Expose:

~~~python
@dataclass(frozen=True)
class DebuggerRuntimeProfileError(Exception):
    code: str
    module: str
    runtime_profile: str
    runtime_profile_version: str
    image_build_id: str
    message: str

def ensure_workspace_runtime_profile(
    python_executable: Path,
) -> RuntimeDependencyProfile: ...
~~~

Reject Python below 3.12 before installation and check the workspace interpreter against the manifest's exact schema-1 debugger constraint inside the same installed-metadata/import probe process. image_build_id is local-debugger for CLI errors. Print repair text separately from structured JSON so stable fields do not contain local paths.

- [ ] **Step 4: Replace bootstrap resolution with the committed lock**

Task 3's seed lock predates the shared validator implementation committed in Task 4. Before implementing bootstrap, repin the debugger's immutable Git source to the current strategy-library commit and regenerate the lock:

~~~bash
cd strategy-debugger-cli
LIBRARY_COMMIT="$(git -C ../strategy-library rev-parse HEAD)"
test "${#LIBRARY_COMMIT}" -eq 40
./scripts/with-local-strategy-library-git.sh ../strategy-library \
  uv add --no-sync "hushine-strategy-library @ git+https://github.com/hushine-tech/strategy-library.git@${LIBRARY_COMMIT}"
./scripts/with-local-strategy-library-git.sh ../strategy-library uv lock --check
~~~

This newer Task 4 commit is also intentionally unpublished. Assert again that the lock records only the canonical HTTPS URL/full commit, never the mirror transport.

Assert that this exact commit contains `hushine_strategy/import_validation.py`, `validator.py`, and the packaged manifest. The bootstrap then runs from `Path(__file__).resolve().parent`, requires `pyproject.toml` and `uv.lock` there, and never searches for `../strategy-library`. Its order is exact; `STAGING_VENV` and `WORKSPACE_TEMP` are new private paths on the same filesystem as the destination workspace:

~~~bash
uv lock --check --project strategy-debugger-cli
uv export --frozen --no-dev --no-emit-project \
  --project strategy-debugger-cli \
  --output-file WORKSPACE_TEMP/runtime-requirements.txt
uv venv --python BOOTSTRAP_PYTHON STAGING_VENV
uv pip sync --python STAGING_PYTHON WORKSPACE_TEMP/runtime-requirements.txt
uv pip install --python STAGING_PYTHON --no-deps --editable strategy-debugger-cli
STAGING_PYTHON -I -m hushine_strategy.runtime_dependencies \
  verify-installed --python-constraint '>=3.12' --json
~~~

The frozen export includes the immutable-Git strategy-library package repinned in this task (from the Task 3 seed lock); there is no `--no-emit-package` bypass and no subsequent local library install. Only after all commands and `ensure_workspace_runtime_profile(STAGING_PYTHON)` succeed, atomically rename the old `.venv` to a private backup, rename the staging venv to `.venv`, and remove the backup. Roll back the rename on any failure. Always remove temporary/backup paths in `finally`; never mutate the existing working environment in place. The manifest does not authorize per-strategy dependency installation.

- [ ] **Step 5: Prove clean standalone bootstrap on every currently released supported minor**

`scripts/bootstrap-standalone.test.sh --library-repo ../strategy-library` creates a private bare mirror for pre-push transport, then creates a temporary directory, clones/copies only tracked `strategy-debugger-cli` files into `checkout/strategy-debugger-cli`, asserts no sibling `strategy-library` path exists, and runs the documented entrypoint on Python 3.12, 3.13, and 3.14 with isolated uv caches/workspaces. The bootstrap process receives only process-local Git URL-rewrite variables—not the source-repository path:

~~~bash
UV_CACHE_DIR="$TMP/cache-312" HUSHINE_DEBUG_WORKSPACE="$TMP/workspace-312" \
  uv run --no-project --python 3.12 python checkout/strategy-debugger-cli/init.py
"$TMP/workspace-312/.venv/bin/python" -m hushine_debugger.cli profile --json

UV_CACHE_DIR="$TMP/cache-313" HUSHINE_DEBUG_WORKSPACE="$TMP/workspace-313" \
  uv run --no-project --python 3.13 python checkout/strategy-debugger-cli/init.py
"$TMP/workspace-313/.venv/bin/python" -m hushine_debugger.cli profile --json

UV_CACHE_DIR="$TMP/cache-314" HUSHINE_DEBUG_WORKSPACE="$TMP/workspace-314" \
  uv run --no-project --python 3.14 python checkout/strategy-debugger-cli/init.py
"$TMP/workspace-314/.venv/bin/python" -m hushine_debugger.cli profile --json
~~~

On Windows, use `Scripts/python.exe`; the shell test covers POSIX and the Python unit test covers path selection/atomic replacement on Windows. All three profile JSON documents must match the packaged digest and each bootstrap must succeed without reading the parent worktree. Pre-push library transport is only the isolated mirror; distribution network access remains lock-constrained. A second `--offline` run against each populated cache must also succeed. A separate `--network` mode refuses all Git rewrite/mirror variables and is intentionally deferred until the exact library commit has been pushed by the full-system workflow.

- [ ] **Step 6: Gate init completion and every replay**

init_workspace calls ensure_workspace_runtime_profile only after sync succeeds and writes the existing workspace files only after closure passes. replay calls it before source validation/data loading. Map shared validator dependency issues to the same uppercase codes while retaining debugger-specific human repair guidance.

- [ ] **Step 7: Run the complete debugger and shared validator suites**

~~~bash
cd strategy-debugger-cli
./scripts/with-local-strategy-library-git.sh ../strategy-library \
  uv run --frozen --extra test pytest tests/ -q
bash scripts/bootstrap-standalone.test.sh --library-repo ../strategy-library
cd ../strategy-library
uv run --isolated --no-project --with-editable '.[test]' pytest tests/hushine_strategy/test_validator.py tests/hushine_strategy/test_runtime_dependencies.py tests/hushine_strategy/test_import_validation.py -q
~~~

Expected: all tests pass, including requests accepted and internal tools rejected in strategy source.

- [ ] **Step 8: Commit debugger bootstrap/profile behavior**

~~~bash
cd strategy-debugger-cli
git add pyproject.toml uv.lock init.py scripts/with-local-strategy-library-git.sh scripts/bootstrap-standalone.test.sh src/hushine_debugger/runtime_profile.py src/hushine_debugger/cli.py src/hushine_debugger/init_workspace.py src/hushine_debugger/replay.py tests/test_runtime_profile.py tests/test_cli.py tests/test_workspace.py tests/test_replay_cli.py
git commit -m "feat: verify locked debugger runtime profile"
~~~

### Task 7: Define and Regenerate the Typed Dependency Protocol

**Files:**
- Modify: strategy-service/proto/strategy_service.proto
- Modify: strategy-service/proto/runtime_worker.proto
- Modify: control-panel-service/proto/control_panel_service.proto
- Modify: strategy-service/generate_proto.sh
- Modify generated: strategy-service/strategy_service/gen/strategy_service_pb2.py
- Modify generated: strategy-service/strategy_service/gen/strategy_service_pb2_grpc.py
- Modify generated: strategy-service/strategy_service/gen/runtime_worker_pb2.py
- Modify generated: strategy-service/strategy_service/gen/runtime_worker_pb2_grpc.py
- Modify generated: strategy-service/strategy_service/gen/control_panel_service_pb2.py
- Modify generated: strategy-service/strategy_service/gen/control_panel_service_pb2_grpc.py
- Modify generated: strategy-service/gen/strategyv1/strategy_service.pb.go
- Modify generated: strategy-service/gen/strategyv1/strategy_service_grpc.pb.go
- Modify generated: strategy-service/gen/runtimeworkerv1/runtime_worker.pb.go
- Modify generated: strategy-service/gen/runtimeworkerv1/runtime_worker_grpc.pb.go
- Modify generated: strategy-service/gen/controlpanelv1/control_panel_service.pb.go
- Modify generated: strategy-service/gen/controlpanelv1/control_panel_service_grpc.pb.go
- Modify generated: control-panel-service/gen/controlpanelv1/control_panel_service.pb.go
- Modify generated: control-panel-service/gen/controlpanelv1/control_panel_service_grpc.pb.go
- Modify: strategy-service/tests/test_runtime_worker_proto.py
- Create: strategy-service/tests/test_runtime_dependency_proto.py
- Modify: strategy-service/internal/runtimeagent/runtime_channel_proto_test.go
- Modify: control-panel-service/internal/runtimechannel/frame_contract_test.go

**Interfaces:**
- Consumes: shared profile/error facts from Python and Runtime image build metadata.
- Produces: strategy.v1 RuntimeDependencyProfile, RuntimeDependencyError, StrategyValidationIssueProto, ValidateStrategySource RPC; typed worker detail; RuntimeChannel HELLO/RESUME/StreamError detail; and a credential-signed failure-only startup report that cannot register a Runtime.

- [ ] **Step 1: Write generated-contract tests before editing proto**

Python contract assertions:

~~~python
def test_dependency_error_fields_survive_worker_progress():
    detail = strategy_pb2.RuntimeDependencyError(
        code="STRATEGY_DEPENDENCY_UNAVAILABLE",
        module="google.cloud",
        runtime_profile="platform-python-3.13",
        runtime_profile_version="1.0.0",
        image_build_id="build-1",
        message="module unavailable",
    )
    progress = worker_pb2.SessionProgress(
        session_id="s1", status="failed", dependency_error=detail
    )
    assert progress.dependency_error == detail

def test_validate_source_rpc_exists():
    request = strategy_pb2.ValidateStrategySourceRequest(
        source="import numpy", user_id=7, runtime_id="rt-1"
    )
    assert request.runtime_id == "rt-1"

def test_dependency_tags_coexist_with_worker_frame_evolution():
    assert worker_pb2.SessionProgress.DESCRIPTOR.fields_by_name[
        "dependency_error"
    ].number == 6
    assert worker_pb2.PlatformCallResult.DESCRIPTOR.fields_by_name[
        "dependency_error"
    ].number == 5
    frame = worker_pb2.WorkerFrame.DESCRIPTOR
    if "indicator_frame_v2" in frame.fields_by_name:
        assert worker_pb2.WorkerHello.DESCRIPTOR.fields_by_name[
            "protocol_version"
        ].number == 5
        assert worker_pb2.WorkerHello(protocol_version=2).protocol_version == 2
        assert frame.fields_by_name["indicator_frame_v2"].number == 21
        assert descriptor_reserves(frame, 15)
    else:
        assert frame.fields_by_name["indicator_frame"].number == 15
~~~

Go frame test:

~~~go
profile := &strategyv1.RuntimeDependencyProfile{
    SchemaVersion: 1,
    ProfileName: "platform-python-3.13",
    ProfileVersion: "1.0.0",
    ContractSha256: "8457b3c35618558fc8bfc74d4135b7eb52e00c33a8c9a49d202830f3fd5b62c5",
    ImageBuildId: "build-1",
}
frame := &cpv1.RuntimeFrame{Payload: &cpv1.RuntimeFrame_Hello{
    Hello: &cpv1.RuntimeHello{DependencyProfile: profile},
}}
if got := frame.GetHello().GetDependencyProfile().GetImageBuildId(); got != "build-1" {
    t.Fatalf("image build id = %q", got)
}
~~~

- [ ] **Step 2: Run contract tests and verify RED**

~~~bash
cd strategy-service
PYTHONPATH=.:../strategy-library uv run --frozen --extra dev pytest \
  tests/test_runtime_dependency_proto.py tests/test_runtime_worker_proto.py -q
go test ./internal/runtimeagent -run RuntimeChannelProto -count=1
cd ../control-panel-service
go test ./internal/runtimechannel -run FrameContract -count=1
~~~

Expected: generated types and ValidateStrategySource do not exist.

- [ ] **Step 3: Add exact shared strategy messages and RPC**

Add to StrategyService:

~~~protobuf
rpc ValidateStrategySource(ValidateStrategySourceRequest)
    returns (ValidateStrategySourceResponse);

message RuntimeDependencyProfile {
  uint32 schema_version = 1;
  string profile_name = 2;
  string profile_version = 3;
  string contract_sha256 = 4;
  string hosted_python = 5;
  repeated string public_import_roots = 6;
  string strategy_service_commit = 7;
  string strategy_library_commit = 8;
  string image_build_id = 9;
}

message RuntimeDependencyError {
  string code = 1;
  string module = 2;
  string runtime_profile = 3;
  string runtime_profile_version = 4;
  string image_build_id = 5;
  string message = 6;
}

message StrategyValidationIssueProto {
  string code = 1;
  string message = 2;
  string module = 3;
  int32 line = 4;
}

message ValidateStrategySourceRequest {
  string source = 1;
  int64 user_id = 100;
  string runtime_id = 101;
}

message ValidateStrategySourceResponse {
  bool ok = 1;
  repeated StrategyValidationIssueProto issues = 2;
  RuntimeDependencyProfile runtime_profile = 3;
}
~~~

Validate returns ok=false plus issues for source validation failures; transport/auth/runtime failures remain gRPC errors.

- [ ] **Step 4: Add typed worker fields without reusing tags**

Import strategy_service.proto in runtime_worker.proto and add:

~~~protobuf
message SessionProgress {
  // existing fields 1 through 5 unchanged
  strategy.v1.RuntimeDependencyError dependency_error = 6;
}

message PlatformCallResult {
  // existing fields 1 through 4 unchanged
  strategy.v1.RuntimeDependencyError dependency_error = 5;
}

message FinalStatus {
  // existing fields 1 through 4 unchanged
  strategy.v1.RuntimeDependencyError dependency_error = 5;
}

message WorkerError {
  // existing fields 1 through 4 unchanged
  strategy.v1.RuntimeDependencyError dependency_error = 5;
}
~~~

- [ ] **Step 5: Add RuntimeChannel profile and error fields**

Add ValidateStrategySource to ControlPanelService and the method comment. Add:

~~~protobuf
message RuntimeHello {
  // existing fields 1 through 14 unchanged
  strategy.v1.RuntimeDependencyProfile dependency_profile = 15;
}

message RuntimeResume {
  // existing fields 1 through 3 unchanged
  strategy.v1.RuntimeDependencyProfile dependency_profile = 4;
}

message StreamError {
  string code = 1;
  string message = 2;
  strategy.v1.RuntimeDependencyError dependency_error = 3;
}

message ReportRuntimeStartupFailureRequest {
  string key_id = 1;
  string runtime_id = 2;
  string source = 3;
  int64 issued_at_unix_ms = 4;
  string nonce = 5;
  strategy.v1.RuntimeDependencyError dependency_error = 6;
  strategy.v1.RuntimeDependencyProfile actual_profile = 7;
  string signature = 8;
}

message ReportRuntimeStartupFailureResponse {
  bool recorded = 1;
}
~~~

Add `ReportRuntimeStartupFailure` to ControlPanelService adjacent to RuntimeChannel. It is failure-only: the server authenticates a canonical Ed25519 payload with the existing runtime credential, accepts only `source=self_hosted` and `code=RUNTIME_DEPENDENCY_PROFILE_INVALID`, records into the existing admission-failure repository, and returns without upsert, lease, token rotation, registry mutation, or route availability. Do not add profile fields to the persisted Runtime registry message or database model; RESUME repeats the authenticated in-memory admission facts. The dependency plan does not renumber the WorkerFrame oneof: nested dependency field numbers 5/6 are in different message scopes from WorkerHello.protocol_version field number 5 (runtime value 2) and WorkerFrame indicator field numbers 15/21.

- [ ] **Step 6: Make strategy-service regeneration portable and deterministic**

Replace the hard-coded /opt/anaconda3 Python with the nounset-safe fallback:

~~~bash
PYTHON_BIN="${PYTHON:-}"
if [ -z "$PYTHON_BIN" ]; then
  PYTHON_BIN="$(command -v python3)"
fi
"$PYTHON_BIN" -m grpc_tools.protoc ...
~~~

Add a shell contract test that runs with `env -u PYTHON` under the existing
`set -euo pipefail` path and proves `python3` is selected; also cover an explicit
`PYTHON` override. Add a sed_in_place function that selects sed -i for GNU and
sed -i '' for BSD, and use it for generated relative-import rewrites. Keep every
existing proto source/output and mapping. The script must fail when python3,
grpc_tools.protoc, protoc, protoc-gen-go, or protoc-gen-go-grpc is unavailable.

- [ ] **Step 7: Regenerate all stubs and compare first/second-generation checksums**

~~~bash
cd strategy-service
PYTHON=.venv/bin/python ./generate_proto.sh
find strategy_service/gen gen -type f \( -name '*.py' -o -name '*.go' \) -print \
  | LC_ALL=C sort \
  | while IFS= read -r file; do shasum -a 256 "$file"; done \
  > /tmp/strategy-proto-first.sha256
PYTHON=.venv/bin/python ./generate_proto.sh
find strategy_service/gen gen -type f \( -name '*.py' -o -name '*.go' \) -print \
  | LC_ALL=C sort \
  | while IFS= read -r file; do shasum -a 256 "$file"; done \
  > /tmp/strategy-proto-second.sha256
diff -u /tmp/strategy-proto-first.sha256 /tmp/strategy-proto-second.sha256

cd ../control-panel-service
make proto
find gen/controlpanelv1 -type f -name '*.go' -print \
  | LC_ALL=C sort \
  | while IFS= read -r file; do shasum -a 256 "$file"; done \
  > /tmp/control-panel-proto-first.sha256
make proto
find gen/controlpanelv1 -type f -name '*.go' -print \
  | LC_ALL=C sort \
  | while IFS= read -r file; do shasum -a 256 "$file"; done \
  > /tmp/control-panel-proto-second.sha256
diff -u /tmp/control-panel-proto-first.sha256 /tmp/control-panel-proto-second.sha256
~~~

Expected: each checksum diff is empty. Review the ordinary repository diff separately to confirm the authoritative/generated changes are the intended protocol delta. Never use `git diff --exit-code` as the second-generation determinism assertion because the first generation is intentionally dirty relative to HEAD.

Before staging, compare `git diff --name-only` scoped to
`strategy_service/gen` and `gen` against the exact generated-file inventory in
this task. Any changed generated file outside that allow-list is a failure that
must be reviewed; directory-level staging must not absorb it. The PYTHON-unset
fallback/override assertions live in the already listed
`tests/test_runtime_dependency_proto.py`, so this task creates no unlisted shell
test.

- [ ] **Step 8: Run protocol contract tests**

~~~bash
cd strategy-service
PYTHONPATH=.:../strategy-library uv run --frozen --extra dev pytest \
  tests/test_runtime_dependency_proto.py tests/test_runtime_worker_proto.py -q
go test ./internal/runtimeagent -run RuntimeChannelProto -count=1
cd ../control-panel-service
go test ./internal/runtimechannel -run FrameContract -count=1
~~~

Expected: all tests pass. At this dependency stage, the coexistence test observes legacy WorkerFrame indicator field number 15; after the ordered Indicator V2 plan it observes WorkerHello.protocol_version field number 5 with runtime value 2, indicator_frame_v2 field number 21, and the reservation of field number 15 while the nested dependency field numbers remain 5/6.

- [ ] **Step 9: Commit authoritative and generated protocol changes per repository**

~~~bash
cd strategy-service
git add proto/strategy_service.proto proto/runtime_worker.proto generate_proto.sh strategy_service/gen/strategy_service_pb2.py strategy_service/gen/strategy_service_pb2_grpc.py strategy_service/gen/runtime_worker_pb2.py strategy_service/gen/runtime_worker_pb2_grpc.py strategy_service/gen/control_panel_service_pb2.py strategy_service/gen/control_panel_service_pb2_grpc.py gen/strategyv1/strategy_service.pb.go gen/strategyv1/strategy_service_grpc.pb.go gen/runtimeworkerv1/runtime_worker.pb.go gen/runtimeworkerv1/runtime_worker_grpc.pb.go gen/controlpanelv1/control_panel_service.pb.go gen/controlpanelv1/control_panel_service_grpc.pb.go tests/test_runtime_dependency_proto.py tests/test_runtime_worker_proto.py internal/runtimeagent/runtime_channel_proto_test.go
git commit -m "feat: add runtime dependency protocol"
cd ../control-panel-service
git add proto/control_panel_service.proto gen/controlpanelv1/control_panel_service.pb.go gen/controlpanelv1/control_panel_service_grpc.pb.go internal/runtimechannel/frame_contract_test.go
git commit -m "feat: carry runtime dependency admission facts"
~~~

### Task 8: Implement Validate, Worker Readiness, Typed Failure Propagation, and Cleanup

**Files:**
- Modify: strategy-service/strategy_service/grpc_server.py
- Modify: strategy-service/strategy_service/session_worker_entry.py
- Modify: strategy-service/strategy_service/session.py
- Modify: strategy-service/strategy_service/worker_agent_client.py
- Modify: strategy-service/strategy_service/platform_proxy.py
- Modify: strategy-service/strategy_service/portfolio_client.py
- Modify: strategy-service/tests/test_grpc_server.py
- Modify: strategy-service/tests/test_session_worker_entry.py
- Modify: strategy-service/tests/test_worker_agent_client.py
- Modify: strategy-service/tests/test_platform_proxy.py
- Modify: strategy-service/tests/test_portfolio_client_runtime_binding.py
- Modify: strategy-service/internal/runtimeagent/agent.go
- Modify: strategy-service/internal/runtimeagent/agent_test.go
- Modify: strategy-service/internal/runtimeagent/worker_manager.go
- Modify: strategy-service/internal/runtimeagent/worker_manager_test.go
- Modify: strategy-service/internal/runtimeagent/worker_ipc_server.go
- Modify: strategy-service/internal/runtimeagent/worker_ipc_server_test.go
- Modify: strategy-service/strategy_service/gen/portfolio_service_pb2.py
- Modify: strategy-service/strategy_service/gen/portfolio_service_pb2_grpc.py
- Modify: strategy-service/gen/portfoliov1/portfolio_service.pb.go
- Modify: strategy-service/gen/portfoliov1/portfolio_service_grpc.pb.go
- Modify: core-service/proto/portfolio_service.proto
- Modify: core-service/gen/portfoliov1/portfolio_service.pb.go
- Modify: core-service/gen/portfoliov1/portfolio_service_grpc.pb.go
- Modify: core-service/internal/service/grpc.go
- Modify: core-service/internal/service/grpc_strategy_test.go
- Modify: core-service/internal/repository/timescale.go
- Modify: core-service/internal/repository/session_test.go

**Interfaces:**
- Consumes: ValidateStrategySourceRequest, StrategyDependencyError, worker PlatformCall/SessionProgress, and worker generation lifecycle.
- Produces: ValidateStrategySourceResponse, typed RuntimeDependencyError frames,
  a bounded construction/persistence/activation barrier, the existing persisted
  non-active `pending` state, and generation-owned worker/pending/alias cleanup;
  no in-flight startup platform call can commit after cleanup ownership is lost.

- [ ] **Step 1: Write Python Validate and running-order tests**

Add tests proving Validate uses no portfolio/core calls and creates no Session:

~~~python
def test_validate_source_returns_profile_without_session(servicer, context):
    response = servicer.ValidateStrategySource(
        pb2.ValidateStrategySourceRequest(
            source=ALL_PUBLIC_SOURCE, user_id=7, runtime_id="rt-1"
        ),
        context,
    )
    assert response.ok is True
    assert response.runtime_profile.contract_sha256 == current_runtime_profile().contract_sha256
    assert servicer._sessions.list_ids() == []

def test_run_does_not_return_until_strategy_instance_is_ready(...):
    engine_block = threading.Event()
    engine_ready = threading.Event()
    # Fake create_strategy sets engine_ready, then waits on engine_block.
    response = call_run_in_thread()
    assert worker_progresses == []
    assert portfolio_client.save_session_calls == []
    assert portfolio_client.list_sessions() == []
    engine_ready.wait(1)
    assert response_thread.is_alive()
    engine_block.set()
    assert response.session_id
~~~

The second fake must place the readiness signal after strategy construction but
before the normal market-data loop. Add failure variants for
StrategyDependencyError and generic constructor failure; both return before
any running progress. Add snapshot-write and activation-write failures: after
`SaveSession(initial_status="pending")`, concurrent List/GetSession may observe
only `pending`, never `running`; failure transitions it to `failed`. Add a
constructor that releases only after the 30-second readiness timeout and prove
the RPC sets `abort` before bounded join/cleanup, returns without deadlock, and
eventually removes thread/subscriptions/aliases. Add a static unsupported-import
Preview/Run case proving the Task 5 gate attaches RuntimeDependencyError to the
RPC context rather than returning only the validation message.

Add a deterministic worker test that lets core activation succeed, then kills
the child before `session_worker_entry` can send external `running` progress.
The Agent must already know the canonical Session ID from `StartSession`, return
failure rather than success, mark that exact durable row failed through the
existing RuntimeChannel platform proxy, and remove the generation. A NotFound
from that cleanup is allowed only when persistence never happened.

Add the adversarial in-flight ordering test at the real Agent/IPC boundary:
block the generation's `SaveSession` platform dispatch after admission, kill the
worker and close its stream, and prove there is no failed update and no final
Run response while that admitted call remains in flight. Release Save so it
commits `pending`; require `SaveSession:end` to precede
`UpdateSession(failed)`, the final durable row to be failed, and all generation
state to be removed. Repeat with the `strategy_start` snapshot and activation
call, stale-generation frames, and a drain timeout that retains cleanup
ownership.

- [ ] **Step 2: Write worker frame and Go agent failure tests**

Python:

~~~python
def test_platform_call_result_carries_dependency_error(fake_client):
    error = dependency_error("STRATEGY_DEPENDENCY_UNAVAILABLE", "google.cloud")
    fake_context.runtime_dependency_error = error
    _handle_agent_platform_call(fake_client, servicer, validate_call())
    sent = fake_client.last_platform_result
    assert sent.ok is False
    assert sent.dependency_error.module == "google.cloud"
~~~

Go:

~~~go
func TestValidateDependencyFailureIsTypedAndOneShotWorkerIsRemoved(t *testing.T) {
    detail := &strategyv1.RuntimeDependencyError{
        Code: "STRATEGY_DEPENDENCY_UNAVAILABLE",
        Module: "google.cloud",
        RuntimeProfile: "platform-python-3.13",
        RuntimeProfileVersion: "1.0.0",
        ImageBuildId: "build-1",
    }
    // Worker reply is ok=false with detail.
    response := agent.HandleRequest(ctx, validateRuntimeFrame(detail))
    if got := response.GetError().GetDependencyError(); !proto.Equal(got, detail) {
        t.Fatalf("dependency detail = %+v", got)
    }
    assertNoManagedWorkersOrPendingAliases(t, agent)
}
~~~

Add Run variants for failure before startup persistence, failure after canonical
Session routing registration, child process exit, and timeout. Every variant asserts no
pendingRun, workerCallReply, session alias, managed process, or running response
remains. A failure before `SaveSession` leaves no durable row; a failure after
the pending row exists must leave it `failed`, never `running`. Add a
concurrent observability test that blocks construction, snapshot, and activation
in turn, repeatedly calls the product List/GetSession path, and proves it can
never observe `running` before the complete activation barrier.

- [ ] **Step 3: Run focused tests and verify RED**

~~~bash
cd strategy-service
PYTHONPATH=.:../strategy-library uv run --frozen --extra dev pytest \
  tests/test_grpc_server.py tests/test_session_worker_entry.py \
  tests/test_worker_agent_client.py tests/test_platform_proxy.py \
  tests/test_portfolio_client_runtime_binding.py -q
go test ./internal/runtimeagent -run 'Validate|Dependency|Started|Cleanup' -count=1 -v
~~~

Expected: Validate is unimplemented, dependency fields are not populated, and existing Run can publish running before background strategy construction completes.

- [ ] **Step 4: Implement ValidateStrategySource in the Python servicer**

Enforce user binding and runtime_id exactly like Preview. Call the Task 5 shared validate/probe helper on request.source. Convert every issue to StrategyValidationIssueProto and always return the current RuntimeDependencyProfile. Validation failures are response ok=false; an invalid caller/runtime remains an RPC error. Validate does not turn issue responses into transport errors.

Add one converter:

~~~python
def _runtime_dependency_error_proto(error: StrategyDependencyError):
    return pb2.RuntimeDependencyError(
        code=error.code,
        module=error.module,
        runtime_profile=error.runtime_profile,
        runtime_profile_version=error.runtime_profile_version,
        image_build_id=error.image_build_id,
        message=error.message,
    )
~~~

Preview and Run consume the same `StrategySourceGateResult`: when `ok=false` and `dependency_error` is present, call `set_context_dependency_error` before returning failure; when only ordinary syntax/declaration issues exist, retain the existing validation response. Tests cover UNSUPPORTED_STRATEGY_DEPENDENCY from static validation as well as child-probe failures, so no path can flatten a known dependency code to `issues[0].message`.

- [ ] **Step 5: Add a bounded strategy-ready barrier to Run**

Make `StartSession.session_id` the canonical ID all the way through the local
worker context and `SessionManager.create`; Python must not generate a second
random real ID. Every SaveSession, progress, final status, alias/generation
record, and response uses this same value. Reject an empty, malformed, or
already-live canonical ID without replacing an existing Session; tests cover
duplicate/collision and cleanup followed by safe reuse.

Introduce an internal `_SessionStartupResult` carrying `constructed`, `commit`,
`activation_ready`, `activated`, and `abort` Events plus error. The foreground
may register the Agent-provided canonical in-memory session ID and Demo delivery subscriptions,
but it must not call `SaveSession`, write the `strategy_start` snapshot, publish
running progress, or allow the market-data loop to consume a bar yet. Pass the
result into `_run_session`. `_run_session` sets `constructed` only after
`StrategyEngine.create_strategy` returns and every order/indicator/notification/
sink callback required before the first bar is installed; it then waits for
`commit` or `abort`. After commit it sets `activation_ready` and still waits for
`activated` or `abort` before consuming the first bar. On construction exception
it records the typed or safe generic error before setting `constructed`.

RunStrategy waits at most 30 seconds after starting the thread:

~~~python
if not startup.constructed.wait(timeout=self._session_start_timeout_seconds):
    startup.abort.set()
    self._fail_and_discard_startup(session_id, "strategy worker readiness timed out")
    context.set_code(grpc.StatusCode.DEADLINE_EXCEEDED)
    return pb2.RunStrategyResponse()
if startup.error is not None:
    startup.abort.set()
    self._fail_and_discard_startup(session_id, startup.error.message)
    set_context_dependency_error(context, startup.error)
    return pb2.RunStrategyResponse()
~~~

Add `initial_status = 15` to `SaveSessionRequest`. Empty preserves legacy
`running`; Runtime worker startup sends the only other accepted value,
`pending`. Reuse the existing stable text/code mapping `pending <-> 1` unchanged
(no migration, constraint rewrite, or reinterpretation of historical slot 2
`preflight`) and permit only `pending -> running|failed`. It does **not** add
pending to the general active predicate used by orders or wallet mutations.
Only `UpdatePortfolioSnapshot(snapshot_reason=strategy_start)` may accept a pending
session after the existing user/Portfolio/Strategy checks; all other snapshot/
order mutation paths remain fail-closed.

After successful construction, the foreground calls
`SaveSession(initial_status="pending")` exactly once and writes the
`strategy_start` snapshot while the worker remains blocked. If Save fails, set
abort before bounded join/cleanup and leave no row. If snapshot fails, set abort
first, transition the existing pending row to failed with a safe category,
then bounded-join/clean the generation; it can never leave a running row. After
both writes are durable, set `commit`, wait for the internal
`activation_ready`, call `UpdateSession(status="running")`, then immediately set
`activated` and return `session_id`. If activation fails, set abort and
transition pending to failed. The worker consumes no bar until `activated`.

Do **not** wait here for Agent `SessionProgress(status="running")`:
`session_worker_entry.py` sends that progress only after `RunStrategy` returns.
The Go Agent continues treating that later progress as its sole external Run
success signal. Add a deterministic no-deadlock test for this exact ordering.
Every validation/import/construction failure creates no Session; every failure
after persistence is non-running and leaves no bars/orders/indicators.

Because activation precedes the entry's external running send, add one Agent
failure rule: until this generation's canonical Session ID has produced the
accepted running progress, child exit, stream close, timeout, or send failure
first closes that generation's startup-platform-call admission. After HELLO,
`WorkerIPCServer.Connect` obtains an immutable authenticated `WorkerIdentity`
(canonical Session ID, PID, opaque token, generation) and passes it to every
frame and disconnect callback; the token is never logged or persisted. Agent
owns a mutex/condition generation gate: admission atomically rejects a
closing/stale generation and increments `inFlight` before dispatching
`SaveSession`, the `strategy_start` snapshot, or activation `UpdateSession`;
completion records its outcome, decrements the count, and signals waiters. Do
not implement this as an unguarded `WaitGroup.Add` racing `Wait`.

Already-admitted startup calls use an Agent-owned bounded lifecycle context, not
the worker stream/EOF context, so disconnect cannot make their completion
invisible. Exit cleanup closes the gate first, drains every already-admitted
startup call, then issues idempotent `UpdateSession(failed)` through the existing
RuntimeChannel platform proxy before releasing the Run failure. The Agent
receives no core address. `NotFound` is accepted only after the gate drained and
an authenticated `GetSession` through the same proxy confirms absence. An
ambiguous/timeout result retains a minimal generation cleanup record, blocks
canonical-ID reuse, and is retried by the Agent-owned cleanup loop rather than
orphaning a possibly late row. Thus an in-flight Save cannot commit `pending`
after the failed update and leave a durable nonterminal row; the gate blocks
only that generation, never RuntimeChannel heartbeat or another Session.

Regenerate, never hand-edit, both ownership domains: run
`make -C core-service proto-portfolio` for core `gen/portfoliov1`, and run
`strategy-service/generate_proto.sh` for its Python and local Go copies. Run
each generator twice, compare its owned checksums, then run the descriptor
coexistence test and require no second-generation diff.

- [ ] **Step 6: Carry typed details through worker helpers**

Extend _WorkerContext with runtime_dependency_error and set_runtime_dependency_error(). Add dependency_error parameters to WorkerAgentClient.send_progress(), send_final_status(), send_platform_call_result(), and send_worker_error(). _invoke_servicer_platform_call recognizes ValidateStrategySource and raises an internal typed WorkerPlatformCallError rather than RuntimeError when context has dependency detail. Keep the one `running` progress send in `session_worker_entry.py` strictly after the successful RunStrategy response; do not duplicate or move it into a path that can fire before core activation.

The outer exception handler returns a safe message plus typed detail and logs the traceback separately. It never serializes str(exc) when exc could contain a local path.

- [ ] **Step 7: Dispatch Validate in Go and preserve details**

Add ValidateStrategySource to the allowed Runtime request switch. Reuse the bounded one-shot worker path used by Preview:

~~~go
type RuntimeRequestError struct {
    GRPCCode codes.Code
    Message string
    Dependency *strategyv1.RuntimeDependencyError
}
~~~

invokeWorkerUnary returns *RuntimeRequestError when PlatformCallResult.ok is false. runtimeErrorFrame accepts this typed value and fills StreamError.dependency_error. For Run, SessionProgress.status=running is the only success signal; a progress/final/worker error carrying dependency detail wins over generic process-exit text.

- [ ] **Step 8: Centralize one-shot and failed-generation cleanup**

Use one cleanup method that first closes and drains startup platform-call
admission, then performs the pre-running durable failure rule when applicable,
then stops/waits the process, unregisters worker connections,
removes workerCallReply channels, pendingRun state, any legacy alias, indicator
state, and session routing entries for that generation. New Run has no
provisional-to-real alias because the StartSession ID is canonical. Validate
and Preview call cleanup on success as well as failure. Keep runtime-agent and
RuntimeChannel alive.

- [ ] **Step 9: Run focused lifecycle suites**

~~~bash
cd strategy-service
PYTHONPATH=.:../strategy-library uv run --frozen --extra dev pytest \
  tests/test_strategy_imports.py \
  tests/test_grpc_server.py \
  tests/test_session_worker_entry.py \
  tests/test_worker_agent_client.py \
  tests/test_platform_proxy.py \
  tests/test_portfolio_client_runtime_binding.py -q
go test ./internal/runtimeagent -run 'Validate|Dependency|Started|Cleanup|Worker|PlatformCall|Admission|Drain' -count=1
cd ../core-service
go test ./internal/service ./internal/repository -run 'Session.*Pending|Pending.*Session|StrategyStart' -count=1
~~~

Expected: all tests pass; race-enabled runs are repeated once with go test -race for internal/runtimeagent.

- [ ] **Step 10: Commit core startup-state and worker behavior in owning repositories**

~~~bash
cd core-service
git add proto/portfolio_service.proto gen/portfoliov1/portfolio_service.pb.go gen/portfoliov1/portfolio_service_grpc.pb.go internal/service/grpc.go internal/service/grpc_strategy_test.go internal/repository/timescale.go internal/repository/session_test.go
git commit -m "feat: persist session startup before activation"

cd ../strategy-service
git add strategy_service/gen/portfolio_service_pb2.py strategy_service/gen/portfolio_service_pb2_grpc.py gen/portfoliov1/portfolio_service.pb.go gen/portfoliov1/portfolio_service_grpc.pb.go
git add strategy_service/grpc_server.py strategy_service/session_worker_entry.py strategy_service/session.py strategy_service/worker_agent_client.py strategy_service/platform_proxy.py strategy_service/portfolio_client.py tests/test_grpc_server.py tests/test_session_worker_entry.py tests/test_worker_agent_client.py tests/test_platform_proxy.py tests/test_portfolio_client_runtime_binding.py internal/runtimeagent/agent.go internal/runtimeagent/agent_test.go internal/runtimeagent/worker_manager.go internal/runtimeagent/worker_manager_test.go internal/runtimeagent/worker_ipc_server.go internal/runtimeagent/worker_ipc_server_test.go
git commit -m "feat: gate strategy readiness on durable activation"
~~~

### Task 9: Close Normal and Coverage Final Images Over the Same Locked Profile

**Files:**
- Modify: strategy-service/Dockerfile
- Modify: strategy-service/scripts/build_strategy_runtime.sh
- Create: strategy-service/scripts/prepare_runtime_build_context.py
- Create: strategy-service/scripts/verify_runtime_image.sh
- Modify: strategy-service/scripts/smoke_strategy_runtime.sh
- Create: strategy-service/scripts/runtime_dependency_worker_smoke.py
- Create: strategy-service/scripts/fixtures/runtime_dependency_strategy_body.py
- Create: strategy-service/tests/fixtures/Dockerfile.runtime-dependency-fault
- Modify: strategy-service/tests/test_strategy_runtime_dockerfile.py
- Create: strategy-service/tests/test_runtime_image_scripts.py
- Modify: strategy-service/Makefile

**Interfaces:**
- Consumes: service/debugger lock state, packaged manifest, exact
  strategy-service/strategy-library/golang-lib Git trees, final Docker target,
  and expected coverage mode.
- Produces: a hermetic Git-derived temporary Docker context; normal and coverage images with identical profile facts, OCI labels, build-time closure, final-image closure, actual worker Validate bootstrap, and a deliberate missing-distribution fault fixture.

- [ ] **Step 1: Add a manifest-generated representative strategy and source-contract tests**

The tracked fixture declares only the dependency-neutral read-only Phase 3 class. A single helper in runtime_dependency_worker_smoke.py prepends imports by iterating load_runtime_dependency_profile().dependencies and using each public dependency.probe:

~~~python
def representative_strategy_source(body: str) -> str:
    profile = load_runtime_dependency_profile()
    imports = "\n".join(
        f"import {dependency.probe}"
        for dependency in profile.dependencies
        if dependency.public
    )
    return f"{imports}\n{body}"
~~~

Tests assert the generated AST roots/probes equal the loader projections. Shell, Docker, and Go files never spell out the eight roots.

Extend tests/test_strategy_runtime_dockerfile.py to assert:

- runtime-base copies both project trees before running `uv sync --frozen --no-dev`, installs the sibling `hushine-strategy-library` source recorded by the lock (with no `--no-install-package hushine-strategy-library` escape), then runs uv pip check, project/lock checker, verify-installed, SDK/worker/proto imports, and all-public validation;
- final Runtime `PYTHONPATH` does not contain `/app/strategy-library`, so source files cannot shadow the locked installed wheel; the verifier compares the installed package-resource manifest digest to the embedded source-derived digest;
- executor and executor-coverage both inherit runtime-base;
- executor-coverage installs only the named coverage extra and repeats uv pip check, checker, verify-installed, and bootstrap;
- both final targets set the same profile/version/digest/commit/source-state facts, but target-qualified build IDs differ so an executor failure cannot be confused with executor-coverage;
- Docker receives only the sealed temporary context created from the three
  declared Git repositories; `.git`, worktree pointer files, ignored `.venv`,
  caches, egg-info, coverage output, and any other host artifact are absent;
- the Go runtime-agent input `golang-lib` has its own exact commit label/fact and
  participates in source-state/build-ID changes;
- no public-root literal allow-list appears in Dockerfile;
- no pip/uv install outside the frozen project sync and the named frozen coverage-extra sync appears in a final image.

tests/test_runtime_image_scripts.py runs build/verify scripts with a fake docker executable and asserts exact target/tag/build-arg/label verification commands for normal, coverage, and --all. Its temporary three-repository fixture adds ignored sentinels under `.git`, `.venv`, pytest/cache, and egg-info paths and proves none appears in the context. A tracked or allowed-dirty `golang-lib` byte change must either fail the clean build or change source-state/build ID; it can never reuse the old identity.

- [ ] **Step 2: Run image source tests and verify RED**

~~~bash
cd strategy-service
PYTHONPATH=.:../strategy-library uv run --frozen --extra dev pytest \
  tests/test_strategy_runtime_dockerfile.py tests/test_runtime_image_scripts.py -q
~~~

Expected: final-target closure, build facts, paired build, and verification script assertions fail.

- [ ] **Step 3: Embed immutable build facts and common base closure**

`build_strategy_runtime.sh` computes the profile facts plus an exact source-state classification for all three build-input repositories:

~~~bash
PROFILE_NAME="$(python3 -c 'import tomllib; print(tomllib.load(open("strategy-library/hushine_strategy/runtime_dependencies.toml","rb"))["profile_name"])')"
PROFILE_VERSION="$(python3 -c 'import tomllib; print(tomllib.load(open("strategy-library/hushine_strategy/runtime_dependencies.toml","rb"))["profile_version"])')"
CONTRACT_SHA256="$(python3 -c 'import hashlib,pathlib; print(hashlib.sha256(pathlib.Path("strategy-library/hushine_strategy/runtime_dependencies.toml").read_bytes()).hexdigest())')"
SERVICE_COMMIT="$(git -C strategy-service rev-parse HEAD)"
LIBRARY_COMMIT="$(git -C strategy-library rev-parse HEAD)"
GOLANG_LIB_COMMIT="$(git -C golang-lib rev-parse HEAD)"
SERVICE_COMMIT_SHORT="$(git -C strategy-service rev-parse --short=12 HEAD)"
LIBRARY_COMMIT_SHORT="$(git -C strategy-library rev-parse --short=12 HEAD)"
GOLANG_LIB_COMMIT_SHORT="$(git -C golang-lib rev-parse --short=12 HEAD)"
image_build_id() {
  target="$1"
  case "$target" in executor|executor-coverage) ;; *) return 2 ;; esac
  printf '%s-%s-%s-%s-%s' \
    "$SERVICE_COMMIT_SHORT" "$LIBRARY_COMMIT_SHORT" \
    "$GOLANG_LIB_COMMIT_SHORT" "$PROFILE_VERSION" "$target"
}
NORMAL_IMAGE_BUILD_ID="$(image_build_id executor)"
COVERAGE_IMAGE_BUILD_ID="$(image_build_id executor-coverage)"
test "$NORMAL_IMAGE_BUILD_ID" != "$COVERAGE_IMAGE_BUILD_ID"
~~~

For each of strategy-service, strategy-library, and golang-lib, compute
`git status --porcelain=v1 --untracked-files=all`. A clean build requires all
three empty. Development-only `--allow-dirty` permits only tracked working-tree
changes and untracked non-ignored files; gitlinks/submodules, special devices,
and files outside those repositories fail closed.

`prepare_runtime_build_context.py` receives a newly created mode-0700 empty
directory. For each repository it exports `HEAD` with `git archive` into the
matching context subdirectory. In allow-dirty mode it overlays exactly the
current bytes/types/executable bits from `git ls-files --cached --others
--exclude-standard`, removes tracked deletions, and rejects a path that escapes
its repository. It then writes a canonical sorted manifest over every staged
relative path, type, executable bit, symlink target/file bytes, and deletion
marker. `SOURCE_STATE_SHA256` hashes that manifest, the three full commits, and
the profile digest. Clean and dirty modes therefore describe the exact same
bytes Docker receives; ignored files and `.git` are never copied or hashed.
The build script passes only this temporary root to `docker build`, never the
live workspace, and removes it on every exit. Dirty mode appends
`-dirty-${SOURCE_STATE_SHA256:0:12}` to each target-qualified build ID. Commit
labels describe the base revisions while target, dirty flag, and state digest
identify the exact build inputs. Allow CI to provide a target-specific
IMAGE_BUILD_ID explicitly, but never reuse one value for both targets and never
override SOURCE_DIRTY or SOURCE_STATE_SHA256; reject empty values and
whitespace/control characters.

Pass the common source/profile facts plus that target's build ID as build args. In each final target set exact labels:

~~~dockerfile
LABEL org.hushine.runtime.profile=$RUNTIME_PROFILE_NAME \
      org.hushine.runtime.profile.version=$RUNTIME_PROFILE_VERSION \
      org.hushine.runtime.contract.sha256=$RUNTIME_CONTRACT_SHA256 \
      org.hushine.runtime.strategy-service.commit=$RUNTIME_STRATEGY_SERVICE_COMMIT \
      org.hushine.runtime.strategy-library.commit=$RUNTIME_STRATEGY_LIBRARY_COMMIT \
      org.hushine.runtime.golang-lib.commit=$RUNTIME_GOLANG_LIB_COMMIT \
      org.hushine.runtime.image-build-id=$RUNTIME_IMAGE_BUILD_ID \
      org.hushine.runtime.source-dirty=$RUNTIME_SOURCE_DIRTY \
      org.hushine.runtime.source-state.sha256=$RUNTIME_SOURCE_STATE_SHA256
~~~

Set matching HUSHINE_RUNTIME_* environment variables for runtime-agent/Python. Do not embed Git remote output. Dockerfile `COPY` statements address only the sealed context's `strategy-service/`, `strategy-library/`, and `golang-lib/` directories; no source is copied from outside it. Final release verification requires `source-dirty=false`; Task 9/10 pre-commit proofs explicitly opt into dirty development images and cannot be reused for release.

In `runtime-base`, copy `strategy-library/`, `strategy-service/pyproject.toml`, and `strategy-service/uv.lock` before dependency installation, then run exactly:

~~~dockerfile
RUN cd /app/strategy-service \
 && uv sync --frozen --no-dev \
 && uv pip check --python /app/strategy-service/.venv/bin/python
~~~

The sync must install the non-editable sibling `hushine-strategy-library` from the locked `[tool.uv.sources]` path. Remove the current `--no-install-package hushine-strategy-library` bypass, remove `/app/strategy-library` from the final `PYTHONPATH`, and do not use source-path shadowing as a substitute for installed distribution metadata. Keep the copied source only for the contract checker/smoke fixture and build traceability. After that frozen sync and pip check, run:

~~~dockerfile
RUN /app/strategy-service/.venv/bin/python \
      /app/strategy-library/scripts/check_runtime_dependency_contract.py \
      --service-project /app/strategy-service/pyproject.toml \
      --service-lock /app/strategy-service/uv.lock \
      --installed-python runtime=/app/strategy-service/.venv/bin/python \
      --installed-python-version runtime=3.13 \
 && /app/strategy-service/.venv/bin/python \
      -I -m hushine_strategy.runtime_dependencies verify-installed \
      --python-constraint 3.13 --json
~~~

Then import strategy_service.session_worker_entry and generated strategy/worker/control-panel modules, generate the representative source from the packaged loader plus the dependency-neutral body, run static/complete-path/import-only probes, and assert no issue. Each command exits nonzero on failure.

- [ ] **Step 4: Re-run closure after coverage instrumentation**

executor-coverage uses the same runtime-base, replaces only the covered Go binary, installs --extra coverage with --frozen, and repeats every command from the common closure. It additionally proves importlib.metadata.version("coverage") exists while validate_strategy_code("import coverage...") returns UNSUPPORTED_STRATEGY_DEPENDENCY.

The normal final image proves importlib.metadata.PackageNotFoundError for coverage. Both images report identical public roots/profile/digest.

- [ ] **Step 5: Implement explicit build script modes**

The script interface is:

~~~bash
scripts/build_strategy_runtime.sh [--no-cache] [--verify] [--allow-dirty] VERSION
scripts/build_strategy_runtime.sh --coverage [--no-cache] [--verify] [--allow-dirty] VERSION
scripts/build_strategy_runtime.sh --all [--no-cache] [--verify] [--allow-dirty] VERSION
~~~

Normal tags hushine/strategy-runtime:executor-VERSION and the existing compatibility tags. Coverage tags hushine/strategy-runtime:executor-coverage-VERSION. --all builds both from separate final-target invocations. --verify calls verify_runtime_image.sh once per produced final image with all five explicit profile arguments. Unknown flags, missing VERSION, reserved VERSION=coverage, or a dirty worktree without `--allow-dirty` exits 2.

- [ ] **Step 6: Implement exact final-image verifier**

verify_runtime_image.sh accepts:

~~~bash
scripts/verify_runtime_image.sh \
  --image hushine/strategy-runtime:executor-contract \
  --coverage false \
  --profile platform-python-3.13 \
  --version 1.0.0 \
  --digest 8457b3c35618558fc8bfc74d4135b7eb52e00c33a8c9a49d202830f3fd5b62c5
~~~

It uses docker image inspect to compare all nine OCI labels—including the exact
golang-lib commit—to in-container HUSHINE_RUNTIME_* facts, runs uv pip check,
the project/lock/installed checker with `--installed-python-version
runtime=3.13`, verify-installed under
`/app/strategy-service/.venv/bin/python -I` with `--python-constraint 3.13`,
SDK/protobuf/worker imports, the representative strategy validate/import probe,
and coverage-present/absent plus coverage-denied assertions. It accepts
`--allow-dirty` only for Task 9/10 development proofs; otherwise `source-dirty`
must be false. Any mismatch exits 1 and names the image/fact without printing
the environment.

- [ ] **Step 7: Make container smoke start a real one-shot worker**

scripts/runtime_dependency_worker_smoke.py starts a loopback TCP RuntimeWorkerAgent gRPC server, launches /app/strategy-service/.venv/bin/python -m strategy_service.session_worker_entry with a one-shot worker token, waits for WorkerHello, sends a ValidateStrategySource PlatformCall containing the tracked all-public fixture, and requires an ok response with the exact `--expected-profile`, `--expected-version`, and `--expected-digest` before the worker exits 0. A 30-second timeout kills/reaps the child.

`scripts/smoke_strategy_runtime.sh` requires the same five named arguments as the verifier—`--image`, `--coverage`, `--profile`, `--version`, and `--digest`—plus optional `--allow-dirty` for Task 9/10 only, then runs:

~~~bash
scripts/verify_runtime_image.sh --image "$IMAGE" --coverage "$COVERAGE" --profile "$PROFILE" --version "$VERSION" --digest "$DIGEST"
docker run --rm --entrypoint python "$IMAGE" \
  /app/strategy-service/scripts/runtime_dependency_worker_smoke.py \
  --strategy-body /app/strategy-service/scripts/fixtures/runtime_dependency_strategy_body.py \
  --expected-profile "$PROFILE" \
  --expected-version "$VERSION" \
  --expected-digest "$DIGEST"
docker run --rm --entrypoint ./bin/runtime-agent "$IMAGE" --help
~~~

Copy only these two smoke files/fixture into the image; do not copy the whole test suite.

- [ ] **Step 8: Add missing-distribution fault targets**

tests/fixtures/Dockerfile.runtime-dependency-fault accepts BASE_IMAGE and FAULT_DISTRIBUTION, uninstalls that loader-selected public distribution from its venv, and defines:

- build-gate: runs verify-installed during build and therefore must fail;
- startup-gate: preserves the broken environment so Task 10 can prove runtime-agent exits before HELLO.

tests/test_runtime_image_scripts.py asserts the fault distribution is obtained from the packaged loader JSON, and that no manifest/validator file is modified to manufacture failure.

- [ ] **Step 9: Add Make targets and run source tests**

Add:

~~~make
runtime-images:
	./scripts/build_strategy_runtime.sh --all --allow-dirty dev

runtime-images-verify:
	./scripts/build_strategy_runtime.sh --all --no-cache --verify contract

runtime-images-verify-dev:
	./scripts/build_strategy_runtime.sh --all --no-cache --verify --allow-dirty contract
~~~

Run:

~~~bash
cd strategy-service
PYTHONPATH=.:../strategy-library uv run --frozen --extra dev pytest \
  tests/test_strategy_runtime_dockerfile.py tests/test_runtime_image_scripts.py -q
~~~

Expected: all source/script tests pass.

- [ ] **Step 10: Build and verify both final images without cache**

~~~bash
cd strategy-service
./scripts/build_strategy_runtime.sh --all --no-cache --verify --allow-dirty contract
./scripts/smoke_strategy_runtime.sh \
  --image hushine/strategy-runtime:executor-contract \
  --coverage false \
  --profile platform-python-3.13 \
  --version 1.0.0 \
  --digest 8457b3c35618558fc8bfc74d4135b7eb52e00c33a8c9a49d202830f3fd5b62c5 \
  --allow-dirty
./scripts/smoke_strategy_runtime.sh \
  --image hushine/strategy-runtime:executor-coverage-contract \
  --coverage true \
  --profile platform-python-3.13 \
  --version 1.0.0 \
  --digest 8457b3c35618558fc8bfc74d4135b7eb52e00c33a8c9a49d202830f3fd5b62c5 \
  --allow-dirty
~~~

Expected: both builds and both final-image verifiers pass; their profile/version/digest JSON is identical; only coverage installation status differs.

- [ ] **Step 11: Prove a missing distribution fails the build gate**

~~~bash
cd strategy-service
FAULT_DISTRIBUTION="$(docker run --rm --entrypoint python \
  hushine/strategy-runtime:executor-contract \
  -c 'from hushine_strategy.runtime_dependencies import load_runtime_dependency_profile as load; print(next(item.distribution for item in load().dependencies if item.public))')"
if docker build \
  --build-arg BASE_IMAGE=hushine/strategy-runtime:executor-contract \
  --build-arg FAULT_DISTRIBUTION="$FAULT_DISTRIBUTION" \
  --target build-gate \
  -f tests/fixtures/Dockerfile.runtime-dependency-fault \
  -t hushine/strategy-runtime:dependency-fault-build .; then
  exit 1
fi
~~~

Expected: docker build exits nonzero at verify-installed and reports the loader-selected import/distribution pair as missing.

- [ ] **Step 12: Commit the image closure unit**

~~~bash
cd strategy-service
git add Dockerfile Makefile scripts/build_strategy_runtime.sh scripts/prepare_runtime_build_context.py scripts/verify_runtime_image.sh scripts/smoke_strategy_runtime.sh scripts/runtime_dependency_worker_smoke.py scripts/fixtures/runtime_dependency_strategy_body.py tests/fixtures/Dockerfile.runtime-dependency-fault tests/test_strategy_runtime_dockerfile.py tests/test_runtime_image_scripts.py
git commit -m "build: close runtime images over dependency profile"
~~~

### Task 10: Fail Runtime Startup Before HELLO and Sign Exact Profile Facts

**Files:**
- Create: strategy-service/internal/runtimeagent/dependency_profile.go
- Create: strategy-service/internal/runtimeagent/dependency_profile_test.go
- Modify: strategy-service/internal/runtimeagent/runtime_channel.go
- Modify: strategy-service/internal/runtimeagent/runtime_channel_test.go
- Modify: strategy-service/internal/runtimeagent/worker_manager.go
- Modify: strategy-service/internal/runtimeagent/worker_manager_test.go
- Modify: strategy-service/internal/runtimeagent/worker_environment.go
- Modify: strategy-service/internal/runtimeagent/worker_environment_test.go
- Modify: strategy-service/internal/runtimeagent/worker_environment_posix.go
- Modify: strategy-service/internal/runtimeagent/worker_environment_windows.go
- Create: strategy-service/internal/runtimeagent/startup_failure_report.go
- Create: strategy-service/internal/runtimeagent/startup_failure_report_test.go
- Modify: strategy-service/cmd/runtime-agent/main.go
- Modify: strategy-service/cmd/runtime-agent/main_test.go

**Interfaces:**
- Consumes: a pure resolved WorkerLaunchSpec, exact WorkerPythonInvocation, same-process Python/metadata/import JSON, HUSHINE_RUNTIME_* embedded facts, Runtime source, and credential HELLO signer.
- Produces: verified strategy.v1.RuntimeDependencyProfile, RUNTIME_DEPENDENCY_PROFILE_INVALID startup error, RuntimeIdentity.DependencyProfile, signed HELLO/profile-bearing RESUME, a safe Hosted failure record, and one bounded signed Self-hosted failure report that never creates readiness.

- [ ] **Step 1: Write verifier table tests**

Use an injected command runner:

~~~go
type WorkerPythonInvocation struct {
    Executable string
    ArgsPrefix []string
    WorkDir string
    Env []string
}

func TestVerifyRuntimeDependencyProfileUsesExactWorkerInvocation(t *testing.T) {
    runner := &recordingRunner{stdout: validVerifyJSON}
    got, err := VerifyRuntimeDependencyProfile(
        context.Background(),
        WorkerPythonInvocation{
            Executable: "uv",
            ArgsPrefix: []string{"run", "python", "-Xfrozen_modules=off"},
            WorkDir: "/app/strategy-service",
        },
        EmbeddedRuntimeFacts{Source: "hosted", /* exact facts */},
        runner,
    )
    if err != nil { t.Fatal(err) }
    wantArgs := []string{
        "run", "python", "-Xfrozen_modules=off",
        "-m", "hushine_strategy.runtime_dependencies",
        "verify-installed", "--python-constraint", "3.13", "--json",
    }
    if !slices.Equal(runner.args, wantArgs) { t.Fatalf("args = %v", runner.args) }
    if got.GetContractSha256() != expectedDigest { t.Fatalf("profile = %+v", got) }
}
~~~

Table cases reject nonzero child exit, timeout, malformed/non-JSON stdout, ok=false, a reported Python other than 3.13.x, missing profile distribution, a profile probe that raises ModuleNotFoundError during initialization, schema/name/version/digest mismatch, missing Hosted image facts, empty commit/build ID, and env-vs-loader mismatch. Both missing-profile cases map to RUNTIME_DEPENDENCY_PROFILE_INVALID before any listener/worker/strategy request exists; their safe startup message names only the manifest import root/distribution/probe and never the internal transitive missing name. Poison the parent with PYTHONPATH, PYTHONHOME, VIRTUAL_ENV, UV_PROJECT_ENVIRONMENT, DB/Kafka/core/order addresses, tokens, and credentials; the recorded child environment must contain only the WorkerLaunchSpec allowlist and none of the poisoned values. Hosted and Self-hosted specs may include the strategy-service work directory needed to import the worker, but must reject any `strategy-library` source directory and prove `hushine_strategy` resolves from installed distribution metadata outside `/app/strategy-library`. Bare internal development may explicitly allow the verified sibling source path. A bare source without image facts succeeds with loader facts plus local-dev commit/build fields; hosted and self_hosted never use that fallback.

- [ ] **Step 2: Write ordering and HELLO signature tests**

Refactor run behind injected runtimeBootstrapOps so a test can count calls:

~~~go
func TestHostedDependencyGateFailsBeforeListenerOrChannel(t *testing.T) {
    ops := bootstrapOpsReturningProfileFailure()
    if code := runWithOps([]string{"--config", ops.configPath}, ops); code != 1 {
        t.Fatalf("exit = %d", code)
    }
    assertCalls(t, ops.calls, []string{
        "load-config", "resolve-worker-launch-spec", "verify-profile",
        "emit-startup-failure",
    })
}
~~~

Add a Self-hosted failure case whose call order is resolve, verify, load credential/TLS, report failure; assert it never initializes observability/listener/WorkerManager, never dials RuntimeChannel, never sends HELLO, and returns 1 even when the bounded report itself fails. Verify the failure-report canonical signature changes if code, module, profile facts, source, runtime_id, issued_at, or nonce changes. Extend signed and Bare HELLO tests to compare every profile field. Mutating profile name, version, digest, public roots, either commit, or image build ID after signing must fail control-panel signature verification once Task 11 lands.

- [ ] **Step 3: Run startup tests and verify RED**

~~~bash
cd strategy-service
go test ./internal/runtimeagent -run 'DependencyProfile|RuntimeChannel' -count=1 -v
go test ./cmd/runtime-agent -run 'DependencyGate|RuntimeIdentity' -count=1 -v
~~~

Expected: verifier/profile fields do not exist and the current run path opens worker IPC before any dependency self-check.

- [ ] **Step 4: Implement exact worker-invocation verification**

Refactor `worker_environment.go` rather than duplicating its executable, path, and sanitization logic. Introduce a pure `ResolveWorkerLaunchSpec(config, runtimeSource, processEnv)` that resolves executable/symlinks once and returns the prefix, working directory, source-specific Python import path, and sanitized base environment without creating per-Session directories, opening a listener, or starting a process. Split the current directory/token work into `BuildWorkerSessionInvocation(spec, WorkerStartSpec)`, which creates the private home/tmp/cache root and adds only agent address, token, Session ID, and debug flags. `NewWorkerManager(spec, listener, ...)` consumes that exact immutable spec and never calls `LookPath`, `EvalSymlinks`, or rebuilds the base environment; `Invocation()` returns a defensive copy for regression tests. VerifyRuntimeDependencyProfile consumes the same pre-construction spec and appends only:

~~~text
-m hushine_strategy.runtime_dependencies verify-installed --python-constraint 3.13 --json
~~~

Run with a 30-second context. Parse a single JSON object, require ok=true and Python 3.13.x, and compare embedded profile name/version/digest to loader output. The command receives precisely the same executable/prefix/workdir/base environment later used by session workers; the verifier adds no source path or inherited environment. For Hosted/Self-hosted, resolve PythonPath to strategy-service only and assert no path whose clean basename/path is `strategy-library`; run an origin probe in both verifier and a real worker child and require `hushine_strategy` plus its manifest to come from the installed distribution. Bare/debugger may opt into the local sibling path only under its existing guarded source. Convert every failure to:

~~~go
type RuntimeDependencyProfileError struct {
    Code string
    Message string
    Actual *strategyv1.RuntimeDependencyProfile
}
~~~

Code is always RUNTIME_DEPENDENCY_PROFILE_INVALID. Message is safe and names the failed fact/probe without stdout, environment, workdir, or credential content.

- [ ] **Step 5: Move the gate ahead of Runtime readiness**

In run(), keep argument/config parsing first, then resolve WorkerLaunchSpec and run the profile verifier. Only after success:

1. initialize observability;
2. create the loopback worker listener;
3. construct WorkerManager from the already verified WorkerLaunchSpec;
4. load credentials/TLS;
5. dial/send RuntimeChannel HELLO.

On failure write one JSON line with only code, module, profile name/version, image build ID, source, and safe reason, then return 1. Do not print the child command, environment, stdout, workdir, or credential material. Hosted provisioners consume this JSON in Task 11. For Self-hosted only, load the existing credential/TLS after verification fails and attempt `ReportRuntimeStartupFailure` with a five-second total deadline, fresh nonce/timestamp, and canonical signature; failure to report is logged safely and never changes the exit or starts RuntimeChannel. Bare/debugger does not call the report RPC.

- [ ] **Step 6: Attach verified facts to RuntimeIdentity and HELLO**

RuntimeIdentity gains:

~~~go
DependencyProfile *strategyv1.RuntimeDependencyProfile
~~~

buildBareHello and buildSignedHello require a non-nil complete profile. canonicalHelloPayload flattens all dependency fields with stable names and sorted public_import_roots:

~~~text
dependency_contract_sha256
dependency_hosted_python
dependency_image_build_id
dependency_profile_name
dependency_profile_version
dependency_public_import_roots
dependency_schema_version
dependency_strategy_library_commit
dependency_strategy_service_commit
~~~

The control-panel implementation in Task 11 uses the identical order. Add BuildResumeRuntimeFrame(identity, resumeToken, fingerprint) and require it to carry the same immutable profile; this keeps the protocol correct for current server-side RESUME support without changing runtime_id routing.

- [ ] **Step 7: Run Go startup/channel tests**

~~~bash
cd strategy-service
go test ./internal/runtimeagent -run 'DependencyProfile|RuntimeChannel|WorkerManager' -count=1
go test ./cmd/runtime-agent -run 'DependencyGate|RuntimeIdentity|WorkerPython' -count=1
go vet ./internal/runtimeagent ./cmd/runtime-agent
~~~

Expected: all commands pass.

- [ ] **Step 8: Rebuild both final images after the startup gate exists**

Task 9 images were built before the runtime-agent startup verifier was implemented and are not valid inputs to the startup fault proof. Rebuild from the current Task 10 worktree, without cache, and verify both final targets before deriving the fault image:

~~~bash
cd strategy-service
./scripts/build_strategy_runtime.sh \
  --all --no-cache --verify --allow-dirty startup-contract
./scripts/verify_runtime_image.sh \
  --image hushine/strategy-runtime:executor-startup-contract \
  --coverage false \
  --profile platform-python-3.13 \
  --version 1.0.0 \
  --digest 8457b3c35618558fc8bfc74d4135b7eb52e00c33a8c9a49d202830f3fd5b62c5 \
  --allow-dirty
./scripts/verify_runtime_image.sh \
  --image hushine/strategy-runtime:executor-coverage-startup-contract \
  --coverage true \
  --profile platform-python-3.13 \
  --version 1.0.0 \
  --digest 8457b3c35618558fc8bfc74d4135b7eb52e00c33a8c9a49d202830f3fd5b62c5 \
  --allow-dirty
~~~

Expected: both images contain the just-built runtime-agent startup gate, report `source_dirty=true` only because this is the pre-commit development proof, and pass final-image closure. Do not reuse `executor-contract` from Task 9.

- [ ] **Step 9: Prove the rebuilt fault image exits before channel readiness**

~~~bash
cd strategy-service
FAULT_DISTRIBUTION="$(docker run --rm --entrypoint python \
  hushine/strategy-runtime:executor-startup-contract \
  -c 'from hushine_strategy.runtime_dependencies import load_runtime_dependency_profile as load; print(next(item.distribution for item in load().dependencies if item.public))')"
docker build \
  --build-arg BASE_IMAGE=hushine/strategy-runtime:executor-startup-contract \
  --build-arg FAULT_DISTRIBUTION="$FAULT_DISTRIBUTION" \
  --target startup-gate \
  -f tests/fixtures/Dockerfile.runtime-dependency-fault \
  -t hushine/strategy-runtime:dependency-fault-startup .
set +e
OUTPUT="$(docker run --rm hushine/strategy-runtime:dependency-fault-startup 2>&1)"
STATUS=$?
set -e
test "$STATUS" -ne 0
printf '%s\n' "$OUTPUT" | grep -F RUNTIME_DEPENDENCY_PROFILE_INVALID
if printf '%s\n' "$OUTPUT" | grep -F 'runtime-agent started:'; then exit 1; fi
~~~

Expected: nonzero exit, stable invalid-profile code, and no started/HELLO-ready log.

- [ ] **Step 10: Commit the startup/identity gate**

~~~bash
cd strategy-service
git add internal/runtimeagent/dependency_profile.go internal/runtimeagent/dependency_profile_test.go internal/runtimeagent/runtime_channel.go internal/runtimeagent/runtime_channel_test.go internal/runtimeagent/worker_manager.go internal/runtimeagent/worker_manager_test.go internal/runtimeagent/worker_environment.go internal/runtimeagent/worker_environment_test.go internal/runtimeagent/worker_environment_posix.go internal/runtimeagent/worker_environment_windows.go internal/runtimeagent/startup_failure_report.go internal/runtimeagent/startup_failure_report_test.go cmd/runtime-agent/main.go cmd/runtime-agent/main_test.go
git commit -m "feat: verify runtime profile before channel hello"
~~~

### Task 11: Admit Only the Expected Profile Before Registry or Routing

**Files:**
- Modify: control-panel-service/internal/config/config.go
- Modify: control-panel-service/internal/config/config_test.go
- Modify: control-panel-service/config.yaml
- Modify: control-panel-service/internal/runtimechannel/auth.go
- Modify: control-panel-service/internal/runtimechannel/auth_test.go
- Modify: control-panel-service/internal/runtimechannel/service.go
- Modify: control-panel-service/internal/runtimechannel/grpc.go
- Create: control-panel-service/internal/runtimechannel/grpc_startup_failure_test.go
- Create: control-panel-service/internal/runtimechannel/dependency_admission_test.go
- Create: control-panel-service/internal/runtimechannel/startup_failure_test.go
- Modify: control-panel-service/internal/provision/provision.go
- Modify: control-panel-service/internal/provision/docker.go
- Modify: control-panel-service/internal/provision/docker_test.go
- Modify: control-panel-service/internal/runtime/service.go
- Modify: control-panel-service/internal/runtime/service_test.go
- Modify: control-panel-service/cmd/control-panel-service/main.go
- Modify: control-panel-service/cmd/control-panel-service/main_test.go

**Interfaces:**
- Consumes: configured schema/name/version/digest, signed HELLO or token-bound RESUME profile, signed Self-hosted ReportRuntimeStartupFailure, and Hosted container startup-failure JSON.
- Produces: ExpectedDependencyProfile, ErrDependencyProfileMismatch, admitted AuthenticatedRuntime.DependencyProfile, visible failure records for invalid/mismatched Hosted and Self-hosted startup, and a registry entry only after exact successful comparison.

- [ ] **Step 1: Write config validation tests**

~~~go
func TestDefaultDependencyProfileAdmissionIsPinned(t *testing.T) {
    cfg := Default().RuntimeChannelServer.DependencyProfile
    if cfg.SchemaVersion != 1 ||
       cfg.Name != "platform-python-3.13" ||
       cfg.Version != "1.0.0" ||
       cfg.ContractSHA256 != expectedDigest {
        t.Fatalf("dependency admission = %+v", cfg)
    }
}
~~~

Table tests reject schema 0, blank name/version, non-64-lowercase-hex digest, whitespace, and invalid env overrides.

- [ ] **Step 2: Write fail-before-mutation HELLO and RESUME tests**

~~~go
func TestMismatchedHelloIsRecordedBeforeUpsertLeaseOrRegister(t *testing.T) {
    svc, repo := serviceWithExpectedProfile(expectedProfile())
    err := svc.Handle(streamWithFirstFrame(
        signedHelloWithProfile(profileWithDigest("bad-digest")),
    ))
    assertStatusCode(t, err, codes.FailedPrecondition)
    if repo.upserts != 0 || repo.leases != 0 || len(svc.RegistrySnapshot()) != 0 {
        t.Fatalf("mismatch mutated admission state")
    }
    assertAdmissionFailure(t, repo, "RUNTIME_DEPENDENCY_PROFILE_MISMATCH")
}
~~~

Repeat for missing profile, name/version/schema mismatch, unsorted/duplicate/empty roots, missing build ID/commits, and RESUME mismatch. Positive normal/coverage profiles have identical schema/name/version/digest and different build IDs; both are accepted.

Add two failure-before-readiness suites:

- Self-hosted `ReportRuntimeStartupFailure` verifies credential ownership/status, nonce/timestamp, signature, source, stable code, and safe field lengths; it records RUNTIME_DEPENDENCY_PROFILE_INVALID but performs zero upsert/lease/register/token mutation. Replays, expired timestamps, wrong source, wrong owner, altered signed fields, and unknown codes fail closed and record no attacker-controlled reason.
- Hosted `DockerProvisioner.StartupFailure` parses only a complete JSON log line emitted by Task 10, allowlists fields/lengths, and returns a typed `provision.StartupFailure`. `EnsureHostedRuntime` records it against the already known plan user/runtime/credential before deprovision and returns FailedPrecondition. Plain logs, malformed JSON, secret-looking extra fields, or other codes remain redacted diagnostics and are not promoted to structured failure.

- [ ] **Step 3: Run focused tests and verify RED**

~~~bash
cd control-panel-service
go test ./internal/config -run DependencyProfile -count=1 -v
go test ./internal/runtimechannel -run 'DependencyAdmission|StartupFailure|Hello|Resume' -count=1 -v
go test ./internal/provision ./internal/runtime -run 'StartupFailure|DependencyProfile' -count=1 -v
~~~

Expected: configuration/profile fields do not exist and mismatched authenticated Runtimes can currently reach upsert.

- [ ] **Step 4: Add typed configuration and overrides**

RuntimeDependencyProfileConfig has SchemaVersion uint32, Name, Version, and ContractSHA256 strings, with YAML names schema_version, name, version, and contract_sha256. Nest it at runtime_channel_server.dependency_profile. Default/config.yaml pin schema 1, platform-python-3.13, 1.0.0, and the rollout digest. Support RUNTIME_DEPENDENCY_SCHEMA_VERSION, RUNTIME_DEPENDENCY_PROFILE_NAME, RUNTIME_DEPENDENCY_PROFILE_VERSION, and RUNTIME_DEPENDENCY_CONTRACT_SHA256. Validate after overrides and never forward these values to Runtime containers.

- [ ] **Step 5: Include profile in authentication and canonical signature**

AuthenticatedRuntime gains a deep-copied DependencyProfile. helloPayload adds the nine flattened Task 10 dependency fields in identical order. verifyHello returns it only after signature verification; Bare HELLO enforces the same structural completeness.

- [ ] **Step 6: Validate before upsert/lease/register**

~~~go
var ErrDependencyProfileMismatch = errors.New("runtime dependency profile mismatch")

func validateDependencyAdmission(
    expected ExpectedDependencyProfile,
    actual *strategyv1.RuntimeDependencyProfile,
) error
~~~

Require schema, nonblank name/version/digest/hosted_python, sorted unique nonempty roots, both commits, and build ID; compare expected schema/name/version/digest exactly. Call after authentication/peer identity and before upsertRuntime/lease. Record failure_code RUNTIME_DEPENDENCY_PROFILE_MISMATCH with safe expected/actual facts.

- [ ] **Step 7: Record failure-only startup reports without readiness**

Implement the Task 7 unary RPC on the dedicated RuntimeChannel listener using the same credential repository and Ed25519 primitives as HELLO, but a domain-separated canonical payload beginning `runtime-startup-failure-v1`. Add the explicit method adapter to `internal/runtimechannel/grpc.go`; the listener registers `runtimechannel.GRPCService`, whose non-embedded `svc *Service` does not acquire new `Service` methods automatically. Its focused test starts the real listener/client and proves the RPC reaches the service rather than returning `Unimplemented`. Consume no credential and issue no resume token. Record only allowlisted safe facts in the existing `runtime_admission_failures` table.

Add `StartupFailure(ctx, handle) (provision.StartupFailure, bool, error)` to DockerProvisioner as an optional provider interface. On Hosted registration timeout, query it before generic diagnostics/deprovision and call the existing repository's RecordRuntimeAdmissionFailure with the plan-owned user/runtime/name/credential/source—not identities supplied by the log line. This is an existing-table write, not a migration. Runtime Management already reads this table; tests prove both invalid Hosted and invalid Self-hosted attempts appear through ListRuntimeAdmissionFailures.

- [ ] **Step 8: Validate RESUME without database changes**

After token/runtime ownership checks, validate resume.dependency_profile before token rotation and registration; copy it onto AuthenticatedRuntime. Mismatch does not rotate, upsert, lease, or register. Add no migration.

- [ ] **Step 9: Run and commit**

~~~bash
cd control-panel-service
go test ./internal/config ./internal/runtimechannel ./internal/provision ./internal/runtime ./cmd/control-panel-service
go vet ./internal/config ./internal/runtimechannel ./internal/provision ./internal/runtime ./cmd/control-panel-service
git add internal/config/config.go internal/config/config_test.go config.yaml internal/runtimechannel/auth.go internal/runtimechannel/auth_test.go internal/runtimechannel/service.go internal/runtimechannel/grpc.go internal/runtimechannel/grpc_startup_failure_test.go internal/runtimechannel/dependency_admission_test.go internal/runtimechannel/startup_failure_test.go internal/provision/provision.go internal/provision/docker.go internal/provision/docker_test.go internal/runtime/service.go internal/runtime/service_test.go cmd/control-panel-service/main.go cmd/control-panel-service/main_test.go
git commit -m "feat: admit exact runtime dependency profile"
~~~

### Task 12: Preserve Structured Runtime Errors Through gRPC and HTTP

**Files:**
- Modify: golang-lib/pkg/errors/error.go
- Modify: golang-lib/pkg/errors/error_test.go
- Modify: golang-lib/pkg/errors/grpc.go
- Modify: golang-lib/pkg/errors/grpc_test.go
- Modify: control-panel-service/internal/runtimechannel/proxy.go
- Modify: control-panel-service/internal/runtimechannel/platform_proxy_test.go
- Modify: control-panel-service/internal/runtime/grpc.go
- Modify: control-panel-service/internal/runtime/grpc_status_test.go
- Modify: gateway/quant-handler/internal/app/strategy_route.go
- Modify: gateway/quant-handler/internal/app/app.go
- Create: gateway/quant-handler/internal/app/runtime_dependency_error.go
- Create: gateway/quant-handler/internal/app/runtime_dependency_error_test.go
- Modify: gateway/quant-handler/internal/app/strategy.go
- Modify: gateway/quant-handler/internal/app/strategy_test.go
- Modify: gateway/quant-handler/internal/app/strategy_cutover_test.go
- Modify: gateway/quant-handler/internal/app/backtest_download_jobs.go
- Modify: gateway/quant-handler/internal/app/backtest_coverage_test.go
- Modify: gateway/quant-handler/internal/app/strategy_mgmt.go
- Create: gateway/quant-handler/internal/app/strategy_mgmt_test.go

**Interfaces:**
- Consumes: StreamError.DependencyError, ValidateStrategySource response, synchronous gRPC CommonError, and asynchronous Preview/Run job errors.
- Produces: lossless details map, `POST /api/strategy/validate-source`, and the same safe HTTP runtime_error envelope for direct calls and polled jobs while preserving Runtime-independent CreateStrategy.

- [ ] **Step 1: Write round-trip and HTTP tests**

Assert CommonError{Code, Message, Details} survives the actual
`ToGRPCStatus`/`FromGRPCStatus` round trip with details keys code, module,
runtime_profile, runtime_profile_version, image_build_id. Handler tests require:

~~~json
{
  "error": "Python module 'google.cloud' is not available",
  "runtime_error": {
    "code": "STRATEGY_DEPENDENCY_UNAVAILABLE",
    "module": "google.cloud",
    "runtime_profile": "platform-python-3.13",
    "runtime_profile_version": "1.0.0",
    "image_build_id": "build-1",
    "message": "Python module 'google.cloud' is not available"
  }
}
~~~

Add regressions for all three HTTP shapes:

- `POST /api/strategy/validate-source` with `{ "runtime_id": "rt-1", "source": "import numpy" }` returns `{ok, issues, runtime_profile}` and routes only by that owned runtime_id; missing runtime_id/source is 400 and no Runtime is created.
- A download-and-run job whose Preview or Run RPC returns the example dependency detail reaches status=error with the same `runtime_error` object; `error` equals only the safe message, not `err.Error()` or serialized status data.
- `POST /api/strategies` without runtime_id still calls core CreateStrategy and returns 201; it never calls control-panel or Validate.

- [ ] **Step 2: Run and verify RED**

~~~bash
cd golang-lib
go test ./pkg/errors -count=1
cd ../control-panel-service
go test ./internal/runtimechannel ./internal/runtime -run 'Dependency|Status' -count=1
cd ../gateway/quant-handler
go test ./internal/app -run 'RuntimeDependency|ValidateStrategySource|DownloadAndRun|CreateStrategy|Cutover' -count=1
~~~

Expected: Details are dropped and HTTP emits only error.

- [ ] **Step 3: Extend CommonError and gRPC round trip**

Add Details map[string]string with defensive copy and JSON encoding. Keep compatibility for errors with no details. streamErrorToStatus maps gRPC code as today, converts the six dependency fields into CommonError details, and uses the existing StringValue status-detail transport; quant-handler decodes it.

- [ ] **Step 4: Proxy Validate and typed errors**

Implement control-panel ValidateStrategySource by InvokeStrategyUnaryByRuntimeID using request.user_id/runtime_id. Add it to controlPanelStrategyClient. No route fallback is allowed. This optional API creates one-shot worker validation only when explicitly called.

- [ ] **Step 5: Add the explicit HTTP Validate endpoint**

Register `POST /api/strategy/validate-source` in `app.go`. Define request fields `runtime_id` and `source`; derive user_id only from the authenticated request. `handleValidateStrategySource` rejects an empty/oversized source and calls the existing `strategyClient(..., routeEnsure, runtimeID, ...)` path, whose current contract requires runtime_id and invokes ResolveRuntimeRouteByID rather than provisioning a Runtime. It then calls the control-panel proxy and returns all issues plus the runtime profile. It creates no Strategy, Runtime, or Session. Transport/admission errors use the same structured error mapper; a normal source rejection remains HTTP 200 with `ok=false`.

Keep `handleStrategiesCollection` unchanged except for its regression test. Do not add Validate to Create, do not add runtime_id to the Create request, and do not make frontend save wait for validation. A future editor may call this endpoint only after the user has explicitly selected a Runtime.

- [ ] **Step 6: Emit safe synchronous and asynchronous HTTP errors**

`runtimeDependencyErrorFromGRPC` accepts only the five stable codes and six allowlisted fields; unknown details fall back to existing grpcToHTTP/writeErr. Preview/Run use writeRuntimeDependencyError. Add `RuntimeError *runtimeDependencyHTTPError \`json:"runtime_error,omitempty"\`` to `downloadRunJob`. Its failure helper uses the same mapper for both Preview and Run; when recognized, it stores the safe message in `Error` and a defensive copy in `RuntimeError`, and never stores `err.Error()`. Success clears both. Status polling returns this field unchanged. Leave ordinary CreateStrategy request shape and call order unchanged; runtime_id is neither required nor silently provisioned.

- [ ] **Step 7: Run and commit per repository**

~~~bash
cd golang-lib
go test ./pkg/errors
go vet ./pkg/errors
git add pkg/errors/error.go pkg/errors/error_test.go pkg/errors/grpc.go pkg/errors/grpc_test.go
git commit -m "feat: preserve structured grpc error details"
cd ../control-panel-service
go test ./internal/runtimechannel ./internal/runtime
git add internal/runtimechannel/proxy.go internal/runtimechannel/platform_proxy_test.go internal/runtime/grpc.go internal/runtime/grpc_status_test.go
git commit -m "feat: proxy runtime dependency failures"
cd ../gateway/quant-handler
go test ./internal/app
git add internal/app/app.go internal/app/strategy_route.go internal/app/runtime_dependency_error.go internal/app/runtime_dependency_error_test.go internal/app/strategy.go internal/app/strategy_test.go internal/app/strategy_cutover_test.go internal/app/backtest_download_jobs.go internal/app/backtest_coverage_test.go internal/app/strategy_mgmt.go internal/app/strategy_mgmt_test.go
git commit -m "feat: expose runtime dependency errors"
~~~

### Task 13: Display Actionable Errors Without Changing Strategy Creation UX

**Files:**
- Modify: gateway/quant-frontend/src/api/client.ts
- Modify: gateway/quant-frontend/src/pages/PortfolioDetail.tsx
- Modify: gateway/quant-frontend/src/pages/RuntimeManagement.tsx
- Modify: gateway/quant-frontend/src/pages/StrategyList.tsx
- Create: gateway/quant-frontend/scripts/runtime-dependency-contract.test.mjs
- Modify: gateway/quant-frontend/package.json

**Interfaces:**
- Consumes: optional runtime_error HTTP body on direct responses and download-and-run job status, ValidateStrategySource HTTP response, and RuntimeAdmissionFailure code/reason.
- Produces: categorized module/profile/build messages for Preview/Run/polled jobs/Hosted or Self-hosted admission, plus an optional Validate client while Strategy Create remains unchanged.

- [ ] **Step 1: Write executable frontend assertions**

Test formatRuntimeDependencyError for all five codes and missing optional body. Test `validateStrategySource(runtimeID, source)` posts the exact HTTP shape and parses `{ok, issues, runtime_profile}`. Structural assertions require PortfolioDetail to pass both immediate API errors and `DownloadRunJob.runtime_error` through the formatter, RuntimeManagement to show invalid/mismatch failure code and safe reason, and StrategyList create payload/form to contain no required runtime selector/runtime_id and no implicit Validate call.

- [ ] **Step 2: Run and verify RED**

~~~bash
cd gateway/quant-frontend
node scripts/runtime-dependency-contract.test.mjs
~~~

Expected: formatter/type/test script does not exist.

- [ ] **Step 3: Add typed parse/format behavior**

Add RuntimeDependencyError, APIError, StrategySourceValidationResponse, and `runtime_error?: RuntimeDependencyError` on DownloadRunJob. `parseErr` preserves runtime_error rather than converting immediately to string. Formatter categories are: unsupported strategy dependency, Runtime dependency unavailable, strategy import initialization failed, Runtime image profile invalid, and Runtime profile mismatch. Always display module when present, profile/version, and image build ID; never render stack/path/environment fields. Add `validateStrategySource` as an exported optional client; no existing save path calls it.

- [ ] **Step 4: Wire pages and preserve creation**

PortfolioDetail uses the formatter for direct Preview/Run failures and terminal download-and-run job failures, preferring structured detail over the legacy `job.error` string. RuntimeManagement renders both RUNTIME_DEPENDENCY_PROFILE_INVALID and RUNTIME_DEPENDENCY_PROFILE_MISMATCH from the existing admission-failure list. StrategyList retains current fields and createStrategy call; add only a regression marker/test if needed, not a Runtime selector or automatic validation.

- [ ] **Step 5: Run build/tests and commit**

~~~bash
cd gateway/quant-frontend
node scripts/runtime-dependency-contract.test.mjs
bash -euo pipefail -c '
  tests="$(git ls-files "scripts/*.test.mjs" | LC_ALL=C sort)"
  test -n "$tests"
  while IFS= read -r test_file; do node "$test_file"; done <<<"$tests"
'
npm run build
git add src/api/client.ts src/pages/PortfolioDetail.tsx src/pages/RuntimeManagement.tsx src/pages/StrategyList.tsx scripts/runtime-dependency-contract.test.mjs package.json
git commit -m "feat: explain runtime dependency failures"
~~~

### Task 14: Add Deployment Gates, Read-Only Saved-Strategy Scan, and Current Documentation

**Files:**
- Modify: hushine-deploy/Makefile
- Create: hushine-deploy/scripts/runtime-dependency-contract.test.sh
- Create: hushine-deploy/scripts/scan-saved-strategy-imports.py
- Modify: hushine-deploy/docs/runtime-operator-flow.md
- Modify: hushine-deploy/docs/production-deploy-checklist.md
- Modify: strategy-library/README.md
- Modify: strategy-service/README.md
- Modify: strategy-debugger-cli/README.md
- Modify: control-panel-service/README.md

**Interfaces:**
- Consumes: all repository gates, two clean final image references, an optional read-only Portfolio DSN environment-variable name, and optional existing saved strategies.
- Produces: one paired acceptance command, JSON scan report, first-introduction baseline evidence, deployment/rollback procedure, current debugger/operator commands, and an AGENTS handoff note without exposing secrets.

- [ ] **Step 1: Write shell contract and scanner tests first**

runtime-dependency-contract.test.sh must fail if either normal or coverage image verification is skipped, profile/digest JSON differs, coverage becomes public, or the fault build succeeds. Scanner unit mode accepts JSON rows and asserts unsupported roots include strategy_id/name/import/line, allowed roots are omitted, source is never executed, ordering is deterministic, and input is unchanged. Add explicit negative tests proving `datetime`/`os`, `strategy_service.types`, and `hushine_strategy` imports never appear as affected findings; add one positive unsupported-root case beside each negative family so an accidentally disabled scanner cannot pass.

- [ ] **Step 2: Run and verify RED**

~~~bash
cd hushine-deploy
bash scripts/runtime-dependency-contract.test.sh --self-test
~~~

Expected: script/scanner do not exist.

- [ ] **Step 3: Implement the read-only scanner**

Production mode accepts `--dsn-env PORTFOLIO_READONLY_DSN`, reads the value only from that named process environment variable, and performs only:

~~~sql
SELECT strategy_id, user_id, name, version, code
FROM strategies
WHERE archived = FALSE
ORDER BY strategy_id
~~~

Reject a missing/empty variable without printing its value. Never accept a DSN value as a CLI argument, include it in JSON, or log it. Parse the AST and call the shared `validate_dependency_imports` API with the loader profile, `sys.stdlib_module_names`, and the exact safe platform prefixes `("strategy_service.types", "hushine_strategy")`; do not reimplement scanner-specific root filtering from `iter_imported_modules`. Report only `UNSUPPORTED_STRATEGY_DEPENDENCY` findings as migration impact, while preserving stable line/module data. Standard-library imports and either platform prefix are therefore omitted even when an import finder cannot resolve them in the deploy tool's environment. Do not exec/import user code or issue write/DDL/lock statements. JSON includes profile/version/digest, scanned/affected counts, and sorted findings.

- [ ] **Step 4: Add exact Make acceptance targets**

Require the immutable pre-implementation `RUNTIME_DEPENDENCY_BASE_SHA`; do not provide a moving/default branch value. Avoid assuming any repository already has a `.venv` before the target starts:

~~~make
runtime-dependency-envs:
	test "$${#RUNTIME_DEPENDENCY_BASE_SHA}" -eq 40
	git -C strategy-library cat-file -e "$${RUNTIME_DEPENDENCY_BASE_SHA}^{commit}"
	test ! -e strategy-library/uv.lock
	cd strategy-library && uv run --isolated --no-project --with-editable '.[test]' \
		python -c 'import hushine_strategy, pytest'
	test ! -e strategy-library/uv.lock
	uv sync --project strategy-service --python 3.13 --frozen --extra dev
	cd strategy-debugger-cli && ./scripts/with-local-strategy-library-git.sh \
		../strategy-library uv sync --frozen --extra test

runtime-dependency-contract: runtime-dependency-envs
	cd strategy-library && uv run --isolated --no-project --with-editable '.[test]' \
		python scripts/check_runtime_dependency_contract.py \
		--service-project ../strategy-service/pyproject.toml \
		--service-lock ../strategy-service/uv.lock \
		--debugger-project ../strategy-debugger-cli/pyproject.toml \
		--debugger-lock ../strategy-debugger-cli/uv.lock \
		--installed-python strategy-service=../strategy-service/.venv/bin/python \
		--installed-python-version strategy-service=3.13 \
		--installed-python debugger=../strategy-debugger-cli/.venv/bin/python \
		--installed-python-version debugger='>=3.12' \
		--baseline-ref "$(RUNTIME_DEPENDENCY_BASE_SHA)"

runtime-images-verify:
	$(MAKE) -C strategy-service runtime-images-verify

runtime-dependency-acceptance: runtime-dependency-contract runtime-images-verify
	bash hushine-deploy/scripts/runtime-dependency-contract.test.sh
~~~

The gate invokes these exact closure paths:

- strategy-service/scripts/verify_runtime_image.sh for each final image;
- strategy-service/scripts/smoke_strategy_runtime.sh for each final image;
- strategy-service/tests/test_strategy_runtime_dockerfile.py and test_runtime_image_scripts.py;
- hushine-deploy/scripts/runtime-dependency-contract.test.sh for paired/fault/equality acceptance.

The shell acceptance parses checker JSON and accepts baseline state `introduced` only when notice BASELINE_MANIFEST_ABSENT is the sole baseline notice and the exact schema-1 digest/version is present; `present` is the steady-state path. It fails an unresolved ref, any projection rewrite in check mode, a dirty release image, or an installed check that succeeds only with PYTHONPATH/source shadowing. Its smoke calls pass all five named image/profile arguments.

- [ ] **Step 5: Document contract, gates, rollout, and rollback**

Document manifest ownership and generated projections, first-introduction/steady-state baseline behavior, direct locks, clean normal/coverage commands, source-dirty labels, startup/HELLO/RESUME/admission plus Hosted/Self-hosted failure-only reporting, runtime_id-only routing, Preview/Run/download-job validation order, five error codes, unchanged Strategy-first creation, exact optional HTTP Validate contract, standalone debugger bootstrap/profile/repair, read-only scan, ordered rollout, paired rollback, proto ordering with Indicator V2, and no database migration. Explain that the local bare-mirror wrapper is a pre-push development/acceptance transport only: it never enters pyproject/lock/user instructions. Release remains blocked until the coordinated full-system push is complete and the fresh no-mirror network bootstrap below passes; do not perform a partial early strategy-library push.

Preserve the current AGENTS-required strategy-service suite exactly: `PYTHONPATH=.:../strategy-library uv run --frozen --extra dev pytest tests/ -q`. Document that it is a source-development regression, not image closure. Add a separate documented installed/frozen `python -I` gate with no PYTHONPATH for Runtime/debugger proof. Because the workspace root is not Git and its AGENTS.md is outside these repository commits, include a handoff block in `runtime-operator-flow.md` containing the exact new debugger bootstrap and installed-gate commands for the workspace owner to mirror into AGENTS.md after rollout; do not silently mutate that root file in this change.

- [ ] **Step 6: Commit docs/gates per repository before clean-image acceptance**

~~~bash
cd hushine-deploy
git add Makefile scripts/runtime-dependency-contract.test.sh scripts/scan-saved-strategy-imports.py docs/runtime-operator-flow.md docs/production-deploy-checklist.md
git commit -m "docs: operate runtime dependency contract"
cd ../strategy-library
git add README.md
git commit -m "docs: describe runtime dependency manifest"
cd ../strategy-service
git add README.md
git commit -m "docs: describe runtime dependency gates"
cd ../strategy-debugger-cli
git add README.md
git commit -m "docs: describe debugger runtime profile"
cd ../control-panel-service
git add README.md
git commit -m "docs: describe runtime profile admission"
~~~

The image builder refuses dirty strategy-service, strategy-library, or
golang-lib worktrees, so these commits must precede the clean acceptance build.
Ignored local artifacts are allowed to remain on the host only because the
sealed Git-derived context proves they cannot enter Docker. Review each staged
diff and preserve unrelated dirty paths.

- [ ] **Step 7: Repin debugger after the final dependency-plan library commit**

~~~bash
cd /Users/xdy/Workplace/hushine-worktrees/medium-cleanup/strategy-debugger-cli
LIBRARY_COMMIT="$(git -C ../strategy-library rev-parse HEAD)"
test "${#LIBRARY_COMMIT}" -eq 40
./scripts/with-local-strategy-library-git.sh ../strategy-library \
  uv add --no-sync "hushine-strategy-library @ git+https://github.com/hushine-tech/strategy-library.git@${LIBRARY_COMMIT}"
./scripts/with-local-strategy-library-git.sh ../strategy-library uv lock --check
rg -n "https://github.com/hushine-tech/strategy-library.git.*${LIBRARY_COMMIT}" pyproject.toml uv.lock
if rg -n 'file:|\.\./strategy-library|insteadOf|mirror' pyproject.toml uv.lock; then exit 1; fi
bash scripts/bootstrap-standalone.test.sh --library-repo ../strategy-library
git add pyproject.toml uv.lock
git commit -m "build: repin debugger to final dependency library"
~~~

The standalone gate runs Python 3.12, 3.13, and 3.14 and verifies canonical direct-url metadata. No later task in this dependency plan may modify strategy-library. The ordered Spot plan intentionally adds later library behavior and therefore repeats this exact repin after its own final library commit.

- [ ] **Step 8: Run focused acceptance from clean commits**

~~~bash
cd /Users/xdy/Workplace/hushine-worktrees/medium-cleanup
test -z "$(git -C strategy-library status --porcelain)"
test -z "$(git -C strategy-service status --porcelain)"
test -z "$(git -C golang-lib status --porcelain)"
test -z "$(git -C strategy-debugger-cli status --porcelain)"
make -f hushine-deploy/Makefile runtime-dependency-acceptance \
  RUNTIME_DEPENDENCY_BASE_SHA="$RUNTIME_DEPENDENCY_BASE_SHA"
~~~

Expected: checker reports a valid first-introduction baseline against the immutable pre-change SHA; both clean no-cache final builds/verifiers/smokes, profile equality with distinct normal/coverage build IDs, coverage denial, and build/startup fault checks pass.

### Task 15: Full Regression, Real Preview/Run, Review, and Handoff

**Files:**
- Verify only; fix failures in the task-owned file that caused them.

**Interfaces:**
- Consumes: all implementation commits and a test stack with one admitted Runtime.
- Produces: evidence for every acceptance criterion; no push, merge, release, Notion mutation, or unrequested deployment.

- [ ] **Step 1: Run complete Python suites**

~~~bash
cd strategy-library
uv run --isolated --no-project --with-editable '.[test]' pytest tests/ -q
cd ../strategy-debugger-cli
./scripts/with-local-strategy-library-git.sh ../strategy-library \
  uv run --frozen --extra test pytest tests/ -q
bash scripts/bootstrap-standalone.test.sh --library-repo ../strategy-library
cd ../strategy-service
PYTHONPATH=.:../strategy-library uv run --frozen --extra dev pytest tests/ -q
cd ../golang-lib/py_log
uv run --isolated --no-project --with-editable '.[dev]' pytest -q
~~~

The final command is the AGENTS-required source-development suite in a
no-lock, no-project environment; assert `golang-lib/py_log/uv.lock` is absent
before and after it. Then prove installed closure separately, with no source
shadowing:

~~~bash
cd strategy-service
env -u PYTHONPATH -u PYTHONHOME -u VIRTUAL_ENV \
  .venv/bin/python -I -m hushine_strategy.runtime_dependencies \
  verify-installed --python-constraint 3.13 --json
cd ../strategy-debugger-cli
env -u PYTHONPATH -u PYTHONHOME -u VIRTUAL_ENV \
  .venv/bin/python -I -m hushine_strategy.runtime_dependencies \
  verify-installed --python-constraint '>=3.12' --json
~~~

Expected: the source suite and both independent installed/frozen checks pass. Neither installed check may add strategy-library to PYTHONPATH or run from its source directory.

- [ ] **Step 2: Run all Go, vet, and tracked shell tests**

~~~bash
cd strategy-service
go test ./...
go vet ./...
bash scripts/start-bare-runtime-debugpy.test.sh
bash scripts/runtime-agent-platform.test.sh
cd ../control-panel-service
go test ./...
go vet ./...
cd ../gateway/quant-handler
go test ./...
go vet ./...
cd ../../golang-lib
go test ./...
go vet ./...
cd log-shipper
go test ./...
go vet ./...
cd ../elk/kafka-es-bridge
go test ./...
go vet ./...
cd ../../../core-service
go test ./...
go vet ./...
cd ../scraper
go test ./...
go vet ./...
cd ../hushine-deploy
bash -euo pipefail -c '
  tests="$(git ls-files "scripts/*.test.sh" | LC_ALL=C sort)"
  test -n "$tests"
  while IFS= read -r test_file; do bash "$test_file"; done <<<"$tests"
'
~~~

This is the complete current eight-module Go matrix: strategy-service, control-panel-service, gateway/quant-handler, golang-lib, golang-lib/log-shipper, golang-lib/elk/kafka-es-bridge, core-service, and scraper. The Python step also covers `golang-lib/py_log`, and the shell loop covers every tracked hushine-deploy script contract, including those not directly modified by this plan. Do not infer that an untouched repository can skip its required regression.

- [ ] **Step 3: Run frontend and workspace regression**

~~~bash
cd gateway/quant-frontend
bash -euo pipefail -c '
  tests="$(git ls-files "scripts/*.test.mjs" | LC_ALL=C sort)"
  test -n "$tests"
  while IFS= read -r test_file; do node "$test_file"; done <<<"$tests"
'
npm run build
cd ../..
make -f hushine-deploy/Makefile test
cd /Users/xdy/Workplace/hushine
set +e
openspec_output="$(openspec validate --all --strict --no-interactive 2>&1)"
openspec_status=$?
set -e
printf '%s\n' "$openspec_output"
if [ "$openspec_status" -ne 0 ]; then exit "$openspec_status"; fi
if grep -Fq 'No items found to validate' <<<"$openspec_output"; then exit 1; fi
~~~

Expected: all pass, including Futures, Spot, orders, indicators, notifications, Runtime coverage, Windows cross-build, and Runtime-independent Strategy creation.

- [ ] **Step 4: Verify dependency/Indicator V2 descriptor coexistence at the current rollout stage**

Run the descriptor-aware protocol test before and after the ordered Indicator V2 change:

~~~bash
cd strategy-service
PYTHONPATH=.:../strategy-library uv run --frozen --extra dev pytest \
  tests/test_runtime_dependency_proto.py tests/test_runtime_worker_proto.py -q
go test ./internal/runtimeagent -run RuntimeChannelProto -count=1
cd ../control-panel-service
go test ./internal/runtimechannel -run FrameContract -count=1
~~~

At dependency-only handoff, record the legacy WorkerFrame indicator field number 15 plus nested dependency field numbers SessionProgress=6 and result/final/error=5. The full-system acceptance plan then applies Indicator V2 and reruns this same test; final evidence must show WorkerHello.protocol_version field number 5 with runtime value 2, WorkerFrame.indicator_frame_v2 field number 21, WorkerFrame field number 15 reserved, and all nested dependency field numbers unchanged. Descriptor checksum generation from Task 7 must still be deterministic after both proto changes.

- [ ] **Step 5: Repeat final normal/coverage closure from clean commits and cache**

~~~bash
cd strategy-service
test -z "$(git status --porcelain)"
test -z "$(git -C ../strategy-library status --porcelain)"
test -z "$(git -C ../golang-lib status --porcelain)"
./scripts/build_strategy_runtime.sh --all --no-cache --verify acceptance
./scripts/smoke_strategy_runtime.sh \
  --image hushine/strategy-runtime:executor-acceptance \
  --coverage false \
  --profile platform-python-3.13 \
  --version 1.0.0 \
  --digest 8457b3c35618558fc8bfc74d4135b7eb52e00c33a8c9a49d202830f3fd5b62c5
./scripts/smoke_strategy_runtime.sh \
  --image hushine/strategy-runtime:executor-coverage-acceptance \
  --coverage true \
  --profile platform-python-3.13 \
  --version 1.0.0 \
  --digest 8457b3c35618558fc8bfc74d4135b7eb52e00c33a8c9a49d202830f3fd5b62c5
~~~

Expected: clean `source-dirty=false` labels, exact source-state facts, identical profile/version/digest and manifest-generated probes; coverage installed only in coverage image and rejected as user dependency in both. No `--allow-dirty` is permitted here.

- [ ] **Step 6: Run real-stack user-flow acceptance**

Using the existing authenticated flow and an admitted Runtime:

1. Create Strategy without runtime_id and assert 201.
2. Call `POST /api/strategy/validate-source` explicitly with a selected runtime_id; assert success creates no Strategy/Runtime/Session, and a rejected source returns issues/profile.
3. Activate/mount the saved Strategy through the current product flow.
4. Preview and Run the manifest-generated representative source on selected runtime_id.
5. Observe worker readiness before running and a valid running/terminal backtest state.
6. Exercise unsupported, missing requested allowed submodule/parent (UNAVAILABLE), found module with missing transitive dependency (IMPORT_FAILED), and other import-initialization fixtures through direct Preview/Run and download-and-run Preview/Run failures; assert the exact same runtime_error fields/codes in synchronous and polled responses and no transitive module-name leak.
7. Assert failed cases leave no running Session, worker, pending call, or alias.
8. Exercise invalid-profile Hosted and Self-hosted startup fixtures; assert Runtime Management admission failures appear and neither Runtime can resolve a route.
9. Repeat success on coverage Runtime.

Record request/runtime/Session/profile/digest/build IDs without credentials, environment, or paths.

- [ ] **Step 7: Run saved-strategy scan read-only**

~~~bash
PYTHONPATH=strategy-library strategy-service/.venv/bin/python \
  hushine-deploy/scripts/scan-saved-strategy-imports.py \
  --dsn-env PORTFOLIO_READONLY_DSN \
  --output /tmp/hushine-runtime-dependency-scan.json
~~~

Expected: no writes. Report affected strategies; do not install packages or rewrite code.

- [ ] **Step 8: Review and reverify**

Invoke superpowers:requesting-code-review, process findings with superpowers:receiving-code-review, rerun affected tests plus Steps 1–5, then invoke superpowers:verification-before-completion with fresh outputs.

Pre-push evidence in this dependency plan uses only the isolated bare-mirror wrapper for the intentionally unpublished strategy-library SHA. Record the following mandatory deferred gate in the full-system handoff; do not execute it by pushing one repository early. After the main workflow has completed its coordinated pushes for all affected repositories/ordered plans, run from a fresh directory with no URL rewrite, no sibling checkout, a clean HOME, and a clean uv cache:

~~~bash
test -n "$DEBUGGER_PUBLISHED_REF"
test -n "$LIBRARY_PUBLISHED_REF"
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
~~~

The fresh library clone proves the published final SHA is now a `present` dependency baseline. `--network` refuses any local path, mirror option, `url.*.insteadOf`, warm cache, or sibling strategy-library; it runs fresh standalone bootstrap on Python 3.12, 3.13, and 3.14 and verifies the installed distribution's direct_url metadata resolves the exact canonical HTTPS library commit. This post-push gate is required for final release acceptance and is not satisfied by pre-push mirror/offline evidence.

- [ ] **Step 9: Audit scope and hand off**

~~~bash
set +e
rg -n 'scipy|sklearn|statsmodels|pandas_ta|pandas-ta|TA-Lib|debugpy|coverage|pyarrow|pytest' \
  strategy-library/hushine_strategy/runtime_dependencies.toml
manifest_rg_status=$?
set -e
test "$manifest_rg_status" -eq 1
git -C core-service status --short
git -C scraper status --short
git -C strategy-library diff --check
git -C strategy-service diff --check
git -C strategy-debugger-cli diff --check
git -C control-panel-service diff --check
git -C gateway/quant-handler diff --check
git -C gateway/quant-frontend diff --check
git -C golang-lib diff --check
git -C hushine-deploy diff --check
~~~

Expected: manifest search exits exactly 1 (no matches; an I/O error is not
accepted); scraper has no task-owned change; core-service contains only the
reviewed pending-startup wire/service/repository unit; all repository diff
checks pass. Report commits, files/lines, test/vet/shell evidence,
first-baseline state, descriptor coexistence stage, image IDs/labels/source
facts, pre-push mirror/offline standalone debugger evidence, the still-required
post-push no-mirror network gate, scan summary, AGENTS handoff block, and
operational caveats. Stop before push, merge, deployment, release, or Notion
changes; the main acceptance workflow owns coordinated pushes and must attach
the deferred network-gate evidence before release.
