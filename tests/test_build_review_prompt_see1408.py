"""Unit tests for the toolchain review-prompt builder (build_review_prompt.py).

SEE-1408 §SPEC-009 hardening: the assembly logic (THEMES rotation mapping,
placeholder substitution, Kill Switch, --nth edge cases, section-number /
parse_sections consistency) previously had no direct tests — only manual
acceptance commands. These tests guard it against regression.

Placement: .dev/tests/unit/ is the formal pytest home for devtools unit tests
(.dev/docs/devtests.md §3). The builder imports its real template from the
repo tree; a minimal synthetic template fixture is used where the test only
exercises parsing/assembly mechanics.
"""
from __future__ import annotations

import argparse
import importlib.util
import json
import subprocess
import sys
from pathlib import Path

import pytest

REPO_ROOT = Path(__file__).resolve().parents[1]
BUILDER_PATH = REPO_ROOT / "review-prompts/toolchain/build_review_prompt.py"
TEMPLATE_PATH = REPO_ROOT / "review-prompts/toolchain/prompts/toolchain_review_prompt.md"


def _load_builder():
    spec = importlib.util.spec_from_file_location("build_review_prompt", BUILDER_PATH)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


builder = _load_builder()


def _run_builder(*cli_args: str, cwd: Path = REPO_ROOT) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        [sys.executable, str(BUILDER_PATH), *cli_args],
        cwd=str(cwd),
        capture_output=True,
        text=True,
        timeout=30,
    )


@pytest.fixture()
def tmp_state(tmp_path: Path) -> Path:
    return tmp_path / "review-state.json"


class TestThemesRotationMapping:
    def test_themes_table_shape_and_section_numbers(self):
        assert len(builder.THEMES) == 4
        assert [t[0] for t in builder.THEMES] == [4, 5, 6, 7]
        assert len({t[2] for t in builder.THEMES}) == 4, "theme keys must be unique"

    def test_theme_sections_exist_in_real_template(self):
        sections = builder.parse_sections(TEMPLATE_PATH.read_text(encoding="utf-8"))
        for section_num, _zh, _key in builder.THEMES:
            assert section_num in sections, f"template missing §{section_num}"

    def test_theme_titles_match_template_headings(self):
        sections = builder.parse_sections(TEMPLATE_PATH.read_text(encoding="utf-8"))
        for section_num, zh, _key in builder.THEMES:
            heading = sections[section_num].splitlines()[0]
            assert zh in heading, f"THEMES {zh!r} not reflected in template heading: {heading}"

    def test_nth_rotation_cycles_through_all_four(self, tmp_state):
        seen = []
        for _ in range(5):
            r = _run_builder("--date", "2026-10-14", "--state-file", str(tmp_state))
            assert r.returncode == 0
            for _n, zh, _k in builder.THEMES:
                if zh in r.stdout.split("### 1.1")[1]:
                    seen.append(zh)
                    break
            else:
                pytest.fail("no theme_zh found in assembled prompt")
        assert seen == [builder.THEMES[i][1] for i in range(4)] + [builder.THEMES[0][1]]


class TestPlaceholderSubstitution:
    PLACEHOLDERS = [
        "date", "nth", "theme", "theme_zh", "theme_section",
        "theme_body", "executor_agent", "daily_report_dir", "ledger_path",
    ]

    def test_no_residual_placeholders_nth_1_to_4(self, tmp_path):
        for nth in range(1, 5):
            out = tmp_path / f"p{nth}.md"
            r = _run_builder(
                "--nth", str(nth), "--date", "2026-10-14",
                "--state-file", str(tmp_path / "state.json"),
                "--output", str(out),
            )
            assert r.returncode == 0
            text = out.read_text(encoding="utf-8")
            residual = [ph for ph in self.PLACEHOLDERS if "{{" + ph + "}}" in text]
            assert not residual, f"nth={nth} residual placeholders: {residual}"
            # any other unreplaced {{...}} marker is a substitution leak too
            leaked = [ln for ln in text.splitlines() if "{{" in ln and "{{var}}" not in ln]
            assert not leaked, f"nth={nth} leaked substitution markers: {leaked[:3]}"

    def test_placeholder_values_landed(self, tmp_path):
        out = tmp_path / "p.md"
        r = _run_builder(
            "--nth", "2", "--date", "2026-10-14",
            "--state-file", str(tmp_path / "state.json"),
            "--output", str(out),
            "--executor-agent", "Harti",
        )
        assert r.returncode == 0
        text = out.read_text(encoding="utf-8")
        assert "第 2 期 · 2026-10-14" in text
        assert "Harti" in text
        assert builder.THEMES[1][1] in text  # theme_zh for nth=2
        assert str(builder.THEMES[1][2]) in text  # theme key injected


class TestKillSwitch:
    def test_daily_report_dir_disabled_exit_3_empty_output(self, tmp_path):
        disabled_dir = tmp_path / "reports"
        disabled_dir.mkdir()
        (disabled_dir / "DISABLED").touch()
        out = tmp_path / "out.md"
        r = _run_builder(
            "--nth", "1", "--date", "2026-10-14",
            "--daily-report-dir", str(disabled_dir),
            "--state-file", str(tmp_path / "state.json"),
            "--output", str(out),
        )
        assert r.returncode == 3
        assert not out.exists() or out.stat().st_size == 0
        assert r.stdout == ""

    def test_ledger_dir_disabled_exit_3(self, tmp_path):
        ledger = tmp_path / "ledger" / "2026-10.md"
        ledger.parent.mkdir(parents=True)
        (ledger.parent / "DISABLED").touch()
        r = _run_builder(
            "--nth", "1", "--date", "2026-10-14",
            "--daily-report-dir", str(tmp_path / "reports"),
            "--ledger-path", str(ledger),
            "--state-file", str(tmp_path / "state.json"),
        )
        assert r.returncode == 3
        assert r.stdout == ""

    def test_no_disabled_file_proceeds(self, tmp_path):
        r = _run_builder(
            "--nth", "1", "--date", "2026-10-14",
            "--daily-report-dir", str(tmp_path / "reports"),
            "--ledger-path", str(tmp_path / "ledger" / "2026-10.md"),
            "--state-file", str(tmp_path / "state.json"),
        )
        assert r.returncode == 0
        assert r.stdout.strip()


