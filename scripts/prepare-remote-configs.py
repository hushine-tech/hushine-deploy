#!/usr/bin/env python3
"""Render private, short-lived application configs for an explicit dependency host."""

from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import re
import tempfile


HOST_PATTERN = re.compile(r"^[A-Za-z0-9](?:[A-Za-z0-9.-]*[A-Za-z0-9])?$")


def _write_private(target: Path, content: str) -> None:
    target.parent.mkdir(parents=True, exist_ok=True)
    descriptor, temporary_name = tempfile.mkstemp(
        prefix=f".{target.name}.", dir=target.parent
    )
    temporary = Path(temporary_name)
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8", newline="\n") as output:
            output.write(content)
            output.flush()
            os.fsync(output.fileno())
        temporary.chmod(0o600)
        temporary.replace(target)
        target.chmod(0o600)
    finally:
        temporary.unlink(missing_ok=True)


def _render_yaml(source: Path, target: Path, host: str) -> None:
    text = source.read_text(encoding="utf-8")
    text = re.sub(r'(?m)^(\s*host:\s*)"[^"]+"$', rf'\1"{host}"', text)
    text = re.sub(
        r'"[^"\s]+:(?:9092|19092)"', f'"{host}:19092"', text
    )
    text = re.sub(
        r"http://[^\s\"']+:4318", f"http://{host}:4318", text
    )
    _write_private(target, text)


def _render_scraper_log(source: Path, target: Path, host: str) -> None:
    document = json.loads(source.read_text(encoding="utf-8"))
    document.setdefault("kafka", {})["brokers"] = [f"{host}:19092"]
    document.setdefault("tracing", {})["endpoint"] = f"http://{host}:4318"
    _write_private(target, json.dumps(document, indent=2) + "\n")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--source-root", required=True, type=Path)
    parser.add_argument("--output-dir", required=True, type=Path)
    parser.add_argument("--host", required=True)
    args = parser.parse_args()

    if not HOST_PATTERN.fullmatch(args.host):
        parser.error("--host must be a plain IPv4 address or DNS name")
    source_root = args.source_root.resolve()
    output_dir = args.output_dir.resolve()
    output_dir.mkdir(parents=True, exist_ok=True)
    output_dir.chmod(0o700)

    for source, target in (
        ("core-service/config.yaml", "core-service.yaml"),
        ("control-panel-service/config.yaml", "control-panel-service.yaml"),
        ("scraper/config.yaml", "scraper.yaml"),
        ("gateway/quant-handler/config.yaml", "quant-handler.yaml"),
    ):
        _render_yaml(source_root / source, output_dir / target, args.host)
    _render_scraper_log(
        source_root / "scraper/log-config.json",
        output_dir / "scraper-log.json",
        args.host,
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
