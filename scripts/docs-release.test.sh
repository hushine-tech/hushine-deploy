#!/usr/bin/env bash
set -euo pipefail

DEPLOY_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
SOURCE_ROOT="$(cd -- "${DEPLOY_ROOT}/.." && pwd -P)"
GENERATOR="${DEPLOY_ROOT}/scripts/docs/deployment-manifest.py"
BUILDER="${DEPLOY_ROOT}/scripts/docs/build-release.sh"
PUBLISHER="${DEPLOY_ROOT}/scripts/docs/publish-release.sh"
DOCS_SOURCE="${SOURCE_ROOT}/hushine-docs"

fixture="$(mktemp -d "${TMPDIR:-/tmp}/hushine-docs-release.XXXXXX")"
cleanup() {
  rm -rf -- "${fixture}"
}
trap cleanup EXIT HUP INT TERM

source_root="${fixture}/source"
mkdir -p "${source_root}"

init_repo() {
  local relative="$1"
  local repository="${source_root}/${relative}"
  mkdir -p "${repository}"
  git -C "${repository}" init -b main >/dev/null
  printf '%s\n' "${relative}" > "${repository}/marker.txt"
  git -C "${repository}" add marker.txt
  git -C "${repository}" \
    -c user.name='Hushine Docs Test' \
    -c user.email='docs-test@invalid' \
    commit -m fixture >/dev/null
}

for repository in \
  hushine-deploy \
  core-service \
  control-panel-service \
  gateway/quant-handler \
  gateway/quant-frontend \
  scraper \
  strategy-service \
  strategy-library \
  golang-lib; do
  init_repo "${repository}"
done

[[ -d "${DOCS_SOURCE}/.git" ]] || {
  echo "hushine-docs fixture source must be a Git repository" >&2
  exit 1
}
git clone --quiet "${DOCS_SOURCE}" "${source_root}/hushine-docs"

digest="sha256:$(printf '2%.0s' {1..64})"
images="[{\"name\":\"strategy-runtime\",\"digest\":\"${digest}\"}]"
manifest="${fixture}/deployment.json"

DOCS_IMAGE_DIGESTS_JSON="${images}" \
  python3 "${GENERATOR}" --source-root "${source_root}" --output "${manifest}"

python3 - "${source_root}" "${manifest}" "${digest}" <<'PY'
import json
from pathlib import Path
import subprocess
import sys

root = Path(sys.argv[1])
manifest = json.loads(Path(sys.argv[2]).read_text())
digest = sys.argv[3]
expected_paths = {
    "hushine-deploy": "hushine-deploy",
    "hushine-docs": "hushine-docs",
    "core-service": "core-service",
    "control-panel-service": "control-panel-service",
    "quant-handler": "gateway/quant-handler",
    "quant-frontend": "gateway/quant-frontend",
    "scraper": "scraper",
    "strategy-service": "strategy-service",
    "strategy-library": "strategy-library",
    "golang-lib": "golang-lib",
}
assert manifest["schema_version"] == 1
assert [item["name"] for item in manifest["repositories"]] == sorted(expected_paths)
for item in manifest["repositories"]:
    expected = subprocess.check_output(
        ["git", "-C", str(root / expected_paths[item["name"]]), "rev-parse", "HEAD"],
        text=True,
    ).strip()
    assert item["commit"] == expected
assert manifest["images"] == [{"name": "strategy-runtime", "digest": digest}]
assert set(manifest) == {"schema_version", "repositories", "images"}
PY

printf '%s\n' dirty >> "${source_root}/core-service/marker.txt"
if DOCS_IMAGE_DIGESTS_JSON="${images}" \
  python3 "${GENERATOR}" --source-root "${source_root}" --output "${fixture}/dirty.json" \
  >"${fixture}/dirty.stdout" 2>"${fixture}/dirty.stderr"; then
  echo "deployment manifest accepted a dirty repository" >&2
  exit 1
fi
grep -Fq 'dirty repository: core-service' "${fixture}/dirty.stderr"

ALLOW_DIRTY_DOCS_RELEASE=true DOCS_IMAGE_DIGESTS_JSON="${images}" \
  python3 "${GENERATOR}" --source-root "${source_root}" --output "${fixture}/allowed-dirty.json"
git -C "${source_root}/core-service" add marker.txt
git -C "${source_root}/core-service" \
  -c user.name='Hushine Docs Test' \
  -c user.email='docs-test@invalid' \
  commit -m 'clean fixture' >/dev/null

