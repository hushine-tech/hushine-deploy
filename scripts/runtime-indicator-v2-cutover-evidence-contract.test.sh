#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
SCRIPT="${ROOT}/scripts/runtime-indicator-v2-cutover-evidence.test.sh"
SMOKE_SCRIPT="${ROOT}/scripts/runtime-indicator-v2-smoke.sh"
COVERAGE_LIB="${ROOT}/scripts/lib/runtime_coverage.sh"

fail() {
  echo "runtime Indicator V2 cutover evidence contract: $*" >&2
  exit 1
}

file_mode() {
  if stat -f '%Lp' "$1" >/dev/null 2>&1; then
    stat -f '%Lp' "$1"
  else
    stat -c '%a' "$1"
  fi
}

[[ -x "${SCRIPT}" ]] || fail "executable evidence script is missing"
bash -n "${SCRIPT}" || fail "evidence script is not valid Bash"
[[ -x "${SMOKE_SCRIPT}" ]] || fail "executable smoke script is missing"
bash -n "${SMOKE_SCRIPT}" || fail "smoke script is not valid Bash"
if grep -Fq '/Users/xdy/.local/bin/uv' "${SMOKE_SCRIPT}"; then
  fail "smoke script contains a machine-specific uv path"
fi
grep -Fq 'Core V1 removed and V2-only service contracts' "${SMOKE_SCRIPT}" \
  || fail "smoke script does not label the core gate as V2-only"
grep -Fq -- "-run 'IndicatorProtoV1Removed|StrategyIndicator.*V2|Indicator.*V2'" "${SMOKE_SCRIPT}" \
  || fail "smoke script does not select the core V1-removal contract"
grep -Fq 'Authenticated RuntimeChannel V1 removed and V2-only proxy' "${SMOKE_SCRIPT}" \
  || fail "smoke script does not label the control gate as V2-only"
grep -Fq -- "-run 'IndicatorProtoV1Removed|Indicator.*V2|SessionFinalizationPending'" "${SMOKE_SCRIPT}" \
  || fail "smoke script does not select the control V1-removal contract"
grep -Fq 'Handler V1 removed and field-preserving V2-only JSON' "${SMOKE_SCRIPT}" \
  || fail "smoke script does not label the handler gate as V2-only"
grep -Fq -- "-run 'StrategyIndicatorV1Removed|StrategyIndicator.*V2|Session.*FinalizationPending'" "${SMOKE_SCRIPT}" \
  || fail "smoke script does not select the handler V1-removal contract"
if grep -Fq 'V1CoexistsWithV2' "${SMOKE_SCRIPT}" || grep -Fq 'V1/V2 coexistence' "${SMOKE_SCRIPT}"; then
  fail "post-cutover smoke script still selects or labels V1/V2 coexistence"
fi
for consumer in "${SCRIPT}" "${SMOKE_SCRIPT}"; do
  grep -Fq 'source "${DEPLOY_ROOT}/scripts/lib/runtime_coverage.sh"' "${consumer}" \
    || fail "$(basename "${consumer}") does not use the shared runtime tooling"
  grep -Fq 'runtime_coverage_resolve_uv_bin' "${consumer}" \
    || fail "$(basename "${consumer}") does not use the shared uv resolver"
  if grep -Fq 'resolve_uv_bin() {' "${consumer}"; then
    fail "$(basename "${consumer}") duplicates the shared uv resolver"
  fi
done
grep -Fq '${HOME}/.local/bin/uv' "${COVERAGE_LIB}" \
  || fail "shared uv resolver does not support the portable HOME fallback"

test_root="$(mktemp -d)"
test_root="$(cd "${test_root}" && pwd -P)"
trap 'rm -rf -- "${test_root}"' EXIT
chmod 0700 "${test_root}"
source_root="${test_root}/source"
mkdir -p "${source_root}/gateway"

scan_source_root="${test_root}/scan-source"
mkdir -p \
  "${scan_source_root}/core-service/internal/storage/migrations" \
  "${scan_source_root}/core-service/internal/service" \
  "${scan_source_root}/control-panel-service" \
  "${scan_source_root}/strategy-service/gen/runtimeworkerv1" \
  "${scan_source_root}/strategy-service/tests" \
  "${scan_source_root}/gateway/quant-handler" \
  "${scan_source_root}/gateway/quant-frontend"
printf '%s\n' 'type WorkerFrame_IndicatorFrameV2 struct{}' \
  >"${scan_source_root}/strategy-service/gen/runtimeworkerv1/runtime_worker.pb.go"
printf '%s\n' 'const legacyColumn = "values_json"' \
  >"${scan_source_root}/core-service/internal/storage/migrations/indicator_v2_integration_test.go"

scan_output="${test_root}/scan.log"
HUSHINE_SOURCE_ROOT="${scan_source_root}" "${SCRIPT}" scan-no-v1 >"${scan_output}"
grep -Fxq 'runtime Indicator V2 no-V1 source/generated scan: PASS' "${scan_output}" \
  || fail "strict no-V1 scan did not accept V2 generated wrappers and current test coverage"

