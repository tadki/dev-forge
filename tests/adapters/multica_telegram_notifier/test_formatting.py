"""§SPEC-001/002/003/005 unit tests for the Markdown→Telegram-HTML renderer:
escaping, supported-tag whitelist, GFM table → key-value cards, safe
degradations, UTF-16 fitting, and the readable header composition."""

import pytest

from multica_telegram_notifier.formatting import (
    SEPARATOR,
    Notification,
    fit_html_text,
    markdown_to_html,
    render_notification,
)


class _FixedResolver:
    """Resolver stub returning canned labels; records query attempts."""

    def __init__(self, agent=("Bachi", "agent"), issue=("SEE-1567", "优化排版")):
        self.agent = agent
        self.issue = issue
        self.agent_queries = 0
        self.issue_queries = 0

    def agent_display(self, actor_type, actor_id):
        self.agent_queries += 1
        return self.agent[0]

    def issue_ref(self, issue_id, item_title):
        self.issue_queries += 1
        return self.issue


class _BrokenResolver:
    """Simulates total metadata-query failure."""

    def agent_display(self, actor_type, actor_id):
        return "Agent" if actor_type == "agent" else "Unknown"

    def issue_ref(self, issue_id, item_title):
        return ("", item_title or "")


def _item(**overrides):
    item = {
        "id": "item-1",
        "type": "issue_assigned",
        "title": "SEE-1567 优化排版",
        "body": "正文",
        "issue_id": "11111111-1111-1111-1111-111111111111",
        "actor_type": "agent",
        "actor_id": "22222222-2222-2222-2222-222222222222",
        "created_at": "2026-11-11T03:00:00Z",
    }
    item.update(overrides)
    return item


class TestEscaping:
    def test_html_specials_escaped(self):
        assert markdown_to_html("a <b> & \"c\"") == "a &lt;b&gt; &amp; \"c\""

    def test_script_tag_text_is_escaped_not_rendered(self):
        out = markdown_to_html("<script>alert(1)</script>")
        assert "<script>" not in out
        assert "&lt;script&gt;" in out

    def test_code_span_content_escaped(self):
        assert markdown_to_html("`<i>x</i>`") == "<code>&lt;i&gt;x&lt;/i&gt;</code>"

    def test_bold_italic_strikethrough(self):
        assert markdown_to_html("**b** *i* ~~s~~") == "<b>b</b> <i>i</i> <s>s</s>"

    def test_heading_becomes_bold(self):
        assert markdown_to_html("## 标题") == "<b>标题</b>"

    def test_unordered_list_bullets(self):
        assert markdown_to_html("- 一\n- 二") == "• 一\n• 二"

    def test_ordered_list_keeps_number(self):
        assert markdown_to_html("1. 甲\n2. 乙") == "1. 甲\n2. 乙"

    def test_blockquote_wrapped(self):
        assert markdown_to_html("> 引用行") == "<blockquote>引用行</blockquote>"

    def test_fenced_code_pre_escaped(self):
        out = markdown_to_html("```python\nx < y\n```")
        assert out.startswith("<pre>")
        assert out.endswith("</pre>")
        assert "x &lt; y" in out

    def test_unterminated_fence_still_balanced(self):
        out = markdown_to_html("```code\nnever closed")
        assert out.count("<pre>") == out.count("</pre>") == 1

    def test_link_href_and_text(self):
        out = markdown_to_html("[标题](https://x.test/a?b=1&c=2)")
        assert out == '<a href="https://x.test/a?b=1&amp;c=2">标题</a>'

    def test_dangerous_scheme_neutralized_to_plain_text(self):
        out = markdown_to_html("[点我](javascript:alert(1))")
        assert "<a" not in out and "href" not in out
        assert "点我" in out

    def test_autolink(self):
        assert markdown_to_html("<https://a.test>") == '<a href="https://a.test">https://a.test</a>'

    def test_image_becomes_link(self):
        out = markdown_to_html("![图](https://x.test/i.png)")
        assert out == '<a href="https://x.test/i.png">图</a>'

    def test_formatting_inside_code_span_is_literal(self):
        out = markdown_to_html("`**x**`")
        assert "<b>" not in out
        assert "<code>**x**</code>" in out


