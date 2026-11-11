"""Minimal RFC6455 client against fake Multica endpoints: handshake,
masking, keepalive, fragmentation, malformed-input tolerance."""

import json
import socket
import struct
import threading
import time

import pytest

from multica_telegram_notifier.wsclient import (
    WebSocketClosed,
    WebSocketError,
    WSClient,
    parse_ws_url,
)

from multica_notifier_fakes import FakeMulticaWS, text_frame_bytes, wait_for


def _refusing_port_server():
    """Starts a plain TCP server answering a fixed HTTP 404; returns
    (port, server_socket)."""
    srv = socket.socket()
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind(("127.0.0.1", 0))
    srv.listen(1)
    port = srv.getsockname()[1]
    response = [b"HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\n\r\n"]

    def serve():
        while True:
            try:
                conn, _ = srv.accept()
            except OSError:
                return
            try:
                conn.recv(4096)
                conn.sendall(response[0])
                conn.close()
            except OSError:
                return

    t = threading.Thread(target=serve, daemon=True)
    t.start()
    return port, srv


class TestParseWsUrl:
    def test_ws_with_port_and_query(self):
        host, port, path, tls = parse_ws_url("ws://h.example:9278/ws?workspace_id=x")
        assert (host, port, path, tls) == ("h.example", 9278, "/ws?workspace_id=x", False)

    def test_wss_default_port(self):
        host, port, path, tls = parse_ws_url("wss://h.example")
        assert (host, port, path, tls) == ("h.example", 443, "/", True)

    def test_rejects_non_ws_scheme(self):
        with pytest.raises(WebSocketError):
            parse_ws_url("http://h.example")


class TestHandshake:
    def test_connect_and_teardown(self, fake_multica):
        client = WSClient(f"{fake_multica.url}?workspace_id=ws-x")
        client.connect()
        assert fake_multica.connect_count == 1
        client.close()

    def test_non_101_response_is_error(self):
        port, srv = _refusing_port_server()
        try:
            client = WSClient(f"ws://127.0.0.1:{port}/ws")
            with pytest.raises(WebSocketError) as exc:
                client.connect()
            assert "404" in str(exc.value)
        finally:
            srv.close()

    def test_bad_accept_key_is_error(self):
        srv = socket.socket()
        srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        srv.bind(("127.0.0.1", 0))
        srv.listen(1)
        port = srv.getsockname()[1]

        def serve():
            try:
                conn, _ = srv.accept()
                conn.recv(4096)
                conn.sendall(
                    b"HTTP/1.1 101 Switching Protocols\r\n"
                    b"Sec-WebSocket-Accept: wrongkeyvaluehere\r\n\r\n"
                )
                conn.close()
            except OSError:
                pass

        threading.Thread(target=serve, daemon=True).start()
        try:
            client = WSClient(f"ws://127.0.0.1:{port}/ws")
            with pytest.raises(WebSocketError):
                client.connect()
        finally:
            srv.close()


class TestDataPath:
    def test_send_text_reaches_server_as_masked_text(self, fake_multica):
        client = WSClient(fake_multica.url)
        client.connect()
        client.send_text(json.dumps({"type": "auth", "payload": {"token": "test-pat-value-0123456789"}}))
        assert wait_for(lambda: fake_multica.received)
        opcode, payload = fake_multica.received[0]
        assert opcode == 0x1
        assert json.loads(payload) == {"type": "auth", "payload": {"token": "test-pat-value-0123456789"}}
        client.close()

    def test_ping_answered_with_pong_and_ack_received(self):
        server = FakeMulticaWS(script=[("ping", b"ka"), ("text", '{"type":"after-ping"}'), ("sleep", 5)])
        try:
            client = WSClient(server.url)
            client.connect()
            client.send_text("hello")
            assert json.loads(client.recv_message()) == {"type": "auth_ack"}
            # The second recv processes the ping (auto-pong) then the text.
            assert json.loads(client.recv_message()) == {"type": "after-ping"}
            client.close()
            assert wait_for(lambda: any(op == 0xA for op, _ in server.received)), \
                "no pong sent for server ping"
        finally:
            server.close()

    def test_server_close_raises_websocketclosed(self):
        server = FakeMulticaWS(script=[("close",)])
        try:
            client = WSClient(server.url)
            client.connect()
            client.send_text("hello")
            with pytest.raises(WebSocketClosed):
                for _ in range(10):
                    client.recv_message()
            client.close()
        finally:
            server.close()


