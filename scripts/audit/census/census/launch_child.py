"""Exec one census child with a service-specific environment allowlist."""

from __future__ import annotations

import argparse
import os
import re
import shutil
import subprocess
from pathlib import Path
from typing import Mapping


ENVIRONMENT_NAME = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*$")
SAFE_BASE_NAMES = {
    "HOME",
    "LANG",
    "LC_ALL",
    "LOGNAME",
    "NO_PROXY",
    "PATH",
    "SHELL",
    "SSL_CERT_DIR",
    "SSL_CERT_FILE",
    "TEMP",
    "TMP",
    "TMPDIR",
    "TZ",
    "USER",
    "UV_CACHE_DIR",
    "http_proxy",
    "https_proxy",
    "no_proxy",
    "HTTP_PROXY",
    "HTTPS_PROXY",
}

SERVICE_NAMES = {
    "core-service": {
        "BACKTEST_SPOT_USDT_ENABLED",
        "CORE_CREDENTIAL_ENCRYPTION_KEY",
        "CORE_CREDENTIAL_KEY_VERSION",
        "DATABASE_DBNAME",
        "DATABASE_HOST",
        "DATABASE_PASSWORD",
        "DATABASE_PORT",
        "DATABASE_SSLMODE",
        "DATABASE_USER",
        "DEMO_SPOT_USDT_ENABLED",
        "EXCHANGE_MOCK_BINANCE",
        "EXCHANGE_SYMBOL_CACHE_TTL",
        "OFFLINE_SPOT_USDT_ENABLED",
        "ORDER_DATABASE_DBNAME",
        "ORDER_DATABASE_HOST",
        "ORDER_DATABASE_PASSWORD",
        "ORDER_DATABASE_PORT",
        "ORDER_DATABASE_SSLMODE",
        "ORDER_DATABASE_USER",
        "ORDER_MIGRATIONS",
        "PORTFOLIO_SERVICE_MIGRATIONS",
        "SERVER_GRPC_ADDR",
        "SERVER_HTTP_ADDR",
        "TELEGRAM_BOT_TOKEN",
        "TELEGRAM_BOT_USERNAME",
        "LIVE_SPOT_USDT_ENABLED",
    },
    "control-panel-service": {
        "CONTROL_PANEL_TEST_DSN",
        "DEPENDENCIES_CORE_SERVICE_GRPC",
        "DEPENDENCIES_ORDER_SERVICE_GRPC",
        "MARKET_DATA_KAFKA_BROKERS",
        "MARKET_DATA_LIVE_DELIVERY_ENABLED",
        "NOTIFICATION_KAFKA_BROKERS",
        "NOTIFICATION_KAFKA_TOPIC",
        "RUNTIME_CHANNEL_SERVER_GRPC_ADDR",
        "RUNTIME_CHANNEL_SERVER_TLS_CERT_FILE",
        "RUNTIME_CHANNEL_SERVER_TLS_CLIENT_CA_FILE",
        "RUNTIME_CHANNEL_SERVER_TLS_CLIENT_CA_KEY_FILE",
        "RUNTIME_CHANNEL_SERVER_TLS_ENABLED",
        "RUNTIME_CHANNEL_SERVER_TLS_KEY_FILE",
        "RUNTIME_CHANNEL_SERVER_TLS_SERVER_NAME",
        "RUNTIME_COVERAGE_ENABLED",
        "RUNTIME_COVERAGE_IMAGE",
        "RUNTIME_COVERAGE_OUTPUT_DIR",
        "RUNTIME_DEPENDENCY_CONTRACT_SHA256",
        "RUNTIME_DEPENDENCY_PROFILE_NAME",
        "RUNTIME_DEPENDENCY_PROFILE_VERSION",
        "RUNTIME_DEPENDENCY_SCHEMA_VERSION",
        "RUNTIME_PLATFORM_BARE_BOOTSTRAP_IP_ALLOWLIST",
        "RUNTIME_PLATFORM_BARE_CERTIFICATE_TTL",
        "RUNTIME_PLATFORM_BARE_RUNTIME_DEATH_GRACE_SECONDS",
        "RUNTIME_PLATFORM_DEBUG_BARE_RUNTIME_ENABLED",
        "RUNTIME_PLATFORM_DEFAULT_PLAN_CODE",
        "SERVER_GRPC_ADDR",
        "SERVER_HTTP_ADDR",
    },
    "scraper": {
        "MARKET_DATA_DB_DATABASE",
        "MARKET_DATA_DB_HOST",
        "MARKET_DATA_DB_PASSWORD",
        "MARKET_DATA_DB_PORT",
        "MARKET_DATA_DB_SSLMODE",
        "MARKET_DATA_DB_USER",
        "MARKET_DATA_KAFKA_BROKERS",
        "SCRAPER_DBS",
    },
    "quant-handler": {
        "AUTH_CORS_ORIGINS",
        "AUTH_JWT_SECRET",
        "DEPENDENCIES_CONTROL_PANEL_SERVICE_GRPC",
        "DEPENDENCIES_CORE_SERVICE_GRPC",
        "DEPENDENCIES_ORDER_SERVICE_GRPC",
        "SERVER_HTTP_ADDR",
    },
    "quant-frontend": {
        "NODE_ENV",
        "PORT",
        "VITE_API_BASE_URL",
        "npm_config_cache",
    },
}

