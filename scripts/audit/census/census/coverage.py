import json
import math
import os
import re
import shlex
import shutil
import stat
import subprocess
import time
from datetime import datetime
from pathlib import Path
from urllib.parse import unquote, urlsplit

from .writer import append_jsonl, read_json, write_json


HOSTED_RUNTIME_LABEL_PREFIX = "hushine.runtime"
HOSTED_FINALIZATION_WAIT_SECONDS = 2.0
MAX_HOSTED_FINALIZATION_BYTES = 64 * 1024
MAX_FRONTEND_PRECISE_BYTES = 256 * 1024 * 1024
SAFE_COMPONENT = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$")
RFC3339_NANO = re.compile(
    r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{1,9})?(?:Z|[+-]\d{2}:\d{2})$"
)
FINALIZATION_BASE_FIELDS = {
    "schema_version",
    "runtime_id",
    "boot_id",
    "state",
    "worker_shutdown",
    "forced_workers",
    "go_snapshot",
}
HOSTED_RUNTIME_DIRECTORY_OUTPUTS = {
    "go-merged",
}
HOSTED_RUNTIME_FILE_OUTPUTS = {
    "coverage-manifest.json",
    "go.cover.out",
    "go-covdata-merge-output.txt",
    "go-covdata-textfmt-output.txt",
    "go-functions.txt",
    "python-combine-output.txt",
    "python-coverage.json",
    "python-data-validation-output.txt",
    "python-json-output.txt",
    "python-report.coveragerc",
    "python-report.txt",
}


class CoverageCollectionFailed(RuntimeError):
    pass


def collect_unit_coverage(ctx, cfg) -> list[dict]:
    results = []
    for service in cfg.services:
        kind = service.get("kind", "")
        if kind.startswith("go-"):
            results.append(run_go_unit_coverage(ctx, service))
        elif kind.startswith("python-"):
            results.append(run_python_unit_coverage(ctx, service))
        elif kind == "frontend":
            results.append(run_frontend_unit_coverage(ctx, service))
    write_json(ctx.run_dir / "coverage/unit-coverage-summary.json", results)
    for item in results:
        append_jsonl(ctx.run_dir / "evidence/coverage.jsonl", item)
    normalize_dynamic_coverage(ctx, cfg)
    failures = [item for item in results if item.get("exit_code") != 0]
    if failures:
        names = ", ".join(f"{item.get('service')} exit={item.get('exit_code')}" for item in failures)
        raise CoverageCollectionFailed(f"FAILED_COVERAGE: unit coverage failed for {names}")
    return results


