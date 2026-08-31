#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import re
import subprocess
import tempfile


REPOSITORIES = {
    "hushine-deploy": ("hushine-deploy", "."),
    "hushine-docs": ("hushine-docs",),
    "core-service": ("core-service",),
    "control-panel-service": ("control-panel-service",),
    "quant-handler": ("gateway/quant-handler",),
    "quant-frontend": ("gateway/quant-frontend",),
    "scraper": ("scraper",),
    "strategy-service": ("strategy-service",),
    "strategy-library": ("strategy-library",),
    "golang-lib": ("golang-lib",),
}
COMMIT_RE = re.compile(r"^[a-f0-9]{40}$")
DIGEST_RE = re.compile(r"^sha256:[a-f0-9]{64}$")
NAME_RE = re.compile(r"^[a-z0-9][a-z0-9._/-]*$")


def _git(repository: Path, *arguments: str) -> str:
    result = subprocess.run(
        ["git", "-C", str(repository), *arguments],
        check=False,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    if result.returncode != 0:
        detail = result.stderr.strip() or result.stdout.strip() or "git command failed"
        raise RuntimeError(f"{repository}: {detail}")
    return result.stdout.strip()


def _repository_path(source_root: Path, name: str, candidates: tuple[str, ...]) -> Path:
    for relative in candidates:
        candidate = (source_root / relative).resolve()
        if candidate.is_dir() and (candidate / ".git").exists():
            return candidate
    raise RuntimeError(f"missing repository: {name}")


def _repository_fact(source_root: Path, name: str, candidates: tuple[str, ...], allow_dirty: bool) -> dict[str, str]:
    repository = _repository_path(source_root, name, candidates)
    commit = _git(repository, "rev-parse", "HEAD")
    if not COMMIT_RE.fullmatch(commit):
        raise RuntimeError(f"invalid Git commit for repository: {name}")
    if not allow_dirty and _git(repository, "status", "--porcelain", "--untracked-files=all"):
        raise RuntimeError(f"dirty repository: {name}")
    return {"name": name, "commit": commit}


def _image_facts(raw: str) -> list[dict[str, str]]:
    try:
        value = json.loads(raw)
    except json.JSONDecodeError as exc:
        raise RuntimeError("DOCS_IMAGE_DIGESTS_JSON must be valid JSON") from exc
    if not isinstance(value, list):
        raise RuntimeError("DOCS_IMAGE_DIGESTS_JSON must be an array")
    images: list[dict[str, str]] = []
    names: set[str] = set()
    for index, item in enumerate(value):
        if not isinstance(item, dict) or set(item) != {"name", "digest"}:
            raise RuntimeError(f"image[{index}] must contain exactly name and digest")
        name = item["name"]
        digest = item["digest"]
        if not isinstance(name, str) or not NAME_RE.fullmatch(name):
            raise RuntimeError(f"image[{index}] has invalid name")
        if name in names:
            raise RuntimeError(f"duplicate image name: {name}")
        if not isinstance(digest, str) or not DIGEST_RE.fullmatch(digest):
            raise RuntimeError(f"image[{index}] has invalid sha256 digest")
        names.add(name)
        images.append({"name": name, "digest": digest})
    return sorted(images, key=lambda item: item["name"])


def build_manifest(source_root: Path, allow_dirty: bool, images_json: str) -> dict[str, object]:
    repositories = [
        _repository_fact(source_root, name, REPOSITORIES[name], allow_dirty)
        for name in sorted(REPOSITORIES)
    ]
    return {
        "schema_version": 1,
        "repositories": repositories,
        "images": _image_facts(images_json),
    }


def _write_atomic(output: Path, value: dict[str, object]) -> None:
    output.parent.mkdir(parents=True, exist_ok=True)
    descriptor, temporary_name = tempfile.mkstemp(prefix=f".{output.name}.", dir=output.parent)
    temporary = Path(temporary_name)
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8", newline="\n") as handle:
            json.dump(value, handle, indent=2, ensure_ascii=False)
            handle.write("\n")
            handle.flush()
            os.fsync(handle.fileno())
        temporary.replace(output)
    finally:
        temporary.unlink(missing_ok=True)


def main() -> int:
    parser = argparse.ArgumentParser(description="Build exact Hushine deployment metadata for a document release")
    parser.add_argument("--source-root", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    arguments = parser.parse_args()
    source_root = arguments.source_root.expanduser().resolve()
    allow_dirty = os.environ.get("ALLOW_DIRTY_DOCS_RELEASE", "").strip().lower() == "true"
    images_json = os.environ.get("DOCS_IMAGE_DIGESTS_JSON", "[]")
    try:
        manifest = build_manifest(source_root, allow_dirty, images_json)
        _write_atomic(arguments.output.expanduser().resolve(), manifest)
    except (OSError, RuntimeError) as exc:
        parser.exit(1, f"{exc}\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
