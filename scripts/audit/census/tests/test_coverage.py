import json
import os
import subprocess
import sys
import tempfile
import tomllib
import unittest
from pathlib import Path
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from census.coverage import (
    CoverageCollectionFailed,
    collect_hosted_runtime_coverage,
    collect_hosted_runtime_coverage_outputs,
    collect_unit_coverage,
    discover_hosted_runtime_directories,
    normalize_dynamic_coverage,
    python_runtime_script,
    start_session_collectors,
)
from census import coverage
from census.run_context import RunContext


def make_runtime_output(
    root: Path,
    runtime_id: str,
    *,
    go: bool,
    python: bool,
    finalization: str | None = "complete",
) -> Path:
    runtime = root / "runtimes" / runtime_id
    runtime.mkdir(parents=True)
    if go:
        go_dir = runtime / "go"
        go_dir.mkdir()
        (go_dir / "covmeta.fake").write_bytes(b"go coverage")
    if python:
        python_dir = runtime / "python"
        python_dir.mkdir()
        (python_dir / ".coverage.fake").write_bytes(b"python coverage")
    if finalization is not None:
        write_finalization(runtime, state=finalization)
    return runtime


def write_finalization(
    runtime: Path,
    *,
    state: str = "complete",
    runtime_id: str | None = None,
) -> dict:
    if state == "running":
        worker_shutdown = "pending"
        go_snapshot = "pending"
    elif state == "complete":
        worker_shutdown = "ok"
        go_snapshot = "ok"
    else:
        worker_shutdown = "error"
        go_snapshot = "ok"
    marker = {
        "schema_version": 1,
        "runtime_id": runtime_id or runtime.name,
        "boot_id": f"boot-{runtime.name}",
        "state": state,
        "worker_shutdown": worker_shutdown,
        "forced_workers": 0,
        "go_snapshot": go_snapshot,
    }
    if state != "running":
        marker["completed_at"] = "2026-07-12T01:02:03Z"
    (runtime / "finalization.json").write_text(
        json.dumps(marker) + "\n",
        encoding="utf-8",
    )
    return marker


def fake_success_runner(calls: list[list[str]]):
    def run(command, **kwargs):
        command = [str(part) for part in command]
        calls.append(command)
        if command[:4] == ["go", "tool", "covdata", "merge"]:
            output = next(part.removeprefix("-o=") for part in command if part.startswith("-o="))
            Path(output).mkdir(parents=True, exist_ok=True)
        elif command[:4] == ["go", "tool", "covdata", "textfmt"]:
            output = next(part.removeprefix("-o=") for part in command if part.startswith("-o="))
            Path(output).write_text("mode: atomic\n", encoding="utf-8")
        elif "coverage" in command and "combine" in command and kwargs.get("env"):
            Path(kwargs["env"]["COVERAGE_FILE"]).write_bytes(b"combined python coverage")
        elif "coverage" in command and "json" in command:
            output = command[command.index("-o") + 1]
            Path(output).write_text(
                json.dumps({"totals": {"covered_lines": 1}}) + "\n",
                encoding="utf-8",
            )
        return subprocess.CompletedProcess(command, 0, stdout="command output\n")

    return run