def run_go_unit_coverage(ctx, service):
    repo = ctx.workspace / service["path"]
    out = ctx.run_dir / "coverage" / service["name"] / "unit"
    out.mkdir(parents=True, exist_ok=True)
    cover = out / "cover.out"
    cmd = ["go", "test", service.get("go_packages", "./..."), "-covermode=atomic", f"-coverprofile={cover}"]
    proc = subprocess.run(cmd, cwd=repo, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    (out / "test-output.txt").write_text(proc.stdout, encoding="utf-8")
    if cover.exists():
        with (out / "functions.txt").open("w", encoding="utf-8") as fh:
            subprocess.run(["go", "tool", "cover", f"-func={cover}"], cwd=repo, text=True, stdout=fh, stderr=subprocess.STDOUT)
    return {"kind": "go_unit_coverage", "subject": service["name"], "service": service["name"], "exit_code": proc.returncode, "output": str(out.relative_to(ctx.run_dir))}


def run_python_unit_coverage(ctx, service):
    repo = ctx.workspace / service["path"]
    out = ctx.run_dir / "coverage" / service["name"] / "unit"
    out.mkdir(parents=True, exist_ok=True)
    command = service.get("unit_command") or "python3 -m coverage run --parallel-mode -m pytest tests"
    unit_command, assignments = python_unit_coverage_command(command)
    env = os.environ.copy()
    env.update(assignments)
    coverage_file = out / ".coverage"
    env["COVERAGE_FILE"] = str(coverage_file)
    logs = []
    test = subprocess.run(
        unit_command,
        cwd=repo,
        env=env,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
    )
    logs.append(f"$ {shlex.join(unit_command)}\n{test.stdout}")
    exit_code = test.returncode
    coverage_status = "missing"
    coverage_tool = [
        "uv",
        "run",
        "--isolated",
        "--no-project",
        "--with",
        "coverage",
        "coverage",
    ]
    shards = sorted(out.glob(".coverage.*"))
    if shards:
        combine_command = [*coverage_tool, "combine", "--keep", str(out)]
        combine = subprocess.run(
            combine_command,
            cwd=repo,
            env=env,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
        )
        logs.append(f"$ {shlex.join(combine_command)}\n{combine.stdout}")
        if exit_code == 0 and combine.returncode != 0:
            exit_code = combine.returncode
    if coverage_file.is_file():
        report_command = [*coverage_tool, "report", "--ignore-errors", "-m"]
        report = subprocess.run(
            report_command,
            cwd=repo,
            env=env,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
        )
        logs.append(f"$ {shlex.join(report_command)}\n{report.stdout}")
        (out / "functions.txt").write_text(report.stdout, encoding="utf-8")
        json_command = [
            *coverage_tool,
            "json",
            "--ignore-errors",
            "-o",
            str(out / "coverage.json"),
        ]
        json_result = subprocess.run(
            json_command,
            cwd=repo,
            env=env,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
        )
        logs.append(f"$ {shlex.join(json_command)}\n{json_result.stdout}")
        coverage_status = (
            "ok" if report.returncode == 0 and json_result.returncode == 0 else "error"
        )
        if exit_code == 0 and report.returncode != 0:
            exit_code = report.returncode
        if exit_code == 0 and json_result.returncode != 0:
            exit_code = json_result.returncode
    elif exit_code == 0:
        exit_code = 1
    (out / "test-output.txt").write_text("\n".join(logs), encoding="utf-8")
    return {
        "kind": "python_unit_coverage",
        "subject": service["name"],
        "service": service["name"],
        "exit_code": exit_code,
        "coverage_status": coverage_status,
        "output": str(out.relative_to(ctx.run_dir)),
    }


def python_unit_coverage_command(command: str) -> tuple[list[str], dict[str, str]]:
    parts = shlex.split(command)
    assignments = {}
    while parts and re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*=.*", parts[0]):
        name, value = parts.pop(0).split("=", 1)
        assignments[name] = value
    if parts[:2] != ["uv", "run"]:
        raise CoverageCollectionFailed(
            "FAILED_COVERAGE: managed Python unit command must begin with uv run"
        )
    try:
        pytest_index = parts.index("pytest", 2)
    except ValueError as exc:
        raise CoverageCollectionFailed(
            "FAILED_COVERAGE: managed Python unit command must invoke pytest"
        ) from exc
    uv_options = parts[2:pytest_index]
    pytest_args = parts[pytest_index + 1 :]
    return (
        [
            "uv",
            "run",
            *uv_options,
            "--with",
            "coverage",
            "coverage",
            "run",
            "--parallel-mode",
            "-m",
            "pytest",
            *pytest_args,
        ],
        assignments,
    )


def run_frontend_unit_coverage(ctx, service):
    repo = ctx.workspace / service["path"]
    out = ctx.run_dir / "coverage" / service["name"] / "unit"
    v8_out = out / "v8"
    v8_out.mkdir(parents=True, exist_ok=True)
    contracts = sorted(
        path.relative_to(repo).as_posix()
        for path in (repo / "scripts").glob("*.test.mjs")
        if path.is_file()
    )
    write_json(
        out / "contract-registry.json",
        {
            "schema_version": 1,
            "build": ["npm", "run", "build"],
            "contracts": contracts,
            "node_v8_coverage": str(v8_out.relative_to(ctx.run_dir)),
        },
    )
    output = []
    build = subprocess.run(
        ["npm", "run", "build"],
        cwd=repo,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
    )
    output.append(f"$ npm run build\n{build.stdout}")
    exit_code = build.returncode
    if build.returncode == 0:
        for contract in contracts:
            env = os.environ.copy()
            env["NODE_V8_COVERAGE"] = str(v8_out)
            process = subprocess.run(
                ["node", contract],
                cwd=repo,
                env=env,
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
            )
            output.append(f"$ node {contract}\n{process.stdout}")
            if exit_code == 0 and process.returncode != 0:
                exit_code = process.returncode
    (out / "test-output.txt").write_text("\n".join(output), encoding="utf-8")
    return {
        "kind": "frontend_unit_coverage",
        "subject": service["name"],
        "service": service["name"],
        "exit_code": exit_code,
        "contract_count": len(contracts),
        "output": str(out.relative_to(ctx.run_dir)),
    }


def start_session_collectors(ctx, cfg) -> list[dict]:
    scripts = generate_runtime_scripts(ctx, cfg)
    pids = {"collectors": [], "runtime_scripts": scripts}
    browser_id = os.getenv("CODE_CENSUS_BROWSER_ID", "")
    tab_id = os.getenv("CODE_CENSUS_BROWSER_TAB_ID", "")
    target_url = os.getenv("CODE_CENSUS_CHROME_TARGET_URL", "")
    binding = (browser_id, tab_id, target_url)
    if any(binding) and not all(binding):
        raise CoverageCollectionFailed(
            "FAILED_COVERAGE: browser owner binding requires browser ID, tab ID, and target URL"
        )
    frontend = next(
        (service for service in cfg.services if service.get("kind") == "frontend"),
        None,
    )
    if all(binding):
        if not target_url.startswith(("http://127.0.0.1:", "http://localhost:")):
            raise CoverageCollectionFailed(
                "FAILED_COVERAGE: browser owner target must be loopback HTTP"
            )
        write_json(
            ctx.run_dir / "coverage/frontend-owner-waiting.json",
            {
                "schema_version": 1,
                "status": "waiting-for-browser-owner",
                "browser_id": browser_id,
                "tab_id": tab_id,
                "target_url": target_url,
                "frontend": frontend.get("name") if frontend else None,
                "ownership": "external-retained-tab",
            },
        )
    else:
        write_json(
            ctx.run_dir / "coverage/frontend-owner-skipped.json",
            {
                "schema_version": 1,
                "status": "not-requested",
                "reason": "external browser owner binding was not supplied",
            },
        )
    write_json(ctx.run_dir / "coverage/session-pids.json", pids)
    return []


def stop_session_collectors(ctx, cfg) -> dict:
    coverage_root = ctx.run_dir / "coverage"
    evidence_root = ctx.run_dir / "evidence"
    coverage_root_identity = (
        _directory_identity(coverage_root)
        if _anchored_directory_path_is_safe(ctx.run_dir, coverage_root)
        else None
    )
    evidence_root_identity = (
        _directory_identity(evidence_root)
        if _anchored_directory_path_is_safe(ctx.run_dir, evidence_root)
        else None
    )
    pids = read_json(
        ctx.run_dir / "coverage/session-pids.json",
        {"collectors": [], "runtime_scripts": []},
    )
    stopped = [
        {
            "name": collector.get("name", "unknown"),
            "pid": collector.get("pid"),
            "status": "not-managed-external-owner",
        }
        for collector in pids.get("collectors", [])
    ]
    runtime_coverage = collect_runtime_coverage_outputs(ctx, cfg, pids.get("runtime_scripts", []))
    hosted_runtime_finalization = finalize_hosted_runtime_containers(ctx, cfg)
    hosted_runtime_coverage = collect_hosted_runtime_coverage_outputs(
        ctx,
        cfg,
        finalization_results=hosted_runtime_finalization,
    )
    normalized_coverage_result = normalize_dynamic_coverage(
        ctx,
        cfg,
        require_frontend=(
            ctx.run_dir / "coverage/frontend-owner-waiting.json"
        ).is_file(),
    )
    normalized_coverage = {
        key: value
        for key, value in normalized_coverage_result.items()
        if key != "records"
    }
    summary = {
        "stopped": stopped,
        "runtime_scripts": pids.get("runtime_scripts", []),
        "runtime_coverage": runtime_coverage,
        "hosted_runtime_finalization": hosted_runtime_finalization,
        "hosted_runtime_coverage": hosted_runtime_coverage,
        "normalized_coverage": normalized_coverage,
    }
    _write_json_in_matching_directory(
        ctx.run_dir,
        coverage_root,
        coverage_root_identity,
        "session-coverage-summary.json",
        summary,
    )
    _append_jsonl_in_matching_directory(
        ctx.run_dir,
        evidence_root,
        evidence_root_identity,
        "coverage.jsonl",
        {
            "kind": "session_coverage",
            "subject": ctx.run_id,
            "source": "collectors",
            "confidence": "medium",
            "details": summary,
        },
    )
    return summary


def normalize_dynamic_coverage(
    ctx,
    cfg,
    *,
    require_frontend: bool = False,
) -> dict:
    records = []
    sources = []
    services = {service["name"]: service for service in cfg.services}
    for service in cfg.services:
        kind = service.get("kind", "")
        if kind.startswith("go-"):
            for label, profile_name, functions_name in (
                ("unit", "cover.out", "functions.txt"),
                ("runtime", "runtime.cover.out", "functions.txt"),
            ):
                root = (
                    ctx.run_dir
                    / "coverage"
                    / service["name"]
                    / label
                )
                parsed = _normalize_go_coverage(
                    ctx,
                    service,
                    root / profile_name,
                    root / functions_name,
                    source=f"{service['name']}:{label}",
                )
                if parsed:
                    records.extend(parsed)
                    sources.append(
                        {
                            "service": service["name"],
                            "language": "go",
                            "scope": label,
                            "status": "ok",
                            "record_count": len(parsed),
                        }
                    )
        elif kind.startswith("python-"):
            for label, filename in (
                ("unit", "coverage.json"),
                ("runtime", "runtime-coverage.json"),
            ):
                report = (
                    ctx.run_dir
                    / "coverage"
                    / service["name"]
                    / label
                    / filename
                )
                parsed = _normalize_python_coverage(
                    ctx,
                    service,
                    report,
                    source=f"{service['name']}:{label}",
                )
                if parsed:
                    records.extend(parsed)
                    sources.append(
                        {
                            "service": service["name"],
                            "language": "python",
                            "scope": label,
                            "status": "ok",
                            "record_count": len(parsed),
                        }
                    )

    runtime_agent = services.get("runtime-agent")
    combined_root = ctx.run_dir / "coverage/runtime-agent/combined"
    if runtime_agent is not None:
        parsed = _normalize_go_coverage(
            ctx,
            runtime_agent,
            combined_root / "go.cover.out",
            combined_root / "go-functions.txt",
            source="runtime-agent:hosted-combined",
        )
        if parsed:
            records.extend(parsed)
            sources.append(
                {
                    "service": runtime_agent["name"],
                    "language": "go",
                    "scope": "hosted-combined",
                    "status": "ok",
                    "record_count": len(parsed),
                }
            )
    session_worker = services.get("session-worker")
    if session_worker is not None:
        parsed = _normalize_python_coverage(
            ctx,
            session_worker,
            combined_root / "python-coverage.json",
            source="session-worker:hosted-combined",
        )
        if parsed:
            records.extend(parsed)
            sources.append(
                {
                    "service": session_worker["name"],
                    "language": "python",
                    "scope": "hosted-combined",
                    "status": "ok",
                    "record_count": len(parsed),
                }
            )

    frontend, frontend_records = _normalize_frontend_coverage(
        ctx,
        cfg,
        required=require_frontend,
    )
    records.extend(frontend_records)
    if frontend_records:
        sources.append(
            {
                "service": frontend.get("service"),
                "language": "javascript",
                "scope": "browser-precise",
                "status": "ok",
                "record_count": len(frontend_records),
            }
        )
    records = _dedupe_normalized_coverage_records(records)
    summary = {
        "schema_version": 1,
        "record_count": len(records),
        "sources": sources,
        "frontend": frontend,
        "records": records,
    }
    coverage_root = ctx.run_dir / "coverage"
    evidence_root = ctx.run_dir / "evidence"
    coverage_identity = _directory_identity(coverage_root)
    evidence_identity = _directory_identity(evidence_root)
    _write_json_in_matching_directory(
        ctx.run_dir,
        coverage_root,
        coverage_identity,
        "normalized-coverage-summary.json",
        summary,
    )
    for record in records:
        _append_jsonl_in_matching_directory(
            ctx.run_dir,
            evidence_root,
            evidence_identity,
            "coverage.jsonl",
            record,
        )
    return summary


def _normalize_go_coverage(
    ctx,
    service: dict,
    profile_path: Path,
    functions_path: Path,
    *,
    source: str,
) -> list[dict]:
    if not profile_path.is_file() and not functions_path.is_file():
        return []
    module = _go_module_path(ctx.workspace / service["path"])
    files = {}
    if profile_path.is_file():
        for line in profile_path.read_text(
            encoding="utf-8",
            errors="replace",
        ).splitlines():
            match = re.fullmatch(
                r"(.+):\d+\.\d+,\d+\.\d+\s+(\d+)\s+(\d+)",
                line.strip(),
            )
            if match is None:
                continue
            statement_count = int(match.group(2))
            execution_count = int(match.group(3))
            rel = _normalize_source_subject(
                ctx,
                service,
                match.group(1),
                module=module,
            )
            if rel is None:
                continue
            state = files.setdefault(
                rel,
                {"statements": 0, "covered_statements": 0},
            )
            state["statements"] += statement_count
            if execution_count > 0:
                state["covered_statements"] += statement_count
    records = []
    for rel, state in sorted(files.items()):
        if state["covered_statements"] <= 0:
            continue
        records.append(
            _normalized_coverage_record(
                "file",
                rel,
                service["name"],
                source,
                "go",
                {
                    "covered_statements": state["covered_statements"],
                    "statements": state["statements"],
                },
            )
        )
    if functions_path.is_file():
        for line in functions_path.read_text(
            encoding="utf-8",
            errors="replace",
        ).splitlines():
            match = re.fullmatch(
                r"(.+):\d+:\s+(.+?)\s+([0-9]+(?:\.[0-9]+)?)%",
                line.strip(),
            )
            if match is None or float(match.group(3)) <= 0:
                continue
            rel = _normalize_source_subject(
                ctx,
                service,
                match.group(1),
                module=module,
            )
            if rel is None:
                continue
            function_name = match.group(2).strip()
            records.append(
                _normalized_coverage_record(
                    "function",
                    f"{rel}::{function_name}",
                    service["name"],
                    source,
                    "go",
                    {
                        "file": rel,
                        "function": function_name,
                        "covered_percent": float(match.group(3)),
                    },
                )
            )
    return records


def _normalize_python_coverage(
    ctx,
    service: dict,
    report_path: Path,
    *,
    source: str,
) -> list[dict]:
    if not report_path.is_file():
        return []
    try:
        report = json.loads(report_path.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return []
    files = report.get("files")
    if not isinstance(files, dict):
        return []
    records = []
    for raw_file, details in sorted(files.items()):
        if not isinstance(raw_file, str) or not isinstance(details, dict):
            continue
        rel = _normalize_source_subject(ctx, service, raw_file)
        if rel is None:
            continue
        covered_lines = _python_covered_lines(details)
        if covered_lines > 0:
            records.append(
                _normalized_coverage_record(
                    "file",
                    rel,
                    service["name"],
                    source,
                    "python",
                    {"covered_lines": covered_lines},
                )
            )
        functions = details.get("functions", {})
        if not isinstance(functions, dict):
            continue
        for function_name, function in sorted(functions.items()):
            if (
                not isinstance(function_name, str)
                or not isinstance(function, dict)
                or _python_covered_lines(function) <= 0
            ):
                continue
            records.append(
                _normalized_coverage_record(
                    "function",
                    f"{rel}::{function_name}",
                    service["name"],
                    source,
                    "python",
                    {
                        "file": rel,
                        "function": function_name,
                        "covered_lines": _python_covered_lines(function),
                    },
                )
            )
    return records


def _normalize_frontend_coverage(
    ctx,
    cfg,
    *,
    required: bool,
) -> tuple[dict, list[dict]]:
    coverage_root = ctx.run_dir / "coverage"
    waiting_path = coverage_root / "frontend-owner-waiting.json"
    precise_path = coverage_root / "frontend-precise.json"
    waiting = None
    if waiting_path.is_file():
        try:
            waiting = _read_regular_json(
                waiting_path,
                MAX_FRONTEND_PRECISE_BYTES,
            )
        except (OSError, ValueError, TypeError) as exc:
            raise CoverageCollectionFailed(
                f"FAILED_COVERAGE: invalid frontend browser owner binding: {exc}"
            ) from exc
        required = True
    if not required and not precise_path.exists():
        return (
            {
                "status": "not-requested",
                "reason": "retained browser owner was not registered",
            },
            [],
        )
    if waiting is None:
        raise CoverageCollectionFailed(
            "FAILED_COVERAGE: frontend browser owner binding is missing"
        )
    if not precise_path.exists():
        raise CoverageCollectionFailed(
            "FAILED_COVERAGE: coverage/frontend-precise.json is missing"
        )
    try:
        precise = _read_regular_json(precise_path, MAX_FRONTEND_PRECISE_BYTES)
        _validate_frontend_binding(waiting, precise)
    except (OSError, ValueError, TypeError) as exc:
        raise CoverageCollectionFailed(
            f"FAILED_COVERAGE: invalid coverage/frontend-precise.json: {exc}"
        ) from exc
    service = next(
        (
            item
            for item in cfg.services
            if item.get("kind") == "frontend"
            and (
                waiting.get("frontend") is None
                or item.get("name") == waiting.get("frontend")
            )
        ),
        None,
    )
    if service is None:
        raise CoverageCollectionFailed(
            "FAILED_COVERAGE: retained browser owner has no configured frontend"
        )
    records = []
    application_scripts = 0
    application_functions = 0
    application_ranges = 0
    expected_origin = urlsplit(precise["frontend_origin"])
    for script in precise["precise_result"]["result"]:
        if not isinstance(script, dict):
            raise CoverageCollectionFailed(
                "FAILED_COVERAGE: frontend precise script is malformed"
            )
        url = script.get("url")
        functions = script.get("functions")
        if not isinstance(url, str) or not isinstance(functions, list):
            raise CoverageCollectionFailed(
                "FAILED_COVERAGE: frontend precise script is malformed"
            )
        script_url = urlsplit(url)
        if (
            script_url.scheme != expected_origin.scheme
            or script_url.netloc != expected_origin.netloc
        ):
            continue
        rel = _frontend_source_subject(ctx, service, url)
        if rel is None:
            continue
        application_scripts += 1
        file_covered = False
        for index, function in enumerate(functions):
            if not isinstance(function, dict):
                raise CoverageCollectionFailed(
                    "FAILED_COVERAGE: frontend precise function is malformed"
                )
            ranges = function.get("ranges")
            if not isinstance(ranges, list):
                raise CoverageCollectionFailed(
                    "FAILED_COVERAGE: frontend precise ranges are malformed"
                )
            application_functions += 1
            covered_ranges = []
            for item in ranges:
                if not _valid_frontend_range(item):
                    raise CoverageCollectionFailed(
                        "FAILED_COVERAGE: frontend precise range is malformed"
                    )
                application_ranges += 1
                if item["count"] > 0:
                    covered_ranges.append(item)
            if not covered_ranges:
                continue
            file_covered = True
            name = str(function.get("functionName") or "").strip()
            if not name:
                first = covered_ranges[0]
                name = (
                    f"<anonymous@{first['startOffset']}:"
                    f"{first['endOffset']}>"
                )
            records.append(
                _normalized_coverage_record(
                    "function",
                    f"{rel}::{name}",
                    service["name"],
                    "quant-frontend:browser-precise",
                    "javascript",
                    {
                        "file": rel,
                        "function": name,
                        "covered_ranges": len(covered_ranges),
                        "function_index": index,
                    },
                )
            )
        if file_covered:
            records.append(
                _normalized_coverage_record(
                    "file",
                    rel,
                    service["name"],
                    "quant-frontend:browser-precise",
                    "javascript",
                    {"covered": True},
                )
            )
    if not records:
        raise CoverageCollectionFailed(
            "FAILED_COVERAGE: frontend-precise.json has no covered workspace source"
        )
    return (
        {
            "status": "ok",
            "service": service["name"],
            "artifact": str(precise_path.relative_to(ctx.run_dir)),
            "application_script_count": application_scripts,
            "application_function_count": application_functions,
            "application_range_count": application_ranges,
            "record_count": len(records),
        },
        records,
    )


def _read_regular_json(path: Path, limit: int) -> dict:
    descriptor = os.open(
        path,
        os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0),
    )
    try:
        info = os.fstat(descriptor)
        if not stat.S_ISREG(info.st_mode):
            raise OSError("artifact is not a regular file")
        if info.st_size > limit:
            raise OSError("artifact exceeds size limit")
        with os.fdopen(descriptor, "rb") as handle:
            descriptor = None
            payload = handle.read(limit + 1)
    finally:
        if descriptor is not None:
            os.close(descriptor)
    if len(payload) > limit:
        raise OSError("artifact exceeds size limit")
    value = json.loads(payload.decode("utf-8"))
    if not isinstance(value, dict):
        raise ValueError("artifact root must be an object")
    return value


def _validate_frontend_binding(waiting: dict, precise: dict) -> None:
    if precise.get("schema_version") != 1:
        raise ValueError("schema_version must be 1")
    for field in ("browser_id", "tab_id"):
        value = waiting.get(field)
        if not isinstance(value, str) or not value or precise.get(field) != value:
            raise ValueError(f"{field} binding mismatch")
    target = waiting.get("target_url")
    origin = precise.get("frontend_origin")
    if not isinstance(target, str) or not isinstance(origin, str):
        raise ValueError("frontend origin binding is missing")
    target_url = urlsplit(target)
    precise_url = urlsplit(origin)
    if (
        target_url.scheme not in {"http", "https"}
        or precise_url.scheme != target_url.scheme
        or precise_url.netloc != target_url.netloc
    ):
        raise ValueError("frontend origin binding mismatch")
    result = precise.get("precise_result", {}).get("result")
    if not isinstance(result, list) or not result:
        raise ValueError("precise_result.result must be a nonempty array")


def _valid_frontend_range(value) -> bool:
    if not isinstance(value, dict):
        return False
    start = value.get("startOffset")
    end = value.get("endOffset")
    count = value.get("count")
    if any(isinstance(item, bool) for item in (start, end, count)):
        return False
    if not all(isinstance(item, (int, float)) for item in (start, end, count)):
        return False
    return (
        all(math.isfinite(float(item)) for item in (start, end, count))
        and start >= 0
        and end > start
        and count >= 0
    )


def _frontend_source_subject(ctx, service: dict, raw_url: str) -> str | None:
    parsed = urlsplit(raw_url)
    path = unquote(parsed.path)
    repo = ctx.workspace / service["path"]
    if path.startswith("/@fs/"):
        candidate = Path("/" + path.removeprefix("/@fs/").lstrip("/"))
    else:
        candidate = repo / path.lstrip("/")
    return _workspace_source_subject(ctx.workspace, candidate)


def _normalize_source_subject(
    ctx,
    service: dict,
    raw_path: str,
    *,
    module: str | None = None,
) -> str | None:
    repo = ctx.workspace / service["path"]
    if module and raw_path.startswith(module + "/"):
        candidate = repo / raw_path[len(module) + 1 :]
    else:
        path = Path(raw_path)
        candidate = path if path.is_absolute() else repo / path
    return _workspace_source_subject(ctx.workspace, candidate)


def _workspace_source_subject(workspace: Path, candidate: Path) -> str | None:
    try:
        resolved_workspace = workspace.resolve()
        resolved = candidate.resolve()
        rel = resolved.relative_to(resolved_workspace)
    except (OSError, ValueError):
        return None
    if not resolved.is_file():
        return None
    if any(part in {"node_modules", "dist", "build", ".git"} for part in rel.parts):
        return None
    return rel.as_posix()


def _go_module_path(repo: Path) -> str | None:
    go_mod = repo / "go.mod"
    if not go_mod.is_file():
        return None
    for line in go_mod.read_text(encoding="utf-8", errors="replace").splitlines():
        parts = line.strip().split()
        if len(parts) == 2 and parts[0] == "module":
            return parts[1]
    return None


def _python_covered_lines(details: dict) -> int:
    summary = details.get("summary", {})
    if isinstance(summary, dict):
        value = summary.get("covered_lines")
        if isinstance(value, int) and not isinstance(value, bool) and value >= 0:
            return value
    executed = details.get("executed_lines")
    if isinstance(executed, list):
        return len(executed)
    return 0


def _normalized_coverage_record(
    level: str,
    subject: str,
    service: str,
    source: str,
    language: str,
    extra: dict,
) -> dict:
    file = subject.split("::", 1)[0]
    details = {
        "file": file,
        "covered": True,
        "language": language,
        **extra,
    }
    return {
        "kind": f"normalized_coverage_{level}",
        "subject": subject,
        "service": service,
        "source": source,
        "confidence": "high",
        "details": details,
    }


def _dedupe_normalized_coverage_records(records: list[dict]) -> list[dict]:
    deduped = {}
    for record in records:
        key = (
            record.get("kind"),
            record.get("subject"),
            record.get("source"),
        )
        deduped[key] = record
    return [
        deduped[key]
        for key in sorted(
            deduped,
            key=lambda value: tuple(str(item) for item in value),
        )
    ]


def collect_runtime_coverage_outputs(ctx, cfg, runtime_scripts: list[dict]) -> list[dict]:
    services = {service["name"]: service for service in cfg.services}
    results = []
    for item in runtime_scripts:
        service = services.get(item.get("service"))
        if not service:
            continue
        kind = service.get("kind", "")
        out = ctx.run_dir / "coverage" / service["name"] / "runtime"
        if kind == "go-service":
            results.append(collect_go_runtime_coverage(ctx, service, out))
        elif kind == "python-service":
            results.append(collect_python_runtime_coverage(ctx, service, out))
    return results


def _is_safe_component(value: str) -> bool:
    return value not in {".", ".."} and SAFE_COMPONENT.fullmatch(value) is not None


def _anchored_directory_path_is_safe(
    anchor: Path,
    target: Path,
    *,
    allow_missing: bool = False,
) -> bool:
    anchor = Path(anchor)
    target = Path(target)
    try:
        relative = target.relative_to(anchor)
    except ValueError:
        return False

    current = anchor
    paths = [anchor]
    for part in relative.parts:
        current = current / part
        paths.append(current)
    for index, path in enumerate(paths):
        try:
            info = os.stat(path, follow_symlinks=False)
        except FileNotFoundError:
            return allow_missing and index == len(paths) - 1
        except OSError:
            return False
        if not stat.S_ISDIR(info.st_mode):
            return False
    return True


def _directory_identity(path: Path) -> tuple[int, int] | None:
    try:
        info = os.stat(path, follow_symlinks=False)
    except OSError:
        return None
    if not stat.S_ISDIR(info.st_mode):
        return None
    return info.st_dev, info.st_ino


def _open_matching_directory(
    anchor: Path,
    path: Path,
    expected_identity: tuple[int, int],
) -> int:
    if not _anchored_directory_path_is_safe(anchor, path):
        raise OSError("directory path is no longer safely anchored")
    flags = (
        os.O_RDONLY
        | getattr(os, "O_DIRECTORY", 0)
        | getattr(os, "O_NOFOLLOW", 0)
    )
    descriptor = os.open(path, flags)
    try:
        opened = os.fstat(descriptor)
        if (
            not stat.S_ISDIR(opened.st_mode)
            or (opened.st_dev, opened.st_ino) != expected_identity
        ):
            raise OSError("directory identity changed")
    except BaseException:
        os.close(descriptor)
        raise
    return descriptor


def _write_json_atomic_at(directory_fd: int, name: str, data: object) -> None:
    temp_name = f".{name}.{os.urandom(8).hex()}.tmp"
    descriptor = None
    try:
        descriptor = os.open(
            temp_name,
            os.O_WRONLY | os.O_CREAT | os.O_EXCL,
            0o600,
            dir_fd=directory_fd,
        )
        with os.fdopen(descriptor, "w", encoding="utf-8") as handle:
            descriptor = None
            handle.write(
                json.dumps(data, ensure_ascii=False, indent=2, sort_keys=True) + "\n"
            )
            handle.flush()
            os.fsync(handle.fileno())
        os.rename(
            temp_name,
            name,
            src_dir_fd=directory_fd,
            dst_dir_fd=directory_fd,
        )
    finally:
        if descriptor is not None:
            os.close(descriptor)
        try:
            os.unlink(temp_name, dir_fd=directory_fd)
        except FileNotFoundError:
            pass


def _append_jsonl_at(directory_fd: int, name: str, record: dict) -> None:
    source_descriptor = None
    temp_descriptor = None
    temp_name = f".{name}.{os.urandom(8).hex()}.tmp"
    try:
        try:
            source_descriptor = os.open(
                name,
                os.O_RDONLY
                | getattr(os, "O_NONBLOCK", 0)
                | getattr(os, "O_NOFOLLOW", 0),
                dir_fd=directory_fd,
            )
        except FileNotFoundError:
            source_descriptor = None
        if source_descriptor is not None:
            source_info = os.fstat(source_descriptor)
            if not stat.S_ISREG(source_info.st_mode):
                raise OSError("evidence target is not a regular file")
            if source_info.st_size > 0:
                os.lseek(source_descriptor, -1, os.SEEK_END)
                if os.read(source_descriptor, 1) != b"\n":
                    raise OSError("existing evidence log is not newline terminated")
                os.lseek(source_descriptor, 0, os.SEEK_SET)
        temp_descriptor = os.open(
            temp_name,
            os.O_WRONLY | os.O_CREAT | os.O_EXCL,
            0o600,
            dir_fd=directory_fd,
        )
        if source_descriptor is not None:
            while True:
                chunk = os.read(source_descriptor, 64 * 1024)
                if not chunk:
                    break
                _write_all(temp_descriptor, chunk)
        payload = (
            json.dumps(record, ensure_ascii=False, sort_keys=True) + "\n"
        ).encode("utf-8")
        _write_all(temp_descriptor, payload)
        os.fsync(temp_descriptor)
        os.close(temp_descriptor)
        temp_descriptor = None
        os.rename(
            temp_name,
            name,
            src_dir_fd=directory_fd,
            dst_dir_fd=directory_fd,
        )
    finally:
        if source_descriptor is not None:
            os.close(source_descriptor)
        if temp_descriptor is not None:
            os.close(temp_descriptor)
        try:
            os.unlink(temp_name, dir_fd=directory_fd)
        except FileNotFoundError:
            pass


def _write_all(descriptor: int, payload: bytes) -> None:
    offset = 0
    while offset < len(payload):
        written = os.write(descriptor, payload[offset:])
        if written <= 0:
            raise OSError("failed to write complete file")
        offset += written


def _write_json_in_matching_directory(
    anchor: Path,
    directory: Path,
    expected_identity: tuple[int, int] | None,
    name: str,
    data: object,
) -> bool:
    if expected_identity is None:
        return False
    try:
        directory_fd = _open_matching_directory(
            anchor,
            directory,
            expected_identity,
        )
        try:
            _write_json_atomic_at(directory_fd, name, data)
        finally:
            os.close(directory_fd)
    except OSError:
        return False
    return True


def _append_jsonl_in_matching_directory(
    anchor: Path,
    directory: Path,
    expected_identity: tuple[int, int] | None,
    name: str,
    record: dict,
) -> bool:
    if expected_identity is None:
        return False
    try:
        directory_fd = _open_matching_directory(
            anchor,
            directory,
            expected_identity,
        )
        try:
            _append_jsonl_at(directory_fd, name, record)
        finally:
            os.close(directory_fd)
    except OSError:
        return False
    return True


def _create_private_directory_at(parent_fd: int, prefix: str) -> str:
    for _ in range(128):
        name = f"{prefix}{os.urandom(8).hex()}"
        try:
            os.mkdir(name, 0o700, dir_fd=parent_fd)
        except FileExistsError:
            continue
        return name
    raise OSError("could not allocate a private staging directory")


def _remove_directory_at(parent_fd: int, name: str) -> None:
    flags = (
        os.O_RDONLY
        | getattr(os, "O_DIRECTORY", 0)
        | getattr(os, "O_NOFOLLOW", 0)
    )
    child_fd = os.open(name, flags, dir_fd=parent_fd)
    try:
        for entry_name in os.listdir(child_fd):
            entry = os.stat(entry_name, dir_fd=child_fd, follow_symlinks=False)
            if stat.S_ISDIR(entry.st_mode):
                _remove_directory_at(child_fd, entry_name)
            else:
                os.unlink(entry_name, dir_fd=child_fd)
    finally:
        os.close(child_fd)
    os.rmdir(name, dir_fd=parent_fd)


def _replace_staged_directory(directory_fd: int, staged: Path, name: str) -> None:
    backup_name = None
    try:
        existing = os.stat(name, dir_fd=directory_fd, follow_symlinks=False)
    except FileNotFoundError:
        existing = None
    if existing is not None:
        if not stat.S_ISDIR(existing.st_mode):
            raise OSError("owned directory output changed type")
        backup_name = f".{name}.old-{os.urandom(8).hex()}"
        os.rename(
            name,
            backup_name,
            src_dir_fd=directory_fd,
            dst_dir_fd=directory_fd,
        )
    try:
        os.rename(staged, name, dst_dir_fd=directory_fd)
    except OSError:
        if backup_name is not None:
            os.rename(
                backup_name,
                name,
                src_dir_fd=directory_fd,
                dst_dir_fd=directory_fd,
            )
        raise
    if backup_name is not None:
        _remove_directory_at(directory_fd, backup_name)


def _stage_hosted_runtime_inputs(runtime_dir: Path, staging_root: Path) -> Path:
    staged_runtime = staging_root / runtime_dir.name
    staged_runtime.mkdir(mode=0o700)
    for name in ("go", "python"):
        source = runtime_dir / name
        if source.is_dir():
            shutil.copytree(source, staged_runtime / name, symlinks=True)
    return staged_runtime


def _publish_staged_runtime_outputs(
    runtime_dir: Path,
    staged_runtime: Path,
    *,
    trusted_root: Path,
    expected_identity: tuple[int, int],
    manifest: dict,
) -> None:
    runtime_fd = _open_matching_directory(
        trusted_root,
        runtime_dir,
        expected_identity,
    )
    try:
        for name in sorted(HOSTED_RUNTIME_FILE_OUTPUTS - {"coverage-manifest.json"}):
            staged = staged_runtime / name
            if staged.is_file() and not staged.is_symlink():
                os.rename(staged, name, dst_dir_fd=runtime_fd)
        staged_merged = staged_runtime / "go-merged"
        if staged_merged.is_dir() and not staged_merged.is_symlink():
            _replace_staged_directory(runtime_fd, staged_merged, "go-merged")
        staged_python_data = staged_runtime / "python/.coverage"
        if staged_python_data.is_file() and not staged_python_data.is_symlink():
            python_fd = os.open(
                "python",
                os.O_RDONLY
                | getattr(os, "O_DIRECTORY", 0)
                | getattr(os, "O_NOFOLLOW", 0),
                dir_fd=runtime_fd,
            )
            try:
                os.rename(staged_python_data, ".coverage", dst_dir_fd=python_fd)
            finally:
                os.close(python_fd)
        _write_json_atomic_at(runtime_fd, "coverage-manifest.json", manifest)
    finally:
        os.close(runtime_fd)


def _normalize_hosted_runtime_result_paths(result: dict, runtime_dir: Path) -> None:
    go_result = result["go"]
    go_result["input"] = str(runtime_dir / "go")
    if "cover_profile" in go_result:
        go_result["cover_profile"] = str(runtime_dir / "go.cover.out")
    if "functions" in go_result:
        go_result["functions"] = str(runtime_dir / "go-functions.txt")
    python_result = result["python"]
    python_result["input"] = str(runtime_dir / "python")
    if "json" in python_result:
        python_result["json"] = str(runtime_dir / "python-coverage.json")
    if "report" in python_result:
        python_result["report"] = str(runtime_dir / "python-report.txt")


def _read_hosted_finalization(runtime_dir: Path, runtime_id: str) -> dict:
    marker_path = runtime_dir / "finalization.json"
    try:
        runtime_root_stat = os.stat(runtime_dir.parent, follow_symlinks=False)
        runtime_stat = os.stat(runtime_dir, follow_symlinks=False)
    except FileNotFoundError:
        return {
            "status": "incomplete",
            "error_category": "finalization_missing",
        }
    except OSError:
        return {
            "status": "incomplete",
            "error_category": "finalization_path_unsafe",
        }
    if not stat.S_ISDIR(runtime_root_stat.st_mode) or not stat.S_ISDIR(
        runtime_stat.st_mode
    ):
        return {
            "status": "incomplete",
            "error_category": "finalization_path_unsafe",
        }

    try:
        marker_stat = os.stat(marker_path, follow_symlinks=False)
    except FileNotFoundError:
        return {
            "status": "incomplete",
            "error_category": "finalization_missing",
        }
    except OSError:
        return {
            "status": "incomplete",
            "error_category": "finalization_path_unsafe",
        }
    if not stat.S_ISREG(marker_stat.st_mode):
        return {
            "status": "incomplete",
            "error_category": "finalization_path_unsafe",
        }

    runtime_root_fd = None
    runtime_fd = None
    marker_fd = None
    try:
        directory_flags = (
            os.O_RDONLY
            | getattr(os, "O_DIRECTORY", 0)
            | getattr(os, "O_NOFOLLOW", 0)
        )
        runtime_root_fd = os.open(runtime_dir.parent, directory_flags)
        runtime_fd = os.open(
            runtime_dir.name,
            directory_flags,
            dir_fd=runtime_root_fd,
        )
        marker_fd = os.open(
            "finalization.json",
            os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0),
            dir_fd=runtime_fd,
        )
        opened_stat = os.fstat(marker_fd)
        if (
            not stat.S_ISREG(opened_stat.st_mode)
            or opened_stat.st_dev != marker_stat.st_dev
            or opened_stat.st_ino != marker_stat.st_ino
        ):
            return {
                "status": "incomplete",
                "error_category": "finalization_path_unsafe",
            }
        if opened_stat.st_size > MAX_HOSTED_FINALIZATION_BYTES:
            return {
                "status": "incomplete",
                "error_category": "finalization_malformed",
            }
        handle = os.fdopen(marker_fd, "rb")
        marker_fd = None
        with handle:
            encoded_marker = handle.read(MAX_HOSTED_FINALIZATION_BYTES + 1)
        if len(encoded_marker) > MAX_HOSTED_FINALIZATION_BYTES:
            return {
                "status": "incomplete",
                "error_category": "finalization_malformed",
            }
        marker = json.loads(encoded_marker.decode("utf-8"))
    except FileNotFoundError:
        return {
            "status": "incomplete",
            "error_category": "finalization_missing",
        }
    except OSError:
        return {
            "status": "incomplete",
            "error_category": "finalization_path_unsafe",
        }
    except (UnicodeDecodeError, ValueError, RecursionError):
        return {
            "status": "incomplete",
            "error_category": "finalization_malformed",
        }
    finally:
        for descriptor in (marker_fd, runtime_fd, runtime_root_fd):
            if descriptor is not None:
                os.close(descriptor)
    if not isinstance(marker, dict):
        return {
            "status": "incomplete",
            "error_category": "finalization_malformed",
        }
    marker_runtime_id = marker.get("runtime_id")
    if isinstance(marker_runtime_id, str) and marker_runtime_id != runtime_id:
        return {
            "status": "incomplete",
            "error_category": "finalization_runtime_mismatch",
        }

    state = marker.get("state")
    expected_fields = set(FINALIZATION_BASE_FIELDS)
    if state in {"complete", "incomplete"}:
        expected_fields.add("completed_at")
    if state not in {"running", "complete", "incomplete"} or set(marker) != expected_fields:
        return {
            "status": "incomplete",
            "error_category": "finalization_malformed",
        }
    forced_workers = marker.get("forced_workers")
    schema_version = marker.get("schema_version")
    if (
        isinstance(schema_version, bool)
        or schema_version != 1
        or marker_runtime_id != runtime_id
        or not _is_safe_component(runtime_id)
        or not isinstance(marker.get("boot_id"), str)
        or not _is_safe_component(marker["boot_id"])
        or isinstance(forced_workers, bool)
        or not isinstance(forced_workers, int)
        or forced_workers < 0
    ):
        return {
            "status": "incomplete",
            "error_category": "finalization_malformed",
        }

    worker_shutdown = marker.get("worker_shutdown")
    go_snapshot = marker.get("go_snapshot")
    if state == "running":
        if worker_shutdown != "pending" or forced_workers != 0 or go_snapshot != "pending":
            return {
                "status": "incomplete",
                "error_category": "finalization_malformed",
            }
        return {
            "status": "incomplete",
            "error_category": "finalization_running",
            "marker": marker,
        }

    completed_at = marker.get("completed_at")
    if not isinstance(completed_at, str) or RFC3339_NANO.fullmatch(completed_at) is None:
        return {
            "status": "incomplete",
            "error_category": "finalization_malformed",
        }
    try:
        completed_time = datetime.fromisoformat(completed_at.replace("Z", "+00:00"))
    except ValueError:
        return {
            "status": "incomplete",
            "error_category": "finalization_malformed",
        }
    if completed_time.tzinfo is None:
        return {
            "status": "incomplete",
            "error_category": "finalization_malformed",
        }
    if worker_shutdown not in {"ok", "error", "forced"} or go_snapshot not in {"ok", "error"}:
        return {
            "status": "incomplete",
            "error_category": "finalization_malformed",
        }
    if (
        (worker_shutdown == "forced" and forced_workers == 0)
        or (worker_shutdown == "ok" and forced_workers != 0)
    ):
        return {
            "status": "incomplete",
            "error_category": "finalization_malformed",
        }
    complete_facts = worker_shutdown == "ok" and forced_workers == 0 and go_snapshot == "ok"
    if state == "complete" and complete_facts:
        return {"status": "ok", "marker": marker}
    if state == "incomplete" and not complete_facts:
        return {
            "status": "incomplete",
            "error_category": "finalization_incomplete",
            "marker": marker,
        }
    return {
        "status": "incomplete",
        "error_category": "finalization_malformed",
    }


