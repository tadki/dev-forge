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
        if line.startswith(_FENCE_SENTINEL) and line.endswith(_FENCE_SENTINEL):
            _flush_paragraph(blocks, paragraph)
            blocks.append(line.strip(_FENCE_SENTINEL))
            i += 1
            continue
        if "|" in line and i + 1 < len(lines) and _is_delimiter_row(lines[i + 1]):
            header, rows, consumed = _collect_table(lines, i)
            _flush_paragraph(blocks, paragraph)
            blocks.append(_table_cards(header, rows, mode))
            i += consumed
            continue
        if _HR_RE.match(line):
            _flush_paragraph(blocks, paragraph)
            blocks.append(SEPARATOR)
            i += 1
            continue
        heading = _HEADING_RE.match(line)
        if heading:
            _flush_paragraph(blocks, paragraph)
            inner = _render_inline(heading.group(1), mode)
            blocks.append(f"<b>{inner}</b>" if mode == "html" else inner)
            i += 1
            continue
        if _QUOTE_RE.match(line):
            _flush_paragraph(blocks, paragraph)
            quote = []
            while i < len(lines):
                m = _QUOTE_RE.match(lines[i])
                if not m:
                    break
                quote.append(_render_inline(m.group(1), mode))
                i += 1
            joined = "\n".join(quote)
            blocks.append(f"<blockquote>{joined}</blockquote>" if mode == "html" else joined)
            continue
        if _LIST_RE.match(line):
            _flush_paragraph(blocks, paragraph)
            items = []
            while i < len(lines) and _LIST_RE.match(lines[i]):
                m = _LIST_RE.match(lines[i])
                indent, marker, content = m.group(1), m.group(2), m.group(3)
                prefix = "  " * min(len(indent) // 2, 3)
                if marker in ("-", "*", "+"):
                    items.append(f"{prefix}• {_render_inline(content, mode)}")
                else:
                    items.append(f"{prefix}{marker.rstrip('.)')}. {_render_inline(content, mode)}")
                i += 1
            blocks.append("\n".join(items))
            continue
        paragraph.append(_render_inline(line, mode))
        i += 1
    _flush_paragraph(blocks, paragraph)
    return "\n\n".join(b for b in blocks if b)


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


def _compose_header(item: dict, resolver) -> tuple:
    actor_type, actor_id = _text(item.get("actor_type")), _text(item.get("actor_id"))
    icon = _ACTOR_ICONS.get(actor_type, _DEFAULT_ICON)
    parts_html, parts_plain = [], []
    agent = resolver.agent_display(actor_type, actor_id)
    if agent:
        parts_html.append(f"{icon} <b>{escape_html(agent)}</b>")
        parts_plain.append(f"{icon} {agent}")
    identifier, title = resolver.issue_ref(_text(item.get("issue_id")), _text(item.get("title")))
    if identifier and title:
        parts_html.append(f"<b>{escape_html(identifier)}</b> {escape_html(title)}")
        parts_plain.append(f"{identifier} {title}")
    elif identifier:
        parts_html.append(f"<b>{escape_html(identifier)}</b>")
        parts_plain.append(identifier)
    elif title:
        parts_html.append(escape_html(title))
        parts_plain.append(title)
    return " · ".join(parts_html), " · ".join(parts_plain)


def _compose_footer(item: dict) -> tuple:
    parts = []
    created = _text(item.get("created_at"))
    if created:
        parts.append(f"🕐 {created}")
    parts.append(_text(item.get("type")) or "inbox")
    return " · ".join(parts), " · ".join(parts)


def _collapse_blank_runs(text: str) -> str:
    return re.sub(r"\n{3,}", "\n\n", text).strip("\n")


def fit_html_text(body_md: str, header: str = "", footer: str = "",
                  limit: int = MAX_TEXT_LENGTH) -> str:
    """Renders body_md to HTML and, when the result exceeds Telegram's 4096
    UTF-16 budget, shrinks the SOURCE and re-renders, so tags and entities are
    never cut mid-token. Degrades deterministically to tag-free escaped text."""
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
    budget = max(1, limit - fixed - utf16_len("\n"))
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