class TestMalformedTolerance:
    def test_non_utf8_payload_ignored_then_text_received(self):
        # FakeMulticaWS auto-sends an auth_ack before the script, so the first
        # recv consumes that; the second must skip the invalid-UTF-8 text frame
        # and return the following valid text (a regression here would decode
        # the bad frame or stall).
        bad = bytes([0x81, 0x03, 0xFF, 0xFE, 0xFD])  # FIN+text, invalid UTF-8
        server = FakeMulticaWS(script=[("raw", bad), ("text", '{"type":"ok"}')])
        try:
            client = WSClient(server.url)
            client.connect()
            client.send_text("hello")
            assert json.loads(client.recv_message()) == {"type": "auth_ack"}
            assert json.loads(client.recv_message()) == {"type": "ok"}
            client.close()
        finally:
            server.close()

    def test_binary_frame_ignored_then_text_received(self):
        binary = bytes([0x82, 0x02, 0x01, 0x02])
        pong = bytes([0x8A, 0x00])  # unsolicited pong, not a text message
        server = FakeMulticaWS(script=[("raw", binary), ("raw", pong),
                                       ("text", '{"type":"ok"}')])
        try:
            client = WSClient(server.url)
            client.connect()
            client.send_text("hello")
            assert json.loads(client.recv_message()) == {"type": "auth_ack"}
            assert json.loads(client.recv_message()) == {"type": "ok"}
            client.close()
        finally:
            server.close()

    def test_fragmented_text_reassembled(self):
        part1 = bytes([0x01, 0x05]) + b'{"typ'   # FIN=0 text, 5-byte part
        part2 = bytes([0x80, 0x08]) + b'e":"ok"}'  # FIN=1 continuation, 8-byte part
        server = FakeMulticaWS(script=[("raw", part1), ("raw", part2)])
        try:
            client = WSClient(server.url)
            client.connect()
            client.send_text("hello")
            assert json.loads(client.recv_message()) == {"type": "auth_ack"}
            assert json.loads(client.recv_message()) == {"type": "ok"}
            client.close()
        finally:
            server.close()

    def test_orphan_continuation_ignored(self):
        # A continuation frame with no preceding fragment start is dropped, and
        # reading continues to the next valid text message.
        orphan = bytes([0x80, 0x02]) + b"ab"
        server = FakeMulticaWS(script=[("raw", orphan), ("text", '{"type":"ok"}')])
        try:
            client = WSClient(server.url)
            client.connect()
            client.send_text("hello")
            assert json.loads(client.recv_message()) == {"type": "auth_ack"}
            assert json.loads(client.recv_message()) == {"type": "ok"}
            client.close()
        finally:
            server.close()

    def test_masked_server_frame_is_unmasked(self):
        # RFC6455 servers normally send unmasked frames, but a masked frame
        # must still be unmasked before decoding.
        payload = b'{"type":"masked-ok"}'
        mask = b"\x01\x02\x03\x04"
        masked = bytes(b ^ mask[i % 4] for i, b in enumerate(payload))
        frame = bytes([0x81, 0x80 | len(payload)]) + mask + masked
        server = FakeMulticaWS(script=[("raw", frame)])
        try:
            client = WSClient(server.url)
            client.connect()
            client.send_text("hello")
            assert json.loads(client.recv_message()) == {"type": "auth_ack"}
            assert json.loads(client.recv_message()) == {"type": "masked-ok"}
            client.close()
        finally:
            server.close()

    def test_fragmented_emoji_split_mid_codepoint_reassembled(self):
        # A legitimate multi-byte character split ACROSS fragments must be
        # reassembled as raw bytes before UTF-8 decoding.
        message = '{"type":"ok","note":"🚀"}'
        raw = message.encode("utf-8")
        cut = raw.index("🚀".encode("utf-8")) + 2  # inside the 4-byte emoji
        server = FakeMulticaWS(script=[
            ("raw", text_frame_bytes(raw[:cut], fin=False)),
            ("raw", text_frame_bytes(raw[cut:], fin=True, opcode=0x0)),
        ])
        try:
            client = WSClient(server.url, read_timeout=2)
            client.connect()
            client.send_text("hello")
            assert json.loads(client.recv_message()) == {"type": "auth_ack"}
            assert json.loads(client.recv_message()) == {"type": "ok", "note": "🚀"}
            client.close()
        finally:
            server.close()

    def test_fragmented_chinese_split_mid_codepoint_reassembled(self):
        message = '{"type":"ok","note":"中文通知"}'
        raw = message.encode("utf-8")
        cut = raw.index("中".encode("utf-8")) + 1  # inside the 3-byte 中
        server = FakeMulticaWS(script=[
            ("raw", text_frame_bytes(raw[:cut], fin=False)),
            ("raw", text_frame_bytes(raw[cut:], fin=True, opcode=0x0)),
        ])
        try:
            client = WSClient(server.url, read_timeout=2)
            client.connect()
            client.send_text("hello")
            assert json.loads(client.recv_message()) == {"type": "auth_ack"}
            assert json.loads(client.recv_message()) == {"type": "ok", "note": "中文通知"}
            client.close()
        finally:
            server.close()

    def test_fragmented_three_way_split_reassembled(self):
        message = '{"type":"ok","note":"🚀中文"}'
        raw = message.encode("utf-8")
        cuts = [raw.index("🚀".encode("utf-8")) + 3, raw.index("文".encode("utf-8")) + 1]
        server = FakeMulticaWS(script=[
            ("raw", text_frame_bytes(raw[:cuts[0]], fin=False)),
            ("raw", text_frame_bytes(raw[cuts[0]:cuts[1]], fin=False, opcode=0x0)),
            ("raw", text_frame_bytes(raw[cuts[1]:], fin=True, opcode=0x0)),
        ])
        try:
            client = WSClient(server.url, read_timeout=2)
            client.connect()
            client.send_text("hello")
            assert json.loads(client.recv_message()) == {"type": "auth_ack"}
            assert json.loads(client.recv_message()) == {"type": "ok", "note": "🚀中文"}
            client.close()
        finally:
            server.close()

    def test_oversize_frame_is_error_not_hang(self):
        declared = struct_len_bytes(2 * 1024 * 1024)
        server = FakeMulticaWS(script=[("raw", declared)])
        try:
            client = WSClient(server.url, max_frame_bytes=1024 * 1024)
            client.connect()
            client.send_text("hello")
            assert json.loads(client.recv_message()) == {"type": "auth_ack"}
            with pytest.raises(WebSocketError):
                client.recv_message()
            client.close()
        finally:
            server.close()