deleted_core_paths=(
  core-service/internal/storage/migrations/0005_runtime_indicator_v2.sql
  core-service/cmd/ensure-portfolio-db/cutover_guard.go
  core-service/cmd/ensure-portfolio-db/cutover_guard_test.go
  core-service/internal/storage/migrations/testdata/indicator_v1_fixture.sql
)
for deleted_path in "${deleted_core_paths[@]}"; do
  mkdir -p "$(dirname "${scan_source_root}/${deleted_path}")"
  printf '%s\n' 'const legacyColumn = "values_json"' \
    >"${scan_source_root}/${deleted_path}"
  set +e
  deleted_path_output="$(
    HUSHINE_SOURCE_ROOT="${scan_source_root}" "${SCRIPT}" scan-no-v1 2>&1
  )"
  deleted_path_status="$?"
  set -e
  [[ "${deleted_path_status}" -ne 0 ]] \
    || fail "strict no-V1 scan accepted deleted Core path ${deleted_path}"
  grep -Fq "${deleted_path}" <<<"${deleted_path_output}" \
    || fail "deleted Core path failure did not identify ${deleted_path}"
  rm -f -- "${scan_source_root}/${deleted_path}"
done

printf '%s\n' 'type WorkerFrame_IndicatorFrame struct{}' \
  >"${scan_source_root}/strategy-service/gen/runtimeworkerv1/runtime_worker.pb.go"
set +e
exact_v1_output="$(HUSHINE_SOURCE_ROOT="${scan_source_root}" "${SCRIPT}" scan-no-v1 2>&1)"
exact_v1_status="$?"
set -e
[[ "${exact_v1_status}" -ne 0 ]] \
  || fail "strict no-V1 scan accepted the exact generated V1 wrapper"
grep -Fq 'strategy-service/gen/runtimeworkerv1/runtime_worker.pb.go' <<<"${exact_v1_output}" \
  || fail "exact generated V1 wrapper failure did not identify its path"

printf '%s\n' 'type WorkerFrame_IndicatorFrameV2 struct{}' \
  >"${scan_source_root}/strategy-service/gen/runtimeworkerv1/runtime_worker.pb.go"
printf '%s\n' 'frame = worker_pb2.IndicatorFrame(session_id="legacy")' \
  >"${scan_source_root}/strategy-service/tests/test_worker_agent_client.py"
set +e
python_v1_output="$(HUSHINE_SOURCE_ROOT="${scan_source_root}" "${SCRIPT}" scan-no-v1 2>&1)"
python_v1_status="$?"
set -e
[[ "${python_v1_status}" -ne 0 ]] \
  || fail "strict no-V1 scan accepted Python construction of a worker V1 frame"
grep -Fq 'strategy-service/tests/test_worker_agent_client.py' <<<"${python_v1_output}" \
  || fail "Python worker V1 frame failure did not identify its path"
rm -f -- "${scan_source_root}/strategy-service/tests/test_worker_agent_client.py"

printf '%s\n' 'const executableLegacyColumn = "values_json"' \
  >"${scan_source_root}/core-service/internal/service/legacy_indicator.go"
set +e
unexpected_compat_output="$(HUSHINE_SOURCE_ROOT="${scan_source_root}" "${SCRIPT}" scan-no-v1 2>&1)"
unexpected_compat_status="$?"
set -e
[[ "${unexpected_compat_status}" -ne 0 ]] \
  || fail "strict no-V1 scan accepted values_json outside the compatibility allowlist"
grep -Fq 'core-service/internal/service/legacy_indicator.go' <<<"${unexpected_compat_output}" \
  || fail "unexpected compatibility surface failure did not identify its path"
rm -f -- "${scan_source_root}/core-service/internal/service/legacy_indicator.go"

repositories=(
  core-service
  control-panel-service
  strategy-library
  strategy-service
  strategy-debugger-cli
  scraper
  gateway/quant-handler
  gateway/quant-frontend
  hushine-deploy
)

for repository in "${repositories[@]}"; do
  repo_root="${source_root}/${repository}"
  mkdir -p "${repo_root}"
  git -C "${repo_root}" init -q
  git -C "${repo_root}" config user.name "Indicator V2 evidence test"
  git -C "${repo_root}" config user.email "indicator-v2-evidence@example.invalid"
  printf '%s\n' "${repository}" >"${repo_root}/tracked.txt"
  git -C "${repo_root}" add tracked.txt
  git -C "${repo_root}" commit -q -m "test fixture"
done

mkdir -p \
  "${source_root}/strategy-service/strategy_service/gen" \
  "${source_root}/strategy-service/gen/controlpanelv1" \
  "${source_root}/control-panel-service/gen/controlpanelv1"
