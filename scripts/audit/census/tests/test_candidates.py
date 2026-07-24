import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from census.candidates import apply_overrides, classify_candidates, evidence_record
from census.run_context import RunContext
from census.writer import append_jsonl, write_json


class CandidateTests(unittest.TestCase):
    def test_apply_overrides_protects_migrations(self):
        overrides = {"classifications": {"never_delete_by_coverage": [{"path": "**/migrations/", "reason": "migration"}]}}
        bucket, reason = apply_overrides("core-service/internal/storage/migrations/001.sql", "delete-candidate", overrides)
        self.assertEqual(bucket, "never-delete-by-coverage")
        self.assertEqual(reason, "migration")

    def test_static_only_candidate_is_not_delete_candidate(self):
        with tempfile.TemporaryDirectory() as td:
            ctx = RunContext.create(Path(td), "census-runs", "static", "candidate-static")
            write_json(ctx.run_dir / "inventory/static-entrypoints.json", [{"kind": "script", "file": "scripts/old.sh", "name": "old"}])
            classification = classify_candidates(ctx, type("Cfg", (), {"raw": {}})(), static_only=True)
            buckets = {item["bucket"] for item in classification["items"]}
            self.assertNotIn("delete-candidate", buckets)

    def test_observability_evidence_marks_subject_active(self):
        with tempfile.TemporaryDirectory() as td:
            ctx = RunContext.create(Path(td), "census-runs", "snapshot", "candidate-active")
            append_jsonl(ctx.run_dir / "evidence/observability.jsonl", evidence_record("observability", "core-service:Login", "jaeger", "high", {}))
            classification = classify_candidates(ctx, type("Cfg", (), {"raw": {}})(), static_only=False)
            active = [item for item in classification["items"] if item["subject"] == "core-service:Login"]
            self.assertEqual(active[0]["bucket"], "active")

    def test_unprotected_no_evidence_can_be_delete_candidate_in_non_static_run(self):
        with tempfile.TemporaryDirectory() as td:
            ctx = RunContext.create(Path(td), "census-runs", "snapshot", "candidate-delete")
            write_json(ctx.run_dir / "reachability/static-references.json", {"unreferenced_files": ["unused/module.py"], "references": []})
            classification = classify_candidates(ctx, type("Cfg", (), {"raw": {}})(), static_only=False)
            found = [item for item in classification["items"] if item["subject"] == "unused/module.py"]
            self.assertEqual(found[0]["bucket"], "delete-candidate")

    def test_external_source_root_uses_overrides_next_to_tool_config(self):
        with tempfile.TemporaryDirectory() as td:
            temp = Path(td)
            source_root = temp / "medium-cleanup"
            source_root.mkdir()
            ctx = RunContext.create(source_root, "census-runs", "snapshot", "tool-overrides")
            write_json(
                ctx.run_dir / "reachability/static-references.json",
                {"unreferenced_files": ["unused/module.py"], "references": []},
            )
            config_dir = temp / "tool/scripts/audit/census"
            config_dir.mkdir(parents=True)
            config_path = config_dir / "config.yaml"
            config_path.write_text("services: []\n", encoding="utf-8")
            (config_dir / "overrides.yaml").write_text(
                """classifications:
  never_delete_by_coverage:
    - path: "unused/module.py"
      reason: "tool-owned override"
""",
                encoding="utf-8",
            )
            cfg = type("Cfg", (), {"config_path": config_path})()

            classification = classify_candidates(ctx, cfg, static_only=False)

        found = next(
            item for item in classification["items"] if item["subject"] == "unused/module.py"
        )
        self.assertEqual(found["bucket"], "never-delete-by-coverage")
        self.assertEqual(found["reason"], "tool-owned override")


if __name__ == "__main__":
    unittest.main()