def struct_len_bytes(n):
    """A header declaring a 64-bit length of n bytes with no payload."""
    return struct.pack("!BBQ", 0x81, 127, n)


class TestReadTimeout:
    def test_silent_server_raises_closed_quickly(self):
        server = FakeMulticaWS(script=[("sleep", 5)])
        try:
            client = WSClient(server.url, read_timeout=0.4)
            client.connect()
            client.send_text("hello")
            assert json.loads(client.recv_message()) == {"type": "auth_ack"}
            start = time.monotonic()
            with pytest.raises(WebSocketClosed):
                client.recv_message()
            assert time.monotonic() - start < 3
            client.close()
        finally:
            server.close()


def _raw_tcp_server(handler):
    """Start a one-shot raw TCP server; handler(conn) runs per connection.
    Returns (port, server_socket)."""
    srv = socket.socket()
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind(("127.0.0.1", 0))
    srv.listen(1)
    port = srv.getsockname()[1]

    def serve():
        try:
            conn, _ = srv.accept()
        except OSError:
            return
        try:
            handler(conn)
        except OSError:
            pass
        finally:
            try:
                conn.close()
            except OSError:
                pass

    threading.Thread(target=serve, daemon=True).start()
    return port, srv


class _FakeSock:
    """Minimal socket stand-in for TLS-wiring and teardown branch tests."""

    def __init__(self, send_error=None, close_error=None, recv_error=None):
        self.send_error = send_error
        self.close_error = close_error
        self.recv_error = recv_error
        self.timeout = None
        self.sent = []

    def sendall(self, data):
        if self.send_error is not None:
            raise self.send_error
        self.sent.append(data)

    def settimeout(self, value):
        self.timeout = value

    def close(self):
        if self.close_error is not None:
            raise self.close_error

    def recv(self, _count):
        if self.recv_error is not None:
            raise self.recv_error
        return b""


