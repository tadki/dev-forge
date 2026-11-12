"""Bounded read-only Multica REST lookups for notification metadata
(§SPEC-001): agent display names and issue identifier/title.

Discipline:
- Read-only GETs against the configured Multica origin, authenticated with
  the same PAT as the WebSocket. Requests are strictly bounded by a timeout
  and failures degrade to event-provided labels — a name lookup must never
  block delivery, loop, or widen the failure surface of the notifier.
- Secret discipline mirrors telegram.py: the PAT travels only in the
  Authorization header; error messages are rebuilt from the exception type
  name with the original exception context suppressed, so no token or
  token-bearing URL can reach a log through this module.
- A small in-process TTL cache (positive and negative) keeps repeated
  notifications cheap and bounds the request rate against the server.
"""

import json
import re
import socket
import time
import urllib.error
import urllib.parse
import urllib.request
import http.client

UUID_RE = re.compile(
    r"^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$")
_IDENTIFIER_RE = re.compile(r"^\s*(SEE-\d+)\s*(.*)$", re.S)

POSITIVE_TTL_SECONDS = 6 * 3600.0
NEGATIVE_TTL_SECONDS = 60.0
DEFAULT_QUERY_TIMEOUT = 5.0

_MAX_NAME_LEN = 64
_MAX_TITLE_LEN = 256

_TYPE_LABELS = {"agent": "Agent", "member": "Member", "user": "User"}

_MISS = object()


class MulticaApiError(Exception):
    """Safe metadata-query failure: message carries no token and no URL."""


def looks_like_uuid(value: str) -> bool:
    return UUID_RE.fullmatch(value) is not None


def type_label(actor_type: str) -> str:
    if actor_type in _TYPE_LABELS:
        return _TYPE_LABELS[actor_type]
    if actor_type and 0 < len(actor_type) <= 32 and not looks_like_uuid(actor_type):
        return actor_type
    return "Unknown"


class MetadataResolver:
    def __init__(self, server_url: str, pat: str, workspace_id: str,
                 timeout: float = DEFAULT_QUERY_TIMEOUT, clock=time.monotonic):
        self._base = server_url.rstrip("/")
        self._pat = pat
        self._workspace = workspace_id
        self._timeout = timeout
        self._clock = clock
        self._cache = {}

    # --- public resolution API ---

    def agent_display(self, actor_type: str, actor_id: str) -> str:
        if actor_id and not looks_like_uuid(actor_id):
            return actor_id[:_MAX_NAME_LEN]
        if not actor_id:
            return type_label(actor_type)
        name = self._cached(("agent", actor_id))
        if name is _MISS:
            try:
                data = self._get_json(f"/api/agents/{actor_id}")
                name = self._clean(data.get("name"), _MAX_NAME_LEN)
            except MulticaApiError:
                name = None
            self._store(("agent", actor_id), name,
                        POSITIVE_TTL_SECONDS if name else NEGATIVE_TTL_SECONDS)
        return name if name else type_label(actor_type)

    def issue_ref(self, issue_id: str, item_title: str) -> tuple:
        """Returns (identifier, title); both may be empty on fallback."""
        # FR-3: only a canonical UUID may become a REST path segment. Any
        # other id (upstream event data) degrades locally and never steers
        # the authenticated request off /api/issues/.
        safe_id = issue_id if isinstance(issue_id, str) and looks_like_uuid(issue_id) else ""
        if item_title:
            m = _IDENTIFIER_RE.match(item_title)
            if m:
                # F4: identifier-only title must not duplicate the identifier
                # as the title.
                return m.group(1), m.group(2).strip()
            if not safe_id:
                return "", item_title
            # Title exists but carries no SEE identifier: look one up.
            ref = self._cached(("issue", safe_id))
            if ref is _MISS:
                ref = self._fetch_issue(safe_id)
            if ref and ref[0]:
                return ref[0], item_title
            return "", item_title
        if not safe_id:
            return "", ""
        ref = self._cached(("issue", safe_id))
        if ref is _MISS:
            ref = self._fetch_issue(safe_id)
        return ref if ref else ("", "")

    # --- internals ---

    def _fetch_issue(self, issue_id: str):
        try:
            data = self._get_json(f"/api/issues/{issue_id}")
        except MulticaApiError:
            self._store(("issue", issue_id), None, NEGATIVE_TTL_SECONDS)
            return None
        ref = (self._clean(data.get("identifier"), _MAX_NAME_LEN),
               self._clean(data.get("title"), _MAX_TITLE_LEN))
        ref = (ref[0] or "", ref[1] or "")
        self._store(("issue", issue_id), ref or None,
                    POSITIVE_TTL_SECONDS if ref else NEGATIVE_TTL_SECONDS)
        return ref or None

    def _cached(self, key):
        entry = self._cache.get(key)
        if entry is None:
            return _MISS
        if entry[1] <= self._clock():
            # Evict expired entries on miss so the cache does not grow without
            # bound as distinct ids stream through a long-lived daemon.
            self._cache.pop(key, None)
            return _MISS
        return entry[0]

    def _store(self, key, value, ttl: float) -> None:
        self._cache[key] = (value, self._clock() + ttl)

    @staticmethod
    def _clean(value, limit: int):
        if not isinstance(value, str):
            return None
        value = value.strip()
        return value[:limit] if value else None

    def _get_json(self, path: str) -> dict:
        sep = "&" if "?" in path else "?"
        url = (f"{self._base}{path}{sep}"
               f"workspace_id={urllib.parse.quote(self._workspace, safe='')}")
        request = urllib.request.Request(
            url, headers={"Authorization": f"Bearer {self._pat}"}, method="GET")
        try:
            with urllib.request.urlopen(request, timeout=self._timeout) as response:
                raw = response.read()
        except (urllib.error.HTTPError, urllib.error.URLError, TimeoutError,
                socket.timeout, OSError, http.client.HTTPException) as exc:
            # `from None` keeps the token-bearing URL out of any traceback.
            raise MulticaApiError(f"metadata query failed: {type(exc).__name__}") from None
        try:
            data = json.loads(raw.decode("utf-8"))
        except (UnicodeDecodeError, ValueError):
            raise MulticaApiError("metadata query returned invalid JSON") from None
        if not isinstance(data, dict):
            raise MulticaApiError("metadata query returned a non-object body")
        return data
