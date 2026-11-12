"""Markdown → Telegram-HTML rendering (§SPEC-002/003/005) and the readable
notification layout (§SPEC-001).

Telegram's parse_mode=HTML accepts only a small tag whitelist (b, i, s, code,
pre, blockquote, a); everything else must arrive as escaped text. The
renderer is line-based and deterministic: headings become bold, lists become
bullet/numbered lines, GFM pipe tables become mobile-friendly key-value
cards, and any input that cannot be understood degrades to escaped plain
text — never to broken markup.
"""

import re
from typing import NamedTuple

from multica_telegram_notifier.telegram import MAX_TEXT_LENGTH, truncate_utf16

SEPARATOR = "──────────"

_ACTOR_ICONS = {"agent": "🤖", "member": "👤", "user": "👤"}
_DEFAULT_ICON = "🔔"

_UUID_FULL = re.compile(
    r"[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}")
_IDENTIFIER_RE = re.compile(r"^\s*(SEE-\d+)\s*(.*)$", re.S)

_CODE_SPAN_RE = re.compile(r"`([^`\n]+)`")
_AUTOLINK_RE = re.compile(r"<(https?://[^<>\s]+)>")
# Link destinations keep one level of balanced parentheses (F7: wiki-style
# https://x/Foo_(bar) must not be cut at the first ")").
_LINK_DEST = r"((?:[^()\s]|\([^()\s]*\))*)"
_IMAGE_RE = re.compile(r"!\[([^\]]*)\]\(" + _LINK_DEST + r"\)")
_LINK_RE = re.compile(r"\[([^\]]+)\]\(" + _LINK_DEST + r"\)")
_BOLD_RE = re.compile(r"\*\*(.+?)\*\*|__(.+?)__", re.S)
_ITALIC_STAR_RE = re.compile(r"(?<![\w*])\*(?!\s)([^*\n]+?)(?<!\s)\*(?!\*)")
_ITALIC_UNDER_RE = re.compile(r"(?<![\w_])_(?!\s)([^_\n]+?)(?<!\s)_(?![\w_])")
_STRIKE_RE = re.compile(r"~~(.+?)~~", re.S)
# Bare URLs in text are shielded from emphasis the same way (F1: dunder
# segments in a URL must not become bold/italic markers); Telegram still
# auto-links bare URLs in message text on its own.
_BARE_URL_RE = re.compile(r"https?://[^\s<>\"']+")
_BARE_URL_TRAILING = ")]}.,;:!?'\""

_FENCE_RE = re.compile(r"^\s*```\s*(\S*)\s*$")
_HEADING_RE = re.compile(r"^\s{0,3}#{1,6}\s+(.*?)\s*#*\s*$")
_HR_RE = re.compile(r"^\s{0,3}(?:-{3,}|\*{3,}|_{3,})\s*$")
_QUOTE_RE = re.compile(r"^\s{0,3}>\s?(.*)$")
_LIST_RE = re.compile(r"^(\s*)([-*+]|\d+[.)])\s+(.*)$")

_DELIM_CELL_RE = re.compile(r":?-+:?")

_MAX_TABLE_COLS = 6
_FENCE_SENTINEL = "\x00"

# FR-1: fixed header/footer metadata is clamped in UTF-16 units BEFORE the
# heading text is escaped. Worst case (& → &amp; ×5): agent 64→320,
# identifier 16→80, title 256→1280, footer ~480 plus template/separator ~80.
# SEE-1572: the header line may be wrapped in one <a href> anchor; every URL
# component is validated upstream (multica_api: http(s) web root ≤512 code
# points, slug [a-z0-9-]{1,64}, identifier SEE-\d{1,12}, canonical UUID), so
# the URL is bounded at 512+1+64+8+16+9+36 = 646 units and the wrapper adds
# ≤ 646+15. Worst-case fixed parts: 320+3+16+1+1280+661 (header) + 560
# (footer) ⇒ ≤ ~2840 units, safely under Telegram's 4096 budget.
_MAX_AGENT_UNITS = 64
_MAX_IDENTIFIER_UNITS = 16
_MAX_TITLE_UNITS = 256
_MAX_CREATED_UNITS = 64
_MAX_KIND_UNITS = 32


