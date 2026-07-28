import json
import os
import subprocess
import tempfile
import time
import unittest
from pathlib import Path


DEPLOY_ROOT = Path(__file__).resolve().parents[4]
SCRIPT = DEPLOY_ROOT / "scripts/audit/census/start_instrumented_stack.sh"
LAUNCHER = DEPLOY_ROOT / "scripts/audit/census/census/launch_child.py"
COVERAGE_IMAGE = "sha256:" + "a" * 64
SERVICE_REPOSITORIES = {
    "core-service": "core-service",
    "control-panel-service": "control-panel-service",
    "scraper": "scraper",
    "quant-handler": "gateway/quant-handler",
}
CERT_FILES = (
    "runtime-channel-server.pem",
    "runtime-channel-server.key",
    "runtime-client-ca.pem",
    "runtime-client-ca.key",
)


class StartInstrumentedStackTests(unittest.TestCase):
    def _fixture(self, root: Path, *, capture: bool = False) -> tuple[Path, Path]:
        source_root = root / "source"
        run_id = "instrumented-test"
        source_root.mkdir(parents=True, exist_ok=True)
        source_root = source_root.resolve()
        run_dir = source_root / "census-runs" / run_id
        for service, repository in SERVICE_REPOSITORIES.items():
            repo = source_root / repository
            repo.mkdir(parents=True, exist_ok=True)
            (repo / "config.local.yaml").write_text("server: {}\n", encoding="utf-8")
            if service == "scraper":
                (repo / "log-config.local.json").write_text("{}\n", encoding="utf-8")
            script = run_dir / "coverage" / service / "runtime/run-instrumented.sh"
            script.parent.mkdir(parents=True, exist_ok=True)
            output = script.parent / "captured.txt"
            if capture:
                body = f"""#!/usr/bin/env bash
REPO=\"{repo}\"
{{
  printf 'argv=%s\\n' \"$*\"
  env | LC_ALL=C sort
}} > \"{output}\"
trap 'exit 0' TERM INT
while true; do sleep 1; done
"""
            else:
                body = f'#!/usr/bin/env bash\nREPO="{repo}"\nexit 0\n'
            script.write_text(body, encoding="utf-8")
            script.chmod(0o755)
        (source_root / "gateway/quant-frontend").mkdir(parents=True)
        cert_root = source_root / "hushine-deploy/certs"
        cert_root.mkdir(parents=True)
        for name in CERT_FILES:
            (cert_root / name).write_text("test\n", encoding="utf-8")
        env_file = source_root / ".env.local"
        env_file.write_text(
            "QUANT_HANDLER_JWT_SECRET=jwt-sentinel\n"
            "TELEGRAM_BOT_TOKEN=telegram-sentinel\n"
            "CORE_CREDENTIAL_ENCRYPTION_KEY=encryption-sentinel\n"
            "DATABASE_PASSWORD=portfolio-db-sentinel\n"
            "ORDER_DATABASE_PASSWORD=order-db-sentinel\n"
            "CONTROL_PANEL_TEST_DSN=control-db-sentinel\n"
            "MARKET_DATA_DB_PASSWORD=market-db-sentinel\n"
            "MARKET_DATA_KAFKA_BROKERS=kafka-sentinel\n"
            "UNRELATED_SECRET=unrelated-sentinel\n",
            encoding="utf-8",
        )
        return source_root, env_file

    def _command(self, source_root: Path, *extra: str) -> list[str]:
        return [
            "bash",
            str(SCRIPT),
            "--source-root",
            str(source_root),
            "--coverage-image",
            COVERAGE_IMAGE,
            *extra,
            "instrumented-test",
        ]

    def _spawn_stop_fixture(
        self,
        root: Path,
        body: str,
    ) -> tuple[Path, int]:
        source_root = root / "source"
        coverage = (
            source_root
            / "census-runs/instrumented-test/coverage"
        )
        coverage.mkdir(parents=True)
        child = root / "covered-service.sh"
        child.write_text(
            "#!/usr/bin/env bash\nset -e\n" + body + "\n",
            encoding="utf-8",
        )
        child.chmod(0o755)
        log = coverage / "core-service.out"
        spawned = subprocess.run(
            [
                "python3",
                str(LAUNCHER),
                "--service",
                "core-service",
                "--spawn",
                "--cwd",
                str(root),
                "--log",
                str(log),
                "--",
                str(child),
            ],
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
        )
        self.assertEqual(spawned.returncode, 0, spawned.stdout)
        pid = int(spawned.stdout.strip())
        # launch_child intentionally detaches; allow the child to exec its
        # interpreter and install signal handlers before exercising stop.
        time.sleep(0.5)
        (coverage / "instrumented-stack-pids.tsv").write_text(
            f"core-service\t{pid}\t{log}\n",
            encoding="utf-8",
        )
        return source_root, pid

    def _stop_fixture(
        self,
        source_root: Path,
        *,
        timeout: str,
        poll_interval: str = "0.01",
    ) -> tuple[subprocess.CompletedProcess[str], dict]:
        env = os.environ.copy()
        env["CODE_CENSUS_STOP_TIMEOUT_SECONDS"] = timeout
        env["CODE_CENSUS_STOP_POLL_INTERVAL_SECONDS"] = poll_interval
        proc = subprocess.run(
            self._command(source_root, "--stop"),
            env=env,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
        )
        status_path = (
            source_root
            / "census-runs/instrumented-test/coverage"
            / "instrumented-stack-stop.json"
        )
        status = (
            json.loads(status_path.read_text(encoding="utf-8"))
            if status_path.exists()
            else {}
        )
        return proc, status

    def test_stop_records_fast_and_delayed_graceful_exit(self) -> None:
        cases = (
            ("fast", "trap 'exit 0' TERM INT\nwhile true; do sleep 1; done"),
            (
                "delayed",
                "trap 'sleep 0.05; exit 0' TERM INT\n"
                "while true; do sleep 1; done",
            ),
        )
        for name, body in cases:
            with self.subTest(name=name), tempfile.TemporaryDirectory() as td:
                source_root, pid = self._spawn_stop_fixture(Path(td), body)
                proc, status = self._stop_fixture(source_root, timeout="0.5")

                self.assertEqual(proc.returncode, 0, proc.stdout)
                self.assertEqual(
                    status["services"],
                    [
                        {
                            "service": "core-service",
                            "pid": pid,
                            "status": "graceful",
                        }
                    ],
                )

    def test_stop_forces_only_processes_alive_after_deadline(self) -> None:
        with tempfile.TemporaryDirectory() as td:
            source_root, pid = self._spawn_stop_fixture(
                Path(td),
                "exec python3 -c 'import signal, time; "
                "signal.signal(signal.SIGTERM, signal.SIG_IGN); "
                "time.sleep(60)'",
            )
            proc, status = self._stop_fixture(source_root, timeout="0.05")

            self.assertEqual(proc.returncode, 0, proc.stdout)
            self.assertEqual(
                status["services"],
                [
                    {
                        "service": "core-service",
                        "pid": pid,
                        "status": "forced",
                    }
                ],
            )
            self.assertIn("forced core-service", proc.stdout)

    def test_stop_timeout_must_be_a_positive_bounded_number(self) -> None:
        with tempfile.TemporaryDirectory() as td:
            source_root, pid = self._spawn_stop_fixture(
                Path(td),
                "trap 'exit 0' TERM INT\nwhile true; do sleep 1; done",
            )
            try:
                proc, status = self._stop_fixture(
                    source_root,
                    timeout="not-a-number",
                )
                self.assertNotEqual(proc.returncode, 0)
                self.assertEqual(status, {})
                self.assertIn(
                    "CODE_CENSUS_STOP_TIMEOUT_SECONDS",
                    proc.stdout,
                )
                os.kill(pid, 0)
            finally:
                try:
                    os.killpg(pid, 9)
                except ProcessLookupError:
                    pass

    def test_launcher_has_no_global_export_or_builtin_credentials(self) -> None:
        text = SCRIPT.read_text(encoding="utf-8")
        launcher = (DEPLOY_ROOT / "scripts/audit/census/census/launch_child.py").read_text(
            encoding="utf-8"
        )
        self.assertNotIn("set -a", text)
        self.assertNotIn("192.168.88.10", text)
        self.assertNotIn("0123456789abcdef0123456789abcdef", text)
        self.assertNotIn("PGPASSWORD=postgres", text)
        self.assertNotIn("env RUNTIME_COVERAGE", text)
        self.assertIn("census/launch_child.py", text)
        self.assertIn("--spawn", text)
        self.assertIn("start_new_session=True", launcher)

    def test_dry_run_records_only_names_and_requires_explicit_coverage_image(self) -> None:
        with tempfile.TemporaryDirectory() as td:
            source_root, _ = self._fixture(Path(td))
            proc = subprocess.run(
                self._command(source_root, "--dry-run"),
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
            )
            plan_path = (
                source_root
                / "census-runs/instrumented-test/coverage/instrumented-stack.json"
            )
            plan = json.loads(plan_path.read_text(encoding="utf-8"))

            self.assertEqual(proc.returncode, 0, proc.stdout)
            self.assertEqual(plan["coverage_image"], COVERAGE_IMAGE)
            self.assertEqual(plan["source_root"], str(source_root.resolve()))
            self.assertEqual(
                [item["service"] for item in plan["services"]],
                ["core-service", "control-panel-service", "scraper", "quant-handler"],
            )
            serialized = json.dumps(plan, sort_keys=True)
            for sentinel in (
                "jwt-sentinel",
                "telegram-sentinel",
                "encryption-sentinel",
                "portfolio-db-sentinel",
                "kafka-sentinel",
            ):
                self.assertNotIn(sentinel, serialized)
                self.assertNotIn(sentinel, proc.stdout)
            self.assertIn("RUNTIME_COVERAGE_IMAGE", serialized)

            missing = subprocess.run(
                [
                    "bash",
                    str(SCRIPT),
                    "--dry-run",
                    "--source-root",
                    str(source_root),
                    "instrumented-test",
                ],
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
            )
            self.assertNotEqual(missing.returncode, 0)
            self.assertIn("--coverage-image is required", missing.stdout)

    def test_demo_credential_names_are_rejected_without_printing_values(self) -> None:
        with tempfile.TemporaryDirectory() as td:
            source_root, env_file = self._fixture(Path(td))
            env_file.write_text("BINANCE_API_KEY=do-not-print-this\n", encoding="utf-8")
            proc = subprocess.run(
                self._command(source_root, "--dry-run"),
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
            )

        self.assertNotEqual(proc.returncode, 0)
        self.assertIn("BINANCE_API_KEY", proc.stdout)
        self.assertNotIn("do-not-print-this", proc.stdout)

    def test_real_fake_children_receive_only_service_allowlists(self) -> None:
        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            source_root, _ = self._fixture(root, capture=True)
            fake_bin = root / "bin"
            fake_bin.mkdir()
            frontend_capture = root / "frontend.txt"
            fake_npm = fake_bin / "npm"
            fake_npm.write_text(
                f"""#!/usr/bin/env bash
{{ printf 'argv=%s\\n' \"$*\"; env | LC_ALL=C sort; }} > \"{frontend_capture}\"
trap 'exit 0' TERM INT
while true; do sleep 1; done
""",
                encoding="utf-8",
            )
            fake_npm.chmod(0o755)
            env = os.environ.copy()
            env["PATH"] = f"{fake_bin}:{env.get('PATH', '')}"
            env["UNRELATED_SECRET"] = "parent-unrelated-sentinel"
            env["VENUE_API_SECRET"] = "parent-demo-sentinel"
            env["CODE_CENSUS_START_DELAY_SECONDS"] = "0"
            proc = subprocess.run(
                self._command(source_root),
                env=env,
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
            )
            try:
                self.assertEqual(proc.returncode, 0, proc.stdout)
                paths = {
                    service: source_root
                    / "census-runs/instrumented-test/coverage"
                    / service
                    / "runtime/captured.txt"
                    for service in SERVICE_REPOSITORIES
                }
                for _ in range(200):
                    if all(path.exists() for path in paths.values()) and frontend_capture.exists():
                        break
                    time.sleep(0.05)
                for service, path in paths.items():
                    log = path.parent / f"{service}.out"
                    self.assertTrue(
                        path.exists(),
                        f"{service} did not capture its environment: "
                        + (log.read_text(encoding="utf-8") if log.exists() else "no log"),
                    )
                captures = {
                    service: path.read_text(encoding="utf-8")
                    for service, path in paths.items()
                }
                captures["quant-frontend"] = frontend_capture.read_text(encoding="utf-8")

                self.assertIn("TELEGRAM_BOT_TOKEN=telegram-sentinel", captures["core-service"])
                self.assertIn(
                    "CORE_CREDENTIAL_ENCRYPTION_KEY=encryption-sentinel",
                    captures["core-service"],
                )
                self.assertIn("DATABASE_PASSWORD=portfolio-db-sentinel", captures["core-service"])
                self.assertIn(
                    "CONTROL_PANEL_TEST_DSN=control-db-sentinel",
                    captures["control-panel-service"],
                )
                self.assertIn(
                    f"RUNTIME_COVERAGE_IMAGE={COVERAGE_IMAGE}",
                    captures["control-panel-service"],
                )
                self.assertIn(
                    "MARKET_DATA_DB_PASSWORD=market-db-sentinel",
                    captures["scraper"],
                )
                self.assertIn(
                    "QUANT_HANDLER_JWT_SECRET=jwt-sentinel",
                    captures["quant-handler"],
                )
                for service, capture in captures.items():
                    self.assertNotIn("UNRELATED_SECRET=", capture, service)
                    self.assertNotIn("VENUE_API_SECRET=", capture, service)
                self.assertNotIn("TELEGRAM_BOT_TOKEN=", captures["quant-handler"])
                self.assertNotIn("QUANT_HANDLER_JWT_SECRET=", captures["core-service"])
                self.assertNotIn("DATABASE_PASSWORD=", captures["control-panel-service"])
                self.assertNotIn("MARKET_DATA_DB_PASSWORD=", captures["quant-frontend"])
                self.assertNotIn("jwt-sentinel", captures["quant-frontend"])
            finally:
                subprocess.run(
                    [
                        "bash",
                        str(SCRIPT),
                        "--stop",
                        "--source-root",
                        str(source_root),
                        "instrumented-test",
                    ],
                    text=True,
                    stdout=subprocess.PIPE,
                    stderr=subprocess.STDOUT,
                )


if __name__ == "__main__":
    unittest.main()
