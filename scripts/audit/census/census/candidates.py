from fnmatch import fnmatch
from pathlib import Path

import yaml

from .writer import append_jsonl, read_json, read_jsonl, write_json


BUCKETS = ["active", "cold-valid", "suspicious-legacy", "delete-candidate", "never-delete-by-coverage", "unknown"]


def evidence_record(kind: str, subject: str, source: str, confidence: str, details: dict) -> dict:
    return {
        "kind": kind,
        "subject": subject,
        "source": source,
        "confidence": confidence,
        "details": details,
    }


def classify_candidates(ctx, cfg, static_only: bool) -> dict:
    config_path = getattr(cfg, "config_path", None)
    overrides = load_overrides(
        Path(config_path).parent / "overrides.yaml"
        if config_path is not None
        else ctx.workspace / "scripts/audit/census/overrides.yaml"
    )
    subjects: dict[str, dict] = {}
    add_static_inventory_subjects(subjects, ctx)
    add_reachability_subjects(subjects, ctx)
    add_evidence_subjects(subjects, ctx)

    items = []
    for subject, state in sorted(subjects.items()):
        bucket = decide_bucket(subject, state, static_only)
        bucket, reason = apply_overrides(subject, bucket, overrides)
        item = {
            "subject": subject,
            "bucket": bucket,
            "reason": reason or state.get("reason") or bucket_reason(bucket, static_only),
            "evidence": sorted(state.get("evidence", [])),
            "files": sorted(state.get("files", [])),
        }
        items.append(item)
    classification = {"static_only": static_only, "buckets": bucket_counts(items), "items": items}
    write_json(ctx.run_dir / "candidates/all-candidates.json", classification)
    write_json(ctx.run_dir / "candidates/delete-candidates.json", [item for item in items if item["bucket"] == "delete-candidate"])
    write_json(ctx.run_dir / "candidates/suspicious-legacy.json", [item for item in items if item["bucket"] == "suspicious-legacy"])
    write_json(ctx.run_dir / "candidates/never-delete-by-coverage.json", [item for item in items if item["bucket"] == "never-delete-by-coverage"])
    append_jsonl(ctx.run_dir / "evidence/candidates.jsonl", {"kind": "candidate_summary", "buckets": classification["buckets"]})
    return classification


def load_overrides(path: Path) -> dict:
    if not path.exists():
        return {}
    with path.open("r", encoding="utf-8") as fh:
        return yaml.safe_load(fh) or {}


def add_static_inventory_subjects(subjects: dict[str, dict], ctx) -> None:
    for item in read_json(ctx.run_dir / "inventory/static-entrypoints.json", []):
        subject = f"{item.get('repo', 'unknown')}:{item.get('name') or item.get('file')}"
        state = subjects.setdefault(subject, {"evidence": set(), "files": set()})
        state["evidence"].add("static-entrypoint")
        if item.get("file"):
            state["files"].add(item["file"])


def add_reachability_subjects(subjects: dict[str, dict], ctx) -> None:
    reachability = read_json(ctx.run_dir / "reachability/static-references.json", {})
    for rel in reachability.get("unreferenced_files", []):
        state = subjects.setdefault(rel, {"evidence": set(), "files": set()})
        state["evidence"].add("unreferenced-static")
        state["files"].add(rel)
    for rel in reachability.get("naming_suspicions", []):
        state = subjects.setdefault(rel, {"evidence": set(), "files": set()})
        state["evidence"].add("legacy-like-name")
        state["files"].add(rel)


def add_evidence_subjects(subjects: dict[str, dict], ctx) -> None:
    for path in [ctx.run_dir / "evidence/observability.jsonl", ctx.run_dir / "evidence/coverage.jsonl"]:
        for item in read_jsonl(path):
            subject = item.get("subject") or item.get("service") or item.get("kind")
            if not subject:
                continue
            details = item.get("details")
            if isinstance(details, dict) and details.get("covered") is False:
                continue
            state = subjects.setdefault(subject, {"evidence": set(), "files": set()})
            evidence = item.get("kind", path.stem)
            state["evidence"].add(evidence)
            state["active"] = True
            covered_file = (
                details.get("file")
                if isinstance(details, dict)
                else None
            )
            if not covered_file:
                continue
            state["files"].add(covered_file)
            file_state = subjects.setdefault(
                covered_file,
                {"evidence": set(), "files": set()},
            )
            file_state["evidence"].add(evidence)
            file_state["files"].add(covered_file)
            file_state["active"] = True
            for candidate in subjects.values():
                if covered_file in candidate.get("files", set()):
                    candidate["evidence"].add(evidence)
                    candidate["active"] = True


def decide_bucket(subject: str, state: dict, static_only: bool) -> str:
    if is_never_delete_path(subject):
        return "never-delete-by-coverage"
    if state.get("active"):
        return "active"
    if static_only:
        return "unknown"
    if "unreferenced-static" in state.get("evidence", set()):
        if legacy_like(subject):
            return "suspicious-legacy"
        return "delete-candidate"
    if legacy_like(subject):
        return "suspicious-legacy"
    if state.get("evidence"):
        return "cold-valid"
    return "unknown"


def apply_overrides(subject: str, default_bucket: str, overrides: dict) -> tuple[str, str | None]:
    for item in overrides.get("classifications", {}).get("never_delete_by_coverage", []):
        pattern = item["path"]
        if path_matches(subject, pattern):
            return "never-delete-by-coverage", item.get("reason")
    return default_bucket, None


def path_matches(subject: str, pattern: str) -> bool:
    normalized = subject.replace("\\", "/")
    pattern = pattern.replace("\\", "/")
    if pattern.endswith("/"):
        prefix = pattern.rstrip("/")
        if pattern.startswith("**/"):
            segment = "/" + prefix[3:] + "/"
            return segment in "/" + normalized
        return normalized == prefix or normalized.startswith(prefix + "/")
    return fnmatch(normalized, pattern)


def is_never_delete_path(subject: str) -> bool:
    lowered = subject.lower()
    protected_tokens = ["/migrations/", "/proto/", "/gen/", "/tests/", "/fixtures/", "db/", "openspec/", "progress/"]
    return any(token in lowered or lowered.startswith(token.strip("/")) for token in protected_tokens)


def legacy_like(subject: str) -> bool:
    lowered = subject.lower()
    return any(token in lowered for token in ["legacy", "deprecated", "/old", "old_", "_old"])


def bucket_reason(bucket: str, static_only: bool) -> str:
    if static_only:
        return "static-only 运行只提供静态证据，不能直接作为删除依据"
    return {
        "active": "存在 observability 或 coverage 动态证据",
        "cold-valid": "存在静态入口或引用，但缺少当前动态证据",
        "suspicious-legacy": "路径或命名显示旧架构痕迹，需要人工复核",
        "delete-candidate": "未发现动态证据、入口通达或保护规则，仍需人工确认",
        "never-delete-by-coverage": "受保护路径不能按覆盖率删除",
        "unknown": "证据不足",
    }.get(bucket, bucket)


def bucket_counts(items: list[dict]) -> dict:
    counts = {bucket: 0 for bucket in BUCKETS}
    for item in items:
        counts[item["bucket"]] = counts.get(item["bucket"], 0) + 1
    return counts
