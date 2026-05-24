# /// script
# requires-python = ">=3.11"
# dependencies = [
#   "readability-lxml>=0.8",
#   "markdownify>=0.11",
#   "trafilatura>=1.6",
#   "lxml>=5.0",
#   "html5lib>=1.1",
#   "beautifulsoup4>=4.12",
# ]
# ///

import json
import re
import sys
from pathlib import Path

from bs4 import BeautifulSoup
from lxml import html as lxml_html
from markdownify import markdownify as html_to_md
from readability import Document
from trafilatura import extract as trafilatura_extract
from trafilatura.metadata import extract_metadata


# Collapse [![alt](src)](href) to ![alt](src) when href == src — Readability
# often preserves the <a> wrapper around article images even though it adds
# nothing meaningful for a linked-to-self image.
_SELF_LINKED_IMAGE_RE = re.compile(
    r"\[!\[([^\]]*)\]\(([^)]+)\)\]\(([^)]+)\)"
)


# Strip these tags from the original HTML tree before running the slice
# ancestor walk — keeps nav/footer/etc. from pulling the LCA above the article.
_NOISE_TAGS = frozenset((
    "script", "style", "nav", "aside", "footer", "header",
    "form", "button", "noscript", "iframe", "svg",
))


_WS_RE = re.compile(r"\s+")


def _normalize_ws(s: str) -> str:
    # Collapse all whitespace (including U+00A0 nbsp) to single spaces so
    # paragraph matching survives whitespace differences between trafilatura's
    # text output and the original HTML.
    return _WS_RE.sub(" ", s.replace(" ", " ")).strip()


def _unwrap_self_linked_images(text: str) -> str:
    def repl(m: re.Match[str]) -> str:
        alt, src, href = m.group(1), m.group(2), m.group(3)
        if src == href:
            return f"![{alt}]({src})"
        return m.group(0)

    return _SELF_LINKED_IMAGE_RE.sub(repl, text)


def _has_content(content_html: str | None) -> bool:
    # Readability returns a non-empty wrapper element even for empty pages;
    # check the actual text content rather than just emptiness of the string.
    if not content_html or not content_html.strip():
        return False
    try:
        frag = lxml_html.fragment_fromstring(content_html, create_parent=True)
    except Exception:
        return False
    return bool(frag.text_content().strip()) or frag.find(".//img") is not None


def _repair_html(html: str) -> str:
    # html5lib matches browser parsing and recovers misplaced elements (e.g.
    # pages that close </html> before <body>, or stray tags inside IE
    # conditional comments). Re-serializing yields well-formed HTML that
    # libxml2 — and therefore readability-lxml — can parse in full.
    return str(BeautifulSoup(html, "html5lib"))


def _word_count(html_str: str) -> int:
    try:
        frag = lxml_html.fragment_fromstring(html_str, create_parent=True)
        return len(re.findall(r"\w+", frag.text_content() or ""))
    except Exception:
        return 0


def _extract_readability(html: str) -> str | None:
    """Readability with html5lib repair fallback."""
    doc = Document(html)
    content_html = doc.summary(html_partial=True)
    if _has_content(content_html):
        return content_html

    # Readability-lxml's underlying parser drops <body> on pages with malformed
    # markup. Repair via html5lib and retry.
    repaired = _repair_html(html)
    doc = Document(repaired)
    content_html = doc.summary(html_partial=True)
    return content_html if _has_content(content_html) else None


