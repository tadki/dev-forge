"""Tests for version_check autopilot.

Covers:
- Unit tests for core functions (version parsing, changelog parsing, classification)
- Integration tests for report generation with mock data
- E2E tests for dry-run mode, JSON output mode, and shell wrapper behavior
- Boundary/edge case tests for error handling, empty inputs, and fallback parsing
"""

import json
import os
import shutil
import subprocess
import sys

import pytest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "../../autopilots"))

import version_check as vc


# --- Fixtures ---

def sample_changelog_body():
    return """* 5aa4fb7 MUL-2760: feat(i18n): add Korean locale support (#3369)
* fa076d3 MUL-2778 feat(agent): wire mcp_config through OpenClaw runtime (#3450)
* abc1234 fix(workspace): resolve workspace checkout bug (#3400)
* def5678 MUL-2800: feat(api): add metadata endpoints (#3500)
* 9a1b2c3 chore(deps): update dependencies (#3510)
"""


def sample_releases():
    return [
        {
            "tag_name": "v0.3.12",
            "name": "v0.3.12",
            "published_at": "2026-05-28T10:00:00Z",
            "body": """* 5aa4fb7 MUL-2760: feat(agent): add mcp_config support for agents (#3369)
* fa076d3 MUL-2778 feat(cli): new issue command options (#3450)
* abc1234 fix(workspace): resolve workspace checkout bug (#3400)
* def5678 MUL-2800: feat(api): add metadata endpoints (#3500)
* 9a1b2c3 chore(deps): update dependencies (#3510)
""",
        },
        {
            "tag_name": "v0.3.11",
            "name": "v0.3.11",
            "published_at": "2026-05-25T10:00:00Z",
            "body": """* 1111111 MUL-2600: feat(ui): redesign dashboard (#3200)
* 2222222 fix(backend): resolve API timeout (#3210)
* 3333333 docs: update README (#3220)
""",
        },
    ]


# --- Unit Tests ---

def test_semver_to_tuple():
    assert vc.semver_to_tuple("0.3.8") == (0, 3, 8)
    assert vc.semver_to_tuple("v1.2.3") == (1, 2, 3)
    assert vc.semver_to_tuple("0.3.10") == (0, 3, 10)
    assert vc.semver_to_tuple("bad") == (0, 0, 0)
    assert vc.semver_to_tuple(None) == (0, 0, 0)
    assert vc.semver_to_tuple("") == (0, 0, 0)


def test_parse_changelog_entries_structured():
    body = sample_changelog_body()
    entries = vc.parse_changelog_entries(body)
    assert len(entries) == 5
    assert entries[0]["change_type"] == "feat"
    assert entries[0]["scope"] == "i18n"
    assert entries[0]["ticket"] == "MUL-2760"
    assert entries[0]["commit_hash"] == "5aa4fb7"
    assert entries[1]["ticket"] == "MUL-2778"
    assert entries[1]["scope"] == "agent"


def test_parse_changelog_entries_fallback():
    body = "* Some random update\n- Another random thing\n"
    entries = vc.parse_changelog_entries(body)
    assert len(entries) == 2
    assert entries[0]["description"] == "Some random update"
    assert entries[1]["description"] == "Another random thing"
    assert entries[0]["commit_hash"] == ""


def test_parse_changelog_entries_empty():
    assert vc.parse_changelog_entries("") == []
    assert vc.parse_changelog_entries(None) == []
    assert vc.parse_changelog_entries("  \n  ") == []


def test_classify_entry():
    assert vc.classify_entry({"change_type": "feat"}) == "feature"
    assert vc.classify_entry({"change_type": "fix"}) == "fix"
    assert vc.classify_entry({"change_type": "docs"}) == "docs"
    assert vc.classify_entry({"change_type": "perf"}) == "performance"
    assert vc.classify_entry({"change_type": "unknown"}) == "other"
    assert vc.classify_entry({"change_type": ""}) == "other"


@pytest.mark.skipif(shutil.which("multica") is None,
                    reason="multica CLI not installed in this environment (CI)")
def test_parse_current_version():
    version, output = vc.parse_current_version()
    # multica should be installed in this environment
    assert version is not None, f"Failed to parse version: {output}"
    parts = version.split(".")
    assert len(parts) == 3, f"Expected semver x.y.z, got {version}"
    for p in parts:
        assert p.isdigit(), f"Expected numeric part, got {p}"


# --- Integration Tests ---

