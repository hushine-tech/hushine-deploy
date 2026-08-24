#!/usr/bin/env bash
set -euo pipefail

DEPLOY_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
source "${DEPLOY_ROOT}/scripts/lib/runtime_coverage.sh"
SOURCE_ROOT="${HUSHINE_SOURCE_ROOT:-$(cd "${DEPLOY_ROOT}/.." && pwd -P)}"
umask 077

REPOSITORIES=(
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

die() {
  echo "runtime Indicator V2 cutover evidence: $*" >&2
  exit 1
}

require_command() {
  command -v "$1" >/dev/null 2>&1 \
    || die "required command not found: $1"
}

file_mode() {
  if stat -f '%Lp' "$1" >/dev/null 2>&1; then
    stat -f '%Lp' "$1"
  else
    stat -c '%a' "$1"
  fi
}

sha256_file() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
  else
    sha256sum "$1" | awk '{print $1}'
  fi
}

validate_mode_0600_file() {
  local path="$1" label="$2"
  [[ "${path}" == /* ]] || die "${label} path must be absolute"
  [[ -f "${path}" && ! -L "${path}" ]] \
    || die "${label} must be a regular non-symlink file"
  [[ "$(file_mode "${path}")" == "600" ]] \
    || die "${label} must have mode 0600"
}

canonical_directory() {
  local requested="$1" canonical
  [[ "${requested}" == /* ]] || die "state directory must be absolute"
  [[ -d "${requested}" && ! -L "${requested}" ]] \
    || die "state directory must be an existing non-symlink directory"
  canonical="$(cd "${requested}" && pwd -P)"
  [[ "${canonical}" == "${requested}" ]] \
    || die "state directory must be canonical"
  [[ "$(file_mode "${canonical}")" == "700" ]] \
    || die "state directory must have mode 0700"
  printf '%s\n' "${canonical}"
}

canonical_parent() {
  local destination="$1" parent canonical
  [[ "${destination}" == /* ]] || die "output path must be absolute"
  [[ ! -L "${destination}" ]] || die "output path must not be a symlink"
  parent="$(dirname "${destination}")"
  [[ -d "${parent}" && ! -L "${parent}" ]] \
    || die "output parent must be an existing non-symlink directory"
  canonical="$(cd "${parent}" && pwd -P)"
  [[ "${canonical}/$(basename "${destination}")" == "${destination}" ]] \
    || die "output path must be canonical"
}

atomic_json() {
  local destination="$1"
  shift
  local temporary="${destination}.tmp.$$"
  canonical_parent "${destination}"
  jq "$@" >"${temporary}"
  chmod 0600 "${temporary}"
  mv -f -- "${temporary}" "${destination}"
}

source_sha_json() {
  local require_clean="$1" value='{}' repository sha
  for repository in "${REPOSITORIES[@]}"; do
    [[ -d "${SOURCE_ROOT}/${repository}" ]] \
      || die "repository is missing: ${repository}"
    if [[ "${require_clean}" == "true" ]] \
      && [[ -n "$(git -C "${SOURCE_ROOT}/${repository}" status --porcelain --untracked-files=normal)" ]]; then
      die "repository is not clean: ${repository}"
    fi
    sha="$(git -C "${SOURCE_ROOT}/${repository}" rev-parse HEAD)"
    [[ "${sha}" =~ ^[0-9a-f]{40}$ ]] \
      || die "repository HEAD is invalid: ${repository}"
    value="$(jq -c --arg repository "${repository}" --arg sha "${sha}" \
      '. + {($repository): $sha}' <<<"${value}")"
  done
  printf '%s\n' "${value}"
}

write_current_shas() {
  local destination="$1" require_clean="$2" source_shas
  source_shas="$(source_sha_json "${require_clean}")"
  atomic_json "${destination}" -nc \
    --argjson source_shas "${source_shas}" \
    '{schema:1,source_shas:$source_shas}'
  echo "runtime Indicator V2 cutover evidence: current SHA manifest written: ${destination}"
}

validate_source_sha_map() {
  jq -e '
    type == "object"
    and keys == [
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
    and all(.[]; type == "string" and test("^[0-9a-f]{40}$"))
  ' >/dev/null
}

redact_log() {
  sed -E \
    -e 's/(Bearer[[:space:]]+)[^[:space:]]+/\1<redacted>/g' \
    -e 's/[0-9a-f]{64}/<redacted-64-hex>/g'
}

run_no_v1_scan() {
  require_command rg
  local pattern roots raw status unexpected="" line path
  pattern='(SaveStrategyIndicators(Request|Response|\()|ListStrategyIndicators(Request|Response|\()|ListStrategyIndicatorChunks(Request|Response|\()|values_json|PORTFOLIO_SAVE_STRATEGY_INDICATORS|IndicatorChunkBuffer|WorkerFrame_IndicatorFrame\b|worker_pb2\.Indicator(Frame|Value)\b|runtimeworkerv1\.Indicator(Frame|Value)\b|\bindicator_frame\b\s*=|GetIndicatorFrame\(|IndicatorFrame indicator_frame = 15)'
  roots=(
    core-service
    control-panel-service
    strategy-service
    gateway/quant-handler
    gateway/quant-frontend
  )
  for path in "${roots[@]}"; do
    [[ -d "${SOURCE_ROOT}/${path}" ]] || die "source root is missing: ${path}"
  done

  set +e
  raw="$(
    cd "${SOURCE_ROOT}"
    rg -n -P -g '!**/docs/**' "${pattern}" "${roots[@]}"
  )"
  status="$?"
  set -e
  [[ "${status}" -eq 0 || "${status}" -eq 1 ]] \
    || die "strict no-V1 scan failed to execute"

  while IFS= read -r line; do
    [[ -n "${line}" ]] || continue
    path="${line%%:*}"
    case "${path}" in
      core-service/internal/storage/migrations/indicator_v2_integration_test.go|\
      core-service/internal/service/grpc_strategy_indicator_proto_test.go|\
      strategy-service/tests/test_strategy_indicators.py|\
      strategy-service/tests/test_platform_proxy.py|\
      gateway/quant-handler/internal/app/session_indicators_test.go|\
      gateway/quant-frontend/scripts/session-custom-indicators.test.mjs)
        ;;
      *)
        unexpected+="${line}"$'\n'
        ;;
    esac
  done <<<"${raw}"

  if [[ -n "${unexpected}" ]]; then
    printf '%s' "${unexpected}" >&2
    die "unexpected indicator V1 source/generated surface remains"
  fi
  echo "runtime Indicator V2 no-V1 source/generated scan: PASS"
}

run_dependency_combined_gate() (
  require_command diff
  require_command go
  require_command make
  local strategy_root="${SOURCE_ROOT}/strategy-service"
  local control_root="${SOURCE_ROOT}/control-panel-service"
  local state uv_bin strategy_first strategy_second control_first control_second
  [[ -x "${strategy_root}/generate_proto.sh" ]] \
    || die "strategy-service proto generator is missing"
  [[ -d "${control_root}/gen/controlpanelv1" ]] \
    || die "control-panel generated protobuf directory is missing"
  uv_bin="$(runtime_coverage_resolve_uv_bin)" \
    || die "required command not found: uv"
  state="$(mktemp -d "${TMPDIR:-/tmp}/hushine-indicator-post-contract.XXXXXX")"
  trap 'rm -rf -- "${state}"' EXIT

  (
    cd "${strategy_root}"
    PYTHON="${strategy_root}/.venv/bin/python" ./generate_proto.sh
    find strategy_service/gen gen -type f \( -name '*.py' -o -name '*.go' \) -print \
      | LC_ALL=C sort \
      | while IFS= read -r file; do sha256_file "${file}" | awk -v file="${file}" '{print $1 "  " file}'; done \
      >"${state}/strategy.first"
    PYTHON="${strategy_root}/.venv/bin/python" ./generate_proto.sh
    find strategy_service/gen gen -type f \( -name '*.py' -o -name '*.go' \) -print \
      | LC_ALL=C sort \
      | while IFS= read -r file; do sha256_file "${file}" | awk -v file="${file}" '{print $1 "  " file}'; done \
      >"${state}/strategy.second"
  )
  diff -u "${state}/strategy.first" "${state}/strategy.second"
  strategy_first="$(sha256_file "${state}/strategy.first")"
  strategy_second="$(sha256_file "${state}/strategy.second")"
  printf '%s\n' "strategy-service generated checksum first: ${strategy_first}"
  printf '%s\n' "strategy-service generated checksum second: ${strategy_second}"
  printf '%s\n' 'strategy-service generated file checksums:'
  cat "${state}/strategy.second"

  (
    cd "${control_root}"
    make proto
    find gen/controlpanelv1 -type f -name '*.go' -print \
      | LC_ALL=C sort \
      | while IFS= read -r file; do sha256_file "${file}" | awk -v file="${file}" '{print $1 "  " file}'; done \
      >"${state}/control.first"
    make proto
    find gen/controlpanelv1 -type f -name '*.go' -print \
      | LC_ALL=C sort \
      | while IFS= read -r file; do sha256_file "${file}" | awk -v file="${file}" '{print $1 "  " file}'; done \
      >"${state}/control.second"
  )
  diff -u "${state}/control.first" "${state}/control.second"
  control_first="$(sha256_file "${state}/control.first")"
  control_second="$(sha256_file "${state}/control.second")"
  printf '%s\n' "control-panel-service generated checksum first: ${control_first}"
  printf '%s\n' "control-panel-service generated checksum second: ${control_second}"
  printf '%s\n' 'control-panel-service generated file checksums:'
  cat "${state}/control.second"

  cmp \
    "${strategy_root}/gen/controlpanelv1/control_panel_service.pb.go" \
    "${control_root}/gen/controlpanelv1/control_panel_service.pb.go"
  cmp \
    "${strategy_root}/gen/controlpanelv1/control_panel_service_grpc.pb.go" \
    "${control_root}/gen/controlpanelv1/control_panel_service_grpc.pb.go"
  echo "control-panel generated copies byte-identical: PASS"

  (
    cd "${strategy_root}"
    PYTHONPATH=.:../strategy-library "${uv_bin}" run --frozen --extra dev \
      pytest tests/test_runtime_dependency_proto.py tests/test_runtime_worker_proto.py \
      -vv --color=no
    go test ./internal/runtimeagent \
      -run '^TestRuntimeDependencyChannelProto$' -count=1 -v
  )
  (
    cd "${control_root}"
    go test ./internal/runtimechannel \
      -run '^TestRuntimeDependencyFrameContract$' -count=1 -v
  )
  echo "runtime dependency combined descriptor/checksum: PASS"
)

validate_post_contract_log_proof() {
  local id="$1" log="$2" first second
  if [[ "${id}" == "indicator-v1-removed-source-generated" ]]; then
    grep -Fxq 'runtime Indicator V2 no-V1 source/generated scan: PASS' "${log}" \
      || die "post-contract log does not prove strict V1 absence: ${id}"
    return
  fi
  [[ "${id}" == "runtime-dependency-combined-descriptor-checksum" ]] \
    || die "unknown post-contract command ID: ${id}"
  grep -Fq \
    'tests/test_runtime_dependency_proto.py::test_worker_dependency_fields_and_indicator_evolution_are_exact PASSED' \
    "${log}" \
    && grep -Fq \
      'tests/test_runtime_worker_proto.py::test_worker_frame_reserves_removed_v1_tag_and_name PASSED' \
      "${log}" \
    && grep -Fq '=== RUN   TestRuntimeDependencyChannelProto' "${log}" \
    && grep -Fq -- '--- PASS: TestRuntimeDependencyChannelProto' "${log}" \
    && grep -Fq '=== RUN   TestRuntimeDependencyFrameContract' "${log}" \
    && grep -Fq -- '--- PASS: TestRuntimeDependencyFrameContract' "${log}" \
    && grep -Fxq 'control-panel generated copies byte-identical: PASS' "${log}" \
    && grep -Fxq 'runtime dependency combined descriptor/checksum: PASS' "${log}" \
    || die "post-contract log does not prove the combined dependency gate: ${id}"
  first="$(sed -n 's/^strategy-service generated checksum first: //p' "${log}")"
  second="$(sed -n 's/^strategy-service generated checksum second: //p' "${log}")"
  [[ "${first}" =~ ^[0-9a-f]{64}$ && "${first}" == "${second}" ]] \
    || die "strategy-service generated checksum evidence is invalid"
  first="$(sed -n 's/^control-panel-service generated checksum first: //p' "${log}")"
  second="$(sed -n 's/^control-panel-service generated checksum second: //p' "${log}")"
  [[ "${first}" =~ ^[0-9a-f]{64}$ && "${first}" == "${second}" ]] \
    || die "control-panel generated checksum evidence is invalid"
}

post_contract_command_json() {
  local id="$1" state_dir="$2"
  local log_dir="${state_dir}/post-contracts"
  local log="${log_dir}/${id}.log"
  local raw="${log}.raw.$$"
  local started_at finished_at status log_sha argv
  started_at="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  set +e
  case "${id}" in
    indicator-v1-removed-source-generated)
      (
        cd "${DEPLOY_ROOT}"
        HUSHINE_SOURCE_ROOT="${SOURCE_ROOT}" \
          bash scripts/runtime-indicator-v2-cutover-evidence.test.sh scan-no-v1
      ) >"${raw}" 2>&1
      status="$?"
      argv='["bash","scripts/runtime-indicator-v2-cutover-evidence.test.sh","scan-no-v1"]'
      ;;
    runtime-dependency-combined-descriptor-checksum)
      (
        cd "${DEPLOY_ROOT}"
        HUSHINE_SOURCE_ROOT="${SOURCE_ROOT}" \
          bash scripts/runtime-indicator-v2-cutover-evidence.test.sh check-dependency-combined
      ) >"${raw}" 2>&1
      status="$?"
      argv='["bash","scripts/runtime-indicator-v2-cutover-evidence.test.sh","check-dependency-combined"]'
      ;;
    *)
      rm -f -- "${raw}"
      set -e
      die "unknown post-contract command ID: ${id}"
      ;;
  esac
  set -e
  finished_at="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  mv -- "${raw}" "${log}"
  chmod 0600 "${log}"
  [[ "${status}" -eq 0 ]] \
    || die "post-contract command failed: ${id}; see ${log}"
  [[ -s "${log}" ]] || die "post-contract command produced an empty log: ${id}"
  validate_post_contract_log_proof "${id}" "${log}"
  log_sha="$(sha256_file "${log}")"
  jq -nc \
    --arg id "${id}" \
    --arg cwd "hushine-deploy" \
    --argjson argv "${argv}" \
    --argjson exit_code "${status}" \
    --arg started_at "${started_at}" \
    --arg finished_at "${finished_at}" \
    --arg log_path "post-contracts/${id}.log" \
    --arg log_sha256 "${log_sha}" \
    '{
      id:$id,
      cwd:$cwd,
      argv:$argv,
      exit_code:$exit_code,
      started_at:$started_at,
      finished_at:$finished_at,
      log_path:$log_path,
      log_sha256:$log_sha256
    }'
}

capture_post_contracts() {
  local state_dir="$1" expected_shas="$2" out="$3"
  local expected_sources current_sources expected_hash commands='[]' id record
  state_dir="$(canonical_directory "${state_dir}")"
  [[ "${expected_shas}" == "${state_dir}/final-shas.json" ]] \
    || die "expected SHA manifest must be <state-dir>/final-shas.json"
  [[ "${out}" == "${state_dir}/post-contracts.json" ]] \
    || die "post-contract output must be <state-dir>/post-contracts.json"
  [[ ! -e "${out}" && ! -e "${state_dir}/post-contracts" ]] \
    || die "post-contract evidence already exists"
  expected_sources="$(validate_expected_shas_manifest "${expected_shas}")"
  current_sources="$(source_sha_json true)"
  json_objects_equal "${expected_sources}" "${current_sources}" \
    || die "current clean repository SHAs do not match expected post-cutover SHAs"
  expected_hash="$(sha256_file "${expected_shas}")"
  mkdir -m 0700 "${state_dir}/post-contracts"

  for id in \
    indicator-v1-removed-source-generated \
    runtime-dependency-combined-descriptor-checksum; do
    record="$(post_contract_command_json "${id}" "${state_dir}")"
    commands="$(jq -c --argjson record "${record}" '. + [$record]' <<<"${commands}")"
    current_sources="$(source_sha_json true)"
    json_objects_equal "${expected_sources}" "${current_sources}" \
      || die "post-contract command changed the expected clean source tree: ${id}"
  done

  atomic_json "${out}" -nc \
    --arg phase "post" \
    --arg expected_shas_manifest_sha256 "${expected_hash}" \
    --argjson source_shas "${expected_sources}" \
    --argjson commands "${commands}" \
    '{
      schema:1,
      phase:$phase,
      expected_shas_manifest_sha256:$expected_shas_manifest_sha256,
      source_shas:$source_shas,
      commands:$commands,
      created_at:(now|todateiso8601)
    }'
  echo "runtime Indicator V2 cutover evidence: post-contract manifest written: ${out}"
}

validate_coexistence_log_proof() {
  local id="$1" log="$2" expected_test
  if [[ "${id}" == "strategy-service-worker-v1-v2" ]]; then
    grep -Fq \
      'tests/test_runtime_worker_proto.py::test_worker_frame_keeps_v1_tag_during_additive_v2_gate PASSED' \
      "${log}" \
      && grep -Fq \
        'tests/test_grpc_server.py::test_proxy_only_backtest_flushes_custom_indicator_chunks PASSED' \
        "${log}" \
      || die "coexistence pytest log does not prove the fixed tests ran: ${id}"
    return
  fi
  case "${id}" in
    core-indicator-v1-v2|control-indicator-v1-v2)
      expected_test=TestIndicatorProtoV1CoexistsWithV2
      ;;
    handler-indicator-v1-v2)
      expected_test=TestStrategyIndicatorV1CoexistsWithV2
      ;;
    *)
      die "unknown coexistence command ID: ${id}"
      ;;
  esac
  grep -Fq "=== RUN   ${expected_test}" "${log}" \
    && grep -Fq -- "--- PASS: ${expected_test}" "${log}" \
    && grep -Fxq 'PASS' "${log}" \
    || die "coexistence Go log does not prove the fixed test ran: ${id}"
}

coexistence_command_json() {
  local id="$1" repository="$2" state_dir="$3" repository_sha="$4"
  local cwd="${SOURCE_ROOT}/${repository}"
  local log_dir="${state_dir}/coexistence"
  local log="${log_dir}/${id}.log"
  local raw="${log}.raw.$$"
  local started_at finished_at status log_sha argv environment uv_bin
  started_at="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  if [[ "${id}" == "strategy-service-worker-v1-v2" ]]; then
    uv_bin="$(runtime_coverage_resolve_uv_bin)" \
      || die "required command not found: uv"
  fi
  set +e
  case "${id}" in
    strategy-service-worker-v1-v2)
      (
        cd "${cwd}"
        PYTEST_ADDOPTS= PYTHONPATH=.:../strategy-library \
          "${uv_bin}" run --frozen --extra dev pytest \
          tests/test_runtime_worker_proto.py::test_worker_frame_keeps_v1_tag_during_additive_v2_gate \
          tests/test_grpc_server.py::test_proxy_only_backtest_flushes_custom_indicator_chunks \
          -vv --color=no
      ) >"${raw}" 2>&1
      status="$?"
      argv='[
        "uv", "run", "--frozen", "--extra", "dev", "pytest",
        "tests/test_runtime_worker_proto.py::test_worker_frame_keeps_v1_tag_during_additive_v2_gate",
        "tests/test_grpc_server.py::test_proxy_only_backtest_flushes_custom_indicator_chunks",
        "-vv",
        "--color=no"
      ]'
      environment='{"PYTEST_ADDOPTS":"","PYTHONPATH":".:../strategy-library"}'
      ;;
    core-indicator-v1-v2)
      (
        cd "${cwd}"
        go test ./internal/service -run IndicatorProtoV1CoexistsWithV2 -count=1 -v
      ) >"${raw}" 2>&1
      status="$?"
      argv='[
        "go", "test", "./internal/service", "-run",
        "IndicatorProtoV1CoexistsWithV2", "-count=1", "-v"
      ]'
      environment='{}'
      ;;
    control-indicator-v1-v2)
      (
        cd "${cwd}"
        go test ./internal/runtimechannel -run IndicatorProtoV1CoexistsWithV2 -count=1 -v
      ) >"${raw}" 2>&1
      status="$?"
      argv='[
        "go", "test", "./internal/runtimechannel", "-run",
        "IndicatorProtoV1CoexistsWithV2", "-count=1", "-v"
      ]'
      environment='{}'
      ;;
    handler-indicator-v1-v2)
      (
        cd "${cwd}"
        go test ./internal/app -run StrategyIndicatorV1CoexistsWithV2 -count=1 -v
      ) >"${raw}" 2>&1
      status="$?"
      argv='[
        "go", "test", "./internal/app", "-run",
        "StrategyIndicatorV1CoexistsWithV2", "-count=1", "-v"
      ]'
      environment='{}'
      ;;
    *)
      rm -f -- "${raw}"
      set -e
      die "unknown coexistence command ID: ${id}"
      ;;
  esac
  set -e
  finished_at="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  redact_log <"${raw}" >"${log}"
  chmod 0600 "${log}"
  rm -f -- "${raw}"
  [[ "${status}" -eq 0 ]] \
    || die "coexistence command failed: ${id}; see ${log}"
  [[ -s "${log}" ]] || die "coexistence command produced an empty log: ${id}"
  validate_coexistence_log_proof "${id}" "${log}"
  log_sha="$(sha256_file "${log}")"
  jq -nc \
    --arg id "${id}" \
    --arg repository "${repository}" \
    --arg repository_sha "${repository_sha}" \
    --arg cwd "${repository}" \
    --argjson argv "${argv}" \
    --argjson environment "${environment}" \
    --argjson exit_code "${status}" \
    --arg started_at "${started_at}" \
    --arg finished_at "${finished_at}" \
    --arg log_path "coexistence/${id}.log" \
    --arg log_sha256 "${log_sha}" \
    '{
      id:$id,
      repository:$repository,
      repository_sha:$repository_sha,
      cwd:$cwd,
      argv:$argv,
      environment:$environment,
      exit_code:$exit_code,
      started_at:$started_at,
      finished_at:$finished_at,
      log_path:$log_path,
      log_sha256:$log_sha256
    }'
}

capture_coexistence() {
  local state_dir="$1" chain="$2" out="$3"
  state_dir="$(canonical_directory "${state_dir}")"
  [[ "${chain}" == "${state_dir}/chain.json" ]] \
    || die "chain path must be <state-dir>/chain.json"
  [[ "${out}" == "${state_dir}/coexistence.json" ]] \
    || die "coexistence output must be <state-dir>/coexistence.json"
  validate_mode_0600_file "${chain}" "chain"
  [[ ! -e "${out}" && ! -e "${state_dir}/coexistence" ]] \
    || die "coexistence evidence already exists"

  local chain_sources chain_hash commands='[]' id repository repository_sha record
  jq -e '
    .schema == 1
    and .phase == "pre"
    and .status == "stopped"
    and .cleanup.complete == true
    and (.source_shas | type == "object")
  ' "${chain}" >/dev/null \
    || die "chain is not a completed pre-cutover run"
  chain_sources="$(jq -c .source_shas "${chain}")"
  validate_source_sha_map <<<"${chain_sources}" \
    || die "chain source SHA map is invalid"
  chain_hash="$(sha256_file "${chain}")"
  mkdir -m 0700 "${state_dir}/coexistence"

  for id in \
    strategy-service-worker-v1-v2 \
    core-indicator-v1-v2 \
    control-indicator-v1-v2 \
    handler-indicator-v1-v2; do
    case "${id}" in
      strategy-service-worker-v1-v2) repository="strategy-service" ;;
      core-indicator-v1-v2) repository="core-service" ;;
      control-indicator-v1-v2) repository="control-panel-service" ;;
      handler-indicator-v1-v2) repository="gateway/quant-handler" ;;
    esac
    repository_sha="$(jq -er --arg repository "${repository}" \
      '.[$repository]' <<<"${chain_sources}")"
    [[ "$(git -C "${SOURCE_ROOT}/${repository}" rev-parse HEAD)" == "${repository_sha}" ]] \
      || die "repository SHA does not match chain: ${repository}"
    [[ -z "$(git -C "${SOURCE_ROOT}/${repository}" status --porcelain --untracked-files=normal)" ]] \
      || die "repository is not clean: ${repository}"
    record="$(coexistence_command_json \
      "${id}" "${repository}" "${state_dir}" "${repository_sha}")"
    commands="$(jq -c --argjson record "${record}" '. + [$record]' <<<"${commands}")"
  done

  atomic_json "${out}" -nc \
    --arg phase "pre" \
    --arg chain_sha256 "${chain_hash}" \
    --argjson source_shas "${chain_sources}" \
    --argjson commands "${commands}" \
    '{
      schema:1,
      phase:$phase,
      chain_sha256:$chain_sha256,
      source_shas:$source_shas,
      commands:$commands,
      created_at:(now|todateiso8601)
    }'
  echo "runtime Indicator V2 cutover evidence: coexistence manifest written: ${out}"
}

canonical_json() {
  jq -S -c .
}

json_objects_equal() {
  local left="$1" right="$2"
  [[ "$(canonical_json <<<"${left}")" == "$(canonical_json <<<"${right}")" ]]
}

validate_chain_evidence() {
  local chain="$1" phase="$2" state_dir runtime_id runtime_root assertions finalization
  validate_mode_0600_file "${chain}" "chain"
  state_dir="$(canonical_directory "$(dirname "${chain}")")"
  [[ "${chain}" == "${state_dir}/chain.json" ]] \
    || die "chain path must be <state-dir>/chain.json"
  jq -e --arg phase "${phase}" '
    type == "object"
    and .schema == 1
    and .phase == $phase
    and .status == "stopped"
    and .evidence_eligible == true
    and (.source_dirty | type == "object")
    and (.source_dirty | keys) == (.source_shas | keys)
    and all(.source_dirty[]; . == false)
    and .cleanup.complete == true
    and .cleanup.supervisor_exit_code == 0
    and (.owner_token | type == "string" and test("^[0-9a-f]{64}$"))
    and (.generation | type == "string" and test("^generation-[0-9a-f]{32}$"))
    and (.runtime_id | type == "string" and test("^rt-[0-9a-f]{24}$"))
    and (.session_id | type == "string" and test("^[0-9a-f]{32}$"))
    and (.runtime_image | type == "string" and length > 0)
    and (.runtime_image_id | type == "string" and test("^sha256:[0-9a-f]{64}$"))
    and (.runtime_image_provenance | type == "object")
    and .runtime_image_provenance.source_dirty == false
    and .runtime_image_provenance.strategy_service_commit
      == .source_shas["strategy-service"]
    and .runtime_image_provenance.strategy_library_commit
      == .source_shas["strategy-library"]
    and (.runtime_image_provenance.golang_lib_commit
      | test("^[0-9a-f]{40}$"))
    and (.runtime_image_provenance.source_state_sha256
      | test("^[0-9a-f]{64}$"))
    and (.runtime_image_provenance.image_build_id
      | type == "string" and length > 0)
    and (.source_shas | type == "object")
    and (.databases | type == "object")
    and (.databases | keys) == [
      "control_panel", "market", "market_prefix", "order", "portfolio"
    ]
  ' "${chain}" >/dev/null \
    || die "chain is not completed, evidence-eligible ${phase} evidence"
  validate_source_sha_map < <(jq -c .source_shas "${chain}") \
    || die "chain source SHA map is invalid"

  runtime_id="$(jq -er .runtime_id "${chain}")"
  runtime_root="$(jq -er .runtime_root "${chain}")"
  [[ "${runtime_root}" == "${state_dir}/coverage/runtimes/${runtime_id}" ]] \
    || die "chain runtime coverage path does not match runtime_id"
  [[ -d "${runtime_root}" && ! -L "${runtime_root}" ]] \
    || die "runtime coverage directory is missing or unsafe"

  assertions="${state_dir}/assertions.json"
  validate_mode_0600_file "${assertions}" "assertions"
  jq -e --slurpfile chain "${chain}" '
    ($chain[0]) as $chain
    | .schema == 1
    and .owner_token == $chain.owner_token
    and .generation == $chain.generation
    and .runtime_id == $chain.runtime_id
    and .session_id == $chain.session_id
    and (.states | keys) == [
      "finalized-1024-plus-tail",
      "open-1023",
      "two-full-plus-tail"
    ]
    and .states["open-1023"].completed == 1023
    and .states["finalized-1024-plus-tail"].completed == 1025
    and .states["two-full-plus-tail"].completed == 2049
    and all(.states[];
      .api_database_equal == true
      and (.database_sha256 | test("^[0-9a-f]{64}$"))
      and .api_sha256 == .database_sha256
      and (.chunks | type == "array")
      and (.orders | type == "array")
    )
    and (.states["open-1023"].chunks | length) == 2
    and all(.states["open-1023"].chunks[];
      .chunk_index == 0 and .count == 1023 and .revision == 1023
      and .finalized == false and .protocol_version == 2
    )
    and (.states["finalized-1024-plus-tail"].chunks | length) == 4
    and ([.states["finalized-1024-plus-tail"].chunks[]
      | select(.chunk_index == 0 and .count == 1024 and .finalized == true)]
      | length) == 2
    and ([.states["finalized-1024-plus-tail"].chunks[]
      | select(.chunk_index == 1 and .count == 1 and .finalized == false)]
      | length) == 2
    and (.states["two-full-plus-tail"].chunks | length) == 6
    and ([.states["two-full-plus-tail"].chunks[]
      | select(.chunk_index == 0 and .count == 1024 and .finalized == true)]
      | length) == 2
    and ([.states["two-full-plus-tail"].chunks[]
      | select(.chunk_index == 1 and .count == 1024 and .finalized == true)]
      | length) == 2
    and ([.states["two-full-plus-tail"].chunks[]
      | select(.chunk_index == 2 and .count == 1 and .finalized == false)]
      | length) == 2
    and (.states["two-full-plus-tail"].orders | length) == 3
  ' "${assertions}" >/dev/null \
    || die "assertions do not prove the complete 1023/1025/2049 chain"

  finalization="${runtime_root}/finalization.json"
  validate_mode_0600_file "${finalization}" "runtime finalization"
  jq -e --arg runtime_id "${runtime_id}" '
    type == "object"
    and .schema_version == 1
    and .runtime_id == $runtime_id
    and .state == "complete"
    and .worker_shutdown == "ok"
    and .forced_workers == 0
    and .go_snapshot == "ok"
    and (.completed_at | type == "string" and length > 0)
  ' "${finalization}" >/dev/null \
    || die "runtime finalization is incomplete"
}

validate_browser_evidence() {
  local browser="$1" phase="$2" chain="$3" state_dir chain_sources browser_sources
  local runtime_id session_id screenshot_path expected_hash actual_hash screenshots='[]'
  validate_mode_0600_file "${browser}" "browser"
  state_dir="$(canonical_directory "$(dirname "${browser}")")"
  [[ "${browser}" == "${state_dir}/browser.json" ]] \
    || die "browser path must be <state-dir>/browser.json"
  runtime_id="$(jq -er .runtime_id "${chain}")"
  session_id="$(jq -er .session_id "${chain}")"
  jq -e \
    --arg phase "${phase}" \
    --arg runtime_id "${runtime_id}" \
    --arg session_id "${session_id}" \
    '
      type == "object"
      and .schema == 1
      and .phase == $phase
      and .runtime_id == $runtime_id
      and .session_id == $session_id
      and (.source_shas | type == "object")
      and (.browser.tab_id | type == "string" and length > 0)
      and (.browser.frontend_url | type == "string"
        and startswith("http://127.0.0.1:"))
      and [.actions[].id] == [
        "open-1023",
        "marker-open-time-order-close-time",
        "finalized-1024-plus-tail",
        "two-full-plus-tail",
        "double-refresh-immutable",
        "v2-network-contract",
        "console-network-clean"
      ]
      and all(.actions[];
        .passed == true
        and (.observed_at | type == "string" and length > 0)
      )
      and .assertions.chunk_1023 == {count:1023,finalized:false}
      and .assertions.chunk_1025 == [
        {count:1024,finalized:true},
        {count:1,finalized:false}
      ]
      and .assertions.chunk_2049 == [1024,1024,1]
      and .assertions.repeat_1023 == {
        row_delta:0,revision_delta:0,updated_at_changed:false
      }
      and .assertions.marker_1438 == {
        sequence:1438,time_ms_equals_open_time:true
      }
      and .assertions.close_time_preserved_for_order == true
      and .assertions.protocol_version == 2
      and .assertions.api_database_hash_equal == true
      and .console.unexpected_errors == 0
      and .network.unexpected_same_origin_errors == 0
      and (.screenshots | type == "array" and length > 0)
      and ([.screenshots[].path] | unique | length) == (.screenshots | length)
    ' "${browser}" >/dev/null \
    || die "browser evidence contract is incomplete"
  chain_sources="$(jq -c .source_shas "${chain}")"
  browser_sources="$(jq -c .source_shas "${browser}")"
  validate_source_sha_map <<<"${browser_sources}" \
    || die "browser source SHA map is invalid"
  json_objects_equal "${chain_sources}" "${browser_sources}" \
    || die "browser source SHA map does not match chain"

  while IFS=$'\t' read -r screenshot_path expected_hash; do
    [[ "${screenshot_path}" =~ ^screenshots/[A-Za-z0-9][A-Za-z0-9._-]*$ ]] \
      || die "browser screenshot path is unsafe: ${screenshot_path}"
    local absolute="${state_dir}/${screenshot_path}"
    validate_mode_0600_file "${absolute}" "browser screenshot"
    actual_hash="$(sha256_file "${absolute}")"
    [[ "${actual_hash}" == "${expected_hash}" ]] \
      || die "screenshot hash mismatch: ${screenshot_path}"
    screenshots="$(jq -c \
      --arg path "${screenshot_path}" \
      --arg sha256 "${actual_hash}" \
      '. + [{path:$path,sha256:$sha256}]' <<<"${screenshots}")"
  done < <(jq -r '.screenshots[] | [.path,.sha256] | @tsv' "${browser}")
  printf '%s\n' "${screenshots}"
}

validate_coexistence_evidence() {
  local manifest="$1" chain="$2" state_dir chain_hash chain_sources manifest_sources
  local commands='[]' id repository log_path log expected_hash actual_hash
  validate_mode_0600_file "${manifest}" "coexistence"
  state_dir="$(canonical_directory "$(dirname "${manifest}")")"
  [[ "${manifest}" == "${state_dir}/coexistence.json" ]] \
    || die "coexistence path must be <state-dir>/coexistence.json"
  chain_hash="$(sha256_file "${chain}")"
  jq -e --arg chain_hash "${chain_hash}" '
    type == "object"
    and .schema == 1
    and .phase == "pre"
    and .chain_sha256 == $chain_hash
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
      and (.started_at | type == "string" and length > 0)
      and (.finished_at | type == "string" and length > 0)
    )
    and .commands[0].repository == "strategy-service"
    and .commands[0].cwd == "strategy-service"
    and .commands[0].argv == [
      "uv", "run", "--frozen", "--extra", "dev", "pytest",
      "tests/test_runtime_worker_proto.py::test_worker_frame_keeps_v1_tag_during_additive_v2_gate",
      "tests/test_grpc_server.py::test_proxy_only_backtest_flushes_custom_indicator_chunks",
      "-vv", "--color=no"
    ]
    and .commands[0].environment == {
      PYTEST_ADDOPTS:"",
      PYTHONPATH:".:../strategy-library"
    }
    and .commands[1].repository == "core-service"
    and .commands[1].cwd == "core-service"
    and .commands[1].argv == [
      "go", "test", "./internal/service", "-run",
      "IndicatorProtoV1CoexistsWithV2", "-count=1", "-v"
    ]
    and .commands[1].environment == {}
    and .commands[2].repository == "control-panel-service"
    and .commands[2].cwd == "control-panel-service"
    and .commands[2].argv == [
      "go", "test", "./internal/runtimechannel", "-run",
      "IndicatorProtoV1CoexistsWithV2", "-count=1", "-v"
    ]
    and .commands[2].environment == {}
    and .commands[3].repository == "gateway/quant-handler"
    and .commands[3].cwd == "gateway/quant-handler"
    and .commands[3].argv == [
      "go", "test", "./internal/app", "-run",
      "StrategyIndicatorV1CoexistsWithV2", "-count=1", "-v"
    ]
    and .commands[3].environment == {}
  ' "${manifest}" >/dev/null \
    || die "coexistence manifest command table is invalid"
  chain_sources="$(jq -c .source_shas "${chain}")"
  manifest_sources="$(jq -c .source_shas "${manifest}")"
  json_objects_equal "${chain_sources}" "${manifest_sources}" \
    || die "coexistence source SHA map does not match chain"

  while IFS=$'\t' read -r id repository log_path expected_hash; do
    [[ "${log_path}" == "coexistence/${id}.log" ]] \
      || die "coexistence log path is not fixed for ${id}"
    log="${state_dir}/${log_path}"
    validate_mode_0600_file "${log}" "coexistence log"
    [[ -s "${log}" ]] || die "coexistence log is empty: ${id}"
    actual_hash="$(sha256_file "${log}")"
    [[ "${actual_hash}" == "${expected_hash}" ]] \
      || die "coexistence log hash mismatch: ${id}"
    [[ "$(jq -r --arg id "${id}" '.commands[] | select(.id == $id) | .repository_sha' "${manifest}")" \
      == "$(jq -r --arg repository "${repository}" '.[$repository]' <<<"${chain_sources}")" ]] \
      || die "coexistence repository SHA mismatch: ${id}"
    validate_coexistence_log_proof "${id}" "${log}"
    commands="$(jq -c \
      --arg id "${id}" \
      --arg repository_sha "$(jq -r --arg id "${id}" \
        '.commands[] | select(.id == $id) | .repository_sha' "${manifest}")" \
      --arg log_sha256 "${actual_hash}" \
      '. + [{id:$id,repository_sha:$repository_sha,log_sha256:$log_sha256}]' \
      <<<"${commands}")"
  done < <(jq -r '.commands[] | [.id,.repository,.log_path,.log_sha256] | @tsv' \
    "${manifest}")
  printf '%s\n' "${commands}"
}

validate_expected_shas_manifest() {
  local expected="$1" expected_sources
  validate_mode_0600_file "${expected}" "expected SHA manifest"
  jq -e '
    type == "object"
    and keys == ["schema", "source_shas"]
    and .schema == 1
    and (.source_shas | type == "object")
  ' "${expected}" >/dev/null \
    || die "expected SHA manifest schema is invalid"
  expected_sources="$(jq -c .source_shas "${expected}")"
  validate_source_sha_map <<<"${expected_sources}" \
    || die "expected SHA manifest repository set is invalid"
  printf '%s\n' "${expected_sources}"
}

validate_post_contract_evidence() {
  local manifest="$1" expected_shas="$2"
  local state_dir expected_hash expected_sources manifest_sources commands='[]'
  local id log_path log expected_log_hash actual_log_hash
  validate_mode_0600_file "${manifest}" "post-contract manifest"
  state_dir="$(canonical_directory "$(dirname "${manifest}")")"
  [[ "${manifest}" == "${state_dir}/post-contracts.json" ]] \
    || die "post-contract manifest path must be <state-dir>/post-contracts.json"
  [[ "${expected_shas}" == "${state_dir}/final-shas.json" ]] \
    || die "post-contract expected SHA manifest must share its state directory"
  expected_hash="$(sha256_file "${expected_shas}")"
  jq -e --arg expected_hash "${expected_hash}" '
    type == "object"
    and .schema == 1
    and .phase == "post"
    and .expected_shas_manifest_sha256 == $expected_hash
    and (.source_shas | type == "object")
    and [.commands[].id] == [
      "indicator-v1-removed-source-generated",
      "runtime-dependency-combined-descriptor-checksum"
    ]
    and (.commands | length) == 2
    and all(.commands[];
      .cwd == "hushine-deploy"
      and .exit_code == 0
      and (.started_at | type == "string" and length > 0)
      and (.finished_at | type == "string" and length > 0)
      and (.log_sha256 | test("^[0-9a-f]{64}$"))
    )
    and .commands[0].argv == [
      "bash", "scripts/runtime-indicator-v2-cutover-evidence.test.sh", "scan-no-v1"
    ]
    and .commands[0].log_path ==
      "post-contracts/indicator-v1-removed-source-generated.log"
    and .commands[1].argv == [
      "bash", "scripts/runtime-indicator-v2-cutover-evidence.test.sh",
      "check-dependency-combined"
    ]
    and .commands[1].log_path ==
      "post-contracts/runtime-dependency-combined-descriptor-checksum.log"
  ' "${manifest}" >/dev/null \
    || die "post-contract manifest command table is invalid"
  expected_sources="$(validate_expected_shas_manifest "${expected_shas}")"
  manifest_sources="$(jq -c .source_shas "${manifest}")"
  json_objects_equal "${manifest_sources}" "${expected_sources}" \
    || die "post-contract source SHA map does not match expected SHAs"

  while IFS=$'\t' read -r id log_path expected_log_hash; do
    [[ "${log_path}" == "post-contracts/${id}.log" ]] \
      || die "post-contract log path is not fixed for ${id}"
    log="${state_dir}/${log_path}"
    validate_mode_0600_file "${log}" "post-contract log"
    [[ -s "${log}" ]] || die "post-contract log is empty: ${id}"
    actual_log_hash="$(sha256_file "${log}")"
    [[ "${actual_log_hash}" == "${expected_log_hash}" ]] \
      || die "post-contract log hash mismatch: ${id}"
    validate_post_contract_log_proof "${id}" "${log}"
    commands="$(jq -c \
      --arg id "${id}" \
      --arg log_sha256 "${actual_log_hash}" \
      '. + [{id:$id,log_sha256:$log_sha256}]' <<<"${commands}")"
  done < <(jq -r '.commands[] | [.id,.log_path,.log_sha256] | @tsv' "${manifest}")
  printf '%s\n' "${commands}"
}

build_seal_payload() {
  local phase="$1" chain="$2" browser="$3" coexistence="$4" expected_shas="$5" post_contracts="$6"
  local state_dir chain_sources current_sources screenshots coexistence_commands='[]'
  local assertions finalization chain_hash assertions_hash finalization_hash browser_hash
  local coexistence_hash="" expected_hash="" expected_sources=""
  local post_contract_hash="" post_contract_commands='[]'
  state_dir="$(canonical_directory "$(dirname "${chain}")")"
  validate_chain_evidence "${chain}" "${phase}"
  chain_sources="$(jq -c .source_shas "${chain}")"
  current_sources="$(source_sha_json true)"
  json_objects_equal "${chain_sources}" "${current_sources}" \
    || die "current clean repository SHAs do not match chain"
  screenshots="$(validate_browser_evidence "${browser}" "${phase}" "${chain}")"

  if [[ "${phase}" == "pre" ]]; then
    [[ -n "${coexistence}" ]] || die "pre phase requires coexistence evidence"
    coexistence_commands="$(validate_coexistence_evidence "${coexistence}" "${chain}")"
    coexistence_hash="$(sha256_file "${coexistence}")"
    [[ -z "${expected_shas}" ]] \
      || die "pre phase does not accept an expected SHA manifest"
    [[ -z "${post_contracts}" ]] \
      || die "pre phase does not accept post-contract evidence"
  else
    [[ -z "${coexistence}" ]] \
      || die "post phase does not accept coexistence evidence"
    [[ -n "${expected_shas}" ]] || die "post phase requires --expected-shas"
    expected_sources="$(validate_expected_shas_manifest "${expected_shas}")"
    json_objects_equal "${chain_sources}" "${expected_sources}" \
      || die "expected SHA manifest does not match post chain"
    expected_hash="$(sha256_file "${expected_shas}")"
    [[ -n "${post_contracts}" ]] || die "post phase requires post-contract evidence"
    post_contract_commands="$(validate_post_contract_evidence \
      "${post_contracts}" "${expected_shas}")"
    post_contract_hash="$(sha256_file "${post_contracts}")"
  fi

  assertions="${state_dir}/assertions.json"
  finalization="$(jq -er .runtime_root "${chain}")/finalization.json"
  chain_hash="$(sha256_file "${chain}")"
  assertions_hash="$(sha256_file "${assertions}")"
  finalization_hash="$(sha256_file "${finalization}")"
  browser_hash="$(sha256_file "${browser}")"

  jq -S -nc \
    --arg phase "${phase}" \
    --argjson source_shas "${chain_sources}" \
    --arg owner_token "$(jq -r .owner_token "${chain}")" \
    --arg generation "$(jq -r .generation "${chain}")" \
    --arg runtime_id "$(jq -r .runtime_id "${chain}")" \
    --arg session_id "$(jq -r .session_id "${chain}")" \
    --arg runtime_image "$(jq -r .runtime_image "${chain}")" \
    --arg runtime_image_id "$(jq -r .runtime_image_id "${chain}")" \
    --argjson runtime_image_provenance "$(jq -c .runtime_image_provenance "${chain}")" \
    --argjson databases "$(jq -c .databases "${chain}")" \
    --arg chain_sha256 "${chain_hash}" \
    --arg assertions_sha256 "${assertions_hash}" \
    --arg runtime_finalization_sha256 "${finalization_hash}" \
    --arg browser_sha256 "${browser_hash}" \
    --arg browser_tab_id "$(jq -r .browser.tab_id "${browser}")" \
    --argjson browser_assertions "$(jq -c .assertions "${browser}")" \
    --argjson screenshots "${screenshots}" \
    --arg coexistence_manifest_sha256 "${coexistence_hash}" \
    --argjson coexistence_commands "${coexistence_commands}" \
    --arg expected_shas_manifest_sha256 "${expected_hash}" \
    --arg post_contract_manifest_sha256 "${post_contract_hash}" \
    --argjson post_contract_commands "${post_contract_commands}" \
    '{
      source_shas:$source_shas,
      owner_token:$owner_token,
      generation:$generation,
      runtime_id:$runtime_id,
      session_id:$session_id,
      runtime_image:$runtime_image,
      runtime_image_id:$runtime_image_id,
      runtime_image_provenance:$runtime_image_provenance,
      databases:$databases,
      chain_sha256:$chain_sha256,
      assertions_sha256:$assertions_sha256,
      runtime_finalization_sha256:$runtime_finalization_sha256,
      browser_sha256:$browser_sha256,
      browser_tab_id:$browser_tab_id,
      browser_assertions:$browser_assertions,
      screenshots:$screenshots,
      coexistence_manifest_sha256:
        (if $phase == "pre" then $coexistence_manifest_sha256 else null end),
      coexistence_commands:
        (if $phase == "pre" then $coexistence_commands else [] end),
      expected_shas_manifest_sha256:
        (if $phase == "post" then $expected_shas_manifest_sha256 else null end),
      post_contract_manifest_sha256:
        (if $phase == "post" then $post_contract_manifest_sha256 else null end),
      post_contract_commands:
        (if $phase == "post" then $post_contract_commands else [] end)
    }'
}

seal_evidence() {
  local phase="$1" chain="$2" browser="$3" coexistence="$4" expected_shas="$5" post_contracts="$6" seal="$7"
  local payload payload_canonical payload_hash existing_payload existing_hash
  payload="$(build_seal_payload \
    "${phase}" "${chain}" "${browser}" "${coexistence}" "${expected_shas}" "${post_contracts}")"
  payload_canonical="$(canonical_json <<<"${payload}")"
  payload_hash="$(
    if command -v shasum >/dev/null 2>&1; then
      printf '%s' "${payload_canonical}" | shasum -a 256 | awk '{print $1}'
    else
      printf '%s' "${payload_canonical}" | sha256sum | awk '{print $1}'
    fi
  )"

  if [[ -e "${seal}" ]]; then
    validate_mode_0600_file "${seal}" "seal"
    jq -e --arg phase "${phase}" '
      type == "object"
      and keys == ["payload", "payload_sha256", "phase", "schema", "sealed_at"]
      and .schema == 1
      and .phase == $phase
      and (.sealed_at | type == "string" and length > 0)
      and (.payload_sha256 | test("^[0-9a-f]{64}$"))
      and (.payload | type == "object")
    ' "${seal}" >/dev/null \
      || die "seal schema or phase is invalid"
    existing_payload="$(jq -S -c .payload "${seal}")"
    existing_hash="$(jq -r .payload_sha256 "${seal}")"
    [[ "${existing_payload}" == "${payload_canonical}" ]] \
      || die "seal payload does not match current evidence"
    [[ "${existing_hash}" == "${payload_hash}" ]] \
      || die "seal payload hash does not match current evidence"
    echo "runtime Indicator V2 cutover evidence: seal revalidated: ${seal}"
    return
  fi

  atomic_json "${seal}" -nc \
    --arg phase "${phase}" \
    --argjson payload "${payload_canonical}" \
    --arg payload_sha256 "${payload_hash}" \
    '{
      schema:1,
      phase:$phase,
      payload:$payload,
      payload_sha256:$payload_sha256,
      sealed_at:(now|todateiso8601)
    }'
  echo "runtime Indicator V2 cutover evidence: seal written: ${seal}"
}

run_seal_command() {
  local phase="$1"
  shift
  local chain="" browser="" coexistence="" expected_shas="" post_contracts="" seal=""
  local check_current=false require_clean=false state_dir
  while (( $# )); do
    case "$1" in
      --chain) chain="${2:-}"; shift 2 ;;
      --browser) browser="${2:-}"; shift 2 ;;
      --coexistence) coexistence="${2:-}"; shift 2 ;;
      --expected-shas) expected_shas="${2:-}"; shift 2 ;;
      --post-contracts) post_contracts="${2:-}"; shift 2 ;;
      --seal) seal="${2:-}"; shift 2 ;;
      --check-current-shas) check_current=true; shift ;;
      --require-clean) require_clean=true; shift ;;
      *) usage ;;
    esac
  done
  [[ "${phase}" == "pre" || "${phase}" == "post" ]] \
    || die "--phase must be pre or post"
  [[ -n "${seal}" ]] || usage
  canonical_parent "${seal}"
  state_dir="$(canonical_directory "$(dirname "${seal}")")"
  [[ "${seal}" == "${state_dir}/seal.json" ]] \
    || die "seal path must be <state-dir>/seal.json"
  [[ "${check_current}" == "true" ]] \
    || die "seal creation and revalidation require --check-current-shas"
  if [[ -e "${seal}" ]]; then
    [[ -n "${chain}" ]] || chain="${state_dir}/chain.json"
    [[ -n "${browser}" ]] || browser="${state_dir}/browser.json"
    if [[ "${phase}" == "pre" && -z "${coexistence}" ]]; then
      coexistence="${state_dir}/coexistence.json"
    fi
  fi
  if [[ "${phase}" == "post" && -z "${post_contracts}" ]]; then
    post_contracts="${state_dir}/post-contracts.json"
  fi
  [[ -n "${chain}" && -n "${browser}" ]] || usage
  [[ "${chain}" == "${state_dir}/chain.json" ]] \
    || die "chain and seal must share one state directory"
  [[ "${browser}" == "${state_dir}/browser.json" ]] \
    || die "browser and seal must share one state directory"
  if [[ -n "${coexistence}" && "${coexistence}" != "${state_dir}/coexistence.json" ]]; then
    die "coexistence and seal must share one state directory"
  fi
  if [[ -n "${expected_shas}" ]]; then
    [[ "${expected_shas}" == /* ]] \
      || die "--expected-shas must be absolute"
  fi
  if [[ -n "${post_contracts}" && "${post_contracts}" != "${state_dir}/post-contracts.json" ]]; then
    die "post-contract evidence and seal must share one state directory"
  fi
  # Clean repositories are mandatory for both creation and revalidation.
  # --require-clean remains accepted for the explicit final revalidation command.
  : "${require_clean}"
  seal_evidence \
    "${phase}" "${chain}" "${browser}" "${coexistence}" "${expected_shas}" "${post_contracts}" "${seal}"
}

usage() {
  cat >&2 <<'EOF'
usage:
  runtime-indicator-v2-cutover-evidence.test.sh --write-current-shas /absolute/current-shas.json [--require-clean]
  runtime-indicator-v2-cutover-evidence.test.sh scan-no-v1
  runtime-indicator-v2-cutover-evidence.test.sh check-dependency-combined
  runtime-indicator-v2-cutover-evidence.test.sh capture-coexistence --state-dir /absolute/state --chain /absolute/state/chain.json --out /absolute/state/coexistence.json
  runtime-indicator-v2-cutover-evidence.test.sh capture-post-contracts --state-dir /absolute/state --expected-shas /absolute/state/final-shas.json --out /absolute/state/post-contracts.json
  runtime-indicator-v2-cutover-evidence.test.sh --phase pre --chain /absolute/state/chain.json --browser /absolute/state/browser.json --coexistence /absolute/state/coexistence.json --seal /absolute/state/seal.json --check-current-shas
  runtime-indicator-v2-cutover-evidence.test.sh --phase post --expected-shas /absolute/state/final-shas.json --post-contracts /absolute/state/post-contracts.json --chain /absolute/state/chain.json --browser /absolute/state/browser.json --seal /absolute/state/seal.json --check-current-shas
  runtime-indicator-v2-cutover-evidence.test.sh --phase pre|post --seal /absolute/state/seal.json [--expected-shas /absolute/state/final-shas.json] [--post-contracts /absolute/state/post-contracts.json] --check-current-shas --require-clean
EOF
  exit 2
}

require_command git
require_command jq

case "${1:-}" in
  scan-no-v1)
    [[ "$#" -eq 1 ]] || usage
    run_no_v1_scan
    ;;
  check-dependency-combined)
    [[ "$#" -eq 1 ]] || usage
    run_dependency_combined_gate
    ;;
  --phase)
    [[ -n "${2:-}" ]] || usage
    phase="$2"
    shift 2
    run_seal_command "${phase}" "$@"
    ;;
  --write-current-shas)
    [[ -n "${2:-}" ]] || usage
    destination="$2"
    shift 2
    require_clean=false
    if (( $# )); then
      [[ "${1:-}" == "--require-clean" && $# -eq 1 ]] || usage
      require_clean=true
    fi
    write_current_shas "${destination}" "${require_clean}"
    ;;
  capture-coexistence)
    shift
    state_dir=""
    chain=""
    out=""
    while (( $# )); do
      case "$1" in
        --state-dir) state_dir="${2:-}"; shift 2 ;;
        --chain) chain="${2:-}"; shift 2 ;;
        --out) out="${2:-}"; shift 2 ;;
        *) usage ;;
      esac
    done
    [[ -n "${state_dir}" && -n "${chain}" && -n "${out}" ]] || usage
    capture_coexistence "${state_dir}" "${chain}" "${out}"
    ;;
  capture-post-contracts)
    shift
    state_dir=""
    expected_shas=""
    out=""
    while (( $# )); do
      case "$1" in
        --state-dir) state_dir="${2:-}"; shift 2 ;;
        --expected-shas) expected_shas="${2:-}"; shift 2 ;;
        --out) out="${2:-}"; shift 2 ;;
        *) usage ;;
      esac
    done
    [[ -n "${state_dir}" && -n "${expected_shas}" && -n "${out}" ]] || usage
    capture_post_contracts "${state_dir}" "${expected_shas}" "${out}"
    ;;
  *)
    usage
    ;;
esac
