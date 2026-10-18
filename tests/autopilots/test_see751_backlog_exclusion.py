"""Unit tests for SEE-751: exclude backlog from issue status check scanning.

Verifies that:
1. STATUSES constant no longer contains "backlog"
2. STATUSES retains the 3 active statuses (todo, in_progress, blocked)
3. The script's main() loop iterates only over the 3 expected statuses
4. No code path in issue_status_check.py still references "backlog"
"""

import os
import sys

import pytest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "..", "autopilots"))


# ---------------------------------------------------------------------------
# Test 1: STATUSES constant excludes backlog
# ---------------------------------------------------------------------------

class TestStatusesConstant:
    """Verify STATUSES module-level constant is correctly defined."""

    def test_statuses_does_not_contain_backlog(self):
        from issue_status_check import STATUSES
        assert "backlog" not in STATUSES, (
            "STATUSES must not contain 'backlog' — SEE-751 requirement"
        )

    def test_statuses_exact_value(self):
        from issue_status_check import STATUSES
        assert STATUSES == ["todo", "in_progress", "blocked"]

    def test_statuses_has_exactly_three_entries(self):
        from issue_status_check import STATUSES
        assert len(STATUSES) == 3

    def test_statuses_contains_required_active_statuses(self):
        from issue_status_check import STATUSES
        for required in ["todo", "in_progress", "blocked"]:
            assert required in STATUSES, f"STATUSES must include '{required}'"


# ---------------------------------------------------------------------------
# Test 2: Source code has no leftover "backlog" string references
# ---------------------------------------------------------------------------

class TestNoBacklogReferences:
    """Verify the source file has no references to 'backlog' anywhere."""

    @pytest.fixture
    def source_code(self):
        script_path = os.path.join(
            os.path.dirname(__file__), "..", "..", "autopilots", "issue_status_check.py"
        )
        with open(script_path, "r", encoding="utf-8") as f:
            return f.read()

    def test_no_string_literal_backlog(self, source_code):
        """The string 'backlog' must not appear anywhere in the script source."""
        assert '"backlog"' not in source_code, (
            "Found leftover 'backlog' string literal in issue_status_check.py"
        )
        assert "'backlog'" not in source_code, (
            "Found leftover 'backlog' string literal in issue_status_check.py"
        )

    def test_no_word_backlog_in_code(self, source_code):
        """The word 'backlog' must not appear as an identifier/keyword reference."""
        # Check for any word boundary match
        import re
        matches = re.findall(r'\bbacklog\b', source_code)
        assert len(matches) == 0, (
            f"Found {len(matches)} 'backlog' references in issue_status_check.py: {matches}"
        )