printf '%s\n' \
  '#!/usr/bin/env bash' \
  'set -euo pipefail' \
  'printf "%s\n" "generated fixture stubs"' \
  >"${source_root}/strategy-service/generate_proto.sh"
chmod 0755 "${source_root}/strategy-service/generate_proto.sh"
printf '%s\n' '# generated Python fixture' \
  >"${source_root}/strategy-service/strategy_service/gen/runtime_worker_pb2.py"
for generated in control_panel_service.pb.go control_panel_service_grpc.pb.go; do
  printf '%s\n' '// generated Go fixture' \
    >"${source_root}/strategy-service/gen/controlpanelv1/${generated}"
  cp \
    "${source_root}/strategy-service/gen/controlpanelv1/${generated}" \
    "${source_root}/control-panel-service/gen/controlpanelv1/${generated}"
done
git -C "${source_root}/strategy-service" add \
  generate_proto.sh strategy_service/gen/runtime_worker_pb2.py gen/controlpanelv1
git -C "${source_root}/strategy-service" commit -q -m "generated fixture"
git -C "${source_root}/control-panel-service" add gen/controlpanelv1
git -C "${source_root}/control-panel-service" commit -q -m "generated fixture"

fake_bin="${test_root}/fake-bin"
mkdir -p "${fake_bin}"
printf '%s\n' \
  '#!/usr/bin/env bash' \
  'set -euo pipefail' \
  'case "$*" in' \
  '  *TestRuntimeDependencyChannelProto*) test_name=TestRuntimeDependencyChannelProto ;;' \
  '  *TestRuntimeDependencyFrameContract*) test_name=TestRuntimeDependencyFrameContract ;;' \
  '  *StrategyIndicatorV1CoexistsWithV2*) test_name=TestStrategyIndicatorV1CoexistsWithV2 ;;' \
  '  *) test_name=TestIndicatorProtoV1CoexistsWithV2 ;;' \
  'esac' \
  'printf "=== RUN   %s\n--- PASS: %s (0.00s)\nPASS\n" "$test_name" "$test_name"' \
  >"${fake_bin}/go"
printf '%s\n' \
  '#!/usr/bin/env bash' \
  'set -euo pipefail' \
  'printf "%s\n" \' \
  '  "tests/test_runtime_dependency_proto.py::test_worker_dependency_fields_and_indicator_evolution_are_exact PASSED [ 25%]" \' \
  '  "tests/test_runtime_worker_proto.py::test_worker_frame_reserves_removed_v1_tag_and_name PASSED [ 50%]" \' \
  '  "tests/test_runtime_worker_proto.py::test_worker_frame_keeps_v1_tag_during_additive_v2_gate PASSED [ 50%]" \' \
  '  "tests/test_grpc_server.py::test_proxy_only_backtest_flushes_custom_indicator_chunks PASSED [100%]" \' \
  '  "2 passed in 0.01s"' \
  >"${fake_bin}/uv"
printf '%s\n' \
  '#!/usr/bin/env bash' \
  'set -euo pipefail' \
  'printf "%s\n" "generated control fixture stubs"' \
  >"${fake_bin}/make"
chmod 0700 "${fake_bin}/go" "${fake_bin}/uv" "${fake_bin}/make"

current_shas="${test_root}/current-shas.json"
HUSHINE_SOURCE_ROOT="${source_root}" \
  "${SCRIPT}" --write-current-shas "${current_shas}" --require-clean

[[ -f "${current_shas}" && ! -L "${current_shas}" ]] \
  || fail "current SHA manifest is missing or unsafe"
if stat -f '%Lp' "${current_shas}" >/dev/null 2>&1; then
  mode="$(stat -f '%Lp' "${current_shas}")"
else
  mode="$(stat -c '%a' "${current_shas}")"
fi
[[ "${mode}" == "600" ]] || fail "current SHA manifest mode is ${mode}, expected 600"

jq -e '
  type == "object"
  and keys == ["schema", "source_shas"]
  and .schema == 1
  and (.source_shas | keys) == [
    "control-panel-service",
    "core-service",
    "gateway/quant-frontend",
    "gateway/quant-handler",
    "hushine-deploy",
    "scraper",
    "strategy-debugger-cli",
    "strategy-library",
    "strategy-service"
  ]
  and all(.source_shas[]; test("^[0-9a-f]{40}$"))
' "${current_shas}" >/dev/null \
  || fail "current SHA manifest schema is invalid"

for repository in "${repositories[@]}"; do
  expected="$(git -C "${source_root}/${repository}" rev-parse HEAD)"
  actual="$(jq -r --arg repository "${repository}" \
    '.source_shas[$repository]' "${current_shas}")"
  [[ "${actual}" == "${expected}" ]] \
    || fail "SHA mismatch for ${repository}"
done

