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
from trafilatura import extract
from trafilatura.metadata import extract_metadata


_SELF_LINKED_IMAGE_RE = re.compile(
    r"\[!\[([^\]]*)\]\(([^)]+)\)\]\(([^)]+)\)"
)


def _unwrap_self_linked_images(text: str) -> str:
    def repl(m: re.Match[str]) -> str:
        alt, src, href = m.group(1), m.group(2), m.group(3)
        if src == href:
            return f"![{alt}]({src})"
        return m.group(0)

    return _SELF_LINKED_IMAGE_RE.sub(repl, text)


def _has_content(content_html: str | None) -> bool:
    if not content_html or not content_html.strip():
        return False
    try:
        frag = lxml_html.fragment_fromstring(content_html, create_parent=True)
    except Exception:
        return False
    return bool(frag.text_content().strip()) or frag.find(".//img") is not None


def _repair_html(html: str) -> str:
    return str(BeautifulSoup(html, "html5lib"))


def _extract_trafilatura(html: str) -> str | None:
    """Try trafilatura extraction, returning HTML fragment or None."""
    content_html = extract(
        html,
        output_format="html",
        include_images=True,
        include_links=True,
        include_tables=True,
        favor_recall=True,
    )
    if _has_content(content_html):
        return content_html
    return None


def _extract_readability(html: str) -> str | None:
    """Try readability extraction, with html5lib repair fallback."""
    doc = Document(html)
    content_html = doc.summary(html_partial=True)
    if _has_content(content_html):
        return content_html

    repaired = _repair_html(html)
    doc = Document(repaired)
    content_html = doc.summary(html_partial=True)
    if _has_content(content_html):
        return content_html

    return None


def _html_to_markdown(content_html: str) -> str:
    text = html_to_md(content_html, heading_style="ATX")
    text = _unwrap_self_linked_images(text)
    text = re.sub(r"\n{3,}", "\n\n", text).strip() + "\n"
    return text


def main() -> None:
    if len(sys.argv) < 3:
        print("Usage: main.py <html_file> <output_dir>", file=sys.stderr)
        sys.exit(1)

    html_file = Path(sys.argv[1])
    output_dir = Path(sys.argv[2])

    html = html_file.read_text(encoding="utf-8", errors="replace")

    # Try trafilatura first (better at isolating article content),
    # fall back to readability-lxml if trafilatura returns nothing.
    content_html = _extract_trafilatura(html)
    if content_html is not None:
        tool = "trafilatura"
    else:
        content_html = _extract_readability(html)
        tool = "readability-lxml"

    if content_html is None:
        print("Could not extract article content", file=sys.stderr)
        sys.exit(1)

    text = _html_to_markdown(content_html)

    output_dir.mkdir(parents=True, exist_ok=True)
    (output_dir / "content.md").write_text(text, encoding="utf-8")

    # Metadata: trafilatura handles structured metadata well.
    tree = lxml_html.fromstring(html)
    meta = extract_metadata(tree)

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
