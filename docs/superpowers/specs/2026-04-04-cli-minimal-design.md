# CLI (Minimal) — Design Spec

## Goal

Add a minimal CLI for interacting with Cham from the terminal. Thin Python client over the REST API.

## Scope

Minimal subset of the full CLI design (`design-docs/cli.md`). Basic item management and config only. No follow, search, reprocess, retry, cancel, tags, archive, open.

## Commands

```
cham item add <url> [--tags t1,t2]
cham item list [--status STATUS] [--type TYPE] [--tag TAG]
cham item show <id-or-slug>
cham config init
cham config show
```

### `cham item add <url>`

Submit a URL for archiving. Prints the created item summary.

Options:
- `--tags t1,t2` — comma-separated tags

### `cham item list`

List items. Defaults to showing all items.

Options:
- `--status STATUS` — filter by status (bootstrapping, processing, complete, incomplete, failed)
- `--type TYPE` — filter by content type
- `--tag TAG` — filter by tag

Output: Rich table with columns: ID (8-char truncated), Status, Title (or URL), Content Type, Tags, Date.

### `cham item show <id-or-slug>`

Show full item detail. Looks up by slug or UUID prefix.

Output: Key-value display with all item fields.

### `cham config init`

Interactive setup — prompts for server URL and API key, tests the connection via `GET /health`.

### `cham config show`

Print current config. API key is redacted.

## Output Handling

- TTY: Rich tables and formatting
- Non-TTY / `--json`: JSON output
- Errors to stderr

## Configuration

File: `~/.config/cham/config.toml`

```toml
[server]
url = "http://localhost:4000"
api_key = ""
```

Env var overrides: `CHAM_URL`, `CHAM_API_KEY`

## Project Structure

```
cli/
  pyproject.toml
  cham_cli/
    __init__.py
    main.py          # Root click.Group
    config.py        # Config loading/saving
    client.py        # httpx API client
    output.py        # TTY detection, formatting
    commands/
      item.py        # item noun group
      config_cmd.py  # config noun group
```

## Dependencies

- click>=8.1
- rich>=13.0
- httpx>=0.27
- tomli-w>=1.0
- tomli>=2.0 (Python <3.11 only)

## Testing

- pytest with mocked httpx responses
- Test each command's output formatting
- Integration tests (marked, skipped by default) against a running server
