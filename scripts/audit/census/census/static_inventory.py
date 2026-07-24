from dataclasses import asdict, dataclass
from pathlib import Path
import os
import re

from .writer import append_jsonl, write_json


@dataclass(frozen=True)
class InventoryRecord:
    kind: str
    repo: str
    name: str
    file: str
    line: int
    evidence: str


HTTP_PATTERNS = [
    re.compile(r'\b(?:HandleFunc|Handle)\s*\(\s*"([^"]+)"'),
    re.compile(r'\b(?:GET|POST|PUT|DELETE|PATCH|OPTIONS|HEAD)\s*\(\s*"([^"]+)"'),
    re.compile(r'\b(?:router|r|api|engine)\.(?:GET|POST|PUT|DELETE|PATCH|OPTIONS|HEAD|Handle)\s*\(\s*"([^"]+)"'),
]
API_LITERAL_PATTERN = re.compile(r'["`](/api/[A-Za-z0-9_./:{}?=&-]+)["`]')
KAFKA_PATTERN = re.compile(r'["`]([A-Za-z0-9_.-]*(?:topic|events|logs|market|notification)[A-Za-z0-9_.-]*)["`]')
MAKE_PATTERN = re.compile(r'^([A-Za-z0-9_.-]+):(?:\s|$)')
GRPC_SERVICE_PATTERN = re.compile(r'^\s*service\s+([A-Za-z0-9_]+)\s*\{')
GRPC_RPC_PATTERN = re.compile(r'^\s*rpc\s+([A-Za-z0-9_]+)\s*\(')
FRONTEND_ROUTE_PATTERN = re.compile(r'\bpath\s*:\s*["`]([^"`]+)["`]|<Route\s+[^>]*path=["`]([^"`]+)["`]')
ARGPARSE_PATTERN = re.compile(r'\badd_parser\s*\(\s*["`]([^"`]+)["`]')
CLICK_PATTERN = re.compile(r'@\w+\.command\s*\(\s*(?:name\s*=\s*)?["`]([^"`]+)["`]')

SKIP_DIRS = {
    ".git",
    ".idea",
    ".cache",
    ".pytest_cache",
    ".venv",
    "venv",
    "__pycache__",
    "node_modules",
    "dist",
    "build",
    "logs",
    "coverage",
    "census-runs",
    ".audit-build",
}
SOURCE_SUFFIXES = {".go", ".proto", ".ts", ".tsx", ".js", ".jsx", ".py", ".sh", ".sql", ".yaml", ".yml", ".mk"}


def collect_static_inventory(ctx, cfg) -> list[dict]:
    records: list[InventoryRecord] = []
    for service in cfg.services:
        repo_root = ctx.workspace / service["path"]
        if not repo_root.exists():
            continue
        records.extend(scan_repo(ctx.workspace, service, repo_root))
    data = [asdict(record) for record in records]
    write_json(ctx.run_dir / "inventory/static-entrypoints.json", data)
    for item in data:
        append_jsonl(ctx.run_dir / "evidence/static-entrypoints.jsonl", item)
    return data


def scan_repo(workspace: Path, service: dict, repo_root: Path) -> list[InventoryRecord]:
    repo_name = service["name"]
    records: list[InventoryRecord] = []
    for path in iter_source_files(repo_root):
        records.extend(scan_file_for_patterns(workspace, repo_name, path))
    return records


def iter_source_files(root: Path):
    for current, dirs, files in os.walk(root):
        dirs[:] = [d for d in dirs if d not in SKIP_DIRS]
        current_path = Path(current)
        for filename in files:
            path = current_path / filename
            if filename == "Makefile" or path.suffix in SOURCE_SUFFIXES or os.access(path, os.X_OK):
                yield path


def scan_file_for_patterns(workspace: Path, repo: str, path: Path) -> list[InventoryRecord]:
    try:
        text = path.read_text(encoding="utf-8", errors="ignore")
    except OSError:
        return []
    rel = _relative(workspace, path)
    records: list[InventoryRecord] = []
    is_makefile = path.name == "Makefile" or path.suffix == ".mk"
    is_shell = path.suffix == ".sh" or text.startswith("#!/usr/bin/env bash") or text.startswith("#!/bin/bash")
    if is_shell:
        records.append(InventoryRecord("script_file", repo, rel, rel, 1, "executable_or_shell_script"))
    for line_no, line in enumerate(text.splitlines(), start=1):
        if path.suffix == ".proto":
            _add_match(records, GRPC_SERVICE_PATTERN, line, "grpc_service", repo, rel, line_no)
            _add_match(records, GRPC_RPC_PATTERN, line, "grpc_rpc", repo, rel, line_no)
        if path.suffix in {".go", ".py", ".ts", ".tsx", ".js", ".jsx"}:
            for pattern in HTTP_PATTERNS:
                _add_match(records, pattern, line, "http_route", repo, rel, line_no)
            _add_match(records, API_LITERAL_PATTERN, line, "frontend_api", repo, rel, line_no)
            _add_match(records, KAFKA_PATTERN, line, "kafka_topic", repo, rel, line_no)
        if path.suffix in {".ts", ".tsx", ".js", ".jsx"}:
            for match in FRONTEND_ROUTE_PATTERN.finditer(line):
                name = next(group for group in match.groups() if group)
                records.append(InventoryRecord("frontend_route", repo, name, rel, line_no, line.strip()))
        if path.suffix == ".py":
            _add_match(records, ARGPARSE_PATTERN, line, "python_cli", repo, rel, line_no)
            _add_match(records, CLICK_PATTERN, line, "python_cli", repo, rel, line_no)
        if is_makefile:
            _add_match(records, MAKE_PATTERN, line, "make_target", repo, rel, line_no)
        if path.suffix == ".go" and ("go func" in line or "time.NewTicker" in line or "for {" in line):
            records.append(InventoryRecord("background_worker_hint", repo, f"{rel}:{line_no}", rel, line_no, line.strip()))
        if path.suffix == ".py" and ("while True" in line or "asyncio.create_task" in line):
            records.append(InventoryRecord("background_worker_hint", repo, f"{rel}:{line_no}", rel, line_no, line.strip()))
    return dedupe_records(records)


def _add_match(records: list[InventoryRecord], pattern: re.Pattern, line: str, kind: str, repo: str, rel: str, line_no: int) -> None:
    for match in pattern.finditer(line):
        name = match.group(1)
        if name:
            records.append(InventoryRecord(kind, repo, name, rel, line_no, line.strip()))


def _relative(workspace: Path, path: Path) -> str:
    try:
        return str(path.relative_to(workspace))
    except ValueError:
        return str(path)


def dedupe_records(records: list[InventoryRecord]) -> list[InventoryRecord]:
    seen = set()
    result = []
    for record in records:
        key = (record.kind, record.repo, record.name, record.file, record.line)
        if key not in seen:
            seen.add(key)
            result.append(record)
    return result
