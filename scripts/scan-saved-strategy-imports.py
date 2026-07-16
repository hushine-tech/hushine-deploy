#!/usr/bin/env python3
"""Read-only compatibility scan for saved strategy imports.

The scanner deliberately parses strategy source as an AST and delegates policy
decisions to the installed strategy-library.  It never imports or executes
saved source.
"""

from __future__ import annotations

import argparse
import ast
from collections.abc import Iterable, Mapping
import json
import os
from pathlib import Path
import re
import sys
from typing import Any

from hushine_strategy.import_validation import (
    HOSTED_PLATFORM_IMPORT_POLICY,
    validate_dependency_imports,
    validate_dynamic_import_safety,
    validate_platform_import_safety,
)
from hushine_strategy.runtime_dependencies import (
    RuntimeDependencyProfile,
    load_runtime_dependency_profile,
)


MAX_SOURCE_BYTES = 1024 * 1024
MAX_SYNTAX_LINE = MAX_SOURCE_BYTES + 1
FETCH_BATCH_SIZE = 100
SERVER_CURSOR_NAME = "hushine_saved_strategy_import_scan"
ROW_FIELDS = frozenset(
    {"strategy_id", "user_id", "name", "version", "code_octets", "code"}
)
FINDING_KINDS = (
    "dependency",
    "dynamic_safety",
    "platform_safety",
    "scan_error",
)
ENV_NAME_PATTERN = re.compile(r"[A-Za-z_][A-Za-z0-9_]*")

SELECT_SQL = """SELECT strategy_id,
       user_id,
       name,
       version,
       octet_length(code) AS code_octets,
       CASE WHEN octet_length(code) <= 1048576 THEN code ELSE NULL END AS code
FROM strategies
WHERE archived = FALSE
ORDER BY strategy_id"""

FATAL_PAYLOAD: dict[str, object] = {
    "error": {
        "code": "STRATEGY_SCAN_FATAL",
        "message": "saved-strategy scan could not be completed",
    },
    "ok": False,
    "schema_version": 1,
}


class InvalidStrategyRow(ValueError):
    """A row does not match the bounded database/unit contract."""


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="scan-saved-strategy-imports.py",
        add_help=True,
        exit_on_error=False,
    )
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument("--unit-json", metavar="PATH")
    mode.add_argument("--dsn-env", metavar="NAME")
    parser.add_argument("--output", metavar="PATH")
    return parser


def _canonical_json(payload: object) -> str:
    return json.dumps(
        payload,
        ensure_ascii=True,
        sort_keys=True,
        separators=(",", ":"),
    ) + "\n"


def _write_payload(payload: object, output: str | None) -> None:
    encoded = _canonical_json(payload)
    if output in (None, "-"):
        sys.stdout.write(encoded)
        sys.stdout.flush()
        return
    Path(output).write_text(encoded, encoding="utf-8")


def _emit_fatal(output: str | None = None) -> None:
    if output not in (None, "-"):
        try:
            _write_payload(FATAL_PAYLOAD, output)
            return
        except Exception:
            pass
    try:
        _write_payload(FATAL_PAYLOAD, None)
    except Exception:
        pass


def _valid_strategy_id(value: object) -> bool:
    return type(value) is int and 0 < value <= 9_223_372_036_854_775_807


def _valid_user_id(value: object) -> bool:
    return _valid_strategy_id(value)


def _bounded_name(value: object) -> str:
    if not isinstance(value, str) or not value or len(value) > 200:
        return ""
    if any(ord(character) < 32 or ord(character) == 127 for character in value):
        return ""
    return value


def _row_identity(row: object, ordinal: int) -> tuple[int | str, str]:
    if isinstance(row, Mapping) and _valid_strategy_id(row.get("strategy_id")):
        return int(row["strategy_id"]), _bounded_name(row.get("name"))
    return f"row:{ordinal:06d}", ""


def _database_row(raw: object) -> object:
    if not isinstance(raw, (tuple, list)) or len(raw) != 6:
        return raw
    return dict(zip(ROW_FIELDS_IN_SELECT_ORDER, raw, strict=True))


ROW_FIELDS_IN_SELECT_ORDER = (
    "strategy_id",
    "user_id",
    "name",
    "version",
    "code_octets",
    "code",
)