def finalize_hosted_runtime_containers(
    ctx,
    cfg,
    run_command=subprocess.run,
) -> list[dict]:
    stop_timeout = cfg.hosted_runtime_coverage["stop_timeout_seconds"]
    list_command = [
        "docker",
        "ps",
        "--filter",
        f"label={HOSTED_RUNTIME_LABEL_PREFIX}.coverage=true",
        "--filter",
        f"label={HOSTED_RUNTIME_LABEL_PREFIX}.coverage_run_id={ctx.run_id}",
        "--format",
        (
            '{{.ID}}\t{{.Label "'
            f"{HOSTED_RUNTIME_LABEL_PREFIX}.runtime_id"
            '"}}\t{{.Label "'
            f"{HOSTED_RUNTIME_LABEL_PREFIX}.user_id"
            '"}}'
        ),
    ]
    try:
        listed = run_command(
            list_command,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
        )
    except OSError:
        return [
            {
                "status": "error",
                "exit_code": -1,
                "error_category": "docker_list_unavailable",
            }
        ]
    if listed.returncode != 0:
        return [
            {
                "status": "error",
                "exit_code": listed.returncode,
                "error_category": "docker_list_failed",
            }
        ]

    runtime_root = ctx.run_dir / "coverage/runtime-agent/runtimes"
    results = []
    listed_runtime_ids: set[str] = set()
    for line in (listed.stdout or "").splitlines():
        if not line.strip():
            continue
        fields = line.split("\t")
        if len(fields) != 3:
            results.append(
                {
                    "status": "rejected",
                    "error_category": "invalid_container_record",
                }
            )
            continue
        container_id, runtime_id, user_id_text = fields
        if not _is_safe_component(container_id):
            results.append(
                {
                    "status": "rejected",
                    "error_category": "unsafe_container_id",
                }
            )
            continue
        if not _is_safe_component(runtime_id):
            results.append(
                {
                    "container_id": container_id,
                    "status": "rejected",
                    "error_category": "unsafe_runtime_id",
                }
            )
            continue
        listed_runtime_ids.add(runtime_id)
        if not user_id_text.isdigit() or int(user_id_text) <= 0:
            results.append(
                {
                    "container_id": container_id,
                    "runtime_id": runtime_id,
                    "status": "rejected",
                    "error_category": "invalid_user_id",
                }
            )
            continue

        runtime_dir = runtime_root / runtime_id
        current_finalization = _read_hosted_finalization(runtime_dir, runtime_id)
        if current_finalization.get("error_category") == "finalization_runtime_mismatch":
            results.append(
                {
                    "container_id": container_id,
                    "runtime_id": runtime_id,
                    "user_id": int(user_id_text),
                    "status": "rejected",
                    "error_category": "runtime_id_mismatch",
                }
            )
            continue

        stop_command = [
            "docker",
            "stop",
            "--time",
            str(stop_timeout),
            container_id,
        ]
        try:
            stopped = run_command(
                stop_command,
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                check=False,
            )
        except OSError:
            results.append(
                {
                    "container_id": container_id,
                    "runtime_id": runtime_id,
                    "user_id": int(user_id_text),
                    "status": "error",
                    "exit_code": -1,
                    "error_category": "docker_stop_unavailable",
                }
            )
            continue
        if stopped.returncode != 0:
            results.append(
                {
                    "container_id": container_id,
                    "runtime_id": runtime_id,
                    "user_id": int(user_id_text),
                    "status": "error",
                    "exit_code": stopped.returncode,
                    "error_category": "docker_stop_failed",
                }
            )
            continue

        finalization = _wait_for_hosted_finalization(runtime_dir, runtime_id)
        item = {
            "container_id": container_id,
            "runtime_id": runtime_id,
            "user_id": int(user_id_text),
            "status": "stopped",
            "exit_code": 0,
            "finalization_status": _finalization_status_name(finalization),
        }
        if finalization["status"] != "ok":
            item["error_category"] = finalization["error_category"]
        results.append(item)

    runtime_agent_root = runtime_root.parent
    for runtime_dir in discover_hosted_runtime_directories(runtime_agent_root):
        runtime_id = runtime_dir.name
        if runtime_id in listed_runtime_ids:
            continue
        if not _is_safe_component(runtime_id):
            results.append(
                {
                    "status": "rejected",
                    "error_category": "unsafe_runtime_id",
                }
            )
            continue
        finalization = _read_hosted_finalization(runtime_dir, runtime_id)
        item = {
            "runtime_id": runtime_id,
            "status": "stopped" if finalization["status"] == "ok" else "unconfirmed",
            "finalization_status": _finalization_status_name(finalization),
            "stop_source": "existing_finalization",
        }
        if finalization["status"] == "ok":
            item["exit_code"] = 0
        else:
            item["error_category"] = finalization["error_category"]
        results.append(item)
    return results


