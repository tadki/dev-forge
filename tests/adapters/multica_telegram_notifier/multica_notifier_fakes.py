"""Test fakes for the Multica → Telegram notifier suite.

Lives in a uniquely named module (not conftest.py) so test files can import it
by name without colliding with other conftest.py modules in the repo suite.

- FakeMulticaWS: scriptable local WebSocket server speaking the same wire
  contract as the real Multica `/ws` endpoint (auth first-frame, auth_ack,
  error-then-close, server pings).
- FakeTelegram: local HTTP server standing in for api.telegram.org.
"""

import base64
import hashlib
import json
import socket
import struct
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

WS_GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"


# --- minimal server-side WS frame helpers (test-only) ---


def server_send_frame(sock, opcode, payload=b"", fin=True):
    b1 = (0x80 if fin else 0) | opcode
    n = len(payload)
    if n < 126:
        header = struct.pack("!BB", b1, n)
    elif n < 65536:
        header = struct.pack("!BBH", b1, 126, n)
    else:
        header = struct.pack("!BBQ", b1, 127, n)
    sock.sendall(header + payload)


def server_recv_frame(sock, timeout=5.0):
    """Read one masked client frame. Returns (opcode, payload)."""
    sock.settimeout(timeout)
    b1, b2 = sock.recv(2)
    opcode = b1 & 0x0F
    masked = bool(b2 & 0x80)
    ln = b2 & 0x7F
    if ln == 126:
        (ln,) = struct.unpack("!H", sock.recv(2))
    elif ln == 127:
        (ln,) = struct.unpack("!Q", sock.recv(8))
    mask = sock.recv(4) if masked else b"\x00\x00\x00\x00"
    payload = b""
    while len(payload) < ln:
        chunk = sock.recv(ln - len(payload))
        if not chunk:
            break
        payload += chunk
    if masked:
        payload = bytes(b ^ mask[i % 4] for i, b in enumerate(payload))
    return opcode, payload


def http_upgrade_handshake(sock):
    """Complete the HTTP upgrade; returns the requested path+query."""
    buf = b""
    while b"\r\n\r\n" not in buf:
        chunk = sock.recv(4096)
        if not chunk:
            raise RuntimeError("client closed during handshake")
        buf += chunk
    head, _, _rest = buf.partition(b"\r\n\r\n")
    lines = head.decode("utf-8", errors="replace").split("\r\n")
    path = lines[0].split(" ")[1] if len(lines[0].split(" ")) > 1 else "/"
    key = None
    for line in lines[1:]:
        name, _, value = line.partition(":")
        if name.strip().lower() == "sec-websocket-key":
            key = value.strip()
    if key is None:
        raise RuntimeError("no Sec-WebSocket-Key in client handshake")
    accept = base64.b64encode(hashlib.sha1((key + WS_GUID).encode()).digest()).decode()
    resp = (
        "HTTP/1.1 101 Switching Protocols\r\n"
        "Upgrade: websocket\r\nConnection: Upgrade\r\n"
        f"Sec-WebSocket-Accept: {accept}\r\n\r\n"
    )
    sock.sendall(resp.encode())
    return path


