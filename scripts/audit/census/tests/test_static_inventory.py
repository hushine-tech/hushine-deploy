import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from census.static_inventory import scan_file_for_patterns, scan_repo


class StaticInventoryTests(unittest.TestCase):
    def test_grpc_proto_inventory(self):
        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            proto = root / "portfolio_service.proto"
            proto.write_text("service PortfolioService {\n  rpc Login(LoginRequest) returns (LoginResponse);\n}\n", encoding="utf-8")
            records = scan_file_for_patterns(root, "core-service", proto)
        self.assertTrue(any(r.kind == "grpc_service" and r.name == "PortfolioService" for r in records))
        self.assertTrue(any(r.kind == "grpc_rpc" and r.name == "Login" for r in records))

    def test_frontend_route_and_make_target_inventory(self):
        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            app = root / "src/App.tsx"
            app.parent.mkdir()
            app.write_text('<Route path="/portfolios" element={<Portfolios />} />\n', encoding="utf-8")
            makefile = root / "Makefile"
            makefile.write_text("dev:\n\tvite\n", encoding="utf-8")
            service = {"name": "quant-frontend", "path": ".", "kind": "frontend"}
            records = scan_repo(root, service, root)
        self.assertTrue(any(r.kind == "frontend_route" and r.name == "/portfolios" for r in records))
        self.assertTrue(any(r.kind == "make_target" and r.name == "dev" for r in records))


if __name__ == "__main__":
    unittest.main()