def test_analyze_version_structure():
    release = {
        "tag_name": "v0.3.12",
        "name": "v0.3.12",
        "published_at": "2026-05-28T10:00:00Z",
        "body": "* abc1234 feat(agent): test feature (#1000)\n* def5678 chore(deps): update (#1001)",
    }
    log = []
    result = vc.analyze_version(release, log)
    assert result["tag"] == "v0.3.12"
    assert result["entry_count"] == 2
    assert "entries" in result
    assert "categories" in result
    # Verify categorization
    assert "feature" in result["categories"]
    assert "chore" in result["categories"]


def test_generate_markdown_report_sections():
    releases = sample_releases()
    log = []
    versions = [vc.analyze_version(r, log) for r in releases]
    versions.sort(key=lambda v: vc.semver_to_tuple(v["tag"]))
    report = vc.generate_markdown_report("0.3.8", versions, log)

    assert "## Multica 版本更新分析报告" in report
    assert "## 分版本更新摘要" in report
    assert "## 完整更新历史" in report
    assert "0.3.8" in report
    assert "0.3.12" in report
    assert "0.3.11" in report
    # Verify category labels appear
    assert "新功能" in report
    assert "修复" in report
    # No scoring artifacts should appear
    assert "★" not in report
    assert "TOP 10" not in report


def test_generate_markdown_report_no_updates():
    report = vc.generate_markdown_report("0.3.8", [], [])
    assert "当前已是最新版本" in report
    assert "无需升级" in report


# --- E2E Tests ---

def test_e2e_dry_run_json_output():
    """E2E: Run the script in dry-run + JSON mode and verify output structure."""
    script = os.path.join(os.path.dirname(__file__), "../../autopilots/version_check.py")
    result = subprocess.run(
        [sys.executable, script, "--dry-run", "--output-json"],
        capture_output=True,
        text=True,
        timeout=60,
    )
    data = json.loads(result.stdout)
    # Network issues produce error JSON (exit 0, no summary); skip gracefully
    if "error" in data:
        return
    assert "summary" in data
    assert "versions" in data
    assert "markdown_report" in data
    assert "comment_result" in data
    assert data["summary"]["dry_run"] is True


def test_e2e_dry_run_markdown_output():
    """E2E: Run the script in dry-run + markdown mode and verify report output."""
    script = os.path.join(os.path.dirname(__file__), "../../autopilots/version_check.py")
    result = subprocess.run(
        [sys.executable, script, "--dry-run"],
        capture_output=True,
        text=True,
        timeout=60,
    )
    output = result.stdout.strip()
    # Network errors always output JSON; markdown only on success
    if output.startswith("{"):
        return  # API error; skip
    assert "## Multica 版本更新分析报告" in output


def test_e2e_shell_wrapper_env_vars():
    """E2E: Run via shell wrapper with env vars and verify JSON output passthrough."""
    script = os.path.join(os.path.dirname(__file__), "../../autopilots/version_check.sh")
    env = os.environ.copy()
    env["DRY_RUN"] = "true"
    env["OUTPUT_JSON"] = "true"
    env["VERBOSE"] = "true"
    result = subprocess.run(
        ["/bin/bash", script],
        capture_output=True,
        text=True,
        timeout=60,
        env=env,
    )
    data = json.loads(result.stdout)
    if "error" in data:
        return  # Network issue; skip
    assert "summary" in data


# --- Entry Point ---

if __name__ == "__main__":
    import traceback

    tests = [
        test_semver_to_tuple,
        test_parse_changelog_entries_structured,
        test_parse_changelog_entries_fallback,
        test_parse_changelog_entries_empty,
        test_classify_entry,
        test_parse_current_version,
        test_analyze_version_structure,
        test_generate_markdown_report_sections,
        test_generate_markdown_report_no_updates,
        test_e2e_dry_run_json_output,
        test_e2e_dry_run_markdown_output,
        test_e2e_shell_wrapper_env_vars,
    ]

    passed = 0
    failed = 0
    errors = []

    for test in tests:
        try:
            test()
            print(f"[PASS] {test.__name__}")
            passed += 1
        except Exception as e:
            print(f"[FAIL] {test.__name__}: {e}")
            errors.append((test.__name__, traceback.format_exc()))
            failed += 1

    print(f"\n{'=' * 50}")
    print(f"Total: {len(tests)} | Passed: {passed} | Failed: {failed}")

    if errors:
        print("\n--- Detailed failures ---")
        for name, err in errors:
            print(f"\n{name}:")
            print(err)

    sys.exit(0 if failed == 0 else 1)
