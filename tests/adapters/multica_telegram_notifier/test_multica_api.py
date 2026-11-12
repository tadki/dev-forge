"""§SPEC-001 unit tests for the bounded read-only metadata resolver:
agent/issue name lookup, TTL caching, timeout bounding, failure fallbacks,
and secret discipline (the PAT must never appear in error strings)."""

import time

import pytest

from multica_telegram_notifier.multica_api import (
    MulticaApiError,
    MetadataResolver,
)

from multica_notifier_fakes import FakeMulticaAPI


AGENT_ID = "22222222-2222-2222-2222-222222222222"
ISSUE_ID = "11111111-1111-1111-1111-111111111111"
WORKSPACE = "ws-1"
PAT = "probe-pat-value-0001"


def _resolver(server, timeout=2.0, clock=time.monotonic):
    return MetadataResolver(
        server_url=server.base_url, pat=PAT, workspace_id=WORKSPACE,
        timeout=timeout, clock=clock)


class _ManualClock:
    def __init__(self):
        self.now = 1000.0

    def __call__(self):
        return self.now


class TestAgentLookup:
    def test_uuid_resolved_to_display_name(self):
        server = FakeMulticaAPI()
        try:
            resolver = _resolver(server)
            assert resolver.agent_display("agent", AGENT_ID) == "Bachi"
            assert server.requests == [f"/api/agents/{AGENT_ID}?workspace_id={WORKSPACE}"]
            assert server.auth_headers[0] == f"Bearer {PAT}"
        finally:
            server.close()

    def test_readable_slug_used_without_query(self):
        server = FakeMulticaAPI()
        try:
            resolver = _resolver(server)
            assert resolver.agent_display("agent", "agent-atlas-1") == "agent-atlas-1"
            assert server.requests == []
        finally:
            server.close()

    def test_missing_actor_id_falls_back_to_type_label(self):
        server = FakeMulticaAPI()
        try:
            assert _resolver(server).agent_display("agent", "") == "Agent"
            assert server.requests == []
        finally:
            server.close()

    def test_query_failure_falls_back_without_uuid(self):
        server = FakeMulticaAPI(agent_status=500)
        try:
            out = _resolver(server).agent_display("agent", AGENT_ID)
            assert out == "Agent"
            assert AGENT_ID not in out
        finally:
            server.close()

    def test_failure_without_type_label_is_unknown_not_uuid(self):
        server = FakeMulticaAPI(agent_status=404)
        try:
            out = _resolver(server).agent_display("", AGENT_ID)
            assert out == "Unknown"
            assert AGENT_ID not in out
        finally:
            server.close()

    def test_overlong_display_name_truncated_to_max(self):
        # _MAX_NAME_LEN bounds the header label so one huge name cannot blow
        # past the fixed budget or the 4096 limit.
        server = FakeMulticaAPI(agent_body={"name": "N" * 100})
        try:
            assert _resolver(server).agent_display("agent", AGENT_ID) == "N" * 64
        finally:
            server.close()


class TestIssueLookup:
    def test_uuid_resolved_to_identifier_and_title(self):
        server = FakeMulticaAPI()
        try:
            assert _resolver(server).issue_ref(ISSUE_ID, "") == ("SEE-1567", "优化 Telegram 排版")
        finally:
            server.close()

    def test_title_with_identifier_used_without_query(self):
        server = FakeMulticaAPI()
        try:
            ref = _resolver(server).issue_ref(ISSUE_ID, "SEE-1567 我的标题")
            assert ref == ("SEE-1567", "我的标题")
            assert server.requests == []
        finally:
            server.close()

    def test_title_without_identifier_queries_for_identifier(self):
        server = FakeMulticaAPI()
        try:
            assert _resolver(server).issue_ref(ISSUE_ID, "普通标题") == ("SEE-1567", "普通标题")
            assert len(server.requests) == 1
        finally:
            server.close()

    def test_failure_keeps_title_drops_identifier(self):
        server = FakeMulticaAPI(issue_status=401)
        try:
            assert _resolver(server).issue_ref(ISSUE_ID, "普通标题") == ("", "普通标题")
        finally:
            server.close()

    def test_total_failure_returns_empty_ref_no_uuid(self):
        server = FakeMulticaAPI(issue_status=500)
        try:
            assert _resolver(server).issue_ref(ISSUE_ID, "") == ("", "")
        finally:
            server.close()


