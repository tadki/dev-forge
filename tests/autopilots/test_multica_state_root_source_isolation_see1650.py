"""SEE-1650 §SPEC-011 — behavior guard for the suite-level state-root net.

§SPEC-010 closes the root cause at the SOURCE: ``tests/autopilots/conftest.py``
pins ``MULTICA_HOME`` to a suite-owned scratch directory at conftest import,
before any test module is collected. Every state-root binding in the autopilot
layer happens at import time from this process's environment
(``multica_helpers.MULTICA_HOME``, ``architecture_sweep.MULTICA_HOME`` →
``arch-patrol/*`` state files, ``WORKSPACE_MUTEX_FILE`` →
``autopilot_workspace.lock``), and test subprocesses inherit this process's
environment — so the pin covers in-process imports, unpinned subprocesses, and
tests added later that forget to isolate.

These tests pin that behavior. If the conftest net is removed, weakened to
inherit a host-exported value, or pinned anywhere but a suite-owned temp
directory, they go red — without reading or writing the machine's real
``~/.multica``: the probes only resolve paths and take the default workspace
mutex, which the net itself keeps inside the suite's scratch.

Pinned contract:
- The suite process carries ``MULTICA_HOME`` pointing at a directory the suite
  created itself (``devforge-suite-state-*`` under the system temp dir) — never
  the ``$HOME/.multica`` fallback, never a host-exported root.
- A fresh interpreter resolving the state root the same way the autopilot
  layer does binds the same suite-owned scratch.
- Taking the DEFAULT workspace mutex (the exact write path behind SEE-1649's
  registered ``autopilot_workspace.lock`` incident) creates the lock under the
  suite-owned scratch.
"""

import os
import subprocess
import sys
import tempfile
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
OWNED_PREFIX = "devforge-suite-state-"


def _home_fallback():
    return (Path(os.environ["HOME"]) / ".multica").resolve()


def _assert_owned_scratch(root):
    assert root.name.startswith(OWNED_PREFIX), (
        f"state root {root} is not a suite-owned scratch (expected the "
        f"{OWNED_PREFIX}* directory tests/autopilots/conftest.py creates); "
        "inherited host values defeat the source-level isolation"
    )
    assert Path(tempfile.gettempdir()).resolve() in root.parents, (
        f"state root {root} must live under the system temp dir, never "
        "inside the repo or the host home"
    )
    assert root != _home_fallback(), (
        f"state root {root} resolved to the $HOME/.multica fallback the "
        "suite must keep unreachable"
    )


def test_suite_process_pins_an_owned_scratch_state_root():
    pinned = os.environ.get("MULTICA_HOME")
    assert pinned, (
        "MULTICA_HOME is not pinned in the suite process: the source-level "
        "net in tests/autopilots/conftest.py is missing or disabled"
    )
    _assert_owned_scratch(Path(pinned).resolve())


def test_fresh_interpreter_binds_the_same_owned_scratch_root():
    pinned = os.environ.get("MULTICA_HOME")
    assert pinned, "source-level net missing (see test_suite_process_pins_an_owned_scratch_state_root)"
    proc = subprocess.run(
        [sys.executable, "-c",
         "import sys; sys.path.insert(0, 'autopilots'); "
         "import multica_helpers; print(multica_helpers.MULTICA_HOME)"],
        cwd=str(REPO_ROOT), env=os.environ.copy(),
        capture_output=True, text=True, timeout=60)
    assert proc.returncode == 0, proc.stderr
    binding = Path(proc.stdout.strip()).resolve()
    assert binding == Path(pinned).resolve(), (
        f"fresh interpreter bound {binding}, not the suite scratch {pinned}; "
        "state-root resolution escaped the net"
    )
    _assert_owned_scratch(binding)


def test_default_workspace_mutex_writes_under_the_owned_scratch_root():
    sys.path.insert(0, str(REPO_ROOT / "autopilots"))
    import multica_helpers as mh

    pinned = os.environ.get("MULTICA_HOME")
    assert pinned, "source-level net missing (see test_suite_process_pins_an_owned_scratch_state_root)"
    with mh.WorkspaceMutex(label="see1650-regression"):
        lock = Path(mh.WORKSPACE_MUTEX_FILE).resolve()
    assert lock.parent == Path(pinned).resolve(), (
        f"default WorkspaceMutex wrote {lock.parent}, not the suite scratch; "
        "the autopilot_workspace.lock write path (§SPEC-010) escaped the net"
    )
    assert lock.name == "autopilot_workspace.lock"
    _assert_owned_scratch(lock.parent)
