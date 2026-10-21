"""Structural guard for .github/workflows/ci.yml (SEE-1445 hardening).

The CI hardening items (workflow_dispatch trigger, concurrency
cancel-in-progress, per-job timeout-minutes, minimal top-level permissions)
are pure configuration with no functional code behind them — mutation and
coverage tooling do not apply. These tests guard the structure so a future
edit cannot silently drop a hardening item.

Note: PyYAML parses the bare key `on` as boolean True (YAML 1.1), so the
trigger map is looked up under `True`, not `"on"`.
"""
from __future__ import annotations

from pathlib import Path

import pytest

yaml = pytest.importorskip("yaml")

REPO_ROOT = Path(__file__).resolve().parents[1]
CI_YML = REPO_ROOT / ".github/workflows/ci.yml"


@pytest.fixture(scope="module")
def workflow():
    return yaml.safe_load(CI_YML.read_text(encoding="utf-8"))


def _triggers(wf):
    # YAML 1.1: bare `on` key is loaded as boolean True.
    return wf.get("on") or wf.get(True)


def test_ci_workflow_file_exists():
    assert CI_YML.is_file()


def test_workflow_dispatch_trigger_present(workflow):
    assert "workflow_dispatch" in _triggers(workflow)


def test_push_trigger_targets_main(workflow):
    triggers = _triggers(workflow)
    assert "main" in triggers["push"]["branches"]


def test_pull_request_trigger_present(workflow):
    assert "pull_request" in _triggers(workflow)


def test_concurrency_cancels_in_progress(workflow):
    concurrency = workflow.get("concurrency") or {}
    assert concurrency.get("group"), "concurrency.group must be set"
    assert concurrency.get("cancel-in-progress") is True


def test_top_level_permissions_minimal_read(workflow):
    permissions = workflow.get("permissions") or {}
    assert permissions.get("contents") == "read"
    extra = {k: v for k, v in permissions.items() if k != "contents"}
    assert not extra, f"unexpected extra permissions: {extra}"


def test_every_job_has_timeout_minutes(workflow):
    jobs = workflow.get("jobs") or {}
    assert jobs, "ci.yml must define jobs"
    for name, job in jobs.items():
        timeout = job.get("timeout-minutes")
        assert isinstance(timeout, int) and 0 < timeout <= 60, (
            f"job {name!r} missing/bad timeout-minutes: {timeout!r}"
        )


def test_required_check_jobs_exist(workflow):
    # Branch protection on main requires these exact job names as status
    # checks; renaming either job breaks the merge gate (SEE-1445 R1).
    jobs = workflow.get("jobs") or {}
    for required in ("lint", "engine-tests"):
        assert required in jobs, (
            f"required check job {required!r} missing — branch protection "
            "would deadlock PR merges"
        )