def _validated_source(row: object) -> str:
    if not isinstance(row, Mapping) or frozenset(row) != ROW_FIELDS:
        raise InvalidStrategyRow
    if not _valid_strategy_id(row["strategy_id"]):
        raise InvalidStrategyRow
    if not _valid_user_id(row["user_id"]):
        raise InvalidStrategyRow
    if _bounded_name(row["name"]) != row["name"]:
        raise InvalidStrategyRow
    version = row["version"]
    if (
        not isinstance(version, str)
        or not version
        or len(version) > 20
        or any(ord(character) < 32 or ord(character) == 127 for character in version)
    ):
        raise InvalidStrategyRow
    code_octets = row["code_octets"]
    if type(code_octets) is not int or code_octets < 0:
        raise InvalidStrategyRow
    source = row["code"]
    if source is None:
        if code_octets > MAX_SOURCE_BYTES:
            raise SourceTooLarge
        raise InvalidStrategyRow
    if not isinstance(source, str):
        raise InvalidStrategyRow
    encoded_octets = len(source.encode("utf-8"))
    if code_octets > MAX_SOURCE_BYTES or encoded_octets > MAX_SOURCE_BYTES:
        raise SourceTooLarge
    if code_octets != encoded_octets:
        raise InvalidStrategyRow
    return source


class SourceTooLarge(ValueError):
    """The database refused to return, or unit input supplied, oversized source."""


def _bounded_line(value: object) -> int:
    if type(value) is not int:
        return 0
    return min(max(value, 0), MAX_SYNTAX_LINE)


def _finding(
    *,
    strategy_id: int | str,
    name: str,
    kind: str,
    code: str,
    module: str = "",
    symbol: str = "",
    line: int = 0,
) -> dict[str, object]:
    return {
        "strategy_id": strategy_id,
        "name": name,
        "kind": kind,
        "code": code,
        "module": module,
        "symbol": symbol,
        "line": _bounded_line(line),
    }


def scan_source(
    source: str,
    profile: RuntimeDependencyProfile,
) -> list[dict[str, object]]:
    """Parse and validate one source string without importing or executing it."""

    tree = ast.parse(source)
    platform_issues = validate_platform_import_safety(
        tree,
        policy=HOSTED_PLATFORM_IMPORT_POLICY,
    )
    dynamic_issues = validate_dynamic_import_safety(tree)
    platform_modules = frozenset(
        module for module, _symbols in HOSTED_PLATFORM_IMPORT_POLICY.allowed_from_symbols
    )
    dependency_issues = validate_dependency_imports(
        tree,
        profile=profile,
        stdlib_roots=sys.stdlib_module_names,
        platform_modules=platform_modules,
    )

    findings: list[dict[str, object]] = []
    rejected_platform_nodes = {
        (issue.line, issue.module) for issue in platform_issues
    }
    for issue in platform_issues:
        findings.append(
            {
                "kind": "platform_safety",
                "code": issue.code,
                "module": issue.module,
                "symbol": issue.symbol,
                "line": issue.line,
            }
        )
    for issue in dynamic_issues:
        findings.append(
            {
                "kind": "dynamic_safety",
                "code": issue.code,
                "module": issue.module,
                "symbol": issue.symbol,
                "line": issue.line,
            }
        )
    for issue in dependency_issues:
        if (issue.line, issue.module) in rejected_platform_nodes:
            continue
        findings.append(
            {
                "kind": "dependency",
                "code": issue.code,
                "module": issue.module,
                "symbol": "",
                "line": issue.line,
            }
        )
    return findings


def _strategy_id_sort_key(value: object) -> tuple[int, object]:
    if type(value) is int:
        return (0, value)
    return (1, str(value))


def _finding_sort_key(item: Mapping[str, object]) -> tuple[object, ...]:
    return (
        _strategy_id_sort_key(item["strategy_id"]),
        item["line"],
        item["kind"],
        item["code"],
        item["module"],
        item["symbol"],
    )


def _build_report(
    profile: RuntimeDependencyProfile,
    scanned: int,
    findings: list[dict[str, object]],
) -> dict[str, object]:
    ordered = sorted(findings, key=_finding_sort_key)
    counts = {kind: 0 for kind in FINDING_KINDS}
    affected: set[tuple[type, object]] = set()
    for item in ordered:
        counts[str(item["kind"])] += 1
        identity = item["strategy_id"]
        affected.add((type(identity), identity))
    return {
        "schema_version": 1,
        "runtime_profile": {
            "name": profile.profile_name,
            "version": profile.profile_version,
            "digest": profile.contract_sha256,
        },
        "summary": {
            "scanned": scanned,
            "affected": len(affected),
            "findings": len(ordered),
            "by_kind": counts,
        },
        "findings": ordered,
    }