class TestTables:
    def test_two_column_becomes_key_value_lines(self):
        md = "| 状态 | 说明 |\n|---|---|\n| ok | 好 |\n| bad | 坏 |"
        out = markdown_to_html(md)
        assert "|---|" not in out and "---" not in out.replace("&amp;", "")
        assert "<b>状态</b>: ok · <b>说明</b>: 好" in out
        assert "<b>状态</b>: bad · <b>说明</b>: 坏" in out

    def test_three_column_becomes_row_cards(self):
        md = "| A | B | C |\n|---|---|---|\n| 1 | 2 | 3 |"
        out = markdown_to_html(md)
        assert "• <b>A</b>: 1\n• <b>B</b>: 2\n• <b>C</b>: 3" in out

    def test_cell_inline_formatting_kept(self):
        md = "| K | V |\n|---|---|\n| **粗** | `代` |"
        out = markdown_to_html(md)
        assert "<b>粗</b>" in out and "<code>代</code>" in out

    def test_empty_cell_placeholder(self):
        md = "| K | V |\n|---|---|\n| a |  |"
        assert "<b>K</b>: a · <b>V</b>: —" in markdown_to_html(md)

    def test_ragged_row_padded_and_extras_merged(self):
        md = "| A | B |\n|---|---|\n| only |\n| 1 | 2 | extra |"
        out = markdown_to_html(md)
        assert "<b>A</b>: only · <b>B</b>: —" in out
        assert "<b>A</b>: 1 · <b>B</b>: 2 · extra" in out

    def test_wide_table_summarized(self):
        header = "| " + " | ".join(f"c{i}" for i in range(1, 8)) + " |"
        delim = "|" + "|".join(["---"] * 7) + "|"
        row = "|" + "|".join(["v"] * 7) + "|"
        out = markdown_to_html("\n".join([header, delim, row]))
        assert "表格过宽" in out and "7 列 × 1 行" in out
        assert "|" not in out

    def test_cjk_cells(self):
        md = "| 名称 | 值 |\n|---|---|\n| 中文键 | 中文值 |"
        assert "<b>名称</b>: 中文键 · <b>值</b>: 中文值" in markdown_to_html(md)

    def test_pipe_text_without_delimiter_row_stays_text(self):
        out = markdown_to_html("a | b 普通文本")
        assert "a | b 普通文本" in out
        assert "<b>" not in out

    def test_pseudo_table_inside_code_block_untouched(self):
        md = "```\n| a | b |\n|---|---|\n```"
        out = markdown_to_html(md)
        assert "| a | b |" in out and "|---|---|" in out
        assert "<b>" not in out

    def test_plain_mode_table_has_no_tags(self):
        md = "| K | V |\n|---|---|\n| a | b |"
        out = render_notification(_item(body=md), _FixedResolver()).plain
        assert "<b>" not in out
        assert "K: a · V: b" in out

    def test_six_column_table_not_summarized(self):
        # Exactly _MAX_TABLE_COLS (6) columns must still render as cards; only
        # strictly wider tables degrade to the "too wide" note.
        header = "| " + " | ".join(f"c{i}" for i in range(1, 7)) + " |"
        delim = "|" + "|".join(["---"] * 6) + "|"
        row = "|" + "|".join(str(i) for i in range(1, 7)) + "|"
        out = markdown_to_html("\n".join([header, delim, row]))
        assert "表格过宽" not in out
        assert "<b>c1</b>: 1" in out

    def test_partially_delimited_row_is_not_a_table(self):
        # A row whose cells do not ALL look like delimiter cells must not turn
        # the block into a table (all(), not any()).
        md = "| A | B |\n| --- | notdelim |\n| 1 | 2 |"
        out = markdown_to_html(md)
        assert "<b>A</b>: 1" not in out
        assert "notdelim" in out


