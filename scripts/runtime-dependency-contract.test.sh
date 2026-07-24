#!/usr/bin/env bash
set -euo pipefail

DEPLOY_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
SOURCE_ROOT="${HUSHINE_SOURCE_ROOT:-$(cd "${DEPLOY_ROOT}/.." && pwd -P)}"
SCANNER="${DEPLOY_ROOT}/scripts/scan-saved-strategy-imports.py"
SERVICE_PYTHON="${RUNTIME_DEPENDENCY_PYTHON:-${SOURCE_ROOT}/strategy-service/.venv/bin/python}"

fail() {
  echo "runtime dependency acceptance failed: $*" >&2
  exit 1
}

require_status() {
  local expected="$1"
  local actual="$2"
  local context="$3"
  [[ "${actual}" -eq "${expected}" ]] \
    || fail "${context}: expected status ${expected}, got ${actual}"
}

scanner_self_test() {
  [[ -x "${SERVICE_PYTHON}" ]] || fail "missing installed service Python: ${SERVICE_PYTHON}"
  [[ -f "${SCANNER}" ]] || fail "missing saved-strategy scanner: ${SCANNER}"

  local fixture_dir input report marker before after status
  fixture_dir="$(mktemp -d "${TMPDIR:-/tmp}/hushine-scan-contract.XXXXXX")"
  trap 'rm -rf -- "${fixture_dir}"' RETURN
  input="${fixture_dir}/rows.json"
  report="${fixture_dir}/report.json"
  marker="${fixture_dir}/source-was-executed"

  "${SERVICE_PYTHON}" - "${input}" "${marker}" <<'PY'
import json
from pathlib import Path
import sys

output = Path(sys.argv[1])
marker = sys.argv[2]
oversize = "#" * (1024 * 1024 + 1)
rows = [
    {
        "strategy_id": 1,
        "user_id": 101,
        "name": "safe-hosted-imports",
        "version": "1",
        "code": (
            "import datetime\n"
            "import os\n"
            "from strategy_service.types import OrderDecision\n"
            "from hushine_strategy import Exchange\n"
        ),
    },
    {
        "strategy_id": 2,
        "user_id": 102,
        "name": "unsupported-root",
        "version": "1",
        "code": "import definitely_missing_vendor\n",
    },
    {
        "strategy_id": 3,
        "user_id": 103,
        "name": "protected-module-object",
        "version": "1",
        "code": "import hushine_strategy\n",
    },
    {
        "strategy_id": 4,
        "user_id": 104,
        "name": "protected-nested-symbol",
        "version": "1",
        "code": "from hushine_strategy.runtime_dependencies import subprocess\n",
    },
    {
        "strategy_id": 5,
        "user_id": 105,
        "name": "protected-notifier-symbol",
        "version": "1",
        "code": "from hushine_strategy.notifier import Path\n",
    },
    {
        "strategy_id": 6,
        "user_id": 106,
        "name": "dynamic-importlib-alias",
        "version": "1",
        "code": "import importlib as loader\nloader.import_module('vendor')\n",
    },
    {
        "strategy_id": 7,
        "user_id": 107,
        "name": "dynamic-exec",
        "version": "1",
        "code": "exec('result = 1')\n",
    },
    {
        "strategy_id": 8,
        "user_id": 108,
        "name": "builtins-smuggling",
        "version": "1",
        "code": "runner = __builtins__['exec']\nrunner('result = 1')\n",
    },
    {
        "strategy_id": 9,
        "user_id": 109,
        "name": "invalid-syntax",
        "version": "1",
        "code": "def broken(:\n",
    },
    {
        "strategy_id": 10,
        "user_id": 110,
        "name": "oversize-source",
        "version": "1",
        "code": oversize,
    },
    "not-an-object",
    {
        "strategy_id": 12,
        "user_id": 112,
        "name": "missing-version",
        "code": "import datetime\n",
    },
    {
        "strategy_id": 13,
        "user_id": 113,
        "name": "must-not-execute",
        "version": "1",
        "code": f"from pathlib import Path\nPath({marker!r}).write_text('executed')\n",
    },
    {
        "strategy_id": 14,
        "user_id": 114,
        "name": "later-valid-row",
        "version": "1",
        "code": "import another_missing_vendor\n",
    },
]
for row in rows:
    if isinstance(row, dict) and "code" in row and "code_octets" not in row:
        row["code_octets"] = len(row["code"].encode("utf-8"))
output.write_text(json.dumps(rows, ensure_ascii=False), encoding="utf-8")
PY

  before="$(shasum -a 256 "${input}" | awk '{print $1}')"
  set +e
  env -u PYTHONPATH -u PYTHONHOME -u VIRTUAL_ENV \
    "${SERVICE_PYTHON}" -I "${SCANNER}" \
      --unit-json "${input}" --output "${report}"
  status=$?
  set -e
  require_status 1 "${status}" "unit scan with migration findings"
  after="$(shasum -a 256 "${input}" | awk '{print $1}')"
  [[ "${before}" == "${after}" ]] || fail "unit scan modified its input"
  [[ ! -e "${marker}" ]] || fail "scanner executed saved strategy source"

  "${SERVICE_PYTHON}" -I - "${report}" <<'PY'
import json
from pathlib import Path
import sys

report = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
assert report["schema_version"] == 1
assert report["runtime_profile"] == {
    "digest": "8457b3c35618558fc8bfc74d4135b7eb52e00c33a8c9a49d202830f3fd5b62c5",
    "name": "platform-python-3.13",
    "version": "1.0.0",
}
assert report["summary"]["scanned"] == 14
assert set(report["summary"]["by_kind"]) == {
    "dependency", "dynamic_safety", "platform_safety", "scan_error"
}
findings = report["findings"]
assert report["summary"]["findings"] == len(findings)
assert report["summary"]["affected"] == len({item["strategy_id"] for item in findings})
assert all(set(item) == {
    "strategy_id", "name", "kind", "code", "module", "symbol", "line"
} for item in findings)
assert all(isinstance(item["line"], int) and item["line"] >= 0 for item in findings)

by_id = {}
for item in findings:
    by_id.setdefault(item["strategy_id"], []).append(item)
assert 1 not in by_id
assert 13 not in by_id
assert any(item["kind"] == "dependency" and item["module"] == "definitely_missing_vendor" for item in by_id[2])
assert any(item["kind"] == "platform_safety" and item["module"] == "hushine_strategy" for item in by_id[3])
assert not any(item["kind"] == "dependency" for item in by_id[3])
assert any(item["kind"] == "platform_safety" and item["symbol"] == "subprocess" for item in by_id[4])
assert any(item["kind"] == "platform_safety" and item["symbol"] == "Path" for item in by_id[5])
assert any(item["kind"] == "dynamic_safety" and item["module"] == "importlib" for item in by_id[6])
assert any(item["kind"] == "dynamic_safety" and item["symbol"] == "exec" for item in by_id[7])
assert any(item["kind"] == "dynamic_safety" and item["symbol"] in {"exec", "__builtins__"} for item in by_id[8])
assert [item["code"] for item in by_id[9]] == ["INVALID_STRATEGY_SYNTAX"]
assert [item["code"] for item in by_id[10]] == ["STRATEGY_SOURCE_TOO_LARGE"]
assert [item["code"] for item in by_id["row:000011"]] == ["INVALID_STRATEGY_ROW"]
assert [item["code"] for item in by_id[12]] == ["INVALID_STRATEGY_ROW"]
assert any(item["kind"] == "dependency" and item["module"] == "another_missing_vendor" for item in by_id[14])
expected_order = sorted(
    findings,
    key=lambda item: (
        (0, item["strategy_id"]) if isinstance(item["strategy_id"], int)
        else (1, item["strategy_id"]),
        item["line"], item["kind"], item["code"], item["module"], item["symbol"],
    ),
)
assert findings == expected_order
PY

  "${SERVICE_PYTHON}" -I - "${SCANNER}" <<'PY'
from contextlib import redirect_stderr, redirect_stdout
import importlib.util
import io
import json
import os
from pathlib import Path
import sys
from types import SimpleNamespace

scanner_path = Path(sys.argv[1])
spec = importlib.util.spec_from_file_location("saved_strategy_scanner", scanner_path)
module = importlib.util.module_from_spec(spec)
assert spec.loader is not None
sys.modules[spec.name] = module
spec.loader.exec_module(module)
profile = module.load_runtime_dependency_profile()

# Unexpected per-row scanner failures are isolated and do not prevent later rows.
original_scan_source = module.scan_source
def injected(source, selected_profile):
    if "INJECT_SCAN_FAILURE" in source:
        raise RuntimeError("sensitive exception text")
    return original_scan_source(source, selected_profile)
module.scan_source = injected
rows = [
    {"strategy_id": 20, "user_id": 120, "name": "injected", "version": "1", "code_octets": 21, "code": "# INJECT_SCAN_FAILURE"},
    {"strategy_id": 21, "user_id": 121, "name": "later", "version": "1", "code_octets": 20, "code": "import missing_later"},
]
report = module.scan_rows(rows, profile)
assert any(item["strategy_id"] == 20 and item["code"] == "STRATEGY_SCAN_FAILED" for item in report["findings"])
assert any(item["strategy_id"] == 21 and item["kind"] == "dependency" for item in report["findings"])
assert "sensitive exception text" not in json.dumps(report)
module.scan_source = original_scan_source

class Cursor:
    def __init__(self, connection, name):
        self.connection = connection
        self.name = name
        self.itersize = None
        self.closed = False
        self.index = 0
    def execute(self, statement):
        self.connection.events.append(("execute", self.name, statement))
    def fetchmany(self, size):
        self.connection.events.append(("fetchmany", self.name, size))
        if self.index:
            return []
        self.index += 1
        return [(31, 131, "db-safe", "1", 16, "import datetime\n")]
    def close(self):
        self.closed = True
        self.connection.events.append(("cursor-close", self.name))

class Connection:
    def __init__(self):
        self.events = []
        self.cursors = []
    def set_session(self, **kwargs):
        self.events.append(("set-session", kwargs))
    def cursor(self, name=None):
        cursor = Cursor(self, name)
        self.cursors.append(cursor)
        self.events.append(("cursor", name))
        return cursor
    def rollback(self):
        self.events.append(("rollback",))
    def close(self):
        self.events.append(("connection-close",))

connection = Connection()
driver = SimpleNamespace(connect=lambda dsn: connection)
db_report = module.scan_database("postgresql://secret.invalid/portfolio", profile, driver)
assert db_report["summary"]["scanned"] == 1
assert connection.events[0] == ("set-session", {"readonly": True, "autocommit": False})
executed = [event for event in connection.events if event[0] == "execute"]
assert executed == [
    ("execute", None, "SET TRANSACTION READ ONLY"),
    ("execute", module.SERVER_CURSOR_NAME, module.SELECT_SQL),
]
assert ("fetchmany", module.SERVER_CURSOR_NAME, 100) in connection.events
assert connection.events[-2:] == [("rollback",), ("connection-close",)]
assert all(cursor.closed for cursor in connection.cursors)

fatal_expected = module.FATAL_PAYLOAD
secret = "postgresql://top-secret.invalid/portfolio"
os.environ["SCANNER_FATAL_DSN"] = secret
module.load_database_driver = lambda: SimpleNamespace(
    connect=lambda _dsn: (_ for _ in ()).throw(RuntimeError("database leaked " + secret))
)
stdout = io.StringIO()
with redirect_stdout(stdout):
    status = module.main(["--dsn-env", "SCANNER_FATAL_DSN"])
assert status == 2
assert json.loads(stdout.getvalue()) == fatal_expected
assert secret not in stdout.getvalue()

os.environ.pop("SCANNER_MISSING_DSN", None)
stdout = io.StringIO()
with redirect_stdout(stdout):
    status = module.main(["--dsn-env", "SCANNER_MISSING_DSN"])
assert status == 2
assert json.loads(stdout.getvalue()) == fatal_expected

cli_secret = "postgresql://cli-secret.invalid/portfolio"
stdout = io.StringIO()
stderr = io.StringIO()
with redirect_stdout(stdout), redirect_stderr(stderr):
    status = module.main(["--dsn-env", "SCANNER_MISSING_DSN", cli_secret])
assert status == 2
assert json.loads(stdout.getvalue()) == fatal_expected
assert stderr.getvalue() == ""
assert cli_secret not in stdout.getvalue() + stderr.getvalue()
PY

  trap - RETURN
  rm -rf -- "${fixture_dir}"
}

