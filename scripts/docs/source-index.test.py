from __future__ import annotations

import hashlib
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


SCRIPT = Path(__file__).with_name("source-index.py")


class SourceIndexTest(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.source_root = self.root / "source"
        self.repository = self.source_root / "core-service"
        self.repository.mkdir(parents=True)
        self.git("init", "-b", "main")
        self.git("config", "user.name", "Source Index Test")
        self.git("config", "user.email", "source-index@invalid")

    def git(self, *arguments: str) -> str:
        return subprocess.check_output(
            ["git", "-C", str(self.repository), *arguments], text=True
        ).strip()

    def write(self, relative: str, text: str) -> None:
        destination = self.repository / relative
        destination.parent.mkdir(parents=True, exist_ok=True)
        destination.write_text(text, encoding="utf-8")

    def commit(self) -> str:
        self.git("add", "-A")
        self.git("commit", "-m", "fixture")
        return self.git("rev-parse", "HEAD")

    def deployment(self, commit: str) -> Path:
        deployment = self.root / "deployment.json"
        deployment.write_text(
            json.dumps(
                {
                    "schema_version": 1,
                    "repositories": [{"name": "core-service", "commit": commit}],
                    "images": [],
                },
                sort_keys=True,
            )
            + "\n",
            encoding="utf-8",
        )
        return deployment

    def run_index(self, deployment: Path, output: Path | None = None) -> subprocess.CompletedProcess[str]:
        output = output or self.root / "source-index.json"
        return subprocess.run(
            [
                sys.executable,
                str(SCRIPT),
                "--source-root",
                str(self.source_root),
                "--deployment",
                str(deployment),
                "--output",
                str(output),
            ],
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
        )

    def test_indexes_committed_safe_source_with_exact_lines_symbols_and_hashes(self) -> None:
        safe_go = "package wallet\n\nfunc AvailableBalance() string {\n\treturn \"账本余额\"\n}\n"
        self.write("internal/wallet/balance.go", safe_go)
        self.write("internal/wallet/model.proto", "message WalletBalance {\n  string asset = 1;\n}\n")
        self.write("web/panel.tsx", "export function WalletPanel() { return null }\n")
        commit = self.commit()
        deployment = self.deployment(commit)

        # The index must read the manifest commit rather than a dirty working tree.
        self.write("internal/wallet/balance.go", "api-secret-from-working-tree\n")
        output = self.root / "index.json"
        result = self.run_index(deployment, output)

        self.assertEqual(result.returncode, 0, result.stderr)
        index = json.loads(output.read_text(encoding="utf-8"))
        self.assertEqual(index["schema_version"], 1)
        self.assertEqual(
            index["deployment_digest"],
            hashlib.sha256(deployment.read_bytes()).hexdigest(),
        )
        self.assertEqual(
            [(chunk["path"], chunk["start_line"]) for chunk in index["chunks"]],
            sorted((chunk["path"], chunk["start_line"]) for chunk in index["chunks"]),
        )

        go_chunk = next(
            chunk for chunk in index["chunks"] if chunk["path"] == "internal/wallet/balance.go"
        )
        self.assertEqual(go_chunk["repository"], "core-service")
        self.assertEqual(go_chunk["commit"], commit)
        self.assertEqual(go_chunk["start_line"], 1)
        self.assertEqual(go_chunk["end_line"], 5)
        self.assertEqual(go_chunk["language"], "go")
        self.assertIn("AvailableBalance", go_chunk["symbols"])
        self.assertEqual(go_chunk["text"], safe_go.rstrip("\n"))
        self.assertEqual(
            go_chunk["sha256"], hashlib.sha256(go_chunk["text"].encode()).hexdigest()
        )
        self.assertRegex(go_chunk["id"], r"^[a-f0-9]{64}$")
        self.assertNotIn("api-secret-from-working-tree", output.read_text(encoding="utf-8"))

    def test_excludes_dependencies_generated_outputs_local_config_and_secrets(self) -> None:
        self.write("cmd/service/main.go", "package main\n")
        excluded = {
            ".env": "api-secret-env",
            "certs/server.pem": "api-secret-pem",
            "certs/server.key": "api-secret-key",
            "node_modules/pkg/index.ts": "api-secret-node",
            "vendor/pkg/vendor.go": "api-secret-vendor",
            ".venv/lib/module.py": "api-secret-venv",
            "dist/bundle.ts": "api-secret-dist",
            "build/generated.py": "api-secret-build",
            "generated/types.go": "api-secret-generated",
            "proto/example.pb.go": "api-secret-protobuf",
            "coverage/report.md": "api-secret-coverage",
            "logs/service.md": "api-secret-log",
            "config.local.yaml": "api-secret-local-config",
            "fixtures/secrets/token.yaml": "api-secret-fixture",
            "user-strategies/42/strategy.py": "api-secret-user-strategy",
            "README.txt": "api-secret-disallowed-suffix",
        }
        for relative, secret in excluded.items():
            self.write(relative, secret + "\n")
        commit = self.commit()
        deployment = self.deployment(commit)
        output = self.root / "index.json"

        result = self.run_index(deployment, output)

        self.assertEqual(result.returncode, 0, result.stderr)
        serialized = output.read_text(encoding="utf-8")
        index = json.loads(serialized)
        self.assertEqual(
            {chunk["path"] for chunk in index["chunks"]}, {"cmd/service/main.go"}
        )
        for secret in excluded.values():
            self.assertNotIn(secret, serialized)

    def test_chunks_at_logical_boundaries_with_bounded_overlap_deterministically(self) -> None:
        paragraphs = []
        for index in range(70):
            paragraphs.append(
                f"func Function{index}() int {{\n"
                f"\tvalue := {index}\n"
                "\treturn value\n"
                "}"
            )
        self.write("large.go", "package large\n\n" + "\n\n".join(paragraphs) + "\n")
        commit = self.commit()
        deployment = self.deployment(commit)
        first = self.root / "first.json"
        second = self.root / "second.json"

        first_result = self.run_index(deployment, first)
        second_result = self.run_index(deployment, second)

        self.assertEqual(first_result.returncode, 0, first_result.stderr)
        self.assertEqual(second_result.returncode, 0, second_result.stderr)
        self.assertEqual(first.read_bytes(), second.read_bytes())
        chunks = json.loads(first.read_text(encoding="utf-8"))["chunks"]
        self.assertGreater(len(chunks), 1)
        self.assertTrue(all(1 <= chunk["end_line"] - chunk["start_line"] + 1 <= 180 for chunk in chunks))
        for previous, current in zip(chunks, chunks[1:]):
            overlap = previous["end_line"] - current["start_line"] + 1
            self.assertGreaterEqual(overlap, 1)
            self.assertLessEqual(overlap, 12)

    def test_rejects_a_committed_symlink_that_escapes_the_repository(self) -> None:
        (self.repository / "outside.go").symlink_to("../../outside.go")
        commit = self.commit()
        deployment = self.deployment(commit)

        result = self.run_index(deployment)

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("symlink leaves repository", result.stderr)


if __name__ == "__main__":
    unittest.main()
