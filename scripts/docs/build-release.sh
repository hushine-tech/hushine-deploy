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
SOURCE_INDEXER="${DEPLOY_ROOT}/scripts/docs/source-index.py"

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
staging_root="${scratch}/docs-build"
(
  cd "${DOCS_ROOT}"
  SOURCE_DATE_EPOCH="${source_date_epoch}" \
    "${NODE_BIN}" scripts/build.mjs \
      --deployment "${deployment}" \
      --out "${staging_root}"
)

staged_release="${staging_root}/${docs_commit}"
python3 "${SOURCE_INDEXER}" \
  --source-root "${SOURCE_ROOT}" \
  --deployment "${deployment}" \
  --output "${staged_release}/source-index.json"
python3 - "${staged_release}" <<'PY'
from __future__ import annotations

import hashlib
import json
from pathlib import Path
import sys
import tempfile

release = Path(sys.argv[1])
manifest_path = release / "manifest.json"
source_index_path = release / "source-index.json"
manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
source_index = json.loads(source_index_path.read_text(encoding="utf-8"))
if source_index.get("schema_version") != 1:
    raise SystemExit("source index must use schema_version 1")
manifest["source_index_schema_version"] = 1
manifest["source_index_sha256"] = hashlib.sha256(source_index_path.read_bytes()).hexdigest()
with tempfile.NamedTemporaryFile(
    mode="w", encoding="utf-8", newline="\n", dir=release, delete=False
) as handle:
    json.dump(manifest, handle, ensure_ascii=False, indent=2)
    handle.write("\n")
    temporary = Path(handle.name)
temporary.replace(manifest_path)
PY

[[ -s "${staged_release}/manifest.json" \
   && -s "${staged_release}/search-index.json" \
   && -s "${staged_release}/source-index.json" ]] || {
  echo "document builder did not produce a complete release: ${staged_release}" >&2
  exit 1
}

mkdir -p "${BUILD_ROOT}"
release="${BUILD_ROOT}/${docs_commit}"
if [[ -e "${release}" ]]; then
  if ! diff -qr "${staged_release}" "${release}" >/dev/null; then
    echo "release already exists with different contents: ${release}" >&2
    exit 1
  fi
else
  temporary="${BUILD_ROOT}/.${docs_commit}.tmp.$$"
  rm -rf -- "${temporary}"
  cp -R "${staged_release}" "${temporary}"
  mv -- "${temporary}" "${release}"
fi
printf '%s\n' "${release}"