makefile_self_test() {
  "${SERVICE_PYTHON}" -I - "${DEPLOY_ROOT}/Makefile" <<'PY'
from pathlib import Path
import sys

text = Path(sys.argv[1]).read_text(encoding="utf-8")
required = (
    "runtime-dependency-envs:",
    'test "$${#RUNTIME_DEPENDENCY_BASE_SHA}" -eq 40',
    'git -C "$(SOURCE_ROOT)/strategy-library" cat-file -e "$${RUNTIME_DEPENDENCY_BASE_SHA}^{commit}"',
    'test ! -e "$(SOURCE_ROOT)/strategy-library/uv.lock"',
    "uv run --isolated --no-project --with-editable '.[test]'",
    'uv sync --project "$(SOURCE_ROOT)/strategy-service" --python 3.13 --frozen --extra dev',
    "./scripts/with-local-strategy-library-git.sh",
    "runtime-dependency-contract: runtime-dependency-envs",
    "--installed-python strategy-service=../strategy-service/.venv/bin/python",
    "--installed-python debugger=../strategy-debugger-cli/.venv/bin/python",
    "--baseline-ref \"$(RUNTIME_DEPENDENCY_BASE_SHA)\"",
    "--json",
    "runtime-images-verify:",
    '$(MAKE) -C "$(SOURCE_ROOT)/strategy-service" runtime-images-verify',
    "runtime-dependency-acceptance: runtime-dependency-contract runtime-images-verify",
    'RUNTIME_DEPENDENCY_CHECKER_JSON="$$(cd "$(SOURCE_ROOT)/strategy-library"',
    'bash $(DEPLOY_ROOT)/scripts/runtime-dependency-contract.test.sh',
)
for literal in required:
    assert literal in text, literal
assert text.count('test ! -e "$(SOURCE_ROOT)/strategy-library/uv.lock"') >= 2
assert "RUNTIME_DEPENDENCY_BASE_SHA ?=" not in text
assert "RUNTIME_DEPENDENCY_BASE_SHA :=" not in text
PY
}

