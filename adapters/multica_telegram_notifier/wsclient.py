"""Minimal RFC6455 WebSocket client, stdlib only.

No third-party dependency is intentionally taken: dev-forge scripts run in
minimal environments and tests/requirements.txt pins nothing beyond pytest.
Covers exactly what the Multica endpoint needs — handshake with accept-key
validation, masked client frames, text messages, automatic pong replies to
server pings (the server closes idle connections after 60 s without one),
fragment reassembly, and tolerance for malformed frames (ignore and keep
reading per §SPEC-003).
"""

import base64
import hashlib
import os
import socket
import ssl
import struct
import urllib.parse

WS_GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
MAX_FRAME_BYTES = 1 << 20
_HANDSHAKE_READ_LIMIT = 64 * 1024

OP_CONT = 0x0
OP_TEXT = 0x1
OP_CLOSE = 0x8
OP_PING = 0x9
OP_PONG = 0xA


class WebSocketError(Exception):
    pass


class WebSocketClosed(WebSocketError):
    pass


def parse_ws_url(url: str):
    parts = urllib.parse.urlsplit(url)
    if parts.scheme == "ws":
        tls, default_port = False, 80
    elif parts.scheme == "wss":
        tls, default_port = True, 443
    else:
        raise WebSocketError(f"unsupported ws url scheme: {parts.scheme!r}")
    if not parts.hostname:
        raise WebSocketError(f"ws url missing host: {url!r}")
    path = parts.path or "/"
    if parts.query:
        path += "?" + parts.query
    return parts.hostname, parts.port or default_port, path, tls