class Notification(NamedTuple):
    html: str
    plain: str


def escape_html(text: str) -> str:
    return text.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")


def utf16_len(text: str) -> int:
    # errors="ignore" drops lone surrogates so the measurement can never raise.
    return len(text.encode("utf-16-le", errors="ignore")) // 2


def _looks_like_uuid(value: str) -> bool:
    return _UUID_FULL.fullmatch(value) is not None


# --- inline rendering ---


def _sanitize(text: str) -> str:
    # F5: literal NUL/SOH in upstream text must not bypass escaping (they are
    # the sentinel/protection-key alphabet); they never appear in legitimate
    # notification content, so they are removed outright.
    return text.replace("\x00", "").replace("\x01", "")


def _anchor(text: str, url: str, mode: str) -> str:
    url_ok = url.lower().startswith(("http://", "https://"))
    if mode != "html":
        return f"{text} ({url})" if url_ok else text
    if not url_ok:
        # Neutralize dangerous schemes: render the label without any anchor.
        return escape_html(text)
    return f'<a href="{escape_html(url)}">{escape_html(text)}</a>'


def _render_inline(text: str, mode: str) -> str:
    protected = {}

    def _protect(rendered: str) -> str:
        key = f"\x01{len(protected)}\x01"
        protected[key] = rendered
        return key

    def _code(match):
        content = escape_html(match.group(1)) if mode == "html" else match.group(1)
        return _protect(f"<code>{content}</code>" if mode == "html" else content)

    def _bare_url(match):
        url = match.group(0)
        stripped = url.rstrip(_BARE_URL_TRAILING)
        tail = url[len(stripped):]
        shown = escape_html(stripped) if mode == "html" else stripped
        return _protect(shown) + tail

    out = _CODE_SPAN_RE.sub(_code, text)
    # Links, images, autolinks and bare URLs are fully resolved into the
    # protected set BEFORE emphasis runs, so the emphasis regexes can never
    # reach href attributes or URL text (F1).
    out = _IMAGE_RE.sub(
        lambda m: _protect(_anchor(m.group(1) or m.group(2), m.group(2), mode)), out)
    out = _LINK_RE.sub(lambda m: _protect(_anchor(m.group(1), m.group(2), mode)), out)
    out = _AUTOLINK_RE.sub(lambda m: _protect(_anchor(m.group(1), m.group(1), mode)), out)
    out = _BARE_URL_RE.sub(_bare_url, out)
    if mode == "html":
        out = escape_html(out)
    if mode == "html":
        out = _BOLD_RE.sub(lambda m: f"<b>{m.group(1) or m.group(2)}</b>", out)
        out = _STRIKE_RE.sub(lambda m: f"<s>{m.group(1)}</s>", out)
        out = _ITALIC_STAR_RE.sub(lambda m: f"<i>{m.group(1)}</i>", out)
        out = _ITALIC_UNDER_RE.sub(lambda m: f"<i>{m.group(1)}</i>", out)
    else:
        out = _BOLD_RE.sub(lambda m: m.group(1) or m.group(2), out)
        out = _STRIKE_RE.sub(lambda m: m.group(1), out)
        out = _ITALIC_STAR_RE.sub(lambda m: m.group(1), out)
        out = _ITALIC_UNDER_RE.sub(lambda m: m.group(1), out)
    for key, rendered in protected.items():
        out = out.replace(key, rendered)
    return out


# --- block rendering ---


def _split_fences(md: str, mode: str) -> list:
    """Collapses fenced code blocks into single sentinel-wrapped lines so
    table/list detection never sees their content (pseudo-tables in code
    must stay literal)."""
    lines = md.split("\n")
    out = []
    i = 0
    while i < len(lines):
        if _FENCE_RE.match(lines[i]):
            content = []
            i += 1
            while i < len(lines) and not _FENCE_RE.match(lines[i]):
                content.append(lines[i])
                i += 1
            if i < len(lines):
                i += 1  # closing fence
            body = "\n".join(content)
            rendered = f"<pre>{escape_html(body)}</pre>" if mode == "html" else body
            out.append(_FENCE_SENTINEL + rendered + _FENCE_SENTINEL)
        else:
            out.append(lines[i])
            i += 1
    return out


