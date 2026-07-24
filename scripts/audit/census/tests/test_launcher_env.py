import os
import tempfile
import unittest
from pathlib import Path

from census.launch_child import (
    ForbiddenEnvironmentName,
    build_child_environment,
    load_environment_file,
)


class LauncherEnvironmentTests(unittest.TestCase):
    def test_secret_values_reach_only_their_owning_service(self) -> None:
        sentinels = {
            "QUANT_HANDLER_JWT_SECRET": "jwt-only-handler",
            "TELEGRAM_BOT_TOKEN": "telegram-only-core",
            "CORE_CREDENTIAL_ENCRYPTION_KEY": "encryption-only-core",
            "DATABASE_PASSWORD": "portfolio-only-core",
            "ORDER_DATABASE_PASSWORD": "order-only-core",
            "CONTROL_PANEL_TEST_DSN": "control-only-panel",
            "MARKET_DATA_DB_PASSWORD": "market-only-scraper",
            "MARKET_DATA_KAFKA_BROKERS": "market-only-scraper",
            "UNRELATED_SECRET": "nowhere",
        }

        environments = {
            service: build_child_environment(service, sentinels, {})
            for service in (
                "core-service",
                "control-panel-service",
                "scraper",
                "quant-handler",
                "quant-frontend",
            )
        }

        self.assertEqual(
            environments["quant-handler"]["QUANT_HANDLER_JWT_SECRET"],
            "jwt-only-handler",
        )
        self.assertEqual(
            environments["core-service"]["TELEGRAM_BOT_TOKEN"],
            "telegram-only-core",
        )
        self.assertEqual(
            environments["core-service"]["CORE_CREDENTIAL_ENCRYPTION_KEY"],
            "encryption-only-core",
        )
        self.assertEqual(
            environments["core-service"]["DATABASE_PASSWORD"],
            "portfolio-only-core",
        )
        self.assertEqual(
            environments["core-service"]["ORDER_DATABASE_PASSWORD"],
            "order-only-core",
        )
        self.assertEqual(
            environments["control-panel-service"]["CONTROL_PANEL_TEST_DSN"],
            "control-only-panel",
        )
        self.assertEqual(
            environments["scraper"]["MARKET_DATA_DB_PASSWORD"],
            "market-only-scraper",
        )
        self.assertEqual(
            environments["scraper"]["MARKET_DATA_KAFKA_BROKERS"],
            "market-only-scraper",
        )
        for service, child in environments.items():
            self.assertNotIn("UNRELATED_SECRET", child, service)
        self.assertNotIn("QUANT_HANDLER_JWT_SECRET", environments["core-service"])
        self.assertNotIn("TELEGRAM_BOT_TOKEN", environments["quant-handler"])
        self.assertFalse(
            any(
                name.endswith("SECRET")
                or "PASSWORD" in name
                or name.startswith("TELEGRAM_")
                or name.startswith("DATABASE_")
                or name.startswith("MARKET_DATA_")
                for name in environments["quant-frontend"]
            )
        )

    def test_env_file_is_parsed_as_data_and_refuses_demo_credentials(self) -> None:
        with tempfile.TemporaryDirectory() as td:
            path = Path(td) / "census.env"
            path.write_text(
                "QUANT_HANDLER_JWT_SECRET='literal-$HOME'\n"
                "TELEGRAM_BOT_TOKEN=token\n",
                encoding="utf-8",
            )
            values = load_environment_file(path)
            self.assertEqual(values["QUANT_HANDLER_JWT_SECRET"], "literal-$HOME")

            for name in (
                "BINANCE_API_KEY",
                "VENUE_API_SECRET",
                "DEMO_API_KEY",
            ):
                path.write_text(f"{name}=never-read\n", encoding="utf-8")
                with self.subTest(name=name), self.assertRaises(
                    ForbiddenEnvironmentName
                ):
                    load_environment_file(path)

    def test_child_environment_contains_no_implicit_credentials(self) -> None:
        child = build_child_environment(
            "core-service",
            {"PATH": os.environ.get("PATH", "")},
            {},
        )

        self.assertNotIn("DATABASE_PASSWORD", child)
        self.assertNotIn("CORE_CREDENTIAL_ENCRYPTION_KEY", child)
        self.assertNotIn("TELEGRAM_BOT_TOKEN", child)

    def test_spot_rollout_flags_reach_only_core_service(self) -> None:
        flags = {
            "BACKTEST_SPOT_USDT_ENABLED": "true",
            "DEMO_SPOT_USDT_ENABLED": "true",
            "OFFLINE_SPOT_USDT_ENABLED": "true",
            "LIVE_SPOT_USDT_ENABLED": "true",
        }

        core = build_child_environment("core-service", flags, {})
        self.assertEqual({name: core[name] for name in flags}, flags)
        for service in (
            "control-panel-service",
            "scraper",
            "quant-handler",
            "quant-frontend",
        ):
            child = build_child_environment(service, flags, {})
            self.assertTrue(flags.keys().isdisjoint(child), service)


if __name__ == "__main__":
    unittest.main()