class TestNthBoundaries:
    def test_nth_zero_rejected_exit_2(self, tmp_path):
        r = _run_builder("--nth", "0", "--date", "2026-10-14",
                         "--state-file", str(tmp_path / "state.json"))
        assert r.returncode == 2
        assert r.stdout == ""

    def test_nth_negative_rejected_exit_2(self, tmp_path):
        r = _run_builder("--nth", "-1", "--date", "2026-10-14",
                         "--state-file", str(tmp_path / "state.json"))
        assert r.returncode == 2

    def test_preset_state_wraps_correctly(self, tmp_path):
        # state nth=4 → next auto-increment 5 → (5-1)%4=0 → theme index 0
        state_file = tmp_path / "state.json"
        state_file.write_text(json.dumps({"nth": 4}), encoding="utf-8")
        r = _run_builder("--date", "2026-10-14", "--state-file", str(state_file))
        assert r.returncode == 0
        assert builder.THEMES[0][1] in r.stdout
        assert json.loads(state_file.read_text(encoding="utf-8"))["nth"] == 5

    def test_preset_state_corrupt_falls_back_to_1(self, tmp_path):
        state_file = tmp_path / "state.json"
        state_file.write_text("not json", encoding="utf-8")
        r = _run_builder("--date", "2026-10-14", "--state-file", str(state_file))
        assert r.returncode == 0
        assert builder.THEMES[0][1] in r.stdout
        assert json.loads(state_file.read_text(encoding="utf-8"))["nth"] == 1


class TestSectionConsistency:
    def test_parse_sections_finds_all_theme_sections(self):
        sections = builder.parse_sections(TEMPLATE_PATH.read_text(encoding="utf-8"))
        for n in (0, 1, 2, 3, 4, 5, 6, 7, 8):
            assert n in sections, f"parse_sections lost §{n}"

    def test_extract_theme_body_strips_heading_and_trailing_rule(self):
        text = "## 4. 主题素材 A\n\n正文第一行\n\n正文第二行\n\n---\n\n"
        body = builder.extract_theme_body({4: text}, 4)
        assert body == "正文第一行\n\n正文第二行"
        assert "## 4." not in body
        assert not body.endswith("---")

    def test_extract_theme_body_keeps_inner_section_like_lines(self):
        # inner "## " lines (e.g. report skeleton) must not be dropped
        text = "## 3. 产出\n\n## 本期元信息\n\n内容\n"
        body = builder.extract_theme_body({3: text}, 3)
        assert "## 本期元信息" in body

    def test_parse_sections_ignores_hash_inside_code_block(self):
        text = "## 1. a\n\n```\n## 9. fake\n```\n\n## 2. b\n\ncontent\n"
        sections = builder.parse_sections(text)
        assert set(sections) == {1, 2}
        assert "fake" in sections[1]

    def test_theme_body_of_real_template_matches_material(self):
        sections = builder.parse_sections(TEMPLATE_PATH.read_text(encoding="utf-8"))
        for section_num, _zh, _key in builder.THEMES:
            body = builder.extract_theme_body(sections, section_num)
            assert body, f"theme body §{section_num} empty"
            assert "## " != body.splitlines()[0][:3] or "素材" in sections[section_num].splitlines()[0]


class TestByteForcedNthOutput:
    def test_forced_nth_1_to_4_outputs_are_stable_and_distinct(self, tmp_path):
        digests = []
        for nth in range(1, 5):
            out = tmp_path / f"p{nth}.md"
            r = _run_builder(
                "--nth", str(nth), "--date", "2026-10-14",
                "--state-file", str(tmp_path / "state.json"),
                "--output", str(out),
            )
            assert r.returncode == 0
            digests.append(out.read_bytes())
        # four distinct assemblies; forced rerun of the same nth is byte-identical
        assert len({d for d in digests}) == 4
        r = _run_builder(
            "--nth", "3", "--date", "2026-10-14",
            "--state-file", str(tmp_path / "state.json"),
            "--output", str(tmp_path / "p3-again.md"),
        )
        assert r.returncode == 0
        assert (tmp_path / "p3-again.md").read_bytes() == digests[2]


class TestDefaultStateFilePath:
    def test_default_state_file_lands_in_repo(self, tmp_path):
        """§SPEC-022 hardening (SEE-1440 / 8e0c896702d2): the DEFAULT counter
        path must resolve inside the repo ledger dir — never the legacy
        out-of-repo ~/.multica/toolchain-reports/. Every other test in this
        file passes --state-file explicitly, leaving the default branch
        unguarded (mutant revert-to-home survived the full suite)."""
        args = argparse.Namespace(
            repo_root=str(tmp_path),
            state_file=None,
            ledger_path=str(tmp_path / "ledger.md"),
            daily_report_dir=str(tmp_path / "reports"),
        )
        _template, _daily, _ledger, state = builder.resolve_paths(args, "2026-10-21")
        assert state == (
            tmp_path / "review-prompts" / "toolchain" / "ledger" / "review-state.json"
        )
        assert ".multica" not in str(state)