acceptance_self_test() {
  local fixture_dir fake_bin fake_verify fake_smoke fake_source_runner gate_log docker_log
  local base_sha valid_json present_json output rc
  fixture_dir="$(mktemp -d "${TMPDIR:-/tmp}/hushine-runtime-acceptance.XXXXXX")"
  trap 'rm -rf -- "${fixture_dir}"' RETURN
  fake_bin="${fixture_dir}/bin"
  fake_verify="${fixture_dir}/verify"
  fake_smoke="${fixture_dir}/smoke"
  fake_source_runner="${fixture_dir}/source-tests"
  gate_log="${fixture_dir}/gates.log"
  docker_log="${fixture_dir}/docker.jsonl"
  output="${fixture_dir}/child-output"
  mkdir -p "${fake_bin}"

  cat >"${fake_bin}/docker" <<'PY'
#!/usr/bin/env python3
import json
import os
import sys
import time

args = sys.argv[1:]
with open(os.environ["FAKE_DOCKER_LOG"], "a", encoding="utf-8") as log:
    log.write(json.dumps(args, sort_keys=True) + "\n")

normal = os.environ["RUNTIME_NORMAL_IMAGE"]
coverage = os.environ["RUNTIME_COVERAGE_IMAGE"]
fault_startup = os.environ["RUNTIME_FAULT_STARTUP_IMAGE"]
profile = os.environ.get("FAKE_IMAGE_PROFILE", os.environ["EXPECTED_PROFILE"])
version = os.environ.get("FAKE_IMAGE_VERSION", os.environ["EXPECTED_VERSION"])
digest = os.environ.get("FAKE_IMAGE_DIGEST", os.environ["EXPECTED_DIGEST"])
dirty = os.environ.get("FAKE_IMAGE_DIRTY", "false")

def config(image):
    is_coverage = image == coverage
    facts = {
        "profile": profile,
        "profile.version": version,
        "contract.sha256": digest,
        "strategy-service.commit": "a" * 40,
        "strategy-library.commit": "b" * 40,
        "golang-lib.commit": "c" * 40,
        "image-build-id": "coverage-build" if is_coverage else "normal-build",
        "source-dirty": dirty,
        "source-state.sha256": "d" * 64,
    }
    labels = {"org.hushine.runtime." + key: value for key, value in facts.items()}
    env_names = {
        "profile": "HUSHINE_RUNTIME_PROFILE_NAME",
        "profile.version": "HUSHINE_RUNTIME_PROFILE_VERSION",
        "contract.sha256": "HUSHINE_RUNTIME_CONTRACT_SHA256",
        "strategy-service.commit": "HUSHINE_RUNTIME_STRATEGY_SERVICE_COMMIT",
        "strategy-library.commit": "HUSHINE_RUNTIME_STRATEGY_LIBRARY_COMMIT",
        "golang-lib.commit": "HUSHINE_RUNTIME_GOLANG_LIB_COMMIT",
        "image-build-id": "HUSHINE_RUNTIME_IMAGE_BUILD_ID",
        "source-dirty": "HUSHINE_RUNTIME_SOURCE_DIRTY",
        "source-state.sha256": "HUSHINE_RUNTIME_SOURCE_STATE_SHA256",
    }
    environment = [env_names[key] + "=" + value for key, value in facts.items()]
    return {"Config": {"Labels": labels, "Env": environment}}

if args[:2] == ["image", "inspect"]:
    print(json.dumps([config(image) for image in args[2:]], sort_keys=True))
    raise SystemExit(0)
if args[:2] == ["image", "rm"]:
    raise SystemExit(0)
if args and args[0] == "build":
    target = args[args.index("--target") + 1]
    if target == "build-gate":
        raise SystemExit(0 if os.environ.get("FAKE_FAULT_BUILD_SUCCEEDS") == "true" else 41)
    if target == "startup-gate":
        raise SystemExit(0)
    raise SystemExit(42)
if args and args[0] == "run":
    index = 1
    while index < len(args) and args[index].startswith("-"):
        if args[index] in {"--entrypoint", "--name", "-e", "--env"}:
            index += 2
        else:
            index += 1
    image = args[index]
    command = args[index + 1:]
    joined = " ".join(command)
    if "next(item.distribution" in joined:
        print("numpy")
        raise SystemExit(0)
    if "import coverage" in joined:
        raise SystemExit(43 if os.environ.get("FAKE_COVERAGE_PUBLIC") == "true" else 0)
    if image == fault_startup:
        if os.environ.get("FAKE_STARTUP_HANG") == "true":
            time.sleep(5)
        if os.environ.get("FAKE_STARTUP_SUCCEEDS") == "true":
            print("runtime-agent started:")
            raise SystemExit(0)
        if os.environ.get("FAKE_STARTUP_MISSING_CODE") != "true":
            print("RUNTIME_DEPENDENCY_PROFILE_INVALID")
        raise SystemExit(44)
    raise SystemExit(45)
raise SystemExit(46)
PY

  cat >"${fake_verify}" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
kind="$(basename "$0")"
[[ "$#" -eq 10 ]]
[[ "$1" == "--image" && "$3" == "--coverage" && "$5" == "--profile" ]]
[[ "$7" == "--version" && "$9" == "--digest" ]]
image="$2"
coverage="$4"
[[ "$6" == "${EXPECTED_PROFILE}" && "$8" == "${EXPECTED_VERSION}" && "${10}" == "${EXPECTED_DIGEST}" ]]
if [[ "${image}" == "${RUNTIME_NORMAL_IMAGE}" ]]; then
  target="normal"
  [[ "${coverage}" == "false" ]]
elif [[ "${image}" == "${RUNTIME_COVERAGE_IMAGE}" ]]; then
  target="coverage"
  [[ "${coverage}" == "true" ]]
else
  exit 48
fi
printf '%s:%s\n' "${kind}" "${target}" >>"${FAKE_GATE_LOG}"
[[ "${FAKE_GATE_FAILURE:-}" != "${kind}:${target}" ]]
SH
  cp "${fake_verify}" "${fake_smoke}"

  cat >"${fake_source_runner}" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf 'source-tests\n' >>"${FAKE_GATE_LOG}"
[[ "${FAKE_SOURCE_TEST_FAILURE:-false}" != "true" ]]
SH
  chmod +x "${fake_bin}/docker" "${fake_verify}" "${fake_smoke}" "${fake_source_runner}"

  base_sha="$(printf 'e%.0s' {1..40})"
  valid_json="$("${SERVICE_PYTHON}" -I - "${base_sha}" <<'PY'
import json
import sys

base = sys.argv[1]
print(json.dumps({
    "baseline": {"commit": base, "ref": base, "state": "introduced"},
    "checked_interpreters": [
        {"expected_python": ">=3.12", "name": "debugger", "path": "/installed/debugger/python"},
        {"expected_python": "3.13", "name": "strategy-service", "path": "/installed/service/python"},
    ],
    "checked_projects": ["debugger", "service"],
    "digest": "8457b3c35618558fc8bfc74d4135b7eb52e00c33a8c9a49d202830f3fd5b62c5",
    "notices": [{
        "code": "BASELINE_MANIFEST_ABSENT",
        "distribution": "",
        "message": "baseline does not contain the runtime dependency manifest",
        "project": "baseline",
    }],
    "ok": True,
    "profile": {
        "debugger_python": ">=3.12",
        "hosted_python": "3.13",
        "name": "platform-python-3.13",
        "schema_version": 1,
        "version": "1.0.0",
    },
    "violations": [],
}, sort_keys=True, separators=(",", ":")))
PY
)"

  mutate_payload() {
    local payload="$1"
    local mutation="$2"
    RUNTIME_TEST_PAYLOAD="${payload}" "${SERVICE_PYTHON}" -I - "${mutation}" <<'PY'
import json
import os
import sys

payload = json.loads(os.environ.pop("RUNTIME_TEST_PAYLOAD"))
mutation = sys.argv[1]
if mutation == "present":
    payload["baseline"]["state"] = "present"
    payload["notices"] = []
elif mutation == "unresolved":
    payload["ok"] = False
    payload["baseline"]["state"] = "not_checked"
    payload["error"] = {"code": "CONFIGURATION_ERROR", "message": "cannot resolve"}
elif mutation == "projection":
    payload["ok"] = False
    payload["violations"] = [{"code": "PROJECTION_NOT_GENERATED"}]
elif mutation == "missing-interpreter":
    payload["checked_interpreters"] = payload["checked_interpreters"][:1]
elif mutation == "introduced-profile":
    payload["profile"]["name"] = "unexpected-profile"
elif mutation == "introduced-digest":
    payload["digest"] = "f" * 64
elif mutation == "baseline-commit":
    payload["baseline"]["commit"] = "f" * 40
else:
    raise AssertionError(mutation)
print(json.dumps(payload, sort_keys=True, separators=(",", ":")))
PY
  }

  present_json="$(mutate_payload "${valid_json}" present)"
  local -a base_environment
  base_environment=(
    "PATH=${fake_bin}:${PATH}"
    "RUNTIME_DEPENDENCY_CHECKER_JSON=${valid_json}"
    "RUNTIME_DEPENDENCY_BASE_SHA=${base_sha}"
    "RUNTIME_DEPENDENCY_PYTHON=${SERVICE_PYTHON}"
    "RUNTIME_VERIFY_SCRIPT=${fake_verify}"
    "RUNTIME_SMOKE_SCRIPT=${fake_smoke}"
    "RUNTIME_SOURCE_TEST_RUNNER=${fake_source_runner}"
    "RUNTIME_NORMAL_IMAGE=hushine/test:normal"
    "RUNTIME_COVERAGE_IMAGE=hushine/test:coverage"
    "RUNTIME_FAULT_BUILD_IMAGE=hushine/test:fault-build"
    "RUNTIME_FAULT_STARTUP_IMAGE=hushine/test:fault-startup"
    "RUNTIME_STARTUP_FAULT_TIMEOUT_SECONDS=1"
    "RUNTIME_FAULT_DOCKERFILE=${SOURCE_ROOT}/strategy-service/tests/fixtures/Dockerfile.runtime-dependency-fault"
    "RUNTIME_SERVICE_DIR=${SOURCE_ROOT}/strategy-service"
    "EXPECTED_PROFILE=platform-python-3.13"
    "EXPECTED_VERSION=1.0.0"
    "EXPECTED_DIGEST=8457b3c35618558fc8bfc74d4135b7eb52e00c33a8c9a49d202830f3fd5b62c5"
    "FAKE_GATE_LOG=${gate_log}"
    "FAKE_DOCKER_LOG=${docker_log}"
  )

  run_fixture() {
    env "${base_environment[@]}" "$@" \
      bash "${BASH_SOURCE[0]}" >"${output}" 2>&1
  }
  expect_rejection() {
    local label="$1"
    shift
    set +e
    run_fixture "$@"
    rc=$?
    set -e
    if [[ "${rc}" -eq 0 ]]; then
      sed -n '1,120p' "${output}" >&2
      fail "self-test mutation was accepted: ${label}"
    fi
  }

  : >"${gate_log}"
  : >"${docker_log}"
  run_fixture || {
    sed -n '1,160p' "${output}" >&2
    fail "valid introduced acceptance fixture was rejected"
  }
  for expected in verify:normal verify:coverage smoke:normal smoke:coverage source-tests; do
    [[ "$(grep -Fxc -- "${expected}" "${gate_log}")" -eq 1 ]] \
      || fail "valid acceptance did not invoke ${expected} exactly once"
  done

  run_fixture "RUNTIME_DEPENDENCY_CHECKER_JSON=${present_json}" || {
    sed -n '1,160p' "${output}" >&2
    fail "valid steady-state acceptance fixture was rejected"
  }
  expect_rejection "normal verifier skipped" "FAKE_GATE_FAILURE=verify:normal"
  expect_rejection "coverage verifier skipped" "FAKE_GATE_FAILURE=verify:coverage"
  expect_rejection "normal smoke skipped" "FAKE_GATE_FAILURE=smoke:normal"
  expect_rejection "coverage smoke skipped" "FAKE_GATE_FAILURE=smoke:coverage"
  expect_rejection "source image tests skipped" "FAKE_SOURCE_TEST_FAILURE=true"
  expect_rejection "image profile differs from checker" "FAKE_IMAGE_PROFILE=wrong-profile"
  expect_rejection "image digest differs from checker" "FAKE_IMAGE_DIGEST=$(printf 'f%.0s' {1..64})"
  expect_rejection "dirty release image" "FAKE_IMAGE_DIRTY=true"
  expect_rejection "coverage became public" "FAKE_COVERAGE_PUBLIC=true"
  expect_rejection "fault build succeeds" "FAKE_FAULT_BUILD_SUCCEEDS=true"
  expect_rejection "startup fault succeeds" "FAKE_STARTUP_SUCCEEDS=true"
  expect_rejection "startup fault omits stable code" "FAKE_STARTUP_MISSING_CODE=true"
  expect_rejection "startup fault hangs" "FAKE_STARTUP_HANG=true"
  expect_rejection "unresolved baseline" \
    "RUNTIME_DEPENDENCY_CHECKER_JSON=$(mutate_payload "${valid_json}" unresolved)"
  expect_rejection "projection rewrite required" \
    "RUNTIME_DEPENDENCY_CHECKER_JSON=$(mutate_payload "${valid_json}" projection)"
  expect_rejection "installed interpreter check omitted" \
    "RUNTIME_DEPENDENCY_CHECKER_JSON=$(mutate_payload "${valid_json}" missing-interpreter)"
  expect_rejection "introduced profile is not exact schema-1 profile" \
    "RUNTIME_DEPENDENCY_CHECKER_JSON=$(mutate_payload "${valid_json}" introduced-profile)"
  expect_rejection "introduced digest is not exact schema-1 digest" \
    "RUNTIME_DEPENDENCY_CHECKER_JSON=$(mutate_payload "${valid_json}" introduced-digest)"
  expect_rejection "resolved baseline commit differs from immutable input" \
    "RUNTIME_DEPENDENCY_CHECKER_JSON=$(mutate_payload "${valid_json}" baseline-commit)"

  "${SERVICE_PYTHON}" -I - "${docker_log}" <<'PY'
