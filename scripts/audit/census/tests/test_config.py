import os
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from census.config import load_config


class ConfigTests(unittest.TestCase):
    def test_hosted_runtime_coverage_defaults_stop_timeout_to_ten_seconds(self):
        with tempfile.TemporaryDirectory() as td:
            config_path = Path(td) / "config.yaml"
            config_path.write_text("services: []\n", encoding="utf-8")

            cfg = load_config(config_path)

        self.assertEqual(
            cfg.hosted_runtime_coverage,
            {"stop_timeout_seconds": 10},
        )

    def test_hosted_runtime_coverage_loads_positive_stop_timeout(self):
        with tempfile.TemporaryDirectory() as td:
            config_path = Path(td) / "config.yaml"
            config_path.write_text(
                "hosted_runtime_coverage:\n  stop_timeout_seconds: 17\nservices: []\n",
                encoding="utf-8",
            )

            cfg = load_config(config_path)

        self.assertEqual(cfg.hosted_runtime_coverage["stop_timeout_seconds"], 17)

    def test_hosted_runtime_coverage_rejects_nonpositive_stop_timeout(self):
        for value in (0, -1):
            with self.subTest(value=value), tempfile.TemporaryDirectory() as td:
                config_path = Path(td) / "config.yaml"
                config_path.write_text(
                    f"hosted_runtime_coverage:\n  stop_timeout_seconds: {value}\nservices: []\n",
                    encoding="utf-8",
                )

                with self.assertRaisesRegex(ValueError, "stop_timeout_seconds"):
                    load_config(config_path)

    def test_loads_services_and_applies_observability_env_overrides(self):
        with tempfile.TemporaryDirectory() as td:
            config_path = Path(td) / "config.yaml"
            config_path.write_text(
                """
observability:
  elasticsearch_url: "http://es-original:9200"
  jaeger_url: "http://jaeger-original:16686"
output:
  root: "runs"
services:
  - name: "core-service"
    path: "core-service"
    kind: "go-service"
""".strip()
                + "\n",
                encoding="utf-8",
            )
            old_es = os.environ.get("CODE_CENSUS_ES_URL")
            old_jaeger = os.environ.get("CODE_CENSUS_JAEGER_URL")
            os.environ["CODE_CENSUS_ES_URL"] = "http://es-env:9200"
            os.environ["CODE_CENSUS_JAEGER_URL"] = "http://jaeger-env:16686"
            try:
                cfg = load_config(config_path)
                obs = cfg.observability
            finally:
                if old_es is None:
                    os.environ.pop("CODE_CENSUS_ES_URL", None)
                else:
                    os.environ["CODE_CENSUS_ES_URL"] = old_es
                if old_jaeger is None:
                    os.environ.pop("CODE_CENSUS_JAEGER_URL", None)
                else:
                    os.environ["CODE_CENSUS_JAEGER_URL"] = old_jaeger

        self.assertEqual(cfg.output_root, "runs")
        self.assertEqual(cfg.services[0]["name"], "core-service")
        self.assertEqual(obs["elasticsearch_url"], "http://es-env:9200")
        self.assertEqual(obs["jaeger_url"], "http://jaeger-env:16686")

    def test_current_config_enumerates_every_supported_source_subject(self):
        config_path = Path(__file__).resolve().parents[1] / "config.yaml"

        cfg = load_config(config_path)
        services = {service["name"]: service for service in cfg.services}

        self.assertNotIn("strategy-service", services)
        self.assertEqual(
            set(services),
            {
                "core-service",
                "control-panel-service",
                "quant-handler",
                "scraper",
                "runtime-agent",
                "golang-lib",
                "log-shipper",
                "kafka-es-bridge",
                "session-worker",
                "strategy-library",
                "strategy-debugger-cli",
                "py-log",
                "hushine-deploy-tooling",
                "quant-frontend",
            },
        )
        self.assertEqual(services["runtime-agent"]["path"], "strategy-service")
        self.assertTrue(services["runtime-agent"]["kind"].startswith("go-"))
        self.assertEqual(services["runtime-agent"]["cmd_package"], "./cmd/runtime-agent")
        self.assertEqual(
            services["session-worker"],
            {
                "name": "session-worker",
                "path": "strategy-service",
                "kind": "python-library",
                "unit_command": "PYTHONPATH=.:../strategy-library uv run --frozen --extra dev pytest tests/ -q",
            },
        )
        self.assertEqual(
            services["strategy-library"]["unit_command"],
            "uv run --isolated --no-project --with-editable '.[test]' pytest tests -q",
        )
        self.assertEqual(
            services["strategy-debugger-cli"]["unit_command"],
            "uv run --frozen --extra test pytest tests -q",
        )
        self.assertEqual(services["py-log"]["path"], "golang-lib/py_log")
        self.assertEqual(
            services["hushine-deploy-tooling"]["unit_command"],
            "uv run --isolated --no-project --with-requirements scripts/audit/census/requirements.txt pytest scripts/audit/census/tests -q",
        )
        self.assertEqual(
            cfg.observability["elasticsearch_url"], "http://127.0.0.1:9200"
        )
        self.assertEqual(cfg.observability["jaeger_url"], "http://127.0.0.1:16686")


if __name__ == "__main__":
    unittest.main()
