# /// script
# requires-python = ">=3.11"
# dependencies = ["trafilatura>=1.6"]
# ///

import json
import sys
from pathlib import Path

import trafilatura


def main():
    if len(sys.argv) < 3:
        print("Usage: main.py <html_file> <output_dir>", file=sys.stderr)
        sys.exit(1)

    html_file = Path(sys.argv[1])
    output_dir = Path(sys.argv[2])

    html = html_file.read_text(encoding="utf-8", errors="replace")

    text = trafilatura.extract(
        html,
        output_format="txt",
        include_comments=False,
        include_tables=True,
    )

    if text is None:
        print("Could not extract article content", file=sys.stderr)
        sys.exit(1)

    meta = trafilatura.bare_extraction(html)

    output_dir.mkdir(parents=True, exist_ok=True)
    (output_dir / "content.md").write_text(text, encoding="utf-8")

    result = {}
    if meta:
        if getattr(meta, "title", None):
            result["title"] = meta.title
        if getattr(meta, "author", None):
            result["author"] = meta.author
        if getattr(meta, "date", None):
            result["date"] = meta.date
        if getattr(meta, "sitename", None):
            result["sitename"] = meta.sitename

    print(json.dumps(result))


if __name__ == "__main__":
    main()
