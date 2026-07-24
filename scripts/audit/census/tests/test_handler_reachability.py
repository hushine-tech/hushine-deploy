import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from census.handler_reachability import deletion_confidence, normalize_route, route_matches


class HandlerReachabilityTests(unittest.TestCase):
    def test_normalize_route_replaces_template_params(self):
        self.assertEqual(normalize_route("/api/portfolios/${portfolioId}/venues"), "/api/portfolios/:param/venues")
        self.assertEqual(normalize_route("/api/sessions/{session_id}/indicators"), "/api/sessions/:param/indicators")

    def test_route_matches_prefix_and_dynamic_segments(self):
        self.assertTrue(route_matches("/api/portfolios/:param/run-strategy", "/api/portfolios/"))
        self.assertTrue(route_matches("/api/portfolios", "/api/portfolios"))
        self.assertFalse(route_matches("/api/bookkeeping", "/api/portfolios"))

    def test_deletion_confidence_marks_unreferenced_handler_high(self):
        item = {"kind": "handler_method_unreferenced", "production_refs": 0, "test_refs": 2, "protected": False}
        self.assertGreaterEqual(deletion_confidence(item), 80)

    def test_deletion_confidence_keeps_route_without_frontend_low(self):
        item = {"kind": "backend_route_no_frontend_call", "route": "/api/runtime-credentials", "protected": False}
        self.assertLess(deletion_confidence(item), 50)


if __name__ == "__main__":
    unittest.main()
