import os
import sys

# Add autopilot scripts directory to Python path for all tests (SEE-1430:
# autopilots tests migrated from KOL .dev/tests/, scripts live in autopilots/)
autopilots_dir = os.path.join(os.path.dirname(__file__), '..', 'autopilots')
autopilots_dir = os.path.abspath(autopilots_dir)
if autopilots_dir not in sys.path:
    sys.path.insert(0, autopilots_dir)

# §SPEC-023 (SEE-1440 QA HIGH-1): fixture-built git repos commit via bare
# `git commit`, which dies with exit 128 on CI runners that carry no global
# git identity. Env-var identity outranks git config, applies to every git
# subprocess that inherits os.environ (commit/merge/stash/rebase alike), and
# is independent of GIT_CONFIG_GLOBAL — setdefault keeps any explicitly
# provided identity intact.
for _key, _value in (
    ("GIT_AUTHOR_NAME", "dev-forge-ci"),
    ("GIT_AUTHOR_EMAIL", "ci@dev-forge.invalid"),
    ("GIT_COMMITTER_NAME", "dev-forge-ci"),
    ("GIT_COMMITTER_EMAIL", "ci@dev-forge.invalid"),
):
    os.environ.setdefault(_key, _value)


def pytest_configure(config):
    # SEE-1195: tests that need a live Multica daemon / real server access.
    # They are excluded from a default `pytest tests` run; opt in with
    # `pytest tests -m requires_daemon`. See KOL .dev/docs/devtests.md §4.
    config.addinivalue_line(
        "markers",
        "requires_daemon: requires a running Multica daemon and real server "
        "access; excluded from the default suite (run with -m requires_daemon)",
    )
    # SEE-1381 §SPEC-004: register suite-domain markers to silence
    # PytestUnknownMarkWarning (unit/abtest are in active use; e2e mirrors
    # the e2e/ directory semantics for future use).
    config.addinivalue_line("markers", "unit: unit-scope toolchain test")
    config.addinivalue_line("markers", "e2e: end-to-end toolchain test")
    config.addinivalue_line("markers", "abtest: A/B comparison test")


def pytest_collection_modifyitems(config, items):
    # SEE-1195: a bare `pytest tests` must never touch the real daemon or
    # server (a create_issue autopilot trigger leaks a real issue per run).
    # Unless the caller explicitly selects markers via -m, deselect every
    # requires_daemon test so the default full suite is side-effect free.
    if config.getoption("-m", default=None):
        return
    remaining = [
        item for item in items
        if not any(m.name == "requires_daemon" for m in item.iter_markers())
    ]
    deselected = [item for item in items if item not in remaining]
    if deselected:
        config.hook.pytest_deselected(items=deselected)
    items[:] = remaining
