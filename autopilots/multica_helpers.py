"""Shared constants and helpers for Multica workspace scripts.

Used by local_repo_check.py.
"""

import json
import os
import shlex
import subprocess
import sys
import time

# --- Agent maps ---

AGENT_MAP = {
    "fac3e3a1-dcda-498d-8613-e8c2811f3ef5": "[@Atlas](mention://agent/fac3e3a1-dcda-498d-8613-e8c2811f3ef5)",
    "809951ab-c70c-48c3-b0d6-7b16b49e1ce3": "[@Archi](mention://agent/809951ab-c70c-48c3-b0d6-7b16b49e1ce3)",
    "a5c250e8-7257-466e-b45a-03f995c7206c": "[@Bachi](mention://agent/a5c250e8-7257-466e-b45a-03f995c7206c)",
    "23354e78-8322-418b-b44d-375287a0650c": "[@Fronti](mention://agent/23354e78-8322-418b-b44d-375287a0650c)",
    "2660961d-6add-4d15-8d1b-dea446142a94": "[@Revy](mention://agent/2660961d-6add-4d15-8d1b-dea446142a94)",
    "3c6b6d88-ce6c-4e02-a78e-24ee08e70c85": "[@Refacty](mention://agent/3c6b6d88-ce6c-4e02-a78e-24ee08e70c85)",
    "b2384294-919a-4a91-9f35-2c45848577aa": "[@Chekky](mention://agent/b2384294-919a-4a91-9f35-2c45848577aa)",
    "77320e17-c79c-4389-9575-27cc1a1d7e19": "[@Harti](mention://agent/77320e17-c79c-4389-9575-27cc1a1d7e19)",
    "6462d805-1d32-4a7f-97db-8c01e78a56ae": "[@jerry](mention://member/6462d805-1d32-4a7f-97db-8c01e78a56ae)",
}

AGENT_NAME_MAP = {
    "archi": "809951ab-c70c-48c3-b0d6-7b16b49e1ce3",
    "bachi": "a5c250e8-7257-466e-b45a-03f995c7206c",
    "fronti": "23354e78-8322-418b-b44d-375287a0650c",
    "revy": "2660961d-6add-4d15-8d1b-dea446142a94",
    "refacty": "3c6b6d88-ce6c-4e02-a78e-24ee08e70c85",
    "chekky": "b2384294-919a-4a91-9f35-2c45848577aa",
    "harti": "77320e17-c79c-4389-9575-27cc1a1d7e19",
    "atlas": "fac3e3a1-dcda-498d-8613-e8c2811f3ef5",
    "jerry": "6462d805-1d32-4a7f-97db-8c01e78a56ae",
}

# --- Branch scanning ---

# Maps remote branch prefix to agent name resolution strategy.
# None  → extract agent name from the next path component (e.g. agent/bachi/xxx → bachi)
# str   → fixed agent name (e.g. revy/test-xxx → revy)
# "unknown" → cannot determine agent; skip @mention
BRANCH_PREFIX_MAP = {
    "agent": None,
    "revy": "revy",
    "feature": "unknown",
    "fix": "unknown",
    "merge": "unknown",
}


# --- Constants ---

INFRA_LABEL = "2eba729e-0c83-4444-9fc5-0afb8a67427c"
CHORE_LABEL = "db329c0c-696d-4268-b57e-c5cee453e9ca"
PROJECT_ID = "f0db1de0-e7b8-4fc9-b839-5a6abba0ee86"
ATLAS_ID = "fac3e3a1-dcda-498d-8613-e8c2811f3ef5"

BACKOFF_DELAYS = [1, 2, 4]

# --- Persistent state home ---
# Autopilot state must survive reboots, so it lives under ~/.multica rather
# than /tmp (which is wiped on restart). Overridable via MULTICA_HOME for tests.
MULTICA_HOME = os.path.expanduser(os.environ.get("MULTICA_HOME", "~/.multica"))
WATCHDOG_STATE_FILE = os.path.join(MULTICA_HOME, "watchdog_state.json")
WORKSPACE_MUTEX_FILE = os.path.join(MULTICA_HOME, "autopilot_workspace.lock")


# --- CLI helpers ---

