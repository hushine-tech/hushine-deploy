from pathlib import Path


DEPLOY_ROOT = Path(__file__).resolve().parents[4]


def test_census_is_owned_by_deploy_repository() -> None:
    assert (DEPLOY_ROOT / "scripts/audit/census/code_census.py").is_file()
    assert (DEPLOY_ROOT / "scripts/audit/census/start_instrumented_stack.sh").is_file()
    assert (DEPLOY_ROOT / "Makefile").read_text().count(
        "code-census-session-start:"
    ) == 1
    makefile = (DEPLOY_ROOT / "Makefile").read_text()
    assert "--with-requirements $(DEPLOY_ROOT)/scripts/audit/census/requirements.txt" in makefile


def test_all_census_docs_use_the_deploy_owned_tool_and_explicit_source_root() -> None:
    for path in sorted((DEPLOY_ROOT / "docs/code-census").glob("*.md")):
        text = path.read_text()
        assert "hushine-deploy/scripts/audit/census" in text
        assert "/Users/xdy/Workplace/hushine/scripts/audit/census" not in text
        for line in text.splitlines():
            if "code-census-" in line or "code_census.py" in line:
                assert "SOURCE_ROOT" in line or "--source-root" in line
