"""Item commands: add, list, show, delete, cancel, retry, follow, open, and enhanced reprocess with stage picker."""

import sys
import webbrowser

import click

from cham_cli.config import load_config, get_server_url, get_api_key
from cham_cli.client import ChamClient
from cham_cli.output import format_item_table, format_item_detail, run_follow_display


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
@click.option("--follow", "do_follow", is_flag=True, help="Follow live progress after submit")
@click.option("--json", "use_json", is_flag=True, help="Output as JSON")
def add(url: str, tags: str, do_follow: bool, use_json: bool):
    """Submit a URL for archiving."""
    client = _make_client()
    tag_list = [t.strip() for t in tags.split(",") if t.strip()] if tags else []
    result = client.submit_item(url, tag_list)
    item_data = result.get("data", result) if isinstance(result, dict) else result

    if do_follow:
        item_id = item_data.get("id")
        if item_id:
            run_follow_display(client, item_id, use_json=use_json)
        else:
            format_item_detail(item_data, use_json=use_json)
    else:
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
@click.option("--keep-files", is_flag=True, help="Keep archive files on disk")
@click.option("--yes", "-y", is_flag=True, help="Skip confirmation prompt")
@click.option("--json", "use_json", is_flag=True, help="Output as JSON")
def delete(id_or_slug: str, keep_files: bool, yes: bool, use_json: bool):
    """Delete an item and its archive files."""
    client = _make_client()

    # Fetch item details for confirmation prompt
    result = client.get_item(id_or_slug)
    item_data = result.get("data", result) if isinstance(result, dict) else result
    display_name = item_data.get("title") or item_data.get("url", id_or_slug)

    if not yes:
        if not sys.stdout.isatty():
            print("Error: --yes flag required for non-interactive delete", file=sys.stderr)
            sys.exit(2)
        msg = f"Delete '{display_name}'?"
        if not keep_files:
            msg += " Files will also be deleted."
        if not click.confirm(msg):
            print("Cancelled.")
            return

    client.delete_item(id_or_slug, keep_files=keep_files)

    if use_json:
        from cham_cli.output import print_json
        print_json({"deleted": True, "id": item_data.get("id")})
    else:
        print(f"Deleted: {display_name}")


@item.command()
@click.argument("id_or_slug")
@click.option("--json", "use_json", is_flag=True, help="Output as JSON")
def cancel(id_or_slug: str, use_json: bool):
    """Cancel an in-progress item."""
    client = _make_client()
    result = client.cancel_item(id_or_slug)
    item_data = result.get("data", result) if isinstance(result, dict) else result
    format_item_detail(item_data, use_json=use_json)


@item.command()
@click.argument("id_or_slug", required=False)
@click.option("--from-stage", default=None, help="Invalidate and retry from a specific stage")
@click.option("--all", "retry_all", is_flag=True, help="Retry all failed/incomplete items")
@click.option("--follow", "do_follow", is_flag=True, help="Follow live progress after retry")
@click.option("--json", "use_json", is_flag=True, help="Output as JSON")
def retry(id_or_slug: str, from_stage: str, retry_all: bool, do_follow: bool, use_json: bool):
    """Retry a failed or incomplete item."""
    client = _make_client()

    if retry_all:
        failed_items = client.list_items(status="failed")
        incomplete_items = client.list_items(status="incomplete")
        all_items = failed_items + incomplete_items

        if not all_items:
            print("No failed or incomplete items to retry.")
            return

        for item_data in all_items:
            item_id = item_data["id"]
            display = item_data.get("title") or item_data.get("url", item_id[:8])
            client.retry_item(item_id, from_stage=from_stage)
            print(f"Retrying: {display}")

        if use_json:
            from cham_cli.output import print_json
            print_json({"retried": len(all_items)})
        return

    if not id_or_slug:
        print("Error: provide an item ID/slug, or use --all", file=sys.stderr)
        sys.exit(2)

    result = client.retry_item(id_or_slug, from_stage=from_stage)
    item_data = result.get("data", result) if isinstance(result, dict) else result

    if do_follow:
        item_id = item_data.get("id")
        if item_id:
            run_follow_display(client, item_id, use_json=use_json)
        else:
            format_item_detail(item_data, use_json=use_json)
    else:
        format_item_detail(item_data, use_json=use_json)


@item.command()
@click.argument("id_or_slug")
@click.option("--json", "use_json", is_flag=True, help="Output as JSON")
def follow(id_or_slug: str, use_json: bool):
    """Follow live pipeline progress for an item."""
    client = _make_client()

    # Check if item exists and get current status
    result = client.get_item(id_or_slug)
    item_data = result.get("data", result) if isinstance(result, dict) else result
    status = item_data.get("status", "")

    if status in ("complete", "incomplete", "failed", "cancelled"):
        display = item_data.get("title") or item_data.get("url", id_or_slug)
        from cham_cli.output import is_tty
        if use_json or not is_tty():
            from cham_cli.output import print_json
            print_json({"status": status, "message": "item already terminal"})
        else:
            from rich.console import Console
            Console().print(f"'{display}' is already {status}.")
        return

    run_follow_display(client, item_data.get("id", id_or_slug), use_json=use_json)


@item.command()
@click.argument("id_or_slug")
def open(id_or_slug: str):
    """Open the item's original URL in the default browser."""
    client = _make_client()
    result = client.get_item(id_or_slug)
    item_data = result.get("data", result) if isinstance(result, dict) else result
    url = item_data.get("url")

    if not url:
        print("Error: item has no URL", file=sys.stderr)
        sys.exit(1)

    print(url)
    webbrowser.open(url)


@item.command()
@click.argument("id_or_slug")
@click.option("--retry-failed", is_flag=True, help="Also retry previously failed stages")
@click.option("--invalidate", "-i", multiple=True, help="Stage plugin_id to invalidate and re-run")
@click.option("--follow", "do_follow", is_flag=True, help="Follow live progress after reprocess")
@click.option("--json", "use_json", is_flag=True, help="Output as JSON")
def reprocess(id_or_slug: str, retry_failed: bool, invalidate: tuple, do_follow: bool, use_json: bool):
    """Reprocess an item, running any new or missing stages."""
    client = _make_client()

    invalidate_list = list(invalidate) if invalidate else None

    # Interactive stage picker when no --invalidate provided and in TTY mode
    if not invalidate_list and sys.stdout.isatty() and not use_json:
        result = client.get_item(id_or_slug)
        item_data = result.get("data", result) if isinstance(result, dict) else result
        executions = item_data.get("stage_executions", [])

        completed_stages = [
            e for e in executions if e.get("status") == "completed"
        ]

        if completed_stages:
            from InquirerPy import inquirer

            choices = [
                {"name": f"{e['stage']} ({e['status']})", "value": e["stage"]}
                for e in completed_stages
            ]

            selected = inquirer.checkbox(
                message="Select stages to invalidate and re-run:",
                choices=choices,
            ).execute()

            if selected:
                invalidate_list = selected

    result = client.reprocess_item(
        id_or_slug,
        retry_failed=retry_failed,
        invalidate=invalidate_list,
    )
    item_data = result.get("data", result) if isinstance(result, dict) else result

    if do_follow:
        item_id = item_data.get("id")
        if item_id:
            run_follow_display(client, item_id, use_json=use_json)
        else:
            format_item_detail(item_data, use_json=use_json)
    else:
        format_item_detail(item_data, use_json=use_json)