class TestHeaderComposition:
    def test_header_order_agent_then_identifier_then_title(self):
        note = render_notification(_item(), _FixedResolver(
            agent=("Revy", "agent"), issue=("SEE-1567", "优化 Telegram 排版")))
        header = note.html.split("\n", 1)[0]
        assert header.index("Revy") < header.index("SEE-1567") < header.index("优化 Telegram 排版")

    def test_header_is_bold_html(self):
        note = render_notification(_item(), _FixedResolver())
        header = note.html.split("\n", 1)[0]
        assert header.startswith("🤖 <b>Bachi</b> · <b>SEE-1567</b> 优化排版")

    def test_footer_time_and_type(self):
        note = render_notification(_item(), _FixedResolver())
        assert note.html.rstrip().endswith("🕐 2026-11-11T03:00:00Z · issue_assigned")

    def test_missing_issue_omits_segment_without_uuid(self):
        note = render_notification(
            _item(issue_id=None, title="只有标题"), _FixedResolver(issue=("", "")))
        header = note.html.split("\n", 1)[0]
        assert "SEE-" not in header
        assert "11111111" not in note.html

    def test_resolver_failure_falls_back_without_bare_uuid(self):
        item = _item(title=None, body=None)
        item["issue_id"] = "99999999-9999-9999-9999-999999999999"
        note = render_notification(item, _BrokenResolver())
        assert "99999999" not in note.html
        assert "🤖 <b>Agent</b>" in note.html

    def test_readable_actor_slug_used_directly(self):
        class _SlugResolver:
            def agent_display(self, actor_type, actor_id):
                return actor_id

            def issue_ref(self, issue_id, item_title):
                return ("", item_title or "")

        note = render_notification(_item(title="t", actor_id="agent-atlas-slug"), _SlugResolver())
        assert "agent-atlas-slug" in note.html

    def test_returns_both_modes(self):
        note = render_notification(_item(), _FixedResolver())
        assert isinstance(note, Notification)
        assert "<b>" in note.html and "<b>" not in note.plain
        assert "Bachi" in note.plain


LINK = "http://x.test/seed/issues/SEE-1567#comment-" + "4" * 36


class _LinkResolver(_FixedResolver):
    """FixedResolver plus a canned deep link (the MetadataResolver surface
    used for the SEE-1572 title-line anchor)."""

    def __init__(self, link=LINK, **kwargs):
        super().__init__(**kwargs)
        self.link = link
        self.link_calls = []

    def comment_link(self, identifier, comment_id):
        self.link_calls.append((identifier, comment_id))
        return self.link


class TestTitleDeepLink:
    """§SPEC-001: in HTML mode the whole header line renders as ONE <a href>
    anchor to the comment deep link; the line's text content is unchanged and
    the plain fallback header stays exactly as before."""

    def test_html_header_wrapped_in_single_anchor(self):
        note = render_notification(_item(), _LinkResolver())
        header = note.html.split("\n", 1)[0]
        assert header == (
            f'<a href="{LINK}">🤖 <b>Bachi</b> · <b>SEE-1567</b> 优化排版</a>')

    def test_header_line_has_exactly_one_anchor(self):
        note = render_notification(_item(), _LinkResolver())
        header = note.html.split("\n", 1)[0]
        assert header.count("<a ") == 1 and header.count("</a>") == 1

    def test_anchor_text_content_identical_to_unlinked(self):
        linked = render_notification(_item(), _LinkResolver()).html.split("\n", 1)[0]
        unlinked = render_notification(_item(), _LinkResolver(link="")).html.split("\n", 1)[0]
        prefix = f'<a href="{LINK}">'
        assert linked.startswith(prefix) and linked.endswith("</a>")
        assert linked[len(prefix):-len("</a>")] == unlinked

    def test_plain_header_never_linked(self):
        note = render_notification(_item(), _LinkResolver())
        head_plain = note.plain.split("\n", 1)[0]
        assert head_plain == "🤖 Bachi · SEE-1567 优化排版"
        assert "<a" not in note.plain

    def test_resolver_without_comment_link_stays_unlinked(self):
        # Duck-typed resolvers without the deep-link surface (older stubs,
        # the static resolver) must keep the current header byte-for-byte.
        note = render_notification(_item(), _FixedResolver())
        header = note.html.split("\n", 1)[0]
        assert header.startswith("🤖 <b>Bachi</b> · <b>SEE-1567</b> 优化排版")
        assert "<a " not in header

    def test_empty_link_degrades_to_unlinked_header(self):
        note = render_notification(_item(), _LinkResolver(link=""))
        header = note.html.split("\n", 1)[0]
        assert header.startswith("🤖 <b>Bachi</b>")
        assert "<a " not in header

    def test_comment_id_read_from_details_wire_field(self):
        # Live wire capture (2026-11-13, read-only): the comment uuid rides at
        # item["details"]["comment_id"] as a canonical UUID string.
        note = render_notification(
            _item(details={"comment_id": "4" * 36}), _LinkResolver())
        assert note.html.split("\n", 1)[0].startswith(f'<a href="{LINK}">')
        resolver = _LinkResolver()
        render_notification(_item(details={"comment_id": "4" * 36}), resolver)
        assert resolver.link_calls == [("SEE-1567", "4" * 36)]

    def test_missing_details_passes_empty_comment_id(self):
        resolver = _LinkResolver()
        render_notification(_item(), resolver)
        assert resolver.link_calls == [("SEE-1567", "")]

    def test_non_dict_details_and_non_string_comment_id_safe(self):
        resolver = _LinkResolver()
        render_notification(_item(details=[]), resolver)
        render_notification(_item(details={"comment_id": 5}), resolver)
        assert resolver.link_calls == [("SEE-1567", ""), ("SEE-1567", "")]

    def test_empty_header_line_never_gets_bare_anchor(self):
        class _EmptyResolver:
            def agent_display(self, actor_type, actor_id):
                return ""

            def issue_ref(self, issue_id, item_title):
                return ("", "")

            def comment_link(self, identifier, comment_id):
                return LINK

        note = render_notification(_item(title=None, issue_id=None), _EmptyResolver())
        assert not note.html.startswith("<a")
        assert "<a " not in note.html.split("\n", 1)[0]