state_dir="${test_root}/precutover"
mkdir -m 0700 "${state_dir}"
runtime_id="rt-aaaaaaaaaaaaaaaaaaaaaaaa"
session_id="bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
owner_token="cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"
generation="generation-dddddddddddddddddddddddddddddddd"
runtime_root="${state_dir}/coverage/runtimes/${runtime_id}"
mkdir -m 0700 -p "${runtime_root}"
chain="${state_dir}/chain.json"
jq -nc \
  --slurpfile current "${current_shas}" \
  --arg runtime_id "${runtime_id}" \
  --arg session_id "${session_id}" \
  --arg owner_token "${owner_token}" \
  --arg generation "${generation}" \
  --arg runtime_root "${runtime_root}" \
  '{
  schema: 1,
  phase: "pre",
  status: "stopped",
  evidence_eligible: true,
  source_shas: $current[0].source_shas,
  source_dirty:($current[0].source_shas | with_entries(.value = false)),
  owner_token:$owner_token,
  generation:$generation,
  runtime_id:$runtime_id,
  session_id:$session_id,
  runtime_root:$runtime_root,
  runtime_image:"hushine/strategy-runtime:executor-coverage-test",
  runtime_image_id:"sha256:eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee",
  runtime_image_provenance:{
    source_dirty:false,
    strategy_service_commit:$current[0].source_shas["strategy-service"],
    strategy_library_commit:$current[0].source_shas["strategy-library"],
    golang_lib_commit:"ffffffffffffffffffffffffffffffffffffffff",
    source_state_sha256:"ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff",
    image_build_id:"fixture-build"
  },
  databases:{
    portfolio:"hushine_indicator_chain_test_portfolio",
    order:"hushine_indicator_chain_test_order",
    control_panel:"hushine_indicator_chain_test_control",
    market_prefix:"hushine_indicator_chain_test_",
    market:"hushine_indicator_chain_test_binance_2025"
  },
  urls:{frontend:"http://127.0.0.1:5173",handler:"http://127.0.0.1:8090"},
  cleanup: {complete: true,supervisor_exit_code:0}
}' >"${chain}"
chmod 0600 "${chain}"

assertions="${state_dir}/assertions.json"
jq -nc \
  --arg owner_token "${owner_token}" \
  --arg generation "${generation}" \
  --arg runtime_id "${runtime_id}" \
  --arg session_id "${session_id}" \
  '
  def chunk($key;$index;$count;$finalized):
    {
      indicator_key:$key,
      chunk_index:$index,
      count:$count,
      revision:$count,
      finalized:$finalized,
      protocol_version:2
    };
  {
    schema:1,
    owner_token:$owner_token,
    generation:$generation,
    runtime_id:$runtime_id,
    session_id:$session_id,
    states:{
      "open-1023":{
        completed:1023,
        database_sha256:"1111111111111111111111111111111111111111111111111111111111111111",
        api_sha256:"1111111111111111111111111111111111111111111111111111111111111111",
        api_database_equal:true,
        chunks:[
          chunk("scalar";0;1023;false),
          chunk("marker";0;1023;false)
        ],
        orders:[]
      },
      "finalized-1024-plus-tail":{
        completed:1025,
        database_sha256:"2222222222222222222222222222222222222222222222222222222222222222",
        api_sha256:"2222222222222222222222222222222222222222222222222222222222222222",
        api_database_equal:true,
        chunks:[
          chunk("scalar";0;1024;true),
          chunk("scalar";1;1;false),
          chunk("marker";0;1024;true),
          chunk("marker";1;1;false)
        ],
        orders:[]
      },
      "two-full-plus-tail":{
        completed:2049,
        database_sha256:"3333333333333333333333333333333333333333333333333333333333333333",
        api_sha256:"3333333333333333333333333333333333333333333333333333333333333333",
        api_database_equal:true,
        chunks:[
          chunk("scalar";0;1024;true),
          chunk("scalar";1;1024;true),
          chunk("scalar";2;1;false),
          chunk("marker";0;1024;true),
          chunk("marker";1;1024;true),
          chunk("marker";2;1;false)
        ],
        orders:[{},{},{}]
      }
    }
  }' >"${assertions}"
chmod 0600 "${assertions}"

jq -nc \
  --arg runtime_id "${runtime_id}" \
  '{
    schema_version:1,
    runtime_id:$runtime_id,
    boot_id:"fixture-boot",
    state:"complete",
    worker_shutdown:"ok",
    forced_workers:0,
    go_snapshot:"ok",
    completed_at:"2026-07-28T00:00:00Z"
  }' >"${runtime_root}/finalization.json"
chmod 0600 "${runtime_root}/finalization.json"

coexistence="${state_dir}/coexistence.json"
PATH="${fake_bin}:${PATH}" HUSHINE_SOURCE_ROOT="${source_root}" \
  "${SCRIPT}" capture-coexistence \
  --state-dir "${state_dir}" \
  --chain "${chain}" \
  --out "${coexistence}"

