# /// script
# requires-python = ">=3.11"
# dependencies = ["httpx>=0.27"]
# ///

import hashlib
import json
import mimetypes
import re
import sys
from pathlib import Path
from urllib.parse import urljoin, urlparse

import httpx

MAX_BYTES = 10_000_000
CONNECT_TIMEOUT = 10.0
READ_TIMEOUT = 30.0
IMAGE_RE = re.compile(r"!\[([^\]]*)\]\(([^)\s]+)(?:\s+\"[^\"]*\")?\)")


def extension_for(url_key: str, content_type: str | None) -> str:
    path = urlparse(url_key).path
    if "." in path.rsplit("/", 1)[-1]:
        ext = "." + path.rsplit(".", 1)[-1].lower()
        if 1 < len(ext) <= 6:
            return ext
    if content_type:
        ct = content_type.split(";", 1)[0].strip().lower()
        guessed = mimetypes.guess_extension(ct) or ""
        if guessed:
            return guessed
    return ".bin"


def local_filename(url_key: str, content_type: str | None) -> str:
    digest = hashlib.md5(url_key.encode("utf-8")).hexdigest()
    return f"img_{digest}{extension_for(url_key, content_type)}"


def download(client: httpx.Client, fetch_url: str, dest: Path) -> tuple[bool, str | None, str | None]:
    try:
        with client.stream("GET", fetch_url) as resp:
            if resp.status_code >= 400:
                return False, f"http {resp.status_code}", None
            content_type = resp.headers.get("content-type")
            total = 0
            with dest.open("wb") as f:
                for chunk in resp.iter_bytes():
                    total += len(chunk)
                    if total > MAX_BYTES:
                        return False, "too large", content_type
                    f.write(chunk)
        return True, None, content_type
    except httpx.HTTPError as e:
        return False, f"http error: {e}", None


def main() -> None:
    if len(sys.argv) < 5:
        print("Usage: main.py <input_md> <output_dir> <base_url> <item_id>", file=sys.stderr)
        sys.exit(1)

    input_md = Path(sys.argv[1])
    output_dir = Path(sys.argv[2])
    base_url = sys.argv[3]
    item_id = sys.argv[4]

    output_dir.mkdir(parents=True, exist_ok=True)
    text = input_md.read_text(encoding="utf-8")

    seen: dict[str, str | None] = {}
    summary: dict = {"succeeded": 0, "failed": 0, "skipped_duplicate": 0, "failures": []}

    timeout = httpx.Timeout(READ_TIMEOUT, connect=CONNECT_TIMEOUT)
    with httpx.Client(timeout=timeout, follow_redirects=True) as client:

        def replace(match: re.Match[str]) -> str:
            alt, url_key = match.group(1), match.group(2)
            if url_key in seen:
                local = seen[url_key]
                if local is not None:
                    summary["skipped_duplicate"] += 1
                    return f"![{alt}](/api/v1/items/{item_id}/files/{local})"
                return match.group(0)

            fetch_url = urljoin(base_url, url_key)
            tentative = local_filename(url_key, None)
            dest = output_dir / tentative

            ok, reason, content_type = download(client, fetch_url, dest)
            if not ok:
                dest.unlink(missing_ok=True)
                seen[url_key] = None
                summary["failed"] += 1
                summary["failures"].append({"url": url_key, "reason": reason or "unknown"})
                return match.group(0)

            final_name = local_filename(url_key, content_type)
            if final_name != tentative:
                final_dest = output_dir / final_name
                dest.rename(final_dest)

            seen[url_key] = final_name
            summary["succeeded"] += 1
            return f"![{alt}](/api/v1/items/{item_id}/files/{final_name})"

        rewritten = IMAGE_RE.sub(replace, text)

    (output_dir / "content.md").write_text(rewritten, encoding="utf-8")
    print(json.dumps(summary))


if __name__ == "__main__":
    main()
