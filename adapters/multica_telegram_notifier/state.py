"""Dedup state, persisted as JSON so delivery survives restarts and
reconnects do not double-send (§SPEC-003).

mark_seen saves immediately: the durable "delivered" fact is what makes the
at-least-once session semantics safe. A corrupt file recovers to a fresh
state (flagged via ``corrupt``) instead of crashing the notifier — the next
save overwrites the bad content.

§SPEC-005 adds the reply-attribution map (delivered Telegram message_id →
the Multica issue/comment the notification came from) and the §SPEC-004
getUpdates offset, so a restart never reprocesses inbound updates. The file
is shared by the WS main thread and the reply-sync receiver thread, so every
mutation and save is lock-guarded.
"""

import json
import os
import threading

from multica_telegram_notifier.config import default_state_file

REPLY_MAP_CAPACITY = 1000


class DedupState:
    def __init__(self, path: str = None, capacity: int = 1000,
                 reply_capacity: int = REPLY_MAP_CAPACITY):
        self.path = path if path is not None else default_state_file()
        self.capacity = capacity
        self.reply_capacity = reply_capacity
        self.delivered = []
        # str(message_id) → {"issue_id": ..., "comment_id": ...}; JSON object
        # keys must be strings, so Telegram's numeric ids are stored as str.
        self.replies = {}
        self.offset = 0
        self.corrupt = False
        self._lock = threading.RLock()

    def load(self) -> None:
        with self._lock:
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
            self.replies = self._clean_replies(data.get("replies"))
            offset = data.get("offset")
            self.offset = offset if isinstance(offset, int) and offset >= 0 else 0

    def _clean_replies(self, raw) -> dict:
        if not isinstance(raw, dict):
            return {}
        cleaned = {}
        for key, value in raw.items():
            if not isinstance(value, dict):
                continue
            issue_id = value.get("issue_id")
            comment_id = value.get("comment_id")
            if isinstance(key, str) and isinstance(issue_id, str) and isinstance(comment_id, str):
                cleaned[key] = {"issue_id": issue_id, "comment_id": comment_id}
        if len(cleaned) > self.reply_capacity:
            # FIFO: dict insertion order keeps the oldest entries first, so
            # trimming drops them and keeps the newest replies resolvable.
            for key in list(cleaned.keys())[: len(cleaned) - self.reply_capacity]:
                cleaned.pop(key)
        return cleaned

    def save(self) -> None:
        with self._lock:
            parent = os.path.dirname(self.path)
            if parent:
                os.makedirs(parent, exist_ok=True)
            tmp_path = self.path + ".tmp"
            # ensure_ascii (default) escapes lone surrogates from upstream ids, so
            # the strict UTF-8 file write can never raise.
            payload = json.dumps({
                "delivered": self.delivered,
                "replies": self.replies,
                "offset": self.offset,
            })
            # Atomic replace: a crash mid-write can never leave a half-written
            # state file behind — readers see either the old or the new content.
            with open(tmp_path, "w", encoding="utf-8") as handle:
                handle.write(payload)
            os.replace(tmp_path, self.path)

    def is_seen(self, item_id: str) -> bool:
        with self._lock:
            return item_id in self.delivered

    def mark_seen(self, item_id: str) -> None:
        with self._lock:
            if item_id in self.delivered:
                return
            self.delivered.append(item_id)
            if len(self.delivered) > self.capacity:
                self.delivered = self.delivered[-self.capacity:]
            self.save()

    def record_reply(self, message_id, issue_id: str, comment_id: str) -> None:
        with self._lock:
            self.replies[str(message_id)] = {"issue_id": issue_id, "comment_id": comment_id}
            if len(self.replies) > self.reply_capacity:
                for key in list(self.replies.keys())[: len(self.replies) - self.reply_capacity]:
                    self.replies.pop(key)
            self.save()

    def lookup_reply(self, message_id):
        with self._lock:
            entry = self.replies.get(str(message_id))
            if entry is None:
                return None
            return entry["issue_id"], entry["comment_id"]

    def advance_offset(self, value: int) -> None:
        # Monotonic: a stale batch arriving late must never rewind the offset
        # and resurrect already-processed updates.
        with self._lock:
            if isinstance(value, int) and value > self.offset:
                self.offset = value
                self.save()