class TestDeepLinkBudget:
    """§SPEC-004: the anchor wrapper is part of the fixed header budget —
    worst-case URL components must keep the rendered HTML under 4096 UTF-16
    units with balanced tags and no dangling entity."""

    _MAX_LINK = ("http://" + "a" * 500 + ".test/" + "b" * 64
                 + "/issues/SEE-999999999999#comment-" + "4" * 36)

    def _assert_budget_safe(self, note_html):
        import re

        assert len(note_html.encode("utf-16-le", errors="ignore")) // 2 <= 4096
        assert not re.search(r"&(?!amp;|lt;|gt;|#\d+;|#x[0-9a-fA-F]+;)", note_html)
        assert note_html.count("<a ") == note_html.count("</a>")

    def test_max_components_anchor_fits_budget(self):
        max_link = self._MAX_LINK

        class _MaxLinkResolver(_FixedResolver):
            def comment_link(self, identifier, comment_id):
                return max_link

        note = render_notification(_item(title="&" * 300), _MaxLinkResolver())
        self._assert_budget_safe(note.html)
        assert f'<a href="{max_link}">' in note.html

    def test_url_never_carries_event_text(self):
        class _CannedLinkResolver(_FixedResolver):
            def comment_link(self, identifier, comment_id):
                return LINK

        item = _item(title='</a><script>alert(1)</script><a href="http://evil')
        note = render_notification(item, _CannedLinkResolver())
        header = note.html.split("\n", 1)[0]
        assert header.count("<a ") == 1
        assert header.startswith(f'<a href="{LINK}">')
        assert "evil" not in header.split('">', 1)[0]

    def test_huge_agent_and_anchor_together_fit(self):
        max_link = self._MAX_LINK

        class _HugeAgentLink(_FixedResolver):
            def agent_display(self, actor_type, actor_id):
                return "&" * 64

            def comment_link(self, identifier, comment_id):
                return max_link

        note = render_notification(_item(title="&" * 300), _HugeAgentLink())
        self._assert_budget_safe(note.html)


