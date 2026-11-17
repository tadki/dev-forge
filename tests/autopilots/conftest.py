import pytest


@pytest.fixture
def isolate_arch_patrol_state(tmp_path, monkeypatch):
    """Redirect the sweep's L1 state files into a per-test tmp dir.

    SEE-1593: ``check_gut_silent_skip`` consults the previous L1 report for
    no-input escalation, so tests must never read or write the machine's real
    ``~/.multica/arch-patrol`` state.
    """
    import architecture_sweep as sweep

    monkeypatch.setattr(sweep, "REPORT_FILE", str(tmp_path / "last_report.json"))
    monkeypatch.setattr(sweep, "BASELINE_FILE", str(tmp_path / "baseline.jsonl"))
