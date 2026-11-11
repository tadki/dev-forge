"""Minimal RFC6455 client against fake Multica endpoints: handshake,
masking, keepalive, fragmentation, malformed-input tolerance."""

import json
import socket
import threading

import pytest

from multica_telegram_notifier.wsclient import (
    WebSocketClosed,
    WebSocketError,
    WSClient,
    parse_ws_url,
)

from multica_notifier_fakes import wait_for


def _refusing_port_server():
    """Starts a plain TCP server answering a fixed HTTP response; returns
    (port, response_bytes, shutdown_fn)."""
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
        from multica_notifier_fakes import FakeMulticaWS

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
        from multica_notifier_fakes import FakeMulticaWS

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
        from multica_notifier_fakes import FakeMulticaWS

        bad = bytes([0x81, 0x03, 0xFF, 0xFE, 0xFD])  # FIN+text, invalid UTF-8
        server = FakeMulticaWS(script=[("raw", bad), ("text", '{"type":"auth_ack"}')])
        try:
            client = WSClient(server.url)
            client.connect()
            client.send_text("hello")
            assert json.loads(client.recv_message()) == {"type": "auth_ack"}
            client.close()
        finally:
            server.close()

    def test_binary_frame_ignored_then_text_received(self):
        from multica_notifier_fakes import FakeMulticaWS

        server = FakeMulticaWS(script=[("raw", bytes([0x82, 0x02, 0x01, 0x02])),
                                      ("text", '{"type":"auth_ack"}')])
        try:
            client = WSClient(server.url)
            client.connect()
            client.send_text("hello")
            assert json.loads(client.recv_message()) == {"type": "auth_ack"}
            client.close()
        finally:
            server.close()

    def test_fragmented_text_reassembled(self):
        from multica_notifier_fakes import FakeMulticaWS

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
        from multica_notifier_fakes import FakeMulticaWS

        orphan = bytes([0x80, 0x02]) + b"ab"
        server = FakeMulticaWS(script=[("raw", orphan), ("text", '{"type":"auth_ack"}')])
        try:
            client = WSClient(server.url)
            client.connect()
            client.send_text("hello")
            assert json.loads(client.recv_message()) == {"type": "auth_ack"}
            client.close()
        finally:
            server.close()

    def test_oversize_frame_is_error_not_hang(self):
        from multica_notifier_fakes import FakeMulticaWS

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
    import struct

    return struct.pack("!BBQ", 0x81, 127, n)


class TestReadTimeout:
    def test_silent_server_raises_closed_quickly(self):
        from multica_notifier_fakes import FakeMulticaWS

        import time

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
