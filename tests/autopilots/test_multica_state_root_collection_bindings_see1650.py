"""SEE-1650 §SPEC-011 — collection-time state-root binding guard.

The conftest source-level net pins ``MULTICA_HOME`` at conftest import, which
pytest always runs before any test module in this directory is collected.
Every autopilot state-root binding is computed at import time from the
process environment (``multica_helpers.MULTICA_HOME`` /
``WORKSPACE_MUTEX_FILE``, ``architecture_sweep.MULTICA_HOME`` →
``ARCH_PATROL_HOME`` and the state files under it), so a pin that only takes
effect once a test body runs (e.g. moved into a session-scoped autouse
fixture) leaves every collection-time import bound to the ambient root. The
runtime probes in ``test_multica_state_root_source_isolation_see1650.py``
cannot see that shape, and a full-suite run only reddens when another test
module happens to import ``multica_helpers`` first — a collection-order
coincidence.

This module imports both layers at module scope — i.e. at collection time —
and requires their already-bound state roots to live under the root the
suite pinned. The invariant holds in any order: the conftest net runs before
every test module in this directory, so a green result here means the pin
was in place before collection, whatever ran earlier.
"""

import os
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPO_ROOT / "autopilots"))

import architecture_sweep as sweep
import multica_helpers as helpers


def _pinned_root():
    pinned = os.environ.get("MULTICA_HOME")
    assert pinned, (
        "MULTICA_HOME is not pinned in the suite process: the source-level "
        "net in tests/autopilots/conftest.py is missing or disabled"
    )
    return Path(pinned).resolve()


def _assert_bound_under_pinned_root(label, bound):
    root = _pinned_root()
    bound_path = Path(bound).resolve()
    assert bound_path == root or root in bound_path.parents, (
        f"{label} was bound to {bound_path} at import time, which is outside "
        f"the suite-pinned state root {root}; the MULTICA_HOME pin was not in "
        "place before test modules were collected (missing, weakened, "
        "relocated after collection, or pointed at another root)"
    )


def test_helpers_module_binds_its_state_root_to_the_pinned_root():
    _assert_bound_under_pinned_root(
        "multica_helpers.MULTICA_HOME", helpers.MULTICA_HOME)
    _assert_bound_under_pinned_root(
        "multica_helpers.WORKSPACE_MUTEX_FILE", helpers.WORKSPACE_MUTEX_FILE)


def test_sweep_module_binds_state_files_under_the_pinned_root():
    for attr in ("ARCH_PATROL_HOME", "BASELINE_FILE", "REPORT_FILE",
                 "HEARTBEAT_FILE", "REDLINE_MANIFEST", "REDLINE_POINTER_FILE"):
        _assert_bound_under_pinned_root(
            f"architecture_sweep.{attr}", getattr(sweep, attr))