def _wait_for_hosted_finalization(runtime_dir: Path, runtime_id: str) -> dict:
    deadline = time.monotonic() + HOSTED_FINALIZATION_WAIT_SECONDS
    while True:
        finalization = _read_hosted_finalization(runtime_dir, runtime_id)
        if finalization.get("error_category") != "finalization_running":
            return finalization
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            return finalization
        time.sleep(min(0.05, remaining))


def _finalization_status_name(finalization: dict) -> str:
    if finalization["status"] == "ok":
        return "complete"
    return finalization["error_category"].removeprefix("finalization_")


def _hosted_runtime_paths_are_safe(runtime_dir: Path) -> bool:
    if (
        not _is_safe_component(runtime_dir.name)
        or runtime_dir.is_symlink()
        or not runtime_dir.is_dir()
        or runtime_dir.parent.is_symlink()
        or not runtime_dir.parent.is_dir()
    ):
        return False

    pending = [runtime_dir]
    while pending:
        directory = pending.pop()
        try:
            entries = list(os.scandir(directory))
        except OSError:
            return False
        for entry in entries:
            try:
                if entry.is_symlink():
                    return False
                if entry.is_dir(follow_symlinks=False):
                    pending.append(Path(entry.path))
                elif not entry.is_file(follow_symlinks=False):
                    return False
            except OSError:
                return False

    for name in ("go", "python", *HOSTED_RUNTIME_DIRECTORY_OUTPUTS):
        path = runtime_dir / name
        if path.exists() and not path.is_dir():
            return False
    for name in ("finalization.json", *HOSTED_RUNTIME_FILE_OUTPUTS):
        path = runtime_dir / name
        if path.exists() and not path.is_file():
            return False
    return True


