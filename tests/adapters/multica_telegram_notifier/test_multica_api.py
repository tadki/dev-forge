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
# Canonical-UUID workspace/comment ids for the SEE-1572 deep-link surface;
# the field shapes mirror the live wire capture (item.details.comment_id).
WS_UUID = "33333333-3333-3333-3333-333333333333"
COMMENT_ID = "44444444-4444-4444-4444-444444444444"


def _resolver(server, timeout=2.0, clock=time.monotonic):
    return MetadataResolver(
        server_url=server.base_url, pat=PAT, workspace_id=WORKSPACE,
        timeout=timeout, clock=clock)


def _ws_resolver(server, timeout=2.0, clock=time.monotonic, workspace=WS_UUID):
    return MetadataResolver(
        server_url=server.base_url, pat=PAT, workspace_id=workspace,
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


class TestWorkspaceSlugLookup:
    """§SPEC-002: the workspace slug comes from a bounded read-only query
    against /api/workspaces/<canonical-uuid>, with positive/negative TTL
    caching and strict value validation — any odd shape degrades to ""."""

    def test_slug_resolved_via_canonical_uuid_with_bearer(self):
        server = FakeMulticaAPI(workspace_body={"slug": "seed"})
        try:
            resolver = _ws_resolver(server)
            assert resolver.workspace_slug() == "seed"
            assert server.requests == [
                f"/api/workspaces/{WS_UUID}?workspace_id={WS_UUID}"]
            assert server.auth_headers[0] == f"Bearer {PAT}"
        finally:
            server.close()

    def test_positive_cache_skips_second_request(self):
        server = FakeMulticaAPI(workspace_body={"slug": "seed"})
        try:
            clock = _ManualClock()
            resolver = _ws_resolver(server, clock=clock)
            assert resolver.workspace_slug() == "seed"
            assert resolver.workspace_slug() == "seed"
            clock.now += 3600.0
            assert resolver.workspace_slug() == "seed"
            assert len(server.requests) == 1
        finally:
            server.close()

    def test_cache_expires_after_positive_ttl(self):
        server = FakeMulticaAPI(workspace_body={"slug": "seed"})
        try:
            clock = _ManualClock()
            resolver = _ws_resolver(server, clock=clock)
            resolver.workspace_slug()
            clock.now += 3600.0 * 7  # positive TTL is 6h
            resolver.workspace_slug()
            assert len(server.requests) == 2
        finally:
            server.close()

    def test_negative_cache_bounds_repeated_failures(self):
        server = FakeMulticaAPI(workspace_status=500)
        try:
            clock = _ManualClock()
            resolver = _ws_resolver(server, clock=clock)
            assert resolver.workspace_slug() == ""
            assert resolver.workspace_slug() == ""
            assert len(server.requests) == 1
            clock.now += 120.0  # negative TTL is 60s
            assert resolver.workspace_slug() == ""
            assert len(server.requests) == 2
        finally:
            server.close()

    def test_non_canonical_workspace_id_never_queries(self):
        # FR-3 discipline: only a canonical UUID may become a REST path
        # segment; anything else degrades locally with zero requests.
        server = FakeMulticaAPI(workspace_body={"slug": "seed"})
        try:
            resolver = _ws_resolver(server, workspace="../api/admin")
            assert resolver.workspace_slug() == ""
            assert resolver.workspace_slug() == ""
            assert server.requests == []
        finally:
            server.close()

    def test_non_canonical_workspace_id_returns_empty_deterministically(self):
        server = FakeMulticaAPI(workspace_body={"slug": "seed"})
        try:
            assert _ws_resolver(server, workspace="ws-1").workspace_slug() == ""
            assert server.requests == []
        finally:
            server.close()

    def test_expired_slug_entry_evicted_on_miss(self):
        server = FakeMulticaAPI(workspace_body={"slug": "seed"})
        try:
            clock = _ManualClock()
            resolver = _ws_resolver(server, clock=clock)
            resolver.workspace_slug()
            assert len(resolver._cache) == 1
            clock.now += 3600.0 * 7
            resolver.workspace_slug()
            assert len(resolver._cache) == 1
            assert len(server.requests) == 2
        finally:
            server.close()


class TestWorkspaceSlugValidation:
    """Every slug that is not a non-empty [a-z0-9-]+ string of sane length is
    a query failure: the value must never reach a URL unvalidated."""

    @pytest.mark.parametrize("body", [
        {},
        {"slug": None},
        {"slug": 123},
        {"slug": ""},
        {"slug": "Seed"},
        {"slug": "see d"},
        {"slug": "seed_x"},
        {"slug": "seed/x"},
        {"slug": "../etc"},
        {"slug": "a" * 65},
        {"slug": ["seed"]},
    ])
    def test_invalid_slug_shapes_degrade_to_empty(self, body):
        server = FakeMulticaAPI(workspace_body=body)
        try:
            assert _ws_resolver(server).workspace_slug() == ""
        finally:
            server.close()

    def test_max_length_slug_is_accepted(self):
        server = FakeMulticaAPI(workspace_body={"slug": "a" * 64})
        try:
            assert _ws_resolver(server).workspace_slug() == "a" * 64
        finally:
            server.close()

    def test_malformed_body_degrades_to_empty(self):
        server = FakeMulticaAPI(workspace_raw=b"{not valid json")
        try:
            assert _ws_resolver(server).workspace_slug() == ""
        finally:
            server.close()

    def test_non_object_body_degrades_to_empty(self):
        server = FakeMulticaAPI(workspace_body=["not", "an", "object"])
        try:
            assert _ws_resolver(server).workspace_slug() == ""
        finally:
            server.close()


class TestCommentLink:
    """§SPEC-001/002/004: the title-line deep link is composed ONLY from
    validated components; any missing or invalid component degrades."""

    def test_full_deep_link(self):
        server = FakeMulticaAPI(workspace_body={"slug": "seed"})
        try:
            resolver = _ws_resolver(server)
            assert resolver.comment_link("SEE-1567", COMMENT_ID) == (
                f"{server.base_url}/seed/issues/SEE-1567#comment-{COMMENT_ID}")
        finally:
            server.close()

    def test_missing_comment_id_links_issue_page_without_anchor(self):
        server = FakeMulticaAPI(workspace_body={"slug": "seed"})
        try:
            resolver = _ws_resolver(server)
            assert resolver.comment_link("SEE-1567", "") == (
                f"{server.base_url}/seed/issues/SEE-1567")
        finally:
            server.close()

    def test_non_uuid_comment_id_never_enters_url(self):
        server = FakeMulticaAPI(workspace_body={"slug": "seed"})
        try:
            resolver = _ws_resolver(server)
            injected = "x#frag?workspace_id=../admin"
            url = resolver.comment_link("SEE-1567", injected)
            assert url == f"{server.base_url}/seed/issues/SEE-1567"
            assert injected not in url
        finally:
            server.close()

    def test_non_string_comment_id_treated_as_missing(self):
        server = FakeMulticaAPI(workspace_body={"slug": "seed"})
        try:
            resolver = _ws_resolver(server)
            assert resolver.comment_link("SEE-1567", 123) == (
                f"{server.base_url}/seed/issues/SEE-1567")
            assert resolver.comment_link("SEE-1567", None) == (
                f"{server.base_url}/seed/issues/SEE-1567")
        finally:
            server.close()

    @pytest.mark.parametrize("identifier", [
        "", None, "优化排版", "ABC-12", "see-1567",
        "SEE-", "SEE-abc", "SEE-1567/x", "SEE-1567?x",
        "SEE-" + "9" * 13,  # over the digit bound: not a real identifier
    ])
    def test_identifier_must_be_see_shaped_to_link(self, identifier):
        server = FakeMulticaAPI(workspace_body={"slug": "seed"})
        try:
            assert _ws_resolver(server).comment_link(identifier, COMMENT_ID) == ""
        finally:
            server.close()

    def test_max_digits_identifier_links(self):
        server = FakeMulticaAPI(workspace_body={"slug": "seed"})
        try:
            url = _ws_resolver(server).comment_link("SEE-" + "9" * 12, COMMENT_ID)
            assert url.endswith("/issues/SEE-" + "9" * 12 + f"#comment-{COMMENT_ID}")
        finally:
            server.close()

    def test_slug_failure_degrades_to_no_link(self):
        server = FakeMulticaAPI(workspace_status=500)
        try:
            assert _ws_resolver(server).comment_link("SEE-1567", COMMENT_ID) == ""
        finally:
            server.close()

    def test_oversized_web_base_degrades_without_querying(self):
        server = FakeMulticaAPI(workspace_body={"slug": "seed"})
        try:
            resolver = MetadataResolver(
                server_url="http://" + "a" * 600, pat=PAT,
                workspace_id=WS_UUID, timeout=2.0)
            assert resolver.comment_link("SEE-1567", COMMENT_ID) == ""
            assert server.requests == []
        finally:
            server.close()

    def test_non_http_web_base_degrades_without_querying(self):
        server = FakeMulticaAPI(workspace_body={"slug": "seed"})
        try:
            resolver = MetadataResolver(
                server_url="ftp://127.0.0.1:1", pat=PAT,
                workspace_id=WS_UUID, timeout=0.3)
            assert resolver.comment_link("SEE-1567", COMMENT_ID) == ""
            assert server.requests == []
        finally:
            server.close()

    def test_web_base_prefers_explicit_override(self):
        server = FakeMulticaAPI(workspace_body={"slug": "seed"})
        try:
            resolver = MetadataResolver(
                server_url=server.base_url, pat=PAT, workspace_id=WS_UUID,
                timeout=2.0, web_base="http://web.test")
            assert resolver.comment_link("SEE-1567", COMMENT_ID) == (
                f"http://web.test/seed/issues/SEE-1567#comment-{COMMENT_ID}")
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
