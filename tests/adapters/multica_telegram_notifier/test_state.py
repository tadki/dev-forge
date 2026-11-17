"""§SPEC-003 state layer: dedup ring, persistence, crash recovery."""

import json
import os

from multica_telegram_notifier.state import DedupState


class TestDedupBasics:
    def test_unknown_id_not_seen(self, tmp_path):
        state = DedupState(str(tmp_path / "state.json"))
        state.load()
        assert not state.is_seen("item-1")

    def test_mark_seen_persists_immediately(self, tmp_path):
        path = str(tmp_path / "state.json")
        state = DedupState(path)
        state.load()
        state.mark_seen("item-1")
        reloaded = DedupState(path)
        reloaded.load()
        assert reloaded.is_seen("item-1")

    def test_mark_seen_twice_is_idempotent(self, tmp_path):
        # Re-marking an already-seen id must not duplicate it in the ring.
        state = DedupState(str(tmp_path / "state.json"))
        state.load()
        state.mark_seen("item-1")
        state.mark_seen("item-1")
        assert state.delivered == ["item-1"]

    def test_save_atomic_no_temp_leftover(self, tmp_path):
        path = str(tmp_path / "state.json")
        state = DedupState(path)
        state.load()
        state.mark_seen("x")
        leftovers = [f for f in os.listdir(tmp_path) if f != "state.json"]
        assert leftovers == []


class TestRecovery:
    def test_missing_file_starts_fresh(self, tmp_path):
        state = DedupState(str(tmp_path / "absent.json"))
        state.load()
        assert state.delivered == []

    def test_corrupt_file_recovers_fresh_and_flags(self, tmp_path):
        path = tmp_path / "state.json"
        path.write_text("{not json", encoding="utf-8")
        state = DedupState(str(path))
        state.load()
        assert state.corrupt is True
        assert not state.is_seen("item-1")
        # A later save replaces the corrupt content instead of failing forever.
        state.mark_seen("item-1")
        reloaded = DedupState(str(path))
        reloaded.load()
        assert reloaded.is_seen("item-1")

    def test_non_dict_json_recovers(self, tmp_path):
        path = tmp_path / "state.json"
        path.write_text("[1,2]", encoding="utf-8")
        state = DedupState(str(path))
        state.load()
        assert state.corrupt is True


class TestCapacity:
    def test_ring_trimmed_to_capacity(self, tmp_path):
        path = str(tmp_path / "state.json")
        state = DedupState(path, capacity=3)
        state.load()
        for i in range(5):
            state.mark_seen(f"item-{i}")
        assert state.delivered == ["item-2", "item-3", "item-4"]
        reloaded = DedupState(path, capacity=3)
        reloaded.load()
        assert reloaded.is_seen("item-4")
        assert not reloaded.is_seen("item-0")


class TestLegacyFields:
    def test_legacy_chat_id_key_in_state_file_is_ignored(self, tmp_path):
        # Older state files cached a chat id; the config key is now the single
        # authority, so loading must tolerate and ignore the leftover field.
        path = tmp_path / "state.json"
        path.write_text('{"chat_id": 555000, "delivered": ["old-item"]}', encoding="utf-8")
        state = DedupState(str(path))
        state.load()
        assert state.is_seen("old-item")
        assert not state.corrupt
        state.mark_seen("new-item")
        raw = json.loads(path.read_text(encoding="utf-8"))
        assert "chat_id" not in raw
        assert raw["delivered"] == ["old-item", "new-item"]