import json
from pathlib import Path
import sys

calls = [json.loads(line) for line in Path(sys.argv[1]).read_text().splitlines()]
assert any(call[:2] == ["image", "inspect"] and len(call) == 4 for call in calls)
assert any(call and call[0] == "build" and call[call.index("--target") + 1] == "build-gate" for call in calls)
assert any(call and call[0] == "build" and call[call.index("--target") + 1] == "startup-gate" for call in calls)
coverage_denials = [call for call in calls if call and call[0] == "run" and "import coverage" in " ".join(call)]
assert len(coverage_denials) >= 2
PY

  trap - RETURN
  rm -rf -- "${fixture_dir}"
}

run_acceptance() {
  local checker_json base_sha service_dir verify_script smoke_script source_test_runner
  local normal_image coverage_image fault_build_image fault_startup_image fault_dockerfile
  local checker_values profile version digest inspect_json metadata_status
  local coverage_probe fault_distribution fault_status startup_timeout
  checker_json="${RUNTIME_DEPENDENCY_CHECKER_JSON:-}"
  base_sha="${RUNTIME_DEPENDENCY_BASE_SHA:-}"
  service_dir="${RUNTIME_SERVICE_DIR:-${SOURCE_ROOT}/strategy-service}"
  verify_script="${RUNTIME_VERIFY_SCRIPT:-${service_dir}/scripts/verify_runtime_image.sh}"
  smoke_script="${RUNTIME_SMOKE_SCRIPT:-${service_dir}/scripts/smoke_strategy_runtime.sh}"
  source_test_runner="${RUNTIME_SOURCE_TEST_RUNNER:-}"
  normal_image="${RUNTIME_NORMAL_IMAGE:-hushine/strategy-runtime:executor-contract}"
  coverage_image="${RUNTIME_COVERAGE_IMAGE:-hushine/strategy-runtime:executor-coverage-contract}"
  fault_build_image="${RUNTIME_FAULT_BUILD_IMAGE:-hushine/strategy-runtime:dependency-fault-build}"
  fault_startup_image="${RUNTIME_FAULT_STARTUP_IMAGE:-hushine/strategy-runtime:dependency-fault-startup}"
  startup_timeout="${RUNTIME_STARTUP_FAULT_TIMEOUT_SECONDS:-30}"
  fault_dockerfile="${RUNTIME_FAULT_DOCKERFILE:-${service_dir}/tests/fixtures/Dockerfile.runtime-dependency-fault}"

  [[ -n "${checker_json}" ]] || fail "RUNTIME_DEPENDENCY_CHECKER_JSON is required"
  [[ "${base_sha}" =~ ^[0-9a-f]{40}$ ]] || fail "RUNTIME_DEPENDENCY_BASE_SHA must be an immutable commit"
  [[ -x "${SERVICE_PYTHON}" ]] || fail "missing installed service Python"
  [[ -x "${verify_script}" && -x "${smoke_script}" ]] || fail "missing image verify/smoke gate"
  [[ -f "${fault_dockerfile}" ]] || fail "missing dependency fault Dockerfile"
  [[ "${startup_timeout}" =~ ^[0-9]+$ && "${startup_timeout}" -ge 1 && "${startup_timeout}" -le 120 ]] \
    || fail "RUNTIME_STARTUP_FAULT_TIMEOUT_SECONDS must be between 1 and 120"

  set +e
  checker_values="$(RUNTIME_CHECKER_INPUT="${checker_json}" \
    "${SERVICE_PYTHON}" -I - "${base_sha}" 2>/dev/null <<'PY'
import json
import os
import re
import sys

payload = json.loads(os.environ.pop("RUNTIME_CHECKER_INPUT"))
base = sys.argv[1]
assert payload["ok"] is True
assert payload["violations"] == []
assert payload["checked_projects"] == ["debugger", "service"]
interpreters = payload["checked_interpreters"]
assert {item["name"] for item in interpreters} == {"debugger", "strategy-service"}
assert len(interpreters) == 2
expected_python = {"debugger": ">=3.12", "strategy-service": "3.13"}
assert all(item["expected_python"] == expected_python[item["name"]] for item in interpreters)
assert all(isinstance(item["path"], str) and item["path"] for item in interpreters)

profile = payload["profile"]
assert profile["schema_version"] == 1
assert profile["hosted_python"] == "3.13"
assert profile["debugger_python"] == ">=3.12"
assert re.fullmatch(r"[A-Za-z0-9_.-]+", profile["name"])
assert re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+(?:[-+][0-9A-Za-z.-]+)?", profile["version"])
digest = payload["digest"]
assert re.fullmatch(r"[0-9a-f]{64}", digest)

baseline = payload["baseline"]
assert baseline["ref"] == base
assert baseline["commit"] == base
state = baseline["state"]
if state == "introduced":
    assert [notice["code"] for notice in payload["notices"]] == ["BASELINE_MANIFEST_ABSENT"]
    assert profile["name"] == "platform-python-3.13"
    assert profile["version"] == "1.0.0"
    assert digest == "8457b3c35618558fc8bfc74d4135b7eb52e00c33a8c9a49d202830f3fd5b62c5"
elif state == "present":
    assert payload["notices"] == []
else:
    raise AssertionError("invalid baseline state")
print(profile["name"])
print(profile["version"])
print(digest)
PY
)"
  metadata_status=$?
  set -e
  [[ "${metadata_status}" -eq 0 ]] || fail "checker JSON failed acceptance"
  profile="$(printf '%s\n' "${checker_values}" | sed -n '1p')"
  version="$(printf '%s\n' "${checker_values}" | sed -n '2p')"
  digest="$(printf '%s\n' "${checker_values}" | sed -n '3p')"
  [[ -n "${profile}" && -n "${version}" && "${#digest}" -eq 64 ]] \
    || fail "checker JSON did not produce exact profile facts"

  if [[ -n "${source_test_runner}" ]]; then
    "${source_test_runner}"
  else
    (
      cd "${service_dir}"
      PYTHONPATH=.:../strategy-library uv run --frozen --extra dev pytest \
        tests/test_strategy_runtime_dockerfile.py \
        tests/test_runtime_image_scripts.py -q
    )
  fi

  "${verify_script}" \
    --image "${normal_image}" --coverage false \
    --profile "${profile}" --version "${version}" --digest "${digest}"
  "${verify_script}" \
    --image "${coverage_image}" --coverage true \
    --profile "${profile}" --version "${version}" --digest "${digest}"
  "${smoke_script}" \
    --image "${normal_image}" --coverage false \
    --profile "${profile}" --version "${version}" --digest "${digest}"
  "${smoke_script}" \
    --image "${coverage_image}" --coverage true \
    --profile "${profile}" --version "${version}" --digest "${digest}"

  inspect_json="$(docker image inspect "${normal_image}" "${coverage_image}")" \
    || fail "cannot inspect paired runtime images"
  set +e
  HUSHINE_PAIRED_IMAGE_INSPECT_JSON="${inspect_json}" \
    "${SERVICE_PYTHON}" -I - "${profile}" "${version}" "${digest}" 2>/dev/null <<'PY'