def scan_rows(
    rows: Iterable[object],
    profile: RuntimeDependencyProfile,
    *,
    database_rows: bool = False,
) -> dict[str, object]:
    findings: list[dict[str, object]] = []
    scanned = 0
    for ordinal, raw_row in enumerate(rows, start=1):
        scanned += 1
        row = _database_row(raw_row) if database_rows else raw_row
        strategy_id, name = _row_identity(row, ordinal)
        try:
            source = _validated_source(row)
            source_findings = scan_source(source, profile)
        except InvalidStrategyRow:
            findings.append(
                _finding(
                    strategy_id=strategy_id,
                    name=name,
                    kind="scan_error",
                    code="INVALID_STRATEGY_ROW",
                )
            )
            continue
        except SourceTooLarge:
            findings.append(
                _finding(
                    strategy_id=strategy_id,
                    name=name,
                    kind="scan_error",
                    code="STRATEGY_SOURCE_TOO_LARGE",
                )
            )
            continue
        except SyntaxError as error:
            findings.append(
                _finding(
                    strategy_id=strategy_id,
                    name=name,
                    kind="scan_error",
                    code="INVALID_STRATEGY_SYNTAX",
                    line=_bounded_line(error.lineno),
                )
            )
            continue
        except Exception:
            findings.append(
                _finding(
                    strategy_id=strategy_id,
                    name=name,
                    kind="scan_error",
                    code="STRATEGY_SCAN_FAILED",
                )
            )
            continue

        for item in source_findings:
            findings.append(
                _finding(
                    strategy_id=strategy_id,
                    name=name,
                    kind=str(item["kind"]),
                    code=str(item["code"]),
                    module=str(item["module"]),
                    symbol=str(item["symbol"]),
                    line=_bounded_line(item["line"]),
                )
            )
    return _build_report(profile, scanned, findings)


def load_database_driver() -> Any:
    import psycopg2

    return psycopg2


def _cleanup_database(connection: object, cursors: Iterable[object]) -> None:
    cleanup_failure = False
    for cursor in reversed(tuple(cursors)):
        try:
            cursor.close()
        except Exception:
            cleanup_failure = True
    try:
        connection.rollback()
    except Exception:
        cleanup_failure = True
    try:
        connection.close()
    except Exception:
        cleanup_failure = True
    if cleanup_failure:
        raise RuntimeError("database cleanup failed")


def scan_database(
    dsn: str,
    profile: RuntimeDependencyProfile,
    driver: object,
) -> dict[str, object]:
    connection = driver.connect(dsn)
    cursors: list[object] = []
    try:
        connection.set_session(readonly=True, autocommit=False)

        transaction_cursor = connection.cursor()
        cursors.append(transaction_cursor)
        transaction_cursor.execute("SET TRANSACTION READ ONLY")
        transaction_cursor.close()
        cursors.remove(transaction_cursor)

        row_cursor = connection.cursor(name=SERVER_CURSOR_NAME)
        cursors.append(row_cursor)
        row_cursor.itersize = FETCH_BATCH_SIZE

        def rows() -> Iterable[object]:
            row_cursor.execute(SELECT_SQL)
            while True:
                batch = row_cursor.fetchmany(FETCH_BATCH_SIZE)
                if not batch:
                    return
                yield from batch

        return scan_rows(rows(), profile, database_rows=True)
    finally:
        _cleanup_database(connection, cursors)


def _load_unit_rows(path: str) -> list[object]:
    if path == "-":
        value = json.load(sys.stdin)
    else:
        with Path(path).open("r", encoding="utf-8") as source:
            value = json.load(source)
    if not isinstance(value, list):
        raise ValueError("unit JSON must be an array")
    return value


def main(argv: list[str] | None = None) -> int:
    output: str | None = None
    try:
        try:
            options = _parser().parse_args(argv)
        except (argparse.ArgumentError, SystemExit) as error:
            raise ValueError("invalid scanner arguments") from error
        output = options.output
        profile = load_runtime_dependency_profile()
        if options.unit_json is not None:
            report = scan_rows(_load_unit_rows(options.unit_json), profile)
        else:
            if ENV_NAME_PATTERN.fullmatch(options.dsn_env or "") is None:
                raise ValueError("invalid DSN environment variable name")
            dsn = os.environ.get(options.dsn_env, "")
            if not dsn:
                raise ValueError("missing DSN environment variable")
            report = scan_database(dsn, profile, load_database_driver())
        _write_payload(report, output)
    except Exception:
        _emit_fatal(output)
        return 2
    return 1 if report["findings"] else 0


if __name__ == "__main__":
    raise SystemExit(main())
