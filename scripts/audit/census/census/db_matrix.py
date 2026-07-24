from pathlib import Path
import os
import re

from .writer import append_jsonl, write_json


CREATE_TABLE = re.compile(r'\bCREATE\s+TABLE\s+(?:IF\s+NOT\s+EXISTS\s+)?["`]?([A-Za-z0-9_.]+)["`]?', re.IGNORECASE)
READ_TABLE = re.compile(r'\b(?:FROM|JOIN)\s+["`]?([A-Za-z0-9_.]+)["`]?', re.IGNORECASE)
WRITE_TABLE = re.compile(r'\b(?:INSERT\s+INTO|UPDATE|DELETE\s+FROM)\s+["`]?([A-Za-z0-9_.]+)["`]?', re.IGNORECASE)
GO_IMPORT = re.compile(r'^\s*(?:"([^"]+)"|import\s+"([^"]+)")')
PY_IMPORT = re.compile(r'^\s*(?:from\s+([A-Za-z0-9_.]+)\s+import|import\s+([A-Za-z0-9_.]+))')
TS_IMPORT = re.compile(r'^\s*import\s+.*?\s+from\s+["`]([^"`]+)["`]')
PROTO_IMPORT = re.compile(r'^\s*import\s+["`]([^"`]+)["`]')

SKIP_DIRS = {".git", ".idea", ".cache", ".pytest_cache", ".venv", "venv", "__pycache__", "node_modules", "dist", "build", "logs", "coverage", "census-runs", ".audit-build"}
SOURCE_SUFFIXES = {".sql", ".go", ".py", ".ts", ".tsx", ".js", ".jsx", ".proto", ".yaml", ".yml"}


def collect_db_matrix(ctx, cfg) -> dict:
    matrix = {"tables": {}, "references": []}
    static_refs = {"imports": [], "table_references": [], "unreferenced_files": []}
    for path in iter_source_files(ctx.workspace):
        text = path.read_text(encoding="utf-8", errors="ignore")
        rel = str(path.relative_to(ctx.workspace))
        for item in scan_sql_references(text):
            table = item["table"]
            if item["operation"] == "define":
                matrix["tables"].setdefault(table, {"defined_in": [], "reads": [], "writes": []})
                matrix["tables"][table]["defined_in"].append(rel)
            elif item["operation"] == "read":
                add_reference(matrix, "read", table, rel)
            elif item["operation"] == "write":
                add_reference(matrix, "write", table, rel)
        static_refs["imports"].extend(scan_imports(path, text, rel))
        if any(token in rel.lower() for token in ["/legacy", "legacy", "/old", "deprecated"]):
            static_refs["unreferenced_files"].append(rel)
    static_refs["table_references"] = matrix["references"]
    write_json(ctx.run_dir / "inventory/db-table-matrix.json", matrix)
    write_json(ctx.run_dir / "reachability/static-references.json", static_refs)
    append_jsonl(ctx.run_dir / "evidence/db-table-matrix.jsonl", {"kind": "db_table_matrix", "table_count": len(matrix["tables"])})
    return matrix


def scan_sql_references(text: str) -> list[dict]:
    refs = []
    for match in CREATE_TABLE.finditer(text):
        refs.append({"operation": "define", "table": normalize_table(match.group(1))})
    for match in READ_TABLE.finditer(text):
        refs.append({"operation": "read", "table": normalize_table(match.group(1))})
    for match in WRITE_TABLE.finditer(text):
        refs.append({"operation": "write", "table": normalize_table(match.group(1))})
    return [ref for ref in refs if ref["table"]]


def add_reference(matrix: dict, operation: str, table: str, rel: str) -> None:
    entry = matrix["tables"].setdefault(table, {"defined_in": [], "reads": [], "writes": []})
    key = "reads" if operation == "read" else "writes"
    if rel not in entry[key]:
        entry[key].append(rel)
    record = {"operation": operation, "table": table, "file": rel}
    if record not in matrix["references"]:
        matrix["references"].append(record)


def normalize_table(raw: str) -> str:
    table = raw.strip().strip('`"').strip(";").lower()
    if "." in table:
        table = table.split(".")[-1]
    return re.sub(r"[^a-z0-9_]", "", table)


def scan_imports(path: Path, text: str, rel: str) -> list[dict]:
    refs = []
    pattern = None
    kind = "import"
    if path.suffix == ".go":
        pattern = GO_IMPORT
        kind = "go_import"
    elif path.suffix == ".py":
        pattern = PY_IMPORT
        kind = "python_import"
    elif path.suffix in {".ts", ".tsx", ".js", ".jsx"}:
        pattern = TS_IMPORT
        kind = "ts_import"
    elif path.suffix == ".proto":
        pattern = PROTO_IMPORT
        kind = "proto_import"
    if pattern is None:
        return refs
    for line_no, line in enumerate(text.splitlines(), start=1):
        match = pattern.search(line)
        if match:
            name = next((group for group in match.groups() if group), None)
            if name:
                refs.append({"kind": kind, "name": name, "file": rel, "line": line_no})
    return refs


def iter_source_files(root: Path):
    for current, dirs, files in os.walk(root):
        dirs[:] = [d for d in dirs if d not in SKIP_DIRS]
        current_path = Path(current)
        for filename in files:
            path = current_path / filename
            if path.suffix in SOURCE_SUFFIXES:
                yield path