import json
import os
import re
import sys

profile, version, digest = sys.argv[1:]
images = json.loads(os.environ.pop("HUSHINE_PAIRED_IMAGE_INSPECT_JSON"))
assert isinstance(images, list) and len(images) == 2
label_names = {
    "profile": "org.hushine.runtime.profile",
    "version": "org.hushine.runtime.profile.version",
    "digest": "org.hushine.runtime.contract.sha256",
    "service": "org.hushine.runtime.strategy-service.commit",
    "library": "org.hushine.runtime.strategy-library.commit",
    "golang": "org.hushine.runtime.golang-lib.commit",
    "build": "org.hushine.runtime.image-build-id",
    "dirty": "org.hushine.runtime.source-dirty",
    "source": "org.hushine.runtime.source-state.sha256",
}
env_names = {
    "profile": "HUSHINE_RUNTIME_PROFILE_NAME",
    "version": "HUSHINE_RUNTIME_PROFILE_VERSION",
    "digest": "HUSHINE_RUNTIME_CONTRACT_SHA256",
    "service": "HUSHINE_RUNTIME_STRATEGY_SERVICE_COMMIT",
    "library": "HUSHINE_RUNTIME_STRATEGY_LIBRARY_COMMIT",
    "golang": "HUSHINE_RUNTIME_GOLANG_LIB_COMMIT",
    "build": "HUSHINE_RUNTIME_IMAGE_BUILD_ID",
    "dirty": "HUSHINE_RUNTIME_SOURCE_DIRTY",
    "source": "HUSHINE_RUNTIME_SOURCE_STATE_SHA256",
}
paired = []
for image in images:
    config = image["Config"]
    labels = config["Labels"]
    environment = dict(item.split("=", 1) for item in config["Env"] if "=" in item)
    facts = {}
    for key in label_names:
        facts[key] = labels[label_names[key]]
        assert facts[key] == environment[env_names[key]]
    assert facts["profile"] == profile
    assert facts["version"] == version
    assert facts["digest"] == digest
    assert facts["dirty"] == "false"
    assert re.fullmatch(r"[0-9a-f]{40}", facts["service"])
    assert re.fullmatch(r"[0-9a-f]{40}", facts["library"])
    assert re.fullmatch(r"[0-9a-f]{40}", facts["golang"])
    assert re.fullmatch(r"[0-9a-f]{64}", facts["source"])
    assert facts["build"]
    paired.append(facts)