def _extract_slice(html: str) -> str | None:
    """Use trafilatura's text extraction to LOCATE the article inside the
    original HTML tree, then return that subtree HTML. Preserves original
    inline tags (<code>, <em>, <kbd>, etc.) that trafilatura's own HTML
    output normalizes away into <pre>/<blockquote>.
    """
    text = trafilatura_extract(html, output_format="txt", favor_recall=True)
    if not text:
        return None

    # Substantial paragraphs as locator probes. Try a strict threshold first,
    # then back off for short articles.
    all_lines = [_normalize_ws(p) for p in text.split("\n") if p.strip()]
    needles = [n for n in all_lines if len(n) >= 60]
    if len(needles) < 5:
        needles = [n for n in all_lines if len(n) >= 30]
    if len(needles) < 3:
        needles = [n for n in all_lines if len(n) >= 15]
    if not needles:
        return None

    # Evenly distribute up to 60 needles across the article so the LCA spans
    # the whole body, not just the opening section.
    cap = 60
    if len(needles) > cap:
        step = len(needles) / cap
        needles = [needles[int(i * step)] for i in range(cap)]

    try:
        # lxml rejects str input that has an XML encoding declaration; pass bytes.
        tree = lxml_html.fromstring(html.encode("utf-8", errors="replace"))
    except Exception:
        return None

    # Strip noise so the LCA walk isn't pulled up by nav/footer/etc.
    for tag in _NOISE_TAGS:
        for el in tree.iter(tag):
            parent = el.getparent()
            if parent is not None:
                parent.remove(el)

    # For each needle, find the tightest element whose normalized text content
    # contains it.
    matched = []
    for needle in needles:
        prefix = needle[:80]
        best = None
        best_len = None
        for el in tree.iter():
            if not isinstance(el.tag, str):
                continue
            try:
                txt = _normalize_ws(el.text_content() or "")
            except Exception:
                continue
            if prefix in txt:
                tlen = len(txt)
                if best is None or tlen < best_len:
                    best, best_len = el, tlen
        if best is not None:
            matched.append(best)

    if not matched:
        return None

    # Lowest common ancestor: intersection of each matched element's ancestor
    # chain, picking the deepest member.
    ancestor_sets = []
    for el in matched:
        chain = set()
        cur = el
        while cur is not None:
            chain.add(cur)
            cur = cur.getparent()
        ancestor_sets.append(chain)
    common = set.intersection(*ancestor_sets)
    if not common:
        return None
    lca = max(common, key=lambda a: len(list(a.iterancestors())))

    html_str = lxml_html.tostring(lca, encoding="unicode")
    return html_str if _has_content(html_str) else None


def _html_to_markdown(content_html: str) -> str:
    text = html_to_md(content_html, heading_style="ATX")
    text = _unwrap_self_linked_images(text)
    # Strip excess blank runs markdownify sometimes produces.
    return re.sub(r"\n{3,}", "\n\n", text).strip() + "\n"


def main() -> None:
    if len(sys.argv) < 3:
        print("Usage: main.py <html_file> <output_dir>", file=sys.stderr)
        sys.exit(1)

    html_file = Path(sys.argv[1])
    output_dir = Path(sys.argv[2])
    html = html_file.read_text(encoding="utf-8", errors="replace")

    # Run both extractors and pick whichever produces more words. Slice usually
    # wins on formatting fidelity (preserves original inline tags), but
    # readability acts as a safety net for pages where slice's paragraph
    # matching falls short.
    slice_html = _extract_slice(html)
    readability_html = _extract_readability(html)

    if slice_html and (
        not readability_html or _word_count(slice_html) >= _word_count(readability_html)
    ):
        content_html, tool = slice_html, "trafilatura-slice"
    elif readability_html:
        content_html, tool = readability_html, "readability-lxml"
    else:
        print("Could not extract article content", file=sys.stderr)
        sys.exit(1)

    text = _html_to_markdown(content_html)

    output_dir.mkdir(parents=True, exist_ok=True)
    (output_dir / "content.md").write_text(text, encoding="utf-8")

    # Metadata: trafilatura handles structured metadata well; fall back to
    # readability's title.
    try:
        tree = lxml_html.fromstring(html.encode("utf-8", errors="replace"))
    except Exception:
        tree = None
    meta = extract_metadata(tree) if tree is not None else None

    result: dict = {"extractor": tool}
    doc = Document(html)
    readability_title = (doc.title() or "").strip()
    meta_title = (meta.title if meta and meta.title else "").strip()
    title = meta_title or readability_title
    if title and title.lower() not in ("[no-title]", "no title"):
        result["title"] = title
    if meta:
        if meta.author:
            result["author"] = meta.author
        if meta.date:
            result["date"] = meta.date
        if meta.sitename:
            result["sitename"] = meta.sitename

    # Cheap listing aids: word count + single-line excerpt.
    stripped = re.sub(r"!\[[^\]]*\]\([^)]*\)", "", text)
    stripped = re.sub(r"\[([^\]]+)\]\([^)]*\)", r"\1", stripped)
    stripped = re.sub(r"`{1,3}[^`]*`{1,3}", "", stripped)
    stripped = re.sub(r"^#+\s*", "", stripped, flags=re.MULTILINE)
    words = re.findall(r"\w+", stripped)
    result["word_count"] = len(words)

    compact = " ".join(stripped.split())
    if compact:
        result["excerpt"] = compact[:280]

    print(json.dumps(result))


if __name__ == "__main__":
    main()