[[ -f "${coexistence}" && ! -L "${coexistence}" ]] \
  || fail "coexistence manifest is missing or unsafe"
jq -e '
  .schema == 1
  and .phase == "pre"
  and [.commands[].id] == [
    "strategy-service-worker-v1-v2",
    "core-indicator-v1-v2",
    "control-indicator-v1-v2",
    "handler-indicator-v1-v2"
  ]
  and (.commands | length) == 4
  and all(.commands[];
    .exit_code == 0
    and (.repository_sha | test("^[0-9a-f]{40}$"))
    and (.log_sha256 | test("^[0-9a-f]{64}$"))
    and (.log_path | startswith("coexistence/"))
  )
  and (.commands[0].argv == [
    "uv", "run", "--frozen", "--extra", "dev", "pytest",
    "tests/test_runtime_worker_proto.py::test_worker_frame_keeps_v1_tag_during_additive_v2_gate",
    "tests/test_grpc_server.py::test_proxy_only_backtest_flushes_custom_indicator_chunks",
    "-vv", "--color=no"
  ])
  and (.commands[0].environment == {
    PYTEST_ADDOPTS: "",
    PYTHONPATH: ".:../strategy-library"
  })
  and (.commands[1].argv == [
    "go", "test", "./internal/service", "-run",
    "IndicatorProtoV1CoexistsWithV2", "-count=1", "-v"
  ])
  and (.commands[2].argv == [
    "go", "test", "./internal/runtimechannel", "-run",
    "IndicatorProtoV1CoexistsWithV2", "-count=1", "-v"
  ])
  and (.commands[3].argv == [
    "go", "test", "./internal/app", "-run",
    "StrategyIndicatorV1CoexistsWithV2", "-count=1", "-v"
  ])
' "${coexistence}" >/dev/null \
  || fail "coexistence manifest contract is invalid"

for id in \
  strategy-service-worker-v1-v2 \
  core-indicator-v1-v2 \
  control-indicator-v1-v2 \
  handler-indicator-v1-v2; do
  log="${state_dir}/coexistence/${id}.log"
  [[ -s "${log}" && ! -L "${log}" ]] \
    || fail "coexistence log is missing or empty: ${id}"
  expected_hash="$(jq -r --arg id "${id}" \
    '.commands[] | select(.id == $id) | .log_sha256' "${coexistence}")"
  actual_hash="$(shasum -a 256 "${log}" | awk '{print $1}')"
  [[ "${actual_hash}" == "${expected_hash}" ]] \
    || fail "coexistence log hash mismatch: ${id}"
done

bad_state="${test_root}/bad-coexistence"
mkdir -m 0700 "${bad_state}"
cp "${chain}" "${bad_state}/chain.json"
chmod 0600 "${bad_state}/chain.json"
bad_bin="${test_root}/bad-bin"
mkdir -m 0700 "${bad_bin}"
cp "${fake_bin}/uv" "${bad_bin}/uv"
printf '%s\n' \
  '#!/usr/bin/env bash' \
  'set -euo pipefail' \
  'printf "testing: warning: no tests to run\nPASS\n"' \
  >"${bad_bin}/go"
chmod 0700 "${bad_bin}/go" "${bad_bin}/uv"
set +e
no_test_output="$(
  PATH="${bad_bin}:${PATH}" HUSHINE_SOURCE_ROOT="${source_root}" \
    "${SCRIPT}" capture-coexistence \
    --state-dir "${bad_state}" \
    --chain "${bad_state}/chain.json" \
    --out "${bad_state}/coexistence.json" 2>&1
)"
no_test_status="$?"
set -e
[[ "${no_test_status}" -ne 0 ]] \
  || fail "coexistence capture accepted an exit-zero no-tests-run result"
grep -Fq 'does not prove the fixed test ran' <<<"${no_test_output}" \
  || fail "no-tests-run coexistence result failed at the wrong boundary"
[[ ! -e "${bad_state}/coexistence.json" ]] \
  || fail "no-tests-run coexistence result produced a manifest"

bad_pytest_state="${test_root}/bad-pytest-coexistence"
mkdir -m 0700 "${bad_pytest_state}"
cp "${chain}" "${bad_pytest_state}/chain.json"
chmod 0600 "${bad_pytest_state}/chain.json"
bad_pytest_bin="${test_root}/bad-pytest-bin"
mkdir -m 0700 "${bad_pytest_bin}"
cp "${fake_bin}/go" "${bad_pytest_bin}/go"
printf '%s\n' \
  '#!/usr/bin/env bash' \
  'set -euo pipefail' \
  'printf "tests/test_unrelated.py::test_unrelated PASSED\n2 passed in 0.01s\n"' \
  >"${bad_pytest_bin}/uv"