def _unsafe_hosted_runtime_result(
    runtime_dir: Path,
    *,
    trusted_root: Path | None = None,
    expected_identity: tuple[int, int] | None = None,
) -> dict:
    unsafe = {
        "status": "error",
        "error_category": "unsafe_coverage_path",
    }
    result = {
        "kind": "hosted_runtime_coverage",
        "runtime_id": runtime_dir.name,
        "status": "error",
        "output": str(runtime_dir),
        "finalization": {
            "status": "incomplete",
            "error_category": "unsafe_coverage_path",
        },
        "go": dict(unsafe),
        "python": dict(unsafe),
        "combined": {
            "included": False,
            "error_category": "unsafe_coverage_path",
        },
    }
    if trusted_root is not None:
        _write_json_in_matching_directory(
            trusted_root,
            runtime_dir,
            expected_identity,
            "coverage-manifest.json",
            result,
        )
    return result


def _unconfirmed_stop_hosted_runtime_result(runtime_dir: Path) -> dict:
    skipped = {
        "status": "skipped",
        "error_category": "runtime_stop_unconfirmed",
    }
    return {
        "kind": "hosted_runtime_coverage",
        "runtime_id": runtime_dir.name,
        "status": "incomplete",
        "output": str(runtime_dir),
        "finalization": {
            "status": "incomplete",
            "error_category": "runtime_stop_unconfirmed",
        },
        "go": dict(skipped),
        "python": dict(skipped),
        "combined": {
            "included": False,
            "error_category": "runtime_stop_unconfirmed",
        },
    }