if HUSHINE_SOURCE_ROOT="${source_root}" \
  HUSHINE_DOCS_ROOT="${source_root}/missing-docs" \
  DOCS_BUILD_ROOT="${fixture}/missing-build" \
  DOCS_IMAGE_DIGESTS_JSON="${images}" \
  bash "${BUILDER}" >"${fixture}/missing.stdout" 2>"${fixture}/missing.stderr"; then
  echo "document build accepted a missing hushine-docs repository" >&2
  exit 1
fi
grep -Fq 'missing hushine-docs repository' "${fixture}/missing.stderr"

build_root="${fixture}/build"
HUSHINE_SOURCE_ROOT="${source_root}" \
HUSHINE_DOCS_ROOT="${source_root}/hushine-docs" \
DOCS_BUILD_ROOT="${build_root}" \
DOCS_IMAGE_DIGESTS_JSON="${images}" \
  bash "${BUILDER}" > "${fixture}/build.path"

release="$(tail -1 "${fixture}/build.path")"
docs_commit="$(git -C "${source_root}/hushine-docs" rev-parse HEAD)"
[[ "${release}" == "${build_root}/${docs_commit}" ]]
[[ -s "${release}/manifest.json" ]]
[[ -s "${release}/search-index.json" ]]
[[ -s "${release}/source-index.json" ]]

python3 - "${release}" <<'PY'
import hashlib
import json
from pathlib import Path
import sys

release = Path(sys.argv[1])
manifest = json.loads((release / "manifest.json").read_text(encoding="utf-8"))
source_index_path = release / "source-index.json"
source_index = json.loads(source_index_path.read_text(encoding="utf-8"))
assert manifest["source_index_schema_version"] == 1
assert manifest["source_index_sha256"] == hashlib.sha256(source_index_path.read_bytes()).hexdigest()
assert source_index["schema_version"] == 1
assert source_index["chunks"] == sorted(
    source_index["chunks"],
    key=lambda chunk: (chunk["repository"], chunk["path"], chunk["start_line"]),
)
PY

publish_root="${fixture}/published"
DOCS_RELEASE_DIR="${release}" DOCS_PUBLISH_ROOT="${publish_root}" \
  bash "${PUBLISHER}"
[[ "$(readlink "${publish_root}/current")" == "releases/${docs_commit}" ]]
first_target="$(readlink "${publish_root}/current")"

# Re-publishing must replace the current symlink itself, including on macOS
# where mv without -h follows a destination symlink to a directory.
git -C "${source_root}/hushine-docs" -c user.name='Hushine Docs Test' \
  -c user.email='docs-test@invalid' commit --allow-empty -m 'second release' >/dev/null
second_commit="$(git -C "${source_root}/hushine-docs" rev-parse HEAD)"
HUSHINE_SOURCE_ROOT="${source_root}" HUSHINE_DOCS_ROOT="${source_root}/hushine-docs" \
  DOCS_BUILD_ROOT="${build_root}" DOCS_IMAGE_DIGESTS_JSON="${images}" \
  bash "${BUILDER}" >"${fixture}/second-build.path"
DOCS_RELEASE_DIR="${build_root}/${second_commit}" DOCS_PUBLISH_ROOT="${publish_root}" \
  bash "${PUBLISHER}"
if [[ "$(readlink "${publish_root}/current")" != "releases/${second_commit}" ]]; then
  echo "publisher did not replace current symlink on second release" >&2
  exit 1
fi
first_target="$(readlink "${publish_root}/current")"

cp "${release}/source-index.json" "${fixture}/source-index.json"
printf '%s\n' tampered >> "${release}/source-index.json"
if DOCS_RELEASE_DIR="${release}" DOCS_PUBLISH_ROOT="${publish_root}" \
  bash "${PUBLISHER}" >"${fixture}/tampered-source.stdout" 2>"${fixture}/tampered-source.stderr"; then
  echo "publisher accepted a source-index checksum mismatch" >&2
  exit 1
fi
grep -Fq 'checksum mismatch: source-index.json' "${fixture}/tampered-source.stderr"
mv "${fixture}/source-index.json" "${release}/source-index.json"

first_document="$(python3 - "${release}/manifest.json" <<'PY'
import json
from pathlib import Path
import sys
manifest = json.loads(Path(sys.argv[1]).read_text())
print(manifest["documents"][0]["path"])
PY
)"
printf '%s\n' tampered >> "${release}/${first_document}"
if DOCS_RELEASE_DIR="${release}" DOCS_PUBLISH_ROOT="${publish_root}" \
  bash "${PUBLISHER}" >"${fixture}/tampered.stdout" 2>"${fixture}/tampered.stderr"; then
  echo "publisher accepted a checksum mismatch" >&2
  exit 1
fi
grep -Fq 'checksum mismatch' "${fixture}/tampered.stderr"
[[ "$(readlink "${publish_root}/current")" == "${first_target}" ]]

printf '%s\n' 'document release contract passed'
