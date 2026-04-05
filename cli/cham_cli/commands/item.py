"""Item commands: add, list, show."""

import click

from cham_cli.config import load_config, get_server_url, get_api_key
from cham_cli.client import ChamClient
from cham_cli.output import format_item_table, format_item_detail


def _make_client() -> ChamClient:
    config = load_config()
    return ChamClient(get_server_url(config), get_api_key(config))


@click.group()
def item():
    """Manage items."""
    pass


@item.command()
@click.argument("url")
@click.option("--tags", default="", help="Comma-separated tags")
@click.option("--json", "use_json", is_flag=True, help="Output as JSON")
def add(url: str, tags: str, use_json: bool):
    """Submit a URL for archiving."""
    client = _make_client()
    tag_list = [t.strip() for t in tags.split(",") if t.strip()] if tags else []
    result = client.submit_item(url, tag_list)
    # The API may wrap the item in a "data" key
    item_data = result.get("data", result) if isinstance(result, dict) else result
    format_item_detail(item_data, use_json=use_json)


@item.command("list")
@click.option("--status", default=None, help="Filter by status")
@click.option("--type", "content_type", default=None, help="Filter by content type")
@click.option("--tag", default=None, help="Filter by tag")
@click.option("--json", "use_json", is_flag=True, help="Output as JSON")
def list_items(status: str, content_type: str, tag: str, use_json: bool):
    """List items."""
    client = _make_client()
    items = client.list_items(status=status, content_type=content_type, tag=tag)
    format_item_table(items, use_json=use_json)


@item.command()
@click.argument("id_or_slug")
@click.option("--json", "use_json", is_flag=True, help="Output as JSON")
def show(id_or_slug: str, use_json: bool):
    """Show item details."""
    client = _make_client()
    result = client.get_item(id_or_slug)
    item_data = result.get("data", result) if isinstance(result, dict) else result
    format_item_detail(item_data, use_json=use_json)


@item.command()
@click.argument("id_or_slug")
@click.option("--retry-failed", is_flag=True, help="Also retry previously failed stages")
@click.option("--invalidate", "-i", multiple=True, help="Stage plugin_id to invalidate and re-run")
@click.option("--json", "use_json", is_flag=True, help="Output as JSON")
def reprocess(id_or_slug: str, retry_failed: bool, invalidate: tuple, use_json: bool):
    """Reprocess an item, running any new or missing stages."""
    client = _make_client()
    result = client.reprocess_item(
        id_or_slug,
        retry_failed=retry_failed,
        invalidate=list(invalidate) if invalidate else None,
    )
    item_data = result.get("data", result) if isinstance(result, dict) else result
    format_item_detail(item_data, use_json=use_json)
