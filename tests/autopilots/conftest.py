import atexit
import os
import shutil
import tempfile

import pytest

# SEE-1650 §SPEC-010 source-level net: the whole autopilot layer resolves its
# state root at IMPORT time from the environment
# (``multica_helpers.MULTICA_HOME`` / ``architecture_sweep.MULTICA_HOME``,
# then ``${MULTICA_HOME:-$HOME/.multica}`` in shell wrappers), and test
# subprocesses inherit this process's environment. Pinning it here — at
# conftest import, before any test module is collected — means every state
# root binding in the suite (in-process imports and unpinned subprocesses,
# including tests added later that forget to isolate) lands in a suite-owned
# scratch directory, never in the machine's real ~/.multica and never in a
# host-exported MULTICA_HOME (the suite must not write a state root it did
# not create). Tests that execute wrappers still pin per-test scratch roots
# (tighter, plus HOME); this net is the floor, not a replacement.
_SUITE_STATE_ROOT = tempfile.mkdtemp(prefix="devforge-suite-state-")
os.environ["MULTICA_HOME"] = _SUITE_STATE_ROOT
atexit.register(shutil.rmtree, _SUITE_STATE_ROOT, ignore_errors=True)


@pytest.fixture
def isolate_arch_patrol_state(tmp_path, monkeypatch):
    """Redirect the sweep's L1 state files into a per-test tmp dir.

    SEE-1593: ``check_gut_silent_skip`` consults the previous L1 report for
    no-input escalation, so tests must never read or write the machine's real
    ``~/.multica/arch-patrol`` state.

    This fixture covers only the in-process module attributes REPORT_FILE and
    BASELINE_FILE. Tests that execute ``architecture_sweep.sh`` as a
    subprocess must also pin ``MULTICA_HOME`` and ``HOME`` in the child
    environment to their own scratch directories; monkeypatching these module
    attributes does not affect the wrapper (SEE-1650). The suite-level
    ``MULTICA_HOME`` pin above is the floor that keeps the fallback shape
    unreachable in the first place.
    """
    import architecture_sweep as sweep

    monkeypatch.setattr(sweep, "REPORT_FILE", str(tmp_path / "last_report.json"))
    monkeypatch.setattr(sweep, "BASELINE_FILE", str(tmp_path / "baseline.jsonl"))
