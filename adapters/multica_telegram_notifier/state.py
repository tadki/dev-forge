"""Dedup state, persisted as JSON so delivery survives restarts and
reconnects do not double-send (§SPEC-003).

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
            # Unknown/legacy keys (e.g. an old chat_id cache) are ignored:
            # the configured chat id is the single authority.
            self.delivered = [x for x in delivered if isinstance(x, str)][: self.capacity]

    def save(self) -> None:
        parent = os.path.dirname(self.path)
        if parent:
            os.makedirs(parent, exist_ok=True)
        tmp_path = self.path + ".tmp"
        # ensure_ascii (default) escapes lone surrogates from upstream ids, so
        # the strict UTF-8 file write can never raise.
        payload = json.dumps({"delivered": self.delivered})
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
