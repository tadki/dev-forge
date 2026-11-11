"""§SPEC-001: wire contract parsing — auth frame, auth_ack, inbox:new filter,
notification formatting. All shapes verified against Multica v0.8.1 server
source + live self-hosted probes (SEE-1561 task-explore)."""

import json

from multica_telegram_notifier.protocol import (
    auth_error_message,
    auth_frame,
    format_notification,
    inbox_item_id,
    is_auth_ack,
    is_auth_error,
    item_workspace_id,
    parse_inbox_new,
    parse_server_frame,
)

from multica_notifier_fakes import make_inbox_frame


class TestAuthFrame:
    def test_auth_frame_shape_matches_contract(self):
        frame = json.loads(auth_frame("test-pat-value-0123456789"))
        assert frame == {"type": "auth", "payload": {"token": "test-pat-value-0123456789"}}


class TestParseServerFrame:
    def test_valid_object(self):
        assert parse_server_frame('{"type":"auth_ack"}') == {"type": "auth_ack"}

    def test_malformed_json_returns_none(self):
        assert parse_server_frame("not json at all") is None

    def test_non_object_json_returns_none(self):
        assert parse_server_frame("[1,2,3]") is None

    def test_empty_string_returns_none(self):
        assert parse_server_frame("") is None


class TestAuthFrames:
    def test_error_frame_detected(self):
        frame = parse_server_frame('{"error":"invalid token"}')
        assert is_auth_error(frame)
        assert auth_error_message(frame) == "invalid token"

    def test_auth_ack_detected(self):
        assert is_auth_ack(parse_server_frame('{"type":"auth_ack"}'))

    def test_auth_ack_not_confused_with_other_types(self):
        assert not is_auth_ack(parse_server_frame('{"type":"inbox:new","payload":{}}'))
        assert not is_auth_ack(parse_server_frame('{"error":"x"}'))


class TestInboxNewParsing:
    def test_valid_frame_yields_item(self):
        raw = make_inbox_frame()
        item = parse_inbox_new(parse_server_frame(raw))
        assert item is not None
        assert item["id"] == "item-1"
        assert item["workspace_id"] == "ws-target"
        assert item["title"] == "SEE-1561 code 子步骤"

    def test_non_inbox_type_returns_none(self):
        frame = parse_server_frame('{"type":"issue:updated","payload":{"issue":{}}}')
        assert parse_inbox_new(frame) is None

    def test_missing_item_returns_none(self):
        frame = parse_server_frame('{"type":"inbox:new","payload":{}}')
        assert parse_inbox_new(frame) is None

    def test_item_not_dict_returns_none(self):
        frame = parse_server_frame('{"type":"inbox:new","payload":{"item":"nope"}}')
        assert parse_inbox_new(frame) is None

    def test_payload_not_dict_returns_none(self):
        # A non-object payload is a malformed inbox frame and must be ignored,
        # not treated as an item-bearing event.
        frame = parse_server_frame('{"type":"inbox:new","payload":"not-an-object"}')
        assert parse_inbox_new(frame) is None


class TestWorkspaceFilter:
    def test_workspace_id_extracted(self):
        item = parse_inbox_new(parse_server_frame(make_inbox_frame(workspace_id="ws-a")))
        assert item_workspace_id(item) == "ws-a"

    def test_missing_workspace_id_is_empty(self):
        item = parse_inbox_new(parse_server_frame(make_inbox_frame(workspace_id=None)))
        assert item_workspace_id(item) == ""


class TestInboxItemId:
    def test_uses_native_id_when_present(self):
        item = {"id": "abc-123"}
        assert inbox_item_id(item) == "abc-123"

    def test_fallback_is_stable_for_identical_items(self):
        a = {"title": "t", "created_at": "2026-11-11T00:00:00Z"}
        b = {"created_at": "2026-11-11T00:00:00Z", "title": "t"}
        assert inbox_item_id(a) == inbox_item_id(b)

    def test_fallback_differs_for_distinct_items(self):
        assert inbox_item_id({"title": "a"}) != inbox_item_id({"title": "b"})

    def test_fallback_survives_lone_surrogate(self):
        # A lone surrogate in an id-less item must not raise
        # UnicodeEncodeError out of the hash fallback.
        item = {"title": "\ud800bad item", "created_at": "2026-11-11T00:00:00Z"}
        fallback = inbox_item_id(item)
        assert isinstance(fallback, str) and len(fallback) == 16
        assert inbox_item_id(item) == fallback


class TestFormatNotification:
    def test_full_item_deterministic_output(self):
        item = parse_inbox_new(parse_server_frame(make_inbox_frame()))
        text = format_notification(item)
        assert text == (
            "[Multica] issue_assigned\n"
            "SEE-1561 code 子步骤\n"
            "Atlas 分配了 code 任务\n"
            "Issue: issue-uuid-1\n"
            "来源: agent agent-atlas-1\n"
            "时间: 2026-11-11T03:00:00Z"
        )

    def test_minimal_item_omits_missing_lines(self):
        text = format_notification({"type": None, "title": "只有标题"})
        assert text == "[Multica] inbox\n只有标题"

    def test_non_string_optional_fields_ignored(self):
        text = format_notification({"title": "t", "body": 123, "issue_id": None, "created_at": 5})
        assert text == "[Multica] inbox\nt"

    def test_output_is_plain_text(self):
        # Pure text only: no markdown entities that Telegram would need parse_mode for.
        item = parse_inbox_new(parse_server_frame(make_inbox_frame()))
        text = format_notification(item)
        assert "**" not in text and "]" in text and text.startswith("[Multica] ")