def multica_cli(cmd, max_retries=3, timeout=30, stdin_input=None):
    """Run a multica CLI command with exponential-backoff retry.

    Exception handling distinguishes the failure mode (SEE-956 H8):
    - FileNotFoundError: the multica binary itself is missing — unrecoverable,
      so we fail fast without burning retries.
    - TimeoutExpired: transient; retry with backoff.
    - Other Exception: retry with backoff, then surface the message.
    """
    args = shlex.split(cmd) if isinstance(cmd, str) else cmd
    for attempt in range(max_retries):
        try:
            r = subprocess.run(
                args, shell=False, capture_output=True, text=True,
                encoding="utf-8", errors="replace", timeout=timeout,
                input=stdin_input,
            )
            if r.returncode == 0:
                return True, r.stdout.strip()
            err = r.stderr.strip() if r.stderr else f"exit {r.returncode}"
            if attempt < max_retries - 1:
                delay = BACKOFF_DELAYS[attempt] if attempt < len(BACKOFF_DELAYS) else BACKOFF_DELAYS[-1]
                time.sleep(delay)
            else:
                return False, err
        except FileNotFoundError as e:
            # Binary not found — retrying won't help; report immediately.
            return False, f"command not found: {e}"
        except subprocess.TimeoutExpired:
            if attempt < max_retries - 1:
                delay = BACKOFF_DELAYS[attempt] if attempt < len(BACKOFF_DELAYS) else BACKOFF_DELAYS[-1]
                time.sleep(delay)
            else:
                return False, f"timeout after {timeout}s"
        except Exception as e:
            if attempt < max_retries - 1:
                delay = BACKOFF_DELAYS[attempt] if attempt < len(BACKOFF_DELAYS) else BACKOFF_DELAYS[-1]
                time.sleep(delay)
            else:
                return False, str(e)
    return False, "unknown error"


def multica_stdin_cmd(base_cmd, content, timeout=30):
    """Run a multica command that reads content from stdin."""
    return multica_cli(base_cmd, timeout=timeout, stdin_input=content)


def log_error(msg):
    """Write a phase error to stderr."""
    sys.stderr.write(f"[Phase 2 ERROR] {msg}\n")


# --- PID file locking ---

if sys.platform != "win32":
    import fcntl
    import errno
else:
    import ctypes

_PID_LOCK_TIMEOUT = 300


def _pid_exists(pid: int) -> bool:
    """Check if a process with the given PID is running. Cross-platform."""
    if sys.platform == "win32":
        try:
            kernel32 = ctypes.windll.kernel32
            handle = kernel32.OpenProcess(0x1000, False, pid)
            if handle:
                kernel32.CloseHandle(handle)
                return True
            return False
        except Exception:
            return True
    else:
        try:
            os.kill(pid, 0)
            return True
        except OSError as err:
            if err.errno == errno.ESRCH:
                return False
            return True


class PidFileLock:
    """Atomic PID file lock using OS-level file locking (context manager).

    Uses fcntl.flock(LOCK_EX | LOCK_NB) on Unix, msvcrt.locking on Windows.
    The lock is released automatically when the file descriptor is closed.
    """

    def __init__(self, pid_file: str):
        self.pid_file = pid_file
        self._fd: int | None = None

    def __enter__(self) -> "PidFileLock":
        if not self.acquire():
            sys.exit(1)
        return self

    def __exit__(self, *args: object) -> None:
        self.release()

    def acquire(self) -> bool:
        """Acquire PID file lock atomically. Returns False if another process holds it."""
        try:
            fd = os.open(self.pid_file, os.O_RDWR | os.O_CREAT, 0o600)
        except OSError as e:
            print(json.dumps({"error": f"Cannot open PID file {self.pid_file}: {e}"}), file=sys.stderr)
            return False

        try:
            if sys.platform != "win32":
                fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
            else:
                import msvcrt
                msvcrt.locking(fd, msvcrt.LK_NBLCK, 1)
        except OSError:
            try:
                os.lseek(fd, 0, os.SEEK_SET)
                pid_str = os.read(fd, 32).decode("utf-8").strip()
                pid = int(pid_str) if pid_str.isdigit() else None
            except (OSError, ValueError):
                pid = None
            os.close(fd)
            if pid is not None and _pid_exists(pid):
                print(json.dumps({"error": f"Already running with PID {pid}"}), file=sys.stderr)
            else:
                print(json.dumps({"error": f"Lock held, PID {pid} (state unknown)"}), file=sys.stderr)
            return False

        try:
            os.lseek(fd, 0, os.SEEK_SET)
            os.truncate(fd, 0)
            os.write(fd, str(os.getpid()).encode("utf-8"))
        except OSError as e:
            print(json.dumps({"error": f"Cannot write PID file: {e}"}), file=sys.stderr)
            os.close(fd)
            return False

        self._fd = fd
        return True

    def release(self) -> None:
        """Release the PID file lock and remove the file."""
        if self._fd is not None:
            try:
                os.close(self._fd)
            except OSError:
                pass
            self._fd = None
        if self.pid_file:
            try:
                os.remove(self.pid_file)
            except OSError:
                pass