def _confirmed_hosted_runtime_stops(
    finalization_results: list[dict] | None,
) -> tuple[bool, set[str]]:
    if finalization_results is None:
        return True, set()
    block_all = False
    confirmed_runtime_ids = set()
    for item in finalization_results:
        runtime_id = item.get("runtime_id")
        if not isinstance(runtime_id, str) or not _is_safe_component(runtime_id):
            block_all = True
            continue
        if item.get("status") == "stopped" and item.get("exit_code") == 0:
            confirmed_runtime_ids.add(runtime_id)
    return block_all, confirmed_runtime_ids


def discover_hosted_runtime_directories(runtime_agent_root: Path) -> list[Path]:
    runtimes_root = runtime_agent_root / "runtimes"
    if runtimes_root.is_symlink() or not runtimes_root.is_dir():
        return []
    return sorted(
        (
            path
            for path in runtimes_root.iterdir()
            if path.is_dir() and not path.is_symlink()
        ),
        key=lambda path: path.name,
    )


def collect_hosted_runtime_coverage(
    runtime_dir: Path,
    *,
    source_dir: Path | None = None,
    run_command=subprocess.run,
    trusted_root: Path | None = None,
) -> dict:
    runtime_dir = Path(runtime_dir)
    source_dir = Path(source_dir) if source_dir is not None else Path.cwd()
    runtime_agent_root = runtime_dir.parent.parent
    trusted_root = Path(trusted_root) if trusted_root is not None else runtime_agent_root
    if not _anchored_directory_path_is_safe(trusted_root, runtime_dir):
        return _unsafe_hosted_runtime_result(runtime_dir)
    expected_identity = _directory_identity(runtime_dir)
    if expected_identity is None:
        return _unsafe_hosted_runtime_result(runtime_dir)
    if not _hosted_runtime_paths_are_safe(runtime_dir):
        return _unsafe_hosted_runtime_result(
            runtime_dir,
            trusted_root=trusted_root,
            expected_identity=expected_identity,
        )
    finalization = _read_hosted_finalization(runtime_dir, runtime_dir.name)
    runtime_agent_identity = _directory_identity(runtime_agent_root)
    if runtime_agent_identity is None:
        return _unsafe_hosted_runtime_result(
            runtime_dir,
            trusted_root=trusted_root,
            expected_identity=expected_identity,
        )
    runtime_agent_fd = None
    try:
        runtime_agent_fd = _open_matching_directory(
            trusted_root,
            runtime_agent_root,
            runtime_agent_identity,
        )
        staging_name = _create_private_directory_at(
            runtime_agent_fd,
            ".census-stage-",
        )
    except OSError:
        if runtime_agent_fd is not None:
            os.close(runtime_agent_fd)
        return _unsafe_hosted_runtime_result(
            runtime_dir,
            trusted_root=trusted_root,
            expected_identity=expected_identity,
        )
    staging_root = runtime_agent_root / staging_name
    try:
        staged_runtime = _stage_hosted_runtime_inputs(runtime_dir, staging_root)
        if not _hosted_runtime_paths_are_safe(staged_runtime):
            return _unsafe_hosted_runtime_result(
                runtime_dir,
                trusted_root=trusted_root,
                expected_identity=expected_identity,
            )
        go_result = _collect_hosted_go_coverage(
            staged_runtime,
            source_dir,
            run_command=run_command,
        )
        python_result = _collect_hosted_python_coverage(
            staged_runtime,
            source_dir,
            run_command=run_command,
        )
        language_statuses = {go_result["status"], python_result["status"]}
        if "error" in language_statuses:
            status = "error"
        elif "missing" in language_statuses or finalization["status"] != "ok":
            status = "incomplete"
        else:
            status = "ok"
        included = status == "ok"
        if finalization["status"] != "ok":
            exclusion_category = finalization["error_category"]
        elif go_result["status"] != "ok":
            exclusion_category = f"go_{go_result['status']}"
        elif python_result["status"] != "ok":
            exclusion_category = f"python_{python_result['status']}"
        else:
            exclusion_category = "included"
        result = {
            "kind": "hosted_runtime_coverage",
            "runtime_id": runtime_dir.name,
            "status": status,
            "output": str(runtime_dir),
            "finalization": finalization,
            "go": go_result,
            "python": python_result,
            "combined": {
                "included": included,
                "error_category": exclusion_category,
            },
        }
        _normalize_hosted_runtime_result_paths(result, runtime_dir)
        _publish_staged_runtime_outputs(
            runtime_dir,
            staged_runtime,
            trusted_root=trusted_root,
            expected_identity=expected_identity,
            manifest=result,
        )
        return result
    except OSError:
        return _unsafe_hosted_runtime_result(
            runtime_dir,
            trusted_root=trusted_root,
            expected_identity=expected_identity,
        )
    finally:
        try:
            _remove_directory_at(runtime_agent_fd, staging_name)
        except OSError:
            pass
        os.close(runtime_agent_fd)


def collect_hosted_runtime_coverage_outputs(
    ctx,
    cfg,
    *,
    finalization_results: list[dict] | None = None,
    run_command=subprocess.run,
) -> list[dict]:
    runtime_agent_root = ctx.run_dir / "coverage/runtime-agent"
    runtime_agent = next(
        (service for service in cfg.services if service.get("name") == "runtime-agent"),
        {"path": "strategy-service"},
    )
    source_dir = ctx.workspace / runtime_agent["path"]
    coverage_root = ctx.run_dir / "coverage"
    coverage_root_is_safe = _anchored_directory_path_is_safe(
        ctx.run_dir,
        coverage_root,
    )
    coverage_root_identity = (
        _directory_identity(coverage_root) if coverage_root_is_safe else None
    )
    evidence_root = ctx.run_dir / "evidence"
    evidence_root_is_safe = _anchored_directory_path_is_safe(
        ctx.run_dir,
        evidence_root,
    )
    evidence_root_identity = (
        _directory_identity(evidence_root) if evidence_root_is_safe else None
    )
    if not coverage_root_is_safe or not _anchored_directory_path_is_safe(
        ctx.run_dir,
        runtime_agent_root,
        allow_missing=True,
    ):
        results = [
            {
                "kind": "hosted_runtime_coverage",
                "subject": "runtime-agent",
                "status": "error",
                "error_category": "unsafe_coverage_path",
                "output": str(runtime_agent_root),
            }
        ]
        if coverage_root_is_safe:
            _write_json_in_matching_directory(
                ctx.run_dir,
                coverage_root,
                coverage_root_identity,
                "hosted-runtime-coverage-summary.json",
                results,
            )
        if evidence_root_is_safe:
            for item in results:
                _append_jsonl_in_matching_directory(
                    ctx.run_dir,
                    evidence_root,
                    evidence_root_identity,
                    "coverage.jsonl",
                    item,
                )
        return results
    runtime_dirs = discover_hosted_runtime_directories(runtime_agent_root)
    block_all, confirmed_runtime_ids = _confirmed_hosted_runtime_stops(
        finalization_results
    )
    if runtime_dirs:
        results = [
            (
                _unconfirmed_stop_hosted_runtime_result(runtime_dir)
                if block_all or runtime_dir.name not in confirmed_runtime_ids
                else collect_hosted_runtime_coverage(
                    runtime_dir,
                    source_dir=source_dir,
                    run_command=run_command,
                    trusted_root=ctx.run_dir,
                )
            )
            for runtime_dir in runtime_dirs
        ]
    else:
        results = [
            {
                "kind": "hosted_runtime_coverage",
                "subject": "runtime-agent",
                "status": "missing",
                "reason": "hosted runtime coverage directories are missing",
                "output": str(runtime_agent_root / "runtimes"),
            }
        ]
    _write_json_in_matching_directory(
        ctx.run_dir,
        coverage_root,
        coverage_root_identity,
        "hosted-runtime-coverage-summary.json",
        results,
    )
    for item in results:
        _append_jsonl_in_matching_directory(
            ctx.run_dir,
            evidence_root,
            evidence_root_identity,
            "coverage.jsonl",
            item,
        )
    combined = _collect_hosted_runtime_combined_coverage(
        runtime_agent_root,
        results,
        source_dir,
        run_command=run_command,
        trusted_root=ctx.run_dir,
    )
    _append_jsonl_in_matching_directory(
        ctx.run_dir,
        evidence_root,
        evidence_root_identity,
        "coverage.jsonl",
        combined,
    )
    return results