for key in ("profile", "version", "digest", "service", "library", "golang", "dirty", "source"):
    assert paired[0][key] == paired[1][key]
assert paired[0]["build"] != paired[1]["build"]
PY
  metadata_status=$?
  set -e
  [[ "${metadata_status}" -eq 0 ]] || fail "paired runtime image metadata differs"

  coverage_probe="from hushine_strategy.import_validation import HOSTED_PLATFORM_IMPORT_POLICY, validate_dependency_imports; from hushine_strategy.runtime_dependencies import load_runtime_dependency_profile; import ast, sys; policy=HOSTED_PLATFORM_IMPORT_POLICY; modules=frozenset(module for module, _ in policy.allowed_from_symbols); issues=validate_dependency_imports(ast.parse('import coverage'), profile=load_runtime_dependency_profile(), stdlib_roots=sys.stdlib_module_names, platform_modules=modules); assert [(item.code, item.module) for item in issues] == [('UNSUPPORTED_STRATEGY_DEPENDENCY', 'coverage')]"
  docker run --rm --entrypoint /app/strategy-service/.venv/bin/python \
    "${normal_image}" -I -c "${coverage_probe}"
  docker run --rm --entrypoint /app/strategy-service/.venv/bin/python \
    "${coverage_image}" -I -c "${coverage_probe}"

  fault_distribution="$(docker run --rm \
    --entrypoint /app/strategy-service/.venv/bin/python "${normal_image}" -I -c \
    'from hushine_strategy.runtime_dependencies import load_runtime_dependency_profile as load; print(next(item.distribution for item in load().dependencies if item.public))')"
  [[ "${fault_distribution}" =~ ^[A-Za-z0-9_.-]+$ ]] \
    || fail "loader did not select a safe fault distribution"

  cleanup_fault_images() {
    docker image rm -f "${fault_build_image}" "${fault_startup_image}" >/dev/null 2>&1 || true
  }
  trap cleanup_fault_images EXIT
  set +e
  docker build --no-cache \
    --build-arg "BASE_IMAGE=${normal_image}" \
    --build-arg "FAULT_DISTRIBUTION=${fault_distribution}" \
    --target build-gate \
    -f "${fault_dockerfile}" \
    -t "${fault_build_image}" "${service_dir}"
  fault_status=$?
  set -e
  [[ "${fault_status}" -ne 0 ]] || fail "missing dependency unexpectedly passed build gate"

  docker build --no-cache \
    --build-arg "BASE_IMAGE=${normal_image}" \
    --build-arg "FAULT_DISTRIBUTION=${fault_distribution}" \
    --target startup-gate \
    -f "${fault_dockerfile}" \
    -t "${fault_startup_image}" "${service_dir}"
  RUNTIME_FAULT_IMAGE="${fault_startup_image}" \
  RUNTIME_FAULT_TIMEOUT="${startup_timeout}" \
    "${SERVICE_PYTHON}" -I - <<'PY' \
    || fail "missing dependency did not fail safely before RuntimeChannel readiness"