class FakeMulticaWS:
    """Scriptable fake of the Multica realtime endpoint.

    reject_auth_times: first N connections get {"error":"invalid token"} + close.
    script: actions after auth_ack, each a tuple:
      ("text", str)        send a text frame
      ("ping", bytes)      send a ping frame
      ("raw", bytes)       send a pre-built raw frame (malformed shapes etc.)
      ("sleep", seconds)   pause
      ("close",)           close the TCP connection
    """

    def __init__(self, reject_auth_times=0, script=()):
        self.reject_auth_times = reject_auth_times
        self.script = list(script)
        self.connect_count = 0
        self.received = []  # (opcode, payload str) client frames post-handshake
        self._lock = threading.Lock()
        self._sock = socket.socket()
        self._sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        self._sock.bind(("127.0.0.1", 0))
        self._sock.listen(8)
        self.port = self._sock.getsockname()[1]
        self._stop = threading.Event()
        self._thread = threading.Thread(target=self._serve, daemon=True)
        self._thread.start()

    @property
    def url(self):
        return f"ws://127.0.0.1:{self.port}/ws"

    def close(self):
        self._stop.set()
        try:
            self._sock.close()
        except OSError:
            pass

    def _serve(self):
        while not self._stop.is_set():
            try:
                conn, _addr = self._sock.accept()
            except OSError:
                return
            threading.Thread(target=self._handle, args=(conn,), daemon=True).start()

    def _handle(self, conn):
        with self._lock:
            self.connect_count += 1
        try:
            http_upgrade_handshake(conn)
            opcode, payload = server_recv_frame(conn)
            self.received.append((opcode, payload.decode("utf-8", errors="replace")))
            with self._lock:
                reject = self.reject_auth_times > 0
                if reject:
                    self.reject_auth_times -= 1
            if reject:
                server_send_frame(conn, 0x1, json.dumps({"error": "invalid token"}).encode())
                conn.close()
                return
            server_send_frame(conn, 0x1, b'{"type":"auth_ack"}')
            for action in self.script:
                kind = action[0]
                if kind == "text":
                    server_send_frame(conn, 0x1, action[1].encode("utf-8"))
                elif kind == "ping":
                    server_send_frame(conn, 0x9, action[1])
                elif kind == "raw":
                    conn.sendall(action[1])
                elif kind == "sleep":
                    time.sleep(action[1])
                elif kind == "close":
                    conn.close()
                    return
            # Keep reading client frames until the test tears the server down,
            # mirroring the idle real endpoint (pings, pongs and stray frames
            # keep arriving and must be observable to assertions).
            while not self._stop.is_set():
                try:
                    opcode, payload = server_recv_frame(conn, timeout=0.2)
                    self.received.append((opcode, payload.decode("utf-8", errors="replace")))
                except (socket.timeout, TimeoutError):
                    continue
                except (OSError, ValueError, struct.error):
                    break
            conn.close()
        except (OSError, RuntimeError, ValueError):
            try:
                conn.close()
            except OSError:
                pass


class FakeMulticaAPI:
    """Scriptable fake of the Multica REST read endpoints (agent/issue lookups)
    used by resolver, notifier-integration and E2E tests."""

    def __init__(self, agent_body=None, issue_body=None, agent_status=200,
                 issue_status=200, delay=0.0, agent_raw=None, issue_raw=None,
                 workspace_body=None, workspace_status=200, workspace_raw=None):
        self.agent_body = agent_body if agent_body is not None else {"name": "Bachi"}
        self.issue_body = issue_body if issue_body is not None else {
            "identifier": "SEE-1567", "title": "优化 Telegram 排版"}
        self.workspace_body = workspace_body if workspace_body is not None else {"slug": "seed"}
        self.agent_status = agent_status
        self.issue_status = issue_status
        self.workspace_status = workspace_status
        self.delay = delay
        # Raw byte bodies bypass json.dumps so tests can feed malformed/odd
        # payloads (e.g. invalid JSON) that the resolver must degrade on.
        self.agent_raw = agent_raw
        self.issue_raw = issue_raw
        self.workspace_raw = workspace_raw
        self.requests = []
        self.auth_headers = []
        self._lock = threading.Lock()

        server = self

        class Handler(BaseHTTPRequestHandler):
            def do_GET(self):
                with server._lock:
                    server.requests.append(self.path)
                    server.auth_headers.append(self.headers.get("Authorization", ""))
                if server.delay:
                    time.sleep(server.delay)
                if "/api/workspaces/" in self.path:
                    status, body = server.workspace_status, server.workspace_body
                    raw = server.workspace_raw
                elif "/api/agents/" in self.path:
                    status, body = server.agent_status, server.agent_body
                    raw = server.agent_raw
                else:
                    status, body = server.issue_status, server.issue_body
                    raw = server.issue_raw
                payload = raw if raw is not None else json.dumps(body).encode("utf-8")
                self.send_response(status)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(payload)))
                self.end_headers()
                self.wfile.write(payload)

            def log_message(self, *args):
                pass

        self._http = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        self.port = self._http.server_address[1]
        self._thread = threading.Thread(target=self._http.serve_forever, daemon=True)
        self._thread.start()

    @property
    def base_url(self):
        return f"http://127.0.0.1:{self.port}"

    def close(self):
        self._http.shutdown()
        self._http.server_close()