def _collect_hosted_runtime_combined_coverage(
    runtime_agent_root: Path,
    results: list[dict],
    source_dir: Path,
    *,
    run_command,
    trusted_root: Path,
) -> dict:
    combined_dir = runtime_agent_root / "combined"
    summary_name = "hosted-runtime-coverage-combined-summary.json"
    included = [item for item in results if item.get("combined", {}).get("included")]
    excluded = [
        {
            "runtime_id": item["runtime_id"],
            "error_category": item["combined"]["error_category"],
        }
        for item in results
        if item.get("runtime_id") and not item.get("combined", {}).get("included")
    ]

    coverage_root = runtime_agent_root.parent
    if not runtime_agent_root.exists():
        if not _anchored_directory_path_is_safe(trusted_root, coverage_root):
            return _combined_path_error(combined_dir, included, excluded)
        try:
            runtime_agent_root.mkdir(mode=0o700)
        except OSError:
            return _combined_path_error(combined_dir, included, excluded)
    if not _anchored_directory_path_is_safe(trusted_root, runtime_agent_root):
        return _combined_path_error(combined_dir, included, excluded)
    root_identity = _directory_identity(runtime_agent_root)
    if root_identity is None:
        return _combined_path_error(combined_dir, included, excluded)
    coverage_root_identity = _directory_identity(coverage_root)
    if coverage_root_identity is None:
        return _combined_path_error(combined_dir, included, excluded)
    coverage_root_fd = None
    try:
        coverage_root_fd = _open_matching_directory(
            trusted_root,
            coverage_root,
            coverage_root_identity,
        )
        staging_name = _create_private_directory_at(
            coverage_root_fd,
            ".census-combined-stage-",
        )
    except OSError:
        if coverage_root_fd is not None:
            os.close(coverage_root_fd)
        return _combined_path_error(combined_dir, included, excluded)
    staging_root = coverage_root / staging_name
    staged_combined = staging_root / "combined"
    try:
        staged_combined.mkdir(mode=0o700)
        if included:
            go_result = _collect_combined_go_coverage(
                staged_combined,
                included,
                source_dir,
                run_command=run_command,
            )
            python_result = _collect_combined_python_coverage(
                staged_combined,
                included,
                source_dir,
                run_command=run_command,
            )
            statuses = {go_result["status"], python_result["status"]}
            if statuses == {"ok"}:
                status = "ok"
            elif "error" in statuses:
                status = "error"
            else:
                status = "incomplete"
        else:
            missing = {
                "status": "missing",
                "reason": "no complete hosted runtime coverage inputs",
                "input": [],
            }
            go_result = dict(missing)
            python_result = dict(missing)
            status = "missing"
    except OSError:
        error_category = "combined_io_failed"
        error = {
            "status": "error",
            "exit_code": -1,
            "error_category": error_category,
            "input": [],
        }
        go_result = dict(error)
        python_result = dict(error)
        status = "error"

    try:
        _normalize_combined_result_paths(
            go_result,
            python_result,
            staged_combined,
            combined_dir,
        )
        summary = {
            "kind": "hosted_runtime_coverage_combined",
            "status": status,
            "included_runtime_ids": [item["runtime_id"] for item in included],
            "excluded": excluded,
            "output": str(combined_dir),
            "go": go_result,
            "python": python_result,
        }
        if status == "error" and "error_category" in go_result:
            summary["error_category"] = go_result["error_category"]
        runtime_agent_fd = _open_matching_directory(
            trusted_root,
            runtime_agent_root,
            root_identity,
        )
        try:
            _replace_staged_directory(
                runtime_agent_fd,
                staged_combined,
                "combined",
            )
            _write_json_atomic_at(runtime_agent_fd, summary_name, summary)
        finally:
            os.close(runtime_agent_fd)
        return summary
    except OSError:
        return _combined_path_error(combined_dir, included, excluded)
    finally:
        try:
            _remove_directory_at(coverage_root_fd, staging_name)
        except OSError:
            pass
        os.close(coverage_root_fd)


def _combined_path_error(
    combined_dir: Path,
    included: list[dict],
    excluded: list[dict],
) -> dict:
    error = {
        "status": "error",
        "exit_code": -1,
        "error_category": "unsafe_combined_path",
        "input": [],
    }
    return {
        "kind": "hosted_runtime_coverage_combined",
        "status": "error",
        "included_runtime_ids": [item["runtime_id"] for item in included],
        "excluded": excluded,
        "output": str(combined_dir),
        "go": dict(error),
        "python": dict(error),
        "error_category": "unsafe_combined_path",
    }


def _normalize_combined_result_paths(
    go_result: dict,
    python_result: dict,
    staged_combined: Path,
    combined_dir: Path,
) -> None:
    for key in ("cover_profile", "functions"):
        value = go_result.get(key)
        if isinstance(value, str):
            go_result[key] = str(combined_dir / Path(value).relative_to(staged_combined))
    python_inputs = python_result.get("input")
    if isinstance(python_inputs, list):
        python_result["input"] = [
            str(combined_dir / Path(value).relative_to(staged_combined))
            if isinstance(value, str) and Path(value).is_relative_to(staged_combined)
            else value
            for value in python_inputs
        ]
    for key in ("json", "report"):
        value = python_result.get(key)
        if isinstance(value, str):
            python_result[key] = str(
                combined_dir / Path(value).relative_to(staged_combined)
            )


def _collect_combined_go_coverage(
    combined_dir: Path,
    included: list[dict],
    source_dir: Path,
    *,
    run_command,
) -> dict:
    input_dirs = [Path(item["go"]["input"]) for item in included]
    merged_dir = combined_dir / "go"
    merged_dir.mkdir()
    merge = _run_coverage_command(
        run_command,
        [
            "go",
            "tool",
            "covdata",
            "merge",
            f"-i={','.join(str(path) for path in input_dirs)}",
            f"-o={merged_dir}",
        ],
        cwd=source_dir,
    )
    _write_process_output(combined_dir / "go-covdata-merge-output.txt", merge)
    if merge.returncode != 0:
        return {
            "status": "error",
            "step": "go covdata merge",
            "exit_code": merge.returncode,
            "input": [str(path) for path in input_dirs],
        }

    cover_profile = combined_dir / "go.cover.out"
    textfmt = _run_coverage_command(
        run_command,
        [
            "go",
            "tool",
            "covdata",
            "textfmt",
            f"-i={merged_dir}",
            f"-o={cover_profile}",
        ],
        cwd=source_dir,
    )
    _write_process_output(combined_dir / "go-covdata-textfmt-output.txt", textfmt)
    if textfmt.returncode != 0:
        return {
            "status": "error",
            "step": "go covdata textfmt",
            "exit_code": textfmt.returncode,
            "input": [str(path) for path in input_dirs],
        }

    functions_path = combined_dir / "go-functions.txt"
    functions = _run_coverage_command(
        run_command,
        ["go", "tool", "cover", f"-func={cover_profile}"],
        cwd=source_dir,
    )
    _write_process_output(functions_path, functions)
    if functions.returncode != 0:
        return {
            "status": "error",
            "step": "go cover functions",
            "exit_code": functions.returncode,
            "input": [str(path) for path in input_dirs],
        }
    return {
        "status": "ok",
        "input": [str(path) for path in input_dirs],
        "cover_profile": str(cover_profile),
        "functions": str(functions_path),
    }


def _collect_combined_python_coverage(
    combined_dir: Path,
    included: list[dict],
    source_dir: Path,
    *,
    run_command,
) -> dict:
    input_dir = combined_dir / "python-input"
    input_dir.mkdir()
    staged = []
    for item in included:
        runtime_id = item["runtime_id"]
        python_dir = Path(item["python"]["input"])
        shards = sorted(path for path in python_dir.glob(".coverage.*") if path.is_file())
        if not shards:
            base = python_dir / ".coverage"
            if base.is_file():
                shards = [base]
        for index, shard in enumerate(shards):
            destination = input_dir / f".coverage.{runtime_id}.{index:04d}"
            shutil.copy2(shard, destination)
            staged.append(destination)
    if not staged:
        return {
            "status": "missing",
            "reason": "complete runtimes have no Python coverage inputs",
            "input": [],
        }

    combined_data = combined_dir / ".coverage"
    env = os.environ.copy()
    env["COVERAGE_FILE"] = str(combined_data)
    env["COVERAGE_RCFILE"] = str(
        _write_hosted_python_report_config(combined_dir, source_dir)
    )
    coverage_command = [
        "uv",
        "run",
        "--frozen",
        "--extra",
        "coverage",
        "coverage",
    ]
    combine = _run_coverage_command(
        run_command,
        [*coverage_command, "combine", "--keep", str(input_dir)],
        cwd=source_dir,
        env=env,
    )
    _write_process_output(combined_dir / "python-combine-output.txt", combine)
    if combine.returncode != 0:
        return {
            "status": "error",
            "step": "coverage combine",
            "exit_code": combine.returncode,
            "input": [str(path) for path in staged],
        }

    report_path = combined_dir / "python-report.txt"
    report = _run_coverage_command(
        run_command,
        [*coverage_command, "report", "--keep-combined"],
        cwd=source_dir,
        env=env,
    )
    _write_process_output(report_path, report)
    json_path = combined_dir / "python-coverage.json"
    json_report = _run_coverage_command(
        run_command,
        [*coverage_command, "json", "--keep-combined", "-o", str(json_path)],
        cwd=source_dir,
        env=env,
    )
    _write_process_output(combined_dir / "python-json-output.txt", json_report)
    if report.returncode != 0:
        return {
            "status": "error",
            "step": "coverage report",
            "exit_code": report.returncode,
            "input": [str(path) for path in staged],
        }
    if json_report.returncode != 0:
        return {
            "status": "error",
            "step": "coverage json",
            "exit_code": json_report.returncode,
            "input": [str(path) for path in staged],
        }
    validation_error = _python_coverage_validation_error(json_path)
    if validation_error is not None:
        return {
            "status": "error",
            "step": validation_error,
            "exit_code": 1,
            "input": [str(path) for path in staged],
        }
    return {
        "status": "ok",
        "input": [str(path) for path in staged],
        "json": str(json_path),
        "report": str(report_path),
    }


def _collect_hosted_go_coverage(
    runtime_dir: Path,
    source_dir: Path,
    *,
    run_command,
) -> dict:
    go_dir = runtime_dir / "go"
    if not _directory_has_files(go_dir):
        return {
            "status": "missing",
            "reason": "Go coverage data files are missing",
            "input": str(go_dir),
        }

    merged_dir = runtime_dir / "go-merged"
    if merged_dir.exists():
        shutil.rmtree(merged_dir)
    merged_dir.mkdir(parents=True)
    merge = _run_coverage_command(
        run_command,
        [
            "go",
            "tool",
            "covdata",
            "merge",
            f"-i={go_dir}",
            f"-o={merged_dir}",
        ],
        cwd=source_dir,
    )
    _write_process_output(runtime_dir / "go-covdata-merge-output.txt", merge)
    if merge.returncode != 0:
        return _hosted_language_error("go covdata merge", merge.returncode, go_dir)

    cover_profile = runtime_dir / "go.cover.out"
    textfmt = _run_coverage_command(
        run_command,
        [
            "go",
            "tool",
            "covdata",
            "textfmt",
            f"-i={merged_dir}",
            f"-o={cover_profile}",
        ],
        cwd=source_dir,
    )
    _write_process_output(runtime_dir / "go-covdata-textfmt-output.txt", textfmt)
    if textfmt.returncode != 0:
        return _hosted_language_error("go covdata textfmt", textfmt.returncode, go_dir)

    functions_path = runtime_dir / "go-functions.txt"
    functions = _run_coverage_command(
        run_command,
        ["go", "tool", "cover", f"-func={cover_profile}"],
        cwd=source_dir,
    )
    _write_process_output(functions_path, functions)
    if functions.returncode != 0:
        return _hosted_language_error("go cover functions", functions.returncode, go_dir)
    return {
        "status": "ok",
        "input": str(go_dir),
        "cover_profile": str(cover_profile),
        "functions": str(functions_path),
    }


