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


def _ws_resolver(server, timeout=2.0, clock=time.monotonic, workspace=WS_UUID,
                 web_base="http://web.test"):
    return MetadataResolver(
        server_url=server.base_url, pat=PAT, workspace_id=workspace,
        timeout=timeout, clock=clock, web_base=web_base)


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
    """§SPEC-002 R2: the deep link is composed ONLY from validated
    components; the web root is NOTIFIER_WEB_BASE_URL alone (never the API
    origin), and the issue path segment comes from the /api/issues lookup of
    the item's canonical issue_id — the title prefix never steers a URL."""

    WEB = "http://web.test"

    def test_full_deep_link(self):
        server = FakeMulticaAPI(workspace_body={"slug": "seed"})
        try:
            url = _ws_resolver(server).comment_link(ISSUE_ID, COMMENT_ID)
            assert url == f"{self.WEB}/seed/issues/SEE-1567#comment-{COMMENT_ID}"
        finally:
            server.close()

    def test_issue_path_segment_sourced_from_issue_api(self):
        # QA M2: the identifier in the URL must come from the /api/issues
        # lookup of item.issue_id — comment_link never sees the title, so a
        # lying title prefix cannot steer the URL.
        server = FakeMulticaAPI(
            issue_body={"identifier": "SEE-1562", "title": "真实归属"})
        try:
            url = _ws_resolver(server).comment_link(ISSUE_ID, COMMENT_ID)
            assert url == f"{self.WEB}/seed/issues/SEE-1562#comment-{COMMENT_ID}"
        finally:
            server.close()

    def test_missing_comment_id_links_issue_page_without_anchor(self):
        server = FakeMulticaAPI(workspace_body={"slug": "seed"})
        try:
            url = _ws_resolver(server).comment_link(ISSUE_ID, "")
            assert url == f"{self.WEB}/seed/issues/SEE-1567"
        finally:
            server.close()

    def test_non_uuid_comment_id_never_enters_url(self):
        server = FakeMulticaAPI(workspace_body={"slug": "seed"})
        try:
            injected = "x#frag?workspace_id=../admin"
            url = _ws_resolver(server).comment_link(ISSUE_ID, injected)
            assert url == f"{self.WEB}/seed/issues/SEE-1567"
            assert injected not in url
        finally:
            server.close()

    def test_non_string_comment_id_treated_as_missing(self):
        server = FakeMulticaAPI(workspace_body={"slug": "seed"})
        try:
            resolver = _ws_resolver(server)
            assert resolver.comment_link(ISSUE_ID, 123) == (
                f"{self.WEB}/seed/issues/SEE-1567")
            assert resolver.comment_link(ISSUE_ID, None) == (
                f"{self.WEB}/seed/issues/SEE-1567")
        finally:
            server.close()

    @pytest.mark.parametrize("issue_id", [
        "", None, 123, "issue-uuid-1",
        "11111111-1111-1111-1111-111111111111?x",
        "../issues/11111111-1111-1111-1111-111111111111",
    ])
    def test_non_canonical_issue_id_never_queries_or_links(self, issue_id):
        # QA M2: only a canonical issue uuid may drive the lookup; anything
        # else degrades locally with zero requests.
        server = FakeMulticaAPI(workspace_body={"slug": "seed"})
        try:
            assert _ws_resolver(server).comment_link(issue_id, COMMENT_ID) == ""
            assert server.requests == []
        finally:
            server.close()

    def test_issue_query_failure_degrades_to_no_link(self):
        server = FakeMulticaAPI(issue_status=500)
        try:
            assert _ws_resolver(server).comment_link(ISSUE_ID, COMMENT_ID) == ""
            assert any("/api/issues/" in p for p in server.requests)
            assert not any("/api/workspaces/" in p for p in server.requests)
        finally:
            server.close()

    def test_api_identifier_must_be_see_shaped_for_link(self):
        server = FakeMulticaAPI(issue_body={"identifier": "ABC-12", "title": "t"})
        try:
            assert _ws_resolver(server).comment_link(ISSUE_ID, COMMENT_ID) == ""
        finally:
            server.close()

    def test_slug_failure_degrades_to_no_link(self):
        server = FakeMulticaAPI(workspace_status=500)
        try:
            assert _ws_resolver(server).comment_link(ISSUE_ID, COMMENT_ID) == ""
        finally:
            server.close()

    def test_max_digits_identifier_links(self):
        server = FakeMulticaAPI(
            issue_body={"identifier": "SEE-" + "9" * 12, "title": "t"})
        try:
            url = _ws_resolver(server).comment_link(ISSUE_ID, COMMENT_ID)
            assert url.endswith("/issues/SEE-" + "9" * 12 + f"#comment-{COMMENT_ID}")
        finally:
            server.close()

    def test_13_digit_api_identifier_does_not_link(self):
        server = FakeMulticaAPI(
            issue_body={"identifier": "SEE-" + "9" * 13, "title": "t"})
        try:
            assert _ws_resolver(server).comment_link(ISSUE_ID, COMMENT_ID) == ""
        finally:
            server.close()

    def test_link_reuses_issue_lookup_cache(self):
        # Repeated links for the same item within the positive TTL must hit
        # /api/issues once; the lookup is cached like every other metadata
        # query (a streaming daemon links each issue over and over).
        server = FakeMulticaAPI(workspace_body={"slug": "seed"})
        try:
            resolver = _ws_resolver(server)
            resolver.comment_link(ISSUE_ID, COMMENT_ID)
            resolver.comment_link(ISSUE_ID, COMMENT_ID)
            assert len([p for p in server.requests if "/api/issues/" in p]) == 1
        finally:
            server.close()

    def test_display_and_link_paths_share_the_issue_cache(self):
        # issue_ref() (display) and comment_link() (href) describe the same
        # item, so they must share the ("issue", uuid) entry: one request.
        server = FakeMulticaAPI(workspace_body={"slug": "seed"})
        try:
            resolver = _ws_resolver(server)
            resolver.issue_ref(ISSUE_ID, "没有标识符前缀的标题")
            resolver.comment_link(ISSUE_ID, COMMENT_ID)
            assert len([p for p in server.requests if "/api/issues/" in p]) == 1
        finally:
            server.close()