import os
import subprocess

image = os.environ.pop("RUNTIME_FAULT_IMAGE")
timeout = int(os.environ.pop("RUNTIME_FAULT_TIMEOUT"))
container = f"hushine-dependency-fault-{os.getpid()}"
timed_out = False
output = b""
status = 0
try:
    try:
        result = subprocess.run(
            ["docker", "run", "--name", container, image],
            check=False,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            timeout=timeout,
        )
        status = result.returncode
        output = result.stdout or b""
    except subprocess.TimeoutExpired as error:
        timed_out = True
        output = error.stdout or b""
finally:
    subprocess.run(
        ["docker", "rm", "-f", container],
        check=False,
        stdin=subprocess.DEVNULL,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )

if isinstance(output, str):
    output = output.encode("utf-8", "replace")
bounded = output[:65536]
if timed_out or status == 0:
    raise SystemExit(1)
if b"RUNTIME_DEPENDENCY_PROFILE_INVALID" not in bounded:
    raise SystemExit(1)
if b"runtime-agent started:" in bounded:
    raise SystemExit(1)
PY
  cleanup_fault_images
  trap - EXIT

  echo "Runtime dependency paired-image acceptance passed."
}

case "${1:-}" in
  --self-test)
    [[ "$#" -eq 1 ]] || fail "--self-test accepts no additional arguments"
    makefile_self_test
    scanner_self_test
    acceptance_self_test
    ;;
  "")
    [[ "$#" -eq 0 ]] || fail "unexpected arguments"
    run_acceptance
    ;;
  *)
    fail "usage: $0 [--self-test]"
    ;;
esac
