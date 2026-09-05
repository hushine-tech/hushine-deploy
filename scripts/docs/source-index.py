#!/usr/bin/env python3
from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import posixpath
import re
import subprocess
import tempfile
from typing import Iterable


ALLOWED_SUFFIXES = {
    ".go": "go",
    ".proto": "proto",
    ".py": "python",
    ".ts": "typescript",
    ".tsx": "typescript",
    ".sql": "sql",
    ".yaml": "yaml",
    ".yml": "yaml",
    ".md": "markdown",
}
REPOSITORY_PATHS = {
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
ALLOWED_REPOSITORY_SYMLINKS = {
    ("strategy-service", "strategy-library"): ("../strategy-library", "strategy-library"),
}
COMMIT_RE = re.compile(r"^[a-f0-9]{40}$")
EXCLUDED_DIRECTORIES = {
    ".git",
    ".venv",
    "venv",
    "node_modules",
    "vendor",
    "dist",
    "build",
    "generated",
    "gen",
    "logs",
    "log",
    "coverage",
    ".coverage",
    "user-strategies",
    "user_strategies",
    "strategy-uploads",
    "strategy_uploads",
}
SECRET_SUFFIXES = {".pem", ".key", ".crt", ".cer", ".p12", ".pfx"}
GENERATED_NAMES = (
    re.compile(r"\.pb\.go$", re.IGNORECASE),
    re.compile(r"_pb2(?:_grpc)?\.py$", re.IGNORECASE),
    re.compile(r"(?:^|\.)generated\.[^.]+$", re.IGNORECASE),
)
SYMBOL_PATTERNS = {
    "go": (
        re.compile(r"^\s*func\s+(?:\([^)]*\)\s*)?([A-Za-z_]\w*)", re.MULTILINE),
        re.compile(r"^\s*type\s+([A-Za-z_]\w*)", re.MULTILINE),
    ),
    "python": (
        re.compile(r"^\s*(?:async\s+)?def\s+([A-Za-z_]\w*)", re.MULTILINE),
        re.compile(r"^\s*class\s+([A-Za-z_]\w*)", re.MULTILINE),
    ),
    "typescript": (
        re.compile(
            r"^\s*(?:export\s+)?(?:default\s+)?(?:async\s+)?"
            r"(?:function|class|interface|type|enum|const)\s+([A-Za-z_$][\w$]*)",
            re.MULTILINE,
        ),
    ),
    "proto": (
        re.compile(r"^\s*(?:message|service|enum|rpc)\s+([A-Za-z_]\w*)", re.MULTILINE),
    ),
}


class IndexError(RuntimeError):
    pass


def git(repository: Path, *arguments: str, binary: bool = False) -> str | bytes:
    result = subprocess.run(
        ["git", "-C", str(repository), *arguments],
        check=False,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=not binary,
    )
    if result.returncode != 0:
        stderr = result.stderr.decode("utf-8", "replace") if binary else result.stderr
        stdout = result.stdout.decode("utf-8", "replace") if binary else result.stdout
        detail = (stderr or stdout).strip() or "git command failed"
        raise IndexError(f"{repository}: {detail}")
    return result.stdout


def repository_path(source_root: Path, name: str) -> Path:
    candidates = REPOSITORY_PATHS.get(name)
    if candidates is None:
        raise IndexError(f"unsupported deployment repository: {name}")
    for relative in candidates:
        candidate = (source_root / relative).resolve()
        if candidate.is_dir():
            try:
                inside = str(git(candidate, "rev-parse", "--is-inside-work-tree")).strip()
            except IndexError:
                continue
            if inside == "true":
                return candidate
    raise IndexError(f"missing repository: {name}")


def parse_deployment(raw: bytes) -> list[dict[str, str]]:
    try:
        value = json.loads(raw)
    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise IndexError("deployment manifest must be valid UTF-8 JSON") from exc
    if not isinstance(value, dict) or value.get("schema_version") != 1:
        raise IndexError("deployment manifest must use schema_version 1")
    repositories = value.get("repositories")
    if not isinstance(repositories, list):
        raise IndexError("deployment manifest repositories must be an array")
    parsed: list[dict[str, str]] = []
    names: set[str] = set()
    for index, item in enumerate(repositories):
        if not isinstance(item, dict) or set(item) != {"name", "commit"}:
            raise IndexError(f"deployment repository[{index}] must contain exactly name and commit")
        name, commit = item.get("name"), item.get("commit")
        if not isinstance(name, str) or name not in REPOSITORY_PATHS:
            raise IndexError(f"deployment repository[{index}] has unsupported name")
        if name in names:
            raise IndexError(f"duplicate deployment repository: {name}")
        if not isinstance(commit, str) or COMMIT_RE.fullmatch(commit) is None:
            raise IndexError(f"deployment repository[{index}] has invalid commit")
        names.add(name)
        parsed.append({"name": name, "commit": commit})
    return sorted(parsed, key=lambda item: item["name"])


def tracked_entries(repository: Path, commit: str) -> Iterable[tuple[str, str, str]]:
    git(repository, "cat-file", "-e", f"{commit}^{{commit}}")
    raw = bytes(git(repository, "ls-tree", "-r", "-z", "--full-tree", commit, binary=True))
    for entry in raw.split(b"\0"):
        if not entry:
            continue
        try:
            metadata, raw_path = entry.split(b"\t", 1)
            mode, object_type, _object_id = metadata.decode("ascii").split(" ", 2)
            path = raw_path.decode("utf-8")
        except (ValueError, UnicodeDecodeError) as exc:
            raise IndexError("repository contains an invalid Git tree entry") from exc
        yield mode, object_type, path


def validate_symlink(
    repository: Path,
    repository_name: str,
    deployed_repositories: set[str],
    commit: str,
    path: str,
) -> None:
    raw_target = bytes(git(repository, "show", f"{commit}:{path}", binary=True))
    try:
        target = raw_target.decode("utf-8")
    except UnicodeDecodeError as exc:
        raise IndexError(f"invalid symlink target: {path}") from exc
    if target.startswith("/"):
        raise IndexError(f"symlink leaves repository: {path}")
    normalized = posixpath.normpath(posixpath.join(posixpath.dirname(path), target))
    if normalized == ".." or normalized.startswith("../"):
        allowed = ALLOWED_REPOSITORY_SYMLINKS.get((repository_name, path))
        if allowed is not None and target == allowed[0] and allowed[1] in deployed_repositories:
            return
        raise IndexError(f"symlink leaves repository: {path}")


def is_allowed_path(path: str) -> bool:
    pure = PurePosixPath(path)
    lowered_parts = tuple(part.lower() for part in pure.parts)
    name = pure.name.lower()
    if any(part in EXCLUDED_DIRECTORIES for part in lowered_parts[:-1]):
        return False
    if name == ".env" or name.startswith(".env."):
        return False
    if pure.suffix.lower() in SECRET_SUFFIXES:
        return False
    if name.endswith((".local.yaml", ".local.yml", ".override.yaml", ".override.yml")):
        return False
    if any(pattern.search(name) for pattern in GENERATED_NAMES):
        return False
    if any(part in {"secret", "secrets"} for part in lowered_parts) and any(
        part in {"fixture", "fixtures", "testdata"} for part in lowered_parts
    ):
        return False
    return pure.suffix.lower() in ALLOWED_SUFFIXES


def chunk_ranges(lines: list[str]) -> Iterable[tuple[int, int]]:
    start = 0
    total = len(lines)
    while start < total:
        if total - start <= 180:
            end = total
        else:
            target = min(start + 120, total)
            hard_end = min(start + 180, total)
            after = next(
                (index + 1 for index in range(target - 1, hard_end) if not lines[index].strip()),
                None,
            )
            if after is not None:
                end = after
            else:
                before = next(
                    (
                        index + 1
                        for index in range(target - 2, start + 59, -1)
                        if not lines[index].strip()
                    ),
                    None,
                )
                end = before or hard_end
        yield start, end
        if end >= total:
            break
        start = max(start + 1, end - 12)


def symbols(language: str, text: str) -> list[str]:
    found = {
        match.group(1)
        for pattern in SYMBOL_PATTERNS.get(language, ())
        for match in pattern.finditer(text)
    }
    return sorted(found)


def chunks_for_file(repository_name: str, commit: str, path: str, content: bytes) -> list[dict[str, object]]:
    if b"\0" in content or len(content) > 2 * 1024 * 1024:
        return []
    try:
        decoded = content.decode("utf-8")
    except UnicodeDecodeError:
        return []
    lines = decoded.splitlines()
    if not lines:
        return []
    language = ALLOWED_SUFFIXES[PurePosixPath(path).suffix.lower()]
    chunks: list[dict[str, object]] = []
    for start, end in chunk_ranges(lines):
        text = "\n".join(lines[start:end])
        if not text.strip():
            continue
        identity = f"{repository_name}\0{path}\0{start + 1}\0{end}".encode()
        chunks.append(
            {
                "id": hashlib.sha256(identity).hexdigest(),
                "repository": repository_name,
                "commit": commit,
                "path": path,
                "start_line": start + 1,
                "end_line": end,
                "language": language,
                "symbols": symbols(language, text),
                "text": text,
                "sha256": hashlib.sha256(text.encode("utf-8")).hexdigest(),
            }
        )
    return chunks


def build_index(source_root: Path, deployment_file: Path) -> dict[str, object]:
    deployment_raw = deployment_file.read_bytes()
    repositories = parse_deployment(deployment_raw)
    deployed_repositories = {fact["name"] for fact in repositories}
    chunks: list[dict[str, object]] = []
    for fact in repositories:
        name, commit = fact["name"], fact["commit"]
        repository = repository_path(source_root, name)
        for mode, object_type, path in tracked_entries(repository, commit):
            if mode == "120000":
                validate_symlink(repository, name, deployed_repositories, commit, path)
                continue
            if object_type != "blob" or not is_allowed_path(path):
                continue
            content = bytes(git(repository, "show", f"{commit}:{path}", binary=True))
            chunks.extend(chunks_for_file(name, commit, path, content))
    chunks.sort(key=lambda chunk: (chunk["repository"], chunk["path"], chunk["start_line"]))
    return {
        "schema_version": 1,
        "deployment_digest": hashlib.sha256(deployment_raw).hexdigest(),
        "chunks": chunks,
    }


def write_atomic(output: Path, value: dict[str, object]) -> None:
    output.parent.mkdir(parents=True, exist_ok=True)
    descriptor, temporary_name = tempfile.mkstemp(prefix=f".{output.name}.", dir=output.parent)
    temporary = Path(temporary_name)
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8", newline="\n") as handle:
            json.dump(value, handle, ensure_ascii=False, indent=2, sort_keys=True)
            handle.write("\n")
            handle.flush()
            os.fsync(handle.fileno())
        temporary.replace(output)
    finally:
        temporary.unlink(missing_ok=True)


def main() -> int:
    parser = argparse.ArgumentParser(description="Build a commit-pinned Hushine source index")
    parser.add_argument("--source-root", required=True, type=Path)
    parser.add_argument("--deployment", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    arguments = parser.parse_args()
    try:
        value = build_index(
            arguments.source_root.expanduser().resolve(),
            arguments.deployment.expanduser().resolve(),
        )
        write_atomic(arguments.output.expanduser().resolve(), value)
    except (IndexError, OSError) as exc:
        parser.exit(1, f"{exc}\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
