"""Dedup + chat-id state, persisted as JSON so delivery survives restarts
and reconnects do not double-send (§SPEC-003).

mark_seen saves immediately: the durable "delivered" fact is what makes the
at-least-once session semantics safe. A corrupt file recovers to a fresh
state (flagged via ``corrupt``) instead of crashing the notifier — the next
save overwrites the bad content.
"""

import json
import os

from multica_telegram_notifier.config import default_state_file


class DedupState:
    def __init__(self, path: str = None, capacity: int = 1000):
        self.path = path if path is not None else default_state_file()
        self.capacity = capacity
        self.delivered = []
        self.chat_id = None
        self.corrupt = False

    def load(self) -> None:
        try:
            with open(self.path, "r", encoding="utf-8") as handle:
                data = json.load(handle)
        except FileNotFoundError:
            return
        except (OSError, ValueError):
            self.corrupt = True
            return
        if not isinstance(data, dict):
            self.corrupt = True
            return
        delivered = data.get("delivered")
        if isinstance(delivered, list):
            self.delivered = [x for x in delivered if isinstance(x, str)][: self.capacity]
        self.chat_id = self._valid_chat_id(data.get("chat_id"))

    def save(self) -> None:
        parent = os.path.dirname(self.path)
        if parent:
            os.makedirs(parent, exist_ok=True)
        tmp_path = self.path + ".tmp"
        payload = json.dumps(
            {"delivered": self.delivered, "chat_id": self.chat_id},
            ensure_ascii=False,
        )
        # Atomic replace: a crash mid-write can never leave a half-written
        # state file behind — readers see either the old or the new content.
        with open(tmp_path, "w", encoding="utf-8") as handle:
            handle.write(payload)
        os.replace(tmp_path, self.path)

    def is_seen(self, item_id: str) -> bool:
        return item_id in self.delivered

    def mark_seen(self, item_id: str) -> None:
        if item_id in self.delivered:
            return
        self.delivered.append(item_id)
        if len(self.delivered) > self.capacity:
            self.delivered = self.delivered[-self.capacity:]
        self.save()

    def set_chat_id(self, chat_id: int) -> None:
        self.chat_id = chat_id
        self.save()

    @staticmethod
    def _valid_chat_id(raw):
        if isinstance(raw, int) and not isinstance(raw, bool):
            return raw
        return None
