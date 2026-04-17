# /// script
# requires-python = ">=3.11"
# dependencies = ["trafilatura>=1.6", "lxml>=5.0"]
# ///

import json
import sys
from pathlib import Path

import trafilatura
from lxml import html as lxml_html
from trafilatura.metadata import extract_metadata


def main():
    if len(sys.argv) < 3:
        print("Usage: main.py <html_file> <output_dir>", file=sys.stderr)
        sys.exit(1)

    html_file = Path(sys.argv[1])
    output_dir = Path(sys.argv[2])

    html = html_file.read_text(encoding="utf-8", errors="replace")

    text = trafilatura.extract(
        html,
        output_format="markdown",
        include_comments=False,
        include_tables=True,
        include_links=True,
        include_images=True,
    )

    if text is None:
        print("Could not extract article content", file=sys.stderr)
        sys.exit(1)

    # Extract metadata using lxml tree — bare_extraction often returns empty metadata
    tree = lxml_html.fromstring(html)
    meta = extract_metadata(tree)

    output_dir.mkdir(parents=True, exist_ok=True)
    (output_dir / "content.md").write_text(text, encoding="utf-8")

    result = {}
    if meta:
        if meta.title:
            result["title"] = meta.title
        if meta.author:
            result["author"] = meta.author
        if meta.date:
            result["date"] = meta.date
        if meta.sitename:
            result["sitename"] = meta.sitename

    # Cheap listing aids: word count and a single-line excerpt built from the
    # first paragraph(s) of plain prose. Strip markdown-ish link/image syntax
    # and code fences so the excerpt reads naturally at list-row size.
    import re

    stripped = re.sub(r"!\[[^\]]*\]\([^)]*\)", "", text)
    stripped = re.sub(r"\[([^\]]+)\]\([^)]*\)", r"\1", stripped)
    stripped = re.sub(r"`{1,3}[^`]*`{1,3}", "", stripped)
    stripped = re.sub(r"^#+\s*", "", stripped, flags=re.MULTILINE)
    words = re.findall(r"\w+", stripped)
    result["word_count"] = len(words)

    # Excerpt: collapse whitespace, take ~280 chars.
    compact = " ".join(stripped.split())
    if compact:
        result["excerpt"] = compact[:280]

    print(json.dumps(result))


if __name__ == "__main__":
    main()
