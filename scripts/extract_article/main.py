# /// script
# requires-python = ">=3.11"
# dependencies = ["readability-lxml>=0.8", "markdownify>=0.11", "trafilatura>=1.6", "lxml>=5.0"]
# ///

import json
import re
import sys
from pathlib import Path

from lxml import html as lxml_html
from markdownify import markdownify as html_to_md
from readability import Document
from trafilatura.metadata import extract_metadata


# Collapse [![alt](src)](href) to ![alt](src) when href == src — Readability
# often preserves the <a> wrapper around article images even though it adds
# nothing meaningful for a linked-to-self image.
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


def main() -> None:
    if len(sys.argv) < 3:
        print("Usage: main.py <html_file> <output_dir>", file=sys.stderr)
        sys.exit(1)

    html_file = Path(sys.argv[1])
    output_dir = Path(sys.argv[2])

    html = html_file.read_text(encoding="utf-8", errors="replace")

    doc = Document(html)
    content_html = doc.summary(html_partial=True)
    # Readability returns a non-empty wrapper element even for empty pages;
    # check the actual text content rather than just emptiness of the string.
    has_content = False
    if content_html and content_html.strip():
        try:
            frag = lxml_html.fragment_fromstring(content_html, create_parent=True)
            has_content = bool(frag.text_content().strip()) or frag.find(".//img") is not None
        except Exception:
            has_content = False
    if not has_content:
        print("Could not extract article content", file=sys.stderr)
        sys.exit(1)

    text = html_to_md(content_html, heading_style="ATX")
    text = _unwrap_self_linked_images(text)
    # Strip excess blank runs markdownify sometimes produces.
    text = re.sub(r"\n{3,}", "\n\n", text).strip() + "\n"

    output_dir.mkdir(parents=True, exist_ok=True)
    (output_dir / "content.md").write_text(text, encoding="utf-8")

    # Metadata: Readability gives us a good title; trafilatura handles the rest.
    tree = lxml_html.fromstring(html)
    meta = extract_metadata(tree)

    result: dict = {}
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
