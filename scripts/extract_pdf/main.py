# /// script
# requires-python = ">=3.11"
# dependencies = ["pypdf>=4.0", "cryptography>=3.1"]
# ///

import json
import sys
from pathlib import Path

from pypdf import PdfReader


def main():
    if len(sys.argv) < 3:
        print("Usage: main.py <pdf_file> <output_dir>", file=sys.stderr)
        sys.exit(1)

    pdf_file = Path(sys.argv[1])
    output_dir = Path(sys.argv[2])

    reader = PdfReader(str(pdf_file))

    # Extract text from all pages
    pages = []
    for i, page in enumerate(reader.pages):
        text = page.extract_text()
        if text and text.strip():
            pages.append(text)

    if not pages:
        print("Could not extract any text from PDF", file=sys.stderr)
        sys.exit(1)

    content = "\n\n---\n\n".join(pages)

    output_dir.mkdir(parents=True, exist_ok=True)
    (output_dir / "content.md").write_text(content, encoding="utf-8")

    # Extract metadata
    meta = reader.metadata
    result = {"page_count": len(reader.pages)}

    if meta:
        if meta.title:
            result["title"] = meta.title
        if meta.author:
            result["author"] = meta.author
        if meta.subject:
            result["subject"] = meta.subject
        if meta.creator:
            result["creator"] = meta.creator

    print(json.dumps(result))


if __name__ == "__main__":
    main()
