"""Cham CLI — entry point."""

import click

from cham_cli.commands.item import item
from cham_cli.commands.config_cmd import config_group
from cham_cli.commands.tags import tags


@click.group()
@click.version_option(package_name="cham-cli")
def cli():
    """Cham - Knowledge Archive CLI"""
    pass


cli.add_command(item)
cli.add_command(config_group)
cli.add_command(tags)
