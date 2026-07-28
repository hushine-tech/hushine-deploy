#!/usr/bin/env bash
# Shared safety boundary for hosted Runtime coverage collection.
#
# Callers own Runtime provisioning and shutdown. This library owns canonical
# path checks, container/mount identity, locked raw-input staging, the complete
# finalization marker, and deterministic Go/Python report generation.

runtime_coverage_error() {
  echo "$*" >&2
  return 1
}

runtime_coverage_resolve_uv_bin() {
  local candidate configured candidate_dir candidate_base canonical_dir
  configured="${UV_BIN:-${UV:-}}"
  candidate="${configured}"
  if [[ -n "${configured}" ]]; then
    if [[ "${candidate}" != */* ]]; then
      candidate="$(command -v "${candidate}" 2>/dev/null || true)"
    fi
  else
    candidate="$(command -v uv 2>/dev/null || true)"
  fi
  if [[ -z "${candidate}" && -z "${configured}" && -n "${HOME:-}" && -x "${HOME}/.local/bin/uv" ]]; then
    candidate="${HOME}/.local/bin/uv"
  fi
  if [[ "${candidate}" == */* ]]; then
    candidate_dir="$(dirname -- "${candidate}")"
    candidate_base="$(basename -- "${candidate}")"
    canonical_dir="$(cd -- "${candidate_dir}" 2>/dev/null && pwd -P)" || candidate=""
    if [[ -n "${candidate}" ]]; then
      candidate="${canonical_dir}/${candidate_base}"
    fi
  fi
  [[ -n "${candidate}" && -x "${candidate}" ]] || return 1
  printf '%s\n' "${candidate}"
}

runtime_coverage_safe_component() {
  local value="$1"
  [[ "${value}" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ && "${value}" != "." && "${value}" != ".." ]]
}