def _collect_hosted_python_coverage(
    runtime_dir: Path,
    source_dir: Path,
    *,
    run_command,
) -> dict:
    python_dir = runtime_dir / "python"
    parallel_data_files = (
        sorted(
            path
            for path in python_dir.glob(".coverage.*")
            if path.is_file()
        )
        if python_dir.is_dir()
        else []
    )
    combined_data_file = python_dir / ".coverage"
    if not parallel_data_files and not combined_data_file.is_file():
        return {
            "status": "missing",
            "reason": "Python coverage data files are missing",
            "input": str(python_dir),
        }

    env = os.environ.copy()
    env["COVERAGE_FILE"] = str(combined_data_file)
    env["COVERAGE_RCFILE"] = str(
        _write_hosted_python_report_config(runtime_dir, source_dir)
    )
    coverage = [
        "uv",
        "run",
        "--frozen",
        "--extra",
        "coverage",
        "coverage",
    ]
    validation_output = []
    validation_files = parallel_data_files or [combined_data_file]
    for data_file in validation_files:
        validation_env = dict(env)
        validation_env["COVERAGE_FILE"] = str(data_file)
        validation = _run_coverage_command(
            run_command,
            [*coverage, "debug", "data"],
            cwd=source_dir,
            env=validation_env,
        )
        validation_output.append(
            f"{data_file.name}: exit={validation.returncode}\n"
            f"{validation.stdout or ''}"
        )
        if validation.returncode != 0:
            (runtime_dir / "python-data-validation-output.txt").write_text(
                "\n".join(validation_output),
                encoding="utf-8",
            )
            return _hosted_language_error(
                "coverage data validation",
                validation.returncode,
                python_dir,
            )
    (runtime_dir / "python-data-validation-output.txt").write_text(
        "\n".join(validation_output),
        encoding="utf-8",
    )
    if parallel_data_files:
        combine = _run_coverage_command(
            run_command,
            [*coverage, "combine", "--keep", str(python_dir)],
            cwd=source_dir,
            env=env,
        )
        _write_process_output(runtime_dir / "python-combine-output.txt", combine)
        if combine.returncode != 0:
            return _hosted_language_error("coverage combine", combine.returncode, python_dir)
    else:
        (runtime_dir / "python-combine-output.txt").write_text(
            "using existing combined coverage data\n",
            encoding="utf-8",
        )

    report_path = runtime_dir / "python-report.txt"
    report = _run_coverage_command(
        run_command,
        [*coverage, "report", "--keep-combined"],
        cwd=source_dir,
        env=env,
    )
    _write_process_output(report_path, report)
    json_path = runtime_dir / "python-coverage.json"
    json_report = _run_coverage_command(
        run_command,
        [*coverage, "json", "--keep-combined", "-o", str(json_path)],
        cwd=source_dir,
        env=env,
    )
    _write_process_output(runtime_dir / "python-json-output.txt", json_report)
    if report.returncode != 0:
        return _hosted_language_error("coverage report", report.returncode, python_dir)
    if json_report.returncode != 0:
        return _hosted_language_error("coverage json", json_report.returncode, python_dir)
    validation_error = _python_coverage_validation_error(json_path)
    if validation_error is not None:
        return _hosted_language_error(validation_error, 1, python_dir)
    return {
        "status": "ok",
        "input": str(python_dir),
        "json": str(json_path),
        "report": str(report_path),
    }


def _directory_has_files(directory: Path) -> bool:
    return directory.is_dir() and any(path.is_file() for path in directory.rglob("*"))


def _write_hosted_python_report_config(runtime_dir: Path, source_dir: Path) -> Path:
    config_path = runtime_dir / "python-report.coveragerc"
    host_source = (source_dir / "strategy_service").resolve()
    config_path.write_text(
        "\n".join(
            [
                "[paths]",
                "source =",
                f"    {host_source}",
                "    /app/strategy-service/strategy_service",
                "    /app/strategy-service/.venv/lib/python*/site-packages/strategy_service",
                "",
            ]
        ),
        encoding="utf-8",
    )
    return config_path


def _python_coverage_validation_error(json_path: Path) -> str | None:
    try:
        document = json.loads(json_path.read_text(encoding="utf-8"))
        covered_lines = document["totals"]["covered_lines"]
    except (OSError, UnicodeError, json.JSONDecodeError, KeyError, TypeError):
        return "coverage json is invalid"
    if isinstance(covered_lines, bool) or not isinstance(covered_lines, int):
        return "coverage json is invalid"
    if covered_lines <= 0:
        return "coverage json has zero covered lines"
    return None


def _run_coverage_command(run_command, command: list[str], *, cwd: Path, env=None):
    kwargs = {
        "cwd": cwd,
        "text": True,
        "stdout": subprocess.PIPE,
        "stderr": subprocess.STDOUT,
    }
    if env is not None:
        kwargs["env"] = env
    try:
        return run_command(command, **kwargs)
    except OSError:
        return subprocess.CompletedProcess(command, -1, stdout="")


def _write_process_output(path: Path, process) -> None:
    path.write_text(process.stdout or "", encoding="utf-8")


def _hosted_language_error(step: str, exit_code: int, input_dir: Path) -> dict:
    return {
        "status": "error",
        "step": step,
        "exit_code": exit_code,
        "input": str(input_dir),
    }


def collect_go_runtime_coverage(ctx, service: dict, out: Path) -> dict:
    gocoverdir = out / "gocoverdir"
    if not gocoverdir.exists() or not any(gocoverdir.iterdir()):
        return {"service": service["name"], "kind": "go_runtime_coverage", "status": "missing", "reason": "gocoverdir is empty", "output": str(out.relative_to(ctx.run_dir))}
    cover_out = out / "runtime.cover.out"
    repo = ctx.workspace / service["path"]
    textfmt = subprocess.run(["go", "tool", "covdata", "textfmt", f"-i={gocoverdir}", f"-o={cover_out}"], cwd=repo, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    (out / "covdata-output.txt").write_text(textfmt.stdout, encoding="utf-8")
    if textfmt.returncode != 0:
        return {"service": service["name"], "kind": "go_runtime_coverage", "status": "error", "exit_code": textfmt.returncode, "output": str(out.relative_to(ctx.run_dir))}
    with (out / "functions.txt").open("w", encoding="utf-8") as fh:
        cover = subprocess.run(["go", "tool", "cover", f"-func={cover_out}"], cwd=repo, text=True, stdout=fh, stderr=subprocess.STDOUT)
    return {"service": service["name"], "kind": "go_runtime_coverage", "status": "ok" if cover.returncode == 0 else "error", "exit_code": cover.returncode, "output": str(out.relative_to(ctx.run_dir))}


def collect_python_runtime_coverage(ctx, service: dict, out: Path) -> dict:
    data_files = list(out.glob(".coverage*"))
    if not data_files:
        return {"service": service["name"], "kind": "python_runtime_coverage", "status": "missing", "reason": "coverage data files are missing", "output": str(out.relative_to(ctx.run_dir))}
    repo = ctx.workspace / service["path"]
    env = os.environ.copy()
    env["COVERAGE_FILE"] = str(out / ".coverage")
    combine = subprocess.run(["uv", "run", "--with", "coverage", "coverage", "combine", str(out)], cwd=repo, env=env, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    (out / "coverage-combine-output.txt").write_text(combine.stdout, encoding="utf-8")
    if combine.returncode != 0:
        return {"service": service["name"], "kind": "python_runtime_coverage", "status": "error", "exit_code": combine.returncode, "output": str(out.relative_to(ctx.run_dir))}
    with (out / "functions.txt").open("w", encoding="utf-8") as fh:
        report = subprocess.run(["uv", "run", "--with", "coverage", "coverage", "report"], cwd=repo, env=env, text=True, stdout=fh, stderr=subprocess.STDOUT)
    json_out = out / "runtime-coverage.json"
    subprocess.run(["uv", "run", "--with", "coverage", "coverage", "json", "-o", str(json_out)], cwd=repo, env=env, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    return {"service": service["name"], "kind": "python_runtime_coverage", "status": "ok" if report.returncode == 0 else "error", "exit_code": report.returncode, "output": str(out.relative_to(ctx.run_dir))}


def generate_runtime_scripts(ctx, cfg) -> list[dict]:
    generated = []
    for service in cfg.services:
        kind = service.get("kind", "")
        if kind not in {"go-service", "python-service"}:
            continue
        out = ctx.run_dir / "coverage" / service["name"] / "runtime"
        out.mkdir(parents=True, exist_ok=True)
        script = out / "run-instrumented.sh"
        if kind == "go-service":
            content = go_runtime_script(ctx, service)
        else:
            content = python_runtime_script(service)
        script.write_text(content, encoding="utf-8")
        script.chmod(0o755)
        generated.append({"service": service["name"], "script": str(script.relative_to(ctx.run_dir))})
    return generated


def go_runtime_script(ctx, service) -> str:
    return f"""#!/usr/bin/env bash
set -euo pipefail
REPO="{ctx.workspace / service['path']}"
OUT_DIR="{ctx.run_dir / 'coverage' / service['name'] / 'runtime'}"
mkdir -p "${{OUT_DIR}}/gocoverdir" "${{OUT_DIR}}/bin"
cd "${{REPO}}"
go build -cover -coverpkg=./... -o "${{OUT_DIR}}/bin/{service['name']}" {service.get('cmd_package', './cmd/' + service['name'])}
GOCOVERDIR="${{OUT_DIR}}/gocoverdir" "${{OUT_DIR}}/bin/{service['name']}" "$@"
"""


def python_runtime_script(service) -> str:
    command = service.get("runtime_command", "python3 -m pytest")
    coverage_command = python_runtime_coverage_command(command)
    return f"""#!/usr/bin/env bash
set -euo pipefail
OUT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$(dirname "$0")/../../../../../{service['path']}"
COVERAGE_FILE="${{OUT_DIR}}/.coverage"
export COVERAGE_FILE
{coverage_command} "$@"
"""


def python_runtime_coverage_command(command: str) -> str:
    parts = shlex.split(command)
    if len(parts) >= 3 and parts[:2] == ["uv", "run"]:
        rest = parts[2:]
        if rest and rest[0] == "hushine-runtime":
            return shlex.join(["uv", "run", "--with", "coverage", "coverage", "run", "--parallel-mode", "-m", "hushine_runtime_cli", *rest[1:]])
        if len(rest) >= 3 and rest[:3] == ["python", "-m", "hushine_runtime_cli"]:
            return shlex.join(["uv", "run", "--with", "coverage", "coverage", "run", "--parallel-mode", "-m", "hushine_runtime_cli", *rest[3:]])
    return f"python3 -m coverage run --parallel-mode {command}"
