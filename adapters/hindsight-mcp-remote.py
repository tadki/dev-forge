#!/usr/bin/env python3
"""stdio→HTTP forwarder for the litellm-gateway hindsight bridge (:4894).

Replaces the local coding-agents plugin's stdio MCP entry. Claude Code (or any
MCP host) launches this process per agent; the memory bank is selected by the
HINDSIGHT_BANK_ID environment variable the platform injects — sent as the
X-Hindsight-Bank header on every request, so every agent keeps an identical
MCP config:

    {"type": "stdio", "command": "python3",
     "args": ["<path-to-this-file>/hindsight-mcp-remote.py"]}

X-Hindsight-Project / X-Hindsight-Workspace are derived once from the local
git worktree so the bridge can scope initiative pages and retain stamps to
this repository.

Pure standard library: no pip/npm dependencies, no network calls at startup.
"""

import json
import os
import re
import subprocess
import sys
import urllib.error
import urllib.request

DEFAULT_MCP_URL = "http://192.168.1.210:4894"
DEFAULT_MCP_PATH = "/hindsight"
REQUEST_TIMEOUT_S = 360.0   # bridge reflect allows up to 330s upstream
NOTIFY_TIMEOUT_S = 30.0
BANK_RE = re.compile(r"[A-Za-z0-9_-]+")  # mixed case is valid: Harti is a real bank id


def die(message: str) -> None:
    print(f"[hindsight-mcp-remote] {message}", file=sys.stderr)
    sys.exit(1)


BANK = os.environ.get("HINDSIGHT_BANK_ID", "").strip()
if not BANK:
    die("HINDSIGHT_BANK_ID is not set — refusing to start. Without it writes would "
        "silently land in the wrong bank; fix the agent's env injection first.")
if not BANK_RE.fullmatch(BANK):
    die(f"HINDSIGHT_BANK_ID {BANK!r} is not a valid bank id (expected [A-Za-z0-9_-]+) — "
        "refusing to start. Check the agent's env injection for typos.")

BASE_URL = ((os.environ.get("HINDSIGHT_MCP_URL") or DEFAULT_MCP_URL).rstrip("/")
            + os.environ.get("HINDSIGHT_MCP_PATH", DEFAULT_MCP_PATH))


def _git_toplevel() -> str | None:
    try:
        out = subprocess.run(["git", "rev-parse", "--show-toplevel"],
                             capture_output=True, text=True, timeout=5)
        return out.stdout.strip() or None
    except Exception:
        return None


_PROJECT = _git_toplevel()
PROJECT = _PROJECT.rstrip("/").rsplit("/", 1)[-1] if _PROJECT else None
WORKSPACE = os.getcwd()

BASE_HEADERS = {
    "Content-Type": "application/json",
    "Accept": "application/json, text/event-stream",
    "X-Hindsight-Bank": BANK,
    "X-Hindsight-Workspace": WORKSPACE,
}
if PROJECT:
    BASE_HEADERS["X-Hindsight-Project"] = PROJECT

print(f"[hindsight-mcp-remote] bank={BANK} url={BASE_URL} project={PROJECT} "
      f"workspace={WORKSPACE}", file=sys.stderr)

_session_id: str | None = None


def _post(message: dict, timeout: float):
    headers = dict(BASE_HEADERS)
    if _session_id:
        headers["Mcp-Session-Id"] = _session_id
    request = urllib.request.Request(BASE_URL, data=json.dumps(message).encode("utf-8"),
                                     headers=headers)
    with urllib.request.urlopen(request, timeout=timeout) as response:
        session = response.headers.get("Mcp-Session-Id")
        if session:
            globals()["_session_id"] = session
        return response.status, response.read().decode("utf-8", "replace")


def _rpc_error(message: dict, text: str, code: int = -32000) -> dict:
    out = {"jsonrpc": "2.0", "error": {"code": code, "message": text}}
    if "id" in message:
        out["id"] = message["id"]
    return out


def send(message: dict) -> dict | None:
    """POST one JSON-RPC frame; returns the response frame, or None for
    notifications (202, no body)."""
    is_request = "id" in message
    timeout = REQUEST_TIMEOUT_S if is_request else NOTIFY_TIMEOUT_S
    try:
        status, body = _post(message, timeout)
    except urllib.error.HTTPError as exc:
        detail = exc.read().decode("utf-8", "replace")[:300]
        if exc.code == 202 or not is_request:
            return None
        return _rpc_error(message, f"bridge HTTP {exc.code}: {detail}")
    except Exception as exc:  # unreachable bridge, timeout, broken pipe
        if not is_request:
            return None
        return _rpc_error(message, f"bridge unreachable: {exc}")

    if status == 202 or not body.strip():
        return None
    for line in body.splitlines():  # SSE-framed: `event: message\ndata: {...}`
        if line.startswith("data: "):
            try:
                return json.loads(line[len("data: "):])
            except ValueError:
                continue
    return None


def main() -> None:
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            message = json.loads(line)
        except ValueError:
            continue
        response = send(message)
        if response is not None:
            sys.stdout.write(json.dumps(response, ensure_ascii=False) + "\n")
            sys.stdout.flush()


if __name__ == "__main__":
    main()