runtime_coverage_prepare_output_root() {
  local requested="$1" canonical
  case "${requested}" in
    /*) ;;
    *) runtime_coverage_error "output directory must be absolute: ${requested}"; return 2 ;;
  esac
  if [[ -L "${requested}" ]]; then
    runtime_coverage_error "output directory must not be a symlink: ${requested}"
    return 2
  fi
  mkdir -p -- "${requested}"
  chmod 0700 "${requested}"
  canonical="$(cd -- "${requested}" && pwd -P)"
  if [[ "${canonical}" != "${requested}" ]]; then
    runtime_coverage_error "output directory must be canonical: ${requested}"
    return 2
  fi
  RUNTIME_COVERAGE_OUTPUT_ROOT="${canonical}"
}

runtime_coverage_expected_run_label() {
  local output_root="$1" label
  label="$(basename -- "${output_root}")"
  if [[ "${label}" == "runtime-agent" && "$(basename -- "$(dirname -- "${output_root}")")" == "coverage" ]]; then
    label="$(basename -- "$(dirname -- "$(dirname -- "${output_root}")")")"
  fi
  printf '%s\n' "${label}"
}

runtime_coverage_validate_layout() {
  local output_root="$1" runtime_id="$2" directory runtimes_root runtime_root
  if ! runtime_coverage_safe_component "${runtime_id}"; then
    runtime_coverage_error "runtime_id has unsafe characters"
    return 1
  fi
  runtimes_root="${output_root}/runtimes"
  runtime_root="${runtimes_root}/${runtime_id}"
  for directory in "${runtimes_root}" "${runtime_root}" "${runtime_root}/go" "${runtime_root}/python"; do
    if [[ ! -d "${directory}" || -L "${directory}" ]]; then
      runtime_coverage_error "expected safe coverage directory missing: ${directory}"
      return 1
    fi
  done
  runtimes_root="$(cd -- "${runtimes_root}" && pwd -P)"
  runtime_root="$(cd -- "${runtime_root}" && pwd -P)"
  if [[ "${runtime_root}" != "${runtimes_root}/${runtime_id}" ]]; then
    runtime_coverage_error "runtime coverage path escapes output root"
    return 1
  fi
  RUNTIME_COVERAGE_RUNTIMES_ROOT="${runtimes_root}"
  RUNTIME_COVERAGE_RUNTIME_ROOT="${runtime_root}"
  RUNTIME_COVERAGE_GO_DIR="${runtime_root}/go"
  RUNTIME_COVERAGE_PYTHON_DIR="${runtime_root}/python"
}

runtime_coverage_container_owned() {
  local container_name="$1" runtime_id="$2" user_id="$3" image_id="$4"
  local runtime_label user_label coverage_label actual_image
  docker container inspect "${container_name}" >/dev/null 2>&1 || return 1
  runtime_label="$(docker container inspect --format '{{index .Config.Labels "hushine.runtime.runtime_id"}}' "${container_name}")"
  user_label="$(docker container inspect --format '{{index .Config.Labels "hushine.runtime.user_id"}}' "${container_name}")"
  coverage_label="$(docker container inspect --format '{{index .Config.Labels "hushine.runtime.coverage"}}' "${container_name}")"
  actual_image="$(docker container inspect --format '{{.Image}}' "${container_name}")"
  [[ "${runtime_label}" == "${runtime_id}" && "${user_label}" == "${user_id}" && "${coverage_label}" == "true" && "${actual_image}" == "${image_id}" ]]
}

runtime_coverage_reject_internal_env_names() {
  local env_names="$1" forbidden
  forbidden="$(grep -Ei '(^|_)(DATABASE|DB|KAFKA|MARKET_DATA|PORTFOLIO|ORDER|ACCOUNT|CORE_SERVICE)(_|$)|(^|_)API_(KEY|SECRET)($|_)' <<<"${env_names}" || true)"
  if [[ -n "${forbidden}" ]]; then
    runtime_coverage_error "hosted runtime received forbidden internal environment names: $(tr '\n' ' ' <<<"${forbidden}" | sed 's/[[:space:]]*$//')"
    return 1
  fi
}

runtime_coverage_validate_container() {
  local container_name="$1" runtime_id="$2" user_id="$3" image_id="$4" runtime_root="$5" output_root="$6"
  local container_id actual_image coverage_label run_label mount_source env_names expected_run_label name
  if ! runtime_coverage_container_owned "${container_name}" "${runtime_id}" "${user_id}" "${image_id}"; then
    runtime_coverage_error "coverage container ownership validation failed"
    return 1
  fi
  container_id="$(docker container inspect --format '{{.Id}}' "${container_name}")"
  actual_image="$(docker container inspect --format '{{.Image}}' "${container_name}")"
  coverage_label="$(docker container inspect --format '{{index .Config.Labels "hushine.runtime.coverage"}}' "${container_name}")"
  run_label="$(docker container inspect --format '{{index .Config.Labels "hushine.runtime.coverage_run_id"}}' "${container_name}")"
  mount_source="$(docker container inspect "${container_name}" | jq -r '.[0].Mounts[] | select(.Destination == "/coverage") | .Source')"
  env_names="$(docker container inspect "${container_name}" | jq -r '.[0].Config.Env | map(split("=")[0]) | .[]')"
  expected_run_label="$(runtime_coverage_expected_run_label "${output_root}")"
  if [[ "${actual_image}" != "${image_id}" || "${coverage_label}" != "true" || "${run_label}" != "${expected_run_label}" || "${mount_source}" != "${runtime_root}" ]]; then
    runtime_coverage_error "coverage container image/label/mount validation failed"
    return 1
  fi
  for name in GOCOVERDIR HUSHINE_RUNTIME_COVERAGE_DIR; do
    if ! grep -Fxq "${name}" <<<"${env_names}"; then
      runtime_coverage_error "coverage environment name missing: ${name}"
      return 1
    fi
  done
  runtime_coverage_reject_internal_env_names "${env_names}" || return 1
  RUNTIME_COVERAGE_CONTAINER_ID="${container_id}"
  RUNTIME_COVERAGE_CONTAINER_IMAGE_ID="${actual_image}"
  RUNTIME_COVERAGE_CONTAINER_ENV_NAMES="${env_names}"
  RUNTIME_COVERAGE_RUN_LABEL="${run_label}"
}

runtime_coverage_stage_locked_inputs() {
  local helper_bin="$1" source_root="$2" output_root="$3" runtime_root="$4" runtime_id="$5"
  local report_root
  report_root="${output_root}/smoke-reports/${runtime_id}"
  (
    cd "${source_root}/control-panel-service"
    "${helper_bin}" \
      -action stage-coverage \
      -output-root "${output_root}" \
      -runtime-root "${runtime_root}" \
      -report-root "${report_root}" \
      -strategy-root "${source_root}/strategy-service" \
      -runtime "${runtime_id}" \
      -timeout 45s
  )
  RUNTIME_COVERAGE_REPORT_ROOT="${report_root}"
  RUNTIME_COVERAGE_PYTHON_INPUT_DIR="${report_root}/python-input"
}

runtime_coverage_require_finalization() {
  local runtime_root="$1" runtime_id="$2" finalization_file
  finalization_file="${runtime_root}/finalization.json"
  if [[ ! -f "${finalization_file}" || -L "${finalization_file}" ]]; then
    runtime_coverage_error "runtime coverage finalization marker is missing or unsafe"
    return 1
  fi
  if ! jq -e --arg runtime_id "${runtime_id}" '
    type == "object"
    and (keys == ["boot_id", "completed_at", "forced_workers", "go_snapshot", "runtime_id", "schema_version", "state", "worker_shutdown"])
    and .schema_version == 1
    and .runtime_id == $runtime_id
    and (.boot_id | type == "string" and length > 0)
    and .state == "complete"
    and .worker_shutdown == "ok"
    and .forced_workers == 0
    and .go_snapshot == "ok"
    and (.completed_at | type == "string" and length > 0)
  ' "${finalization_file}" >/dev/null; then
    runtime_coverage_error "runtime coverage finalization marker is not complete"
    return 1
  fi
  RUNTIME_COVERAGE_FINALIZATION_FILE="${finalization_file}"
}

runtime_coverage_require_python_hits() {
  local report="$1"
  if [[ ! -f "${report}" || -L "${report}" ]] || ! jq -e '
    .totals.covered_lines
    | type == "number" and . > 0 and . == floor
  ' "${report}" >/dev/null; then
    runtime_coverage_error "Python coverage report has no covered lines: ${report}"
    return 1
  fi
}

runtime_coverage_generate_reports() {
  local source_root="$1" go_dir="$2" python_input_dir="$3" report_root="$4"
  local go_merged python_rc report uv_bin
  if ! find "${go_dir}" -type f -print -quit | grep -q .; then
    runtime_coverage_error "Go coverage output is missing: ${go_dir}"
    return 1
  fi
  if ! find "${python_input_dir}" -maxdepth 1 -name '.coverage*' -type f -print -quit | grep -q .; then
    runtime_coverage_error "staged Python coverage output is missing: ${python_input_dir}"
    return 1
  fi

  go_merged="${report_root}/go-merged"
  mkdir -p "${go_merged}"
  (
    cd "${source_root}/strategy-service"
    go tool covdata merge -i="${go_dir}" -o="${go_merged}"
    go tool covdata textfmt -i="${go_merged}" -o="${report_root}/go.cover.out"
    go tool cover -func="${report_root}/go.cover.out" >"${report_root}/go-functions.txt"
  )

  python_rc="${report_root}/python-report.coveragerc"
  if ! uv_bin="$(runtime_coverage_resolve_uv_bin)"; then
    runtime_coverage_error "required command not found: uv"
    return 1
  fi
  {
    echo '[paths]'
    echo 'source ='
    printf '    %s\n' "${source_root}/strategy-service/strategy_service"
    echo '    /app/strategy-service/strategy_service'
    echo '    /app/strategy-service/.venv/lib/python*/site-packages/strategy_service'
  } >"${python_rc}"
  (
    export COVERAGE_FILE="${python_input_dir}/.coverage"
    export COVERAGE_RCFILE="${python_rc}"
    cd "${source_root}/strategy-service"
    "${uv_bin}" run --frozen --extra coverage coverage combine --keep "${python_input_dir}"
    "${uv_bin}" run --frozen --extra coverage coverage report --keep-combined >"${report_root}/python-report.txt"
    "${uv_bin}" run --frozen --extra coverage coverage json --keep-combined -o "${report_root}/python-coverage.json"
  )

  for report in \
    "${report_root}/go.cover.out" \
    "${report_root}/go-functions.txt" \
    "${report_root}/python-report.txt" \
    "${report_root}/python-coverage.json"; do
    if [[ ! -s "${report}" ]]; then
      runtime_coverage_error "coverage report is missing or empty: ${report}"
      return 1
    fi
  done
  runtime_coverage_require_python_hits "${report_root}/python-coverage.json"
}