class TestFitting:
    def _huge_body(self, units):
        return "字" * (units // 1)  # CJK = 1 UTF-16 unit each

    def test_long_document_fits_4096_and_balanced_tags(self):
        body = ("## 段落\n\n**加粗** 内容 行\n\n| K | V |\n|---|---|\n" +
                "\n".join(f"| k{i} | v{i}" + str(i) + " |" for i in range(300)))
        note = render_notification(_item(body=body), _FixedResolver())
        encoded = note.html.encode("utf-16-le", errors="strict")
        assert len(encoded) // 2 <= 4096
        assert note.html.count("<b>") == note.html.count("</b>")

    def test_non_bmp_emoji_heavy_text_fits_without_surrogates(self):
        body = "🚀" * 3000  # each = 2 UTF-16 units
        note = render_notification(_item(body=body), _FixedResolver())
        note.html.encode("utf-16-le", errors="strict")  # must not raise
        assert len(note.html.encode("utf-16-le")) // 2 <= 4096

    def test_lone_surrogate_dropped(self):
        note = render_notification(_item(body="ok \ud800 文本"), _FixedResolver())
        note.html.encode("utf-16-le", errors="strict")

    def test_entities_never_cut(self):
        import re

        body = "&" * 4000 + "尾部"
        note = render_notification(_item(body=body), _FixedResolver())
        assert len(note.html.encode("utf-16-le")) // 2 <= 4096
        # Every & that survived must be part of a whole entity, never "amp&".
        assert not re.search(r"&(?!amp;|lt;|gt;)", note.html)

    def test_fit_html_text_direct(self):
        md = "x" * 9000
        out = fit_html_text(md, header="🤖 <b>A</b>\n──────────\n", footer="\n\n🕐 t")
        assert len(out.encode("utf-16-le")) // 2 <= 4096

    def test_truncation_keeps_head_of_document(self):
        body = "开头标记\n\n" + "y" * 8000
        note = render_notification(_item(body=body), _FixedResolver())
        assert "开头标记" in note.html

    def test_fit_at_exact_limit_is_unchanged(self):
        # A rendered body exactly at the limit must be returned as-is, not
        # shrunk by falling into the shrink loop (boundary is <=, not <).
        assert fit_html_text("abc", limit=3) == "abc"
        assert fit_html_text("abcde", limit=5) == "abcde"

    def test_blank_runs_collapsed_to_single_blank_line(self):
        # header ending in a newline plus the footer's leading blank line would
        # produce a triple newline; it must collapse to a single blank line.
        note = render_notification(_item(body=""), _FixedResolver())
        assert "\n\n\n" not in note.html


class TestUrlEmphasisIsolation:
    """F1: emphasis regexes must never touch href attributes or URL text."""

    def test_link_with_dunder_url_href_intact(self):
        out = markdown_to_html("[init](https://x.test/adapters/__init__.py)")
        assert out == '<a href="https://x.test/adapters/__init__.py">init</a>'

    def test_bare_url_text_not_emphasized(self):
        out = markdown_to_html("see https://x.test/a/__init__.py end")
        assert "<b>" not in out and "<i>" not in out
        assert "https://x.test/a/__init__.py" in out

    def test_plain_mode_urls_undistorted(self):
        out = render_notification(
            _item(body="[init](https://x.test/a/__init__.py) ok https://y.test/__main__.py"),
            _FixedResolver()).plain
        assert "__init__.py" in out and "__main__.py" in out
        assert "<b>" not in out

    def test_emphasis_still_works_outside_urls(self):
        assert markdown_to_html("待办：_注意_ 与 **加粗**") == "待办：<i>注意</i> 与 <b>加粗</b>"


class TestShortDelimiterTables:
    """F2: GFM delimiter cells need only one hyphen."""

    def test_single_hyphen_delimiter(self):
        md = "| A | B |\n|-|-|\n| 1 | 2 |"
        assert "<b>A</b>: 1 · <b>B</b>: 2" in markdown_to_html(md)

    def test_alignment_colons_with_short_delims(self):
        md = "| A | B |\n|:-:|-:|\n| 1 | 2 |"
        assert "<b>A</b>: 1 · <b>B</b>: 2" in markdown_to_html(md)


class TestHeaderOnlyTable:
    """F3: a header-only GFM table must keep its header data."""

    def test_header_only_table_before_paragraph(self):
        md = "| A | B |\n|---|---|\n\n段落"
        out = markdown_to_html(md)
        assert "<b>A</b> · <b>B</b>" in out
        assert "段落" in out

    def test_header_only_table_at_eof(self):
        out = markdown_to_html("| A | B |\n|---|---|")
        assert "<b>A</b> · <b>B</b>" in out


class TestIdentifierOnlyTitle:
    """F4: a title that is exactly the identifier must not repeat."""

    def test_pure_identifier_title_not_duplicated(self):
        note = render_notification(_item(title="SEE-100"), None)
        assert note.html.count("SEE-100") == 1

    def test_normal_title_still_renders_identifier_and_title(self):
        note = render_notification(_item(title="SEE-100 修复登录"), None)
        assert "<b>SEE-100</b> 修复登录" in note.html


class TestSentinelNeutralization:
    """F5: literal NUL/SOH control chars must not bypass escaping or
    collide with protection keys."""

    def test_literal_nul_sentinel_line_escaped(self):
        out = markdown_to_html("\x00<b>inject</b>\x00")
        assert "<b>inject</b>" not in out
        assert "&lt;b&gt;inject&lt;/b&gt;" in out

    def test_protection_key_collision_cannot_duplicate_fragments(self):
        out = markdown_to_html("`code0` \x010\x01 tail")
        assert out.count("<code>") == 1
        assert "tail" in out

    def test_control_chars_removed_from_labels(self):
        note = render_notification(_item(title="abc\x00<b>x</b>"), None)
        assert "<b>x</b>" not in note.html
        assert "&lt;b&gt;x&lt;/b&gt;" in note.html


class TestParenthesizedUrls:
    """F7: link destinations keep balanced parentheses."""

    def test_parens_in_link_url_kept(self):
        out = markdown_to_html("[w](https://x.test/Foo_(bar))")
        assert out == '<a href="https://x.test/Foo_(bar)">w</a>'

    def test_image_parens_kept(self):
        out = markdown_to_html("![i](https://x.test/a_(b).png)")
        assert out == '<a href="https://x.test/a_(b).png">i</a>'

    def test_sentence_paren_after_link_not_swallowed(self):
        out = markdown_to_html("[w](https://x.test/a) (after)")
        assert out == '<a href="https://x.test/a">w</a> (after)'


class TestBlockStructure:
    """Block-level constructs that must render without swallowing neighbours."""

    def test_horizontal_rule_becomes_separator(self):
        assert markdown_to_html("---") == SEPARATOR
        assert SEPARATOR in markdown_to_html("上\n\n---\n\n下")

    def test_quote_block_ends_at_non_quote_line(self):
        out = markdown_to_html("> 引用\n普通\n> 再引用")
        assert out.count("<blockquote>") == 2
        assert "<blockquote>引用</blockquote>" in out
        assert "普通" in out

    def test_pipe_line_followed_by_plain_line_not_table(self):
        out = markdown_to_html("a | b\n普通文本")
        assert "<b>" not in out
        assert "a | b" in out and "普通文本" in out

    def test_single_column_table_becomes_bullet_card(self):
        out = markdown_to_html("| K |\n|---|\n| v |")
        assert "• <b>K</b>: v" in out

    def test_list_followed_by_paragraph_keeps_next_line(self):
        # A list block must consume only its own lines; the following paragraph
        # line must still render (regression guard for block-consumption bounds).
        out = markdown_to_html("- 项\n后续段落")
        assert "• 项" in out
        assert "后续段落" in out


class TestStaticResolverFallbacks:
    """The no-query static resolver must handle a missing title."""

    def test_no_title_and_no_issue_renders_agent_only_header(self):
        note = render_notification(_item(title=None, issue_id=None), None)
        header = note.html.split("\n", 1)[0]
        assert "🤖 <b>Agent</b>" in header
        assert "SEE-" not in header
        assert "None" not in header


class TestFittingDegradation:
    """When the fixed header/footer alone exceed the budget the fitter must
    degrade deterministically instead of looping or emitting broken tags."""

    def test_fit_degrades_when_header_and_footer_exceed_limit(self):
        out = fit_html_text("x" * 500, header="H" * 80, footer="F" * 80, limit=100)
        assert out.startswith("H" * 80)
        assert out.endswith("F" * 80)
        assert "<" not in out and ">" not in out


class TestFixedPartsBudget:
    """FR-1: header/footer fixed metadata must fit inside the 4096 UTF-16
    budget too — a huge event title/agent name/created_at must never push the
    rendered HTML past the limit or leave a dangling entity."""

    _ENTITY_TAIL_LEGAL = None

    def _assert_budget_safe(self, note_html):
        import re

        assert len(note_html.encode("utf-16-le", errors="ignore")) // 2 <= 4096
        # No dangling entity anywhere: every & starts a complete entity.
        assert not re.search(r"&(?!amp;|lt;|gt;|#\d+;|#x[0-9a-fA-F]+;)", note_html)
        # The truncated tail must not be a bare "&" either.
        assert not note_html.rstrip().endswith("&")

    def test_huge_ampersand_title_fits(self):
        note = render_notification(_item(title="&" * 5000), None)
        self._assert_budget_safe(note.html)
        assert note.html.startswith("🤖")

    def test_huge_agent_name_fits(self):
        class _HugeAgent:
            def agent_display(self, actor_type, actor_id):
                return "A" * 5000

            def issue_ref(self, issue_id, item_title):
                return ("SEE-1", "t")

        note = render_notification(_item(), _HugeAgent())
        self._assert_budget_safe(note.html)
        assert "<b>" in note.html and note.html.count("<b>") == note.html.count("</b>")

    def test_huge_created_at_fits(self):
        note = render_notification(_item(created_at="&" * 5000), None)
        self._assert_budget_safe(note.html)

    def test_huge_api_title_fits(self):
        class _HugeTitle:
            def agent_display(self, actor_type, actor_id):
                return "Bachi"

            def issue_ref(self, issue_id, item_title):
                return ("SEE-1", "&" * 5000)

        note = render_notification(_item(), _HugeTitle())
        self._assert_budget_safe(note.html)

    def test_huge_title_keeps_readable_prefix(self):
        note = render_notification(_item(title="标题开头" + "&" * 5000), None)
        self._assert_budget_safe(note.html)
        assert "标题开头" in note.html

    def test_huge_title_plain_mode_bounded_header(self):
        note = render_notification(_item(title="&" * 5000), None)
        head_line = note.plain.split("\n", 1)[0]
        assert len(head_line.encode("utf-16-le", errors="ignore")) // 2 < 800


class TestClampBounds:
    """Hardener: the clamp must mark truncation with an ellipsis, treat the
    exact limit as unchanged, and apply to identifier/kind/footer components;
    the fit fallback budget must account for x5 entity growth."""

    def test_clamp_truncates_with_ellipsis(self):
        note = render_notification(
            _item(title="T" * 300), _FixedResolver(issue=("SEE-1567", "T" * 300)))
        header = note.html.split("\n", 1)[0]
        assert "…" in header
        assert "T" * 300 not in header

    def test_clamp_at_exact_limit_keeps_component_whole(self):
        note = render_notification(
            _item(title="T" * 256), _FixedResolver(issue=("SEE-1567", "T" * 256)))
        header = note.html.split("\n", 1)[0]
        assert "T" * 256 in header
        assert "…" not in header

    def test_overlong_identifier_clamped(self):
        long_id = "SEE-" + "9" * 300
        note = render_notification(_item(title=long_id), _FixedResolver(issue=(long_id, "")))
        header = note.html.split("\n", 1)[0]
        assert "…" in header
        assert long_id not in header

    def test_footer_kind_escaped_in_html(self):
        note = render_notification(_item(type="<b>kind&amp;</b>"), _FixedResolver())
        assert note.html.rstrip().endswith("· &lt;b&gt;kind&amp;amp;&lt;/b&gt;")

    def test_footer_kind_clamped(self):
        note = render_notification(_item(type="K" * 100), _FixedResolver())
        assert note.html.rstrip().endswith("K" * 31 + "…")
        assert "K" * 100 not in note.html

    def test_fit_fallback_budget_accounts_for_escape_growth(self):
        import re

        out = fit_html_text("&" * 2000, header="H" * 10, footer="F" * 10, limit=100)
        assert len(out.encode("utf-16-le", errors="strict")) // 2 <= 100
        assert not re.search(r"&(?!amp;|lt;|gt;)", out)
