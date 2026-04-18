"""Tag commands: bulk clear."""

import sys

import click

from cham_cli.config import load_config, get_server_url, get_api_key
from cham_cli.client import ChamClient


def _make_client() -> ChamClient:
    config = load_config()
    return ChamClient(get_server_url(config), get_api_key(config))


@click.group()
def tags():
    """Manage tags across items."""
    pass


@tags.command()
@click.option("--type", "content_type", default=None, help="Restrict to a content type (e.g. article, video)")
@click.option("--yes", "-y", is_flag=True, help="Skip confirmation prompt")
@click.option("--json", "use_json", is_flag=True, help="Output as JSON")
def clear(content_type: str, yes: bool, use_json: bool):
    """Clear tags on all items (optionally filtered by --type)."""
    client = _make_client()

    scope = f"items with content_type={content_type}" if content_type else "ALL items"

    if not yes:
        if not sys.stdout.isatty():
            print("Error: --yes flag required for non-interactive clear", file=sys.stderr)
            sys.exit(2)
        if not click.confirm(f"Clear tags on {scope}?"):
            print("Cancelled.")
            return

    result = client.clear_tags(content_type=content_type)
    count = result.get("cleared", 0)

    if use_json:
        from cham_cli.output import print_json
        print_json(result)
    else:
        print(f"Cleared tags on {count} item(s).")