class FakeTelegram:
    """Fake api.telegram.org. responses: list of (status, body-dict) consumed
    in order per request; exhausted requests get a default ok response."""

    def __init__(self, responses=()):
        self.responses = list(responses)
        self.requests = []  # (path, body dict)
        self._lock = threading.Lock()

        server = self

        class Handler(BaseHTTPRequestHandler):
            def do_POST(self):
                length = int(self.headers.get("Content-Length", 0))
                raw = self.rfile.read(length) if length else b"{}"
                with server._lock:
                    server.requests.append((self.path, json.loads(raw.decode("utf-8"))))
                    status, body = server._next_response(self.path)
                payload = json.dumps(body).encode("utf-8")
                self.send_response(status)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(payload)))
                self.end_headers()
                self.wfile.write(payload)

            def log_message(self, *args):
                pass

        self._http = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        self.port = self._http.server_address[1]
        self._thread = threading.Thread(target=self._http.serve_forever, daemon=True)
        self._thread.start()

    def _next_response(self, path):
        if self.responses:
            return self.responses.pop(0)
        return 200, {"ok": True, "result": {"message_id": 4242}}

    @property
    def base_url(self):
        return f"http://127.0.0.1:{self.port}"

    def close(self):
        self._http.shutdown()
        self._http.server_close()


def wait_for(condition, timeout=5.0, interval=0.01):
    deadline = time.time() + timeout
    while time.time() < deadline:
        if condition():
            return True
        time.sleep(interval)
    return False


def make_inbox_frame(item_overrides=None, workspace_id="ws-target", item_id="item-1",
                     event_type="inbox:new", recipient_id="user-1"):
    item = {
        "id": item_id,
        "workspace_id": workspace_id,
        "recipient_type": "user",
        "recipient_id": recipient_id,
        "type": "issue_assigned",
        "severity": "info",
        "issue_id": "issue-uuid-1",
        "title": "SEE-1561 code 子步骤",
        "body": "Atlas 分配了 code 任务",
        "read": False,
        "archived": False,
        "created_at": "2026-11-11T03:00:00Z",
        "actor_type": "agent",
        "actor_id": "agent-atlas-1",
        "details": {},
    }
    if item_overrides:
        item.update(item_overrides)
    return json.dumps({"type": event_type, "payload": {"item": item}, "actor_id": "actor-1", "actor_type": "agent"})


def make_env(multica, telegram, tmp_path, api=None, **overrides):
    """Config mapping wired to the fakes, with fast test timings.

    api: optional FakeMulticaAPI; when omitted the metadata resolver points at
    the WS fake origin, where REST queries fail fast (bounding timeout below).
    """
    env = {
        "NOTIFIER_MULTICA_PAT": "test-pat-value-0123456789",
        "NOTIFIER_TELEGRAM_BOT_TOKEN": "test-bot-token-value",
        "NOTIFIER_TELEGRAM_CHAT_ID": "987654",
        "NOTIFIER_MULTICA_SERVER_URL": multica.url.replace("ws://", "http://").rsplit("/ws", 1)[0],
        "NOTIFIER_WORKSPACE_ID": "ws-target",
        "NOTIFIER_TELEGRAM_API_BASE": telegram.base_url,
        "NOTIFIER_STATE_FILE": str(tmp_path / "state.json"),
        "NOTIFIER_RECONNECT_BACKOFF": "0.02,0.05",
        "NOTIFIER_SEND_RETRIES": "0.02,0.05",
        "NOTIFIER_CONNECT_TIMEOUT": "3",
        "NOTIFIER_QUERY_TIMEOUT": "0.05",
    }
    if api is not None:
        env["NOTIFIER_API_BASE"] = api.base_url
    env.update(overrides)
    return env


def text_frame_bytes(payload: bytes, fin=True, opcode=0x1):
    """Build a raw (unmasked, server-side) frame with an arbitrary byte
    payload, so tests can split one logical message mid-UTF-8-sequence.
    Use opcode=0x0 for continuation fragments."""
    b1 = (0x80 if fin else 0) | opcode
    n = len(payload)
    if n < 126:
        header = struct.pack("!BB", b1, n)
    elif n < 65536:
        header = struct.pack("!BBH", b1, 126, n)
    else:
        header = struct.pack("!BBQ", b1, 127, n)
    return header + payload