class TestCaching:
    def test_positive_cache_hit_skips_second_request(self):
        server = FakeMulticaAPI()
        try:
            clock = _ManualClock()
            resolver = _resolver(server, clock=clock)
            assert resolver.agent_display("agent", AGENT_ID) == "Bachi"
            assert resolver.agent_display("agent", AGENT_ID) == "Bachi"
            assert len(server.requests) == 1
            clock.now += 3600.0
            assert resolver.agent_display("agent", AGENT_ID) == "Bachi"
            assert len(server.requests) == 1
        finally:
            server.close()

    def test_cache_expires_after_ttl(self):
        server = FakeMulticaAPI()
        try:
            clock = _ManualClock()
            resolver = _resolver(server, clock=clock)
            resolver.agent_display("agent", AGENT_ID)
            clock.now += 3600.0 * 7  # positive TTL is 6h
            resolver.agent_display("agent", AGENT_ID)
            assert len(server.requests) == 2
        finally:
            server.close()

    def test_negative_cache_bounds_repeated_failures(self):
        server = FakeMulticaAPI(agent_status=500)
        try:
            clock = _ManualClock()
            resolver = _resolver(server, clock=clock)
            assert resolver.agent_display("agent", AGENT_ID) == "Agent"
            assert resolver.agent_display("agent", AGENT_ID) == "Agent"
            assert len(server.requests) == 1
            clock.now += 120.0  # negative TTL is 60s
            assert resolver.agent_display("agent", AGENT_ID) == "Agent"
            assert len(server.requests) == 2
        finally:
            server.close()


class TestBounding:
    def test_hanging_server_is_bounded_by_timeout(self):
        server = FakeMulticaAPI(delay=2.0)
        try:
            started = time.monotonic()
            out = _resolver(server, timeout=0.2).agent_display("agent", AGENT_ID)
            elapsed = time.monotonic() - started
            assert out == "Agent"
            assert elapsed < 1.5
        finally:
            server.close()

    def test_unreachable_server_fails_fast_to_fallback(self):
        resolver = MetadataResolver(
            server_url="http://127.0.0.1:1", pat=PAT, workspace_id=WORKSPACE,
            timeout=0.3)
        assert resolver.agent_display("agent", AGENT_ID) == "Agent"
        assert resolver.issue_ref(ISSUE_ID, "") == ("", "")


class TestSecretDiscipline:
    def test_error_message_never_carries_pat_or_url(self):
        server = FakeMulticaAPI(agent_status=503)
        try:
            resolver = _resolver(server)
            with pytest.raises(MulticaApiError) as excinfo:
                resolver._get_json(f"/api/agents/{AGENT_ID}")
            message = str(excinfo.value)
            assert PAT not in message
            assert "127.0.0.1" not in message
            assert PAT not in repr(excinfo.value)
        finally:
            server.close()


class TestIdentifierOnlyTitleResolver:
    def test_identifier_only_title_returns_empty_title(self):
        server = FakeMulticaAPI()
        try:
            assert _resolver(server).issue_ref(ISSUE_ID, "SEE-100") == ("SEE-100", "")
            assert server.requests == []
        finally:
            server.close()


