#!/usr/bin/env bash
set -euo pipefail

DEPLOY_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)"
if [[ -d "${DEPLOY_ROOT}/core-service" ]]; then
  default_source_root="${DEPLOY_ROOT}"
else
  default_source_root="$(cd -- "${DEPLOY_ROOT}/.." && pwd -P)"
fi
SOURCE_ROOT="${HUSHINE_SOURCE_ROOT:-${default_source_root}}"
DOCS_ROOT="${HUSHINE_DOCS_ROOT:-${SOURCE_ROOT}/hushine-docs}"
BUILD_ROOT="${DOCS_BUILD_ROOT:-${SOURCE_ROOT}/.generated/docs-build}"
NODE_BIN="${NODE_BIN:-node}"

[[ -d "${DOCS_ROOT}/.git" ]] || {
  echo "missing hushine-docs repository: ${DOCS_ROOT}" >&2
  exit 1
}
[[ -f "${DOCS_ROOT}/scripts/build.mjs" ]] || {
  echo "hushine-docs builder is missing: ${DOCS_ROOT}/scripts/build.mjs" >&2
  exit 1
}

scratch="$(mktemp -d "${TMPDIR:-/tmp}/hushine-docs-build.XXXXXX")"
cleanup() {
  rm -rf -- "${scratch}"
}
trap cleanup EXIT HUP INT TERM

deployment="${scratch}/deployment.json"
python3 "${DEPLOY_ROOT}/scripts/docs/deployment-manifest.py" \
  --source-root "${SOURCE_ROOT}" \
  --output "${deployment}"

docs_commit="$(git -C "${DOCS_ROOT}" rev-parse HEAD)"
source_date_epoch="$(git -C "${DOCS_ROOT}" show -s --format=%ct "${docs_commit}")"
mkdir -p "${BUILD_ROOT}"
(
  cd "${DOCS_ROOT}"
  SOURCE_DATE_EPOCH="${source_date_epoch}" \
    "${NODE_BIN}" scripts/build.mjs \
      --deployment "${deployment}" \
      --out "${BUILD_ROOT}"
)

release="${BUILD_ROOT}/${docs_commit}"
[[ -s "${release}/manifest.json" && -s "${release}/search-index.json" ]] || {
  echo "document builder did not produce a complete release: ${release}" >&2
  exit 1
}
printf '%s\n' "${release}"