class CoverageTests(unittest.TestCase):
    def test_normalized_dynamic_coverage_maps_go_python_and_frontend_subjects(self):
        with tempfile.TemporaryDirectory() as td:
            workspace = Path(td)
            ctx = RunContext.create(
                workspace,
                "census-runs",
                "session-stop",
                "normalized-subjects",
            )
            core = workspace / "core-service"
            core_file = core / "internal/live.go"
            core_file.parent.mkdir(parents=True)
            core_file.write_text("package internal\n", encoding="utf-8")
            (core / "go.mod").write_text(
                "module example.com/hushine/core\n\ngo 1.24\n",
                encoding="utf-8",
            )
            go_out = ctx.run_dir / "coverage/core-service/runtime"
            go_out.mkdir(parents=True)
            (go_out / "runtime.cover.out").write_text(
                "mode: atomic\n"
                "example.com/hushine/core/internal/live.go:1.1,1.18 1 1\n",
                encoding="utf-8",
            )
            (go_out / "functions.txt").write_text(
                "example.com/hushine/core/internal/live.go:1:\tHandle\t100.0%\n"
                "total:\t(statements)\t100.0%\n",
                encoding="utf-8",
            )

            worker = workspace / "strategy-service"
            worker_file = worker / "strategy_service/live.py"
            worker_file.parent.mkdir(parents=True)
            worker_file.write_text("def run():\n    return 1\n", encoding="utf-8")
            python_out = ctx.run_dir / "coverage/session-worker/runtime"
            python_out.mkdir(parents=True)
            (python_out / "runtime-coverage.json").write_text(
                json.dumps(
                    {
                        "files": {
                            "strategy_service/live.py": {
                                "summary": {"covered_lines": 2},
                                "functions": {
                                    "run": {"summary": {"covered_lines": 2}}
                                },
                            }
                        }
                    }
                )
                + "\n",
                encoding="utf-8",
            )

            frontend = workspace / "gateway/quant-frontend"
            frontend_file = frontend / "src/live.ts"
            frontend_file.parent.mkdir(parents=True)
            frontend_file.write_text(
                "export function render() { return true }\n",
                encoding="utf-8",
            )
            ignored_frontend_file = frontend / "src/never.ts"
            ignored_frontend_file.write_text(
                "export function never() { return true }\n",
                encoding="utf-8",
            )
            (ctx.run_dir / "coverage/frontend-owner-waiting.json").write_text(
                json.dumps(
                    {
                        "schema_version": 1,
                        "status": "waiting-for-browser-owner",
                        "browser_id": "browser-1",
                        "tab_id": "tab-1",
                        "target_url": "http://127.0.0.1:5173/",
                        "frontend": "quant-frontend",
                        "ownership": "external-retained-tab",
                    }
                )
                + "\n",
                encoding="utf-8",
            )
            (ctx.run_dir / "coverage/frontend-precise.json").write_text(
                json.dumps(
                    {
                        "schema_version": 1,
                        "browser_id": "browser-1",
                        "tab_id": "tab-1",
                        "frontend_origin": "http://127.0.0.1:5173",
                        "application_script_count": 1,
                        "application_function_count": 1,
                        "application_range_count": 1,
                        "precise_result": {
                            "result": [
                                {
                                    "url": "http://127.0.0.1:5173/src/live.ts",
                                    "functions": [
                                        {
                                            "functionName": "render",
                                            "ranges": [
                                                {
                                                    "startOffset": 0,
                                                    "endOffset": 40,
                                                    "count": 1,
                                                }
                                            ],
                                        }
                                    ],
                                },
                                {
                                    "url": "https://untrusted.example/src/never.ts",
                                    "functions": [
                                        {
                                            "functionName": "never",
                                            "ranges": [
                                                {
                                                    "startOffset": 0,
                                                    "endOffset": 40,
                                                    "count": 1,
                                                }
                                            ],
                                        }
                                    ],
                                },
                            ]
                        },
                    }
                )
                + "\n",
                encoding="utf-8",
            )
            cfg = type(
                "Cfg",
                (),
                {
                    "services": [
                        {
                            "name": "core-service",
                            "path": "core-service",
                            "kind": "go-service",
                        },
                        {
                            "name": "session-worker",
                            "path": "strategy-service",
                            "kind": "python-service",
                        },
                        {
                            "name": "quant-frontend",
                            "path": "gateway/quant-frontend",
                            "kind": "frontend",
                        },
                    ]
                },
            )()

            summary = normalize_dynamic_coverage(
                ctx,
                cfg,
                require_frontend=True,
            )

            subjects = {item["subject"] for item in summary["records"]}

        self.assertEqual(summary["frontend"]["status"], "ok")
        self.assertIn("core-service/internal/live.go", subjects)
        self.assertIn("core-service/internal/live.go::Handle", subjects)
        self.assertIn("strategy-service/strategy_service/live.py", subjects)
        self.assertIn("strategy-service/strategy_service/live.py::run", subjects)
        self.assertIn("gateway/quant-frontend/src/live.ts", subjects)
        self.assertIn("gateway/quant-frontend/src/live.ts::render", subjects)
        self.assertNotIn("gateway/quant-frontend/src/never.ts", subjects)
        self.assertNotIn("gateway/quant-frontend/src/never.ts::never", subjects)

    def test_session_stop_requires_valid_frontend_artifact_for_retained_owner(self):
        with tempfile.TemporaryDirectory() as td:
            workspace = Path(td)
            ctx = RunContext.create(
                workspace,
                "census-runs",
                "session-stop",
                "missing-frontend-coverage",
            )
            (ctx.run_dir / "coverage/frontend-owner-waiting.json").write_text(
                json.dumps(
                    {
                        "schema_version": 1,
                        "status": "waiting-for-browser-owner",
                        "browser_id": "browser-1",
                        "tab_id": "tab-1",
                        "target_url": "http://127.0.0.1:5173/",
                        "frontend": "quant-frontend",
                        "ownership": "external-retained-tab",
                    }
                )
                + "\n",
                encoding="utf-8",
            )
            cfg = type(
                "Cfg",
                (),
                {
                    "services": [
                        {
                            "name": "quant-frontend",
                            "path": "gateway/quant-frontend",
                            "kind": "frontend",
                        }
                    ]
                },
            )()

            with (
                patch.object(
                    coverage,
                    "collect_runtime_coverage_outputs",
                    return_value=[],
                ),
                patch.object(
                    coverage,
                    "finalize_hosted_runtime_containers",
                    return_value=[],
                ),
                patch.object(
                    coverage,
                    "collect_hosted_runtime_coverage_outputs",
                    return_value=[],
                ),
            ):
                with self.assertRaisesRegex(
                    CoverageCollectionFailed,
                    "frontend-precise.json",
                ):
                    coverage.stop_session_collectors(ctx, cfg)

    def test_malformed_frontend_owner_binding_is_a_coverage_failure(self):
        with tempfile.TemporaryDirectory() as td:
            workspace = Path(td)
            ctx = RunContext.create(
                workspace,
                "census-runs",
                "session-stop",
                "malformed-owner-binding",
            )
            (ctx.run_dir / "coverage/frontend-owner-waiting.json").write_text(
                "{not-json}\n",
                encoding="utf-8",
            )
            cfg = type("Cfg", (), {"services": []})()

            with self.assertRaisesRegex(
                CoverageCollectionFailed,
                "browser owner",
            ):
                normalize_dynamic_coverage(ctx, cfg, require_frontend=True)

    def test_atomic_evidence_append_preserves_existing_log_after_short_write(self):
        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            evidence = root / "coverage.jsonl"
            first = {"kind": "first"}
            second = {"kind": "second"}
            evidence.write_text(json.dumps(first) + "\n", encoding="utf-8")
            directory_fd = os.open(root, os.O_RDONLY | os.O_DIRECTORY)
            real_write = coverage.os.write
            writes = 0

            def short_then_fail(descriptor, payload):
                nonlocal writes
                writes += 1
                if writes == 1:
                    prefix = payload[: max(1, len(payload) // 3)]
                    return real_write(descriptor, prefix)
                raise OSError("injected append failure")

            try:
                with patch.object(
                    coverage.os,
                    "write",
                    side_effect=short_then_fail,
                ):
                    with self.assertRaises(OSError):
                        coverage._append_jsonl_at(
                            directory_fd,
                            evidence.name,
                            second,
                        )
            finally:
                os.close(directory_fd)

            contents_after_failure = evidence.read_text(encoding="utf-8")
            parsed_after_failure = [
                json.loads(line)
                for line in contents_after_failure.splitlines()
                if line
            ]

        self.assertGreaterEqual(writes, 2)
        self.assertEqual(parsed_after_failure, [first])

    def test_open_matching_directory_closes_descriptor_when_fstat_fails(self):
        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            target = root / "target"
            target.mkdir()
            expected_identity = coverage._directory_identity(target)
            real_close = coverage.os.close
            closed = []

            def record_close(descriptor):
                closed.append(descriptor)
                return real_close(descriptor)

            with (
                patch.object(
                    coverage.os,
                    "fstat",
                    side_effect=OSError("injected fstat failure"),
                ),
                patch.object(
                    coverage.os,
                    "close",
                    side_effect=record_close,
                ),
            ):
                with self.assertRaises(OSError):
                    coverage._open_matching_directory(
                        root,
                        target,
                        expected_identity,
                    )

        self.assertEqual(len(closed), 1)

    def test_hosted_runtime_invalid_python_shard_is_not_reported_ok(self):
        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            runtime = make_runtime_output(
                root,
                "rt-invalid-python",
                go=True,
                python=True,
            )
            calls = []
            success = fake_success_runner(calls)

            def reject_invalid_shard(command, **kwargs):
                command = [str(part) for part in command]
                if "coverage" in command and command[-2:] == ["debug", "data"]:
                    return subprocess.CompletedProcess(
                        command,
                        1,
                        stdout="Data file is not a coverage data file\n",
                    )
                return success(command, **kwargs)

            result = collect_hosted_runtime_coverage(
                runtime,
                source_dir=root,
                run_command=reject_invalid_shard,
            )
            manifest = json.loads(
                (runtime / "coverage-manifest.json").read_text(encoding="utf-8")
            )

        self.assertEqual(result["status"], "error")
        self.assertEqual(result["python"]["status"], "error")
        self.assertEqual(result["python"]["step"], "coverage data validation")
        self.assertFalse(manifest["combined"]["included"])
        self.assertFalse(
            any("combine" in command for command in calls),
            "invalid shards must be rejected before combine",
        )

    def test_finalize_hosted_runtime_containers_uses_current_run_labels_and_timeout(self):
        with tempfile.TemporaryDirectory() as td:
            workspace = Path(td)
            ctx = RunContext.create(workspace, "census-runs", "session-stop", "run-current")
            hosted_root = ctx.run_dir / "coverage/runtime-agent"
            runtime = make_runtime_output(
                hosted_root,
                "rt-current",
                go=False,
                python=False,
            )
            # Task 9 startup replaces any stale complete marker with running.
            write_finalization(runtime, state="running")
            cfg = type(
                "Cfg",
                (),
                {"hosted_runtime_coverage": {"stop_timeout_seconds": 17}},
            )()
            calls = []

            def run(command, **kwargs):
                command = [str(part) for part in command]
                calls.append((command, kwargs))
                if command[1] == "ps":
                    return subprocess.CompletedProcess(
                        command,
                        0,
                        stdout="abc123def456\trt-current\t42\n",
                        stderr="",
                    )
                return subprocess.CompletedProcess(command, 0, stdout="", stderr="")

            with patch.object(
                coverage.time,
                "sleep",
                side_effect=lambda _seconds: write_finalization(runtime),
            ):
                results = coverage.finalize_hosted_runtime_containers(
                    ctx,
                    cfg,
                    run_command=run,
                )

        list_command = calls[0][0]
        stop_commands = [command for command, _ in calls if command[1] == "stop"]
        self.assertIn("label=hushine.runtime.coverage=true", list_command)
        self.assertIn(
            "label=hushine.runtime.coverage_run_id=run-current",
            list_command,
        )
        self.assertEqual(
            stop_commands,
            [["docker", "stop", "--time", "17", "abc123def456"]],
        )
        self.assertEqual(results[0]["status"], "stopped")
        self.assertEqual(results[0]["runtime_id"], "rt-current")
        self.assertEqual(results[0]["finalization_status"], "complete")
        self.assertNotIn("stdout", results[0])
        self.assertNotIn("stderr", results[0])

    def test_finalize_hosted_runtime_containers_accepts_ui_stopped_complete_marker(self):
        with tempfile.TemporaryDirectory() as td:
            workspace = Path(td)
            ctx = RunContext.create(workspace, "census-runs", "session-stop", "run-current")
            hosted_root = ctx.run_dir / "coverage/runtime-agent"
            make_runtime_output(
                hosted_root,
                "rt-ui-stopped",
                go=True,
                python=True,
            )
            cfg = type(
                "Cfg",
                (),
                {"hosted_runtime_coverage": {"stop_timeout_seconds": 10}},
            )()
            calls = []

            def run(command, **_kwargs):
                command = [str(part) for part in command]
                calls.append(command)
                return subprocess.CompletedProcess(
                    command,
                    0,
                    stdout="",
                    stderr="",
                )

            results = coverage.finalize_hosted_runtime_containers(
                ctx,
                cfg,
                run_command=run,
            )

        self.assertEqual(calls[0][1], "ps")
        self.assertFalse(any(command[1] == "stop" for command in calls))
        self.assertEqual(
            results,
            [
                {
                    "runtime_id": "rt-ui-stopped",
                    "status": "stopped",
                    "exit_code": 0,
                    "finalization_status": "complete",
                    "stop_source": "existing_finalization",
                }
            ],
        )

    def test_finalize_hosted_runtime_containers_rejects_unsafe_and_mismatched_runtime_ids(self):
        with tempfile.TemporaryDirectory() as td:
            workspace = Path(td)
            ctx = RunContext.create(workspace, "census-runs", "session-stop", "run-current")
            hosted_root = ctx.run_dir / "coverage/runtime-agent"
            mismatched = make_runtime_output(
                hosted_root,
                "rt-label",
                go=False,
                python=False,
            )
            write_finalization(mismatched, runtime_id="rt-other")
            cfg = type(
                "Cfg",
                (),
                {"hosted_runtime_coverage": {"stop_timeout_seconds": 10}},
            )()
            calls = []

            def run(command, **kwargs):
                command = [str(part) for part in command]
                calls.append(command)
                return subprocess.CompletedProcess(
                    command,
                    0,
                    stdout=(
                        "abc123def456\t../escape\t42\n"
                        "def456abc123\trt-label\t43\n"
                    ),
                    stderr="",
                )

            results = coverage.finalize_hosted_runtime_containers(
                ctx,
                cfg,
                run_command=run,
            )

        self.assertFalse(any(command[1] == "stop" for command in calls))
        self.assertEqual(
            [item["error_category"] for item in results],
            ["unsafe_runtime_id", "runtime_id_mismatch"],
        )
        self.assertNotIn("../escape", json.dumps(results))

    def test_finalize_hosted_runtime_containers_never_follows_symlinked_runtime_dir(self):
        with tempfile.TemporaryDirectory() as td:
            workspace = Path(td)
            ctx = RunContext.create(
                workspace,
                "census-runs",
                "session-stop",
                "run-current",
            )
            runtime_root = ctx.run_dir / "coverage/runtime-agent/runtimes"
            runtime_root.mkdir(parents=True)
            outside = workspace / "outside-runtime"
            outside.mkdir()
            write_finalization(outside, runtime_id="rt-external")
            (runtime_root / "rt-linked").symlink_to(
                outside,
                target_is_directory=True,
            )
            cfg = type(
                "Cfg",
                (),
                {"hosted_runtime_coverage": {"stop_timeout_seconds": 10}},
            )()
            calls = []

            def run(command, **kwargs):
                command = [str(part) for part in command]
                calls.append(command)
                if command[1] == "ps":
                    return subprocess.CompletedProcess(
                        command,
                        0,
                        stdout="abc123def456\trt-linked\t42\n",
                        stderr="",
                    )
                return subprocess.CompletedProcess(
                    command,
                    0,
                    stdout="",
                    stderr="",
                )

            results = coverage.finalize_hosted_runtime_containers(
                ctx,
                cfg,
                run_command=run,
            )

        self.assertIn(
            ["docker", "stop", "--time", "10", "abc123def456"],
            calls,
        )
        self.assertEqual(results[0]["status"], "stopped")
        self.assertEqual(
            results[0]["error_category"],
            "finalization_path_unsafe",
        )
        self.assertEqual(results[0]["finalization_status"], "path_unsafe")

    def test_finalize_hosted_runtime_containers_records_safe_stop_failure(self):
        with tempfile.TemporaryDirectory() as td:
            workspace = Path(td)
            ctx = RunContext.create(workspace, "census-runs", "session-stop", "run-current")
            hosted_root = ctx.run_dir / "coverage/runtime-agent"
            make_runtime_output(hosted_root, "rt-failed", go=False, python=False)
            cfg = type(
                "Cfg",
                (),
                {"hosted_runtime_coverage": {"stop_timeout_seconds": 10}},
            )()

            def run(command, **kwargs):
                command = [str(part) for part in command]
                if command[1] == "ps":
                    return subprocess.CompletedProcess(
                        command,
                        0,
                        stdout="abc123def456\trt-failed\t42\n",
                        stderr="",
                    )
                return subprocess.CompletedProcess(
                    command,
                    7,
                    stdout="PRIVATE KEY SHOULD NOT SURVIVE",
                    stderr="docker diagnostic should not survive",
                )

            results = coverage.finalize_hosted_runtime_containers(
                ctx,
                cfg,
                run_command=run,
            )

        self.assertEqual(
            results,
            [
                {
                    "container_id": "abc123def456",
                    "runtime_id": "rt-failed",
                    "user_id": 42,
                    "status": "error",
                    "exit_code": 7,
                    "error_category": "docker_stop_failed",
                }
            ],
        )

    def test_finalize_hosted_runtime_containers_stops_after_numeric_marker_parse_failure(self):
        with tempfile.TemporaryDirectory() as td:
            workspace = Path(td)
            ctx = RunContext.create(
                workspace,
                "census-runs",
                "session-stop",
                "numeric-marker",
            )
            runtime = ctx.run_dir / "coverage/runtime-agent/runtimes/rt-numeric"
            runtime.mkdir(parents=True)
            (runtime / "finalization.json").write_text(
                '{"schema_version":' + ("9" * 5000) + "}\n",
                encoding="utf-8",
            )
            cfg = type(
                "Cfg",
                (),
                {"hosted_runtime_coverage": {"stop_timeout_seconds": 10}},
            )()
            calls = []

            def run(command, **_kwargs):
                command = [str(part) for part in command]
                calls.append(command)
                if command[1] == "ps":
                    return subprocess.CompletedProcess(
                        command,
                        0,
                        stdout="abc123def456\trt-numeric\t42\n",
                        stderr="",
                    )
                return subprocess.CompletedProcess(
                    command,
                    0,
                    stdout="",
                    stderr="",
                )

            results = coverage.finalize_hosted_runtime_containers(
                ctx,
                cfg,
                run_command=run,
            )

        self.assertIn(
            ["docker", "stop", "--time", "10", "abc123def456"],
            calls,
        )
        self.assertEqual(results[0]["status"], "stopped")
        self.assertEqual(results[0]["error_category"], "finalization_malformed")
        self.assertEqual(results[0]["finalization_status"], "malformed")

    def test_finalize_hosted_runtime_containers_rejects_oversized_marker_before_parsing(self):
        with tempfile.TemporaryDirectory() as td:
            workspace = Path(td)
            ctx = RunContext.create(
                workspace,
                "census-runs",
                "session-stop",
                "oversized-marker",
            )
            runtime = ctx.run_dir / "coverage/runtime-agent/runtimes/rt-oversized"
            runtime.mkdir(parents=True)
            (runtime / "finalization.json").write_bytes(b"{" + (b" " * 70_000))
            cfg = type(
                "Cfg",
                (),
                {"hosted_runtime_coverage": {"stop_timeout_seconds": 10}},
            )()
            calls = []

            def run(command, **_kwargs):
                command = [str(part) for part in command]
                calls.append(command)
                if command[1] == "ps":
                    return subprocess.CompletedProcess(
                        command,
                        0,
                        stdout="abc123def456\trt-oversized\t42\n",
                        stderr="",
                    )
                return subprocess.CompletedProcess(
                    command,
                    0,
                    stdout="",
                    stderr="",
                )

            with patch.object(
                coverage.json,
                "load",
                side_effect=AssertionError("oversized marker reached JSON parser"),
            ):
                results = coverage.finalize_hosted_runtime_containers(
                    ctx,
                    cfg,
                    run_command=run,
                )

        self.assertIn(
            ["docker", "stop", "--time", "10", "abc123def456"],
            calls,
        )
        self.assertEqual(results[0]["status"], "stopped")
        self.assertEqual(results[0]["error_category"], "finalization_malformed")

    def test_stop_session_finalizes_hosted_containers_before_collecting_reports(self):
        with tempfile.TemporaryDirectory() as td:
            workspace = Path(td)
            ctx = RunContext.create(workspace, "census-runs", "session-stop", "run-current")
            cfg = type("Cfg", (), {"services": []})()
            events = []
            finalization_results = [
                {
                    "runtime_id": "rt-current",
                    "status": "stopped",
                    "exit_code": 0,
                }
            ]
            collected_finalization = []

            def collect_hosted(_ctx, _cfg, *, finalization_results=None):
                events.append("collect")
                collected_finalization.extend(finalization_results or [])
                return []

            with (
                patch.object(coverage.time, "sleep"),
                patch.object(
                    coverage,
                    "collect_runtime_coverage_outputs",
                    return_value=[],
                ),
                patch.object(
                    coverage,
                    "finalize_hosted_runtime_containers",
                    side_effect=lambda *_args, **_kwargs: (
                        events.append("finalize") or finalization_results
                    ),
                ),
                patch.object(
                    coverage,
                    "collect_hosted_runtime_coverage_outputs",
                    side_effect=collect_hosted,
                ),
            ):
                summary = coverage.stop_session_collectors(ctx, cfg)

        self.assertEqual(events, ["finalize", "collect"])
        self.assertEqual(summary["hosted_runtime_finalization"], finalization_results)
        self.assertEqual(collected_finalization, finalization_results)

    def test_stop_session_does_not_publish_after_coverage_root_swap(self):
        with tempfile.TemporaryDirectory() as td:
            workspace = Path(td)
            ctx = RunContext.create(
                workspace,
                "census-runs",
                "session-stop",
                "session-summary-root-swap",
            )
            cfg = type("Cfg", (), {"services": []})()
            coverage_root = ctx.run_dir / "coverage"
            original_coverage = ctx.run_dir / "original-coverage"
            outside_coverage = workspace / "outside-coverage"
            outside_coverage.mkdir()
            outside_summary = outside_coverage / "session-coverage-summary.json"
            outside_summary.write_text(
                "outside session summary must survive\n",
                encoding="utf-8",
            )

            def swap_coverage_root(*_args, **_kwargs):
                coverage_root.rename(original_coverage)
                coverage_root.symlink_to(
                    outside_coverage,
                    target_is_directory=True,
                )
                return []

            with (
                patch.object(coverage.time, "sleep"),
                patch.object(
                    coverage,
                    "collect_runtime_coverage_outputs",
                    return_value=[],
                ),
                patch.object(
                    coverage,
                    "finalize_hosted_runtime_containers",
                    return_value=[],
                ),
                patch.object(
                    coverage,
                    "collect_hosted_runtime_coverage_outputs",
                    side_effect=swap_coverage_root,
                ),
            ):
                summary = coverage.stop_session_collectors(ctx, cfg)
            outside_summary_contents = outside_summary.read_text(encoding="utf-8")

        self.assertEqual(summary["hosted_runtime_coverage"], [])
        self.assertEqual(
            outside_summary_contents,
            "outside session summary must survive\n",
        )

    def test_hosted_runtime_collection_skips_unconfirmed_live_runtime(self):
        failure_cases = (
            None,
            [
                {
                    "runtime_id": "rt-live",
                    "status": "error",
                    "exit_code": 7,
                    "error_category": "docker_stop_failed",
                }
            ],
            [
                {
                    "status": "error",
                    "exit_code": 7,
                    "error_category": "docker_list_failed",
                }
            ],
        )
        for finalization_results in failure_cases:
            with self.subTest(finalization_results=finalization_results), tempfile.TemporaryDirectory() as td:
                workspace = Path(td)
                ctx = RunContext.create(
                    workspace,
                    "census-runs",
                    "session-stop",
                    "unconfirmed-stop",
                )
                hosted_root = ctx.run_dir / "coverage/runtime-agent"
                runtime = make_runtime_output(
                    hosted_root,
                    "rt-live",
                    go=True,
                    python=True,
                )
                outside = workspace / "outside-live-target"
                outside.write_text("must survive\n", encoding="utf-8")
                (runtime / "go.cover.out").symlink_to(outside)
                cfg = type(
                    "Cfg",
                    (),
                    {
                        "services": [
                            {
                                "name": "runtime-agent",
                                "path": "strategy-service",
                                "kind": "go-service",
                            }
                        ]
                    },
                )()
                calls = []

                results = collect_hosted_runtime_coverage_outputs(
                    ctx,
                    cfg,
                    finalization_results=finalization_results,
                    run_command=fake_success_runner(calls),
                )

                self.assertEqual(calls, [])
                self.assertEqual(results[0]["status"], "incomplete")
                self.assertEqual(
                    results[0]["combined"]["error_category"],
                    "runtime_stop_unconfirmed",
                )
                self.assertEqual(
                    outside.read_text(encoding="utf-8"),
                    "must survive\n",
                )
                self.assertTrue((runtime / "go.cover.out").is_symlink())
                self.assertFalse((runtime / "coverage-manifest.json").exists())

    def test_hosted_runtime_collection_requires_a_positive_quiescence_allow_list(self):
        with tempfile.TemporaryDirectory() as td:
            workspace = Path(td)
            ctx = RunContext.create(
                workspace,
                "census-runs",
                "session-stop",
                "empty-stop-snapshot",
            )
            hosted_root = ctx.run_dir / "coverage/runtime-agent"
            make_runtime_output(
                hosted_root,
                "rt-late",
                go=True,
                python=True,
            )
            cfg = type(
                "Cfg",
                (),
                {
                    "services": [
                        {
                            "name": "runtime-agent",
                            "path": "strategy-service",
                            "kind": "go-service",
                        }
                    ]
                },
            )()
            calls = []

            results = collect_hosted_runtime_coverage_outputs(
                ctx,
                cfg,
                finalization_results=[],
                run_command=fake_success_runner(calls),
            )
            combined = json.loads(
                (
                    hosted_root
                    / "hosted-runtime-coverage-combined-summary.json"
                ).read_text(encoding="utf-8")
            )

        self.assertEqual(calls, [])
        self.assertEqual(results[0]["runtime_id"], "rt-late")
        self.assertEqual(results[0]["status"], "incomplete")
        self.assertEqual(
            results[0]["combined"]["error_category"],
            "runtime_stop_unconfirmed",
        )
        self.assertEqual(combined["included_runtime_ids"], [])
        self.assertEqual(combined["status"], "missing")

    def test_hosted_runtime_marker_gate_writes_manifest_for_incomplete_evidence(self):
        cases = ("missing", "running", "malformed", "incomplete")
        for marker_case in cases:
            with self.subTest(marker_case=marker_case), tempfile.TemporaryDirectory() as td:
                runtime = make_runtime_output(
                    Path(td),
                    f"rt-{marker_case}",
                    go=True,
                    python=True,
                    finalization=None,
                )
                if marker_case in {"running", "incomplete"}:
                    write_finalization(runtime, state=marker_case)
                elif marker_case == "malformed":
                    (runtime / "finalization.json").write_text("{not json\n", encoding="utf-8")

                result = collect_hosted_runtime_coverage(
                    runtime,
                    run_command=fake_success_runner([]),
                )
                manifest = json.loads(
                    (runtime / "coverage-manifest.json").read_text(encoding="utf-8")
                )

            self.assertEqual(result["go"]["status"], "ok")
            self.assertEqual(result["python"]["status"], "ok")
            self.assertEqual(result["status"], "incomplete")
            self.assertFalse(manifest["combined"]["included"])
            self.assertEqual(manifest["finalization"]["status"], "incomplete")
            self.assertEqual(
                manifest["finalization"]["error_category"],
                f"finalization_{marker_case}",
            )

    def test_hosted_runtime_complete_marker_enables_combined_inclusion(self):
        with tempfile.TemporaryDirectory() as td:
            runtime = make_runtime_output(Path(td), "rt-complete", go=True, python=True)

            result = collect_hosted_runtime_coverage(
                runtime,
                run_command=fake_success_runner([]),
            )
            manifest = json.loads(
                (runtime / "coverage-manifest.json").read_text(encoding="utf-8")
            )

        self.assertEqual(result["status"], "ok")
        self.assertEqual(result["finalization"]["status"], "ok")
        self.assertEqual(result["finalization"]["marker"]["schema_version"], 1)
        self.assertTrue(manifest["combined"]["included"])

    def test_hosted_runtime_accepts_error_marker_with_forced_count_as_incomplete(self):
        with tempfile.TemporaryDirectory() as td:
            runtime = make_runtime_output(
                Path(td),
                "rt-error-forced",
                go=True,
                python=True,
                finalization="incomplete",
            )
            marker_path = runtime / "finalization.json"
            marker = json.loads(marker_path.read_text(encoding="utf-8"))
            marker["forced_workers"] = 2
            marker_path.write_text(json.dumps(marker) + "\n", encoding="utf-8")

            result = collect_hosted_runtime_coverage(
                runtime,
                run_command=fake_success_runner([]),
            )

        self.assertEqual(result["status"], "incomplete")
        self.assertEqual(
            result["finalization"]["error_category"],
            "finalization_incomplete",
        )

    def test_hosted_runtime_rejects_non_rfc3339_completed_at(self):
        with tempfile.TemporaryDirectory() as td:
            runtime = make_runtime_output(
                Path(td),
                "rt-bad-time",
                go=True,
                python=True,
            )
            marker_path = runtime / "finalization.json"
            marker = json.loads(marker_path.read_text(encoding="utf-8"))
            marker["completed_at"] = "2026-07-12 01:02:03+00:00"
            marker_path.write_text(json.dumps(marker) + "\n", encoding="utf-8")

            result = collect_hosted_runtime_coverage(
                runtime,
                run_command=fake_success_runner([]),
            )

        self.assertEqual(result["status"], "incomplete")
        self.assertEqual(
            result["finalization"]["error_category"],
            "finalization_malformed",
        )

    def test_hosted_runtime_rejects_symlinked_inputs_without_running_commands(self):
        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            runtime = make_runtime_output(
                root,
                "rt-input-link",
                go=True,
                python=True,
            )
            outside = root / "outside-input"
            outside.write_bytes(b"host data must not be read")
            raw_go_file = runtime / "go/covmeta.fake"
            raw_go_file.unlink()
            raw_go_file.symlink_to(outside)
            calls = []

            result = collect_hosted_runtime_coverage(
                runtime,
                run_command=fake_success_runner(calls),
            )

        self.assertEqual(calls, [])
        self.assertEqual(result["status"], "error")
        self.assertEqual(
            result["combined"]["error_category"],
            "unsafe_coverage_path",
        )

    def test_hosted_runtime_rejects_symlinked_outputs_without_clobbering_targets(self):
        output_paths = (
            "coverage-manifest.json",
            "go.cover.out",
            "python-report.coveragerc",
            "python-coverage.json",
        )
        for relative_output in output_paths:
            with self.subTest(relative_output=relative_output), tempfile.TemporaryDirectory() as td:
                root = Path(td)
                runtime = make_runtime_output(
                    root,
                    "rt-output-link",
                    go=True,
                    python=True,
                )
                outside = root / "outside-output"
                outside.write_text("host file must survive\n", encoding="utf-8")
                (runtime / relative_output).symlink_to(outside)
                calls = []

                result = collect_hosted_runtime_coverage(
                    runtime,
                    run_command=fake_success_runner(calls),
                )
                outside_contents = outside.read_text(encoding="utf-8")
                manifest_path = runtime / "coverage-manifest.json"
                manifest_is_regular = manifest_path.is_file() and not manifest_path.is_symlink()

            self.assertEqual(calls, [])
            self.assertEqual(outside_contents, "host file must survive\n")
            self.assertEqual(result["status"], "error")
            self.assertEqual(
                result["combined"]["error_category"],
                "unsafe_coverage_path",
            )
            self.assertTrue(manifest_is_regular)

    def test_hosted_runtime_collection_rejects_symlinked_runtime_agent_ancestor(self):
        with tempfile.TemporaryDirectory() as td:
            workspace = Path(td)
            ctx = RunContext.create(
                workspace,
                "census-runs",
                "session-stop",
                "ancestor-link",
            )
            outside_agent = workspace / "outside-agent"
            runtime = make_runtime_output(
                outside_agent,
                "rt-ancestor",
                go=True,
                python=True,
            )
            stale_combined = outside_agent / "combined"
            stale_combined.mkdir()
            victim = stale_combined / "must-survive.txt"
            victim.write_text("outside data must survive\n", encoding="utf-8")
            (ctx.run_dir / "coverage/runtime-agent").symlink_to(
                outside_agent,
                target_is_directory=True,
            )
            cfg = type(
                "Cfg",
                (),
                {
                    "services": [
                        {
                            "name": "runtime-agent",
                            "path": "strategy-service",
                            "kind": "go-service",
                        }
                    ]
                },
            )()
            calls = []

            results = collect_hosted_runtime_coverage_outputs(
                ctx,
                cfg,
                finalization_results=[
                    {
                        "runtime_id": "rt-ancestor",
                        "status": "stopped",
                        "exit_code": 0,
                    }
                ],
                run_command=fake_success_runner(calls),
            )
            victim_contents = (
                victim.read_text(encoding="utf-8") if victim.exists() else None
            )
            outside_manifest_exists = (runtime / "coverage-manifest.json").exists()

        self.assertEqual(calls, [])
        self.assertEqual(results[0]["status"], "error")
        self.assertEqual(results[0]["error_category"], "unsafe_coverage_path")
        self.assertEqual(victim_contents, "outside data must survive\n")
        self.assertFalse(outside_manifest_exists)

    def test_hosted_runtime_collection_does_not_write_through_coverage_ancestor(self):
        with tempfile.TemporaryDirectory() as td:
            workspace = Path(td)
            ctx = RunContext.create(
                workspace,
                "census-runs",
                "session-stop",
                "coverage-ancestor-link",
            )
            coverage_root = ctx.run_dir / "coverage"
            coverage_root.rmdir()
            outside_coverage = workspace / "outside-coverage"
            outside_coverage.mkdir()
            victim = outside_coverage / "hosted-runtime-coverage-summary.json"
            victim.write_text("outside summary must survive\n", encoding="utf-8")
            coverage_root.symlink_to(outside_coverage, target_is_directory=True)
            cfg = type(
                "Cfg",
                (),
                {
                    "services": [
                        {
                            "name": "runtime-agent",
                            "path": "strategy-service",
                            "kind": "go-service",
                        }
                    ]
                },
            )()
            calls = []

            results = collect_hosted_runtime_coverage_outputs(
                ctx,
                cfg,
                finalization_results=[],
                run_command=fake_success_runner(calls),
            )
            victim_contents = victim.read_text(encoding="utf-8")

        self.assertEqual(calls, [])
        self.assertEqual(results[0]["status"], "error")
        self.assertEqual(results[0]["error_category"], "unsafe_coverage_path")
        self.assertEqual(victim_contents, "outside summary must survive\n")

    def test_hosted_runtime_collection_stages_outputs_before_a_runtime_path_swap(self):
        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            runtime = make_runtime_output(
                root,
                "rt-swap",
                go=True,
                python=True,
            )
            original_runtime = root / "original-runtime"
            outside = root / "outside-runtime"
            outside.mkdir()
            calls = []
            staging_facts = {}

            def swap_during_first_command(command, **_kwargs):
                command = [str(part) for part in command]
                calls.append(command)
                if len(calls) == 1:
                    staged_argument = next(
                        Path(argument.removeprefix("-i=").removeprefix("-o="))
                        for argument in command
                        if ".census-stage-" in argument
                    )
                    staged_root = next(
                        parent
                        for parent in staged_argument.parents
                        if parent.name.startswith(".census-stage-")
                    )
                    staging_facts.update(
                        {
                            "parent": staged_root.parent,
                            "mode": staged_root.stat().st_mode & 0o777,
                        }
                    )
                    runtime.rename(original_runtime)
                    runtime.symlink_to(outside, target_is_directory=True)
                return subprocess.CompletedProcess(
                    command,
                    7,
                    stdout="merge failed safely\n",
                )

            result = collect_hosted_runtime_coverage(
                runtime,
                source_dir=root,
                run_command=swap_during_first_command,
            )
            outside_entries = sorted(path.name for path in outside.iterdir())
            staging_entries = sorted(
                path.name for path in root.iterdir() if path.name.startswith(".census-stage-")
            )

        self.assertTrue(calls)
        self.assertTrue(
            any(".census-stage-" in argument for argument in calls[0]),
            calls[0],
        )
        self.assertEqual(outside_entries, [])
        self.assertEqual(staging_entries, [])
        self.assertEqual(staging_facts, {"parent": root, "mode": 0o700})
        self.assertEqual(result["status"], "error")
        self.assertFalse(result["combined"]["included"])

    def test_hosted_runtime_collection_does_not_write_after_runtime_agent_swap(self):
        with tempfile.TemporaryDirectory() as td:
            workspace = Path(td)
            ctx = RunContext.create(
                workspace,
                "census-runs",
                "session-stop",
                "runtime-agent-swap",
            )
            runtime_agent_root = ctx.run_dir / "coverage/runtime-agent"
            make_runtime_output(
                runtime_agent_root,
                "rt-complete",
                go=True,
                python=True,
            )
            original_agent = ctx.run_dir / "coverage/original-runtime-agent"
            outside_agent = workspace / "outside-runtime-agent"
            outside_runtime = outside_agent / "runtimes/rt-complete"
            outside_runtime.mkdir(parents=True)
            cfg = type(
                "Cfg",
                (),
                {
                    "services": [
                        {
                            "name": "runtime-agent",
                            "path": "strategy-service",
                            "kind": "go-service",
                        }
                    ]
                },
            )()
            calls = []

            publish = coverage._publish_staged_runtime_outputs

            def swap_runtime_agent_before_publish(*args, **kwargs):
                runtime_agent_root.rename(original_agent)
                runtime_agent_root.symlink_to(
                    outside_agent,
                    target_is_directory=True,
                )
                return publish(*args, **kwargs)

            with patch.object(
                coverage,
                "_publish_staged_runtime_outputs",
                side_effect=swap_runtime_agent_before_publish,
            ):
                results = collect_hosted_runtime_coverage_outputs(
                    ctx,
                    cfg,
                    finalization_results=[
                        {
                            "runtime_id": "rt-complete",
                            "status": "stopped",
                            "exit_code": 0,
                        }
                    ],
                    run_command=fake_success_runner(calls),
                )
            outside_entries = sorted(path.name for path in outside_runtime.iterdir())

        self.assertTrue(calls)
        self.assertEqual(results[0]["status"], "error")
        self.assertEqual(outside_entries, [])

    def test_hosted_runtime_collection_handles_runtime_agent_swap_during_command(self):
        with tempfile.TemporaryDirectory() as td:
            workspace = Path(td)
            ctx = RunContext.create(
                workspace,
                "census-runs",
                "session-stop",
                "runtime-agent-command-swap",
            )
            runtime_agent_root = ctx.run_dir / "coverage/runtime-agent"
            make_runtime_output(
                runtime_agent_root,
                "rt-complete",
                go=True,
                python=True,
            )
            original_agent = ctx.run_dir / "coverage/original-runtime-agent"
            outside_agent = workspace / "outside-runtime-agent"
            outside_agent.mkdir()
            cfg = type(
                "Cfg",
                (),
                {
                    "services": [
                        {
                            "name": "runtime-agent",
                            "path": "strategy-service",
                            "kind": "go-service",
                        }
                    ]
                },
            )()
            calls = []

            def swap_runtime_agent_during_first_command(command, **_kwargs):
                command = [str(part) for part in command]
                calls.append(command)
                if len(calls) == 1:
                    runtime_agent_root.rename(original_agent)
                    runtime_agent_root.symlink_to(
                        outside_agent,
                        target_is_directory=True,
                    )
                return subprocess.CompletedProcess(
                    command,
                    7,
                    stdout="merge failed safely\n",
                )

            results = collect_hosted_runtime_coverage_outputs(
                ctx,
                cfg,
                finalization_results=[
                    {
                        "runtime_id": "rt-complete",
                        "status": "stopped",
                        "exit_code": 0,
                    }
                ],
                run_command=swap_runtime_agent_during_first_command,
            )
            outside_entries = sorted(path.name for path in outside_agent.iterdir())
            staged_entries = sorted(
                path.name
                for path in original_agent.iterdir()
                if path.name.startswith(".census-stage-")
            )

        self.assertTrue(calls)
        self.assertEqual(results[0]["status"], "error")
        self.assertEqual(outside_entries, [])
        self.assertEqual(staged_entries, [])

    def test_hosted_runtime_collection_does_not_publish_after_coverage_root_swap(self):
        with tempfile.TemporaryDirectory() as td:
            workspace = Path(td)
            ctx = RunContext.create(
                workspace,
                "census-runs",
                "session-stop",
                "coverage-root-swap",
            )
            coverage_root = ctx.run_dir / "coverage"
            runtime_agent_root = coverage_root / "runtime-agent"
            make_runtime_output(
                runtime_agent_root,
                "rt-complete",
                go=True,
                python=True,
            )
            original_coverage = ctx.run_dir / "original-coverage"
            outside_coverage = workspace / "outside-coverage"
            outside_runtime = (
                outside_coverage / "runtime-agent/runtimes/rt-complete"
            )
            outside_runtime.mkdir(parents=True)
            outside_summary = (
                outside_coverage / "hosted-runtime-coverage-summary.json"
            )
            outside_summary.write_text(
                "outside summary must survive\n",
                encoding="utf-8",
            )
            cfg = type(
                "Cfg",
                (),
                {
                    "services": [
                        {
                            "name": "runtime-agent",
                            "path": "strategy-service",
                            "kind": "go-service",
                        }
                    ]
                },
            )()
            calls = []

            publish = coverage._publish_staged_runtime_outputs

            def swap_coverage_before_publish(*args, **kwargs):
                coverage_root.rename(original_coverage)
                coverage_root.symlink_to(
                    outside_coverage,
                    target_is_directory=True,
                )
                return publish(*args, **kwargs)

            with patch.object(
                coverage,
                "_publish_staged_runtime_outputs",
                side_effect=swap_coverage_before_publish,
            ):
                results = collect_hosted_runtime_coverage_outputs(
                    ctx,
                    cfg,
                    finalization_results=[
                        {
                            "runtime_id": "rt-complete",
                            "status": "stopped",
                            "exit_code": 0,
                        }
                    ],
                    run_command=fake_success_runner(calls),
                )
            outside_runtime_entries = sorted(
                path.name for path in outside_runtime.iterdir()
            )
            outside_summary_contents = outside_summary.read_text(encoding="utf-8")

        self.assertTrue(calls)
        self.assertEqual(results[0]["status"], "error")
        self.assertEqual(outside_runtime_entries, [])
        self.assertEqual(
            outside_summary_contents,
            "outside summary must survive\n",
        )

    def test_combined_reports_include_only_complete_runtimes_and_preserve_raw_inputs(self):
        with tempfile.TemporaryDirectory() as td:
            workspace = Path(td)
            ctx = RunContext.create(workspace, "census-runs", "session-stop", "combined")
            hosted_root = ctx.run_dir / "coverage/runtime-agent"
            first = make_runtime_output(hosted_root, "rt-a", go=True, python=True)
            second = make_runtime_output(hosted_root, "rt-b", go=True, python=True)
            excluded = make_runtime_output(
                hosted_root,
                "rt-incomplete",
                go=True,
                python=True,
                finalization="incomplete",
            )
            stale_output = hosted_root / "combined/stale-output.txt"
            stale_output.parent.mkdir(parents=True)
            stale_output.write_text("stale", encoding="utf-8")
            cfg = type(
                "Cfg",
                (),
                {
                    "services": [
                        {
                            "name": "runtime-agent",
                            "path": "strategy-service",
                            "kind": "go-service",
                        }
                    ]
                },
            )()
            calls = []

            results = collect_hosted_runtime_coverage_outputs(
                ctx,
                cfg,
                finalization_results=[
                    {"runtime_id": runtime_id, "status": "stopped", "exit_code": 0}
                    for runtime_id in ("rt-a", "rt-b", "rt-incomplete")
                ],
                run_command=fake_success_runner(calls),
            )
            combined_summary = json.loads(
                (
                    hosted_root
                    / "hosted-runtime-coverage-combined-summary.json"
                ).read_text(encoding="utf-8")
            )
            combined_dir = hosted_root / "combined"

            combined_go_merge = next(
                command
                for command in calls
                if command[:4] == ["go", "tool", "covdata", "merge"]
                and any(
                    ".census-combined-stage-" in part
                    and part.endswith("/combined/go")
                    for part in command
                )
            )
            combined_python = next(
                command
                for command in calls
                if "coverage" in command
                and "combine" in command
                and any(
                    ".census-combined-stage-" in part
                    and part.endswith("/combined/python-input")
                    for part in command
                )
            )
            staged = sorted(path.name for path in (combined_dir / "python-input").iterdir())
            raw_files_preserved = all(
                (runtime / "python/.coverage.fake").is_file()
                for runtime in (first, second, excluded)
            )
            outputs_nonempty = all(
                path.is_file() and path.stat().st_size > 0
                for path in (
                    combined_dir / "go.cover.out",
                    combined_dir / "go-functions.txt",
                    combined_dir / "python-report.txt",
                    combined_dir / "python-coverage.json",
                )
            )

        self.assertEqual([item["runtime_id"] for item in results], ["rt-a", "rt-b", "rt-incomplete"])
        self.assertEqual(combined_summary["status"], "ok")
        self.assertEqual(combined_summary["included_runtime_ids"], ["rt-a", "rt-b"])
        self.assertEqual(
            combined_summary["excluded"],
            [
                {
                    "runtime_id": "rt-incomplete",
                    "error_category": "finalization_incomplete",
                }
            ],
        )
        go_inputs = next(
            part.removeprefix("-i=")
            for part in combined_go_merge
            if part.startswith("-i=")
        ).split(",")
        self.assertEqual(go_inputs, [str(first / "go"), str(second / "go")])
        self.assertNotIn(str(excluded / "go"), combined_go_merge)
        self.assertIn("--frozen", combined_python)
        self.assertEqual(staged, [".coverage.rt-a.0000", ".coverage.rt-b.0000"])
        self.assertTrue(raw_files_preserved)
        self.assertTrue(outputs_nonempty)
        self.assertFalse(stale_output.exists())

    def test_combined_report_launch_failure_replaces_stale_ok_summary(self):
        with tempfile.TemporaryDirectory() as td:
            workspace = Path(td)
            ctx = RunContext.create(workspace, "census-runs", "session-stop", "combined-fail")
            hosted_root = ctx.run_dir / "coverage/runtime-agent"
            make_runtime_output(hosted_root, "rt-complete", go=True, python=True)
            combined_dir = hosted_root / "combined"
            combined_dir.mkdir(parents=True)
            (combined_dir / "stale-output.txt").write_text("stale\n", encoding="utf-8")
            summary_path = hosted_root / "hosted-runtime-coverage-combined-summary.json"
            summary_path.write_text(
                json.dumps({"kind": "hosted_runtime_coverage_combined", "status": "ok"})
                + "\n",
                encoding="utf-8",
            )
            cfg = type(
                "Cfg",
                (),
                {
                    "services": [
                        {
                            "name": "runtime-agent",
                            "path": "strategy-service",
                            "kind": "go-service",
                        }
                    ]
                },
            )()
            calls = []
            success = fake_success_runner(calls)

            def fail_combined_launch(command, **kwargs):
                command = [str(part) for part in command]
                go_input = next(
                    (part for part in command if part.startswith("-i=")),
                    "",
                )
                if (
                    command[:4] == ["go", "tool", "covdata", "merge"]
                    and "/runtimes/rt-complete/go" in go_input
                    and ".census-stage-" not in go_input
                ):
                    raise FileNotFoundError("sensitive launcher detail")
                return success(command, **kwargs)

            collect_hosted_runtime_coverage_outputs(
                ctx,
                cfg,
                finalization_results=[
                    {
                        "runtime_id": "rt-complete",
                        "status": "stopped",
                        "exit_code": 0,
                    }
                ],
                run_command=fail_combined_launch,
            )
            summary = json.loads(summary_path.read_text(encoding="utf-8"))

        self.assertEqual(summary["status"], "error")
        self.assertEqual(summary["go"]["status"], "error")
        self.assertEqual(summary["go"]["exit_code"], -1)
        self.assertNotIn("sensitive launcher detail", json.dumps(summary))

    def test_combined_collection_stages_before_runtime_agent_root_swap(self):
        with tempfile.TemporaryDirectory() as td:
            workspace = Path(td)
            ctx = RunContext.create(
                workspace,
                "census-runs",
                "session-stop",
                "combined-root-swap",
            )
            hosted_root = ctx.run_dir / "coverage/runtime-agent"
            make_runtime_output(
                hosted_root,
                "rt-complete",
                go=True,
                python=True,
            )
            original_agent = ctx.run_dir / "coverage/original-runtime-agent"
            outside_agent = workspace / "outside-agent"
            outside_combined = outside_agent / "combined"
            outside_combined.mkdir(parents=True)
            canary = outside_combined / "must-survive.txt"
            canary.write_text("outside combined must survive\n", encoding="utf-8")
            outside_summary = (
                outside_agent / "hosted-runtime-coverage-combined-summary.json"
            )
            outside_summary.write_text("outside summary must survive\n", encoding="utf-8")
            cfg = type(
                "Cfg",
                (),
                {
                    "services": [
                        {
                            "name": "runtime-agent",
                            "path": "strategy-service",
                            "kind": "go-service",
                        }
                    ]
                },
            )()
            calls = []
            success = fake_success_runner(calls)
            combined_call = None

            def swap_during_combined(command, **kwargs):
                nonlocal combined_call
                command = [str(part) for part in command]
                go_input = next(
                    (part for part in command if part.startswith("-i=")),
                    "",
                )
                is_combined = (
                    command[:4] == ["go", "tool", "covdata", "merge"]
                    and "/runtimes/rt-complete/go" in go_input
                    and ".census-stage-" not in go_input
                )
                if is_combined and combined_call is None:
                    calls.append(command)
                    combined_call = command
                    hosted_root.rename(original_agent)
                    hosted_root.symlink_to(outside_agent, target_is_directory=True)
                    return subprocess.CompletedProcess(
                        command,
                        7,
                        stdout="combined merge failed safely\n",
                    )
                return success(command, **kwargs)

            collect_hosted_runtime_coverage_outputs(
                ctx,
                cfg,
                finalization_results=[
                    {
                        "runtime_id": "rt-complete",
                        "status": "stopped",
                        "exit_code": 0,
                    }
                ],
                run_command=swap_during_combined,
            )
            outside_entries = sorted(path.name for path in outside_combined.iterdir())
            outside_summary_contents = outside_summary.read_text(encoding="utf-8")
            stage_entries = sorted(
                path.name
                for path in (ctx.run_dir / "coverage").iterdir()
                if path.name.startswith(".census-combined-stage-")
            )

        self.assertIsNotNone(combined_call)
        self.assertTrue(
            any(".census-combined-stage-" in part for part in combined_call),
            combined_call,
        )
        self.assertEqual(outside_entries, ["must-survive.txt"])
        self.assertEqual(outside_summary_contents, "outside summary must survive\n")
        self.assertEqual(stage_entries, [])

    def test_combined_collection_cleans_stage_after_coverage_root_swap(self):
        with tempfile.TemporaryDirectory() as td:
            workspace = Path(td)
            ctx = RunContext.create(
                workspace,
                "census-runs",
                "session-stop",
                "combined-coverage-root-swap",
            )
            coverage_root = ctx.run_dir / "coverage"
            runtime_agent_root = coverage_root / "runtime-agent"
            make_runtime_output(
                runtime_agent_root,
                "rt-complete",
                go=True,
                python=True,
            )
            original_coverage = ctx.run_dir / "original-coverage"
            outside_coverage = workspace / "outside-coverage"
            outside_coverage.mkdir()
            cfg = type(
                "Cfg",
                (),
                {
                    "services": [
                        {
                            "name": "runtime-agent",
                            "path": "strategy-service",
                            "kind": "go-service",
                        }
                    ]
                },
            )()
            calls = []
            success = fake_success_runner(calls)
            combined_call = None

            def swap_coverage_during_combined(command, **kwargs):
                nonlocal combined_call
                command = [str(part) for part in command]
                go_input = next(
                    (part for part in command if part.startswith("-i=")),
                    "",
                )
                is_combined = (
                    command[:4] == ["go", "tool", "covdata", "merge"]
                    and "/runtimes/rt-complete/go" in go_input
                    and ".census-stage-" not in go_input
                )
                if is_combined and combined_call is None:
                    calls.append(command)
                    combined_call = command
                    coverage_root.rename(original_coverage)
                    coverage_root.symlink_to(
                        outside_coverage,
                        target_is_directory=True,
                    )
                    return subprocess.CompletedProcess(
                        command,
                        7,
                        stdout="combined merge failed safely\n",
                    )
                return success(command, **kwargs)

            collect_hosted_runtime_coverage_outputs(
                ctx,
                cfg,
                finalization_results=[
                    {
                        "runtime_id": "rt-complete",
                        "status": "stopped",
                        "exit_code": 0,
                    }
                ],
                run_command=swap_coverage_during_combined,
            )
            stage_entries = sorted(
                path.name
                for path in original_coverage.iterdir()
                if path.name.startswith(".census-combined-stage-")
            )
            outside_entries = sorted(path.name for path in outside_coverage.iterdir())

        self.assertIsNotNone(combined_call)
        self.assertEqual(stage_entries, [])
        self.assertEqual(outside_entries, [])

    def test_combined_reports_are_explicitly_missing_when_no_runtime_is_complete(self):
        with tempfile.TemporaryDirectory() as td:
            workspace = Path(td)
            ctx = RunContext.create(workspace, "census-runs", "session-stop", "combined-empty")
            hosted_root = ctx.run_dir / "coverage/runtime-agent"
            make_runtime_output(
                hosted_root,
                "rt-incomplete",
                go=True,
                python=True,
                finalization="incomplete",
            )
            cfg = type(
                "Cfg",
                (),
                {
                    "services": [
                        {
                            "name": "runtime-agent",
                            "path": "strategy-service",
                            "kind": "go-service",
                        }
                    ]
                },
            )()
            calls = []

            collect_hosted_runtime_coverage_outputs(
                ctx,
                cfg,
                finalization_results=[
                    {
                        "runtime_id": "rt-incomplete",
                        "status": "stopped",
                        "exit_code": 0,
                    }
                ],
                run_command=fake_success_runner(calls),
            )
            combined_summary = json.loads(
                (
                    hosted_root
                    / "hosted-runtime-coverage-combined-summary.json"
                ).read_text(encoding="utf-8")
            )

        self.assertEqual(combined_summary["status"], "missing")
        self.assertEqual(combined_summary["included_runtime_ids"], [])
        self.assertEqual(combined_summary["go"]["status"], "missing")
        self.assertEqual(combined_summary["python"]["status"], "missing")
        self.assertFalse(
            any("/combined/" in " ".join(command) for command in calls),
            calls,
        )

    def test_collect_unit_coverage_raises_when_a_repo_fails(self):
        with tempfile.TemporaryDirectory() as td:
            workspace = Path(td)
            ctx = RunContext.create(workspace, "census-runs", "full", "coverage-failure")
            repo = workspace / "python-repo"
            tests = repo / "tests"
            tests.mkdir(parents=True)
            (tests / "test_failure.py").write_text(
                "def test_failure():\n    assert False\n",
                encoding="utf-8",
            )
            cfg = type(
                "Cfg",
                (),
                {
                    "services": [
                        {
                            "name": "python-repo",
                            "path": "python-repo",
                            "kind": "python-library",
                            "unit_command": "uv run --isolated --no-project --with pytest pytest tests -q",
                        }
                    ]
                },
            )()

            with self.assertRaises(CoverageCollectionFailed) as caught:
                collect_unit_coverage(ctx, cfg)

            self.assertIn("python-repo", str(caught.exception))
            self.assertTrue((ctx.run_dir / "coverage/unit-coverage-summary.json").exists())

    def test_resolve_uv_executable_falls_back_to_home_local_bin(self):
        with tempfile.TemporaryDirectory() as td:
            home = Path(td)
            uv = home / ".local" / "bin" / ("uv.exe" if os.name == "nt" else "uv")
            uv.parent.mkdir(parents=True)
            uv.write_text("", encoding="utf-8")
            uv.chmod(0o700)

            resolved = coverage.resolve_uv_executable(
                {"HOME": str(home), "PATH": str(home / "empty-path")}
            )

        self.assertEqual(resolved, str(uv.resolve()))

    def test_resolve_uv_executable_rejects_missing_configured_override(self):
        with tempfile.TemporaryDirectory() as td:
            with self.assertRaises(CoverageCollectionFailed) as caught:
                coverage.resolve_uv_executable(
                    {
                        "HOME": td,
                        "PATH": str(Path(td) / "empty-path"),
                        "UV_BIN": str(Path(td) / "missing-uv"),
                    }
                )

        self.assertIn("configured uv executable was not found", str(caught.exception))

    def test_collect_unit_coverage_includes_every_frontend_contract(self):
        with tempfile.TemporaryDirectory() as td:
            workspace = Path(td)
            repo = workspace / "gateway/quant-frontend"
            scripts = repo / "scripts"
            scripts.mkdir(parents=True)
            (scripts / "a.test.mjs").write_text("", encoding="utf-8")
            (scripts / "b.test.mjs").write_text("", encoding="utf-8")
            ctx = RunContext.create(
                workspace,
                "census-runs",
                "unit-coverage",
                "frontend-unit",
            )
            cfg = type(
                "Cfg",
                (),
                {
                    "services": [
                        {
                            "name": "quant-frontend",
                            "path": "gateway/quant-frontend",
                            "kind": "frontend",
                        }
                    ]
                },
            )()
            calls = []

            def successful(command, **kwargs):
                calls.append((command, kwargs))
                return subprocess.CompletedProcess(command, 0, stdout="ok\n")

            with patch.object(coverage.subprocess, "run", side_effect=successful):
                results = collect_unit_coverage(ctx, cfg)

            registry = json.loads(
                (
                    ctx.run_dir
                    / "coverage/quant-frontend/unit/contract-registry.json"
                ).read_text(encoding="utf-8")
            )

        self.assertEqual(results[0]["kind"], "frontend_unit_coverage")
        self.assertEqual(
            [call[0] for call in calls],
            [
                ["npm", "run", "build"],
                ["node", "scripts/a.test.mjs"],
                ["node", "scripts/b.test.mjs"],
            ],
        )
        self.assertEqual(registry["contracts"], ["scripts/a.test.mjs", "scripts/b.test.mjs"])
        for _command, kwargs in calls[1:]:
            self.assertIn("NODE_V8_COVERAGE", kwargs["env"])

    def test_python_unit_coverage_produces_a_valid_reportable_shard(self):
        with tempfile.TemporaryDirectory() as td:
            workspace = Path(td)
            repo = workspace / "strategy-service"
            repo.mkdir()
            ctx = RunContext.create(
                workspace,
                "census-runs",
                "unit-coverage",
                "python-covered",
            )
            service = {
                "name": "session-worker",
                "path": "strategy-service",
                "kind": "python-library",
                "unit_command": "PYTHONPATH=.:../strategy-library uv run --frozen --extra dev pytest tests/ -q",
            }
            calls = []

            def successful(command, **kwargs):
                calls.append((command, kwargs))
                coverage_file = Path(kwargs["env"]["COVERAGE_FILE"])
                if isinstance(command, list) and any(
                    command[index : index + 2] == ["coverage", "run"]
                    for index in range(len(command) - 1)
                ):
                    coverage_file.with_name(coverage_file.name + ".fake").write_bytes(
                        b"parallel coverage"
                    )
                elif isinstance(command, list) and "combine" in command:
                    coverage_file.write_bytes(b"combined coverage")
                elif isinstance(command, list) and "json" in command:
                    Path(command[command.index("-o") + 1]).write_text(
                        "{}\n", encoding="utf-8"
                    )
                return subprocess.CompletedProcess(command, 0, stdout="ok\n")

            with patch.object(coverage.subprocess, "run", side_effect=successful):
                result = coverage.run_python_unit_coverage(ctx, service)

            out = ctx.run_dir / "coverage/session-worker/unit"

        self.assertEqual(result["exit_code"], 0)
        self.assertEqual(result["coverage_status"], "ok")
        self.assertEqual(
            calls[0][0],
            [
                coverage.resolve_uv_executable(),
                "run", "--frozen", "--extra", "dev", "--with", "coverage",
                "coverage", "run", "--parallel-mode", "-m", "pytest", "tests/", "-q",
            ],
        )
        self.assertEqual(calls[0][1]["env"]["COVERAGE_FILE"], str(out / ".coverage"))
        self.assertTrue(any(isinstance(command, list) and "combine" in command for command, _ in calls))
        self.assertTrue(any(isinstance(command, list) and "report" in command for command, _ in calls))
        self.assertTrue(any(isinstance(command, list) and "json" in command for command, _ in calls))
        report_command = next(command for command, _ in calls if "report" in command)
        json_command = next(command for command, _ in calls if "json" in command)
        self.assertIn("--ignore-errors", report_command)
        self.assertIn("--ignore-errors", json_command)

    def test_python_runtime_script_runs_coverage_inside_uv_environment(self):
        script = python_runtime_script({
            "path": "strategy-service",
            "runtime_command": "uv run python -m hushine_runtime_cli start --config ./config.yaml",
        })

        self.assertIn("uv run --with coverage coverage run --parallel-mode -m hushine_runtime_cli", script)
        self.assertNotIn("python3 -m coverage run --parallel-mode uv run", script)
        self.assertIn('COVERAGE_FILE="${OUT_DIR}/.coverage"', script)
        self.assertIn('"$@"', script)

    def test_hosted_runtime_collects_go_and_python_reports(self):
        with tempfile.TemporaryDirectory() as td:
            runtime = make_runtime_output(Path(td), "rt-1", go=True, python=True)
            calls = []

            result = collect_hosted_runtime_coverage(
                runtime,
                source_dir=Path(td) / "strategy-service",
                run_command=fake_success_runner(calls),
            )

            self.assertEqual(result["runtime_id"], "rt-1")
            self.assertEqual(result["status"], "ok")
            self.assertEqual(result["go"]["status"], "ok")
            self.assertEqual(result["python"]["status"], "ok")
            self.assertTrue((runtime / "go.cover.out").is_file())
            self.assertTrue((runtime / "go-functions.txt").is_file())
            self.assertTrue((runtime / "python-coverage.json").is_file())
            self.assertTrue((runtime / "python-report.txt").is_file())

        commands = [" ".join(command) for command in calls]
        self.assertTrue(any("go tool covdata merge" in command for command in commands))
        self.assertTrue(any("go tool covdata textfmt" in command for command in commands))
        self.assertTrue(any("go tool cover" in command for command in commands))
        self.assertTrue(any("coverage combine" in command for command in commands))
        self.assertTrue(any("coverage report" in command for command in commands))
        self.assertTrue(any("coverage json" in command for command in commands))

    def test_hosted_python_per_runtime_commands_use_locked_environment(self):
        with tempfile.TemporaryDirectory() as td:
            runtime = make_runtime_output(
                Path(td),
                "rt-locked-python",
                go=False,
                python=True,
            )
            calls = []

            result = collect_hosted_runtime_coverage(
                runtime,
                source_dir=Path(td) / "strategy-service",
                run_command=fake_success_runner(calls),
            )

        locked_prefix = [
            coverage.resolve_uv_executable(),
            "run",
            "--frozen",
            "--extra",
            "coverage",
            "coverage",
        ]
        expected_operations = [
            ["debug", "data"],
            ["combine", "--keep"],
            ["report", "--keep-combined"],
            ["json", "--keep-combined"],
        ]
        self.assertEqual(result["python"]["status"], "ok")
        self.assertEqual(len(calls), len(expected_operations), calls)
        for command, operation in zip(calls, expected_operations, strict=True):
            with self.subTest(operation=operation[0]):
                self.assertEqual(command[: len(locked_prefix)], locked_prefix)
                self.assertEqual(
                    command[len(locked_prefix) : len(locked_prefix) + len(operation)],
                    operation,
                )
                self.assertNotIn("--with", command)

    def test_hosted_runtime_missing_python_is_reported(self):
        with tempfile.TemporaryDirectory() as td:
            runtime = make_runtime_output(Path(td), "rt-1", go=True, python=False)

            result = collect_hosted_runtime_coverage(
                runtime,
                run_command=fake_success_runner([]),
            )

        self.assertEqual(result["go"]["status"], "ok")
        self.assertEqual(result["python"]["status"], "missing")
        self.assertEqual(result["status"], "incomplete")

    def test_hosted_runtime_zero_hit_python_report_is_rejected(self):
        with tempfile.TemporaryDirectory() as td:
            runtime = make_runtime_output(Path(td), "rt-zero", go=True, python=True)
            calls = []
            success = fake_success_runner(calls)

            def zero_hit_runner(command, **kwargs):
                result = success(command, **kwargs)
                command = [str(part) for part in command]
                if "coverage" in command and "json" in command:
                    output = Path(command[command.index("-o") + 1])
                    output.write_text(
                        json.dumps({"totals": {"covered_lines": 0}}) + "\n",
                        encoding="utf-8",
                    )
                return result

            result = collect_hosted_runtime_coverage(
                runtime,
                source_dir=Path(td) / "strategy-service",
                run_command=zero_hit_runner,
            )

        self.assertEqual(result["status"], "error")
        self.assertEqual(result["python"]["status"], "error")
        self.assertEqual(result["python"]["step"], "coverage json has zero covered lines")

    def test_hosted_python_report_remaps_container_source_paths(self):
        try:
            uv_executable = coverage.resolve_uv_executable()
        except CoverageCollectionFailed as exc:
            self.skipTest(str(exc))
        tool_root = Path(__file__).resolve().parents[5]
        source_root = Path(os.environ.get("CODE_CENSUS_SOURCE_ROOT", tool_root))
        source_dir = source_root / "strategy-service"
        lock_path = source_dir / "uv.lock"
        if not lock_path.is_file():
            self.skipTest(f"managed strategy-service uv.lock is missing: {lock_path}")
        project_path = source_dir / "pyproject.toml"
        if not project_path.is_file():
            self.skipTest(
                f"managed strategy-service pyproject.toml is missing: {project_path}"
            )
        project = tomllib.loads(project_path.read_text(encoding="utf-8"))
        coverage_extra = (
            project.get("project", {})
            .get("optional-dependencies", {})
            .get("coverage")
        )
        if not coverage_extra:
            self.skipTest(
                "managed strategy-service coverage extra is missing: "
                f"{project_path}"
            )
        source_path = Path("strategy_service/types.py")
        self.assertTrue(
            (source_dir / source_path).is_file(),
            f"managed strategy-service source is missing: {source_dir / source_path}",
        )

        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            runtime = make_runtime_output(root, "rt-container-path", go=False, python=False)
            python_dir = runtime / "python"
            python_dir.mkdir()
            data_file = python_dir / ".coverage.container"
            container_file = f"/app/strategy-service/{source_path.as_posix()}"
            create_data = (
                "from coverage import CoverageData; "
                f"data = CoverageData(basename={str(data_file)!r}); "
                f"data.add_lines({{{container_file!r}: {{3}}}}); "
                "data.write()"
            )
            generated = subprocess.run(
                [
                    uv_executable,
                    "run",
                    "--frozen",
                    "--extra",
                    "coverage",
                    "python",
                    "-c",
                    create_data,
                ],
                cwd=source_dir,
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
            )
            self.assertEqual(generated.returncode, 0, generated.stdout)

            result = collect_hosted_runtime_coverage(runtime, source_dir=source_dir)
            raw_data_preserved_after_first = data_file.exists()
            files_after_first = sorted(path.name for path in python_dir.iterdir())
            retry = collect_hosted_runtime_coverage(runtime, source_dir=source_dir)

            report = (runtime / "python-report.txt").read_text(encoding="utf-8")
            raw_data_preserved = data_file.exists()

        self.assertEqual(result["python"]["status"], "ok", (result, report))
        self.assertEqual(retry["python"]["status"], "ok", (retry, report))
        self.assertTrue(raw_data_preserved_after_first, files_after_first)
        self.assertTrue(raw_data_preserved)
        self.assertIn(source_path.as_posix(), report)

    def test_hosted_python_report_remaps_isolated_venv_source_paths(self):
        try:
            uv_executable = coverage.resolve_uv_executable()
        except CoverageCollectionFailed as exc:
            self.skipTest(str(exc))
        tool_root = Path(__file__).resolve().parents[5]
        source_root = Path(os.environ.get("CODE_CENSUS_SOURCE_ROOT", tool_root))
        source_dir = source_root / "strategy-service"
        source_path = Path("strategy_service/types.py")
        self.assertTrue((source_dir / source_path).is_file())

        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            runtime = make_runtime_output(root, "rt-isolated-path", go=False, python=False)
            python_dir = runtime / "python"
            python_dir.mkdir()
            data_file = python_dir / ".coverage.container"
            installed_file = (
                "/app/strategy-service/.venv/lib/python3.13/site-packages/"
                f"{source_path.as_posix()}"
            )
            create_data = (
                "from coverage import CoverageData; "
                f"data = CoverageData(basename={str(data_file)!r}); "
                f"data.add_lines({{{installed_file!r}: {{3}}}}); "
                "data.write()"
            )
            generated = subprocess.run(
                [
                    uv_executable, "run", "--frozen", "--extra", "coverage",
                    "python", "-c", create_data,
                ],
                cwd=source_dir,
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
            )
            self.assertEqual(generated.returncode, 0, generated.stdout)

            result = collect_hosted_runtime_coverage(runtime, source_dir=source_dir)
            report = (runtime / "python-report.txt").read_text(encoding="utf-8")

        self.assertEqual(result["python"]["status"], "ok", (result, report))
        self.assertIn(source_path.as_posix(), report)

    def test_hosted_runtime_empty_language_directories_are_reported_missing(self):
        with tempfile.TemporaryDirectory() as td:
            runtime = make_runtime_output(Path(td), "rt-empty", go=False, python=False)
            (runtime / "go").mkdir()
            (runtime / "python").mkdir()
            calls = []

            result = collect_hosted_runtime_coverage(
                runtime,
                run_command=fake_success_runner(calls),
            )

        self.assertEqual(result["go"]["status"], "missing")
        self.assertEqual(result["python"]["status"], "missing")
        self.assertEqual(calls, [])

    def test_hosted_python_combine_keeps_parallel_data_for_retry(self):
        with tempfile.TemporaryDirectory() as td:
            runtime = make_runtime_output(Path(td), "rt-keep", go=False, python=True)
            calls = []

            result = collect_hosted_runtime_coverage(
                runtime,
                run_command=fake_success_runner(calls),
            )

        combine = next(command for command in calls if "combine" in command)
        self.assertEqual(result["python"]["status"], "ok")
        self.assertIn("--keep", combine)

    def test_hosted_python_base_data_retries_without_recombine(self):
        with tempfile.TemporaryDirectory() as td:
            runtime = make_runtime_output(Path(td), "rt-base", go=False, python=False)
            python_dir = runtime / "python"
            python_dir.mkdir()
            (python_dir / ".coverage").write_bytes(b"combined coverage")
            calls = []

            result = collect_hosted_runtime_coverage(
                runtime,
                run_command=fake_success_runner(calls),
            )

        self.assertEqual(result["python"]["status"], "ok")
        self.assertFalse(any("combine" in command for command in calls), calls)
        self.assertTrue(any("report" in command for command in calls), calls)
        self.assertTrue(any("json" in command for command in calls), calls)

    def test_hosted_runtime_discovery_is_deterministic_and_ignores_files(self):
        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            make_runtime_output(root, "rt-z", go=False, python=False)
            make_runtime_output(root, "rt-a", go=False, python=False)
            (root / "runtimes" / "README.txt").write_text("not a runtime", encoding="utf-8")

            discovered = discover_hosted_runtime_directories(root)

        self.assertEqual([path.name for path in discovered], ["rt-a", "rt-z"])

    def test_hosted_runtime_summary_is_written_in_discovery_order(self):
        with tempfile.TemporaryDirectory() as td:
            workspace = Path(td)
            ctx = RunContext.create(workspace, "census-runs", "session-stop", "hosted-summary")
            hosted_root = ctx.run_dir / "coverage/runtime-agent"
            make_runtime_output(hosted_root, "rt-z", go=False, python=False)
            make_runtime_output(hosted_root, "rt-a", go=True, python=False)
            cfg = type(
                "Cfg",
                (),
                {
                    "services": [
                        {
                            "name": "runtime-agent",
                            "path": "strategy-service",
                            "kind": "go-service",
                        }
                    ]
                },
            )()

            results = collect_hosted_runtime_coverage_outputs(
                ctx,
                cfg,
                finalization_results=[
                    {"runtime_id": runtime_id, "status": "stopped", "exit_code": 0}
                    for runtime_id in ("rt-a", "rt-z")
                ],
                run_command=fake_success_runner([]),
            )

            summary_path = ctx.run_dir / "coverage/hosted-runtime-coverage-summary.json"
            summary = json.loads(summary_path.read_text(encoding="utf-8"))

        self.assertEqual([item["runtime_id"] for item in results], ["rt-a", "rt-z"])
        self.assertEqual(summary, results)

    def test_hosted_runtime_summary_reports_missing_runtime_root(self):
        with tempfile.TemporaryDirectory() as td:
            workspace = Path(td)
            ctx = RunContext.create(workspace, "census-runs", "session-stop", "no-runtimes")
            cfg = type(
                "Cfg",
                (),
                {
                    "services": [
                        {
                            "name": "runtime-agent",
                            "path": "strategy-service",
                            "kind": "go-service",
                        }
                    ]
                },
            )()

            results = collect_hosted_runtime_coverage_outputs(ctx, cfg)

            summary = json.loads(
                (ctx.run_dir / "coverage/hosted-runtime-coverage-summary.json").read_text(
                    encoding="utf-8"
                )
            )

        self.assertEqual(len(results), 1)
        self.assertEqual(results[0]["status"], "missing")
        self.assertIn("runtime", results[0]["reason"].lower())
        self.assertEqual(summary, results)

    def test_frontend_waits_for_the_external_browser_owner_without_spawning(self):
        with tempfile.TemporaryDirectory() as td:
            workspace = Path(td)
            ctx = RunContext.create(
                workspace,
                "census-runs",
                "session-start",
                "external-owner",
            )
            cfg = type(
                "Cfg",
                (),
                {
                    "services": [
                        {
                            "name": "quant-frontend",
                            "path": "gateway/quant-frontend",
                            "kind": "frontend",
                        }
                    ]
                },
            )()
            binding = {
                "CODE_CENSUS_BROWSER_ID": "browser-1",
                "CODE_CENSUS_BROWSER_TAB_ID": "opaque-tab-1",
                "CODE_CENSUS_CHROME_TARGET_URL": "http://127.0.0.1:5173/",
            }

            with (
                patch.dict("os.environ", binding, clear=True),
                patch("census.coverage.subprocess.Popen") as popen,
            ):
                collectors = start_session_collectors(ctx, cfg)

            waiting = json.loads(
                (ctx.run_dir / "coverage/frontend-owner-waiting.json").read_text(
                    encoding="utf-8"
                )
            )
            pids = json.loads(
                (ctx.run_dir / "coverage/session-pids.json").read_text(
                    encoding="utf-8"
                )
            )

        self.assertEqual(collectors, [])
        popen.assert_not_called()
        self.assertEqual(pids["collectors"], [])
        self.assertEqual(waiting["status"], "waiting-for-browser-owner")
        self.assertEqual(waiting["browser_id"], "browser-1")
        self.assertEqual(waiting["tab_id"], "opaque-tab-1")
        self.assertEqual(waiting["target_url"], "http://127.0.0.1:5173/")

    def test_frontend_owner_binding_is_all_or_nothing(self):
        with tempfile.TemporaryDirectory() as td:
            workspace = Path(td)
            ctx = RunContext.create(
                workspace,
                "census-runs",
                "session-start",
                "partial-owner",
            )
            cfg = type("Cfg", (), {"services": []})()
            with patch.dict(
                "os.environ",
                {"CODE_CENSUS_BROWSER_ID": "browser-only"},
                clear=True,
            ):
                with self.assertRaisesRegex(
                    CoverageCollectionFailed,
                    "browser owner binding",
                ):
                    start_session_collectors(ctx, cfg)


if __name__ == "__main__":
    unittest.main()