chmod 0700 "${bad_pytest_bin}/go" "${bad_pytest_bin}/uv"
set +e
wrong_pytest_output="$(
  PATH="${bad_pytest_bin}:${PATH}" HUSHINE_SOURCE_ROOT="${source_root}" \
    "${SCRIPT}" capture-coexistence \
    --state-dir "${bad_pytest_state}" \
    --chain "${bad_pytest_state}/chain.json" \
    --out "${bad_pytest_state}/coexistence.json" 2>&1
)"
wrong_pytest_status="$?"
set -e
[[ "${wrong_pytest_status}" -ne 0 ]] \
  || fail "coexistence capture accepted unrelated passing pytest tests"
grep -Fq 'does not prove the fixed tests ran' <<<"${wrong_pytest_output}" \
  || fail "unrelated pytest result failed at the wrong boundary"
[[ ! -e "${bad_pytest_state}/coexistence.json" ]] \
  || fail "unrelated pytest result produced a manifest"

fallback_state="${test_root}/home-fallback-coexistence"
mkdir -m 0700 "${fallback_state}"
cp "${chain}" "${fallback_state}/chain.json"
chmod 0600 "${fallback_state}/chain.json"
fallback_bin="${test_root}/fallback-bin"
fallback_home="${test_root}/fallback-home"
mkdir -m 0700 "${fallback_bin}" "${fallback_home}"
mkdir -m 0700 -p "${fallback_home}/.local/bin"
cp "${fake_bin}/go" "${fallback_bin}/go"
cp "${fake_bin}/uv" "${fallback_home}/.local/bin/uv"
chmod 0700 "${fallback_bin}/go" "${fallback_home}/.local/bin/uv"
fallback_path=""
IFS=: read -r -a fallback_path_entries <<<"${PATH}"
for path_entry in "${fallback_path_entries[@]}"; do
  [[ -n "${path_entry}" ]] || continue
  [[ ! -x "${path_entry}/uv" && ! -x "${path_entry}/uv.exe" ]] || continue
  fallback_path="${fallback_path:+${fallback_path}:}${path_entry}"
done
HOME="${fallback_home}" PATH="${fallback_bin}:${fallback_path}" \
  HUSHINE_SOURCE_ROOT="${source_root}" \
  "${SCRIPT}" capture-coexistence \
  --state-dir "${fallback_state}" \
  --chain "${fallback_state}/chain.json" \
  --out "${fallback_state}/coexistence.json"
[[ -f "${fallback_state}/coexistence.json" ]] \
  || fail "coexistence capture did not resolve uv from HOME/.local/bin"

mkdir -m 0700 "${state_dir}/screenshots"
screenshot="${state_dir}/screenshots/indicator-v2.png"
printf '%s\n' 'non-sensitive screenshot fixture' >"${screenshot}"
chmod 0600 "${screenshot}"
screenshot_hash="$(shasum -a 256 "${screenshot}" | awk '{print $1}')"
browser="${state_dir}/browser.json"
jq -nc \
  --slurpfile current "${current_shas}" \
  --arg runtime_id "${runtime_id}" \
  --arg session_id "${session_id}" \
  --arg screenshot_hash "${screenshot_hash}" \
  '{
    schema:1,
    phase:"pre",
    source_shas:$current[0].source_shas,
    runtime_id:$runtime_id,
    session_id:$session_id,
    browser:{tab_id:"fixture-tab",frontend_url:"http://127.0.0.1:5173"},
    actions:[
      {id:"open-1023",passed:true,observed_at:"2026-07-28T00:00:00Z"},
      {id:"marker-open-time-order-close-time",passed:true,observed_at:"2026-07-28T00:00:01Z"},
      {id:"finalized-1024-plus-tail",passed:true,observed_at:"2026-07-28T00:00:02Z"},
      {id:"two-full-plus-tail",passed:true,observed_at:"2026-07-28T00:00:03Z"},
      {id:"double-refresh-immutable",passed:true,observed_at:"2026-07-28T00:00:04Z"},
      {id:"v2-network-contract",passed:true,observed_at:"2026-07-28T00:00:05Z"},
      {id:"console-network-clean",passed:true,observed_at:"2026-07-28T00:00:06Z"}
    ],
    assertions:{
      chunk_1023:{count:1023,finalized:false},
      chunk_1025:[{count:1024,finalized:true},{count:1,finalized:false}],
      chunk_2049:[1024,1024,1],
      repeat_1023:{row_delta:0,revision_delta:0,updated_at_changed:false},
      marker_1438:{sequence:1438,time_ms_equals_open_time:true},
      close_time_preserved_for_order:true,
      protocol_version:2,
      api_database_hash_equal:true
    },
    console:{unexpected_errors:0},
    network:{unexpected_same_origin_errors:0},
    screenshots:[{
      path:"screenshots/indicator-v2.png",
      sha256:$screenshot_hash
    }],
    created_at:"2026-07-28T00:00:07Z"
  }' >"${browser}"
chmod 0600 "${browser}"

