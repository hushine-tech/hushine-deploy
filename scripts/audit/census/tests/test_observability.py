import json
import sys
import tempfile
import threading
import unittest
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from census.observability import ObservabilityUnavailable, collect_observability_snapshot, require_observability
from census.run_context import RunContext


class FakeHandler(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path == "/_cluster/health":
            self._send({"status": "green"})
        elif self.path == "/api/services":
            self._send({"data": ["core-service"]})
        elif self.path.startswith("/api/traces"):
            self._send({"data": [{"traceID": "abc", "spans": [{"operationName": "Login", "processID": "p1"}], "processes": {"p1": {"serviceName": "core-service"}}}]})
        else:
            self.send_error(404)

    def do_POST(self):
        if self.path.endswith("/_search"):
            self._send({"hits": {"hits": [{"_source": {"service": "core-service", "log_type": "grpc_access", "trace_id": "abc", "span_id": "def", "grpc.method": "Login"}}]}})
        else:
            self.send_error(404)

    def log_message(self, fmt, *args):
        return

    def _send(self, payload):
        body = json.dumps(payload).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)


class ObservabilityTests(unittest.TestCase):
    def make_ctx(self, tmp_path: Path) -> RunContext:
        return RunContext.create(tmp_path, "census-runs", "snapshot", "obs-run")

    def test_require_observability_fails_when_urls_missing(self):
        with tempfile.TemporaryDirectory() as td:
            ctx = self.make_ctx(Path(td))
            cfg = type("Cfg", (), {"observability": {"elasticsearch_url": "", "jaeger_url": ""}})()
            with self.assertRaises(ObservabilityUnavailable) as got:
                require_observability(ctx, cfg)
            self.assertIn("FAILED_PRECHECK", str(got.exception))
            self.assertIn("observability unavailable", (ctx.run_dir / "observability/precheck.json").read_text(encoding="utf-8"))

    def test_collect_snapshot_writes_log_and_trace_summaries(self):
        server = HTTPServer(("127.0.0.1", 0), FakeHandler)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        url = f"http://127.0.0.1:{server.server_port}"
        try:
            with tempfile.TemporaryDirectory() as td:
                ctx = self.make_ctx(Path(td))
                cfg = type(
                    "Cfg",
                    (),
                    {"observability": {"elasticsearch_url": url, "jaeger_url": url, "es_index_patterns": ["app-logs-*"], "lookback_minutes": 60}},
                )()
                require_observability(ctx, cfg)
                collect_observability_snapshot(ctx, cfg, 30)
                self.assertTrue((ctx.run_dir / "observability/logs-summary.json").exists())
                self.assertTrue((ctx.run_dir / "observability/traces-summary.json").exists())
                self.assertTrue((ctx.run_dir / "observability/endpoint-activity.json").exists())
        finally:
            server.shutdown()
            server.server_close()


if __name__ == "__main__":
    unittest.main()
