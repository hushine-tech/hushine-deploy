import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from census.db_matrix import collect_db_matrix, scan_sql_references
from census.run_context import RunContext


class DbMatrixTests(unittest.TestCase):
    def test_scan_sql_references_is_table_level_and_case_insensitive(self):
        text = """
CREATE TABLE IF NOT EXISTS orders (id bigint);
select id from orders join portfolios on portfolios.id = orders.portfolio_id;
INSERT INTO order_events (id) VALUES (1);
update portfolio_snapshots set updated_at = now();
"""
        refs = scan_sql_references(text)
        tables = {(item["operation"], item["table"]) for item in refs}
        self.assertIn(("define", "orders"), tables)
        self.assertIn(("read", "orders"), tables)
        self.assertIn(("read", "portfolios"), tables)
        self.assertIn(("write", "order_events"), tables)
        self.assertIn(("write", "portfolio_snapshots"), tables)
        self.assertFalse(any("id" == item["table"] for item in refs))

    def test_collect_db_matrix_writes_inventory_and_reachability(self):
        with tempfile.TemporaryDirectory() as td:
            workspace = Path(td)
            migration = workspace / "core-service/internal/storage/migrations/001.sql"
            migration.parent.mkdir(parents=True)
            migration.write_text("CREATE TABLE IF NOT EXISTS orders (id bigint);\n", encoding="utf-8")
            source = workspace / "core-service/internal/repo/order.go"
            source.parent.mkdir(parents=True)
            source.write_text('const q = "SELECT * FROM orders"\nimport "context"\n', encoding="utf-8")
            ctx = RunContext.create(workspace, "census-runs", "static", "db-run")
            cfg = type("Cfg", (), {"services": [], "raw": {"protected_paths": []}})()
            matrix = collect_db_matrix(ctx, cfg)
            self.assertIn("orders", matrix["tables"])
            self.assertTrue((ctx.run_dir / "inventory/db-table-matrix.json").exists())
            self.assertTrue((ctx.run_dir / "reachability/static-references.json").exists())


if __name__ == "__main__":
    unittest.main()