seal="${state_dir}/seal.json"
PATH="${fake_bin}:${PATH}" HUSHINE_SOURCE_ROOT="${source_root}" \
  "${SCRIPT}" --phase pre \
  --chain "${chain}" \
  --browser "${browser}" \
  --coexistence "${coexistence}" \
  --seal "${seal}" \
  --check-current-shas

[[ -f "${seal}" && ! -L "${seal}" ]] \
  || fail "pre-cutover seal is missing or unsafe"
[[ "$(file_mode "${seal}")" == "600" ]] \
  || fail "pre-cutover seal mode is not 600"
jq -e '
  .schema == 1
  and .phase == "pre"
  and (.payload_sha256 | test("^[0-9a-f]{64}$"))
  and (.payload.chain_sha256 | test("^[0-9a-f]{64}$"))
  and (.payload.assertions_sha256 | test("^[0-9a-f]{64}$"))
  and (.payload.runtime_finalization_sha256 | test("^[0-9a-f]{64}$"))
  and (.payload.browser_sha256 | test("^[0-9a-f]{64}$"))
  and (.payload.coexistence_manifest_sha256 | test("^[0-9a-f]{64}$"))
  and [.payload.coexistence_commands[].id] == [
    "strategy-service-worker-v1-v2",
    "core-indicator-v1-v2",
    "control-indicator-v1-v2",
    "handler-indicator-v1-v2"
  ]
  and .payload.post_contract_manifest_sha256 == null
  and .payload.post_contract_commands == []
  and (.payload.screenshots | length) == 1
' "${seal}" >/dev/null \
  || fail "pre-cutover seal payload is invalid"

PATH="${fake_bin}:${PATH}" HUSHINE_SOURCE_ROOT="${source_root}" \
  "${SCRIPT}" --phase pre \
  --seal "${seal}" \
  --check-current-shas \
  --require-clean

post_state="${test_root}/postcutover"
post_runtime_root="${post_state}/coverage/runtimes/${runtime_id}"
mkdir -m 0700 -p "${post_runtime_root}" "${post_state}/screenshots"
chmod 0700 \
  "${post_state}" \
  "${post_state}/coverage" \
  "${post_state}/coverage/runtimes" \
  "${post_runtime_root}" \
  "${post_state}/screenshots"
jq --arg runtime_root "${post_runtime_root}" \
  '.phase = "post" | .runtime_root = $runtime_root' \
  "${chain}" >"${post_state}/chain.json"
chmod 0600 "${post_state}/chain.json"
cp "${assertions}" "${post_state}/assertions.json"
cp "${runtime_root}/finalization.json" "${post_runtime_root}/finalization.json"
cp "${screenshot}" "${post_state}/screenshots/indicator-v2.png"
chmod 0600 \
  "${post_state}/assertions.json" \
  "${post_runtime_root}/finalization.json" \
  "${post_state}/screenshots/indicator-v2.png"
jq '.phase = "post"' "${browser}" >"${post_state}/browser.json"
chmod 0600 "${post_state}/browser.json"
cp "${current_shas}" "${post_state}/final-shas.json"
chmod 0600 "${post_state}/final-shas.json"
post_contracts="${post_state}/post-contracts.json"
PATH="${fake_bin}:${PATH}" HUSHINE_SOURCE_ROOT="${source_root}" \
  "${SCRIPT}" capture-post-contracts \
  --state-dir "${post_state}" \
  --expected-shas "${post_state}/final-shas.json" \
  --out "${post_contracts}"
[[ -f "${post_contracts}" && ! -L "${post_contracts}" ]] \
  || fail "post-contract manifest is missing or unsafe"
[[ "$(file_mode "${post_contracts}")" == "600" ]] \
  || fail "post-contract manifest mode is not 600"
jq -e '
  .schema == 1
  and .phase == "post"
  and (.expected_shas_manifest_sha256 | test("^[0-9a-f]{64}$"))
  and [.commands[].id] == [
    "indicator-v1-removed-source-generated",
    "runtime-dependency-combined-descriptor-checksum"
  ]
  and (.commands | length) == 2
  and all(.commands[];
    .exit_code == 0
    and (.log_sha256 | test("^[0-9a-f]{64}$"))
    and (.started_at | type == "string" and length > 0)
    and (.finished_at | type == "string" and length > 0)
  )
  and .commands[0].cwd == "hushine-deploy"
  and .commands[0].argv == [
    "bash", "scripts/runtime-indicator-v2-cutover-evidence.test.sh", "scan-no-v1"
  ]
  and .commands[0].log_path ==
    "post-contracts/indicator-v1-removed-source-generated.log"
  and .commands[1].cwd == "hushine-deploy"
  and .commands[1].argv == [
    "bash", "scripts/runtime-indicator-v2-cutover-evidence.test.sh",
    "check-dependency-combined"
  ]
  and .commands[1].log_path ==
    "post-contracts/runtime-dependency-combined-descriptor-checksum.log"