class WSClient:
    def __init__(self, url: str, connect_timeout: float = 10.0,
                 max_frame_bytes: int = MAX_FRAME_BYTES, read_timeout: float = 90.0):
        self.url = url
        self.connect_timeout = connect_timeout
        self.max_frame_bytes = max_frame_bytes
        self.read_timeout = read_timeout
        self._sock = None
        self._frag_parts = None

    def connect(self) -> None:
        host, port, path, tls = parse_ws_url(self.url)
        self._sock = socket.create_connection((host, port), timeout=self.connect_timeout)
        if tls:
            context = ssl.create_default_context()
            self._sock = context.wrap_socket(self._sock, server_hostname=host)
        try:
            self._handshake(host, port, path)
        except (WebSocketError, OSError):
            self.close()
            raise
        # Handshake uses the connect timeout; steady-state reads stay bounded:
        # a half-open connection would otherwise block recv forever and
        # silently drop notifications. The server pings every ~54 s, so a
        # longer quiet stretch means the link is dead — end the session so
        # the caller can rebuild it.
        self._sock.settimeout(self.read_timeout)

    def send_text(self, text: str) -> None:
        self._send_frame(OP_TEXT, text.encode("utf-8"))

    def recv_message(self) -> str:
        while True:
            fin, opcode, payload = self._read_frame()
            if opcode == OP_PING:
                self._send_frame(OP_PONG, payload)
                continue
            if opcode == OP_CLOSE:
                self._send_frame(OP_CLOSE, b"")
                raise WebSocketClosed("server closed connection")
            if opcode == OP_TEXT:
                text = self._decode_text(payload)
                if text is None:
                    continue
                if fin:
                    return text
                self._frag_parts = [text]
                continue
            if opcode == OP_CONT:
                text = self._handle_continuation(fin, payload)
                if text is not None:
                    return text
                continue
            # Unsolicited pong, binary or unknown opcode: not a text message.
            continue

    def close(self) -> None:
        # Best-effort teardown: close() must never mask the session error
        # that triggered it, and may run on an already-dead socket.
        if self._sock is not None:
            try:
                self._send_frame(OP_CLOSE, b"")
            except (OSError, WebSocketError):
                pass
            try:
                self._sock.close()
            except OSError:
                pass
            self._sock = None

    # --- internals ---

    def _handshake(self, host, port, path) -> None:
        key = base64.b64encode(os.urandom(16)).decode()
        request = (
            f"GET {path} HTTP/1.1\r\n"
            f"Host: {host}:{port}\r\n"
            "Upgrade: websocket\r\n"
            "Connection: Upgrade\r\n"
            f"Sec-WebSocket-Key: {key}\r\n"
            "Sec-WebSocket-Version: 13\r\n\r\n"
        )
        self._sock.sendall(request.encode("utf-8"))
        status, accept = self._read_handshake_response()
        if " 101 " not in status + " ":
            raise WebSocketError(f"websocket handshake failed: {status.strip()}")
        expected = base64.b64encode(hashlib.sha1((key + WS_GUID).encode()).digest()).decode()
        if accept != expected:
            raise WebSocketError("websocket accept key mismatch")

    def _read_handshake_response(self):
        buf = b""
        while b"\r\n\r\n" not in buf:
            chunk = self._sock.recv(4096)
            if not chunk:
                raise WebSocketError("connection closed during handshake")
            buf += chunk
            if len(buf) > _HANDSHAKE_READ_LIMIT:
                raise WebSocketError("handshake response too large")
        head, _, body = buf.partition(b"\r\n\r\n")
        lines = head.decode("utf-8", errors="replace").split("\r\n")
        accept = ""
        for line in lines[1:]:
            name, _, value = line.partition(":")
            if name.strip().lower() == "sec-websocket-accept":
                accept = value.strip()
        if " 101 " in (lines[0] + " "):
            return lines[0], accept
        detail = body[:200].decode("utf-8", errors="replace").strip()
        return lines[0] + (" " + detail if detail else ""), accept

    def _handle_continuation(self, fin, payload):
        if self._frag_parts is None:
            return None
        text = self._decode_text(payload)
        if text is None:
            self._frag_parts = None
            return None
        self._frag_parts.append(text)
        if fin:
            joined = "".join(self._frag_parts)
            self._frag_parts = None
            return joined
        return None

    def _decode_text(self, payload: bytes):
        try:
            return payload.decode("utf-8")
        except UnicodeDecodeError:
            # Malformed text payload: drop any partial fragment and keep reading.
            self._frag_parts = None
            return None

    def _read_frame(self):
        b1, b2 = self._recv_exact(2)
        fin = bool(b1 & 0x80)
        opcode = b1 & 0x0F
        masked = bool(b2 & 0x80)
        length = b2 & 0x7F
        if length == 126:
            (length,) = struct.unpack("!H", self._recv_exact(2))
        elif length == 127:
            (length,) = struct.unpack("!Q", self._recv_exact(8))
        if length > self.max_frame_bytes:
            # A length this large means a desynchronized stream; continuing
            # would silently hang, so fail the session explicitly instead.
            raise WebSocketError(f"frame exceeds limit: {length} bytes")
        mask_key = self._recv_exact(4) if masked else b"\x00\x00\x00\x00"
        payload = self._recv_exact(length)
        if masked:
            payload = bytes(b ^ mask_key[i % 4] for i, b in enumerate(payload))
        return fin, opcode, payload

    def _recv_exact(self, count: int) -> bytes:
        chunks = bytearray()
        while len(chunks) < count:
            try:
                chunk = self._sock.recv(count - len(chunks))
            except TimeoutError:
                # socket.timeout aliases TimeoutError; must precede OSError.
                raise WebSocketClosed(
                    f"no frame within {self.read_timeout}s (read timeout)") from None
            except (ConnectionResetError, OSError) as exc:
                raise WebSocketClosed(f"connection lost: {exc}") from exc
            if not chunk:
                raise WebSocketClosed("connection closed by peer")
            chunks.extend(chunk)
        return bytes(chunks)

    def _send_frame(self, opcode: int, payload: bytes) -> None:
        if self._sock is None:
            raise WebSocketError("socket is not connected")
        mask_key = os.urandom(4)
        masked = bytes(b ^ mask_key[i % 4] for i, b in enumerate(payload))
        header = bytearray([0x80 | opcode])
        n = len(payload)
        if n < 126:
            header.append(0x80 | n)
        elif n < 65536:
            header.append(0x80 | 126)
            header.extend(struct.pack("!H", n))
        else:
            header.append(0x80 | 127)
            header.extend(struct.pack("!Q", n))
        header.extend(mask_key)
        self._sock.sendall(bytes(header) + masked)