SERVICE_PREFIXES = {
    "core-service": ("NOTIFICATION_", "OTEL_", "LOG_"),
    "control-panel-service": ("OTEL_", "LOG_"),
    "scraper": ("OTEL_", "LOG_"),
    "quant-handler": ("OTEL_", "LOG_"),
    "quant-frontend": (),
}


class ForbiddenEnvironmentName(ValueError):
    """Raised when a file tries to pass Venue credentials to the stack."""


def _is_demo_credential_name(name: str) -> bool:
    upper = name.upper()
    return upper.endswith("_API_KEY") or upper.endswith("_API_SECRET")


def load_environment_file(path: Path | None) -> dict[str, str]:
    if path is None:
        return {}
    result: dict[str, str] = {}
    for number, raw in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        if line.startswith("export "):
            line = line.removeprefix("export ").lstrip()
        if "=" not in line:
            raise ValueError(f"invalid environment assignment at line {number}")
        name, value = line.split("=", 1)
        name = name.strip()
        value = value.strip()
        if ENVIRONMENT_NAME.fullmatch(name) is None:
            raise ValueError(f"invalid environment name at line {number}")
        if _is_demo_credential_name(name):
            raise ForbiddenEnvironmentName(
                f"Demo Venue credential variable is forbidden: {name}"
            )
        if len(value) >= 2 and value[0] == value[-1] and value[0] in {"'", '"'}:
            value = value[1:-1]
        result[name] = value
    return result


def _service_accepts(service: str, name: str) -> bool:
    if name in SAFE_BASE_NAMES or name in SERVICE_NAMES[service]:
        return True
    return any(name.startswith(prefix) for prefix in SERVICE_PREFIXES[service])


def build_child_environment(
    service: str,
    parent: Mapping[str, str],
    file_values: Mapping[str, str],
    *,
    fixed: Mapping[str, str] | None = None,
) -> dict[str, str]:
    if service not in SERVICE_NAMES:
        raise ValueError(f"unknown service: {service}")
    merged = dict(parent)
    merged.update(file_values)
    child = {
        name: value
        for name, value in merged.items()
        if not _is_demo_credential_name(name) and _service_accepts(service, name)
    }
    for name, value in (fixed or {}).items():
        if not _service_accepts(service, name):
            raise ValueError(f"fixed environment name is not allowed for {service}: {name}")
        child[name] = value
    return child


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="census-launch-child")
    parser.add_argument("--service", choices=sorted(SERVICE_NAMES))
    parser.add_argument("--check-env-file", type=Path)
    parser.add_argument("--env-file", type=Path)
    parser.add_argument("--coverage-output")
    parser.add_argument("--coverage-image")
    parser.add_argument("--spawn", action="store_true")
    parser.add_argument("--cwd", type=Path)
    parser.add_argument("--log", type=Path)
    parser.add_argument("command", nargs=argparse.REMAINDER)
    return parser


def main(argv: list[str] | None = None) -> int:
    args = _parser().parse_args(argv)
    if args.check_env_file is not None:
        load_environment_file(args.check_env_file)
        return 0
    if args.service is None:
        raise SystemExit("--service is required")
    command = list(args.command)
    if command[:1] == ["--"]:
        command = command[1:]
    if not command:
        raise SystemExit("child command is required after --")

    file_values = load_environment_file(args.env_file)
    fixed: dict[str, str] = {}
    if args.service == "control-panel-service":
        if not args.coverage_output or not args.coverage_image:
            raise SystemExit("control-panel-service requires coverage output and image")
        fixed = {
            "RUNTIME_COVERAGE_ENABLED": "true",
            "RUNTIME_COVERAGE_OUTPUT_DIR": args.coverage_output,
            "RUNTIME_COVERAGE_IMAGE": args.coverage_image,
        }
    child = build_child_environment(args.service, os.environ, file_values, fixed=fixed)
    executable = command[0]
    if "/" not in executable:
        executable = shutil.which(executable, path=child.get("PATH")) or ""
    if not executable:
        raise SystemExit(f"child executable not found: {command[0]}")
    command[0] = executable
    if args.spawn:
        if args.cwd is None or args.log is None:
            raise SystemExit("--spawn requires --cwd and --log")
        cwd = args.cwd.resolve()
        log_path = args.log.resolve()
        if not cwd.is_dir():
            raise SystemExit(f"child cwd not found: {cwd}")
        log_path.parent.mkdir(parents=True, exist_ok=True)
        if log_path.exists() and log_path.is_symlink():
            raise SystemExit(f"refusing symbolic-link child log: {log_path}")
        with log_path.open("ab", buffering=0) as log:
            process = subprocess.Popen(
                command,
                cwd=cwd,
                env=child,
                stdin=subprocess.DEVNULL,
                stdout=log,
                stderr=subprocess.STDOUT,
                start_new_session=True,
                close_fds=True,
            )
        print(process.pid)
        return 0
    os.execve(executable, command, child)
    return 127


if __name__ == "__main__":
    raise SystemExit(main())
