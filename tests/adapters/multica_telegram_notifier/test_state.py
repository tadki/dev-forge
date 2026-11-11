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