' "${post_contracts}" >/dev/null \
  || fail "post-contract manifest contract is invalid"
for id in \
  indicator-v1-removed-source-generated \
  runtime-dependency-combined-descriptor-checksum; do
  log="${post_state}/post-contracts/${id}.log"
  [[ -s "${log}" && ! -L "${log}" ]] \
    || fail "post-contract log is missing or empty: ${id}"
  expected_hash="$(jq -r --arg id "${id}" \
    '.commands[] | select(.id == $id) | .log_sha256' "${post_contracts}")"
  actual_hash="$(shasum -a 256 "${log}" | awk '{print $1}')"
  [[ "${actual_hash}" == "${expected_hash}" ]] \
    || fail "post-contract log hash mismatch: ${id}"
done
grep -Fxq 'runtime Indicator V2 no-V1 source/generated scan: PASS' \
  "${post_state}/post-contracts/indicator-v1-removed-source-generated.log" \
  || fail "post-contract scan log does not prove strict V1 absence"
grep -Fxq 'runtime dependency combined descriptor/checksum: PASS' \
  "${post_state}/post-contracts/runtime-dependency-combined-descriptor-checksum.log" \
  || fail "post-contract dependency log does not prove the combined gate"
post_seal="${post_state}/seal.json"
PATH="${fake_bin}:${PATH}" HUSHINE_SOURCE_ROOT="${source_root}" \
  "${SCRIPT}" --phase post \
  --expected-shas "${post_state}/final-shas.json" \
  --chain "${post_state}/chain.json" \
  --browser "${post_state}/browser.json" \
  --seal "${post_seal}" \
  --check-current-shas
jq -e '
  .schema == 1
  and .phase == "post"
  and .payload.coexistence_manifest_sha256 == null
  and .payload.coexistence_commands == []
  and (.payload.expected_shas_manifest_sha256 | test("^[0-9a-f]{64}$"))
  and (.payload.post_contract_manifest_sha256 | test("^[0-9a-f]{64}$"))
  and [.payload.post_contract_commands[].id] == [
    "indicator-v1-removed-source-generated",
    "runtime-dependency-combined-descriptor-checksum"
  ]
  and all(.payload.post_contract_commands[];
    .log_sha256 | test("^[0-9a-f]{64}$")
  )
' "${post_seal}" >/dev/null \
  || fail "post-cutover seal payload is invalid"
PATH="${fake_bin}:${PATH}" HUSHINE_SOURCE_ROOT="${source_root}" \
  "${SCRIPT}" --phase post \
  --expected-shas "${post_state}/final-shas.json" \
  --seal "${post_seal}" \
  --check-current-shas \
  --require-clean

printf '%s\n' 'tampered post-contract evidence' \
  >>"${post_state}/post-contracts/runtime-dependency-combined-descriptor-checksum.log"
set +e
post_contract_tamper_output="$(
  PATH="${fake_bin}:${PATH}" HUSHINE_SOURCE_ROOT="${source_root}" \
    "${SCRIPT}" --phase post \
    --expected-shas "${post_state}/final-shas.json" \
    --seal "${post_seal}" \
    --check-current-shas \
    --require-clean 2>&1
)"
post_contract_tamper_status="$?"
set -e
[[ "${post_contract_tamper_status}" -ne 0 ]] \
  || fail "post seal revalidation accepted post-contract log hash drift"
grep -Fq 'post-contract log hash mismatch' <<<"${post_contract_tamper_output}" \
  || fail "post-contract log drift failed at the wrong boundary"

printf '%s\n' 'tampered screenshot' >>"${screenshot}"
set +e
tamper_output="$(
  PATH="${fake_bin}:${PATH}" HUSHINE_SOURCE_ROOT="${source_root}" \
    "${SCRIPT}" --phase pre \
    --seal "${seal}" \
    --check-current-shas \
    --require-clean 2>&1
)"
tamper_status="$?"
set -e
[[ "${tamper_status}" -ne 0 ]] \
  || fail "seal revalidation accepted screenshot hash drift"
grep -Fq 'screenshot hash mismatch' <<<"${tamper_output}" \
  || fail "screenshot drift failed at the wrong boundary"

printf 'dirty\n' >>"${source_root}/core-service/tracked.txt"
set +e
dirty_output="$(
  HUSHINE_SOURCE_ROOT="${source_root}" \
    "${SCRIPT}" --write-current-shas "${test_root}/dirty-shas.json" \
    --require-clean 2>&1
)"
dirty_status="$?"
set -e
[[ "${dirty_status}" -ne 0 ]] \
  || fail "--require-clean accepted a dirty repository"
grep -Fq 'repository is not clean: core-service' <<<"${dirty_output}" \
  || fail "dirty repository failure did not identify core-service"
[[ ! -e "${test_root}/dirty-shas.json" ]] \
  || fail "dirty source produced a SHA manifest"

echo "runtime Indicator V2 cutover evidence contract: PASS"