class TestReplyMapping:
    """§SPEC-005: telegram message_id → (issue_id, comment_id) persistent
    mapping with FIFO trimming, so a Telegram reply can be attributed to the
    notification part it answers."""

    def test_record_and_lookup_roundtrip(self, tmp_path):
        state = DedupState(str(tmp_path / "state.json"))
        state.load()
        state.record_reply(4242, "issue-uuid", "comment-uuid")
        assert state.lookup_reply(4242) == ("issue-uuid", "comment-uuid")

    def test_lookup_miss_returns_none(self, tmp_path):
        state = DedupState(str(tmp_path / "state.json"))
        state.load()
        assert state.lookup_reply(999) is None

    def test_mapping_persists_across_restart(self, tmp_path):
        path = str(tmp_path / "state.json")
        state = DedupState(path)
        state.load()
        state.record_reply(4242, "issue-uuid", "comment-uuid")
        reloaded = DedupState(path)
        reloaded.load()
        assert reloaded.lookup_reply(4242) == ("issue-uuid", "comment-uuid")

    def test_fifo_trim_keeps_newest(self, tmp_path):
        path = str(tmp_path / "state.json")
        state = DedupState(path, reply_capacity=3)
        state.load()
        for mid in (11, 22, 33, 44):
            state.record_reply(mid, "i", "c")
        assert state.lookup_reply(11) is None
        assert state.lookup_reply(44) == ("i", "c")
        reloaded = DedupState(path, reply_capacity=3)
        reloaded.load()
        assert reloaded.lookup_reply(22) == ("i", "c")
        assert reloaded.lookup_reply(11) is None

    def test_legacy_delivered_only_file_loads_losslessly(self, tmp_path):
        path = tmp_path / "state.json"
        path.write_text('{"delivered": ["old-item"]}', encoding="utf-8")
        state = DedupState(str(path))
        state.load()
        assert state.is_seen("old-item")
        assert not state.corrupt
        assert state.replies == {}
        assert state.offset == 0
        state.record_reply(7, "i", "c")
        raw = json.loads(path.read_text(encoding="utf-8"))
        assert raw["delivered"] == ["old-item"]
        assert raw["replies"]["7"] == {"issue_id": "i", "comment_id": "c"}

    def test_malformed_reply_entries_are_dropped(self, tmp_path):
        path = tmp_path / "state.json"
        path.write_text(json.dumps({
            "delivered": [],
            "replies": {"1": {"issue_id": "i", "comment_id": "c"},
                        "2": "not-a-dict", "3": {"issue_id": 5},
                        "nonsense-key": None, "4": {"issue_id": "i2", "comment_id": "c2"}},
            "offset": "bogus",
        }), encoding="utf-8")
        state = DedupState(str(path))
        state.load()
        assert not state.corrupt
        assert state.lookup_reply(1) == ("i", "c")
        assert state.lookup_reply(3) is None
        assert state.lookup_reply(4) == ("i2", "c2")
        assert state.offset == 0

    def test_non_string_comment_id_entry_dropped(self, tmp_path):
        # Every reply field must be a string: a numeric comment_id cannot
        # attribute a reply, so the entry is dropped at load time.
        path = tmp_path / "state.json"
        path.write_text(json.dumps({
            "delivered": [],
            "replies": {"9": {"issue_id": "i9", "comment_id": 123}},
            "offset": 0,
        }), encoding="utf-8")
        state = DedupState(str(path))
        state.load()
        assert not state.corrupt
        assert state.replies == {}

    def test_load_side_fifo_trim_keeps_newest(self, tmp_path):
        # Oversized on-disk maps trim at load time under the same FIFO rule:
        # the oldest entries go, the newest replies stay resolvable.
        path = tmp_path / "state.json"
        replies = {str(i): {"issue_id": f"i{i}", "comment_id": f"c{i}"}
                   for i in range(5)}
        path.write_text(json.dumps({"delivered": [], "replies": replies,
                                    "offset": 0}), encoding="utf-8")
        state = DedupState(str(path), reply_capacity=3)
        state.load()
        assert not state.corrupt
        assert "0" not in state.replies
        assert "1" not in state.replies
        assert state.replies["2"] == {"issue_id": "i2", "comment_id": "c2"}
        assert state.replies["3"] == {"issue_id": "i3", "comment_id": "c3"}
        assert state.replies["4"] == {"issue_id": "i4", "comment_id": "c4"}


class TestOffsetPersistence:
    """§SPEC-004: the getUpdates offset is persisted so a restart never
    reprocesses old updates."""

    def test_offset_roundtrip(self, tmp_path):
        path = str(tmp_path / "state.json")
        state = DedupState(path)
        state.load()
        state.advance_offset(105)
        reloaded = DedupState(path)
        reloaded.load()
        assert reloaded.offset == 105

    def test_offset_advances_monotonically(self, tmp_path):
        state = DedupState(str(tmp_path / "state.json"))
        state.load()
        state.advance_offset(105)
        state.advance_offset(104)  # stale batch must not rewind
        assert state.offset == 105

    def test_negative_offset_starts_fresh(self, tmp_path):
        path = tmp_path / "state.json"
        path.write_text(json.dumps({"delivered": [], "replies": {},
                                    "offset": -3}), encoding="utf-8")
        state = DedupState(str(path))
        state.load()
        assert not state.corrupt
        assert state.offset == 0
