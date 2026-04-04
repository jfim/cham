"""Output formatting helpers for Cham CLI."""

import json
import sys
from typing import Any

from rich.console import Console
from rich.table import Table


STATUS_COLORS = {
    "bootstrapping": "blue",
    "processing": "yellow",
    "complete": "green",
    "incomplete": "dark_orange",
    "failed": "red",
}


def is_tty() -> bool:
    return sys.stdout.isatty()


def print_json(data: Any) -> None:
    """Print data as JSON to stdout."""
    print(json.dumps(data, indent=2, default=str))


def format_item_table(items: list[dict], use_json: bool = False) -> None:
    """Print a table of items."""
    if use_json or not is_tty():
        print_json(items)
        return

    console = Console()

    if not items:
        console.print("[dim]No items found.[/dim]")
        return

    table = Table(show_header=True, header_style="bold")
    table.add_column("ID", style="dim", width=8)
    table.add_column("Status")
    table.add_column("Title / URL", max_width=50)
    table.add_column("Type")
    table.add_column("Tags")
    table.add_column("Date")

    for item in items:
        item_id = str(item.get("id", ""))[:8]
        status = item.get("status", "unknown")
        color = STATUS_COLORS.get(status, "white")
        title = item.get("title") or item.get("url", "—")
        content_type = item.get("content_type", "—")
        tags = ", ".join(item.get("tags", []))
        date = str(item.get("inserted_at", item.get("created_at", "—")))[:10]

        table.add_row(
            item_id,
            f"[{color}]{status}[/{color}]",
            title,
            content_type,
            tags,
            date,
        )

    console.print(table)


def format_item_detail(item: dict, use_json: bool = False) -> None:
    """Print full item detail."""
    if use_json or not is_tty():
        print_json(item)
        return

    console = Console()

    fields = [
        ("ID", str(item.get("id", "—"))),
        ("Slug", item.get("slug", "—")),
        ("Status", _colored_status(item.get("status", "unknown"))),
        ("URL", item.get("url", "—")),
        ("Title", item.get("title", "—")),
        ("Content Type", item.get("content_type", "—")),
        ("Tags", ", ".join(item.get("tags", [])) or "—"),
        ("Created", str(item.get("inserted_at", item.get("created_at", "—")))),
        ("Updated", str(item.get("updated_at", "—"))),
    ]

    max_label = max(len(label) for label, _ in fields)
    for label, value in fields:
        console.print(f"  [bold]{label:<{max_label}}[/bold]  {value}")


def _colored_status(status: str) -> str:
    color = STATUS_COLORS.get(status, "white")
    return f"[{color}]{status}[/{color}]"
