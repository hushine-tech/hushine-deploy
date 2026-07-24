import subprocess
from pathlib import Path


DEPLOY_ROOT = Path(__file__).resolve().parents[4]
NODE_TEST = DEPLOY_ROOT / "scripts/audit/census/tests/browser_coverage_owner.test.mjs"


def test_browser_coverage_owner_node_contract() -> None:
    completed = subprocess.run(
        ["node", "--test", str(NODE_TEST)],
        cwd=DEPLOY_ROOT,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
    )
    assert completed.returncode == 0, completed.stdout
