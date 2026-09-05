#!/usr/bin/env bash
set -euo pipefail

release="${DOCS_RELEASE_DIR:-}"
publish_root="${DOCS_PUBLISH_ROOT:-/var/lib/hushine/docs}"
[[ -n "${release}" && -d "${release}" ]] || {
  echo "DOCS_RELEASE_DIR must name a built document release" >&2
  exit 1
}

verify_release() {
  python3 - "$1" <<'PY'
from __future__ import annotations

import hashlib
import json
from pathlib import Path
import re
import sys

root = Path(sys.argv[1]).resolve()
manifest_path = root / "manifest.json"
try:
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
except (OSError, json.JSONDecodeError) as exc:
    raise SystemExit(f"invalid document release manifest: {exc}")

commit = manifest.get("docs_commit")
if manifest.get("schema_version") != 1 or not isinstance(commit, str) or re.fullmatch(r"[a-f0-9]{40}", commit) is None:
    raise SystemExit("invalid document release identity")

def checked_path(relative: object) -> Path:
    if not isinstance(relative, str) or not relative or Path(relative).is_absolute():
        raise SystemExit(f"invalid release path: {relative}")
    candidate = root / relative
    if candidate.is_symlink():
        raise SystemExit(f"release path must not be a symlink: {relative}")
    resolved = candidate.resolve()
    if root != resolved and root not in resolved.parents:
        raise SystemExit(f"release path leaves root: {relative}")
    if not resolved.is_file():
        raise SystemExit(f"missing release file: {relative}")
    return resolved

def verify_hash(relative: object, expected: object) -> None:
    file = checked_path(relative)
    if not isinstance(expected, str) or re.fullmatch(r"[a-f0-9]{64}", expected) is None:
        raise SystemExit(f"invalid checksum for {relative}")
    actual = hashlib.sha256(file.read_bytes()).hexdigest()
    if actual != expected:
        raise SystemExit(f"checksum mismatch: {relative}")

verify_hash("search-index.json", manifest.get("search_index_sha256"))
if manifest.get("source_index_schema_version") != 1:
    raise SystemExit("invalid source index schema version")
verify_hash("source-index.json", manifest.get("source_index_sha256"))
allowed = {"manifest.json", "search-index.json", "source-index.json"}
for document in manifest.get("documents", []):
    if not isinstance(document, dict):
        raise SystemExit("invalid document manifest entry")
    verify_hash(document.get("path"), document.get("sha256"))
    allowed.add(document["path"])
for asset in manifest.get("assets", []):
    if not isinstance(asset, dict):
        raise SystemExit("invalid asset manifest entry")
    verify_hash(asset.get("path"), asset.get("sha256"))
    allowed.add(asset["path"])

actual = {
    str(item.relative_to(root)).replace("\\", "/")
    for item in root.rglob("*")
    if item.is_file()
}
if actual != allowed:
    extra = sorted(actual - allowed)
    missing = sorted(allowed - actual)
    raise SystemExit(f"release file set mismatch: extra={extra} missing={missing}")
print(commit)
PY
}

docs_commit="$(verify_release "${release}")"
releases_root="${publish_root}/releases"
destination="${releases_root}/${docs_commit}"
temporary="${releases_root}/.${docs_commit}.tmp.$$"
next_link="${publish_root}/.current.next.$$"
mkdir -p "${releases_root}"
rm -rf -- "${temporary}"
rm -f -- "${next_link}"

cleanup() {
  rm -rf -- "${temporary}"
  rm -f -- "${next_link}"
}
trap cleanup EXIT HUP INT TERM

mkdir -p "${temporary}"
cp -R "${release}/." "${temporary}/"
copied_commit="$(verify_release "${temporary}")"
[[ "${copied_commit}" == "${docs_commit}" ]]

if [[ -e "${destination}" ]]; then
  existing_commit="$(verify_release "${destination}")"
  [[ "${existing_commit}" == "${docs_commit}" ]]
  if ! diff -qr "${temporary}" "${destination}" >/dev/null; then
    echo "published release already exists with different contents: ${destination}" >&2
    exit 1
  fi
  rm -rf -- "${temporary}"
else
  mv -- "${temporary}" "${destination}"
fi

ln -s "releases/${docs_commit}" "${next_link}"
python3 - "${next_link}" "${publish_root}/current" <<'PY'
import os
import sys

# Replace the symlink, never follow an existing symlink to its release directory.
os.replace(sys.argv[1], sys.argv[2])
PY
printf '%s\n' "${publish_root}/current"