class TestUrlAndTls:
    def test_url_without_host_is_rejected(self):
        with pytest.raises(WebSocketError):
            parse_ws_url("ws:///only-path")

    def test_wss_wraps_socket_with_tls(self, monkeypatch):
        # The wss branch must build a default TLS context and wrap the socket
        # with the host as SNI; a plain-text connection to a wss URL would
        # silently fail the handshake otherwise.
        import multica_telegram_notifier.wsclient as wsclient_mod
        raw, wrapped = _FakeSock(), _FakeSock()
        calls = {}

        def fake_create_connection(addr, timeout=None):
            calls["addr"] = addr
            calls["timeout"] = timeout
            return raw

        class _Ctx:
            def wrap_socket(self, sock, server_hostname=None):
                calls["wrapped_sock"] = sock
                calls["server_hostname"] = server_hostname
                return wrapped

        monkeypatch.setattr(wsclient_mod.socket, "create_connection", fake_create_connection)
        monkeypatch.setattr(wsclient_mod.ssl, "create_default_context", lambda: _Ctx())
        monkeypatch.setattr(WSClient, "_handshake", lambda self, host, port, path: None)
        client = WSClient("wss://secure.example/ws")
        client.connect()
        assert calls["server_hostname"] == "secure.example"
        assert calls["wrapped_sock"] is raw
        assert client._sock is wrapped
        assert wrapped.timeout == client.read_timeout


class TestCloseFrameAndTeardown:
    def test_server_close_frame_answered_and_raises(self):
        # A server CLOSE frame must be answered with our own CLOSE and surface
        # as WebSocketClosed (not be mistaken for a normal stream end).
        close_frame = bytes([0x88, 0x00])  # FIN + close, no payload
        server = FakeMulticaWS(script=[("raw", close_frame)])
        try:
            client = WSClient(server.url)
            client.connect()
            client.send_text("hello")
            assert json.loads(client.recv_message()) == {"type": "auth_ack"}
            with pytest.raises(WebSocketClosed):
                client.recv_message()
            assert wait_for(lambda: any(op == 0x8 for op, _ in server.received)), \
                "client did not answer the server CLOSE"
            client.close()
        finally:
            server.close()

    def test_close_swallows_send_error(self):
        client = WSClient("ws://h.example/ws")
        client._sock = _FakeSock(send_error=OSError("send fail"))
        client.close()  # must not raise
        assert client._sock is None

    def test_close_swallows_socket_close_error(self):
        client = WSClient("ws://h.example/ws")
        client._sock = _FakeSock(close_error=OSError("close fail"))
        client.close()  # must not raise
        assert client._sock is None


class TestHandshakeFailures:
    def test_connection_closed_during_handshake_is_error(self):
        port, srv = _raw_tcp_server(lambda conn: (conn.recv(4096), None)[1])
        try:
            client = WSClient(f"ws://127.0.0.1:{port}/ws")
            with pytest.raises(WebSocketError) as exc:
                client.connect()
            assert "closed during handshake" in str(exc.value)
        finally:
            srv.close()

    def test_oversize_handshake_response_is_error(self):
        def handler(conn):
            conn.recv(4096)
            conn.sendall(b"A" * 70000)  # never terminates with CRLFCRLF

        port, srv = _raw_tcp_server(handler)
        try:
            client = WSClient(f"ws://127.0.0.1:{port}/ws")
            with pytest.raises(WebSocketError) as exc:
                client.connect()
            assert "too large" in str(exc.value)
        finally:
            srv.close()


class TestRecvAndSendErrors:
    def test_recv_connection_reset_becomes_websocketclosed(self):
        server = FakeMulticaWS(script=[("sleep", 5)])
        try:
            client = WSClient(server.url)
            client.connect()
            client.send_text("hello")
            assert json.loads(client.recv_message()) == {"type": "auth_ack"}
            real = client._sock
            client._sock = _FakeSock(recv_error=ConnectionResetError("reset"))
            with pytest.raises(WebSocketClosed):
                client.recv_message()
            client._sock = real
            client.close()
        finally:
            server.close()

    def test_send_before_connect_raises(self):
        client = WSClient("ws://h.example/ws")
        with pytest.raises(WebSocketError):
            client.send_text("x")

    def test_send_text_medium_and_large_lengths_reach_server(self, fake_multica):
        # Frames of 126..65535 bytes use the 16-bit length header and frames of
        # >=65536 bytes the 64-bit header; both must round-trip to the server.
        client = WSClient(fake_multica.url)
        client.connect()
        client.send_text("m" * 200)
        client.send_text("l" * 70000)
        assert wait_for(
            lambda: any(len(payload) == 70000 for op, payload in fake_multica.received
                        if op == 0x1), timeout=5)
        lens = [len(payload) for op, payload in fake_multica.received if op == 0x1]
        assert 200 in lens and 70000 in lens
        client.close()
