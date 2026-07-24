import json
import io
import sys
import tempfile
import unittest
from contextlib import redirect_stderr
from pathlib import Path
from unittest.mock import patch


sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from census import cli


class CliSourceRootTests(unittest.TestCase):
    def _write_config(self, root: Path) -> Path:
        config = root / "config.yaml"
        config.write_text(
            "output:\n  root: census-runs\nservices: []\n",
            encoding="utf-8",
        )
        return config

    def _run_static_with_collectors_stubbed(self, argv: list[str]) -> int:
        with (
            patch.object(cli, "collect_static_inventory"),
            patch.object(cli, "collect_db_matrix"),
            patch.object(cli, "collect_handler_reachability"),
            patch.object(cli, "classify_candidates", return_value=[]),
            patch.object(cli, "render_summary"),
        ):
            return cli.main(argv)

    def test_explicit_source_root_drives_run_context(self):
        with tempfile.TemporaryDirectory() as td:
            temp = Path(td)
            source_root = temp / "medium-cleanup"
            source_root.mkdir()
            config = self._write_config(temp)

            exit_code = self._run_static_with_collectors_stubbed(
                [
                    "static",
                    "--config",
                    str(config),
                    "--source-root",
                    str(source_root),
                    "--run-id",
                    "source-root-test",
                ]
            )

            manifest_path = source_root / "census-runs/source-root-test/manifest.json"
            manifest = json.loads(manifest_path.read_text(encoding="utf-8"))

        self.assertEqual(exit_code, 0)
        self.assertEqual(manifest["workspace"], str(source_root.resolve()))

    def test_source_root_must_be_absolute_and_exist(self):
        with tempfile.TemporaryDirectory() as td:
            config = self._write_config(Path(td))
            relative_stderr = io.StringIO()
            with redirect_stderr(relative_stderr):
                with self.assertRaises(SystemExit) as relative:
                    cli.main(
                        [
                            "static",
                            "--config",
                            str(config),
                            "--source-root",
                            "relative/source",
                        ]
                    )
            missing_stderr = io.StringIO()
            with redirect_stderr(missing_stderr):
                with self.assertRaises(SystemExit) as missing:
                    cli.main(
                        [
                            "static",
                            "--config",
                            str(config),
                            "--source-root",
                            str(Path(td) / "missing"),
                        ]
                    )

        self.assertEqual(relative.exception.code, 2)
        self.assertEqual(missing.exception.code, 2)
        self.assertIn("--source-root must be absolute", relative_stderr.getvalue())
        self.assertIn("--source-root directory does not exist", missing_stderr.getvalue())

    def test_default_source_root_remains_tool_workspace(self):
        with tempfile.TemporaryDirectory() as td:
            config = self._write_config(Path(td))
            fake_ctx = type("Ctx", (), {"run_dir": Path(td) / "run"})()
            with (
                patch.object(cli.RunContext, "create", return_value=fake_ctx) as create,
                patch.object(cli, "collect_static_inventory"),
                patch.object(cli, "collect_db_matrix"),
                patch.object(cli, "collect_handler_reachability"),
                patch.object(cli, "classify_candidates", return_value=[]),
                patch.object(cli, "render_summary"),
            ):
                exit_code = cli.main(
                    [
                        "static",
                        "--config",
                        str(config),
                        "--run-id",
                        "default-source-root",
                    ]
                )

        self.assertEqual(exit_code, 0)
        self.assertEqual(create.call_args.args[0], cli.TOOL_ROOT)

    def test_unit_coverage_mode_does_not_require_observability(self):
        with tempfile.TemporaryDirectory() as td:
            temp = Path(td)
            source_root = temp / "source"
            source_root.mkdir()
            config = self._write_config(temp)
            with (
                patch.object(cli, "collect_static_inventory"),
                patch.object(cli, "collect_db_matrix"),
                patch.object(cli, "collect_handler_reachability"),
                patch.object(cli, "collect_unit_coverage") as collect_unit,
                patch.object(cli, "require_observability") as observability,
                patch.object(cli, "classify_candidates", return_value={}),
                patch.object(cli, "render_summary"),
            ):
                exit_code = cli.main(
                    [
                        "unit-coverage",
                        "--config",
                        str(config),
                        "--source-root",
                        str(source_root),
                        "--run-id",
                        "unit-only",
                    ]
                )

        self.assertEqual(exit_code, 0)
        collect_unit.assert_called_once()
        observability.assert_not_called()


if __name__ == "__main__":
    unittest.main()