class TestWebRootGate:
    """§SPEC-002 R2 (QA H1/L1/L2): NOTIFIER_WEB_BASE_URL is the ONLY web
    root. Unset, non-http, over-long, or charset-violating values degrade to
    no link with ZERO requests — the gates must run before any lookup, and
    the API origin must never be used as a fallback."""

    def _resolver(self, server, web_base):
        return MetadataResolver(
            server_url=server.base_url, pat=PAT, workspace_id=WS_UUID,
            timeout=2.0, web_base=web_base)

    def test_unset_web_root_never_links_and_never_falls_back(self):
        # The API origin (server.base_url) must NOT become the web root.
        server = FakeMulticaAPI(workspace_body={"slug": "seed"})
        try:
            resolver = MetadataResolver(
                server_url=server.base_url, pat=PAT, workspace_id=WS_UUID,
                timeout=2.0)
            assert resolver.comment_link(ISSUE_ID, COMMENT_ID) == ""
            assert server.requests == []
        finally:
            server.close()

    @pytest.mark.parametrize("web_base", [
        "ftp://web.test:9277",
        "web.test:9277",
        "//web.test:9277",
        "",
    ])
    def test_non_http_web_root_rejected_with_zero_requests(self, web_base):
        # Discriminating zero-request assertion: the fake API here WORKS, so
        # if the http(s) gate were missing the slug/issue lookups would fire
        # and be recorded — the assertion fails. (Transport-level failures
        # prove nothing; see the QA L2 finding.)
        server = FakeMulticaAPI(workspace_body={"slug": "seed"})
        try:
            assert self._resolver(server, web_base).comment_link(
                ISSUE_ID, COMMENT_ID) == ""
            assert server.requests == []
        finally:
            server.close()

    @pytest.mark.parametrize("tail", [
        "&" * 505,             # QA L1 repro: escape-amplifying base
        "a&b",                 # charset-only: short enough to pass the length gate,
                               # so only the '&' exclusion can reject it
        "x/\"onmouseover=\"1",  # quotes must not reach the href attribute
        "a<b>c",
        "a?b=1",
        "a b",
        "a\nb",
    ])
    def test_charset_violating_web_root_rejected_with_zero_requests(self, tail):
        server = FakeMulticaAPI(workspace_body={"slug": "seed"})
        try:
            web_base = "http://web.test/" + tail
            assert self._resolver(server, web_base).comment_link(
                ISSUE_ID, COMMENT_ID) == ""
            assert server.requests == []
        finally:
            server.close()

    def test_max_length_charset_valid_web_root_links(self):
        server = FakeMulticaAPI(workspace_body={"slug": "seed"})
        try:
            web_base = "http://" + "a" * 505  # exactly 512, charset-clean
            url = self._resolver(server, web_base).comment_link(ISSUE_ID, COMMENT_ID)
            assert url == f"{web_base}/seed/issues/SEE-1567#comment-{COMMENT_ID}"
        finally:
            server.close()

    def test_overlong_web_root_rejected_with_zero_requests(self):
        server = FakeMulticaAPI(workspace_body={"slug": "seed"})
        try:
            web_base = "http://" + "a" * 600
            assert self._resolver(server, web_base).comment_link(
                ISSUE_ID, COMMENT_ID) == ""
            assert server.requests == []
        finally:
            server.close()

    def test_trailing_slash_web_root_normalized_by_resolver(self):
        # The config layer strips a trailing slash, but a resolver built
        # directly with one must still compose a single-slash path (join
        # boundary is a normalisation site, not a string concat accident).
        server = FakeMulticaAPI(workspace_body={"slug": "seed"})
        try:
            url = self._resolver(server, "http://web.test/").comment_link(
                ISSUE_ID, COMMENT_ID)
            assert url == f"http://web.test/seed/issues/SEE-1567#comment-{COMMENT_ID}"
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
