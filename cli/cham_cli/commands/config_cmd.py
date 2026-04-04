"""Config commands: init, show."""

import sys

import click
from rich.console import Console

from cham_cli.config import (
    load_config,
    save_config,
    get_server_url,
    get_api_key,
    redact_api_key,
    DEFAULTS,
    CONFIG_FILE,
)
from cham_cli.client import ChamClient


@click.group("config")
def config_group():
    """Manage CLI configuration."""
    pass


@config_group.command()
def init():
    """Interactive setup — configure server URL and API key."""
    console = Console()
    config = load_config()

    current_url = config["server"]["url"]
    url = click.prompt("Server URL", default=current_url)

    current_key = config["server"]["api_key"]
    key_prompt = "API key"
    if current_key:
        key_prompt += f" (current: {redact_api_key(current_key)})"
    api_key = click.prompt(key_prompt, default=current_key, show_default=False)

    # Test connection
    console.print("\nTesting connection...", style="dim")
    client = ChamClient(url.rstrip("/"), api_key)
    try:
        client.health()
        console.print("[green]Connected successfully.[/green]")
    except SystemExit:
        # health() calls sys.exit on failure — catch it and ask whether to save anyway
        if not click.confirm("\nConnection failed. Save config anyway?", default=False):
            sys.exit(1)

    config["server"]["url"] = url
    config["server"]["api_key"] = api_key
    save_config(config)
    console.print(f"\nConfig saved to [bold]{CONFIG_FILE}[/bold]")


@config_group.command()
def show():
    """Show current configuration."""
    console = Console()
    config = load_config()

    console.print(f"  [bold]Config file[/bold]  {CONFIG_FILE}")
    console.print(f"  [bold]Server URL [/bold]  {get_server_url(config)}")
    console.print(
        f"  [bold]API key    [/bold]  {redact_api_key(get_api_key(config))}"
    )