class TestTypeLabelFallback:
    """Actor types outside the known map still surface a readable label when
    the type string itself is a safe, non-UUID slug."""

    def test_unknown_short_type_used_directly(self):
        server = FakeMulticaAPI()
        try:
            assert _resolver(server).agent_display("squad", "") == "squad"
            assert server.requests == []
        finally:
            server.close()

    def test_uuid_shaped_type_is_unknown_not_uuid(self):
        server = FakeMulticaAPI()
        try:
            out = _resolver(server).agent_display(AGENT_ID, "")
            assert out == "Unknown"
            assert AGENT_ID not in out
        finally:
            server.close()


class TestIssueRefFallbacks:
    """issue_ref must degrade deterministically when only one of the two
    identity fields is present."""

    def test_title_without_issue_id_returns_title_only(self):
        server = FakeMulticaAPI()
        try:
            assert _resolver(server).issue_ref("", "普通标题") == ("", "普通标题")
            assert server.requests == []
        finally:
            server.close()

    def test_no_title_no_issue_id_returns_empty(self):
        server = FakeMulticaAPI()
        try:
            assert _resolver(server).issue_ref("", "") == ("", "")
            assert server.requests == []
        finally:
            server.close()


class TestMalformedResponses:
    """The resolver must treat odd payloads as query failures and fall back,
    never raise or leak the malformed body."""

    def test_non_string_name_falls_back_to_type_label(self):
        server = FakeMulticaAPI(agent_body={"name": 12345})
        try:
            out = _resolver(server).agent_display("agent", AGENT_ID)
            assert out == "Agent"
            assert "12345" not in out
        finally:
            server.close()

    def test_invalid_json_body_degrades_to_fallback(self):
        server = FakeMulticaAPI(agent_raw=b"{not valid json")
        try:
            assert _resolver(server).agent_display("agent", AGENT_ID) == "Agent"
        finally:
            server.close()

    def test_non_object_json_body_degrades_to_fallback(self):
        server = FakeMulticaAPI(agent_body=["not", "an", "object"])
        try:
            assert _resolver(server).agent_display("agent", AGENT_ID) == "Agent"
        finally:
            server.close()


class TestIssuePathSafety:
    """FR-3: a non-UUID issue_id must never reach the REST path — external
    event data cannot steer the authenticated request off /api/issues/."""

    def test_parent_traversal_id_never_queries(self):
        server = FakeMulticaAPI()
        try:
            resolver = _resolver(server)
            assert resolver.issue_ref("../agents/x", "普通标题") == ("", "普通标题")
            assert server.requests == []
        finally:
            server.close()

    def test_query_string_id_never_queries(self):
        server = FakeMulticaAPI()
        try:
            resolver = _resolver(server)
            assert resolver.issue_ref("11111111-1111-1111-1111-111111111111?x=1", "") == ("", "")
            assert server.requests == []
        finally:
            server.close()

    def test_backslash_and_non_string_ids_never_query(self):
        server = FakeMulticaAPI()
        try:
            resolver = _resolver(server)
            assert resolver.issue_ref("..\\agents\\x", "") == ("", "")
            assert resolver.issue_ref(123, "") == ("", "")
            assert resolver.issue_ref(None, "") == ("", "")
            assert server.requests == []
        finally:
            server.close()


class TestCacheEviction:
    def test_expired_entry_evicted_on_miss(self):
        server = FakeMulticaAPI()
        try:
            clock = _ManualClock()
            resolver = _resolver(server, clock=clock)
            resolver.agent_display("agent", AGENT_ID)
            assert len(resolver._cache) == 1
            clock.now += 3600.0 * 7
            resolver.agent_display("agent", AGENT_ID)
            assert len(resolver._cache) == 1
            assert len(server.requests) == 2
            # The expired entry must be REMOVED at the miss itself, not merely
            # overwritten by the re-fetch that follows: drive one expired miss
            # with no store after it and the dict must actually shrink.
            resolver._store(("agent", AGENT_ID), "Bachi", 60.0)
            clock.now += 120.0
            assert ("agent", AGENT_ID) in resolver._cache
            resolver._cached(("agent", AGENT_ID))
            assert ("agent", AGENT_ID) not in resolver._cache
        finally:
            server.close()