def _render_blocks(md: str, mode: str) -> str:
    md = _sanitize(md)
    lines = _split_fences(md, mode)
    blocks = []
    paragraph = []
    i = 0
    while i < len(lines):
        line = lines[i]
        if line.strip() == "":
            _flush_paragraph(blocks, paragraph)
            i += 1
            continue
        consumed, block = _render_block(lines, i, mode)
        if block is not None:
            _flush_paragraph(blocks, paragraph)
            blocks.append(block)
        if consumed:
            i += consumed
            continue
        paragraph.append(_render_inline(line, mode))
        i += 1
    _flush_paragraph(blocks, paragraph)
    return "\n\n".join(b for b in blocks if b)


def _render_block(lines: list, i: int, mode: str) -> tuple:
    """Renders the block starting at lines[i]; returns (consumed, block).
    block is None when the line starts no block (it is a paragraph line)."""
    line = lines[i]
    if line.startswith(_FENCE_SENTINEL) and line.endswith(_FENCE_SENTINEL):
        return 1, line.strip(_FENCE_SENTINEL)
    if "|" in line and i + 1 < len(lines) and _is_delimiter_row(lines[i + 1]):
        header, rows, consumed = _collect_table(lines, i)
        return consumed, _table_cards(header, rows, mode)
    if _HR_RE.match(line):
        return 1, SEPARATOR
    heading = _HEADING_RE.match(line)
    if heading:
        inner = _render_inline(heading.group(1), mode)
        return 1, (f"<b>{inner}</b>" if mode == "html" else inner)
    if _QUOTE_RE.match(line):
        return _render_quote(lines, i, mode)
    if _LIST_RE.match(line):
        return _render_list(lines, i, mode)
    return 0, None


def _render_quote(lines: list, start: int, mode: str) -> tuple:
    quote = []
    i = start
    while i < len(lines):
        m = _QUOTE_RE.match(lines[i])
        if not m:
            break
        quote.append(_render_inline(m.group(1), mode))
        i += 1
    joined = "\n".join(quote)
    return i - start, (f"<blockquote>{joined}</blockquote>" if mode == "html" else joined)


