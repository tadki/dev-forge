"""Multica realtime wire contract (§SPEC-001).

Shapes verified against the Multica v0.8.1 server source (server/internal/
realtime/hub.go firstMessageAuth / HandleWebSocket, server/cmd/server/
listeners.go inbox routing) and live probes of the self-hosted deployment:

- client's first frame:  {"type": "auth", "payload": {"token": "<PAT>"}}
- success reply:         {"type": "auth_ack"}
- failure reply:         {"error": "..."} then the server closes
- inbox:new frame:       {"type": "inbox:new", "payload": {"item": {...}},
                          "actor_id": ..., "actor_type": ...}
- inbox items are personal events routed to the recipient user on every
  connection, so the workspace filter below is the client's own duty.
"""

import hashlib
import json

EVENT_INBOX_NEW = "inbox:new"
AUTH_TYPE = "auth"
AUTH_ACK_TYPE = "auth_ack"


def auth_frame(token: str) -> str:
    return json.dumps({"type": AUTH_TYPE, "payload": {"token": token}})


def parse_server_frame(raw: str):
    try:
        obj = json.loads(raw)
    except (TypeError, ValueError):
        return None
    return obj if isinstance(obj, dict) else None


def is_auth_error(frame: dict) -> bool:
    return "error" in frame


def auth_error_message(frame: dict) -> str:
    return str(frame.get("error", "unknown auth error"))


def is_auth_ack(frame: dict) -> bool:
    return frame.get("type") == AUTH_ACK_TYPE


def parse_inbox_new(frame: dict):
    if frame.get("type") != EVENT_INBOX_NEW:
        return None
    payload = frame.get("payload")
    if not isinstance(payload, dict):
        return None
    item = payload.get("item")
    return item if isinstance(item, dict) else None


def item_workspace_id(item: dict) -> str:
    workspace = item.get("workspace_id")
    return workspace if isinstance(workspace, str) else ""


def inbox_item_id(item: dict) -> str:
    item_id = item.get("id")
    if isinstance(item_id, str) and item_id:
        return item_id
    # Stable fallback for items without an id so reconnect dedup still works.
    # ensure_ascii (default) escapes lone surrogates from upstream "\udXXX"
    # payloads to ASCII, so the UTF-8 encode can never raise.
    canonical = json.dumps(item, sort_keys=True)
    return hashlib.sha1(canonical.encode("utf-8")).hexdigest()[:16]


def format_notification(item: dict) -> str:
    lines = [f"[Multica] {_text(item.get('type')) or 'inbox'}"]
    title = _text(item.get("title"))
    if title:
        lines.append(title)
    body = _text(item.get("body"))
    if body:
        lines.append(body)
    issue_id = _text(item.get("issue_id"))
    if issue_id:
        lines.append(f"Issue: {issue_id}")
    actor = " ".join(part for part in (_text(item.get("actor_type")),
                                       _text(item.get("actor_id"))) if part)
    if actor:
        lines.append(f"来源: {actor}")
    created_at = _text(item.get("created_at"))
    if created_at:
        lines.append(f"时间: {created_at}")
    return "\n".join(lines)


def _text(value) -> str:
    return value if isinstance(value, str) else ""