class WorkspaceMutex:
    """Advisory workspace-level lock to serialize autopilot cron runs (SEE-956 L3).

    Complements PidFileLock: PidFileLock is per-script (exits on contention so a
    second cron of the *same* script no-ops), but two *different* autopilots can
    still run concurrently and both touch the workspace (checkouts, worktrees,
    state files). WorkspaceMutex coordinates them with a bounded wait: it polls
    every 2 s up to ``timeout`` seconds, then proceeds advisory-style (logs and
    continues) rather than permanently stalling a cron job that could not get
    the lock. Locking is best-effort — a process that dies holding it is ignored
    because flock releases automatically on fd close / process exit.
    """

    def __init__(self, mutex_file: str = WORKSPACE_MUTEX_FILE, timeout: int = 120, label: str = ""):
        self.mutex_file = mutex_file
        self.timeout = max(0, int(timeout))
        self.label = label or "autopilot"
        self._fd: int | None = None
        self._acquired = False

    def __enter__(self) -> "WorkspaceMutex":
        self.acquire()
        return self

    def __exit__(self, *args: object) -> None:
        self.release()

    def acquire(self) -> bool:
        try:
            os.makedirs(os.path.dirname(self.mutex_file) or ".", exist_ok=True)
        except OSError:
            pass
        try:
            fd = os.open(self.mutex_file, os.O_RDWR | os.O_CREAT, 0o644)
        except OSError as e:
            print(json.dumps({"warn": f"{self.label}: cannot open mutex, proceeding unlocked: {e}"}), file=sys.stderr)
            return False

        deadline_ticks = time.monotonic() + self.timeout
        while True:
            try:
                if sys.platform != "win32":
                    fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
                else:
                    import msvcrt
                    msvcrt.locking(fd, msvcrt.LK_NBLCK, 1)
                self._fd = fd
                self._acquired = True
                try:
                    os.lseek(fd, 0, os.SEEK_SET)
                    os.truncate(fd, 0)
                    os.write(fd, str(os.getpid()).encode("utf-8"))
                except OSError:
                    pass
                return True
            except OSError:
                remaining = deadline_ticks - time.monotonic()
                if remaining <= 0:
                    print(json.dumps({"warn": f"{self.label}: workspace mutex busy after {self.timeout}s, proceeding advisory"}), file=sys.stderr)
                    try:
                        os.close(fd)
                    except OSError:
                        pass
                    return False
                time.sleep(2)

    def release(self) -> None:
        if self._fd is not None:
            # Truncate the PID text BEFORE unlocking, while still holding the
            # flock: the lock FILE persisting with a dead PID makes E3 residue
            # checks (toolchain_daily_check) fire even though flock is free.
            # Truncating under the lock is race-free — a concurrent acquirer can
            # only write its own PID after we release. File itself stays (other
            # openers may hold the fd); empty content = no residue. (SEE-1234)
            try:
                os.ftruncate(self._fd, 0)
            except OSError as e:
                sys.stderr.write(json.dumps(
                    {"warn": f"{self.label}: mutex truncate failed, PID text may remain: {e}"}
                ) + "\n")
            try:
                if sys.platform != "win32":
                    fcntl.flock(self._fd, fcntl.LOCK_UN)
            except OSError:
                pass
            try:
                os.close(self._fd)
            except OSError:
                pass
            self._fd = None
            self._acquired = False
