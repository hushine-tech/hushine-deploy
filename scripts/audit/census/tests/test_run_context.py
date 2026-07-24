import json
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from census.run_context import RunContext


class RunContextTests(unittest.TestCase):
    def test_create_writes_manifest_and_expected_directories(self):
        with tempfile.TemporaryDirectory() as td:
            workspace = Path(td)
            ctx = RunContext.create(workspace, "census-runs", "static", "unit-run")
            self.assertEqual(ctx.run_id, "unit-run")
            manifest = json.loads((ctx.run_dir / "manifest.json").read_text(encoding="utf-8"))
            self.assertEqual(manifest["mode"], "static")
            for name in ["inventory", "observability", "coverage", "reachability", "candidates", "evidence"]:
                self.assertTrue((ctx.run_dir / name).is_dir(), name)


if __name__ == "__main__":
    unittest.main()
