#!/usr/bin/env bash
set -euo pipefail

DEPLOY_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
SOURCE_ROOT="$(cd -- "${DEPLOY_ROOT}/.." && pwd -P)"
DOCS_ROOT="${SOURCE_ROOT}/hushine-docs"
HANDLER_ROOT="${SOURCE_ROOT}/gateway/quant-handler"
FRONTEND_ROOT="${SOURCE_ROOT}/gateway/quant-frontend"

[[ -d "${DOCS_ROOT}/.git" ]] || {
  echo "missing hushine-docs repository: ${DOCS_ROOT}" >&2
  exit 1
}
[[ -f "${DOCS_ROOT}/tests/fixtures/deployment.json" ]] || {
  echo "missing document smoke deployment fixture" >&2
  exit 1
}

scratch="$(mktemp -d "${TMPDIR:-/tmp}/hushine-docs-portal-smoke.XXXXXX")"
cleanup() {
  rm -rf -- "${scratch}"
}
trap cleanup EXIT HUP INT TERM

docs_commit="$(git -C "${DOCS_ROOT}" rev-parse HEAD)"
source_date_epoch="$(git -C "${DOCS_ROOT}" show -s --format=%ct "${docs_commit}")"
(
  cd "${DOCS_ROOT}"
  SOURCE_DATE_EPOCH="${source_date_epoch}" \
    node scripts/build.mjs \
      --deployment tests/fixtures/deployment.json \
      --out "${scratch}/build"
)
release="${scratch}/build/${docs_commit}"
[[ -s "${release}/manifest.json" && -s "${release}/search-index.json" ]]

handler_output="${scratch}/handler.out"
(
  cd "${HANDLER_ROOT}"
  DOCS_SMOKE_RELEASE="${release}" \
    go test -v ./internal/app -run '^TestDocsPortalSmokeFromRelease$' -count=1
) | tee "${handler_output}"
grep -Fq 'docs portal release smoke passed' "${handler_output}"

(
  cd "${HANDLER_ROOT}"
  go test ./internal/app -run '^TestDocsFilterManifestSearchDocumentsAndAssetsByUser$' -count=1
)

(
  cd "${FRONTEND_ROOT}"
  npm run test:docs
  npm run build
)

printf '%s\n' "document portal smoke passed: ${docs_commit}"