def _render_list(lines: list, start: int, mode: str) -> tuple:
    items = []
    i = start
    while i < len(lines) and _LIST_RE.match(lines[i]):
        m = _LIST_RE.match(lines[i])
        indent, marker, content = m.group(1), m.group(2), m.group(3)
        prefix = "  " * min(len(indent) // 2, 3)
        if marker in ("-", "*", "+"):
            items.append(f"{prefix}• {_render_inline(content, mode)}")
        else:
            items.append(f"{prefix}{marker.rstrip('.)')}. {_render_inline(content, mode)}")
        i += 1
    return i - start, "\n".join(items)


def _flush_paragraph(blocks, paragraph):
    if paragraph:
        blocks.append("\n".join(paragraph))
        paragraph.clear()


# --- tables ---


def _split_row(line: str) -> list:
    stripped = line.strip()
    if stripped.startswith("|"):
        stripped = stripped[1:]
    if stripped.endswith("|"):
        stripped = stripped[:-1]
    return [c.replace("\x02", "|").strip() for c in stripped.replace("\\|", "\x02").split("|")]


def _is_delimiter_row(line: str) -> bool:
    if "|" not in line or "-" not in line:
        return False
    cells = _split_row(line)
    return bool(cells) and all(_DELIM_CELL_RE.fullmatch(c) for c in cells)


def _collect_table(lines: list, start: int):
    header = _split_row(lines[start])
    rows = []
    i = start + 2
    while i < len(lines) and "|" in lines[i] and lines[i].strip() != "":
        rows.append(_split_row(lines[i]))
        i += 1
    return header, rows, i - start


def _normalize_row(cells: list, width: int) -> list:
    if len(cells) > width:
        # Ragged-long rows keep their data by folding extras into the last cell.
        cells = cells[:width - 1] + [" · ".join(cells[width - 1:])]
    while len(cells) < width:
        cells.append("—")
    return [c if c != "" else "—" for c in cells]


def _table_cards(header: list, rows: list, mode: str) -> str:
    width = len(header)
    if width == 0:
        return ""
    if width > _MAX_TABLE_COLS:
        return f"（表格过宽，已省略：{width} 列 × {len(rows)} 行）"
    if not rows:
        # F3: a header-only table still carries its column data.
        names = [_render_inline(h, mode) for h in header]
        if mode == "html":
            names = [f"<b>{n}</b>" for n in names]
        return " · ".join(names)
    cards = []
    for cells in rows:
        cells = _normalize_row(cells, width)
        pairs = [f"<b>{_render_inline(h, mode)}</b>: {_render_inline(c, mode)}"
                 if mode == "html" else f"{_render_inline(h, mode)}: {_render_inline(c, mode)}"
                 for h, c in zip(header, cells)]
        if width == 1:
            cards.append("• " + pairs[0])
        elif width == 2:
            cards.append(" · ".join(pairs))
        else:
            cards.append("\n".join("• " + p for p in pairs))
    return "\n\n".join(cards)


# --- notification assembly ---


def _text(value) -> str:
    return value if isinstance(value, str) else ""


def _clamp(text: str, limit: int) -> str:
    """UTF-16-clamps a header/footer component before escaping (FR-1), so a
    huge event title/name cannot push the rendered message past 4096 units or
    leave a dangling entity."""
    if utf16_len(text) <= limit:
        return text
    return truncate_utf16(text, max(1, limit - 1)) + "…"


class _StaticResolver:
    """No-query resolver: uses only what the event itself carries."""

    def agent_display(self, actor_type, actor_id):
        if actor_id and not _looks_like_uuid(actor_id):
            return actor_id
        return {"agent": "Agent", "member": "Member", "user": "User"}.get(actor_type, "Unknown")

    def issue_ref(self, issue_id, item_title):
        if not item_title:
            return ("", "")
        m = _IDENTIFIER_RE.match(item_title)
        if m:
            # F4: an identifier-only title ("SEE-100") must not repeat as both
            # identifier and title.
            return m.group(1), m.group(2).strip()
        return ("", item_title)

    def comment_link(self, identifier, comment_id):
        return ""


def _comment_id(item: dict) -> str:
    """The comment uuid from the live wire shape (item.details.comment_id,
    captured read-only 2026-11-13); "" when absent or not a string. It is
    validated against the canonical-UUID form before it can reach a URL."""
    details = item.get("details")
    if not isinstance(details, dict):
        return ""
    value = details.get("comment_id")
    return value if isinstance(value, str) else ""


def _deep_link(item: dict, resolver, identifier: str) -> str:
    # Duck-typed resolvers without the deep-link surface (older stubs) keep
    # the current unlinked header; the static resolver defines comment_link
    # as a constant "" so both production resolvers carry the full surface.
    getter = getattr(resolver, "comment_link", None)
    if getter is None:
        return ""
    return getter(identifier, _comment_id(item))


def _compose_header(item: dict, resolver) -> tuple:
    actor_type, actor_id = _text(item.get("actor_type")), _text(item.get("actor_id"))
    icon = _ACTOR_ICONS.get(actor_type, _DEFAULT_ICON)
    parts_html, parts_plain = [], []
    agent = _clamp(resolver.agent_display(actor_type, actor_id), _MAX_AGENT_UNITS)
    if agent:
        parts_html.append(f"{icon} <b>{escape_html(agent)}</b>")
        parts_plain.append(f"{icon} {agent}")
    identifier, title = resolver.issue_ref(_text(item.get("issue_id")), _text(item.get("title")))
    # The link is composed from the RAW identifier: comment_link re-validates
    # the SEE shape, so a clamped or odd-shaped identifier can never enter
    # the URL.
    link = _deep_link(item, resolver, identifier)
    identifier = _clamp(identifier, _MAX_IDENTIFIER_UNITS)
    title = _clamp(title, _MAX_TITLE_UNITS)
    if identifier and title:
        parts_html.append(f"<b>{escape_html(identifier)}</b> {escape_html(title)}")
        parts_plain.append(f"{identifier} {title}")
    elif identifier:
        parts_html.append(f"<b>{escape_html(identifier)}</b>")
        parts_plain.append(identifier)
    elif title:
        parts_html.append(escape_html(title))
        parts_plain.append(title)
    line_html = " · ".join(parts_html)
    if link and line_html:
        line_html = f'<a href="{escape_html(link)}">{line_html}</a>'
    return line_html, " · ".join(parts_plain)


def _compose_footer(item: dict) -> tuple:
    created = _clamp(_text(item.get("created_at")), _MAX_CREATED_UNITS)
    kind = _clamp(_text(item.get("type")) or "inbox", _MAX_KIND_UNITS)
    html_parts, plain_parts = [], []
    if created:
        html_parts.append(f"🕐 {escape_html(created)}")
        plain_parts.append(f"🕐 {created}")
    html_parts.append(escape_html(kind))
    plain_parts.append(kind)
    return " · ".join(html_parts), " · ".join(plain_parts)


def _collapse_blank_runs(text: str) -> str:
    return re.sub(r"\n{3,}", "\n\n", text).strip("\n")


def fit_html_text(body_md: str, header: str = "", footer: str = "",
                  limit: int = MAX_TEXT_LENGTH) -> str:
    """Renders body_md to HTML and, when the result exceeds Telegram's 4096
    UTF-16 budget, shrinks the SOURCE and re-renders, so tags and entities are
    never cut mid-token. Degrades deterministically to tag-free escaped text."""
    # Header/footer are clamped component-wise upstream (see the _MAX_*_UNITS
    # constants), so `fixed` has a deterministic bound well below `limit`.
    fixed = utf16_len(header) + utf16_len(footer)
    out = header + _render_blocks(body_md, "html") + footer
    if utf16_len(out) <= limit:
        # Final pass drops lone surrogates even when under the limit.
        return truncate_utf16(out, limit)
    size = max(utf16_len(body_md), 2)
    for _ in range(6):
        body_md = truncate_utf16(body_md, max(1, size - 1))
        out = header + _render_blocks(body_md, "html") + footer
        if utf16_len(out) <= limit:
            return truncate_utf16(out, limit)
        size //= 2
    # Last resort: escaped text can grow ×5 (& → &amp;), so budget the raw
    # cut by that factor to keep the final string inside the limit.
    budget = max(1, (limit - fixed - utf16_len("\n")) // 5)
    return header + escape_html(truncate_utf16(body_md, budget)) + footer


def render_notification(item: dict, resolver=None) -> Notification:
    # F5: control chars are stripped from every string field before they can
    # reach the renderer, the resolver or the header labels.
    item = {k: _sanitize(v) if isinstance(v, str) else v for k, v in item.items()}
    resolver = resolver if resolver is not None else _StaticResolver()
    header_html, header_plain = _compose_header(item, resolver)
    footer_html, footer_plain = _compose_footer(item)
    body_md = _text(item.get("body"))
    head_html = f"{header_html}\n{SEPARATOR}\n" if header_html else ""
    head_plain = f"{header_plain}\n{SEPARATOR}\n" if header_plain else ""
    html = _collapse_blank_runs(fit_html_text(
        body_md, header=head_html, footer=f"\n\n{footer_html}" if footer_html else ""))
    plain_sections = [s for s in (head_plain, _render_blocks(body_md, "plain")) if s]
    plain = "\n".join(plain_sections)
    if footer_plain:
        plain = f"{plain}\n\n{footer_plain}" if plain else footer_plain
    return Notification(html=html, plain=plain)


def markdown_to_html(md: str) -> str:
    return _render_blocks(md, "html")
